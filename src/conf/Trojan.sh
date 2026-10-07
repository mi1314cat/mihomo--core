#!/bin/bash

# 拼分享链接时给 IPv6 套方括号 (env.sh 的 m_uri_host 局部别名)
_uri_h() { m_uri_host "$1"; }

# ================================
# 彩色定义
# ================================
RED="\e[31m"
# UI 原语统一来自 src/lib/ui.sh (颜色/消息分级/标题), 此处不再重复定义。
# 被父级 source 时已加载; 单独运行时由下面的兜底 source 补上。

# ================================
# 基础路径
# ================================
PROTO="trojan"
# 根目录解析。
#
# 这里原来是裸的 BASE_DIR="/root/catmi/mihomo" —— 硬编码的生产路径, 而后面
# 又用 SRV_ROOT="$BASE_DIR" 把它盖回去。两个后果:
#   1) 面板装在别处时, 直接运行本脚本 (末尾有裸 main_menu, 本来就支持单独跑)
#      会去读写 /root/catmi/mihomo, 而不是自己的安装目录;
#   2) **测试时只传 SRV_ROOT 是无效的** —— BASE_DIR 会把它改回来, 于是
#      "在临时目录里跑测试"实际动的是真实部署。实测踩过: 一次 delete_config
#      测试删掉了真实 conf/config.d/trojan-01.yaml。
# 现在按 环境变量 → 脚本自身位置 (src/conf/<x>.sh 的上两级) → 默认路径 依次解析,
# 与 server.sh 的 SRV_ROOT="${SRV_ROOT:-...}" 保持同一套语义。
if [[ -z "${BASE_DIR:-}" ]]; then
    if [[ -n "${SRV_ROOT:-}" ]]; then
        BASE_DIR="$SRV_ROOT"
    else
        _bd="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
        if [[ -n "$_bd" && -d "$_bd/src/lib" ]]; then BASE_DIR="$_bd"; else BASE_DIR="/root/catmi/mihomo"; fi
        unset _bd
    fi
fi
CONF_DIR="$BASE_DIR/conf/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$BASE_DIR/conf/certs"
PUB_DIR="$OUT_DIR/pub"


# ---------- 共享库 (src/lib/env.sh) ----------
# 提供: 路径常量 / 环境变量读写 / Reality dest 选择 / 合并+严格校验+重载闭环
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRV_ROOT="$BASE_DIR"
MIHOMO_BIN="$BASE_DIR/mihomo"
source "$SELF_DIR/../lib/env.sh"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR" "$PUB_DIR"

# ================================
# 统一域名优选 (与 Reality.sh 相同调用方式)
# 本地不维护域名池, 不复制 random_website, 不下载到本地文件:
#   直接按 Reality.sh 的方式执行统一 domains.sh:
#     bash <(curl -fsSL "$DOMAINS_URL")
#   domains.sh 内部: 留空 -> random_website() 现场优选,
#   结果经 update_env 持久化为 install_info.env 的 dest_server;
#   此处仅负责执行并从该 env 回读域名.
# 接口: auto_website 成功时 stdout 输出一个域名(仅一个),
#       进度/诊断均走 stderr; 失败返回非 0.
# domains.sh 更新后此处无需改动.
# ================================
# 实现已挪到 src/lib/env.sh 的 m_auto_website —— Trojan 与 Reality.sh
# 必须走**同一个**域名源 (用户在 One-click-script/domains.sh 里统一维护),
# 两边各留一份实现迟早会漂移。
auto_website() { m_auto_website; }

# ================================
# 输入清理
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

# ================================
# 自动编号
# ================================
get_next_index() {
    local used=() i=1
    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.yaml; do
        local base
        base=$(basename "$f")
        if [[ "$base" =~ ^$PROTO-([0-9]{2})\.yaml$ ]]; then
            used+=("${BASH_REMATCH[1]}")
        fi
    done
    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done
    printf "%02d\n" "$i"
}

# ================================
# 随机端口
# ================================
# 端口区间须与 all.sh 起点和状态栏统计口径一致, 否则手工建的节点落在
#   统计区间外, 面板「运行中的协议端口」少报。
random_port() { shuf -i 20000-29999 -n 1; }

# 随机十六进制片段 —— 用于 ws 路径 / grpc 服务名。
# 只出 [0-9a-f], 保证拼进分享链接 URI 时不需要 urlencode。
random_token() { openssl rand -hex "${1:-8}"; }

safe_read_port() {
    # 六份重复实现已收敛到 env.sh 的 m_safe_read_port:
    #   拒绝 1-1023 特权端口与系统常用端口, TCP/UDP 双查占用, EOF 安全退出。
    m_safe_read_port "$1"
}

# ================================
# 自动生成自签证书（兜底用）
# ================================

# ================================
# smux 档位集中定义 (web/video/download)
# 语义已按 sing-mux v0.3.10 源码核实 (client.go offer 逻辑):
#   max-connections: 物理连接数上限
#   min-streams: 新建连接的流数门槛 (活跃流数<此值时复用,不新建)
#   max-streams: 单连接流数容量 (max-connections>0 时不参与连接决策)
# ================================
smux_profile() {
    # $1 = web|video|download ; 输出 "max-connections min-streams max-streams"
    case "$1" in
        video)    echo "2 2 16" ;;
        download) echo "4 4 64" ;;
        *)        echo "1 1 32" ;; # web (默认)
    esac
}

