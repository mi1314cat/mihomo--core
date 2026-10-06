#!/bin/bash
# TUICv5 管理脚本（独立子配置 + 客户端 + 订阅）
# 子配置:   conf/config.d/tuicv5-XX.yaml
# 客户端:   out/tuicv5_client-XX.yaml
# 分享链接: out/tuicv5_share-XX.txt

set -o errexit
set -o nounset
set -o pipefail

# ================================
# 彩色
# ================================
# UI 原语统一来自 src/lib/ui.sh (颜色/消息分级/标题), 此处不再重复定义。
# 被父级 source 时已加载; 单独运行时由下面的兜底 source 补上。

# 基础路径
# ================================
PROTO="tuicv5"
BASE_DIR="/root/catmi/mihomo"

CONF_ROOT="$BASE_DIR/conf"
CONF_DIR="$CONF_ROOT/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$CONF_ROOT/certs"


# ---------- 共享库 (src/lib/env.sh) ----------
# 提供: 路径常量 / 环境变量读写 / Reality dest 选择 / 合并+严格校验+重载闭环
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRV_ROOT="$BASE_DIR"
MIHOMO_BIN="$BASE_DIR/mihomo"
source "$SELF_DIR/../lib/env.sh"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR"

# ================================
# 端口工具
# ================================
port_in_use() { m_port_listening "$1"; }

random_port() { shuf -i 10000-60000 -n 1; }

random_free_port() {
    while true; do
        local port
        port=$(random_port)
        if ! port_in_use "$port"; then echo "$port"; return; fi
    done
}

safe_read_port() {
    # 六份重复实现已收敛到 env.sh 的 m_safe_read_port:
    #   拒绝 1-1023 特权端口与系统常用端口, TCP/UDP 双查占用, EOF 安全退出。
    m_safe_read_port "$1"
}

# ================================================================
# 选配 (M 内核 / mihomo v1.19.32 特有字段)
# 每条都标了内核源码位置; 没有源码依据的一律不做。
# ================================================================

# ---------- ① congestion-controller ----------
#   proxy   : adapter/outbound/tuic.go:48
#   listener: listener/inbound/tuic.go:21 (内核默认 "bbr", listener/parse.go:130)
#   合法值: cubic / new_reno / bbr / bbr_meta_v1 / bbr_meta_v2
#           transport/tuic/common/congestion.go:20-53 —— switch **无 default 分支**,
#           写错值不报错, 静默保留内核默认。必须从枚举里选。
#   ⚠ 两侧要一致, 否则客户端算的拥塞窗口和服务端对不上。
CC_PROFILE="bbr"

# ---------- ② udp-relay-mode (仅客户端) ----------
#   adapter/outbound/tuic.go:47
#   合法值: native (默认) / quic。
#   ⚠ 判断是 `if option.UdpRelayMode != "quic"` —— **写错字静默落 native**
#     (adapter/outbound/tuic.go:165-168)。listener 侧没有这个字段。
UDP_RELAY="native"

# ---------- ③ reduce-rtt = TUIC 的 0-RTT 开关 (仅客户端) ----------
#   adapter/outbound/tuic.go:45 → DialQuicOption{Early: ...} (:114)
#   降首包延迟, 代价是失去前向保密; 服务端固定 Allow0RTT=true
#   (listener/tuic/server.go:102), 所以客户端默认关即可。
REDUCE_RTT=false

# ---------- ④ heartbeat-interval (仅客户端, 毫秒) ----------
#   adapter/outbound/tuic.go:43; <=0 时内核回落 10000 (:161-163)
HEARTBEAT_MS="10000"

