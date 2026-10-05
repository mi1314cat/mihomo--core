#!/usr/bin/env bash
# =============================================================
# mihomo--core · 共享环境库 (env.sh)
#
# 职责:
#   - 环境变量文件读写 (带 flock, 原子替换)
#   - Reality dest 域名选择 (本地实现, 不再依赖外部脚本)
#   - 节点变更后的合并 / 严格校验 / 热重载闭环
#
# 用途: 被 src/conf/*.sh 与 src/*.sh 共同 source
# =============================================================

# ---------- 基础路径 ----------
: "${SRV_ROOT:=/root/catmi/mihomo}"
: "${SRV_CONF:=$SRV_ROOT/conf}"
: "${SRV_CONFIGD:=$SRV_CONF/config.d}"
: "${SRV_CERTS:=$SRV_CONF/certs}"
: "${SRV_OUT:=$SRV_ROOT/out}"
: "${SRV_ENV:=$SRV_ROOT/install_info.env}"
: "${SRV_BIN:=$SRV_ROOT/mihomo}"
: "${SRV_SERVICE:=mihomo}"
: "${SHARE_DIR:=$SRV_ROOT/share}"
: "${SHARE_PORT:=9443}"
: "${SHARE_SERVICE:=mihomo-share}"
: "${CATMI_ENV:=/root/catmi/catmi.env}"
# 注意: 不要写成 : "${M_LIB:=$(...)}" —— 嵌套双引号会让 bash 解析器提前收尾。
if [[ -z "${M_LIB:-}" ]]; then
    M_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi

mkdir -p "$SRV_CONFIGD" "$SRV_CERTS" "$SRV_OUT"

# ---------- 外部依赖 URL ----------
# 仅保留确实无法本地化的第三方资源; 全部走代理回退链。
OCS_RAW="https://github.com/mi1314cat/One-click-script/raw/refs/heads/main"
OCS_PROXY="https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main"

# curl 取远程脚本: 依次尝试 直连 → 代理 → 失败返回非 0
fetch_remote() {
    local path="$1"
    local out; out=$(mktemp)
    if curl -fsSL --max-time 20 "$OCS_RAW/$path" -o "$out" 2>/dev/null \
    || curl -fsSL --max-time 20 "$OCS_PROXY/$path" -o "$out" 2>/dev/null; then
        cat "$out"; rm -f "$out"; return 0
    fi
    rm -f "$out"; return 1
}

# =============================================================
# 环境变量文件读写
#
# 全部委托给 envtool.py:
#   - 文件格式固定 KEY="VALUE"
#   - 从不 source / eval, 不可能执行任意代码
#   - flock 串行化 + 原子替换
#   - 转义/反转义不在 bash 里做 (bash 的 ${v//...} 很容易把结尾 $} 误解析)
# =============================================================
ENVTOOL="$M_LIB/envtool.py"

m_set_env() { python3 "$ENVTOOL" set "$1" "$2" "${3:-}"; }
m_get_env() { python3 "$ENVTOOL" get "$1" "$2"; }

# m_load_env <文件> —— 输出 key<TAB>value, 以 IFS=$'\t' 读入当前 shell
m_load_env() {
    local file="${1:-$SRV_ENV}"
    [ -f "$file" ] || return 1
    local k v
    while IFS=$'\t' read -r k v; do
        [ -n "$k" ] || continue
        printf -v "$k" '%s' "$v"
    done < <(python3 "$ENVTOOL" load "$file")
    return 0
}

# =============================================================
# Reality dest 域名选择
#
# Reality 的 dest 只是"借一个 443 上跑 TLS1.3 的站点", 不需要你拥有它。
# 本地内置一份常用清单, 并允许自定义 —— 不再强依赖外部 domains.sh。
# =============================================================
REALITY_DESTS=(
    "www.microsoft.com"  "www.bing.com"      "oracle.com"
    "www.apple.com"      "www.cloudflare.com" "swdist.apple.com"
    "www.lovelive-anime.jp" "dl.google.com"  "www.nvidia.com"
    "one.one.one.one"    "www.tesla.com"
)