# ================================================================
# 传输相关标记的读取与渲染
#
#   proxy   (adapter/outbound/trojan.go)
#     network: ws|grpc|不写/其它 => default 分支 = 裸 TCP+TLS (:79, :148-150, :211-213)
#       ws   : ws-opts{path, headers{Host}, v2ray-http-upgrade(-fast-open)}  (:66)
#       grpc : grpc-opts{grpc-service-name}                                  (:65)
#   listener (listener/inbound/trojan.go)
#     【没有 network 字段】靠平铺键判定, 非空即生效 (listener/trojan/server.go:163, :177)
#       ws   : ws-path: /xxx
#       grpc : grpc-service-name: xxx
#     两个键可同时非空 -> 同一个 listener 同时提供 ws 与 grpc (server.go:163-197)
# ================================================================
render_listener_transport() {
    LISTENER_TRANSPORT=""
    case "$TROJAN_TRANSPORT" in
        ws)   LISTENER_TRANSPORT="    ws-path: $WS_PATH" ;;
        grpc) LISTENER_TRANSPORT="    grpc-service-name: $GRPC_SERVICE" ;;
    esac
}

# 渲染客户端 proxy 的传输层块（输出到 LISTENER_TRANSPORT 对应的 TRANSPORT_BLOCK）
render_proxy_transport() {
    local upgrade=""
    TRANSPORT_BLOCK=""
    # v2ray-http-upgrade / -fast-open 只有 proxy 侧有 (adapter/outbound/trojan.go:93-94
    # 读 WSOpts, 结构定义 adapter/outbound/vmess.go:170-171); listener 侧无对应项,
    # 只写 ws-path。而且 fast-open 必须配合 upgrade, 单独写无效, 所以两块一起出。
    [[ "$WS_HTTP_UPGRADE" = true ]] && upgrade="      v2ray-http-upgrade: true
      v2ray-http-upgrade-fast-open: true"
    case "$TROJAN_TRANSPORT" in
        ws)
            TRANSPORT_BLOCK="    network: ws
    ws-opts:
      path: $WS_PATH
      headers:
        Host: $WS_HOST
$upgrade"
            ;;
        grpc)
            TRANSPORT_BLOCK="    network: grpc
    grpc-opts:
      grpc-service-name: $GRPC_SERVICE"
            ;;
        *)
            TRANSPORT_BLOCK="    network: tcp"
            ;;
    esac
}

# 渲染分享链接 (trojan:// URI)
# 传输参数沿用 VLESS.sh 的同款约定 (VLESS.sh:810-812):
#   tcp : type=tcp
#   ws  : type=ws&path=<ws-path>&host=<ws Host 头>
#   grpc: type=grpc&serviceName=<grpc-service-name>
# fp 跟实际选的 client-fingerprint 走, 不再硬编码 chrome。
render_share_link() {
    local idx="$1" transport_uri="type=tcp"
    case "$TROJAN_TRANSPORT" in
        ws)   transport_uri="type=ws&path=$WS_PATH&host=$WS_HOST" ;;
        grpc) transport_uri="type=grpc&serviceName=$GRPC_SERVICE" ;;
    esac
    # 显示名与 listener / client yaml 同源 (m_node_tag)。
    # 以前是 "Trojan-$idx", 两个形态的节点在客户端里名字一模一样,
    # 分不出哪个是 Reality 哪个是 TLS。
    local tag
    if [[ "$TROJAN_MODE" = "reality" ]]; then
        tag="$(m_node_tag Trojan "$idx" reality)"
        echo "trojan://$PASSWORD@$(_uri_h "$LINK_IP"):$TROJAN_PORT?security=reality&sni=$REALITY_DEST&$transport_uri&fp=$CLIENT_FINGERPRINT&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID#$tag"
    else
        tag="$(m_node_tag Trojan "$idx" tls)"
        echo "trojan://$PASSWORD@$(_uri_h "$LINK_IP"):$TROJAN_PORT?security=tls&sni=$CERT_DOMAIN&$transport_uri&fp=$CLIENT_FINGERPRINT#$tag"
    fi
}

# ================================================================
# client-fingerprint 选配
# 取值表 component/tls/utls.go:78-101。这里只暴露仍在维护的 7 个,
# 【不暴露】utls.go:94-99 注释标 deprecated 的 5 个 (chrome_psk /
# chrome_psk_shuffle / chrome_padding_psk_shuffle / chrome_pq / chrome_pq_psk),
# 也不暴露 randomized (:100, :108 每次启动重播种, 指纹会漂)。
#
# 两种模式都要问:
#   Reality —— 【硬约束】缺 client-fingerprint 会在首次握手直接报
#              "REALITY is based on uTLS, please set a client-fingerprint"
#              (transport/vmess/tls.go:130-132), 而且 -t 校验抓不到 (§3.4 运行期才报错)
#   纯 TLS  —— 不配则走原生 Go TLS (utls.go:43-45), JA3 指纹直接暴露
# ================================================================
ask_client_fingerprint() {
    local yn
    echo "  TLS ClientHello 指纹 (client-fingerprint):" >&2
    echo "  1) chrome   (默认, 兼容面最广)" >&2
    echo "  2) firefox" >&2
    echo "  3) safari" >&2
    echo "  4) edge" >&2
    echo "  5) ios" >&2
    echo "  6) android" >&2
    echo "  7) random   (内核加权: chrome6/safari3/ios2/firefox1, utls.go:62-68)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) CLIENT_FINGERPRINT="firefox" ;;
        3) CLIENT_FINGERPRINT="safari" ;;
        4) CLIENT_FINGERPRINT="edge" ;;
        5) CLIENT_FINGERPRINT="ios" ;;
        6) CLIENT_FINGERPRINT="android" ;;
        7) CLIENT_FINGERPRINT="random" ;;
        *) CLIENT_FINGERPRINT="$(m_fp_get)" ;;
    esac
}

