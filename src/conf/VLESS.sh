#!/bin/bash

# 拼分享链接时给 IPv6 套方括号 (env.sh 的 m_uri_host 局部别名)
_uri_h() { m_uri_host "$1"; }

# ================================
# VLESS 内核服务端生成脚本 (WS / XHTTP / gRPC / HTTP2 / 裸TCP 五选一 + TLS)
# 基于 Trojan.sh 框架:
#   - 传输: 1) WS (CDN友好)  2) XHTTP (XHTTP+CDN)  3) gRPC  4) HTTP/2  5) 裸 TCP
#   - TLSS: 真实域名证书 (走 CDN 伪装)
#   - xhttp 抗探测档位: 标准/强化/极致 (x-padding-*, listener 与 proxy 必须逐字段一致)
#   - client-fingerprint: 7 档可选 (不再硬编码 chrome)
#   - smux: 可选 (3档: web/video/download, 客户端侧) + 服务端 mux-option 联动
#   - mTLS: 可选 (服务端 client-auth 双向认证)
#   - ECH:  可选 (Cloudflare 侧自动检测/开启 + 客户端 enable)
# ================================
# 彩色定义
# ================================
RED="\e[31m"
# UI 原语统一来自 src/lib/ui.sh (颜色/消息分级/标题), 此处不再重复定义。
# 被父级 source 时已加载; 单独运行时由下面的兜底 source 补上。

# ================================
# 基础路径
# ================================
PROTO="vless"
# 根目录解析。原来这里是裸的 BASE_DIR="/root/catmi/mihomo" (硬编码生产路径),
# 后面又用 SRV_ROOT="$BASE_DIR" 盖回去 —— 面板装在别处时会读写错目录, 测试时
# 只传 SRV_ROOT 也无效 (会被改回真实路径)。语义与 server.sh 对齐。
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

# ================================
# 传输 / 选配默认值 (重建时 read_features 会从片段注释回填)
#   VLESS_TRANSPORT : ws | xhttp | grpc | h2 | tcp
#   XHTTP_LEVEL     : std | strong | max   (x-padding 抗探测档位)
#   CLIENT_FP       : client-fingerprint 取值 (adapter/outbound/vless.go:90)
# ================================
VLESS_TRANSPORT="ws"
XHTTP_LEVEL="std"
CLIENT_FP="$(m_fp_get)"   # 服务端「客户端产物设置」里的指纹
GRPC_SERVICE=""
H2_PATH=""
XHTTP_PATH=""
WS_PATH=""
XHTTP_MODE="auto"
# x-padding 抗探测字段 (listener/inbound/vless.go:42-47 与 adapter/outbound/vless.go:99-104 字段同名同义)
XHTTP_PAD_BYTES="100-1000"
XHTTP_PAD_OBFS=false
XHTTP_PAD_KEY=""
XHTTP_PAD_HEADER="X-Pad"
XHTTP_PAD_PLACEMENT="query"
XHTTP_PAD_METHOD="tokenish"
XHTTP_SESSION_KEY="X-Session"
XHTTP_SEQ_KEY="X-Seq"


# ---------- 共享库 (src/lib/env.sh) ----------
# 提供: 路径常量 / 环境变量读写 / Reality dest 选择 / 合并+严格校验+重载闭环
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRV_ROOT="$BASE_DIR"
MIHOMO_BIN="$BASE_DIR/mihomo"
source "$SELF_DIR/../lib/env.sh"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR" "$PUB_DIR"

# ================================
# 输入清理
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

# ================================
# 定位/安装 Cloudflare API 管理器 cf-manager.sh
# 优先级: 服务端 本地路径 -> PATH -> 询问从 GitHub 安装 (cfapi/)
# 输出: 全局 CFMGR 变量 + stdout 打印路径 (无则空, 返回失败)
# 短链: -A <域名> <IP> [--proxy on|off|auto]  DNS ensure (幂等)
#       -E <域名>  ECH enable (幂等)   -S <域名>  ssl status   -P <域名> <端口>  origin port
# ================================
CFMGR=""
_cfmgr_asked=0

cfmgr() {
    local path="" dir="/root/catmi/cloudflare"
    local main="$dir/cf-manager.sh"
    local base_url="https://raw.githubusercontent.com/mi1314cat/One-click-script/main/cfapi"

    # 已存在 → 检查是否含"自归位"标记 (旧版无此标记则自动升级)
    if [[ -x "$main" ]]; then
        path="$main"
        if ! grep -q 'AUTO_HOME_REPO' "$main" 2>/dev/null; then
            print_warn "检测到旧版 cf-manager (无自归位), 自动升级中..."
            mkdir -p "$dir/modules"
            local f
            if curl -fsSL --max-time 25 "$base_url/cf-manager.sh" -o "$main.tmp" 2>/dev/null; then
                mv -f "$main.tmp" "$main"
                chmod +x "$main"
                for f in common context account zone dns ech ssl origin cert; do
                    [[ -f "$dir/modules/$f.sh" ]] || \
                        curl -fsSL --max-time 20 "$base_url/modules/$f.sh" -o "$dir/modules/$f.sh" 2>/dev/null || true
                done
                print_ok "cf-manager 已升级 (含自归位)"
            else
                print_warn "升级下载失败, 继续使用现有版本"
            fi
        fi
        CFMGR="$path"
        echo "$path"
        return 0
    elif command -v cf-manager.sh >/dev/null 2>&1; then
        path=$(command -v cf-manager.sh)
        CFMGR="$path"
        echo "$path"
        return 0
    fi

    # 本地未找到: 静默自动安装到标准目录 (不再询问, 治本)
    print_info "未找到 cf-manager, 自动安装到 $dir ..."
    mkdir -p "$dir/modules"
    local f
    if curl -fsSL --max-time 25 "$base_url/cf-manager.sh" -o "$dir/cf-manager.sh"; then
        chmod +x "$dir/cf-manager.sh"
        for f in common context account zone dns ech ssl origin cert; do
            curl -fsSL --max-time 20 "$base_url/modules/$f.sh" -o "$dir/modules/$f.sh" || true
        done
        if [[ -f "$dir/modules/common.sh" ]]; then
            CFMGR="$dir/cf-manager.sh"
            echo "$CFMGR"
            return 0
        fi
        print_warn "GitHub cfapi/ 缺少 modules/ 目录, 请手动上传 modules/ 或本地安装 cf-manager"
    else
        print_error "下载 cf-manager.sh 失败"
    fi
    CFMGR=""
    return 1
}

# ================================
# 获取公网 IP (交互确认; echo 输出 IP 到 stdout, 所有 print_* 与 read -p 提示走 stderr)
# 优先用 install_info.env 里管理员确认过的 PUBLIC_IP;
# 没有才现探测, 并且一律要人工确认 —— 透明代理下探测到的往往是代理出口 IP
# ================================
detect_public_ip() {
    local ip user_ip
    ip=$(m_server_ip)
    if [[ -z "$ip" ]]; then
        print_error "获取公网 IP 失败"
        read -r -p "请输入公网IP: " ip
        echo "$(clean_input "$ip")"
        return
    fi
    print_info "检测到 IP: $ip"
    read -r -p "使用此IP？(回车默认): " user_ip
    user_ip=$(clean_input "$user_ip")
    echo "${user_ip:-$ip}"
}