ask_uint_ms() {
    local p="$1" d="$2" input v
    while true; do
        printf "%s (默认: %s): " "$p" "$d" >&2
        read -r input || { printf "\n[信息] 非交互环境, 已退出\n" >&2; return 1; }
        input=$(printf '%s' "$input" | tr -d '\000-\037' | tr -d '[:space:]')
        v="${input:-$d}"
        [[ "$v" =~ ^[0-9]+$ ]] || { print_error "请输入正整数 (单位毫秒)"; continue; }
        (( v <= 0 )) && { print_error "必须 > 0 (<=0 内核会静默回落 10000ms)"; continue; }
        printf '%s' "$v"
        return 0
    done
}

ask_tuic_opts() {
    echo "  拥塞控制 congestion-controller (两侧必须一致):" >&2
    echo "  1) bbr (默认; 也是内核 listener 默认值, listener/parse.go:130)" >&2
    echo "  2) bbr_meta_v2" >&2
    echo "  3) cubic" >&2
    echo "  4) new_reno" >&2
    printf "  选择 (默认1): " >&2
    local c=""
    read -r c || c=""
    c=$(clean_input "$c")
    case "$c" in
        2) CC_PROFILE="bbr_meta_v2" ;;
        3) CC_PROFILE="cubic" ;;
        4) CC_PROFILE="new_reno" ;;
        *) CC_PROFILE="bbr" ;;
    esac

    echo "  UDP 中继模式 udp-relay-mode (仅客户端; 写错字会静默落 native):" >&2
    echo "  1) native (默认, UDP 报文直传)" >&2
    echo "  2) quic (走 QUIC DATAGRAM)" >&2
    printf "  选择 (默认1): " >&2
    read -r c || c=""
    c=$(clean_input "$c")
    if [[ "$c" == "2" ]]; then UDP_RELAY="quic"; else UDP_RELAY="native"; fi

    read -r -p "  启用 0-RTT (reduce-rtt)? 降首包延迟, 但会失去前向保密 (默认否, y/N): " c || c=""
    if [[ "$(clean_input "$c")" =~ ^[yY]$ ]]; then REDUCE_RTT=true; else REDUCE_RTT=false; fi

    HEARTBEAT_MS=$(ask_uint_ms "  心跳间隔 heartbeat-interval (毫秒)" "10000") || HEARTBEAT_MS="10000"
}

# 从子配置读回选配 (重建/导出保持一致); 缺字段一律回落内核默认
# ⚠ congestion-controller 是 listener 真实字段, 直接读;
#   udp-relay-mode / reduce-rtt / heartbeat-interval 是 **仅客户端** 字段
#   (listener/inbound/tuic.go:12-28 没有), 只能靠切片顶部的注释行持久化
#   —— 与 AnyTLS/Reality 的 "# smux: x" 同一套路。
read_tuic_opts() {
    local f="$1" v=""
    # ⚠ 本文件开了 `set -o errexit -o pipefail`; grep 无命中时退出码 1 会让整脚本退出,
    #   所以每条读取都必须 `|| true` —— 否则老配置 (没有这些注释行) 重建时直接崩。
    v=$(grep -E '^[[:space:]]*congestion-controller:' "$f" | head -1 | awk '{print $2}') || true
    CC_PROFILE="${v:-bbr}"
    v=$(grep -E '^[[:space:]]*# udp-relay-mode:' "$f" | head -1 | sed -E 's/.*# udp-relay-mode:[[:space:]]*//') || true
    UDP_RELAY="${v:-native}"
    if grep -qE '^[[:space:]]*# reduce-rtt:[[:space:]]*true' "$f"; then
        REDUCE_RTT=true
    else
        REDUCE_RTT=false
    fi
    v=$(grep -E '^[[:space:]]*# heartbeat-interval:' "$f" | head -1 | sed -E 's/.*# heartbeat-interval:[[:space:]]*//') || true
    HEARTBEAT_MS="${v:-10000}"
    return 0
}

# 客户端选配块 (仅 proxy 侧字段)
render_tuic_proxy_opts() {
    echo "    congestion-controller: $CC_PROFILE"
    echo "    udp-relay-mode: $UDP_RELAY"
    echo "    heartbeat-interval: $HEARTBEAT_MS"
    [[ "$REDUCE_RTT" == true ]] && echo "    reduce-rtt: true"
    return 0
}