# skip-cert-verify: 纯 TLS 分支的 proxy 侧字段 (adapter/outbound/trojan.go:53)。
# 默认 true —— 保持脚本既有行为(自签 / 免费证书 / 域名对不上都能连)。
# 选严格校验后, 证书身份必须与 sni 匹配, 否则是【首次握手】才失败, -t 抓不到 (§3.4)。
ask_skip_cert_verify() {
    local yn
    SKIP_CERT_VERIFY=true
    printf "  跳过服务端证书校验 (自签/域名不符也能连)？(Y/n): " >&2
    read -r yn
    [[ "$(clean_input "$yn")" =~ ^[nN]$ ]] && SKIP_CERT_VERIFY=false
}

# ================================================================
# 传输方式提问
# Reality 与 ws/grpc 的兼容性 —— 源码结论 (mihomo 1.19.32):
#
#   Reality + ws  = 【内核不支持, 必须挡掉】
#     adapter/outbound/trojan.go:79-147 的 ws 分支构造 TLS 时只处理
#     ShadowTLS / Restls / JLS (:121-123), 另一条 ca.GetTLSConfig 分支 (:129-144)
#     也没有 Reality 字段 —— realityConfig 在整个 ws 分支里一次都没被传进去。
#     结果: reality-opts 被【静默丢弃】, 客户端退回普通 wss, 对着 Reality
#     listener 握手必失败, 而且 -t 校验照样通过。
#
#   Reality + grpc = 【内核是接通的, 放开但提示】
#     客户端: trojan.go:360-393 建 gun client 时 tlsConfig 里带了
#             Reality: t.realityConfig (:382) —— 与 ws 分支形成对照。
#     服务端: listener/trojan/server.go:211-212 把 reality listener 套在底层 l 上,
#             随后 :203-206 直接 httpServer.Serve(l), 且 :186-189 的注释点名
#             "some tls conn is not *tls.Conn (like *reality.Conn)" 并为此
#             SetUnencryptedHTTP2(true) —— 就是为 reality+grpc 准备的。
#     仍保留提示: 依赖较新的内核, 连不通请改回 tcp。
# ================================================================
ask_transport() {
    local yn
    TROJAN_TRANSPORT="tcp"
    WS_PATH=""
    WS_HOST=""
    WS_HTTP_UPGRADE=false
    GRPC_SERVICE=""

    if [[ "$TROJAN_MODE" = "reality" ]]; then
        echo "  传输方式 (Reality):" >&2
        echo "  1) tcp  (默认)" >&2
        echo "  2) grpc (内核已接通 reality+grpc; 连不通请改回 1)" >&2
        printf "  选择 (默认1): " >&2
        read -r yn
        case "$(clean_input "$yn")" in
            2) TROJAN_TRANSPORT="grpc" ;;
            *) TROJAN_TRANSPORT="tcp" ;;
        esac
        [[ "$TROJAN_TRANSPORT" = "grpc" ]] && \
            print_info "Reality+grpc 依赖较新内核 (1.19.32 已验证接通), 若握手失败请改用 tcp"
    else
        echo "  传输方式 (纯 TLS):" >&2
        echo "  1) tcp  (默认, 裸 TCP+TLS)" >&2
        echo "  2) ws   (可套 CDN)" >&2
        echo "  3) grpc (h2 多路复用)" >&2
        printf "  选择 (默认1): " >&2
        read -r yn
        case "$(clean_input "$yn")" in
            2) TROJAN_TRANSPORT="ws" ;;
            3) TROJAN_TRANSPORT="grpc" ;;
            *) TROJAN_TRANSPORT="tcp" ;;
        esac
    fi

    case "$TROJAN_TRANSPORT" in
        ws)
            WS_PATH="/$(random_token 8)"
            printf "  ws 路径 (回车=随机 %s, 至少 %s 字符): " "$WS_PATH" "$M_MIN_WS_PATH_LEN" >&2
            read -r yn
            yn=$(clean_input "$yn")
            [[ -n "$yn" ]] && WS_PATH="$yn"
            if ! WS_PATH=$(m_check_ws_path "$WS_PATH"); then
                WS_PATH="/$(random_token 8)"
                print_warn "已改用随机路径: $WS_PATH"
            fi
            printf "  启用 v2ray-http-upgrade (省一次 1-RTT, 仅客户端侧生效)? (y/N): " >&2
            read -r yn
            [[ "$(clean_input "$yn")" =~ ^[yY]$ ]] && WS_HTTP_UPGRADE=true
            ;;
        grpc)
            GRPC_SERVICE="gsvc$(random_token 4)"
            printf "  grpc 服务名 (回车=随机 %s): " "$GRPC_SERVICE" >&2
            read -r yn
            yn=$(clean_input "$yn")
            [[ -n "$yn" ]] && GRPC_SERVICE="$yn"
            ;;
    esac
}