# ================================
# URL 编码 (分享链接 ech= 参数用)
# ================================
urlencode() {
    local s="$1" i c out=""
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9_.~-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

# CDN-ECH 分享链接参数: DNS 查询形式 (v2rayN/v2rayNG/edgetunnel 通用)
# cloudflare-ech.com+https://dns.alidns.com/dns-query
ECH_QUERY_PARAM="cloudflare-ech.com+https://dns.alidns.com/dns-query"

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
        [[ $((10#$n)) -ne "$i" ]] && break
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

# 随机 8-16 位路径段 (字母+数字, 抗识别; 大小写混合)
random_path() {
    local len=$((RANDOM % 9 + 8))  # 8..16
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local out="" i
    for ((i = 0; i < len; i++)); do
        out+="${chars:RANDOM % ${#chars}:1}"
    done
    echo "$out"
}

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

# brutal (BBR 带宽声明) 档位 —— 客户端 smux.brutal-opts 与服务端 mux-option.brutal 必须成对,
#   proxy: adapter/outbound/singmux.go:32-39 ; listener: listener/inbound/mux.go:7-13
#   up/down 单位走 ^(\d+)\s*([KMGT]?)([Bb])ps$ (common/utils/mbps.go:9), 纯数字=Mbps, 不匹配静默 0
BRUTAL_ENABLED=false
BRUTAL_UP="200 Mbps"
BRUTAL_DOWN="500 Mbps"

# 生成 x-padding 抗探测密钥 (base64url, 16 字符, 无 '=' 填充)
random_pad_key() {
    openssl rand -base64 12 2>/dev/null | tr '+/' '-_'
}

# ================================
# xhttp x-padding 抗探测档位 -> XHTTP_PAD_FIELDS
# 同一份字符串同时喂给 listener 的 xhttp-config 与 proxy 的 xhttp-opts
# (两侧字段同名同义, 缩进同为 6 空格; 铁律: 必须逐字段一致)
#   x-padding-bytes     默认 "100-1000"            transport/xhttp/xpadding.go:180-186
#   x-padding-obfs-mode 为 true 时才使用下面 4 项    transport/xhttp/config.go:503-512
#   x-padding-placement queryInHeader/cookie/header/query/path/body/auto  config.go:21-29
#   x-padding-method    repeat-x / tokenish        transport/xhttp/xpadding.go:14-18
#   session-*/seq-*     默认 placement 是 path      transport/xhttp/config.go:266-277
# ================================
render_xhttp_pad() {
    XHTTP_PAD_FIELDS="      x-padding-bytes: \"$XHTTP_PAD_BYTES\""
    if $XHTTP_PAD_OBFS; then
        XHTTP_PAD_FIELDS="${XHTTP_PAD_FIELDS}
      x-padding-obfs-mode: true
      x-padding-key: \"$XHTTP_PAD_KEY\"
      x-padding-header: $XHTTP_PAD_HEADER
      x-padding-placement: $XHTTP_PAD_PLACEMENT
      x-padding-method: $XHTTP_PAD_METHOD"
        # 极致档再把 session / seq 从默认 path 挪到 header, URL 长度不再抖动
        if [[ "$XHTTP_LEVEL" = "max" ]]; then
            XHTTP_PAD_FIELDS="${XHTTP_PAD_FIELDS}
      session-placement: header
      session-key: $XHTTP_SESSION_KEY
      seq-placement: header
      seq-key: $XHTTP_SEQ_KEY"
        fi
    fi
}

# ================================================================
# 传输方式渲染 (四处出口共用同一套变量, 避免三处渲染写法漂移)
#
# listener 侧 (listener/inbound/vless.go:12-30):
#   ws    -> ws-path            (:16)
#   xhttp -> xhttp-config       (:17)
#   grpc  -> grpc-service-name  (:18)
#   h2    -> 无此字段; tcp -> 无传输键
#   sing_vless 只在 ws-path / grpc-service-name / xhttp-config 非空时注册 HTTP handler
#   (listener/sing_vless/server.go:167 / :181 / :199-239), 否则 httpServer.Handler 为 nil,
#   每条连接直接走裸 VLESS (server.go:276-284)。=> listener 端结构性没有 h2。
#
# proxy 侧 (adapter/outbound/vless.go:72 + :78-82):
#   ws    -> network: ws    + ws-opts{path,headers.Host}
#   xhttp -> network: xhttp + xhttp-opts{mode,path,x-padding-*}
#   grpc  -> network: grpc  + grpc-opts{grpc-service-name}
#   h2    -> network: h2    + h2-opts{host[],path}
#            ⚠️ h2-opts.host 为空会被注入 ["www.example.com"] (adapter/outbound/vless.go:561-564)
#   tcp   -> network: tcp   (default 分支, vless.go:258-262)
# ================================================================
render_transport() {
    LISTENER_TRANSPORT_BLOCK=""
    CLIENT_TRANSPORT_BLOCK=""
    case "$VLESS_TRANSPORT" in
        ws)
            LISTENER_TRANSPORT_BLOCK="    ws-path: $WS_PATH"
            CLIENT_TRANSPORT_BLOCK="    network: ws
    ws-opts:
      path: $WS_PATH
      headers:
        Host: $CLIENT_HOST"
            ;;
        xhttp)
            LISTENER_TRANSPORT_BLOCK="    xhttp-config:
      mode: $XHTTP_MODE
      path: $XHTTP_PATH
${XHTTP_PAD_FIELDS}"
            CLIENT_TRANSPORT_BLOCK="    network: xhttp
    xhttp-opts:
      mode: $XHTTP_MODE
      path: $XHTTP_PATH
${XHTTP_PAD_FIELDS}"
            ;;
        grpc)
            LISTENER_TRANSPORT_BLOCK="    grpc-service-name: $GRPC_SERVICE"
            CLIENT_TRANSPORT_BLOCK="    network: grpc
    grpc-opts:
      grpc-service-name: $GRPC_SERVICE"
            ;;
        h2)
            # listener 无 h2 字段 (上面注释已说明), 客户端仍按内核结构输出
            CLIENT_TRANSPORT_BLOCK="    network: h2
    h2-opts:
      host:
        - $CLIENT_HOST
      path: $H2_PATH"
            ;;
        *)
            # tcp: 裸 TCP, 两侧都不写任何传输键
            CLIENT_TRANSPORT_BLOCK="    network: tcp"
            ;;
    esac
}

# 分享链接 URI 参数 (内核导入口径见 common/convert/v.go:67-140:
#   type=ws      -> path + host      (:109-136)
#   type=xhttp   -> path + mode      (:141-163)
#   type=grpc    -> serviceName      (:137-140)
#   type=h2      -> path + host      (:98-108); type=http 亦被映射成 h2 (:73-76)
#   type=tcp     -> 无额外参数       (:79-80)
render_share_link() {
    local fp="$CLIENT_FP" ech=""
    $ECH_ENABLED && ech="&ech=$(urlencode "$ECH_QUERY_PARAM")"
    # 显示名复用 NODE_TAG —— 和 listener / proxy 同源。
    # 传输方式不进名字, 对齐 SB 上游 tag_form_suffix 的取舍 (只分 TLS 形态)。
    # 以前这里是 VLESS-XHTTP-01 / VLESS-WS-01, 而 listener 叫 vless-01,
    # 用户在客户端看到的和面板里列的是两个东西。
    # ⚠ 端口用 $VLESS_PORT, 不能写死 443 —— 走 443/CDN 的形态由 CDN 档位负责
        #   (server 填 CDN 域名); 直连档位用自己分配的端口。
    local tag="${NODE_TAG:-$(m_node_tag VLESS "$INDEX" tls)}"
    case "$VLESS_TRANSPORT" in
        xhttp) SHARE_LINK="vless://$UUID@$(_uri_h "$CLIENT_HOST"):$VLESS_PORT?encryption=none&security=tls&sni=$CLIENT_SNI&fp=$fp&type=xhttp&mode=$XHTTP_MODE&path=$XHTTP_PATH$ech#$tag" ;;
        grpc)  SHARE_LINK="vless://$UUID@$(_uri_h "$CLIENT_HOST"):$VLESS_PORT?encryption=none&security=tls&sni=$CLIENT_SNI&fp=$fp&type=grpc&serviceName=$GRPC_SERVICE$ech#$tag" ;;
        h2)    SHARE_LINK="vless://$UUID@$(_uri_h "$CLIENT_HOST"):$VLESS_PORT?encryption=none&security=tls&sni=$CLIENT_SNI&fp=$fp&type=h2&host=$CLIENT_HOST&path=$H2_PATH$ech#$tag" ;;
        tcp)   SHARE_LINK="vless://$UUID@$(_uri_h "$CLIENT_HOST"):$VLESS_PORT?encryption=none&security=tls&sni=$CLIENT_SNI&fp=$fp&type=tcp$ech#$tag" ;;
        *)     SHARE_LINK="vless://$UUID@$(_uri_h "$CLIENT_HOST"):$VLESS_PORT?encryption=none&security=tls&sni=$CLIENT_SNI&fp=$fp&type=ws&path=$WS_PATH&host=$CLIENT_HOST$ech#$tag" ;;
    esac
}

