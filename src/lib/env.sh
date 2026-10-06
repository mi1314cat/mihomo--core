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

# 需要下载执行的第三方脚本统一落在这里 (domains.sh / ssl.sh ...)。
# 不再散落到 /tmp 或进程替换里, 便于排查与清理。
CFMGR_DIR="${CFMGR_DIR:-/root/catmi/mihomo/scripts}"

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

# fetch_script <仓库相对路径> <目标文件>
#
# 下载一个**要被执行**的脚本到本地文件。
#
# 为什么不用 `bash <(curl ...)`:
#   1. 进程替换会把 curl 的管道 fd 交给 bash 读, 一旦 curl 慢/不通,
#      bash 会在该 fd 上自旋不退出 —— 实测表现为面板卡死且吃满 CPU。
#   2. `curl -fsSL` 不带 --max-time 时没有任何上界, 网络异常就是无限期挂起。
#   3. 进程替换拿不到退出码, 失败也无从判断。
#
# 这里统一: 先落到文件 → 校验非空且像 shell 脚本 → 调用方再执行。
fetch_script() {
    local path="$1" dest="$2"
    local tmp="${dest}.part"
    mkdir -p "$CFMGR_DIR" "$(dirname "$dest")"
    local base
    for base in "$OCS_RAW" "$OCS_PROXY"; do
        rm -f "$tmp"
        if curl -fsSL --max-time 30 "$base/$path" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
            # 极简健全性检查: 不是 shell 脚本就别执行
            if head -c 2 "$tmp" | grep -q '#!'; then
                mv -f "$tmp" "$dest"
                chmod +x "$dest" 2>/dev/null
                return 0
            fi
            print_warn "下载内容不像可执行脚本, 已丢弃: $path"
            rm -f "$tmp"
            return 1
        fi
    done
    rm -f "$tmp"
    return 1
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
# 自签证书兜底与客户端接入地址
#
# 以前没有证书/没填域名时, 兜底是 generate_cert "cloudflare.com"。
# 后果实测过: 生成的客户端配置是 server: cloudflare.com + Host: cloudflare.com,
# 面板一路绿灯, 但客户端连的是真正的 cloudflare.com, 和这台服务器毫无关系 ——
# 一个完全不可用、却显示成功的死节点。
#
# 现在改用 RFC 2606 保留 TLD (.invalid 永不解析) 作哨兵, 并且客户端一律回落到
# 服务器真实 IP, 保证自签节点也是"能连上的", 只是没有可信任的证书身份。
# =============================================================
M_NO_DOMAIN="self-signed.invalid"

m_client_host() {
    local cert_domain="${1:-}"
    if [[ -n "$cert_domain" && "$cert_domain" != "$M_NO_DOMAIN" && "$cert_domain" != "cloudflare.com" ]]; then
        printf '%s' "$cert_domain"
        return
    fi
    # 只有自签证书时必须落到真实地址。
    # SERVER_IP 由调用方探测后设置, 但 env.sh 本身不定义它 —— 在 set -u 下
    # 直接引用会"unbound variable"秒杀整个脚本, 所以这里用 :- 兜底并就地探测。
    if [[ -n "${SERVER_IP:-}" ]]; then
        printf '%s' "$SERVER_IP"
        return
    fi
    m_server_ip 2>/dev/null || printf ''
}

# =============================================================
# WS / gRPC 路径
#
# 路径在这里是**安全参数**而不是装饰: 内核侧就是普通的路径匹配
# (listener/inbound 的 ws-path), 路径越短越容易被扫到。
# 之前允许用户随手输入 "/1" 这种, 面板不提示、也不拦。
# =============================================================
M_MIN_WS_PATH_LEN=8

m_check_ws_path() {
    local p="${1:-}"
    [[ -z "$p" ]] && { print_error "路径不能为空"; return 1; }
    [[ "$p" == /* ]] || p="/$p"
    if [[ "${#p}" -lt "$M_MIN_WS_PATH_LEN" ]]; then
        print_error "路径太短 (${#p} 字符), 至少 $M_MIN_WS_PATH_LEN 个; 短路径容易被扫描命中"
        return 1
    fi
    case "$p" in
        *[[:space:]]*) print_error "路径不能包含空格"; return 1 ;;
        *"?"*|*"#"*) print_error "路径不能包含 ? 或 # (分享链接里会被截断)"; return 1 ;;
    esac
    printf "%s" "$p"
}

# =============================================================
# 端口校验
#
# 拒绝 1-1023 特权段以及一批系统常用端口。
# 之前六份 safe_read_port 都写成 `port >= 1 && port <= 65535`,
# 实测直接把端口填成 2, 面板就以 root 身份把节点绑了上去, 全程零提示。
# 顶掉 sshd / rsyslog / 名字服务这类端口的后果是「面板还在、机器连不上」。
# =============================================================
M_BLOCKED_PORTS="22 23 25 53 67 68 69 80 110 111 123 135 137 138 139 143 161 162 389 443 445 465 514 587 631 636 993 995 1194 1433 1521 2049 3306 3389 5432 5900 6379 8443 9200 11211 27017"

m_port_allowed() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; return 1; }
    (( p >= 1024 && p <= 65535 )) || {
        print_error "端口必须在 1024-65535 之间 (1-1023 是特权端口, 会顶掉 sshd 等系统服务)"
        return 1
    }
    local b
    for b in $M_BLOCKED_PORTS; do
        if [[ "$p" == "$b" ]]; then
            print_error "端口 $p 是系统常用端口, 请换一个"
            return 1
        fi
    done
    return 0
}

# 端口是否已被占用 (TCP + UDP 都要查 —— QUIC 节点只看 TCP 会漏)
m_port_in_use() {
    ss -tulHn 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$' | grep -qx "$1"
}

# m_cert_in_use <证书路径>
#
# 该证书是否还被**其它**片段引用。删除节点时必须先问一遍, 否则会连带
# 删掉别的节点正在用的证书。
#
# 踩过的坑: 一个 cert-<域名>....crt 被 5 个片段共用
# (vless-ws / hysteria2 / anytls / tuicv5 / trojan-tls), 删掉其中任一个
# 导致另外 4 个 TLS 节点全部 listen err: parse certificate failed ——
# 而面板当时还显示"服务: 运行中"。
#
# 传入的路径会被规范化成绝对路径再比对, 避免相对/绝对写法不同导致漏判。
m_cert_in_use() {
    local want="$1" f
    [[ -n "$want" ]] || return 1
    want=$(readlink -f "$want" 2>/dev/null || printf '%s' "$want")
    for f in "$SRV_CONFIGD"/*.yaml; do
        [[ -f "$f" ]] || continue
        # 片段里出现该证书的绝对路径即算引用
        grep -qF -- "$want" "$f" 2>/dev/null && return 0
        # 也认文件名形式 (conf/certs/xxx.crt)
        grep -qF -- "$(basename "$want")" "$f" 2>/dev/null && return 0
    done
    return 1
}

# m_cert_gc <要删的证书路径...> —— 只删真正没人用的证书
# 逐个确认, 有引用就跳过并告警, 不静默删。
m_cert_gc() {
    local c base
    for c in "$@"; do
        [[ -e "$c" ]] || continue
        base=$(basename "$c")
        if m_cert_in_use "$c"; then
            print_warn "证书仍被其它节点引用, 已保留: $base"
            continue
        fi
        rm -f "$c" && print_ok "已删除未使用的证书: $base"
    done
}

# ================================================================
# 节点命名
# ================================================================
#
# 之前同一个节点在三处有三个不同的名字, 用户完全对不上:
#   分享链接 # 片段 : VLESS-XHTTP-01   (VLESS.sh:392)
#   all.sh 生成的名字: VLESS-WSS-01
#   片段文件名       : vless-01.yaml    (VLESS.sh:419,444 的 listener/proxy 名)
# 更麻烦的是 Trojan.sh 三个变体 (reality/tls) 的 listener 全叫 trojan-01,
# all.sh 却拆成 Trojan-Reality-01 / Trojan-TLS-01 —— 同一条节点两个身份。
#
# 现在统一到一个函数。规则直接对齐 SB 上游 (lib.sh:2114-2138 的 tag_form_suffix):
#
#   <协议><两位编号>-<形态后缀>[-<方案标签>]
#
#   形态后缀: -REALITY / -TLS / -plain   (只有这三种)
#   方案标签: CDN / ECH / pad / 真证书 / 自签 ...
#
# **传输方式 (ws/grpc/xhttp/h2/tcp) 不进名字** —— 这是 SB 明确的取舍:
#   形态后缀只有三个值, 传输变体不参与。SB 自己的注释 lib.sh:2106 写的是
#   "从名字看出传输方式", 但实现从来只区分 TLS 形态, 注释已过期。
#   照搬实现而不是过期注释。
#
# m_node_tag <协议> <索引> <形态:reality|tls|plain> [方案标签]
# 例: m_node_tag VLESS 01 tls        → mVLESS01-TLS
#     m_node_tag VLESS 01 reality     → mVLESS01-REALITY
#     m_node_tag Trojan 02 plain ECH  → mTrojan02-plain-ECH
#
# 统一前缀 m: 客户端里 mihomo-core 生成的节点一律以 m 开头, 和别的项目/手工
# 加的节点一眼分得开。要改前缀设 M_TAG_PREFIX 即可, 留空则不加。
m_node_tag() {
    local proto="$1" idx="$2" form="${3:-plain}" extra="${4:-}"
    [[ -n "$proto" && -n "$idx" ]] || return 1
    # 索引补零到两位。10# 强制十进制: 否则 08/09 会被当成八进制非法数
    idx=$(printf '%02d' "$((10#$idx))" 2>/dev/null) || idx="$idx"

    local base
    case "$form" in
        reality) base="REALITY" ;;
        tls)     base="TLS" ;;
        *)       base="plain" ;;
    esac
    # 形态已经表达过的词, 标签里不要重复, 否则拼出 "-REALITY-REALITY"。
    # 比较要大小写不敏感: 用户可能传 "TLS" 或 "tls", 但 base 是固定写法。
    case "$form" in
        reality) extra="${extra//REALITY/}"; extra="${extra//reality/}" ;;
        tls)     extra="${extra//TLS/}";     extra="${extra//tls/}" ;;
    esac
    # 标签里的 "+" 是给人看的分隔 (ECH+pad), 拼进名字要换掉, 否则
    # 会得到 "TLS-ECHpad" 这种看不出边界的东西
    extra="${extra//+/-}"
    while [[ "$extra" == -* ]]; do extra="${extra#-}"; done
    while [[ "$extra" == *- ]]; do extra="${extra%-}"; done
    while [[ "$extra" == *,* ]]; do extra="${extra/,/}"; done

    # base 不自带前导连字符, 分隔统一在这里加 —— 否则容易拼出双横线
    # 前缀。用 ${VAR-m} 而不是 ${VAR:-m}: 前者只在"未设置"时用默认值,
    # 后者把显式设成空串也当未设置 —— 那样 M_TAG_PREFIX="" 关不掉前缀。
    local pfx="${M_TAG_PREFIX-m}"
    local tag
    if [[ -n "$extra" ]]; then
        tag="${pfx}${proto}${idx}-${base}-${extra}"
    else
        tag="${pfx}${proto}${idx}-${base}"
    fi
    printf -- "%s\n" "$tag"
}

# 从已生成的 tag 反推形态, 供列表页按形态分组显示
m_tag_form() {
    case "$1" in
        *-REALITY*) echo "REALITY" ;;
        *-TLS*)     echo "TLS" ;;
        *)          echo "plain" ;;
    esac
}

# m_safe_read_port <默认值> —— 六个协议脚本共用的端口提问
#
# 失败时返回 1 且**不输出任何东西**。调用方必须写成
#   port=$(m_safe_read_port X) || return 1
# 而不是裸写 $(m_safe_read_port X) —— 后者在 EOF 时会得到空串并继续往下走,
# 写出一个 `port:` 为空的节点。实测这种节点:
#   mihomo -t   → successful
#   validate.py → 严格校验通过
#   面板        → 显示"节点: N"
#   实际        → 端口为空, 完全不能工作
# 所以下面这个函数额外保证: 万一走到成功分支, 端口绝不会为空。
m_safe_read_port() {
    local default="$1" input port
    while true; do
        printf "请输入监听端口 (默认: %s): " "$default" >&2
        # stdin 已关闭 (EOF) 必须退出, 否则这里会变成吃满 CPU 的死循环
        read input || { printf "\n[信息] 非交互环境 (stdin 已关闭), 已退出\n" >&2; return 1; }
        input=$(printf '%s' "$input" | tr -d '\000-\037' | tr -d '[:space:]')
        port="${input:-$default}"

        m_port_allowed "$port" || continue
        if m_port_in_use "$port"; then
            print_error "端口 $port 已被占用, 换一个"
            continue
        fi
        printf '%s' "$port"
        return 0
    done
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

# 该地址是否挂在本机某个接口上
# (与 share.sh 的同名函数保持一致; 两处都要有, 因为 env.sh 不依赖 share.sh)
m_addr_is_local() {
    local a="$1"
    [[ -n "$a" ]] || return 1
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$a"
}

# 本机第一个全局单播地址 (优先 IPv4, 兼容性最好)
m_local_addr() {
    local v4 v6
    v4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$v4" ]] && { printf '%s' "$v4"; return 0; }
    v6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^fe80:' | head -1)
    [[ -n "$v6" ]] && { printf '%s' "$v6"; return 0; }
    return 1
}

# m_server_ip —— 生成分享链接 / 客户端配置时对外写的那个地址
#
# 顺序刻意这样排:
#   1. 传参进来的
#   2. install_info.env 里管理员确认过的 PUBLIC_IP
#   3. 外部探测, 但**必须先自检**: 不在本机接口上的地址直接丢弃
#   4. 兜底用本机接口地址
#
# 为什么不能把探测放前面: 开了透明代理 (tproxy/redirect) 的机器上,
# --noproxy 对 curl 无效, api.ipify 拿回来的是**代理出口 IP**。
# 把它写进客户端配置, 节点就成了"连自己都连不上"的死节点。
#
# 踩过的坑: all.sh 用未校验的 m_server_ip, 13 个节点的 server
# 全被写成 WARP 出口 <WARP_EXIT_IP>, 真实 IP 是 <REAL_SERVER_IP>。
# 那个地址端口全不通, 客户端 13/13 全部连不上。
# 而 share.sh 的 _share_addr 早已有自检, 于是**分享地址对、节点地址错** ——
# 同一个项目两套 IP 探测逻辑, 这次把它们统一。
m_server_ip() {
    [[ -n "${1:-}" ]] && { printf '%s' "$1"; return 0; }
    # 内存里已加载的值
    if [[ -n "${PUBLIC_IP:-}" ]]; then
        if m_addr_is_local "$PUBLIC_IP" || [[ "${PUBLIC_IP_VERIFIED:-}" == "1" ]]; then
            printf '%s' "$PUBLIC_IP"; return 0
        fi
        print_warn "已记录的 PUBLIC_IP=$PUBLIC_IP 不在本机接口上, 忽略"
        unset PUBLIC_IP
    fi
    # 从 install_info.env 读。存的旧值同样要过自检 —— 修复前的版本在这里
    # 直接返回, 于是 install_info.env 里那个 WARP 出口地址 (<WARP_EXIT_IP>)
    # 会被一直沿用, 自检形同虚设 (实测 2026-10-06, 修复后仍返回旧值)。
    if [[ -f "${SRV_ENV:-}" ]]; then
        m_load_env "$SRV_ENV" 2>/dev/null || true
        if [[ -n "${PUBLIC_IP:-}" ]]; then
            if m_addr_is_local "$PUBLIC_IP" || [[ "${PUBLIC_IP_VERIFIED:-}" == "1" ]]; then
                printf '%s' "$PUBLIC_IP"; return 0
            fi
            print_warn "install_info.env 里的 PUBLIC_IP=$PUBLIC_IP 不在本机接口上, 已忽略"
            print_warn "  (多半是 WARP/透明代理的出口地址, 客户端连不上)"
            print_warn "  确认要改成正确值请执行:"
            print_warn "    python3 src/lib/envtool.py set install_info.env PUBLIC_IP <真实IP>"
            unset PUBLIC_IP
        fi
    fi

    local cand
    for cand in \
        "$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null)" \
        "$(curl -s6 --max-time 8 https://api64.ipify.org 2>/dev/null)"; do
        [[ -n "$cand" ]] || continue
        # 关键: 挂在本机接口上才认。多网卡/多 IP 的机器外部探测常给出
        # 另一个地址, 这时宁可退回本机地址也不要写一个连不上的。
        if m_addr_is_local "$cand"; then
            printf '%s' "$cand"
            return 0
        fi
        print_warn "探测到地址 $cand 不在本机接口上 (多半是 WARP/透明代理的出口), 已丢弃"
    done

    # 兜底: 本机接口地址。NAT 后仍需管理员确认, 但至少是个真实可达的地址,
    # 比写一个代理出口地址强。
    if cand=$(m_local_addr); then
        print_warn "外部探测未通过自检, 改用本机接口地址: $cand"
        print_warn "若本机在 NAT 后面, 请确认客户端能直连, 或手动设置:"
        print_warn "  python3 src/lib/envtool.py set install_info.env PUBLIC_IP <真实IP>"
        printf '%s' "$cand"
        return 0
    fi

    print_error "无法确定对外地址, 且本机没有全局单播地址"
    print_error "请手动设置:  python3 src/lib/envtool.py set install_info.env PUBLIC_IP <真实IP>"
    return 1
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