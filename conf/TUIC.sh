#!/bin/bash
# tuicv5 管理脚本（完整）
# - 子配置保存在 conf/config.d/tuicv5-XX.yaml
# - 主配置 conf/config.yaml 为合并后的 YAML（保留原有顶层字段并合并 listeners）
# - 支持新增、列出、删除、重建（--rebuild）
# - 不包含导入功能
# 依赖: bash, ss, openssl, curl (可选), python3 + PyYAML (可选用于合并校验)

set -o errexit
set -o nounset
set -o pipefail

# ================================
# 配置区（按需修改）
# ================================
PROTO="tuicv5"
BASE_DIR="/root/catmi/mihomo"
CONF_ROOT="$BASE_DIR/conf"
CONF_DIR="$CONF_ROOT/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$CONF_ROOT/certs"
MANAGE_NAME="$(basename "$0")"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR"

# ================================
# 颜色与输出
# ================================
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"
MAGENTA="\e[35m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

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

# ================================
# 工具函数
# ================================
clean_input() { echo "$1" | tr -d '\000-\037'; }

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
# IP 检测与选择
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
# 编号系统
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
# 证书（自签并创建兼容链接）
# ================================
generate_self_signed_cert() {
    local domain="$1"
    local cert_file="$CERT_DIR/cert-$domain.crt"
    local key_file="$CERT_DIR/key-$domain.key"
    local link_cert="$CERT_DIR/server.crt"
    local link_key="$CERT_DIR/server.key"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        print_info "证书已存在: $cert_file"
    else
        print_info "生成自签证书: $domain"
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$key_file" \
            -out "$cert_file" \
            -days 365 \
            -subj "/CN=$domain" >/dev/null 2>&1 || {
                print_error "openssl 生成证书失败"
                return 1
            }
        print_ok "证书生成完成: $cert_file"
    fi

    # 创建或更新 server.crt/server.key 的符号链接，兼容旧配置引用
    # 使用相对链接以便移动目录时仍然有效
    pushd "$CERT_DIR" >/dev/null 2>&1 || return
    if [[ -e "$link_cert" || -L "$link_cert" ]]; then rm -f "$link_cert"; fi
    if [[ -e "$link_key" || -L "$link_key" ]]; then rm -f "$link_key"; fi
    ln -s "$(basename "$cert_file")" "$(basename "$link_cert")" 2>/dev/null || ln -s "$cert_file" "$link_cert"
    ln -s "$(basename "$key_file")" "$(basename "$link_key")" 2>/dev/null || ln -s "$key_file" "$link_key"
    popd >/dev/null 2>&1 || true

    CERT_FILE="$cert_file"
    KEY_FILE="$key_file"
}


# ================================
# 新增 tuicv5 配置
# ================================
add_tuicv5() {
    print_title "新增 tuicv5 配置"

    local detect listen_ip tuic_port uuid password domain PUBLIC_IP index IN_FILE OUT_FILE SHARE_FILE

    detect=$(detect_listen_ip_mode)
    listen_ip=$(choose_listen_ip "$detect")

    tuic_port=$(safe_read_port "$(random_free_port)")

    if command -v uuidgen >/dev/null 2>&1; then
        uuid=$(uuidgen)
    else
        uuid=$(openssl rand -hex 16)
    fi

    password=$(openssl rand -hex 12)

    read -r -p "证书域名 (默认: bing.com): " domain
    domain=$(clean_input "${domain:-bing.com}")

    PUBLIC_IP=$(detect_public_ip)

    generate_self_signed_cert "$domain"

    index=$(get_next_index)
    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    cat > "$IN_FILE" <<EOF
listeners:
  - name: tuicv5-$index
    type: tuic
    port: $tuic_port
    listen: "$listen_ip"
    users:
      $uuid: $password
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
    port: $tuic_port
    uuid: $uuid
    password: $password
    alpn:
      - h3
    disable-sni: true
    sni: $domain
    reduce-rtt: true
    request-timeout: 8000
    udp-relay-mode: native
    congestion-controller: bbr
    skip-cert-verify: true  
EOF

   
    
    # 9. 写入分享链接
echo "tuic://$uuid:$password@$PUBLIC_IP:$tuic_port?sni=$domain&alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#TUICv5-$index" > "$SHARE_FILE"

    print_ok "已创建子配置: $IN_FILE"
    print_ok "客户端文件: $OUT_FILE"
    print_ok "分享文件: $SHARE_FILE"

    
}

# ================================
# 列表
# ================================
list_configs() {
    print_title "配置列表"

    shopt -s nullglob
    local files=("$CONF_DIR"/$PROTO-*.yaml)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "无配置"
        return
    fi

    IFS=$'\n' files=($(printf "%s\n" "${files[@]}" | sort))

    for f in "${files[@]}"; do
        name=$(basename "$f")
        if [[ "$name" =~ ^$PROTO-([0-9]{2})\.yaml$ ]]; then
            num="${BASH_REMATCH[1]}"
        else
            continue
        fi

        port=$(grep -E '^[[:space:]]*port:' "$f" | head -1 | awk -F: '{gsub(/ /,"",$2); print $2}')
        userline=$(grep -E '^[[:space:]]*users:' -n "$f" | cut -d: -f1 || true)
        cred="N/A"
        if [[ -n "$userline" ]]; then
            cred=$(sed -n "$((userline+1))p" "$f" | awk -F: '{gsub(/ /,"",$1); print $1}')
        fi

        printf "${GREEN}%s${RESET}) 端口:${BLUE}%s${RESET} 用户:${MAGENTA}%s${RESET}\n" \
            "$num" "${port:-N/A}" "${cred:-N/A}" >&2
    done
}

# ================================
# 删除
# ================================
delete_config() {
    print_title "删除配置"

    list_configs
    read -r -p "输入编号: " num
    num=$(printf "%02d" "$num")

    IN_FILE="$CONF_DIR/$PROTO-$num.yaml"

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "不存在: $IN_FILE"
        return
    fi

    read -r -p "确认删除? (y/N): " c
    if [[ "$c" =~ ^[yY]$ ]]; then
        rm -f "$IN_FILE" "$OUT_DIR/${PROTO}_client-$num.yaml" "$OUT_DIR/${PROTO}_share-$num.txt"
        print_ok "已删除 $num"
        
    else
        print_info "已取消删除"
    fi
}

# ================================
# CLI / 主菜单
# ================================
print_help() {
    cat <<EOF
Usage: $MANAGE_NAME [command]

Commands:
  menu            交互式菜单（默认）
  add             新增 tuicv5 配置（交互）
  list            列出配置
  delete          删除配置（交互）
  
  help            显示本帮助
EOF
}

main_menu() {
    
    

    while true; do
        print_title "TUICv5 管理面板"

        echo "1) 查看"
        echo "2) 新增"
        echo "3) 删除"
        echo "0) 退出"

        read -r -p "选择: " c
        case "$c" in
            1) list_configs ;;
            2) add_tuicv5 ;;
            3) delete_config ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "回车继续..."
    done
}

# ================================
# 入口解析
# ================================
case "${1:-menu}" in
    menu) main_menu ;;
    add) add_tuicv5 ;;
    list) list_configs ;;
    delete) delete_config ;;
    
    help|-h|--help) print_help ;;
    *) print_help; exit 2 ;;
esac