# ================================================================
# 四处渲染出口 ① : 服务端 config.d 片 -> $IN_FILE
# 顶部注释行是重建客户端时的唯一信息来源 (read_features 回读)
# ================================================================
render_listener_frag() {
    # 兜底: 单独调用本函数时 NODE_TAG 可能没设。name: 为空的话 mihomo -t
    # 照样通过 (它不校验空名字), 但节点在客户端列表里就是个无名项,
    # 排查起来极难 —— 和之前空端口 bug 同一类问题, 所以这里主动补。
    NODE_TAG="${NODE_TAG:-$(m_node_tag VLESS "${INDEX:-01}" tls)}"
    cat > "$IN_FILE" <<EOF
# transport: $VLESS_TRANSPORT
# server-name: $FRONT_DOMAIN
# client-fp: $CLIENT_FP
$([[ "$VLESS_TRANSPORT" = "xhttp" ]] && printf '# xhttp-level: %s' "$XHTTP_LEVEL")
$([[ "$VLESS_TRANSPORT" = "h2" ]] && printf '# h2-path: %s' "$H2_PATH")
# access: $ACCESS_MODE
# mtls: $MTLS_ENABLED
# ech: $ECH_ENABLED
# smux: ${SMUX_PROFILE:-false}
$(if $BRUTAL_ENABLED; then printf '# brutal: true
# brutal-up: %s
# brutal-down: %s' "$BRUTAL_UP" "$BRUTAL_DOWN"; fi)
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "$LISTEN_ADDR"
    port: $VLESS_PORT
    users:
      - username: $NODE_TAG
        uuid: $UUID
    certificate: $CERT_FILE
    private-key: $KEY_FILE
$LISTENER_TRANSPORT_BLOCK
$MUX_OPTION_BLOCK
$([ "$MTLS_ENABLED" = true ] && printf '    client-auth-type: RequireAndVerifyClientCert
    client-auth-cert: %s' "$MTLS_CA")
EOF
}

# ================================================================
# 四处渲染出口 ② : 客户端 out/*.yaml -> $OUT_FILE
# servername 而非 sni: vless proxy 只有 servername (adapter/outbound/vless.go:89),
# 写 sni 会被静默丢弃 (common/structure/structure.go:566-581)
# ================================================================
render_client_yaml() {
    NODE_TAG="${NODE_TAG:-$(m_node_tag VLESS "${INDEX:-01}" tls)}"
    cat > "$OUT_FILE" <<EOF
$([ "$ECH_ENABLED" = true ] && printf '# ECH: 已启用 (mihomo ech-opts 自动发现 Cloudflare ECH, 外层 SNI=cloudflare-ech.com)\n')
proxies:
  - name: $NODE_TAG
    type: vless
    server: $CLIENT_HOST
    port: $VLESS_PORT
    uuid: $UUID
    servername: $CLIENT_SNI
    client-fingerprint: $CLIENT_FP
    udp: true
    tls: true
    skip-cert-verify: true
$CLIENT_TRANSPORT_BLOCK
$([ "$ECH_ENABLED" = true ] && printf '    ech-opts:\n      enable: true\n      query-server-name: %s' "$CERT_DOMAIN")
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
}

# ================================================================
# 四处渲染出口 ③④ : nginx 转发片段 (render_nginx_conf) 与分享链接 (render_share_link)
# 已在各自函数中实现, 全部消费同一批全局渲染变量。
# ================================================================

# ================================
# 特性询问（模式 + mTLS + smux）
# 选择持久化到 config.d 片的注释行:
#   # transport: ws|xhttp|grpc|h2|tcp
#   # xhttp-level: std|strong|max      (仅 xhttp)
#   # client-fp: <client-fingerprint>
#   # h2-path: /<path>                 (仅 h2, listener 无处存放只能记注释)
#   # access: cdn|nginx
#   # mtls: true
#   # ech: true
#   # smux: <档位>
#   # brutal: true / # brutal-up: / # brutal-down:
# ================================
ask_features() {
    local yn
    VLESS_TRANSPORT="ws"  # ws | xhttp | grpc | h2 | tcp
    XHTTP_LEVEL="std"
    CLIENT_FP="chrome"
    ACCESS_MODE="cdn"    # cdn(CF直连 0.0.0.0) | nginx(nginx转发 127.0.0.1)
    MTLS_ENABLED=false
    SMUX_PROFILE=""
    ECH_ENABLED=false
    BRUTAL_ENABLED=false

    # ★ 预置已套用时不再问传输 —— 问了就等于把用户刚选的推荐方案覆盖掉,
    #   那还不如不给预置。M_PRESET_APPLIED 由 preset_apply 置位。
    if [[ "${M_PRESET_APPLIED:-0}" == "1" && -n "${M_PRESET_TR:-}" ]]; then
        VLESS_TRANSPORT="$M_PRESET_TR"
        print_info "传输方式 (来自推荐配置): $VLESS_TRANSPORT"
    else
    echo "  传输方式:" >&2
    echo "  1) WS (WebSocket, CDN 最兼容, 推荐)" >&2
    echo "  2) XHTTP (XHTTP+CDN, 抗识别更强, 需 Cloudflare 支持)" >&2
    echo "  3) gRPC (HTTP/2 多路复用, 无 CDN 场景)" >&2
    echo "  4) HTTP/2 (h2, 直连)" >&2
    echo "  5) 裸 TCP (raw)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) VLESS_TRANSPORT="xhttp" ;;
        3) VLESS_TRANSPORT="grpc" ;;
        4) VLESS_TRANSPORT="h2" ;;
        5) VLESS_TRANSPORT="tcp" ;;
        *) VLESS_TRANSPORT="ws" ;;
    esac
    fi   # ← 预置分支结束

    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
        ask_xhttp_level
    fi

    # smux 档位也由推荐配置给 (网页党/视频党), 没给才问
    if [[ "${M_PRESET_APPLIED:-0}" == "1" && -n "${M_PRESET_MUX:-}" ]]; then
        SMUX_PROFILE="$M_PRESET_MUX"
        print_info "smux 档位 (来自推荐配置): $SMUX_PROFILE"
    fi

    # ECH: 推荐配置里带了 ech 就直接开, 不再单独问一遍
    if [[ "${M_PRESET_ECH:-0}" == "1" ]]; then
        ECH_ENABLED=true
        MTLS_ENABLED=false      # ECH 与 mTLS 冲突, 与原有分支保持一致
        print_info "ECH: 已按推荐配置启用 (mTLS 自动跳过)"
    fi

    ask_client_fp

    if [[ "$VLESS_TRANSPORT" = "h2" ]]; then
        # mihomo 的 VLESS listener 结构性没有 h2 (listener/inbound/vless.go:12-30):
        # sing_vless 只在 ws-path / grpc-service-name / xhttp-config 非空时才注册 HTTP handler
        # (listener/sing_vless/server.go:167 / :181 / :199-239), 否则连接被直接按裸 VLESS 解析,
        # 客户端发来的 HTTP/2 帧会被当成 VLESS 头 -> 必然握手失败。
        print_warn "HTTP/2 (h2) 没有可用的服务端实现: mihomo 的 vless listener 不提供 h2 终止 (listener/inbound/vless.go:12-30 无该字段)"
        print_warn "已自动改用 gRPC (同为 HTTP/2 + ALPN h2 多路复用, 且 listener 侧有 grpc-service-name 支持)"
        VLESS_TRANSPORT="grpc"
    fi

    echo "  接入方式:" >&2
    echo "  1) CF 直连 (监听 0.0.0.0, Cloudflare Origin Rules 直接回源到端口)" >&2
    echo "  2) Nginx 转发 (监听 127.0.0.1, 走 nginx 路径匹配统一入口)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) ACCESS_MODE="nginx" ;;
        *) ACCESS_MODE="cdn" ;;
    esac

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
        printf "启用 brutal 带宽声明 (BBR, 写死上下行速率)? (y/N): " >&2
        read -r yn
        if [[ "$(clean_input "$yn")" =~ ^[yY]$ ]]; then
            BRUTAL_ENABLED=true
            printf "  brutal 上行带宽 (默认 %s): " "$BRUTAL_UP" >&2
            read -r yn
            yn=$(clean_input "$yn")
            [[ -n "$yn" ]] && BRUTAL_UP="$yn"
            printf "  brutal 下行带宽 (默认 %s): " "$BRUTAL_DOWN" >&2
            read -r yn
            yn=$(clean_input "$yn")
            [[ -n "$yn" ]] && BRUTAL_DOWN="$yn"
            print_warn "brutal 会把吞吐硬顶到上述速率 (up: $BRUTAL_UP / down: $BRUTAL_DOWN), 不匹配正则会静默变 0"
        fi
    fi

    printf "启用 ECH (Encrypted Client Hello, 需 Cloudflare 支持)? (y/N): " >&2
    read -r yn
    if [[ "$(clean_input "$yn")" =~ ^[yY]$ ]]; then
        ECH_ENABLED=true
        # ECH = 走 CDN, TLS 终止于 Cloudflare, 客户端证书到不了服务器
        # mTLS(服务端 client-auth) 与此冲突, 强制跳过
        print_warn "ECH 已启用(走 CDN): mTLS 与 ECH 冲突, 已自动跳过 mTLS"
        MTLS_ENABLED=false
    else
        printf "启用 mTLS 客户端证书认证？(y/N): " >&2
        read -r yn
        [[ "$(clean_input "$yn")" =~ ^[yY]$ ]] && MTLS_ENABLED=true
    fi
}