# ================================
# 编号系统
# ================================
get_next_index() {
    local used=() i=1

    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.yaml; do
        local base
        base=$(basename "$f")
        if [[ "$base" =~ ^${PROTO}-([0-9]+)\.yaml$ ]]; then
            used+=("${BASH_REMATCH[1]}")
        fi
    done

    if ((${#used[@]} == 0)); then
        printf "%02d\n" 1
        return
    fi

    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done

    printf "%02d\n" "$i"
}

# ================================
# IP 检测
# ================================
detect_listen_ip_mode() {
    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true || has_ipv4=false
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true || has_ipv6=false

    $has_ipv4 && ! $has_ipv6 && echo "ipv4" && return
    ! $has_ipv4 && $has_ipv6 && echo "ipv6" && return
    $has_ipv4 && $has_ipv6 && echo "dual" && return
    echo "none"
}

choose_listen_ip() {
    local detect="$1"
    print_info "检测结果: $detect"

    ui_menu 1 "IPv4 (0.0.0.0)"
    ui_menu 2 "IPv6 (::)"
    ui_menu 3 "自动"

    printf "选择 (默认1): " >&2
    read -r choice
    choice=$(clean_input "$choice")

    case "$choice" in
        2) echo "::" ;;
        3)
            case "$detect" in
                ipv6) echo "::" ;;
                *) echo "0.0.0.0" ;;
            esac ;;
        *) echo "0.0.0.0" ;;
    esac
}

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
# 新增配置
# ================================
add_config() {
    print_title "新增 tuicv5 配置"

    local detect listen_ip port domain PUBLIC_IP index IN_FILE OUT_FILE SHARE_FILE
    local uuid pass

    detect=$(detect_listen_ip_mode)
    listen_ip=$(choose_listen_ip "$detect")

    # 必须检查返回值: m_safe_read_port 在 stdin 关闭 (EOF) 时返回 1 且不输出,
    # 不检查就会写出一个 `port:` 为空的死节点, 而校验链全放行
    port=$(safe_read_port "$(random_free_port)") || {
        print_error "未指定端口, 已取消创建"
        return 1
    }
    [[ -n "$port" ]] || { print_error "端口为空, 已取消创建"; return 1; }

    PUBLIC_IP=$(detect_public_ip)

    # 证书走统一菜单 —— 与 Trojan / VLESS / hysteria2 / AnyTLS 一致。
    #
    # 原来这里自己问一句"证书域名 (默认: bing.com)"再调本文件的
    # generate_self_signed_cert: RSA2048 / 365 天 / **无 basicConstraints** / 无 SAN。
    # 无 basicConstraints 时 openssl 默认打 CA:TRUE, 于是这张**服务端**证书会被
    # 我们自己的 cert_is_ca 过滤器判成 CA 而排除 —— 别的协议扫描本机证书时
    # 根本看不到它; 而它又没有 SAN, 现代客户端也会拒。
    # 统一走 ask_cert 之后: 有真证书的机器上能直接选真证书 (旧实现永远只会自签),
    # 自签时也拿到 ECDSA P-256 + CA:FALSE + SAN 的正规叶子证书。
    ask_cert || { print_error "证书选择失败, 已取消创建"; return 1; }
    domain="$CERT_DOMAIN"

    index=$(get_next_index)

    uuid=$(uuidgen)
    pass=$(openssl rand -hex 12)

    # ---- 选配: 拥塞控制 / UDP 中继 / 0-RTT / 心跳 ----
    ask_tuic_opts

    IN_FILE="$CONF_DIR/${PROTO}-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    NODE_TAG="$(m_node_tag TUIC "$index" tls)"
    cat > "$IN_FILE" <<EOF
# udp-relay-mode: $UDP_RELAY
# reduce-rtt: $REDUCE_RTT
# heartbeat-interval: $HEARTBEAT_MS
listeners:
  - name: $NODE_TAG
    type: tuic
    port: $port
    listen: "$listen_ip"
    users:
      $uuid: $pass
    certificate: $CERT_FILE
    private-key: $KEY_FILE
    congestion-controller: $CC_PROFILE
    max-idle-time: 15000
    authentication-timeout: 1000
    alpn:
      - h3
    max-udp-relay-packet-size: 1500
EOF

    NODE_TAG="$(m_node_tag TUIC "$num" tls)"
    cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: tuic
    server: $PUBLIC_IP
    port: $port
    uuid: $uuid
    password: $pass
    sni: $domain
$(render_tuic_proxy_opts)
    skip-cert-verify: true
    alpn:
      - h3
EOF

    echo "tuic://$uuid:$pass@$PUBLIC_IP:$port?sni=$domain&alpn=h3&insecure=1&allowInsecure=1&congestion_control=$CC_PROFILE#TUICv5-$index" > "$SHARE_FILE"

    print_ok "已创建子配置: $IN_FILE"
    print_ok "客户端文件: $OUT_FILE"
    print_ok "分享文件: $SHARE_FILE"
    print_ok "拥塞控制: $CC_PROFILE | UDP 中继: $UDP_RELAY | 0-RTT: $REDUCE_RTT | 心跳: ${HEARTBEAT_MS}ms"
}