# ================================================================
# 特性询问（模式 + 传输 + 指纹 + 证书校验 + mTLS + smux）
# 选择持久化到 config.d 片的注释行:
#   # mode: tls|reality
#   # transport: tcp|ws|grpc
#   # fingerprint: <client-fingerprint>
#   # skip-cert-verify: true|false
#   # mtls: true
#   # smux: <档位>
# ================================================================
ask_features() {
    local yn
    TROJAN_MODE=""        # tls | reality
    MTLS_ENABLED=false
    SMUX_PROFILE=""

    echo "  安全模式:" >&2
    echo "  1) 纯 TLS (需域名证书, 流量形似 HTTPS)" >&2
    echo "  2) Reality (无需证书, 伪装访问真实站点)" >&2
    printf "  选择 (默认2): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        1) TROJAN_MODE="tls" ;;
        *) TROJAN_MODE="reality" ;;
    esac

    # 传输方式 (Reality 下 ws 被内核丢弃, 见 ask_transport 头注释)
    ask_transport

    # client-fingerprint: Reality 缺了会握手失败, 纯 TLS 缺了会露 JA3 —— 两边都要
    ask_client_fingerprint

    # mTLS 仅纯 TLS 模式有意义 (Reality 用真站握手, 无本端证书)
    if [[ "$TROJAN_MODE" = "tls" ]]; then
        ask_skip_cert_verify
        printf "启用 mTLS 客户端证书认证？(y/N): " >&2
        read -r yn
        [[ "$(clean_input "$yn")" =~ ^[yY]$ ]] && MTLS_ENABLED=true
    fi

    printf "启用 smux 多路复用？(y/N): " >&2
    read -r yn
    if [[ "$(clean_input "$yn")" =~ ^[yY]$ ]]; then
        echo "  smux 档位 (网页/视频/下载):" >&2
        echo "  1) 网页党 (默认: 复用最大化, 轻量)" >&2
        echo "  2) 视频党 (并行承载, 兼顾视频+网页)" >&2
        echo "  3) 下载党 (多物理连接, 高吞吐)" >&2
        printf "  选择 (默认1): " >&2
        read -r yn
        case "$(clean_input "$yn")" in
            2) SMUX_PROFILE="video" ;;
            3) SMUX_PROFILE="download" ;;
            *) SMUX_PROFILE="web" ;;
        esac
    fi
}

# 读取 config.d 片注释中的特性标记（供重建/导出时同步）
# 兼容旧格式 "# smux: true" -> 视为 web 档
# 向后兼容: 老片段只有 "# mode: tls|reality", 没有 "# transport:" / "# fingerprint:" /
# "# skip-cert-verify:" / ws-path / grpc-service-name —— 全部按历史行为回落 (tcp / chrome / true)。
read_features() {
    local f="$1"
    TROJAN_MODE=""
    MTLS_ENABLED=false
    SMUX_PROFILE=""
    TROJAN_TRANSPORT="tcp"
    CLIENT_FINGERPRINT="chrome"
    SKIP_CERT_VERIFY=true
    WS_PATH=""
    WS_HOST=""
    WS_HTTP_UPGRADE=false
    GRPC_SERVICE=""
    if grep -qE "^[[:space:]]*# mode: (tls|reality)" "$f"; then
        TROJAN_MODE=$(grep -oE "^[[:space:]]*# mode: (tls|reality)" "$f" | awk '{print $3}')
    fi
    # transport: 认新的三元组, 老片段没有就保持 tcp
    if grep -qE "^[[:space:]]*# transport: (tcp|ws|grpc)" "$f"; then
        TROJAN_TRANSPORT=$(grep -oE "^[[:space:]]*# transport: (tcp|ws|grpc)" "$f" | head -1 | awk '{print $3}')
    elif grep -qE "^[[:space:]]*ws-path: " "$f"; then
        TROJAN_TRANSPORT="ws"
    elif grep -qE "^[[:space:]]*grpc-service-name: " "$f"; then
        TROJAN_TRANSPORT="grpc"
    fi
    if grep -qE "^[[:space:]]*# fingerprint: [a-z0-9]+" "$f"; then
        CLIENT_FINGERPRINT=$(grep -oE "^[[:space:]]*# fingerprint: [a-z0-9]+" "$f" | head -1 | awk '{print $3}')
    fi
    if grep -qE "^[[:space:]]*# skip-cert-verify: false" "$f"; then
        SKIP_CERT_VERIFY=false
    fi
    grep -qE "^[[:space:]]*# ws-http-upgrade: true" "$f" && WS_HTTP_UPGRADE=true
    # 平铺键回读 (listener/inbound/trojan.go:15-16)
    WS_PATH=$(grep -oE "^[[:space:]]*ws-path:[[:space:]]*.*$" "$f" | head -1 | sed 's/^[[:space:]]*ws-path:[[:space:]]*//')
    GRPC_SERVICE=$(grep -oE "^[[:space:]]*grpc-service-name:[[:space:]]*.*$" "$f" | head -1 | sed 's/^[[:space:]]*grpc-service-name:[[:space:]]*//')
    grep -qE "^[[:space:]]*# mtls: true" "$f" && MTLS_ENABLED=true
    if grep -qE "^[[:space:]]*# smux: (web|video|download)" "$f"; then
        SMUX_PROFILE=$(grep -oE "^[[:space:]]*# smux: (web|video|download)" "$f" | awk '{print $3}')
    elif grep -qE "^[[:space:]]*# smux: true" "$f"; then
        SMUX_PROFILE="web"
    fi
}

# 渲染 smux 客户端配置块（按档位）；输出到变量 SMUX_BLOCK
render_smux() {
    SMUX_BLOCK=""
    _smux_on "${SMUX_PROFILE-}" || return
    local mc ms mn
    read -r mc mn ms <<< "$(smux_profile "$SMUX_PROFILE")"
    SMUX_BLOCK="    smux:
      enabled: true
      protocol: smux
      max-connections: $mc
      min-streams: $mn
      max-streams: $ms"
}

