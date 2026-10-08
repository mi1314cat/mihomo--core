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

# ---------- UI 基座 ----------
# 颜色/消息/标题/菜单 全在这里定义, 由 ui.sh 一处维护。
# 放在最前面: env.sh 里后面要用 print_warn/print_error, 得先有定义。
_MUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
# shellcheck source=/dev/null
[[ -f "$_MUI" ]] && source "$_MUI"

# 内核/版本管理。依赖上面的 ui.sh (print_* / ui_*), 必须在它之后加载
_MCM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core_mgmt.sh"
# shellcheck source=/dev/null
[[ -f "$_MCM" ]] && source "$_MCM"

# 防火墙管理 (放行/关闭/孤儿清理)
_MFW="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fw.sh"
# shellcheck source=/dev/null
[[ -f "$_MFW" ]] && source "$_MFW"

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

# ---------- 服务端目录 ----------
# 只有服务端上下文才建这套目录树。
#
# 客户端 (src/client.sh) 也会 source 本文件 —— 它需要 m_resolve_ports /
# m_free_port / m_port_in_use 这些公共 helper, 而它们**只在这里定义**。
# 但客户端不该在 /root/catmi/mihomo 下建出**服务端**的目录树: 那台机器上
# 可能根本没有服务端, 甚至 /root/catmi/mihomo 属于别的项目。
# 所以客户端先设 M_NO_SRV_DIRS=1 再 source。
if [[ -z "${M_NO_SRV_DIRS:-}" ]]; then
    mkdir -p "$SRV_CONFIGD" "$SRV_CERTS" "$SRV_OUT"
fi

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
            # 健全性检查: 必须是可解析的 shell 脚本才执行。
            # ⚠ 判据不能用 `head -c 2 | grep '#!'` —— domains.sh 第 1 字节是换行,
            #   头两字节永远匹配不上, 会把合法脚本误判丢弃。
            if grep -qm1 '^#!' "$tmp" || bash -n "$tmp" 2>/dev/null; then
                mv -f "$tmp" "$dest"
                chmod +x "$dest" 2>/dev/null
                return 0
            fi
            print_warn "下载内容不是可执行的 shell 脚本, 已丢弃: $path"
            rm -f "$tmp"
            # ⚠ 这里原本是 return 1 —— 直接跳出镜像循环, **备用源根本没试**。
            #   一个镜像出问题就等于整体失败。改成 continue 试下一个源。
            continue
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

# URI 里的主机字面量 —— IPv6 必须加方括号。
#
# vless://uuid@2001:db8::1:443 里的冒号和端口的冒号混在一起, 客户端根本解析
# 不出主机地址, 结果就是导入失败或连不上。RFC 3986 规定 IPv6 字面量写成
# [addr]。
#
# ⚠ 只在**拼分享链接**时套这个 —— 客户端 YAML 里的 server: 要用裸地址,
#   mihomo 不接受 [2001:db8::1] 这种写法。所以变量本身保持裸值, 在拼串的
#   那一刻套壳; 早先有人想把 LINK_IP 整个变成带括号的值, 结果 YAML 的
#   server: 也跟着带了括号, 节点直接连不上。
m_uri_host() {
    local h="${1:-}"
    [[ -n "$h" ]] || return 0
    case "$h" in
        \[*\]) printf '%s' "$h" ;;   # 已经套过壳的别套两遍
        *:*)   printf '[%s]' "$h" ;;
        *)     printf '%s' "$h" ;;
    esac
}

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
m_port_in_use() { m_port_listening "$1"; }