# ================================
# 列表
# ================================
list_configs() {
    print_title "TUICv5 配置列表"

    shopt -s nullglob
    local files=("$CONF_DIR"/${PROTO}-*.yaml)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "无配置"
        return
    fi

    IFS=$'\n' files=($(printf "%s\n" "${files[@]}" | sort))

    for f in "${files[@]}"; do
        name=$(basename "$f")

        if [[ "$name" =~ ^${PROTO}-([0-9]+)\.yaml$ ]]; then
            num="${BASH_REMATCH[1]}"
            num2=$(printf "%02d" "$num")
        else
            continue
        fi

        port=$(grep -E '^[[:space:]]*port:' "$f" | head -1 | awk -F: '{gsub(/ /,"",$2); print $2}')
        uuid=$(grep -E '^[[:space:]]*[0-9a-fA-F-]{36}:' "$f" | awk -F: '{print $1}' | tr -d ' ')
        pass=$(grep -E '^[[:space:]]*[0-9a-fA-F-]{36}:' "$f" | awk -F: '{print $2}' | tr -d ' ')
        cc=$(grep -E 'congestion-controller:' "$f" | awk '{print $2}')
        cert=$(grep -E 'certificate:' "$f" | awk '{print $2}')
        domain=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

        printf "${GREEN}%s${RESET}) " "$num2" >&2
        printf "端口:${BLUE}%-6s${RESET} " "$port" >&2
        printf "UUID:${MAGENTA}%-36s${RESET} " "$uuid" >&2
        printf "密码:${YELLOW}%-32s${RESET} " "$pass" >&2
        printf "CC:${CYAN}%-6s${RESET} " "${cc:-bbr}" >&2
        printf "SNI:${WHITE}%s${RESET}\n" "$domain" >&2
    done
}