# ================================
# 生成节点专属 mTLS 证书（CA + 客户端证书）
# ================================
gen_mtls_cert() {
    local idx="$1"
    local dir="$CERT_DIR/mtls-$PROTO-$idx"
    mkdir -p "$dir"

    # CA（用于服务端 client-auth-cert 的签发者）
    if [[ ! -f "$dir/ca.pem" ]]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout "$dir/ca.key" -out "$dir/ca.pem" -days 3650 \
            -subj "/CN=mihomo-mtls-ca-$idx" >/dev/null 2>&1
    fi
    # 客户端证书
    if [[ ! -f "$dir/client.pem" || ! -f "$dir/client.key" ]]; then
        openssl req -newkey rsa:2048 -nodes \
            -keyout "$dir/client.key" -out "$dir/client.csr" \
            -subj "/CN=trojan-client-$idx" >/dev/null 2>&1
        printf "extendedKeyUsage = clientAuth\nbasicConstraints = CA:FALSE\nkeyUsage = digitalSignature, keyEncipherment\n" > "$dir/ext.cnf"
        openssl x509 -req -in "$dir/client.csr" \
            -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial \
            -out "$dir/client.pem" -days 3650 -extfile "$dir/ext.cnf" >/dev/null 2>&1
        rm -f "$dir/client.csr"
    fi

    MTLS_CA="$dir/ca.pem"
    MTLS_CLIENT_CERT=$(awk 'NF' "$dir/client.pem")
    MTLS_CLIENT_KEY=$(awk 'NF' "$dir/client.key")
}

# ================================
# 生成 Reality x25519 密钥对
# 输出: REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY
# ================================
gen_reality_keys() {
    local tmpdir="/tmp/mihomo-reality-$$"
    mkdir -p "$tmpdir"

    openssl genpkey -algorithm X25519 -out "$tmpdir/k.key" 2>/dev/null
    openssl pkey -in "$tmpdir/k.key" -pubout -outform DER -out "$tmpdir/k.pub.der" 2>/dev/null
    openssl pkey -in "$tmpdir/k.key" -text -noout > "$tmpdir/k.txt" 2>/dev/null

    REALITY_PUBLIC_KEY=$(python3 - "$tmpdir" <<'PY'
import sys, base64, re
d = sys.argv[1]
pub = open(d + "/k.pub.der","rb").read()[-32:]
# Reality 密钥要求 URL-safe base64 (RFC4648), 无填充
b64_pub = base64.urlsafe_b64encode(pub).decode().rstrip("=")
txt = open(d + "/k.txt").read()
priv_section = txt.split("priv:")[1].split("pub:")[0]
priv_hex = re.sub(r"[^0-9a-fA-F]", "", priv_section)
b64_priv = base64.urlsafe_b64encode(bytes.fromhex(priv_hex)).decode().rstrip("=")
print(b64_pub)
open(d + "/priv.b64","w").write(b64_priv)
PY
    )
    REALITY_PRIVATE_KEY=$(cat "$tmpdir/priv.b64")
    rm -rf "$tmpdir"
}

# ================================
# 纯 TLS 模式证书来源选择
#   1) 已有证书 (ssl.sh 申请, /root/catmi/<域名>.crt|.key)
#   2) 现在调用 ssl.sh 申请
#   3) 自签证书 (内测/无域名兜底)
#   4) 自动优选域名 + 自签证书 (调用统一 domains.sh)
# 输出: CERT_FILE / KEY_FILE / CERT_DOMAIN
# ================================