# m_pick_dest [当前值]
# 返回值写入全局 DEST_SERVER
m_pick_dest() {
    local cur="${1:-}"
    printf "\n请选择 Reality 目标站点 (dest / server-names):\n" >&2
    printf "  %s\n" "  这些站点仅用于借用 TLS 证书, 你无需拥有它们。" >&2
    local i
    for i in "${!REALITY_DESTS[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${REALITY_DESTS[$i]}" >&2
    done
    printf "  %2d) 手动输入域名\n" "$(( ${#REALITY_DESTS[@]} + 1 ))" >&2
    printf "\n请选择 [默认 1]: " >&2
    local n; read -r n; n="${n:-1}"

    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -le "${#REALITY_DESTS[@]}" ]; then
        DEST_SERVER="${REALITY_DESTS[$((n-1))]}"
    else
        printf "请输入域名: " >&2
        local d; read -r d
        d=$(echo "$d" | tr -d '\000-\037' | tr '[:upper:]' '[:lower:]')
        [[ "$d" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || { print_error "域名不合法"; return 1; }
        DEST_SERVER="$d"
    fi
    m_set_env "$SRV_ENV" dest_server "$DEST_SERVER"
    return 0
}

# =============================================================
# 变更闭环: 合并 config.d → config.yaml, 严格校验, 通过才重载
#
# 这是本项目最重要的一条纪律 —— 校验不过就绝不重启,
# 避免"配置写坏了 → 服务起不来"。
# =============================================================
m_sync() {
    local quiet="${1:-}"
    [[ -x "$SRV_BIN" ]] || { print_error "未找到 mihomo 内核: $SRV_BIN"; return 1; }

    if ! python3 "$M_LIB/merge.py" --conf "$SRV_CONF" 2>&1; then
        print_error "配置合并失败, 已保留原配置, 未重载服务"
        return 1
    fi

    if ! python3 "$M_LIB/validate.py" --conf "$SRV_CONF" --bin "$SRV_BIN"; then
        print_error "严格字段校验未通过, 已保留原配置, 未重载服务"
        return 1
    fi

    if ! "$SRV_BIN" -t -d "$SRV_CONF" 2>/dev/null; then
        print_error "内核配置检查未通过, 未重载服务"
        return 1
    fi

    [[ -n "$quiet" ]] || print_ok "配置已合并并通过全部校验"
    return 0
}

# m_server_ip —— 生成分享链接 / 客户端配置时对外写的那个地址
#
# 顺序刻意这样排:
#   1. 传参进来的
#   2. install_info.env 里管理员确认过的 PUBLIC_IP
#   3. 实在没有才现探测, 并**明确告警**
#
# 为什么不能把探测放前面: 开了透明代理 (tproxy/redirect) 的机器上,
# --noproxy 对 curl 无效, api.ipify 拿回来的是**代理出口 IP**。
# 把它写进客户端配置, 节点就成了"连自己都连不上"的死节点。
# 踩过的坑: 有节点的 server 被写成了 CDN 出口 IP, 而服务器本身是另一个地址,
# 客户端连过去直接 i/o timeout。
m_server_ip() {
    [[ -n "${1:-}" ]] && { printf '%s' "$1"; return 0; }
    [[ -n "${PUBLIC_IP:-}" ]] && { printf '%s' "$PUBLIC_IP"; return 0; }
    if [[ -f "${SRV_ENV:-}" ]]; then
        m_load_env "$SRV_ENV" 2>/dev/null || true
        [[ -n "${PUBLIC_IP:-}" ]] && { printf '%s' "$PUBLIC_IP"; return 0; }
    fi
    local ip
    ip=$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s6 --max-time 8 https://api64.ipify.org 2>/dev/null)
    if [[ -n "$ip" ]]; then
        print_warn "install_info.env 里没有 PUBLIC_IP, 现探测到 $ip"
        print_warn "若本机开了透明代理, 这很可能是**代理出口 IP**而不是你的服务器 IP"
        print_warn "请确认无误后写回:  python3 src/lib/envtool.py set install_info.env PUBLIC_IP <真实IP>"
    fi
    printf '%s' "$ip"
}

# m_sync_reload —— 校验通过才重载; 失败保留旧配置
m_sync_reload() {
    local bak; bak=$(mktemp)
    [ -f "$SRV_CONF/config.yaml" ] && cp -f "$SRV_CONF/config.yaml" "$bak"

    if m_sync quiet; then
        if systemctl reload "$SRV_SERVICE" 2>/dev/null && \
           systemctl is-active --quiet "$SRV_SERVICE"; then
            [[ -n "${1:-}" ]] || print_ok "已重载服务"
            rm -f "$bak"; return 0
        fi
        if systemctl restart "$SRV_SERVICE" 2>/dev/null; then
            [[ -n "${1:-}" ]] || print_ok "已重启服务"
            rm -f "$bak"; return 0
        fi
        print_error "服务重启失败, 正在回滚配置"
        cp -f "$bak" "$SRV_CONF/config.yaml"; systemctl restart "$SRV_SERVICE" 2>/dev/null
        rm -f "$bak"; return 1
    fi

    # 校验没过: 恢复原配置, 保证服务一直跑的是好配置
    cp -f "$bak" "$SRV_CONF/config.yaml" 2>/dev/null
    rm -f "$bak"
    return 1
}