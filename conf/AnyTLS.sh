#!/bin/bash

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
RESET="\e[0m"

print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ================================
# 基础路径
# ================================
PROTO="anytls"
BASE_DIR="/root/catmi/mihomo"
CONF_DIR="$BASE_DIR/conf/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$BASE_DIR/AnyTLS"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR"

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
    ls "$CONF_DIR"/$PROTO-*.yaml 2>/dev/null | \
    sed -E 's/.*-([0-9]+)\.yaml/\1/' | sort -n | tail -1
}

# ================================
# 随机端口
# ================================
random_port() { shuf -i 10000-60000 -n 1; }

safe_read_port() {
    local default="$1"
    local input

    while true; do
        printf "请输入监听端口 (默认: %s): " "$default" >&2
        read input
        input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }

        ss -tuln | awk '{print $5}' | grep -E -q "(:|])$port$" && {
            print_error "端口已占用"
            continue
        }

        echo "$port"
        return
    done
}

# ================================
# 自动生成证书
# ================================
generate_cert() {
    local domain="$1"

    CERT_FILE="$CERT_DIR/cert-$domain.crt"
    KEY_FILE="$CERT_DIR/key-$domain.key"

    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] && return

    print_info "生成自签证书: $domain"

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -subj "/CN=$domain" >/dev/null 2>&1

    print_ok "证书生成成功"
}

# ================================
# 新增 AnyTLS 配置（独立版）
# ================================
add_config() {
    print_title "新增 AnyTLS 配置（独立版）"

    # 1. 自动生成 UUID
    UUID=$(cat /proc/sys/kernel/random/uuid)

    # 2. 自动生成密码
    PASSWORD=$(openssl rand -hex 16)

    # 3. 自动生成端口
    default_port=$(random_port)
    ANYTLS_PORT=$(safe_read_port "$default_port")

    # 4. 自动生成域名（证书）
    DOMAIN="cloudflare.com"
    generate_cert "$DOMAIN"

    # 5. 自动编号
    next=$(get_next_index)
    next=$((next + 1))
    index=$(printf "%02d" $next)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # 6. 获取服务器 IP
    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)

    if [[ "$SERVER_IP" =~ : ]]; then
        LINK_IP="[$SERVER_IP]"
    else
        LINK_IP="$SERVER_IP"
    fi

    # 7. 写入入站配置（Mihomo AnyTLS）
cat > "$IN_FILE" <<EOF
# 自动生成：AnyTLS 入站配置
- name: anytls-$index
  type: anytls
  listen: "::"
  port: $ANYTLS_PORT
  users:
    - uuid: $UUID
      password: $PASSWORD
  certificate: $CERT_FILE
  private-key: $KEY_FILE
EOF

    # 8. 写入客户端配置（Clash Meta）
cat > "$OUT_FILE" <<EOF
proxies:
  
  - name: anytls
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    uuid: $UUID
    password: $PASSWORD
    sni: $DOMAIN
    client-fingerprint: chrome
    udp: true
    idle-session-check-interval: 30
    idle-session-timeout: 30
    skip-cert-verify: true  
EOF

    # 9. 写入分享链接
echo "anytls://$UUID:$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1#AnyTLS-$index" > "$SHARE_FILE"

    # 10. 输出信息
    print_ok "AnyTLS 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $ANYTLS_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "密码: $PASSWORD" >&2
    echo -e "SNI: $DOMAIN" >&2
    echo -e "入站配置: $IN_FILE" >&2
    echo -e "客户端配置: $OUT_FILE" >&2
    echo -e "分享链接: $SHARE_FILE" >&2
}

# ================================
# 查看 AnyTLS 配置
# ================================
list_configs() {
    print_title "AnyTLS 配置列表"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有找到任何 AnyTLS 配置"
        return
    fi

    for f in "${files[@]}"; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        port=$(grep -E "^[[:space:]]*port:" "$f" | awk '{print $2}')
        uuid=$(grep -E "uuid:" "$f" | awk '{print $2}')
        pass=$(grep -E "password:" "$f" | awk '{print $2}')
        cert=$(grep -E "certificate:" "$f" | awk '{print $2}')
        domain=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET}  " "$port" >&2
        printf "UUID:${MAGENTA}%s${RESET}  " "$uuid" >&2
        printf "密码:${YELLOW}%s${RESET}  " "$pass" >&2
        printf "SNI:${CYAN}%s${RESET}\n" "$domain" >&2
    done
}

# ================================
# 删除 AnyTLS 配置
# ================================
delete_config() {
    print_title "删除 AnyTLS 配置"

    list_configs

    printf "\n请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")

    IN_FILE="$CONF_DIR/$PROTO-$(printf "%02d" "$num").yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$(printf "%02d" "$num").yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$(printf "%02d" "$num").txt"

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$num"
        return
    fi

    # 删除证书
    cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
    domain=$(basename "$cert" | sed 's/cert-//; s/\.crt//')
    rm -f "$CERT_DIR/cert-$domain.crt" "$CERT_DIR/key-$domain.key"

    # 删除配置文件
    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE"

    print_ok "已删除 AnyTLS 配置 $num"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Mihomo AnyTLS 管理面板（独立版）"

        echo "1) 查看配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case $c in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        printf "按回车继续..." >&2
        read
    done
}

main_menu