# ================================
# 新增 Trojan 配置
# ================================
add_config() {
    print_title "新增 Trojan 配置"

    # 1. 自动生成 UUID 与密码
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASSWORD=$(openssl rand -hex 16)

    # 2. 自动生成端口
    default_port=$(random_port)
    # 必须检查返回值: m_safe_read_port 在 stdin 关闭 (EOF) 时返回 1 且不输出。
    # 原来写成 $(safe_read_port) 不检查, 于是端口变量为空, 但流程继续往下走,
    # 写出一个 `port:` 为空的节点 —— 而 mihomo -t 和 validate.py 都会放行,
    # 面板也显示"节点: N", 实际这个节点完全不能工作 (实测 2026-10-06)。
    TROJAN_PORT=$(safe_read_port "$default_port") || {
        print_error "未指定端口, 已取消创建"
        return 1
    }
    [[ -n "$TROJAN_PORT" ]] || { print_error "端口为空, 已取消创建"; return 1; }

    # 3. 自动编号
    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # 4. 获取服务器 IP
    SERVER_IP=$(m_server_ip)

    if [[ "$SERVER_IP" =~ : ]]; then
        LINK_IP="[$SERVER_IP]"
    else
        LINK_IP="$SERVER_IP"
    fi

    # 4.5 推荐配置 (一路回车 = ① 隐匿优先 REALITY)
    preset_ask trojan "Trojan 推荐配置"

    # 5. 询问特性 (模式/smux/mTLS)
    ask_features
    preset_reset   # 消费完才清

    # 6. 按模式准备安全参数
    if [[ "$TROJAN_MODE" = "reality" ]]; then
        gen_reality_keys
        REALITY_SHORT_ID=$(openssl rand -hex 8)
        # 伪装域名: 手动输入 > 自动优选 (统一 domains.sh) > 原默认 www.bing.com
        read -p "Reality 伪装目标域名 (回车=自动优选 domains.sh): " REALITY_DEST_INPUT
        REALITY_DEST_INPUT=$(clean_input "$REALITY_DEST_INPUT")
        if [[ -n "$REALITY_DEST_INPUT" ]]; then
            REALITY_DEST="$REALITY_DEST_INPUT"
        else
            print_info "未输入域名, 调用统一域名优选 domains.sh..."
            if auto_domain=$(auto_website); then
                REALITY_DEST="$auto_domain"
            else
                print_error "域名优选失败, 使用默认 www.microsoft.com"
                # 兜底值必须取**实测可用**的域名: 老代码兜底用 www.bing.com,
                # 而实测它在 REALITY 下必然 authentication failed (普通 TLS 却是通的),
                # 于是"优选失败"这个降级路径反而给用户一个连不上的节点。
                REALITY_DEST="www.microsoft.com"
            fi
        fi
    else
        ask_cert
        if $MTLS_ENABLED; then
            gen_mtls_cert "$index"
        fi
    fi
    render_smux
    # ws 的 Host 头: 内核默认就是取 sni (adapter/outbound/trojan.go:96-97),
    # 显式写出来只是为了和 path 一起可见, 不改变行为。
    [[ "$TROJAN_TRANSPORT" = "ws" ]] && WS_HOST="${REALITY_DEST:-$CERT_DOMAIN}"

    # 7. 写入入站配置
    render_listener_transport
    # 节点名统一走 m_node_tag。之前 reality/tls 两个变体的 listener
    # 都叫 trojan-01, 客户端列表里分不出哪个是哪个。
    # 用 [[ ]] && || 而不是 if/fi: 下面紧接着就是原有的
    # if/then/else 两分支渲染, 这里必须保持单条语句。
    [[ "$TROJAN_MODE" = "reality" ]] \
        && NODE_TAG="$(m_node_tag Trojan "$index" reality)" \
        || NODE_TAG="$(m_node_tag Trojan "$index" tls)"
    if [[ "$TROJAN_MODE" = "reality" ]]; then
cat > "$IN_FILE" <<EOF
# mode: reality
# transport: $TROJAN_TRANSPORT
# fingerprint: $CLIENT_FINGERPRINT
# smux: ${SMUX_PROFILE:-false}
listeners:
  - name: $NODE_TAG
    type: trojan
    listen: "0.0.0.0"
    port: $TROJAN_PORT
    users:
      - username: $UUID
        password: $PASSWORD
    reality-config:
      dest: $REALITY_DEST:443
      private-key: $REALITY_PRIVATE_KEY
      short-id:
        - $REALITY_SHORT_ID
      server-names:
        - $REALITY_DEST
$LISTENER_TRANSPORT
EOF
    else
cat > "$IN_FILE" <<EOF
# mode: tls
# transport: $TROJAN_TRANSPORT
# fingerprint: $CLIENT_FINGERPRINT
# skip-cert-verify: $SKIP_CERT_VERIFY
# mtls: $MTLS_ENABLED
# ws-http-upgrade: $WS_HTTP_UPGRADE
# smux: ${SMUX_PROFILE:-false}
listeners:
  - name: $NODE_TAG
    type: trojan
    listen: "0.0.0.0"
    port: $TROJAN_PORT
    users:
      - username: $UUID
        password: $PASSWORD
    certificate: $CERT_FILE
    private-key: $KEY_FILE
$LISTENER_TRANSPORT
$([ "$MTLS_ENABLED" = true ] && printf '    client-auth-type: RequireAndVerifyClientCert\n    client-auth-cert: %s' "$MTLS_CA")
EOF
    fi

    # 8. 保存 Reality public-key（按编号）
    if [[ "$TROJAN_MODE" = "reality" ]]; then
        echo "TROJAN_PUBKEY_${index}=$REALITY_PUBLIC_KEY" >> "$PUB_DIR/trojan_public_key.env"
    fi

    # 9. 写入客户端配置
#    ⚠️ 这里【不要】加回 `tls: true`。trojan 的 TrojanOption (adapter/outbound/trojan.go:46-68)
#    没有 tls 字段 —— 全文无 proxy:"tls"。listener 侧 (listener/inbound/trojan.go:12-29) 同样没有。
#    trojan 是 TLS-by-default 协议: StreamConnContext 的 default 分支
#    (adapter/outbound/trojan.go:150-172) 无条件套 TLS, 写了 tls: true 只会静默失效。
#    真正带 tls 字段的是 vless (adapter/outbound/vless.go)。
    render_proxy_transport
    if [[ "$TROJAN_MODE" = "reality" ]]; then
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $REALITY_DEST
    client-fingerprint: $CLIENT_FINGERPRINT
    udp: true
$TRANSPORT_BLOCK
    reality-opts:
      public-key: $REALITY_PUBLIC_KEY
      short-id: $REALITY_SHORT_ID
$SMUX_BLOCK
EOF
    else
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $CERT_DOMAIN
    client-fingerprint: $CLIENT_FINGERPRINT
    udp: true
    skip-cert-verify: $SKIP_CERT_VERIFY
$TRANSPORT_BLOCK
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
    fi

    # 10. 写入分享链接
    SHARE_LINK=$(render_share_link "$index")
    echo "$SHARE_LINK" > "$SHARE_FILE"

    # 11. 输出信息
    print_ok "Trojan 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $TROJAN_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "密码: $PASSWORD" >&2
    [[ "$TROJAN_MODE" = "reality" ]] && echo -e "模式: Reality (伪装: $REALITY_DEST)" >&2 || echo -e "模式: 纯 TLS (域名: $CERT_DOMAIN)" >&2
    case "$TROJAN_TRANSPORT" in
        ws)   echo -e "传输: ws (路径: $WS_PATH)$([[ "$WS_HTTP_UPGRADE" = true ]] && echo ' + v2ray-http-upgrade')" >&2 ;;
        grpc) echo -e "传输: grpc (服务名: $GRPC_SERVICE)" >&2 ;;
        *)    echo -e "传输: tcp" >&2 ;;
    esac
    echo -e "指纹: $CLIENT_FINGERPRINT" >&2
    [[ "$TROJAN_MODE" = "tls" ]] && echo -e "证书校验: $([[ "$SKIP_CERT_VERIFY" = true ]] && echo '跳过' || echo '严格')" >&2
    $MTLS_ENABLED && echo -e "mTLS: 已启用 (客户端证书: $CERT_DIR/mtls-$PROTO-$index/)" >&2
    _smux_on "${SMUX_PROFILE-}" && echo -e "smux: 已启用 ($SMUX_PROFILE 档)" >&2
    echo -e "入站配置: $IN_FILE" >&2
    echo -e "客户端配置: $OUT_FILE" >&2
    echo -e "分享链接: $SHARE_FILE" >&2
}