# 按档位填充 x-padding 字段 (询问与重建共用, 保证两侧生成逻辑唯一)
apply_xhttp_level() {
    case "$XHTTP_LEVEL" in
        strong)
            XHTTP_PAD_BYTES="256-4096"
            XHTTP_PAD_OBFS=true
            XHTTP_PAD_PLACEMENT="query"
            ;;
        max)
            XHTTP_PAD_BYTES="512-8192"
            XHTTP_PAD_OBFS=true
            XHTTP_PAD_PLACEMENT="header"
            ;;
        *)
            # 标准档显式写出内核默认值 "100-1000" (transport/xhttp/xpadding.go:180-186):
            # 行为与不写完全一致, 只是配置里看得见
            XHTTP_LEVEL="std"
            XHTTP_PAD_BYTES="100-1000"
            XHTTP_PAD_OBFS=false
            XHTTP_PAD_PLACEMENT="query"
            ;;
    esac
    render_xhttp_pad
}

# xhttp 抗探测档位 (spec §4.1 ②)
# 铁律: x-padding-key / x-padding-header 只在 x-padding-obfs-mode: true 时生效
#       (transport/xhttp/config.go:503-512), 且 listener 的 xhttp-config 与
#       proxy 的 xhttp-opts 必须逐字段一致, 否则客户端 padding 服务端解不开。
ask_xhttp_level() {
    local yn
    echo "  xhttp 抗探测档位:" >&2
    echo "  1) 标准 (推荐) 只用内核默认 padding, 兼容性最好" >&2
    echo "  2) 强化 调整 padding 区间 + 开 obfs mode" >&2
    echo "  3) 极致 全面拉高 padding/session/seq 各维度" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) XHTTP_LEVEL="strong"; XHTTP_PAD_KEY=$(random_pad_key) ;;
        3) XHTTP_LEVEL="max";    XHTTP_PAD_KEY=$(random_pad_key) ;;
        *) XHTTP_LEVEL="std";    XHTTP_PAD_KEY="" ;;
    esac
    apply_xhttp_level
}

# client-fingerprint (adapter/outbound/vless.go:90)
# 全量枚举见 component/tls/utls.go:78-101; 这里只暴露未废弃的 7 个
# (chrome_psk / chrome_psk_shuffle / chrome_padding_psk_shuffle / chrome_pq /
#  chrome_pq_psk 在 utls.go:94-99 已标 deprecated; 写错值只会 log.Warn 后
#  静默降级成原生 TLS, utls.go:56-59)
ask_client_fp() {
    local yn
    echo "  TLS 客户端指纹 (client-fingerprint):" >&2
    echo "  1) chrome (推荐, 与绝大多数 CDN 一致)" >&2
    echo "  2) firefox" >&2
    echo "  3) safari" >&2
    echo "  4) edge" >&2
    echo "  5) ios" >&2
    echo "  6) android" >&2
    echo "  7) random (每次连接加权随机, chrome 权重最高)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) CLIENT_FP="firefox" ;;
        3) CLIENT_FP="safari" ;;
        4) CLIENT_FP="edge" ;;
        5) CLIENT_FP="ios" ;;
        6) CLIENT_FP="android" ;;
        7) CLIENT_FP="random" ;;
        *) CLIENT_FP="chrome" ;;
    esac
}

# 读取 config.d 片注释中的特性标记（供重建/导出时同步）
# 兼容旧格式 "# smux: true" -> 视为 web 档
read_features() {
    local f="$1"
    VLESS_TRANSPORT="ws"
    XHTTP_LEVEL="std"
    CLIENT_FP="chrome"
    H2_PATH=""
    ACCESS_MODE="cdn"
    MTLS_ENABLED=false
    SMUX_PROFILE=""
    ECH_ENABLED=false
    BRUTAL_ENABLED=false
    if grep -qE "^[[:space:]]*# transport: (ws|xhttp|grpc|h2|tcp)" "$f"; then
        VLESS_TRANSPORT=$(grep -oE "^[[:space:]]*# transport: (ws|xhttp|grpc|h2|tcp)" "$f" | awk '{print $3}')
    fi
    if grep -qE "^[[:space:]]*# xhttp-level: (std|strong|max)" "$f"; then
        XHTTP_LEVEL=$(grep -oE "^[[:space:]]*# xhttp-level: (std|strong|max)" "$f" | awk '{print $3}')
    fi
    if grep -qE "^[[:space:]]*# client-fp: [^[:space:]]+" "$f"; then
        CLIENT_FP=$(grep -oE "^[[:space:]]*# client-fp: [^[:space:]]+" "$f" | awk '{print $3}')
    fi
    H2_PATH=$(grep -oE "^[[:space:]]*# h2-path: [^[:space:]]+" "$f" | awk '{print $3}')
    if grep -qE "^[[:space:]]*# access: (cdn|nginx)" "$f"; then
        ACCESS_MODE=$(grep -oE "^[[:space:]]*# access: (cdn|nginx)" "$f" | awk '{print $3}')
    fi
    grep -qE "^[[:space:]]*# mtls: true" "$f" && MTLS_ENABLED=true
    grep -qE "^[[:space:]]*# ech: true" "$f" && ECH_ENABLED=true
    if grep -qE "^[[:space:]]*# smux: (web|video|download)" "$f"; then
        SMUX_PROFILE=$(grep -oE "^[[:space:]]*# smux: (web|video|download)" "$f" | awk '{print $3}')
    elif grep -qE "^[[:space:]]*# smux: true" "$f"; then
        SMUX_PROFILE="web"
    fi
    grep -qE "^[[:space:]]*# brutal: true" "$f" && BRUTAL_ENABLED=true
    if $BRUTAL_ENABLED; then
        BRUTAL_UP=$(grep -oE "^[[:space:]]*# brutal-up: .+" "$f" | head -1 | sed -E 's/^[^:]+:[[:space:]]*//')
        BRUTAL_DOWN=$(grep -oE "^[[:space:]]*# brutal-down: .+" "$f" | head -1 | sed -E 's/^[^:]+:[[:space:]]*//')
    fi
}

# 渲染 smux 客户端配置块（按档位）；输出到变量 SMUX_BLOCK
# padding 与服务端 mux-option.padding 成对 (singmux.go:29 / listener/inbound/mux.go:6)
# brutal-opts 与服务端 mux-option.brutal 成对 (singmux.go:32-39 / listener/inbound/mux.go:10-13)
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
      max-streams: $ms
      padding: true"
    if $BRUTAL_ENABLED; then
        SMUX_BLOCK="$SMUX_BLOCK
      brutal-opts:
        enabled: true
        up: \"$BRUTAL_UP\"
        down: \"$BRUTAL_DOWN\""
    fi
}