# m_port_held_by_self <端口> —— 占用它的进程是不是**我们自己**的 mihomo?
#
# 为什么必须区分"谁在占"
# ----------------------
# m_resolve_ports 的注释写着"已经在用的端口 (自己刚起的服务) 不算冲突",
# 但实现只调了 m_port_in_use —— 那只回答"有没有人在听", 分不出是谁。
# 全新安装上这个缺口**必现**:
#   core_install 生成的基线配置把 external-controller 定成
#   127.0.0.1:9090 并**立刻启动服务**, 随后首次进面板调 m_resolve_ports,
#   它看到 9090 在监听 (其实是自己), 于是把控制口顺延成 9091 写进
#   settings.env, 还告诉用户"9090 已被占用"。用户从没要求改端口, 而
#   9090 上坐着的正是他刚装的这个客户端; 每重装一次就再往后推一位。
#
# 判据用 /proc/<pid>/exe 与候选内核路径比对, 而不是看进程名 —— 机器上
# 常有**另一个**项目的 mihomo 同名在跑, 那种必须照旧算真冲突。
m_port_held_by_self() {
    local port="$1" pid exe cand real v
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    local cands=()
    for v in "${MIHOMO_BIN:-}" "${CLI_BIN:-}" "${SRV_BIN:-}"; do
        [[ -n "$v" ]] && cands+=("$v")
    done
    for v in "${SRV_ROOT:-}" "${CLI_ROOT:-}" "${M_ROOT:-}" "${INSTALL_DIR:-}"; do
        [[ -n "$v" ]] && cands+=("$v/mihomo")
    done
    ((${#cands[@]})) || return 1

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
        [[ -n "$exe" ]] || continue
        for cand in "${cands[@]}"; do
            [[ -e "$cand" ]] || continue
            real=$(readlink -f "$cand" 2>/dev/null) || continue
            [[ "$exe" == "$real" ]] && return 0
        done
    done < <(ss -tulnpH 2>/dev/null | grep -E "[:.]${port}[[:space:]]" \
             | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    return 1
}

# 真正的端口冲突: 有人在听, **并且** 那不是我们自己刚起的那个内核。
m_port_conflict() {
    m_port_in_use "$1" || return 1
    m_port_held_by_self "$1" && return 1
    return 0
}

# m_free_port [首选端口] [扫描范围]
#
# 首选端口空闲就用它, 被占用则向后顺延找一个空闲的。
# 输出选定的端口号; 全被占满返回 1。
#
# 为什么需要它
# ------------
# 踩过的坑: 全新安装时默认 mixed-port 7890,
# 而这台机器上**另一个**项目的 mihomo 正占着 7890/9090。结果是
# 新装的客户端起不来 —— mihomo 进程直接退出, 面板却显示"运行中"。
# 用户看到的是一个"装好了但连不上"的死局, 还得自己想到去查端口冲突。
#
# 这不是"检测一下就好"的问题: 端口冲突的**表现**与内核崩溃、证书错误、
# 订阅为空全都一样 (面板只说"运行中"或一句报错), 排查成本很高。
# 安装阶段就把这件事定死, 比事后让人去猜要划算。
#
# 顺延而不是报错: 用户不关心你为什么不能用 7890, 只关心能用。
m_free_port() {
    local want="${1:-}" span="${2:-200}"
    [[ -n "$want" ]] || { printf '1\n'; return 0; }

    if ! m_port_in_use "$want"; then
        printf '%s\n' "$want"
        return 0
    fi

    local i p
    for (( i = 1; i <= span; i++ )); do
        p=$(( want + i ))
        (( p <= 65535 )) || break
        m_port_in_use "$p" && continue
        printf '%s\n' "$p"
        return 0
    done
    return 1
}

# m_resolve_ports —— 安装阶段把三个端口定死, 有冲突就顺延并说明。
#
# 输出三个变量名对应的值, 由调用方 source 或读回:
#   M_PORT_MIXED  代理口   (客户端)
#   M_PORT_CTRL   控制面板 (客户端)
#   M_PORT_SHARE  分享口   (服务端)
#
# 已经在用的端口 (自己刚起的服务) 不算冲突 —— 那种情况下宁可沿用旧值,
# 否则每次重跑安装都会把端口推着往前跑, 用户会发现端口一直在变。
m_resolve_ports() {
    local mixed="${1:-7890}" ctrl="${2:-9090}" share="${3-}"
    local changed=0

    if m_port_conflict "$mixed"; then
        local n
        if n=$(m_free_port "$mixed" 200); then
            if [[ "$n" != "$mixed" ]]; then
                print_warn "端口 $mixed 已被占用, 代理口改用 $n"
                mixed="$n"; changed=1
            fi
        else
            print_warn "端口 $mixed 起顺延 200 个都被占, 保留原值 (请手工改)"
        fi
    fi

    if m_port_conflict "$ctrl"; then
        local n
        if n=$(m_free_port "$ctrl" 200); then
            if [[ "$n" != "$ctrl" ]]; then
                print_warn "端口 $ctrl 已被占用, 控制面板口改用 $n"
                ctrl="$n"; changed=1
            fi
        else
            print_warn "端口 $ctrl 起顺延 200 个都被占, 保留原值 (请手工改)"
        fi
    fi

    # 分享口只服务端要用。客户端传空串跳过 —— 客户端的分享口是
    # 另一个变量 (CLI_SHARE_PORT, 默认 9444), 不该在这里被 9443 顶掉。
    if [[ -n "$share" ]] && m_port_conflict "$share"; then
        local n
        if n=$(m_free_port "$share" 200); then
            if [[ "$n" != "$share" ]]; then
                print_warn "端口 $share 已被占用, 分享口改用 $n"
                share="$n"; changed=1
            fi
        else
            print_warn "端口 $share 起顺延 200 个都被占, 保留原值 (请手工改)"
        fi
    fi

    M_PORT_MIXED="$mixed"
    M_PORT_CTRL="$ctrl"
    M_PORT_SHARE="$share"
    [[ "$changed" -eq 1 ]] && print_info "端口已按实际占用情况调整, 见上方提示"
    return 0
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
    local proto="$1" idx="$2" form="${3:-plain}"
    # 第 4 个之后**全部**并进 extra, 不能只取 $4。
    #
    # 原来只读 "$4", 而调用方写的是 m_node_tag VLESS 3 tls XHTTP CDN —— "CDN"
    # 落在 $5, 被静默丢掉。于是走 CDN 的 xHTTP 节点叫 "mVLESS03-TLS-XHTTP",
    # 跟直连那个 "mVLESS02-TLS-XHTTP" 只差编号, 面板上完全看不出谁是过 CDN 的。
    # 排查 CDN 问题时先被名字带偏 —— 本来就在这里绕过一次。
    local extra=""
    if (( $# >= 4 )); then
        shift 3
        # 用 tr 而不是 ${*// /-}: 后者在 zsh 下不做替换, 而面板偶尔会用
        # zsh 跑这个函数, 于是名字里留下空格, 和其他节点的连字符风格不一致。
        extra=$(printf '%s' "$*" | tr ' ' '-')
    fi
    [[ -n "$proto" && -n "$idx" ]] || return 1
    # 索引补零到两位。10# 强制十进制: 否则 08/09 会被当成八进制非法数
    idx=$(printf '%02d' "$((10#$idx))" 2>/dev/null) || idx="$idx"

    local base
    case "$form" in
        reality) base="REALITY" ;;
        tls)     base="TLS" ;;
        # ⚠ 这一档原先没有分支, 于是传 "cdn" 的节点**回落到 plain**,
        #   节点名显示成 "mTrojan04-plain-WS"。但它是过 Cloudflare 的节点,
        #   连的是边缘 443, 不是源站端口 —— 名字写成 plain 会让人以为它是
        #   直连裸节点, 排查 CDN 问题时先被名字带偏。
        cdn)     base="CDN" ;;
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
# ⚠️ 这份清单是**实测**出来的, 不是抄的。REALITY 借宿的站点必须与 REALITY
#    的握手流程兼容 —— 光"能 TLS 握手 / 能 HTTP 200"完全不够, 很多站点普通
#    TLS 全通但 REALITY 认证必失败 (客户端报 REALITY authentication failed,
#    服务端一条日志都没有, 面板也是绿的)。
#
#    实测方法: 真实内核起 vless+reality listener, 用同一对密钥做客户端,
#    经 mixed-port 打 generate_204。每项跑两次排除偶发。
#    实测环境:  节点。
#
#    教训: 兜底值绝不能拍脑袋写。老代码兜底用的正是 bing, 于是"不手动选
#    dest"的用户 100% 拿到一个连不上、却显示成功的 REALITY 节点。
#
# 2026-10-07 实测 (真实内核握手 x3): 下面 12 个全部 3/3 通过。
# 上一版记为"坏"的 bing / 1.1.1.1 本轮反而通过 —— 静态判定并不稳定,
# 所以这份名单只是"此刻可用"的快照, 不是真理。域名池才是第一来源,
# M_REALITY_PROBE_FORCE=1 可强制重测。
REALITY_DESTS_BAD=("oracle.com")
# =============================================================
# 统一域名优选 (从 One-click-script 的 domains.sh 现场取, 失败退回本地名单)
#
# domains.sh 的接口是 stdin 不是命令行参数: 关掉 stdin 让 read 返回空,
# 即走 random_website() 现场优选。抽函数执行而不整份跑, 是为了避开它开头
# 对 update_env.sh / load_env.sh 的 source 依赖, 以及写盘副作用。

# 把 provider 文件里的节点按当前设置改写 (指纹 / 连接地址)。
#
# 改写发生在**客户端本地**: 订阅拉回来的原始节点里带的是服务端生成时的
# server 地址和指纹, 客户端想换就换 —— 服务端监听不受影响, 也不用回服务端
# 重新生成。订阅下次更新会覆盖, 所以每次 update 后都要再改写一次。
# 把 provider 文件里的节点按当前设置改写 (指纹 / 连接地址)。
#
# ⚠ 连接地址改写的是**服务端**的地址, 不是本机的 —— 节点要连的是服务端,
#   写成 m_addr_current (本机地址) 会把节点指向客户端自己。
#   订阅里只有服务端的一个地址, 所以换地址族靠映射表:
#       .addr-map 里存 "<服务端v4> <服务端v6>"
#   用户选 IPv6 而映射里没有对应记录时, 菜单里问一次并存下来。
#   订阅更新会覆盖文件, 所以每次更新后都要再改写一次。
# 拉取文本到 stdout (只读, 不落盘不执行)。
# 与 fetch_script 的区别: 后者是为了执行才落盘, 这里只需解析文本。
fetch_text() { # <url>
    local url="${1:-}" base
    [[ -n "$url" ]] || return 1
    for base in "$url"; do
        curl -fsSL --max-time 30 "$base" 2>/dev/null && return 0
    done
    return 1
}

DOMAINS_URL="${DOMAINS_URL:-https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh}"

m_auto_website() {   # <尝试次数-默认 3>  → stdout: 一个域名; 失败返回 1
    local tries="${1:-3}" tmp fn d i=1
    while (( i <= tries )); do
        tmp=$(fetch_text "$DOMAINS_URL" 2>/dev/null) || true
        [[ -n "$tmp" ]] && break
        sleep 1
    done
    if [[ -z "$tmp" ]]; then
        print_warn "拉取 domains.sh 失败"
        return 1
    fi

    # 只抽 random_website() 一个函数执行, 跳过文件尾部的 read/update_env 尾巴:
    #   不 source 外部脚本、不看 catmi.env 的 mode、不写盘, 域名直接走 stdout。
    #   (整份执行会把域名写进 mode 指向的那个产品的 install_info.env)
    fn=$(printf '%s\n' "$tmp" \
         | awk '/^random_website\(\) *\{/{f=1} f{print; if (/^\}/) exit}')

    # 抽不到就退回整份执行 (万一将来 random_website 改名或换了写法)
    if [[ -n "$fn" ]]; then
        d=$(bash -c "$fn; random_website" 2>/dev/null)
    else
        d=$(bash -c "$tmp" </dev/null 2>/dev/null | tail -1)
    fi

    d=$(clean_input "$d" | tr '[:upper:]' '[:lower:]' | sed 's|^[a-z]*://||; s|/.*$||')
    [[ "$d" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || { print_warn "domains.sh 返回的域名不合法: ${d:-空}"; return 1; }
    echo "$d"
}

# =============================================================
# 客户端节点改写: 指纹 / 连接地址
#
# 这两项都只影响**客户端产物里连向服务端的那个节点**, 服务端监听不受影响,
# 所以放在客户端改就够, 不必回服务端重生成。
#
# 指纹: 对齐 SB 的 SB_UTLS_FINGERPRINTS。⚠ 未知值在 mihomo 里只 log.Warnln
#   后**静默降级成原生 TLS** (utls.go:56-59) —— 抗识别最差, 所以只认枚举内的值。
#   'none'/空 = 关闭 uTLS, 不进菜单 (utls.go:43-45)。
# =============================================================
M_UTLS_FINGERPRINTS=(chrome firefox edge safari 360 qq ios android random randomized)
M_DEFAULT_FP="chrome"

m_fp_state_file() { printf '%s' "${SRV_ROOT:-/root/catmi/mihomo}/.fp"; }
m_fp_get() {
    local v=""; [[ -f "$(m_fp_state_file)" ]] && v=$(head -1 "$(m_fp_state_file)" 2>/dev/null | tr -d '[:space:]')
    local k; for k in "${M_UTLS_FINGERPRINTS[@]}"; do [[ "$v" == "$k" ]] && { printf '%s' "$k"; return 0; }; done
    printf '%s' "$M_DEFAULT_FP"
}
# 建节点时各协议用它作为指纹默认值 (走推荐档时不单独问指纹)
m_fp_default() { printf '%s' "$M_DEFAULT_FP"; }

m_fp_set() {
    local k; for k in "${M_UTLS_FINGERPRINTS[@]}"; do
        [[ "$1" == "$k" ]] && { printf '%s\n' "$k" > "$(m_fp_state_file)"; return 0; }
    done
    return 1
}

# ---------- 地址族 ----------
#
# ⚠ WARP 陷阱: 套了 WARP 时**绝不能**用外部 API 问出口 IP —— 那条查询本身
#   就走 WARP, 返回的是 WARP 地址, 客户端拿去直连必然失败。所以这里只读网卡,
#   并排除隧道/虚拟接口上的地址 (M_TUNNEL_IFACE_RE)。
#   同理, 客户端产物里写 WARP 的 v6 等于把所有流量绕进 WARP, 不是服务器地址。
#
# 另外: 服务端**监听地址**和**产物里写哪个地址**是两件事 —— 双栈监听(::)但
#   产物里写死 IPv4 的话, IPv6 客户端照样连不上。两边都要能选。

m_addr4_real() {
    local dev cidr
    while read -r dev cidr; do
        [[ -n "$dev" && -n "$cidr" ]] || continue
        [[ "$dev" =~ $M_TUNNEL_IFACE_RE ]] && continue
        m_is_private_addr "$cidr" && continue
        case "$cidr" in *:*) continue ;; esac
        printf '%s' "$cidr"; return 0
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $2, $4}' | sed 's|/[0-9]*$||')
    return 1
}

m_addr6_real() {
    local dev cidr
    while read -r dev cidr; do
        [[ -n "$dev" && -n "$cidr" ]] || continue
        [[ "$dev" =~ $M_TUNNEL_IFACE_RE ]] && continue
        case "$cidr" in *:*) printf '%s' "$cidr"; return 0 ;; esac
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $2, $4}' | sed 's|/[0-9]*$||')
    return 1
}

m_warp_active() {
    ip -o addr show scope global 2>/dev/null | awk '{print $2}' | grep -qE "$M_TUNNEL_IFACE_RE"
}

m_addr_family_get() {
    local v=""; [[ -f "$(m_addr_state_file)" ]] && v=$(head -1 "$(m_addr_state_file)" 2>/dev/null | tr -d '[:space:]')
    [[ "$v" == "v6" ]] && { printf 'v6'; return 0; }
    printf 'v4'
}
m_addr_state_file() { printf '%s' "${SRV_ROOT:-/root/catmi/mihomo}/.addr-family"; }
m_addr_family_set() { printf '%s\n' "$1" > "$(m_addr_state_file)"; }
m_addr_family_label() { [[ "$(m_addr_family_get)" == "v6" ]] && printf 'IPv6' || printf 'IPv4'; }

# 当前地址族对应的地址。选了 v6 但本机没有真实 v6 时**如实告知并回退**,
# 不能悄悄给一个连不上的地址。
m_addr_current() {
    if [[ "$(m_addr_family_get)" == "v6" ]]; then
        local a; a=$(m_addr6_real 2>/dev/null)
        if [[ -n "$a" ]]; then printf '%s' "$a"; return 0; fi
        print_warn "本机没有可用的真实 IPv6 (WARP 隧道地址已排除), 回退 IPv4"
    fi
    m_addr4_real 2>/dev/null || m_server_ip
}

# 服务端自身的真实 v4 / v6 (排除 WARP 等隧道接口), 写进 install_info.env,
# 方便客户端切换地址族时直接取, 不用手打。
m_publish_addrs() {
    local v4 v6
    v4=$(m_addr4_real 2>/dev/null) || v4=""
    v6=$(m_addr6_real  2>/dev/null) || v6=""
    local f="${SRV_ENV:-$SRV_ROOT/install_info.env}"
    [[ -f "$f" ]] || return 1
    sed -i '/^server_ipv4=/d;/^server_ipv6=/d' "$f" 2>/dev/null
    {
        [[ -n "$v4" ]] && printf 'server_ipv4="%s"
' "$v4"
        [[ -n "$v6" ]] && printf 'server_ipv6="%s"
' "$v6"
    } >> "$f" 2>/dev/null
    m_warp_active && print_info "检测到 WARP/隧道接口, 其上的地址未纳入 server_ipv4/ipv6" >&2
}

# =============================================================
# nginx 站点检测 —— 扫出本机真正在用的 server_name
#
# 为什么必须扫 nginx 而不是让用户手打:
#   证书选择和 CDN 回源都要"选哪个域名"。光列 /etc/letsencrypt/live 下的
#   证书路径, 用户判断不了"哪个域名是我对外真在用的"; 而 nginx 站点里的
#   server_name 就是他真实对外的域名, 拿来对照选择直观得多 (做法对齐 SB 的
#   sb_scan_nginx_sites)。
#
# ★ 必须同时扫容器里的 nginx:
#   很多部署 (含本项目实测的这台) 的 nginx 跑在 docker 容器中, 宿主机上
#   /etc/nginx/conf.d 是空的。只扫宿主机 → 一个站点都列不出来, 界面上就变成
#   "没检测到", 而用户明明配好了站点。
# =============================================================
m_scan_nginx_sites() {
    local d f n
    # 宿主机
    for d in /etc/nginx /etc/nginx/conf.d /home/web/conf.d /usr/local/nginx/conf; do
        [[ -d "$d" ]] || continue
        while read -r n; do
            [[ -n "$n" ]] && printf '%s\n' "$n"
        done < <(grep -rhoE '^[[:space:]]*server_name[[:space:]]+[^;]+;' "$d" 2>/dev/null                   | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;[[:space:]]*$//'                   | tr ' \t' '\n\n' | grep -vE '^_$')
    done
    # 容器里的 nginx —— 宿主机扫不到的那部分
    command -v docker >/dev/null 2>&1 || return 0
    local c out rc
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
        # ⚠ 这里不能只靠 2>/dev/null 挡错误输出。实测 docker 会把
        #   "OCI runtime exec failed: ... exec: \"sh\": executable file not found in $PATH"
        #   打到 **stdout** —— 机器上只要有一个不含 sh 的容器 (distroless /
        #   scratch 镜像, moontv-core 之类), 这行错误就会原样混进域名列表,
        #   被当成一个"站点域名"显示在选择菜单里。
        #   根治办法是只收**长得像域名**的行, 错误文本再长也过不了这一关。
        out=$(docker exec "$c" sh -c \
            'grep -rhoE "^[[:space:]]*server_name[[:space:]]+[^;]+;" /etc/nginx 2>/dev/null \
             | sed -E "s/^[[:space:]]*server_name[[:space:]]+//; s/;[[:space:]]*$//" \
             | tr " \t" "\n\n" | grep -vE "^_$"' 2>/dev/null)
        rc=$?
        (( rc == 0 )) || continue
        printf '%s\n' "$out"
    done
}

# 去重后的 nginx 站点域名。
#
# 形状校验是必需的, 不是防御性冗余: 宿主机的 grep 也可能吐出半截配置,
# 容器 exec 更是会回错误文本 (见 m_scan_nginx_sites 里的说明)。
# 只有"含点、每段以字母数字开头结尾"才算域名 —— 这条正则同时排除了
# OCI 报错、nginx 的 warning、以及 server_name 里那些通配写法。
m_nginx_domains() {
    m_scan_nginx_sites \
        | grep -E '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
        | tr 'A-Z' 'a-z' | sort -u
}

# 该域名是否已被某个 nginx 站点占用 (用于在证书列表上标注)
m_domain_in_nginx_site() {
    [[ -n "${1:-}" ]] || return 1
    m_nginx_domains | grep -qxF "$1"
}

REALITY_DESTS=(
    "www.microsoft.com"  "www.apple.com"      "www.cloudflare.com"
    "dl.google.com"      "swdist.apple.com"   "www.samsung.com"
    "www.amd.com"        "www.intel.com"      "www.lenovo.com"
    "www.sony.com"       "www.nvidia.com"     "www.tesla.com"
)

# 实测坏名单: 仅用于提示, 不放进候选池。保留是为了在用户手动输入这些域名时
# 能给出针对性警告 —— 直接说"这个域名实测不可用", 比让用户自己排查强得多。
# =============================================================
# REALITY dest 实测探针 (防呆的核心)
#
# 为什么需要"实测"而不是查名单:
#   名单会过期。站点换 CDN、上 HRR、改 ALPN 都会让原本可用的 dest 失效,
#   而**失败方式极其隐蔽** —— 客户端报 REALITY authentication failed,
#   服务端一条日志都没有, 面板全绿, 只有用户连不上。
#   光探测"能不能 TLS 握手 / 能不能 HTTP 200"也没用: 实测 www.bing.com
#   两项都正常, REALITY 却必失败。
#
# 做法: 用真实内核起一对临时的 vless+reality 服务端/客户端握手一次,
#       经 mixed-port 打 generate_204。这是唯一能反映真实行为的方法。
#
# 开销: 每项约 4-5 秒。结果写入缓存, 同一域名只测一次。
# =============================================================
M_DEST_CACHE="${M_DEST_CACHE:-$SRV_ROOT/reality_dest_cache.tsv}"

# 预置缓存: REALITY_DESTS 里这 8 个是 2026-10-06 实测可用的, 直接写进缓存。
# 好处: 从名单里选 dest 是**秒过**的, 只有"手动输入新域名"才真跑一次探针。
# 名单仍可能过期, 所以可用 M_REALITY_PROBE_FORCE=1 强制重测。
m_reality_dest_cache_seed() {
    [[ -f "$M_DEST_CACHE" ]] && return 0
    mkdir -p "$(dirname "$M_DEST_CACHE")" 2>/dev/null || return 0
    # ⚠ 种子只是"此刻实测通过"的快照, 不是真理; 域名池才是第一来源,
    #   M_REALITY_PROBE_FORCE=1 可强制重测, 不信种子。
    { local d
      for d in "${REALITY_DESTS[@]}"; do printf '%s\tok\n' "$d"; done
      for d in "${REALITY_DESTS_BAD[@]}"; do printf '%s\tbad\n' "$d"; done
    } > "$M_DEST_CACHE" 2>/dev/null || true
}

# 读缓存: 命中回显 ok/bad, 未命中回显空
m_reality_dest_cached() { # <域名>
    local d="${1:-}"
    m_reality_dest_cache_seed
    [[ -f "$M_DEST_CACHE" ]] || return 0
    awk -F'\t' -v k="$d" '$1==k{print $2; exit}' "$M_DEST_CACHE" 2>/dev/null
}

# 写缓存 (同域名只留一条)
m_reality_dest_cache_put() { # <域名> <ok|bad>
    local d="${1:-}" v="${2:-}" tmp
    [[ -n "$d" && -n "$v" ]] || return 0
    mkdir -p "$(dirname "$M_DEST_CACHE")" 2>/dev/null || true
    tmp="${M_DEST_CACHE}.tmp.$$"
    { [[ -f "$M_DEST_CACHE" ]] && awk -F'\t' -v k="$d" '$1!=k' "$M_DEST_CACHE"
      printf '%s\t%s\n' "$d" "$v"; } > "$tmp" 2>/dev/null && mv -f "$tmp" "$M_DEST_CACHE" 2>/dev/null || rm -f "$tmp"
}

# 实测一个 dest 是否与 REALITY 兼容。
#   返回 0 = 可用, 1 = 不可用
#   M_REALITY_PROBE_FORCE=1 时忽略缓存
m_reality_dest_probe() { # <域名> [<保留端口-可选>]
    local d="${1:-}" base_port="${2:-}"
    [[ -n "$d" ]] || return 1
    [[ -x "${MIHOMO_BIN:-}" ]] || return 1

    if [[ "${M_REALITY_PROBE_FORCE:-0}" != "1" ]]; then
        local c; c=$(m_reality_dest_cached "$d")
        [[ "$c" == "ok" ]] && return 0
        [[ "$c" == "bad" ]] && return 1
    fi

    local tmp; tmp=$(mktemp -d 2>/dev/null) || return 1
    local rk priv pub sid sp cp
    rk=$("$MIHOMO_BIN" generate reality-keypair 2>/dev/null)
    priv=$(printf '%s\n' "$rk" | awk '/PrivateKey/{print $2}')
    pub=$(printf '%s\n'  "$rk" | awk '/PublicKey/{print $2}')
    [[ -n "$priv" && -n "$pub" ]] || { rm -rf "$tmp"; return 1; }
    sid="0123456789abcdef"
    # 端口: 调用方给了就用, 否则在 40000-44999 里随机试
    if [[ -n "$base_port" ]]; then sp="$base_port"; else sp=$(( (RANDOM % 5000) + 40000 )); fi
    cp=$((sp + 1))

    cat > "$tmp/s.yaml" <<EOF
listeners:
  - name: probe
    type: vless
    port: $sp
    listen: 127.0.0.1
    users:
      - uuid: 11111111-2222-3333-4444-555555555555
        flow: xtls-rprx-vision
    network: tcp
    tls: true
    reality-config:
      dest: $d:443
      private-key: $priv
      server-names:
        - $d
      short-id:
        - $sid
rules:
  - MATCH,DIRECT
EOF
    cat > "$tmp/c.yaml" <<EOF
mixed-port: $cp
log-level: silent
proxies:
  - name: probe
    type: vless
    server: 127.0.0.1
    port: $sp
    uuid: 11111111-2222-3333-4444-555555555555
    network: tcp
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    tls: true
    servername: $d
    reality-opts:
      public-key: $pub
      short-id: $sid
rules:
  - MATCH,probe
EOF

    "$MIHOMO_BIN" -d "$tmp" -f "$tmp/s.yaml" > "$tmp/s.log" 2>&1 &
    local spid=$!
    sleep 1.2
    "$MIHOMO_BIN" -d "$tmp" -f "$tmp/c.yaml" > "$tmp/c.log" 2>&1 &
    local cpid=$!
    sleep 1.5
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 7 \
        -x "http://127.0.0.1:$cp" https://www.gstatic.com/generate_204 2>/dev/null)
    kill "$spid" "$cpid" 2>/dev/null
    wait "$spid" "$cpid" 2>/dev/null
    rm -rf "$tmp"

    if [[ "$code" == "204" ]]; then
        m_reality_dest_cache_put "$d" ok
        return 0
    fi
    m_reality_dest_cache_put "$d" bad
    return 1
}

# 供菜单调用: 提示 + 实测 + 结论。永远 return 0 (不阻断流程)
m_reality_dest_check() { # <域名>
    local d="${1:-}"
    [[ -n "$d" ]] || return 0
    if m_reality_dest_known_bad "$d"; then
        print_warn "「$d」在实测坏名单里 REALITY 会握手失败 (普通 TLS 却是通的)"
        print_warn "  建议换一个; 若坚持使用请自行验证连通性"
        return 0
    fi
    if [[ "${M_REALITY_SKIP_PROBE:-0}" == "1" ]]; then return 0; fi
    local c; c=$(m_reality_dest_cached "$d")
    if [[ "$c" == "ok" ]]; then
        print_info "「$d」此前实测可用 (缓存)"
        return 0
    fi
    if [[ "$c" == "bad" ]]; then
        print_warn "「$d」此前实测**不可用** (缓存); REALITY 大概率连不上"
        return 0
    fi
    print_info "正在实测「$d」与 REALITY 的兼容性 (约 5 秒)..."
    if m_reality_dest_probe "$d"; then
        print_ok "「$d」实测可用"
    else
        print_warn "「$d」实测**不可用** —— REALITY 节点会连不上, 建议换一个"
    fi
    return 0
}

# 判断某个 dest 是否落在实测坏名单里 (含子域匹配: images-na.ssl-images-amazon.com
# 这类 CDN 子域与其根域行为一致的场景)。命中返回 0。
m_reality_dest_known_bad() {
    local d="${1:-}" b
    [[ -n "$d" ]] || return 1
    d="${d,,}"
    for b in "${REALITY_DESTS_BAD[@]}"; do
        [[ "$d" == "${b,,}" ]] && return 0
    done
    return 1
}

# m_pick_dest [当前值]
# 返回值写入全局 DEST_SERVER
m_pick_dest() {
    local cur="${1:-}"

    # 已经配置过就直接沿用 —— 这正是 cur 参数**本来该有**的作用。
    #
    # 之前 cur 只被赋值、从未被读, 于是每次批量生成都重新问一遍 dest; 而调用点
    # (src/conf/all.sh) 又把它的输出重定向到 /dev/null, 两者叠加的结果是:
    #   脚本在「复用已有 Reality 密钥」之后**没有任何提示地卡住等输入**,
    #   用户以为死机, 随手按一下回车 —— 那一按被当成"选第 1 个",
    #   于是 install_info.env 里选好的 dest_server 被静默改掉。
    # 实测复现: m_pick_dest "www.microsoft.com" 管道喂 "2"
    #           → dest_server 从 www.microsoft.com 变成 REALITY_DESTS[1]。
    #
    # ⚠ 本函数只设 DEST_SERVER, 而 Reality.sh 消费的是 dest_server, 两者不同名;
    #   调用方须显式同步, 否则这里的结果传不过去。
    if [[ -n "$cur" ]]; then
        local _k
        for _k in "${REALITY_DESTS[@]}"; do
            if [[ "$_k" == "$cur" ]]; then
                DEST_SERVER="$cur"
                print_info "Reality dest: $DEST_SERVER (沿用 install_info.env, 无需选择)"
                return 0
            fi
        done
        if [[ "$cur" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
            DEST_SERVER="$cur"
            print_info "Reality dest: $DEST_SERVER (沿用 install_info.env, 无需选择)"
            return 0
        fi
        print_warn "install_info.env 里的 dest_server 不合法: 「$cur」, 重新选择"
    fi

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
    # 防呆: 选定后立刻实测一次。名单里的是缓存命中(秒过), 手动输入的才真跑。
    # 这一步挡掉的正是"面板全绿、节点连不上"那类最难查的问题 ——
    # REALITY 认证失败在**服务端没有任何日志**, 客户端也只报一句
    # REALITY authentication failed, 不去实测根本发现不了。
    m_reality_dest_check "$DEST_SERVER"
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

# =============================================================
# 对外地址探测
# =============================================================
#
# 背景: 这台机器可能同时有 真实网卡 / WARP / HE-IPv6 隧道 / docker / wireguard,
# 而**只有真实网卡上的那个地址**是客户端能直连的。
#
# 实测: 一台同时装了 WARP 与 HE-IPv6 隧道的机器上, 接口有
#     eth0    203.0.113.7          <- 正解 (真实网卡)
#     he-ipv6 2001:db8:tunnel::*   <- 隧道
#     warp    172.16.0.2 / 2606:4700:...  <- WARP 出口
#     docker0 / br-* / awg0        <- 私网
# 而当时 install_info.env 里存的是 **WARP 出口地址**,
# 写进客户端配置就是 13/13 全连不上。
#
# ---------------------------------------------------------------
# 曾经的实现 (以及它的问题):
#
#   先问 api.ipify.org, 再拿回来做"在不在本机接口上"的自检。
#
#   问题是**套了 WARP 时那条查询本身就走隧道**, 拿回来的必然是 WARP 地址,
#   然后自检把它丢掉 —— 每次都要白跑一趟网络, 而且刷一堆警告。
#
#   实测那一次输出了 **10 行 [Warn]**, 而结论其实完全正确
#   (正确退回了真实网卡地址)。**逻辑对、呈现糟**。
#
# ---------------------------------------------------------------
# 现在的顺序 (合并 SB 的做法与我们的自检):
#
#   1. 传参
#   2. install_info.env 里管理员设的 PUBLIC_IP (过自检 / 或标记 VERIFIED)
#   3. **本机接口地址, 排除隧道网卡与私网**   <- SB 的做法
#   4. 外部探测 + 自检                        <- 给 NAT 后的机器兜底
#   5. 本机接口地址 (含私网)
#
#   第 3 步是关键: 绝大多数 VPS 上它直接就给出正解, **一次网络请求都不需要**,
#   也就不会出现上面那种"问了一圈、全丢掉、再退回本机"的噪音。
#   SB 的 default_server_ip_real() 正是这个思路, 注释里写得很清楚:
#   "宁可返回空, 也不要给用户一个连不通的地址"。
#
# 降噪原则: 正常路径**完全静默**; 只有"最终答案是私网地址(NAT)"这种
# 用户真的需要动手的情况, 才打警告并给修复命令。
# =============================================================

# 隧道/虚拟接口名 —— 这些接口上的地址是代理出口或隧道地址, 不能给客户端连。
# 与 SB 的 SB_TUNNEL_IFACE_RE 同源, 按本机实测补了 awg / he-ipv6 / docker / br-*。
# ⚠ he-ipv6 与 he-ipv6-tun 要分清: 前者是用户**主动配的**真实 IPv6 (HE 隧道
#   服务商给的公网地址, 对外可路由), 必须保留; 后者是隧道内层口, 不可对外。
#   写成 `he-ipv6.*` 会把 HE 的真实地址一起排掉, 于是明明有 IPv6 却判成「无」。
M_TUNNEL_IFACE_RE='^(warp|wg[0-9]*|awg[0-9]*|tun[0-9]*|tap[0-9]*|utun[0-9]*|tailscale|ts[0-9]*|ppp[0-9]*|zt[0-9]*|meta|he-ipv6-tun|sit[0-9]*|docker[0-9]*|br-[0-9a-f]+|veth.*|virbr[0-9]*)$'

# 不可路由 / 保留 / 会被内核自己占用的地址
#
# 除了常规私网, 这里额外排除几段**实战踩得到的**:
#   198.18.0.0/15  RFC 2544 基准测试段。**mihomo/Clash 默认拿 198.18.0.1/16
#                  做 fake-ip** —— 机器上跑着 TUN 时接口扫描会挑中它,
#                  那是个假地址, 客户端拿去连必然失败。(实测本机就有 eth5 198.18.0.1)
#   100.64.0.0/10  CGNAT, Tailscale 也用这段
#   192.0.2.0/24 / 198.51.100.0/24 / 203.0.113.0/24   TEST-NET, 文档示例地址
#   240.0.0.0/4    保留段
m_is_private_addr() {
    local a="$1"
    case "$a" in
        10.*|127.*|192.168.*|169.254.*|0.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        198.1[89].*|198.51.100.*|192.0.2.*|203.0.113.*) return 0 ;;
        2[4-5][0-9].*) return 0 ;;
        fc*:*|fd*:*|fe80:*|::1|2001:db8:*) return 0 ;;
    esac
    return 1
}

# 本机真实对外地址 —— 读接口, 排除隧道/虚拟网卡与私网。
# 输出第一个可用的地址 (优先 IPv4), 没有则返回 1。
m_iface_public_addr() {
    local dev cidr first6=""
    while read -r dev cidr; do
        [[ -n "$dev" && -n "$cidr" ]] || continue
        [[ "$dev" =~ $M_TUNNEL_IFACE_RE ]] && continue
        m_is_private_addr "$cidr" && continue
        case "$cidr" in
            *:*) [[ -z "$first6" ]] && first6="$cidr"; continue ;;   # 记住, 但 v4 优先
            *)   printf '%s' "$cidr"; return 0 ;;
        esac
    done < <(ip -o addr show scope global 2>/dev/null \
             | awk '{print $2, $4}' | sed 's|/[0-9]*$||')
    [[ -n "$first6" ]] && { printf '%s' "$first6"; return 0; }
    return 1
}

# 本机第一个全局单播地址 (含私网; 最后的兜底用)
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
# 踩过的坑: all.sh 用未校验的 m_server_ip, 13 个节点的 server
# 全被写成 WARP 出口 <WARP_EXIT_IP>, 真实 IP 是 <REAL_SERVER_IP>。
# 那个地址端口全不通, 客户端 13/13 全部连不上。
# 而 share.sh 的 _share_addr 早已有自检, 于是**分享地址对、节点地址错** ——
# 同一个项目两套 IP 探测逻辑, 这次把它们统一。
m_server_ip() {
    [[ -n "${1:-}" ]] && { printf '%s' "$1"; return 0; }

    # 用户选了 IPv6 且本机**确实有**真实 v6 时就用它。
    # 只有服务端能这么做 —— 客户端只知道订阅里那一个地址, 不知道服务端另一个
    # 是什么。所以在服务端选一次, 生成的客户端产物里就已经是对的那个地址。
    #
    # ⚠ m_addr6_real 只读网卡并排除隧道接口, 所以选了 WARP 的机器不会拿到
    #   WARP 地址。本机没有真实 v6 时如实回退 v4, 不给连不上的地址。
    if [[ "$(m_addr_family_get)" == "v6" ]]; then
        local _a6; _a6=$(m_addr6_real 2>/dev/null) || _a6=""
        if [[ -n "$_a6" ]]; then printf '%s' "$_a6"; return 0; fi
        print_warn "已选择 IPv6 但本机没有可用的真实 IPv6 (隧道地址已排除), 仍用 IPv4"
    fi

    # ---- 1. 内存里已加载的 ----
    if [[ -n "${PUBLIC_IP:-}" ]] && \
       { m_addr_is_local "$PUBLIC_IP" || [[ "${PUBLIC_IP_VERIFIED:-}" == "1" ]]; }; then
        printf '%s' "$PUBLIC_IP"; return 0
    fi

    # ---- 2. install_info.env 里管理员设的 ----
    # 存的旧值同样要过自检 —— 修复前的版本在这里直接返回, 于是 WARP 出口
    # 地址会被一直沿用, 自检形同虚设。
    local stale=""
    if [[ -f "${SRV_ENV:-}" ]]; then
        m_load_env "$SRV_ENV" 2>/dev/null || true
        if [[ -n "${PUBLIC_IP:-}" ]]; then
            if m_addr_is_local "$PUBLIC_IP" || [[ "${PUBLIC_IP_VERIFIED:-}" == "1" ]]; then
                printf '%s' "$PUBLIC_IP"; return 0
            fi
            stale="$PUBLIC_IP"
            unset PUBLIC_IP
        fi
    fi

    # ---- 3. 本机接口 (排除隧道/私网) —— 正解通常在这里, 且不联网 ----
    local iface
    if iface=$(m_iface_public_addr); then
        if [[ -n "$stale" ]]; then
            print_info "install_info.env 里的 PUBLIC_IP=$stale 不在本机接口上 (多半是 WARP 出口), 已改用 $iface"
        fi
        printf '%s' "$iface"; return 0
    fi

    # ---- 4. 外部探测 + 自检 (给 NAT 后的机器) ----
    local cand
    for cand in \
        "$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null)" \
        "$(curl -s6 --max-time 8 https://api64.ipify.org 2>/dev/null)"; do
        [[ -n "$cand" ]] || continue
        # 挂在本机接口上才认。多网卡/多 IP 的机器外部探测常给出另一个地址,
        # 这时宁可退回本机地址也不要写一个连不上的。
        if m_addr_is_local "$cand" && ! m_is_private_addr "$cand"; then
            [[ -n "$stale" ]] && \
                print_info "install_info.env 里的 PUBLIC_IP=$stale 不在本机接口上, 已改用 $cand"
            printf '%s' "$cand"; return 0
        fi
        # 被丢弃的候选**不逐条报警** —— 套 WARP 时这是完全正常的情况,
        # 逐条打警告会把正确结论埋掉。
    done

    # ---- 5. 兜底: 本机接口地址 (可能是私网) ----
    # 这一种用户**真的需要动手**(NAT 后客户端连不上), 才值得给完整提示。
    if cand=$(m_local_addr); then
        print_warn "无法确定公网地址, 暂用本机接口地址: $cand"
        [[ -n "$stale" ]] && print_info "  (install_info.env 里的 $stale 不在本机接口上, 已忽略)"
        print_warn "若本机在 NAT 后面, 客户端会连不上 —— 确认后手动设置:"
        print_warn "  python3 src/lib/envtool.py set install_info.env PUBLIC_IP <真实IP>"
        printf '%s' "$cand"; return 0
    fi

    print_error "无法确定对外地址, 且本机没有全局单播地址"
    print_error "请手动设置:  python3 src/lib/envtool.py set install_info.env PUBLIC_IP <真实IP>"
    return 1
}

# m_sync_reload —— 校验通过才重载; 失败保留旧配置
# ---------- 绑定核对: 配置校验通过 ≠ 端口真的绑上了 ----------
#
# mihomo 的 SAFE_PATHS 只允许读工作目录内的证书; 片段引用 /etc/letsencrypt 下的
# 证书时 `mihomo -t` **照样通过** —— 它只验语法, 真正 bind 的那一刻才报
# "parse certificate failed", 而那个 error 只进日志。实测在生产机上: 22 个
# listener 只绑上 9 个, 面板显示"成功 N · 失败 0", 用户拿到一批连不上的节点。
#
# 这不是证书独有的: 端口冲突、协议不被内核支持, 都是同一个形状。所以不针对
# 具体原因, 直接核对"片段里写的端口, 重载后到底有没有在监听", 并把内核的真实
# listen err 翻出来 —— 别让用户自己去翻 journal。
#
# 放在 m_sync_reload 里而不是各协议脚本里: 新增/删除/重建/批量全都走这一个出口,
# 放这里才谈得上"不会再犯"。
m_verify_bound() {
    local f p bad=0 tot=0 dump
    # ★ 必须给内核一点时间把监听绑完。`systemctl restart` 返回只代表**进程
    #   起来了**, listener 是异步绑的 —— 紧接着查 ss 会看到"一个都没绑上",
    #   于是报 "22 个节点的端口没有绑上"。实测生产机上就这么误报过一次,
    #   隔 20 秒再查, 实际 22/22 全在监听。
    #   误报比不报更糟: 用户会以为整批节点都废了, 实际一个都没问题。
    local waited=0
    while :; do
        bad=0
        dump=$(ss -tuln 2>/dev/null)
        shopt -s nullglob
        for f in "$SRV_CONFIGD"/*.yaml; do
            p=$(grep -m1 -oE "port:[[:space:]]*[0-9]+" "$f" 2>/dev/null | grep -oE "[0-9]+")
            [[ -n "$p" ]] || continue
            grep -qE "[:.]${p}[[:space:]]" <<< "$dump" || bad=$((bad + 1))
        done
        shopt -u nullglob
        # 全绑上了, 或者已经等够了还没绑上 —— 后者是真问题
        (( bad == 0 )) && break
        (( waited >= 8 )) && break
        sleep 1; waited=$((waited + 1))
    done
    [[ -n "$dump" ]] || return 0
    local -a badlist=()
    shopt -s nullglob
    for f in "$SRV_CONFIGD"/*.yaml; do
        p=$(grep -m1 -oE "port:[[:space:]]*[0-9]+" "$f" 2>/dev/null | grep -oE "[0-9]+")
        [[ -n "$p" ]] || continue
        tot=$((tot + 1))
        grep -qE "[:.]${p}[[:space:]]" <<< "$dump" || badlist+=("$(basename "$f" .yaml):$p")
    done
    shopt -u nullglob
    (( bad == 0 )) && return 0

    print_error "${bad} 个节点的端口没有绑上 (共 $tot 个): ${badlist[*]}"
    # 把内核真实报错翻出来, 这是唯一能说清原因的地方。
    #
    # ⚠ **不能在这里再起一个 mihomo** —— 服务正占着那些端口, 第二个实例必然
    #   满屏 "bind: address already in use", 把真正的错误 (比如证书
    #   SAFE_PATHS) 挤掉。之前就是这么把自己绕进去的: 明明是证书路径问题,
    #   输出里却全是端口冲突, 差点照着错的方向查。
    # 服务在跑就直接读它自己的日志; 没在跑才自己跑一个。
    local err=""
    if systemctl is-active --quiet "${SRV_SERVICE:-mihomo}" 2>/dev/null; then
        err=$(journalctl -u "${SRV_SERVICE:-mihomo}" -n 60 --no-pager 2>/dev/null \
              | grep -iE "listen err" | tail -2)
        [[ -n "$err" ]] || err=$(timeout 12 "${MIHOMO_BIN:-$SRV_ROOT/mihomo}" -t -d "$SRV_CONF" 2>&1 \
              | grep -iE "listen err" | tail -2)
    else
        err=$(timeout 12 "${MIHOMO_BIN:-$SRV_ROOT/mihomo}" -d "$SRV_CONF" 2>&1 | grep -m2 -iE "listen err")
    fi
    [[ -n "$err" ]] && printf "  ${DIM}%s${RESET}\n" "$err"
    print_warn "这些节点会出现在订阅里, 但连不上 —— bind 失败只写进内核日志, 面板分辨不出来"
    return 1
}

m_sync_reload() {
    local bak; bak=$(mktemp)
    [ -f "$SRV_CONF/config.yaml" ] && cp -f "$SRV_CONF/config.yaml" "$bak"

    if m_sync quiet; then
        if systemctl reload "$SRV_SERVICE" 2>/dev/null && \
           systemctl is-active --quiet "$SRV_SERVICE"; then
            [[ -n "${1:-}" ]] || print_ok "已重载服务"
            rm -f "$bak"; m_verify_bound; return 0
        fi
        if systemctl restart "$SRV_SERVICE" 2>/dev/null; then
            [[ -n "${1:-}" ]] || print_ok "已重启服务"
            rm -f "$bak"; m_verify_bound; return 0
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
# =============================================================
# 证书体系 (扫描 / 识别 / 生成 / 钉扎 / 回收)
#
# 协议脚本都 source 本文件, 在这里带入 cert.sh, 于是它们不再需要各自
# 定义 generate_cert/ask_cert/scan_certs —— 那些副本已删除。
# 放在文件末尾: cert.sh 依赖 ui.sh 的 print_*/safe_read, 而 ui.sh 由
# 本文件前部引入。
# =============================================================
# shellcheck source=/dev/null
[[ -f "$(dirname "${BASH_SOURCE[0]}")/cert.sh" ]] && source "$(dirname "${BASH_SOURCE[0]}")/cert.sh"

# =============================================================
# 推荐配置预置 + CDN 回源编排
#
# 同样放在 env.sh 里带入, 原因与 cert.sh 一样: 所有协议脚本都 source
# 本文件, 它们需要 preset_ask (选推荐配置) 和 cdn_bind_menu (挂 CDN)。
# 只在 server.sh/client.sh 里 source 的话**协议脚本拿不到** ——
# 曾这样接过一次, 实测 declare -F 显示 preset_count/cdn_* 未定义。
#
# 顺序有依赖:
#   cert.sh   仅依赖 ui.sh
#   preset.sh 仅依赖 ui.sh
#   cdn.sh    依赖 cert.sh (用 CERT_DOMAIN) 和 ui.sh, 所以必须排最后
# =============================================================
_m_libdir="$(dirname "${BASH_SOURCE[0]}")"

# smux 档位是否真的开着。
# ⚠ 预设表里 "off" 是合法档位名, 只判空会把 off 当成已启用 —— 统一收口到这里,
#   不要各处自行判空。
_smux_on() {
    local v="${1-}"
    [[ -n "$v" && "$v" != "off" && "$v" != "none" && "$v" != "false" ]]
}


# shellcheck source=/dev/null
[[ -f "$_m_libdir/preset.sh" ]] && source "$_m_libdir/preset.sh"
# shellcheck source=/dev/null
[[ -f "$_m_libdir/cdn.sh" ]]    && source "$_m_libdir/cdn.sh"
# DNS 管理 (服务端)。只定义函数, 不依赖上面几个, 放最后避免引入顺序耦合。
# shellcheck source=/dev/null
[[ -f "$_m_libdir/dns.sh" ]]    && source "$_m_libdir/dns.sh"
# 服务端「出站 / 规则集 / 端口转发」。只定义函数, 不在 source 时做任何 IO,
# 放最后 —— 里面的辅助函数 (_extra_*) 名字已加前缀, 不与其它 lib 撞名。
# shellcheck source=/dev/null
[[ -f "$_m_libdir/server_extra.sh" ]] && source "$_m_libdir/server_extra.sh"


# 删除某个节点的客户端产物 —— 删节点路径共用。
#
# ★ 产物命名有**两套**, 删除必须都覆盖:
#     单协议菜单  → out/<proto>_client-NN.yaml
#     批量 all.sh → out/<mproto>_<proto>_client-NN.yaml
#   (前缀不是冗余: all.sh 的 vless 有 vless / vless-ws / xhttp 多个变体,
#    都叫 vless_client-01.yaml 时后者会覆盖前者, 分享订阅就少一个节点 ——
#    all.sh 里留了这条注释。)
#   删除路径原来只删第一套, 于是**批量生成的节点被删掉后, out/ 里留下一份
#   孤儿产物**, 而它照样被 build_sub.py 收集进订阅 —— 分享出去的链接里
#   继续有这个"已经删掉的"节点。实测: 删 config.d/trojan-01.yaml 时,
#   out/trojan_trojan_client-01.yaml 纹丝不动。
#
# 返回实际删掉的文件数 (供调用方提示)。
m_out_rm_artifacts() { # <proto> <两位编号>
    local proto="${1:-}" idx="${2:-}" f n=0
    [[ -n "$proto" && -n "$idx" ]] || { printf '0'; return 0; }
    for f in "$SRV_OUT/${proto}_client-${idx}.yaml" \
             "$SRV_OUT/${proto}_share-${idx}.txt" \
             "$SRV_OUT/${proto}_"*"_client-${idx}.yaml" \
             "$SRV_OUT/${proto}_"*"_share-${idx}.txt"; do
        [[ -f "$f" ]] || continue
        rm -f "$f" 2>/dev/null
        # 回读确认: 没删掉就不计数 (也顺便让重叠的 glob 不会重复计数)
        [[ -f "$f" ]] && continue
        n=$((n + 1))
    done
    printf '%s' "$n"
    return 0
}

# =============================================================
# 分享 (share.sh)
#
# 也在这里带入。原来只在 server.sh 的 install_share() 里 source, 于是
# **协议脚本拿不到 share_* 函数** —— 删节点时想吊销对应分享链接就调不到。
# share.sh 加载期只做变量赋值和函数定义 (带 declare -F 守卫), 没有副作用,
# 可以安全地全局带入。它依赖 SHARE_DIR, 而 SHARE_DIR 在本文件前部已定义。
# =============================================================
if [[ -f "$_m_libdir/../share/share.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_m_libdir/../share/share.sh"
fi

# ---------- 内核能力探测 ----------
#
# 同一个脚本在不同机器上可能跑在不同内核版本上, 而**协议支持是随版本变的**:
# snell 的 outbound 在 v1.19.24 上是 "unsupport proxy type: snell",
# 到 v1.19.32 才支持。原先批量清单写死, 于是每一步都报"成功", 生成完 22 个
# 节点, 合并出的配置最后被内核整体拒绝 —— 用户看到的是"成功 22 · 失败 0"
# 紧跟着一行校验失败和回滚, 两句话互相矛盾。
#
# 探测办法: 把候选类型塞进一个最小配置跑一次 `mihomo -t`, 它会把不支持的那个
# 类型名报出来 (proxy N: unsupport proxy type: XXX), 去掉再来, 直到干净。
# 通常 1~2 次就收敛, 比逐个类型试 20 多次便宜得多。
#
# 结果缓存到文件: 探测要起内核, 不该每批都做。
_M_PROBE_SNIPPET_vless='    {name: p, type: vless, server: 127.0.0.1, port: 1, uuid: 00000000-0000-0000-0000-000000000000}'
_M_PROBE_SNIPPET_trojan='    {name: p, type: trojan, server: 127.0.0.1, port: 1, password: p}'
_M_PROBE_SNIPPET_vmess='    {name: p, type: vmess, server: 127.0.0.1, port: 1, uuid: 00000000-0000-0000-0000-000000000000, cipher: auto}'
_M_PROBE_SNIPPET_hysteria2='    {name: p, type: hysteria2, server: 127.0.0.1, port: 1, password: p}'
_M_PROBE_SNIPPET_tuic='    {name: p, type: tuic, server: 127.0.0.1, port: 1, uuid: 00000000-0000-0000-0000-000000000000, password: p}'
_M_PROBE_SNIPPET_anytls='    {name: p, type: anytls, server: 127.0.0.1, port: 1, password: p}'
_M_PROBE_SNIPPET_ss='    {name: p, type: ss, server: 127.0.0.1, port: 1, cipher: aes-128-gcm, password: p}'
_M_PROBE_SNIPPET_snell='    {name: p, type: snell, server: 127.0.0.1, port: 1, psk: p, version: "3"}'

# 探测用哪份内核: 显式指定的 MIHOMO_BIN 最权威 (all.sh 里它一定有值),
# 其次 SRV_ROOT, 都没有才用默认安装目录。
#
# 两个入口必须走同一个解析 —— 之前 m_kernel_supports 跟 MIHOMO_BIN 而
# m_kernel_unsupported_types 写死默认目录, 于是"探测的是 A 内核、判断用的是
# B 内核", 表现为桩程序完全不生效、探测结果永远对不上被测的那份内核。
#
# ⚠ MIHOMO_BIN 要优先于 SRV_ROOT: 库文件被单独 source 时 SRV_ROOT 也带默认值,
# 顺序反了就拿着与实际内核无关的目录去探测。
_m_kernel_root() {
    if [[ -n "${MIHOMO_BIN:-}" ]]; then printf '%s' "$(dirname "$MIHOMO_BIN")"
    elif [[ -n "${SRV_ROOT:-}" ]]; then printf '%s' "$SRV_ROOT"
    else printf '%s' "/root/catmi/mihomo"; fi
}

m_kernel_unsupported_types() {
    # ⚠ 必须分成两条 local: bash 会**先把整条命令行展开完再执行 local**,
    #   写成 local root=... bin="$root/mihomo" 时, bin 拿到的是外层的空值,
    #   于是 bin=/mihomo, [[ -x ]] 判否, 函数直接 return —— 探测静默失效,
    #   表现为"永远都支持"。
    local root="${1:-/root/catmi/mihomo}"
    local bin="$root/mihomo"
    local cf="$root/.kernel-unsupported"
    [[ -x "$bin" ]] || return 0
    # 换内核版本后缓存要失效, 所以把版本一起记进去
    local ver; ver=$("$bin" -v 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
    if [[ -f "$cf" ]]; then
        local cv; cv=$(head -1 "$cf" 2>/dev/null)
        [[ "$cv" == "ver=$ver" ]] && { tail -n +2 "$cf" 2>/dev/null; return 0; }
    fi

    local -a want=(vless trojan vmess hysteria2 tuic anytls ss snell)
    local t body out bad i
    local tmp; tmp=$(mktemp -d 2>/dev/null) || return 0
    trap 'rm -rf "$tmp"' RETURN

    for (( i = 0; i < 6; i++ )); do
        body=""
        for t in "${want[@]}"; do
            local snip_var="_M_PROBE_SNIPPET_$t"
            body+="${!snip_var}"$'\n'
        done
        printf 'proxies:\n%s' "$body" > "$tmp/config.yaml"
        out=$("$bin" -t -d "$tmp" 2>&1)
        bad=$(printf '%s' "$out" | grep -oE 'unsupport(ed)? proxy type: [a-z0-9]+' | head -1 | awk '{print $NF}')
        [[ -n "$bad" ]] || break
        local keep=() k
        for k in "${want[@]}"; do [[ "$k" == "$bad" ]] || keep+=("$k"); done
        want=("${keep[@]}")
    done

    local -a missing=()
    for t in vless trojan vmess hysteria2 tuic anytls ss snell; do
        printf '%s\n' "${want[@]}" | grep -qxF "$t" || missing+=("$t")
    done
    { printf 'ver=%s\n' "$ver"; (( ${#missing[@]} )) && printf '%s\n' "${missing[@]}"; } > "$cf" 2>/dev/null
    (( ${#missing[@]} )) && printf '%s\n' "${missing[@]}"
    return 0
}

# 该类型是否被当前内核支持。
#
# root 缺省**跟着实际用的内核走** (dirname MIHOMO_BIN), 不用写死
# /root/catmi/mihomo —— 否则把内核装在别处 (测试目录、备用内核) 时,
# 探测会去找一个不存在的路径, 直接 return, 于是"永远都支持",
# 比没有这个机制更糟: 它会让用户以为已经检查过了。
m_kernel_supports() {
    local t="$1"
    local root="${2:-$(_m_kernel_root)}"
    ! m_kernel_unsupported_types "$root" | grep -qxF "$t"
}

# ---------- 客户端产物: 改了设置要能落到已有文件上 ----------
#
# 原来这两个设置只写状态文件, 并注明"只影响之后新生成的节点"。于是想换一套
# 指纹 / 换个地址族, 就得把全部节点重新生成一遍 —— 端口和凭据全变, 已经
# 发出去的分享链接全部失效。指纹和地址都是**纯客户端表现层**的字段, 改它们
# 不影响服务端任何行为, 所以直接重写产物就够了。
#
# ★ 只碰 $SRV_OUT 下的产物, **绝不碰 conf/config.d/** —— 服务端配置里
#   的监听地址、凭据与客户端产物无关, 改错了等于把服务改坏。

# 把产物里的 client-fingerprint 统一改成 <fp>, 并重写分享链接的 fp= 参数。
m_artifacts_apply_fp() { # <指纹> [1=不交互]
    local fp="${1:-}" n=0 f
    [[ -n "$fp" ]] || return 1
    shopt -s nullglob
    for f in "$SRV_OUT"/*_client-*.yaml; do
        grep -q 'client-fingerprint:' "$f" 2>/dev/null || continue
        sed -i -E "s/^([[:space:]]*client-fingerprint:[[:space:]]*).*/\1$fp/" "$f" 2>/dev/null || continue
        n=$((n + 1))
    done
    for f in "$SRV_OUT"/*_share-*.txt; do
        grep -q 'fp=' "$f" 2>/dev/null || continue
        sed -i -E "s/([?&])fp=[^&]*/\1fp=$fp/g" "$f" 2>/dev/null || continue
        n=$((n + 1))
    done
    shopt -u nullglob
    printf '%s' "$n"
}

# 把产物里的 server: / 分享链接的 @host:port 统一换成 <ip>。
#
# CDN 节点例外: 它们连的是 Cloudflare 边缘域名而不是源站 IP, 换地址族不该
# 动它们 —— 改了反而连不上。所以只改当前确实等于旧地址的那些。
m_artifacts_apply_addr() { # <新IP> <旧IP> [1=不交互]
    local new="${1:-}" old="${2:-}" n=0 f
    [[ -n "$new" && -n "$old" ]] || return 1
    [[ "$new" != "$old" ]] || { printf '0'; return 0; }
    shopt -s nullglob
    for f in "$SRV_OUT"/*_client-*.yaml; do
        grep -qE "^[[:space:]]*server:[[:space:]]*${old//./\\.}[[:space:]]*$" "$f" 2>/dev/null || continue
        sed -i -E "s/^([[:space:]]*server:[[:space:]]*)${old//./\\.}$/\1$new/" "$f" 2>/dev/null || continue
        n=$((n + 1))
    done
    # 分享链接: vless://uuid@host:port?  -> 只换 @ 后面的 host, 端口不动
    #
    # ★ IPv6 必须写成 [addr]: 写成 vless://uuid@2001:db8::1:443 的话, 冒号
    #   与端口的冒号混在一起, 客户端根本解析不出主机地址。share.sh 里的
    #   _share_host() 本来就管这件事, 这里必须用同一套规则 ——
    #   另写一份就是第二个真源, 迟早漂移。
    local newh
    if declare -F _share_host >/dev/null 2>&1; then
        newh=$(_share_host "$new")
    else
        case "$new" in *:*) newh="[$new]" ;; *) newh="$new" ;; esac
    fi
    local ore; ore=${old//./\\.}
    for f in "$SRV_OUT"/*_share-*.txt; do
        grep -qE "@${ore}([:?][0-9]*)?" "$f" 2>/dev/null || continue
        sed -i -E "s/@${ore}([:?])/@${newh}\\1/g" "$f" 2>/dev/null || continue
        n=$((n + 1))
    done
    shopt -u nullglob
    printf '%s' "$n"
}

# 清理孤儿产物 —— out/ 里已经找不到对应节点的客户端产物。
#
# 这些文件的来历: 节点删了, 但产物没跟着删 (批量清空那会儿就漏了, 上一版才
# 补上)。单个删节点走的是 m_out_rm_artifacts, 正常情况下不会留下孤儿, 所以
# 积下来的基本都是历史批量留下的。
#
# 为什么不能靠文件名猜: 产物叫 `<协议>_<变体>_client-<编号>.yaml`, 而节点片段
# 叫 `<协议>-<编号>.yaml` —— 变体部分 (cdn-v-grpc / reality / tls…) 不参与
# 对应。所以按 "<协议> + 编号" 反查片段, 抽不出来就是孤儿。
#
# ★ 只删**确实没有对应片段**的产物。宁可少删: 误删一个还在用的产物, 用户
#   要重新生成才能拿回来; 留下一个孤儿只是下次还能再清一次。
m_artifacts_clean_orphan() { # [1=只报告不删]
    local dry="${1:-}" n=0 del=0 f b m i
    shopt -s nullglob
    for f in "$SRV_OUT"/*_client-*.yaml; do
        b=$(basename "$f")
        m="${b%%_*}"                                  # <协议>
        i="${b##*_client-}"; i="${i%.yaml}"          # <编号>
        [[ -n "$m" && -n "$i" ]] || continue
        [[ -f "$SRV_CONFIGD/$m-$i.yaml" ]] && continue # 节点还在, 保留
        n=$((n + 1))
        [[ "$dry" == "1" ]] && continue
        rm -f "$f" 2>/dev/null || continue
        [[ -f "$f" ]] && continue
        del=$((del + 1))
        # 分享链接是同一节点的另两份产物, 一并清掉 —— 留着等于发一个连不上的链接
        for g in "$SRV_OUT/$m"_*"_share-$i.txt" "$SRV_OUT/$m"_share-$i.txt; do
            [[ -f "$g" ]] && rm -f "$g" 2>/dev/null
        done
    done
    shopt -u nullglob
    printf '%s %s' "$n" "$del"
}