# ================================
# 查看 Trojan 配置
# ================================
list_configs() {
    print_title "Trojan 配置列表"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有找到任何 Trojan 配置"
        return
    fi

    for f in "${files[@]}"; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        port=$(grep -E "^[[:space:]]*port:" "$f" | awk '{print $2}')
        # 取值用 $NF: 片段里可能写成 "- username: xxx" (3 段) 也可能 "username: xxx" (2 段),
        # 固定取 $2 在前一种写法下会得到字面量 "username:"。
        uuid=$(grep -E "^[[:space:]]*-?[[:space:]]*username:" "$f" | awk '{print $NF}' | tr -d ' \r')
        pass=$(grep -E "password:" "$f" | head -1 | awk '{print $2}' | tr -d ' ')
        mode=$(grep -oE "^[[:space:]]*# mode: (tls|reality)" "$f" | awk '{print $3}')
        mode=${mode:-tls}
        # 老片段没有 "# transport:" 标记, 按历史行为回落 tcp
        transport=$(grep -oE "^[[:space:]]*# transport: (tcp|ws|grpc)" "$f" | head -1 | awk '{print $3}')
        [[ -z "$transport" ]] && { grep -qE "^[[:space:]]*ws-path: " "$f" && transport=ws || { grep -qE "^[[:space:]]*grpc-service-name: " "$f" && transport=grpc || transport=tcp; }; }
        fp=$(grep -oE "^[[:space:]]*# fingerprint: [a-z0-9]+" "$f" | head -1 | awk '{print $3}')
        fp=${fp:-chrome}

        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET}  " "$port" >&2
        printf "模式:${MAGENTA}%s${RESET}  " "$mode" >&2
        printf "传输:${MAGENTA}%s${RESET}  " "$transport" >&2
        printf "指纹:${CYAN}%s${RESET}  " "$fp" >&2
        printf "UUID:${WHITE}%s${RESET}  " "$uuid" >&2
        printf "密码:${YELLOW}%s${RESET}\n" "$pass" >&2
    done
}

# ================================
# 删除 Trojan 配置
# ================================
delete_config() {
    print_title "删除 Trojan 配置"

    list_configs

    printf "\n请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    num2=$(printf "%02d" "$num")

    IN_FILE="$CONF_DIR/$PROTO-$num2.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$num"
        return
    fi

    # 删除 Trojan 相关文件
    # 删除节点时同步清理它的 Nginx 回源配置并 reload。
    # 键用片段文件名 (vless-01 / trojan-02), 与创建时登记的一致;
    # 没有 CDN 绑定的节点这里直接返回 0, 不会有副作用。
    cdn_node_unregister "$(basename "$IN_FILE" .yaml)" 2>/dev/null || true
    rm -f "$IN_FILE"
    # 产物有两套命名 (单协议 / 批量 all.sh), 两套都要删, 否则批量生成的节点
    # 会留下孤儿产物 —— 它照样被 build_sub.py 收进订阅。见 m_out_rm_artifacts。
    m_out_rm_artifacts "$PROTO" "$num2" >/dev/null

    # 记下"这次删掉的是哪个协议桶", 供菜单项在**重载成功之后**吊销分享链接。
    # 不能在这里直接吊销: 重载失败会回滚, 那时节点还在, 链接却已经废了
    # (清空路径 server.sh 里记过这个反序踩坑)。
    _DELETED_PROTO_TAG="$PROTO"

    # 删除对应 public-key
    if [[ -f "$PUB_DIR/trojan_public_key.env" ]]; then
        sed -i "/^TROJAN_PUBKEY_${num2}=/d" "$PUB_DIR/trojan_public_key.env"
    fi

    print_ok "已删除 Trojan 配置 $num"
}