# 渲染服务端 mux-option (listener/inbound/vless.go:29 -> listener/sing/sing.go:84-89)
# 没有它, 客户端 smux 档位就只是客户端一侧自说自话
render_mux_option() {
    MUX_OPTION_BLOCK=""
    _smux_on "${SMUX_PROFILE-}" || return
    MUX_OPTION_BLOCK="    mux-option:
      padding: true"
    if $BRUTAL_ENABLED; then
        MUX_OPTION_BLOCK="$MUX_OPTION_BLOCK
      brutal:
        enabled: true
        up: \"$BRUTAL_UP\"
        down: \"$BRUTAL_DOWN\""
    fi
}

# ================================
# 生成 Nginx location 转发片段 (可选接入方式, 存文件供复制)
# 输入: VLESS_TRANSPORT / VLESS_PORT / WS_PATH / XHTTP_PATH / GRPC_SERVICE / H2_PATH
# 输出: Nginx 配置片段写入 NGINX_FILE (out/${PROTO}_nginx-<index>.conf)
# 注意: 裸 TCP 走的是 nginx stream{} 四层透传, 片段要放 nginx.conf 而不是 conf.d
# ================================
render_nginx_conf() {
    local path idx
    if [[ -z "$INDEX" ]]; then
        print_warn "INDEX 未设置, 跳过 Nginx 转发片段生成"
        return
    fi
    idx="$INDEX"
    NGINX_FILE="$OUT_DIR/${PROTO}_nginx-$idx.conf"
    case "$VLESS_TRANSPORT" in
        xhttp)
        # ★ xHTTP 与其它传输不同: 必须用 grpc_pass, **不能**用 proxy_pass。
        #
        #   原因: xHTTP 默认伪装成 gRPC —— 请求带 Content-Type: application/grpc
        #   并对上行做 gRPC 分帧 (上游为此专门加过 PR, 目的就是穿透"会缓存
        #   上行请求"的中间盒)。nginx 只有 grpc_pass 按 gRPC 语义转发;
        #   用 proxy_pass 会因逐请求缓冲而卡死上行 —— 表现为"握手能过、
        #   一传数据就断", 且日志里看不出原因。
        #
        #   代价 (Xray 作者原话): 「grpc_pass 反代 xhttp 时不支持 http/1.1,
        #   要支持请用 proxy_pass」=> 本模板只对 HTTP/2 客户端有效。
        #
        #   另: 必须确认 Cloudflare 缓存规则**排除该 path**, 否则会被缓存。
        path="$XHTTP_PATH"
        [[ "$path" != /* ]] && path="/$path"   # 路径要恰好一个前导斜杠
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (XHTTP, 端口 $VLESS_PORT)
# 放入 nginx conf.d 站点 server{} 块内即可。
# 【必须是 grpc_pass】xhttp 默认伪装成 gRPC, 用 proxy_pass 会卡死上行。
# 【依赖 server{}/http{} 层】client_max_body_size 0;
#                          proxy_request_buffering off;
#                          proxy_buffering off;
#   少了它们会出现"握手能过、一传数据就断"或 413。
location $path {
    grpc_buffer_size 16k;
    grpc_socket_keepalive on;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;
    grpc_set_header Connection "";
    grpc_set_header Host \$host;
    grpc_set_header X-Real-IP \$remote_addr;
    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    grpc_set_header X-Forwarded-Proto \$scheme;
    grpc_pass grpcs://127.0.0.1:$VLESS_PORT;
}
EOF
        ;;
        grpc)
        # grpc_pass 的 grpcs:// 与 grpc:// 必须和上游监听方式对上。
        # mihomo 的 listener 默认对 127.0.0.1 是明文回源 (nginx 终结外层 TLS,
        # 到 mihomo 这一跳走明文), 所以默认 grpc://; 但若本节点启用了
        # 内部 TLS 回源, 必须改成 grpcs:// —— 用错就是稳定 502,
        # 而且日志里看不出原因 (SB 上游为此专门踩过)。
        # gscheme 只存 "grpc"/"grpcs", "://" 由模板补上 ——
        # 两边都写的话会生成 "grpc://://127.0.0.1:..." , nginx 报
        # invalid host in upstream 而拒绝加载。
        local gscheme="grpc" gnote=""
        if [[ "${VLESS_UPSTREAM_TLS:-0}" == "1" ]]; then
            gscheme="grpcs"
            gnote="    # 上游 mihomo 开了 TLS 回源, 必须用 grpcs://"
        fi
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (gRPC, 服务名 $GRPC_SERVICE, 端口 $VLESS_PORT)
# 放入 nginx conf.d 站点 server{} 块内即可 (需编译 --with-http_v2_module)
# 【选对 grpc_pass 的 scheme】上游是明文回源用 grpc://, 上游开了 TLS 用 grpcs://。
#   用错的表现是稳定 502, 日志里看不出原因 —— 先按这里说明确认一遍。
location /$GRPC_SERVICE {
${gnote}
    grpc_pass $gscheme://127.0.0.1:$VLESS_PORT;
    grpc_set_header Host \$host;
    grpc_set_header X-Real-IP \$remote_addr;
    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    grpc_read_timeout 600s;
    grpc_send_timeout 600s;
}
EOF
        ;;
        h2)
        path="$H2_PATH"
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (HTTP/2, 端口 $VLESS_PORT)
# ⚠️ mihomo 的 vless listener 不提供 h2 终止, 本片段仅在自建 h2 终止层时参考
location $path {
    proxy_ssl_server_name on;
    proxy_pass https://127.0.0.1:$VLESS_PORT;
    proxy_http_version 2.0;
}
EOF
        ;;
        tcp)
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (裸 TCP, 端口 $VLESS_PORT)
# ⚠️ 裸 TCP 只能四层透传: 放进 nginx.conf 的 stream{} 块 (不是 conf.d 的 http server{}),
#    nginx 不终结 TLS, TLS + VLESS 全部由 127.0.0.1:$VLESS_PORT 上的 mihomo listener 处理。
stream {
    server {
        listen 443;
        proxy_pass 127.0.0.1:$VLESS_PORT;
        proxy_timeout 300s;
    }
}
EOF
        ;;
        *)
        path="$WS_PATH"
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (WS, 端口 $VLESS_PORT)
# 放入 nginx conf.d 站点 server{} 块内即可 (回源走 TLS + WebSocket 升级)
location $path {
    proxy_ssl_server_name on;                 # 回源时 TLS SNI
    proxy_pass https://127.0.0.1:$VLESS_PORT; # https:// -> nginx 做 TLS 回源
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;      # WebSocket 升级
    proxy_set_header Connection \$connection_upgrade;
}
EOF
            # $connection_upgrade 是 map 指令产生的变量, nginx 没有内置 ——
            # 不定义就用, nginx 启动报 "unknown variable" 而失败。
            # 之前这里只写了句注释说 "map.conf 已备", 但全项目从来没生成过
            # 那个文件, 用户照着粘贴必然起不来。片段自带依赖, 一起给出。
            write_upgrade_map
            ;;
    esac
    print_ok "Nginx 转发片段: $NGINX_FILE"
    nginx_insert_menu "$NGINX_FILE"
    echo -e "${CYAN}  ----- Nginx 配置片段 -----${RESET}" >&2
    cat "$NGINX_FILE" >&2
}

# 把片段插进本机已有的 Nginx 站点。
#
# 之前这里只生成文件、打印一句"粘到 conf.d 的 server{} 里", 把最难的一步
# 留给了用户。实际做的时候: 得先判断 nginx 是宿主还是容器 (服务端 上就是容器,
# 宿主 /etc/nginx/sites-enabled 里的站点文件根本不是生效配置)、要找到域名
# 对应���那个 server 块、要插在对的层级、插完还得 nginx -t 确认。
# 这些每一步都可能出错, 而且出错方式和内核崩溃长得一样难查。
#
# 插入并校验通过后由 nginx_apply.py 直接 reload —— 改了不重载等于没改:
# 片段在文件里但 nginx 跑的还是旧配置, 节点照样连不上, 且没有任何报错。
# nginx 的 reload 是平滑的 (不断现有连接), 顾虑不成立。
nginx_insert_menu() {
    local frag="$1"
    local apply="$SELF_DIR/nginx_apply.py"
    [[ -f "$apply" ]] || return 0
    [[ -n "${CERT_DOMAIN:-}" ]] || return 0

    printf '\n' >&2
    printf "  这台机器上的 Nginx 要不要直接配好？\n" >&2
    printf "    1) 插入到 Nginx 站点 (自动定位 / 备份 / nginx -t 校验)\n" >&2
    printf "    2) 跳过, 我自己粘贴\n" >&2
    printf "  请选择 [2]: " >&2
    local c; read -r c
    [[ "$c" == "1" ]] || return 0

    printf '\n  可选站点:\n' >&2
    python3 "$apply" --list 2>&1 | sed 's/^/    /' >&2
    printf "  回源域名: %s\n" "$CERT_DOMAIN" >&2
    printf "  请输入要写入的站点配置文件 (留空跳过): " >&2
    local f; read -r f
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    [[ -n "$f" && -f "$f" ]] || { print_warn "未指定有效文件, 跳过"; return 0; }

    # 校验命令: 容器化要用 docker exec。
    # 否则 nginx -t 验的是宿主那份 —— 宿主那份可能根本没挂进容器,
    # 验过了也不代表真正生效的配置没问题 (实测 就是这个坑)。
    local chk="none"
    if command -v docker >/dev/null 2>&1; then
        local cname
        cname=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
                | awk 'tolower($0) ~ /nginx/ {print $1; exit}')
        [[ -n "$cname" ]] && chk="docker exec $cname nginx"
    fi
    [[ "$chk" == "none" ]] && command -v nginx >/dev/null 2>&1 && chk="nginx"

    python3 "$apply" --domain "$CERT_DOMAIN" --file "$f" \
            --block "$frag" --nginx "$chk" 2>&1 | sed 's/^/    /' >&2
    local rc=${PIPESTATUS[0]}
    if (( rc != 0 )); then
        print_error "写入失败 (退出码 $rc) —— nginx_apply.py 已自动回滚, 站点未被改动"
        return $rc
    fi

    # 登记「节点 -> 域名/站点」绑定。
    # 没有这一步, 删除节点时就找不到它当初写进了哪个站点、哪一段,
    # 也就无法回删。键用片段文件名 (vless-01), 与 delete_config 一致。
    local meta tr path
    meta=$(cdn_node_meta_from_fragment "$IN_FILE" 2>/dev/null)
    tr="${meta%%|*}"; path="${meta#*|}"
    cdn_bind_node "$PROTO" "$INDEX" "$CERT_DOMAIN" "$f" "$tr" "$path" "${VLESS_PORT:-}"
    print_ok "已登记 CDN 绑定 —— 删除该节点时会自动回删这段 Nginx 配置并 reload"
}

# 生成 WebSocket 升级所需的 map 块。
#
# 必须和引用它的 location 一起给出, 否则 nginx -t 直接失败:
#   nginx: [emerg] unknown "connection_upgrade" variable
#
# 放在 http{} 层 (conf.d/*.conf, 或 nginx.conf 的 http 块内) ——
# nginx 的 map 只允许在 http 层声明, 放 server{} 里会报 "map directive
# is not allowed here"。
write_upgrade_map() {
    local mapfile
    mapfile="$OUT_DIR/${PROTO}_nginx-map-$INDEX.conf"
    cat > "$mapfile" <<'EOF'
# WebSocket 升级所需的 map 块
#
# 【放在哪】nginx 的 http{} 层, 也就是 /etc/nginx/conf.d/*.conf
#          (或 nginx.conf 的 http { } 块内) —— 不能放 server{} 里,
#          nginx 的 map 指令不允许出现在 server 块中。
#
# 【为什么需要】location 里的 $connection_upgrade 由这个 map 产生,
#          nginx 没有内置。缺了它 nginx -t 就报 unknown variable 直接起不来。
#
# 【验证】两个文件都粘完后先 nginx -t, 通过再 nginx -s reload

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    print_ok "Nginx map 块: $mapfile"
    echo -e "${CYAN}  ----- Nginx map 块 (与上面的片段一起用) -----${RESET}" >&2
    cat "$mapfile" >&2
    echo -e "${YELLOW}  ! 两段都要放进 nginx 的 http 层; 只粘 location 段会启动失败${RESET}" >&2
}
# ================================
# Cloudflare ECH 检测 (可选特性)
#
# 这里只**读取** ECH 状态, 不再自己调 Cloudflare API 去改配置。
# 开启 ECH 由独立的 cf-manager 负责 (之后单独配置), 本脚本不持有也不索要
# Cloudflare API Key —— 既避免把 Global API Key 落在 conf/.cf_api_key,
# 也避免"面板顺带改你的 DNS/ECH 设置"这种副作用。
#
# 输出: CF_ECH_READY=true 表示 ECH 已在 Cloudflare 侧生效
# =============================================================

cf_ech_ensure() {
    local domain="$1"
    local email key zone_id ech_status

    # 0. 优先使用 cf-manager 短链 (幂等, 已开则提示 already enabled 退出 0)
    # 注意: 必须直接调用 cfmgr 而不是 $(cfmgr) —— 命令替换在子 shell 执行, 会丢掉 CFMGR 赋值
    if cfmgr; then
        print_info "通过 cf-manager 开启 ECH: $domain"
        if "$CFMGR" -E "$domain"; then
            print_ok "Cloudflare ECH 已确认开启 (cf-manager)"
            CF_ECH_READY=true
            return 0
        else
            print_warn "cf-manager 开启 ECH 失败"
        fi
    else
        print_warn "未找到 cf-manager"
    fi

    print_info "ECH 需要由 cf-manager 单独开启; 本脚本只读状态, 不再代改 Cloudflare 配置"
    print_info "请先配置 cf-manager 后重新执行, 或先用普通 TLS 建节点 (不影响出网)"
    return 1
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
            -subj "/CN=vless-client-$idx" >/dev/null 2>&1
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
# 纯 TLS 模式证书来源选择
#   1) 已有证书 (ssl.sh 申请, /root/catmi/<域名>.crt|.key)
#   2) 现在调用 ssl.sh 申请
#   3) 自签证书 (兜底)
# 输出: CERT_FILE / KEY_FILE / CERT_DOMAIN
# ================================

# ================================
# v2 修复: 从入站配置提取前端/接入域名
# 优先读注释 "# server-name:" (add_config 阶段人工确认的真实访问域名)
# 兜底兼容旧片段: 安全路径证书名剥去 cert-<编号>- / cert- 前缀 (避免旧 bug 碎名)
# ================================
extract_server_name() {
    local f="$1"
    local domain=""
    domain=$(grep -oE "^[[:space:]]*# server-name: [^[:space:]]+" "$f" 2>/dev/null | head -1 | awk '{print $3}')
    if [[ -z "$domain" ]]; then
        local cert
        cert=$(grep -E "certificate:" "$f" | awk '{print $2}')
        domain=$(basename "$cert" .crt | sed -E 's/^cert-[0-9]+-//; s/^cert-//')
    fi
    echo "$domain"
}

# ================================
# 新增 VLESS 配置
# ================================
add_config() {
    print_title "新增 VLESS 配置"

    # 1. 自动生成 UUID (VLESS 用 uuid)
    UUID=$(cat /proc/sys/kernel/random/uuid)

    # 2. 自动生成端口
    default_port=$(random_port)
    # 必须检查返回值: m_safe_read_port 在 stdin 关闭 (EOF) 时返回 1 且不输出,
    # 不检查就会写出一个 `port:` 为空的死节点, 而校验链全放行
    VLESS_PORT=$(safe_read_port "$default_port") || {
        print_error "未指定端口, 已取消创建"
        return 1
    }
    [[ -n "$VLESS_PORT" ]] || { print_error "端口为空, 已取消创建"; return 1; }

    # 3. 自动编号
    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # 4. 获取服务器 IP (交互确认)
    print_info "检测服务器公网 IP..."
    SERVER_IP=$(detect_public_ip)

    if [[ -z "$SERVER_IP" ]]; then
        print_error "获取公网 IP 失败, 节点无 IP 无法生成分享链接"
        return 1
    fi

    if [[ "$SERVER_IP" =~ : ]]; then
        LINK_IP="[$SERVER_IP]"
    else
        LINK_IP="$SERVER_IP"
    fi

    # 4.5 先问"要哪种推荐配置" —— 一路回车 = ① 推荐档 (抗 DPI 最强那档)。
    #     不设这个的话, 后面全是逐项提问, 默认值拼出来的东西能用但称不上好。
    preset_ask vless "VLESS 推荐配置"

    # 5. 询问特性 (传输五选一 / xhttp 档位 / 指纹 / smux / mTLS / ECH)
    #    ⚠ 这里**不能**提前 preset_reset —— 它会把 M_PRESET_APPLIED 和
    #    M_PRESET_TR 一并清掉, 而 ask_features 正是靠这两个值跳过提问的。
    #    早清一次的表现是"菜单里选了推荐档, 结果传输还是问了一遍" ——
    #    预置形同虚设, 而且不报任何错。
    ask_features
    preset_reset   # ← 消费完才清, 下一个节点才不会继承上一个的选择

    # 6. TLS 证书来源 (VLESS 恒 TLS, 无 Reality 分支)
    ask_cert

    # 6.1 证书归位 (mihomo SAFE_PATHS 修复): 无论证书来源, 统一复制到 conf/certs
    #     并改写路径, 否则 mihomo 拒绝 conf 目录外证书 → listener 不启动 (通用 bug)
    if [[ -n "$CERT_FILE" && -f "$CERT_FILE" && -n "$KEY_FILE" && -f "$KEY_FILE" ]]; then
        local _cfn _safe_crt _safe_key
        _cfn=$(basename "$CERT_FILE")
        _safe_crt="$CERT_DIR/cert-$index-$_cfn"
        _safe_key="$CERT_DIR/cert-$index-$(basename "$KEY_FILE")"
        mkdir -p "$CERT_DIR"
        if cp -f "$CERT_FILE" "$_safe_crt" 2>/dev/null && cp -f "$KEY_FILE" "$_safe_key" 2>/dev/null; then
            if [[ "$CERT_FILE" != "$_safe_crt" ]]; then
                CERT_FILE="$_safe_crt"
                KEY_FILE="$_safe_key"
                print_ok "证书已复制到 mihomo 安全路径: $CERT_DIR/"
            fi
        else
            print_warn "证书复制失败, 使用原路径 (若 mihomo 拒绝请手动复制到 $CERT_DIR/)"
        fi
    fi

    # 7. 传输路径 (随机 8-16 位, 抗识别)
    WS_PATH="/$(random_path)"
    XHTTP_PATH="/$(random_path)"
    H2_PATH="/$(random_path)"
    # gRPC service name: 内核按 "/"+name+"/Tun" 组装实际 HTTP/2 路径
    #   (transport/gun/gun.go:325-330), 名字本身随便取, 转小写避免大小写敏感的路由歧义
    GRPC_SERVICE=$(random_path | tr '[:upper:]' '[:lower:]')
    XHTTP_MODE="auto"
    CF_ECH_READY=false

    # 7.1 接入/前端域名 (nginx server_name 或 CF zone 指向的域名)
    #     v2 修复: 客户端 server/sni 不再直接信任证书 CN/CN 文件名, 必须显式确认并持久化。
    printf "请输入访问域名 (客户端 server/sni 使用, 默认: %s): " "$CERT_DOMAIN" >&2
    read -r front_domain
    front_domain=$(clean_input "$front_domain" | tr '[:upper:]' '[:lower:]')
    FRONT_DOMAIN=${front_domain:-$CERT_DOMAIN}

    # 8. 可选: mTLS 证书
    if $MTLS_ENABLED; then
        gen_mtls_cert "$index"
    fi

    # 9. 可选: ECH (Cloudflare 检测/开启)
    CF_ECH_READY=false
    CLIENT_SNI="$CERT_DOMAIN"
    if $ECH_ENABLED; then
        print_info "ECH 已选择, 正在检查 Cloudflare 侧配置..."
        # 优化: 先检测域名是否已开启 ECH; 已开启则跳过开启步骤 (cf-manager ech status)
        if cfmgr && "$CFMGR" ech status "$CERT_DOMAIN" --json 2>/dev/null | grep -q '"ech":"on"'; then
            print_ok "域名 $CERT_DOMAIN 已开启 ECH (检测确认), 跳过开启步骤"
            CF_ECH_READY=true
        else
            cf_ech_ensure "$CERT_DOMAIN" || true
        fi
        # ECH 模式: SNI 保持真实域名, mihomo ech-opts 自动将外层 SNI 伪装为 cloudflare-ech.com
        CLIENT_SNI="$CERT_DOMAIN"
    fi

    # 9.1 可选: DNS 绑定域名到本机 IP (cf-manager: 橙云/CDN 或灰云直连)
    # Bug7 fix: 自签兜底 CERT_DOMAIN=cloudflare.com 占位名, 不询问绑定 (避免误导)
    if [[ "$ECH_ENABLED" = true || -n "$CERT_DOMAIN" ]] && [[ "$CERT_DOMAIN" != "cloudflare.com" ]]; then
        local yn
        echo "  是否将域名 $CERT_DOMAIN 的 DNS 绑定到本机 IP ($SERVER_IP)？(y/N)" >&2
        read -r yn
        if [[ "$(clean_input "$yn")" =~ ^[yY]$ ]]; then
            if cfmgr; then
                echo "  DNS 记录代理模式:" >&2
                echo "  1) 橙云 (CDN 代理, 默认)" >&2
                echo "  2) 灰云 (仅 DNS 直连)" >&2
                printf "  选择 (默认1): " >&2
                read -r yn
                local proxy_mode="on"
                case "$(clean_input "$yn")" in
                    2) proxy_mode="off" ;;
                esac
                if "$CFMGR" -A "$CERT_DOMAIN" "$SERVER_IP" --proxy "$proxy_mode"; then
                    print_ok "DNS 绑定成功: $CERT_DOMAIN -> $SERVER_IP (cf-manager)"
                else
                    print_warn "DNS 绑定失败, 节点仍会生成, 请稍后手动处理"
                fi
            else
                print_warn "未找到 cf-manager, 跳过 DNS 绑定"
            fi
        fi
    fi

    # 客户端接入地址: 有真域名就用域名, 只有自签证书时必须落到服务器 IP
    CLIENT_HOST=$(m_client_host "$CERT_DOMAIN")

    render_smux
    render_mux_option
    render_xhttp_pad
    render_transport

    # 9.5 监听地址: cdn -> 0.0.0.0, nginx -> 127.0.0.1 (仅本机经 nginx 接入)
    LISTEN_ADDR="0.0.0.0"
    [[ "$ACCESS_MODE" = "nginx" ]] && LISTEN_ADDR="127.0.0.1"

    # 10. 写入入站配置 (Nginx 片段无论何种模式都生成)
    # INDEX 供 render_nginx_conf / render_listener_frag / render_client_yaml / render_share_link 复用
    INDEX="$index"
    # NODE_TAG 是这条节点的唯一身份, 四个渲染出口全部用它, 保证
    # 分享链接 / listener / proxy / 列表显示是同一个名字。
    # VLESS.sh 本身只做 TLS 形态, 所以形态参数固定 tls。
    NODE_TAG="$(m_node_tag VLESS "$index" tls)"
    render_nginx_conf

    render_listener_frag

    # 11. 写入客户端配置 + 分享链接
    render_client_yaml
    render_share_link
    echo "$SHARE_LINK" > "$SHARE_FILE"

    # 12. 输出信息
    print_ok "VLESS 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $VLESS_PORT" >&2
    echo -e "UUID: $UUID" >&2
    case "$VLESS_TRANSPORT" in
        xhttp) echo -e "传输: xhttp (路径: $XHTTP_PATH, 抗探测档位: $XHTTP_LEVEL)" >&2 ;;
        grpc)  echo -e "传输: grpc (service-name: $GRPC_SERVICE)" >&2 ;;
        h2)    echo -e "传输: h2 (路径: $H2_PATH)" >&2 ;;
        tcp)   echo -e "传输: 裸 TCP" >&2 ;;
        *)     echo -e "传输: ws (路径: $WS_PATH)" >&2 ;;
    esac
    echo -e "客户端指纹: $CLIENT_FP" >&2
    echo -e "域名: $CERT_DOMAIN" >&2
    $MTLS_ENABLED && echo -e "mTLS: 已启用 (客户端证书: $CERT_DIR/mtls-$PROTO-$index/)" >&2
    $ECH_ENABLED && echo -e "ECH: 已启用 (Cloudflare: ${CF_ECH_READY:-未确认})" >&2 || true
    _smux_on "${SMUX_PROFILE-}" && echo -e "smux: 已启用 ($SMUX_PROFILE 档$(_smux_on "${BRUTAL_ENABLED-}" && echo ", brutal $BRUTAL_UP/$BRUTAL_DOWN"))" >&2
    echo -e "入站配置: $IN_FILE" >&2
    echo -e "客户端配置: $OUT_FILE" >&2
    echo -e "分享链接: $SHARE_FILE" >&2
}

# ================================
# 查看 VLESS 配置
# ================================
list_configs() {
    print_title "VLESS 配置列表"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有找到任何 VLESS 配置"
        return
    fi

    for f in "${files[@]}"; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        port=$(grep -E "^[[:space:]]*port:" "$f" | awk '{print $2}')
        uuid=$(grep -E "uuid:" "$f" | head -1 | awk '{print $2}' | tr -d ' ')
        transport=$(grep -oE "^[[:space:]]*# transport: (ws|xhttp|grpc|h2|tcp)" "$f" | awk '{print $3}')
        transport=${transport:-ws}

        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET}  " "$port" >&2
        printf "传输:${MAGENTA}%s${RESET}  " "$transport" >&2
        printf "UUID:${WHITE}%s${RESET}\n" "$uuid" >&2
    done
}

# ================================
# 删除 VLESS 配置
# ================================
delete_config() {
    print_title "删除 VLESS 配置"

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

    # 删除 VLESS 相关文件
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

    # VLESS 无 Reality, 无 public-key 文件需要清理

    print_ok "已删除 VLESS 配置 $num"
}

# ================================================================
# 从服务端片段重建单个节点的客户端 YAML + 分享链接
# 菜单项 4 与「导出订阅」共用, 保证两条路径永远产出同一份配置
# 输出: SHARE_LINK ; 写入 $OUT_FILE 与 $SHARE_FILE
# ================================================================
rebuild_one() {
    local n="$1"
    IN_FILE="$CONF_DIR/$PROTO-$n.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$n.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$n.txt"
    [[ -f "$IN_FILE" ]] || return 0

    UUID=$(grep -E "uuid:" "$IN_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
    VLESS_PORT=$(grep -E "^[[:space:]]*port:" "$IN_FILE" | awk '{print $2}')

    read_features "$IN_FILE"

    # 传输参数回读 (服务端片段是唯一真源):
    #   ws -> ws-path ; xhttp -> xhttp-config.mode/path ; grpc -> grpc-service-name
    #   h2 -> listener 侧无字段, 路径只存在 # h2-path 注释 (read_features 已读)
    #   tcp -> 两侧都没有
    WS_PATH=$(awk '/^[[:space:]]*ws-path:/{print $2; exit}' "$IN_FILE")
    XHTTP_PATH=$(awk '/xhttp-config:/{f=1;next} f && $1=="path:"{print $2; exit}' "$IN_FILE")
    XHTTP_MODE=$(awk '/xhttp-config:/{f=1;next} f && $1=="mode:"{print $2; exit}' "$IN_FILE")
    GRPC_SERVICE=$(awk '/^[[:space:]]*grpc-service-name:/{print $2; exit}' "$IN_FILE")
    # x-padding 密钥必须与服务端是同一个, 只能从片段里取
    XHTTP_PAD_KEY=$(grep -oE "x-padding-key: [^[:space:]]+" "$IN_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    [[ -z "$XHTTP_MODE" ]] && XHTTP_MODE="auto"
    apply_xhttp_level
    if $XHTTP_PAD_OBFS && [[ -z "$XHTTP_PAD_KEY" ]]; then
        print_warn "片段中缺少 x-padding-key (档位 $XHTTP_LEVEL), 已重新生成; 请同步更新服务端 xhttp-config"
        XHTTP_PAD_KEY=$(random_pad_key)
        render_xhttp_pad
    fi

    server_name="$(extract_server_name "$IN_FILE")"
    cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
    CERT_DOMAIN=${server_name:-$(basename "$cert" .crt | sed -E 's/^cert-[0-9]+-//; s/^cert-//')}
    CLIENT_SNI="$CERT_DOMAIN"
    CLIENT_HOST=$(m_client_host "$CERT_DOMAIN")
    LISTEN_ADDR="0.0.0.0"
    [[ "$ACCESS_MODE" = "nginx" ]] && LISTEN_ADDR="127.0.0.1"

    if $MTLS_ENABLED; then
        MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$n/client.pem")
        MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$n/client.key")
    fi

    SERVER_IP=$(m_server_ip)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

    INDEX="$n"
    NODE_TAG="$(m_node_tag VLESS "$n" tls)"
    render_smux
    render_mux_option
    render_transport
    render_nginx_conf

    render_client_yaml
    render_share_link
    echo "$SHARE_LINK" > "$SHARE_FILE"
}

# ================================
# 手动重建客户端文件
# ================================
rebuild_client() {
    print_title "重建 VLESS 客户端文件"

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

    rebuild_one "$num2"

    print_ok "客户端文件已重建：$num2"

    echo -e "\n${CYAN}===== 客户端 YAML =====${RESET}"
    cat "$OUT_FILE"

    echo -e "\n${CYAN}===== 分享链接 =====${RESET}"
    echo "$SHARE_LINK"
}

# ================================
# 静默重建（订阅用）
# ================================
# ================================
# 查看所有节点的 Nginx 转发配置 (面板菜单 6)
# ================================
view_nginx_conf() {
    print_title "Nginx 转发配置"

    local found=false
    local f
    for f in "$OUT_DIR"/${PROTO}_nginx-*.conf; do
        [[ -f "$f" ]] || continue
        found=true
        echo -e "\n${CYAN}===== $(basename "$f") =====${RESET}" >&2
        cat "$f" >&2
    done

    if ! $found; then
        print_warn "暂无生成的 Nginx 配置片段 (请先在新增配置时生成)"
        # 尝试从 config.d 重建
        local num nginx_file
        for f in "$CONF_DIR"/$PROTO-*.yaml; do
            [[ -f "$f" ]] || continue
            num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
            nginx_file="$OUT_DIR/${PROTO}_nginx-$num.conf"
            if [[ ! -f "$nginx_file" ]]; then
                rebuild_client_silent "$num"
                [[ -f "$nginx_file" ]] && { echo -e "\n${CYAN}===== $(basename "$nginx_file") =====${RESET}" >&2; cat "$nginx_file" >&2; }
            fi
        done
    fi
    echo -e "\n${YELLOW}提示: 将片段放入 nginx conf.d 里站点配置的 server{} 块中即可${RESET}" >&2
}

rebuild_client_silent() {
    rebuild_one "$1"
}

# ================================
# 导出订阅
# ================================
export_subscription() {
    print_title "导出所有 VLESS 节点订阅（展开格式）"

    SUB_FILE="$OUT_DIR/vless_subscribe.yaml"
    echo "# VLESS 全节点订阅（自动生成）" > "$SUB_FILE"
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
# vless-$num2
# ============================
$(grep -v "^proxies:" "$CLIENT_FILE" | grep -v "^# ECH:" | sed 's/^/  /')

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
        print_title "Mihomo VLESS 管理面板"

        ui_menu 1 "查看配置"
        ui_menu 2 "新增配置"
        ui_menu 3 "删除配置"
        ui_menu 4 "重建客户端文件"
        ui_menu 5 "导出所有节点订阅（Clash/Mihomo）"
        ui_menu 6 "查看 Nginx 转发配置"
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
            6) view_nginx_conf ;;
            0) exit 0 ;;
            *) ui_invalid "$c" ;;
        esac

        printf "按回车继续..." >&2
        read || break
    done
}
# 带 add 参数 = 直接进新增向导 (从「添加节点」进来时的路径), 不进管理面板。
case "${1:-}" in
    add|"")
        if [[ "${1:-}" == "add" ]]; then
            add_config; m_sync_reload
            exit 0
        fi
        ;;
esac
main_menu