# ================================
# 删除
# ================================
delete_config() {
    print_title "删除 tuicv5 配置"

    list_configs
    printf "\n输入编号: " >&2
    read -r num_raw
    num=$(printf "%02d" "$num_raw")

    IN_FILE="$CONF_DIR/${PROTO}-$num.yaml"

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "不存在: $IN_FILE"
        return
    fi

    read -r -p "确认删除? (y/N): " c

    if [[ "$c" =~ ^[yY]$ ]]; then
        # 删前记下这个节点用的证书 —— 多个节点常常共用同一份证书,
        # 删完再判断还有没有人用, 没人用才回收 (见 env.sh m_cert_gc)
        local old_cert=""
        if [[ -f "$CONF_DIR/${PROTO}-$num.yaml" ]]; then
            old_cert=$(grep -m1 -oE '(certificate|ca):[[:space:]]*[^[:space:]#]+' \
                          "$CONF_DIR/${PROTO}-$num.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//')
        fi
        # 删除节点时同步清理它的 Nginx 回源配置并 reload。
        # 键用片段文件名 (tuicv5-01), 与创建时登记的一致;
        # 没有 CDN 绑定的节点这里直接返回 0, 不会有副作用。
        cdn_node_unregister "$(basename "$IN_FILE" .yaml)" 2>/dev/null || true

        rm -f "$CONF_DIR/${PROTO}-$num.yaml" \
              "$OUT_DIR/${PROTO}_client-$num.yaml" \
              "$OUT_DIR/${PROTO}_share-$num.txt"

        # 记下"这次删掉的是哪个协议桶", 供菜单项在**重载成功之后**吊销分享链接。
        # 不能在这里直接吊销: 重载失败会回滚, 那时节点还在, 链接却已经废了
        # (清空路径 server.sh 里记过这个反序踩坑)。
        # 注意 PROTO 是 tuicv5 —— 分享 tag 取的就是它, 不是 "tuic"。
        _DELETED_PROTO_TAG="$PROTO"

        # 已删干净? 原来不管删没删掉都报"已删除"
        if [[ -e "$CONF_DIR/${PROTO}-$num.yaml" ]]; then
            print_error "删除失败, 文件仍在: $CONF_DIR/${PROTO}-$num.yaml"
        else
            print_ok "已删除 TUIC 配置 $num"
        fi
        [[ -n "$old_cert" ]] && m_cert_gc "$old_cert"
    else
        print_info "已取消删除"
    fi
}

# ================================
# 重建客户端文件（展开）
# ================================
rebuild_client() {
    print_title "重建 TUICv5 客户端文件"

    list_configs

    printf "\n请输入要重建的编号: " >&2
    read -r num_raw
    num=$(printf "%02d" "$num_raw")

    IN_FILE="$CONF_DIR/${PROTO}-$num.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num.txt"

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$num"
        return
    fi

    port=$(grep -E '^[[:space:]]*port:' "$IN_FILE" | awk -F: '{gsub(/ /,"",$2); print $2}')
    uuid=$(grep -E '^[[:space:]]*[0-9a-fA-F-]{36}:' "$IN_FILE" | awk -F: '{print $1}' | tr -d ' ')
    pass=$(grep -E '^[[:space:]]*[0-9a-fA-F-]{36}:' "$IN_FILE" | awk -F: '{print $2}' | tr -d ' ')
    cert=$(grep -E 'certificate:' "$IN_FILE" | awk '{print $2}')
    domain=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

    # 选配: 读回 congestion-controller / udp-relay-mode / reduce-rtt / heartbeat
    read_tuic_opts "$IN_FILE"

    SERVER_IP=$(m_server_ip)

NODE_TAG="$(m_node_tag TUIC "$num" tls)"
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: tuic
    server: $SERVER_IP
    port: $port
    uuid: $uuid
    password: $pass
    sni: $domain
$(render_tuic_proxy_opts)
    skip-cert-verify: true
    alpn:
      - h3
EOF

    SHARE_LINK="tuic://$uuid:$pass@$SERVER_IP:$port?sni=$domain&alpn=h3&insecure=1&allowInsecure=1&congestion_control=$CC_PROFILE#TUICv5-$num"
    echo "$SHARE_LINK" > "$SHARE_FILE"

    print_ok "客户端文件已重建：$num"

    echo -e "\n${CYAN}===== 客户端 YAML =====${RESET}"
    cat "$OUT_FILE"

    echo -e "\n${CYAN}===== 分享链接 =====${RESET}"
    echo "$SHARE_LINK"

   
}

# ================================
# 静默重建（订阅用）
# ================================
rebuild_client_silent() {
    local num="$1"
    num=$(printf "%02d" "$num")

    IN_FILE="$CONF_DIR/${PROTO}-$num.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num.txt"

    [[ -f "$IN_FILE" ]] || return 0

    port=$(grep -E '^[[:space:]]*port:' "$IN_FILE" | awk -F: '{gsub(/ /,"",$2); print $2}')
    uuid=$(grep -E '^[[:space:]]*[0-9a-fA-F-]{36}:' "$IN_FILE" | awk -F: '{print $1}' | tr -d ' ')
    pass=$(grep -E '^[[:space:]]*[0-9a-fA-F-]{36}:' "$IN_FILE" | awk -F: '{print $2}' | tr -d ' ')
    cert=$(grep -E 'certificate:' "$IN_FILE" | awk '{print $2}')
    domain=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

    # 选配: 读回 congestion-controller / udp-relay-mode / reduce-rtt / heartbeat
    read_tuic_opts "$IN_FILE"

    SERVER_IP=$(m_server_ip)

NODE_TAG="$(m_node_tag TUIC "$num" tls)"
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: tuic
    server: $SERVER_IP
    port: $port
    uuid: $uuid
    password: $pass
    sni: $domain
$(render_tuic_proxy_opts)
    skip-cert-verify: true
    alpn:
      - h3
EOF

    echo "tuic://$uuid:$pass@$SERVER_IP:$port?sni=$domain&alpn=h3&insecure=1&allowInsecure=1&congestion_control=$CC_PROFILE#TUICv5-$num" > "$SHARE_FILE"
}

# ================================
# 导出订阅（展开 YAML + 链接）
# ================================
export_subscription() {
    print_title "导出所有 TUICv5 节点订阅（展开格式）"

    SUB_FILE="$OUT_DIR/tuicv5_subscribe.yaml"
    echo "# TUICv5 全节点订阅（自动生成）" > "$SUB_FILE"
    echo "proxies:" >> "$SUB_FILE"

    shopt -s nullglob
    local files=("$CONF_DIR"/${PROTO}-*.yaml)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "无配置，无法导出订阅"
        return
    fi

    IFS=$'\n' files=($(printf "%s\n" "${files[@]}" | sort))

    for f in "${files[@]}"; do
        name=$(basename "$f")

        if [[ "$name" =~ ^${PROTO}-([0-9]+)\.yaml$ ]]; then
            num="${BASH_REMATCH[1]}"
            num2=$(printf "%02d" "$num")
        else
            continue
        fi

        rebuild_client_silent "$num2"

        CLIENT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
        [[ -f "$CLIENT_FILE" ]] || continue
        SHARE_LINK=$(cat "$OUT_DIR/${PROTO}_share-$num2.txt")

cat >> "$SUB_FILE" <<EOF

# ============================
# TUICv5-$num2
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
        print_title "TUICv5 管理面板"

        ui_menu 1 "查看配置"
        ui_menu 2 "新增配置"
        ui_menu 3 "删除配置"
        ui_menu 4 "重建客户端文件"
        ui_menu 5 "导出所有节点订阅"
        ui_menu 0 "退出配置"

        read -r -p "选择: " c || { printf "\n[信息] 非交互环境 (stdin 已关闭), 已退出\n" >&2; break; }

        case "$c" in
            1) list_configs ;;
            2) add_config; m_sync_reload ;;
            3) _DELETED_PROTO_TAG=""; delete_config; m_sync_reload && share_revoke_on_delete "${_DELETED_PROTO_TAG:-}" ;;
            4) rebuild_client ;;
            5) export_subscription ;;
            0) exit 0 ;;
            *) ui_invalid "$c" ;;
        esac

        read -r -p "回车继续..." _ || break
    done
}

main_menu