# ================================
# 手动重建客户端文件
# ================================
rebuild_client() {
    print_title "重建 Trojan 客户端文件"

    list_configs

    printf "\n请输入要重建的编号: " >&2
    read num
    num=$(clean_input "$num")
    num2=$(printf "%02d" "$num")

    IN_FILE="$CONF_DIR/$PROTO-$num2.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$num2"
        return
    fi

    # 提取字段
    PASSWORD=$(grep -E "^[[:space:]]*password:" "$IN_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
    # 同 rebuild_client: port: 必须锚定, 否则会命中 "# transport: ..." 注释行
    TROJAN_PORT=$(grep -E "^[[:space:]]*port:" "$IN_FILE" | head -1 | awk '{print $2}')

    read_features "$IN_FILE"
    render_smux

    SERVER_IP=$(m_server_ip)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

    if [[ "$TROJAN_MODE" = "reality" ]]; then
        REALITY_DEST=$(grep -A1 "server-names:" "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
        REALITY_SHORT_ID=$(grep -A1 "short-id:" "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
        REALITY_PUBLIC_KEY=$(grep -E "^TROJAN_PUBKEY_${num2}=" "$PUB_DIR/trojan_public_key.env" 2>/dev/null | sed "s/^TROJAN_PUBKEY_${num2}=//")
    else
        cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
        CERT_DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')
        if $MTLS_ENABLED; then
            MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
            MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
        fi
    fi

    # ws 的 Host 头与内核默认值一致 (= sni, adapter/outbound/trojan.go:96-97)
    [[ "$TROJAN_TRANSPORT" = "ws" ]] && WS_HOST="${REALITY_DEST:-$CERT_DOMAIN}"

    render_proxy_transport
    if [[ "$TROJAN_MODE" = "reality" ]]; then
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $REALITY_DEST
    client-fingerprint: $CLIENT_FINGERPRINT
    udp: true
$TRANSPORT_BLOCK
    reality-opts:
      public-key: $REALITY_PUBLIC_KEY
      short-id: $REALITY_SHORT_ID
$SMUX_BLOCK
EOF
    else
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $CERT_DOMAIN
    client-fingerprint: $CLIENT_FINGERPRINT
    udp: true
    skip-cert-verify: $SKIP_CERT_VERIFY
$TRANSPORT_BLOCK
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
    fi

    SHARE_LINK=$(render_share_link "$num2")
    echo "$SHARE_LINK" > "$SHARE_FILE"

    print_ok "客户端文件已重建：$num2"

    echo -e "\n${CYAN}===== 客户端 YAML =====${RESET}"
    cat "$OUT_FILE"

    echo -e "\n${CYAN}===== 分享链接 =====${RESET}"
    echo "$SHARE_LINK"
}

# ================================
# 静默重建（订阅用）
# ================================
rebuild_client_silent() {
    local num2="$1"

    IN_FILE="$CONF_DIR/$PROTO-$num2.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    [[ -f "$IN_FILE" ]] || return 0

    PASSWORD=$(grep -E "^[[:space:]]*password:" "$IN_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
    # port: 必须锚定行首 —— 新增的 "# transport: ws" 注释行里也含 "port:" 子串,
    # 不锚定会被 grep 一起捞出来, 把端口读成 "transport:\n<真端口>"。
    TROJAN_PORT=$(grep -E "^[[:space:]]*port:" "$IN_FILE" | head -1 | awk '{print $2}')

    read_features "$IN_FILE"
    render_smux

    SERVER_IP=$(m_server_ip)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

    if [[ "$TROJAN_MODE" = "reality" ]]; then
        REALITY_DEST=$(grep -A1 "server-names:" "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
        REALITY_SHORT_ID=$(grep -A1 "short-id:" "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
        REALITY_PUBLIC_KEY=$(grep -E "^TROJAN_PUBKEY_${num2}=" "$PUB_DIR/trojan_public_key.env" 2>/dev/null | sed "s/^TROJAN_PUBKEY_${num2}=//")
    else
        cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
        CERT_DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')
        if $MTLS_ENABLED; then
            MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
            MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
        fi
    fi

    # ws 的 Host 头与内核默认值一致 (= sni, adapter/outbound/trojan.go:96-97)
    [[ "$TROJAN_TRANSPORT" = "ws" ]] && WS_HOST="${REALITY_DEST:-$CERT_DOMAIN}"

    render_proxy_transport
    if [[ "$TROJAN_MODE" = "reality" ]]; then
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $REALITY_DEST
    client-fingerprint: $CLIENT_FINGERPRINT
    udp: true
$TRANSPORT_BLOCK
    reality-opts:
      public-key: $REALITY_PUBLIC_KEY
      short-id: $REALITY_SHORT_ID
$SMUX_BLOCK
EOF
    else
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $CERT_DOMAIN
    client-fingerprint: $CLIENT_FINGERPRINT
    udp: true
    skip-cert-verify: $SKIP_CERT_VERIFY
$TRANSPORT_BLOCK
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
    fi

    SHARE_LINK=$(render_share_link "$num2")
    echo "$SHARE_LINK" > "$SHARE_FILE"
}

# ================================
# 导出订阅
# ================================
export_subscription() {
    print_title "导出所有 Trojan 节点订阅（展开格式）"

    SUB_FILE="$OUT_DIR/trojan_subscribe.yaml"
    echo "# Trojan 全节点订阅（自动生成）" > "$SUB_FILE"
    echo "proxies:" >> "$SUB_FILE"

    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.yaml; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        num2=$(printf "%02d" "$num")

        rebuild_client_silent "$num2"

        CLIENT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
        [[ -f "$CLIENT_FILE" ]] || continue
        SHARE_LINK=$(cat "$OUT_DIR/${PROTO}_share-$num2.txt")

cat >> "$SUB_FILE" <<EOF

# ============================
# Trojan-$num2
# ============================
$(sed 's/^/  /' "$CLIENT_FILE")

  $SHARE_LINK

EOF

    done

    print_ok "订阅文件已生成：$SUB_FILE"

    echo -e "\n${CYAN}===== 订阅内容预览 =====${RESET}"
    cat "$SUB_FILE"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Mihomo Trojan 管理面板"

        ui_menu 1 "查看配置"
        ui_menu 2 "新增配置"
        ui_menu 3 "删除配置"
        ui_menu 4 "重建客户端文件"
        ui_menu 5 "导出所有节点订阅（Clash/Mihomo）"
        ui_menu 0 "退出"

        printf "请选择: " >&2
        read c || { printf "\n[信息] 非交互环境 (stdin 已关闭), 已退出\n" >&2; break; }
        c=$(clean_input "$c")

        case $c in
            1) list_configs ;;
            2) add_config; m_sync_reload ;;
            3) _DELETED_PROTO_TAG=""; delete_config; m_sync_reload && share_revoke_on_delete "${_DELETED_PROTO_TAG:-}" ;;
            4) rebuild_client ;;
            5) export_subscription ;;
            0) exit 0 ;;
            *) ui_invalid "$c" ;;
        esac

        printf "按回车继续..." >&2
        read || break
    done
}
# 直接跑本脚本 = 管理面板 (查看/新增/删除)。
# 从服务端面板「添加节点」进来时, 目标是**新增一个**, 不该再让人选一次
# 「2) 新增配置」—— 那层二级菜单在"一路回车"的批量场景下会把所有回车
# 吃成「无效选项:」, 最后节点数仍是 0, 而界面没有任何异常提示。
case "${1:-}" in
    add|"")
        if [[ "${1:-}" == "add" ]]; then
            add_config; m_sync_reload
            exit 0
        fi
        ;;
esac
main_menu
