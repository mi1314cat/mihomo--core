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
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"
MAGENTA="\e[35m"; CYAN="\e[36m"; WHITE="\e[97m"; BOLD="\e[1m"
RESET="\e[0m"

print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

clean_input() { echo "$1" | tr -d '\000-\037'; }

# ================================
# 基础路径
# ================================
PROTO="tuicv5"
BASE_DIR="/root/catmi/mihomo"

CONF_ROOT="$BASE_DIR/conf"
CONF_DIR="$CONF_ROOT/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$CONF_ROOT/certs"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR"

# ================================
# 端口工具
# ================================
port_in_use() {
    local p="$1"
    ss -tuln 2>/dev/null | awk '{print $5}' | grep -E -q "(:|])$p$"
}

random_port() { shuf -i 10000-60000 -n 1; }

random_free_port() {
    while true; do
        local port
        port=$(random_port)
        if ! port_in_use "$port"; then echo "$port"; return; fi
    done
}

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "请输入监听端口 (默认: %s): " "$default" >&2
        read -r input
        input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口已占用"; continue; }

        echo "$port"; return
    done
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

    echo "1) IPv4 (0.0.0.0)" >&2
    echo "2) IPv6 (::)" >&2
    echo "3) 自动" >&2

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

    ip=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || true)

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
# 证书
# ================================
generate_self_signed_cert() {
    local domain="$1"

    CERT_FILE="$CERT_DIR/cert-$domain.crt"
    KEY_FILE="$CERT_DIR/key-$domain.key"

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_info "证书已存在: $CERT_FILE"
        return
    fi

    print_info "生成证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -subj "/CN=$domain" >/dev/null 2>&1 || {
            print_error "openssl 生成证书失败"
            return 1
        }

    print_ok "证书生成完成: $CERT_FILE"
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

    port=$(safe_read_port "$(random_free_port)")

    printf "证书域名 (默认: bing.com): " >&2
    read -r domain
    domain=$(clean_input "$domain")
    domain="${domain:-bing.com}"

    PUBLIC_IP=$(detect_public_ip)

    generate_self_signed_cert "$domain"

    index=$(get_next_index)

    uuid=$(uuidgen)
    pass=$(openssl rand -hex 12)

    IN_FILE="$CONF_DIR/${PROTO}-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    cat > "$IN_FILE" <<EOF
listeners:
  - name: ${PROTO}-$index
    type: tuic
    port: $port
    listen: "$listen_ip"
    users:
      $uuid: $pass
    certificate: $CERT_FILE
    private-key: $KEY_FILE
    congestion-controller: bbr
    max-idle-time: 15000
    authentication-timeout: 1000
    alpn:
      - h3
    max-udp-relay-packet-size: 1500
EOF

    cat > "$OUT_FILE" <<EOF
proxies:
  - name: TUICv5-$index
    type: tuic
    server: $PUBLIC_IP
    port: $port
    uuid: $uuid
    password: $pass
    sni: $domain
    congestion-controller: bbr
    udp-relay-mode: native
    skip-cert-verify: true
EOF

    echo "tuic://$uuid:$pass@$PUBLIC_IP:$port?sni=$domain&congestion_control=bbr#TUICv5-$index" > "$SHARE_FILE"

    print_ok "已创建子配置: $IN_FILE"
    print_ok "客户端文件: $OUT_FILE"
    print_ok "分享文件: $SHARE_FILE"
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
        rm -f "$CONF_DIR/${PROTO}-$num.yaml" \
              "$OUT_DIR/${PROTO}_client-$num.yaml" \
              "$OUT_DIR/${PROTO}_share-$num.txt"

        print_ok "已删除 $num"
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

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)

cat > "$OUT_FILE" <<EOF
proxies:
  - name: TUICv5-$num
    type: tuic
    server: $SERVER_IP
    port: $port
    uuid: $uuid
    password: $pass
    sni: $domain
    congestion-controller: bbr
    udp-relay-mode: native
    skip-cert-verify: true
EOF

    SHARE_LINK="tuic://$uuid:$pass@$SERVER_IP:$port?sni=$domain&congestion_control=bbr#TUICv5-$num"
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

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)

cat > "$OUT_FILE" <<EOF
proxies:
  - name: TUICv5-$num
    type: tuic
    server: $SERVER_IP
    port: $port
    uuid: $uuid
    password: $pass
    sni: $domain
    congestion-controller: bbr
    udp-relay-mode: native
    skip-cert-verify: true
EOF

    echo "tuic://$uuid:$pass@$SERVER_IP:$port?sni=$domain&congestion_control=bbr#TUICv5-$num" > "$SHARE_FILE"
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

        echo "1) 查看配置"
        echo "2) 新增配置"
        echo "3) 删除配置"
        echo "4) 重建客户端文件"
        echo "5) 导出所有节点订阅"
        echo "0) 退出配置"

        read -r -p "选择: " c

        case "$c" in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            4) rebuild_client ;;
            5) export_subscription ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        read -r -p "回车继续..." _
    done
}

main_menu
