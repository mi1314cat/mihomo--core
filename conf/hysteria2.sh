#!/bin/bash

# ================================
# 彩色定义
# ================================
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"
MAGENTA="\e[35m"; CYAN="\e[36m"; WHITE="\e[97m"; BOLD="\e[1m"
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
# 基础路径（方案 A）
# ================================
PROTO="hysteria2"
BASE_DIR="/root/catmi/mihomo"

CONF_ROOT="$BASE_DIR/conf"
CONF_DIR="$BASE_DIR/conf/config.d"   # ★ 入站配置目录（方案 A）
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$BASE_DIR/Hysteria2"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR"

# ================================
# 输入清理
# ================================
clean_input() { echo "$1" | tr -d '\000-\037'; }

# ================================
# 公网 IP 检测（带确认 + 回车默认）
# ================================
detect_public_ip() {
    local ip user_ip

    ip=$(
        curl -s https://api.ipify.org ||
        curl -s https://ifconfig.me ||
        curl -s https://ipinfo.io/ip
    )

    if [[ -z "$ip" ]]; then
        print_error "无法自动检测公网 IP，请手动输入"
        printf "请输入公网 IP: " >&2
        read ip
        ip=$(clean_input "$ip")
        echo "$ip"
        return
    fi

    print_info "检测到公网 IP: $ip"
    printf "请输入要使用的公网 IP (直接回车 = 使用检测到的 IP): " >&2
    read user_ip
    user_ip=$(clean_input "$user_ip")

    if [[ -z "$user_ip" ]]; then
        echo "$ip"
    else
        echo "$user_ip"
    fi
}

# ================================
# 端口工具
# ================================
port_in_use() { ss -tuln | awk '{print $5}' | grep -E -q "(:|])$1$"; }
random_port() { shuf -i 10000-60000 -n 1; }

random_free_port() {
    while true; do
        port=$(random_port)
        if ! port_in_use "$port"; then echo "$port"; return; fi
    done
}

safe_read_port() {
    local default="$1"; local input
    while true; do
        printf "请输入监听端口 (默认: %s): " "$default" >&2
        read input; input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口已占用"; continue; }

        echo "$port"; return
    done
}

# ================================
# IP 检测
# ================================
detect_listen_ip() {
    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true || has_ipv4=false
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true || has_ipv6=false

    $has_ipv4 && ! $has_ipv6 && echo "ipv4" && return
    ! $has_ipv4 && $has_ipv6 && echo "ipv6" && return
    $has_ipv4 && $has_ipv6 && echo "dual" && return
    echo "none"
}

choose_listen_ip() {
    local detect="$1"
    print_info "自动检测结果：$detect"

    echo "1) IPv4 (0.0.0.0)" >&2
    echo "2) IPv6 (::)" >&2
    echo "3) 自动推荐" >&2

    printf "选择 (默认 1): " >&2
    read choice; choice=$(clean_input "$choice")

    case "$choice" in
        2) echo "::" ;;
        3)
            case "$detect" in
                ipv4) echo "0.0.0.0" ;;
                ipv6) echo "::" ;;
                dual) echo "0.0.0.0" ;;
                none) echo "0.0.0.0" ;;
            esac ;;
        *) echo "0.0.0.0" ;;
    esac
}

# ================================
# 自动编号
# ================================
get_next_index() {
    ls "$CONF_DIR"/$PROTO-*.yaml 2>/dev/null |
    sed -E 's/.*-([0-9]+)\.yaml/\1/' | sort -n | tail -1
}

# ================================
# 生成证书
# ================================
generate_self_signed_cert() {
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
# 新增配置
# ================================
add_config() {
    print_title "新增 Hysteria2 配置"

    detect=$(detect_listen_ip)
    listen_ip=$(choose_listen_ip "$detect")

    default_port=$(random_free_port)
    hysteria_port=$(safe_read_port "$default_port")

    hy_pass=$(openssl rand -hex 16)
    domain="bing.com"

    PUBLIC_IP=$(detect_public_ip)

    generate_self_signed_cert "$domain"

    next=$(get_next_index); next=$((next + 1))
    index=$(printf "%02d" $next)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

cat > "$IN_FILE" <<EOF
inbounds:
  - name: hysteria2-$index
    type: hysteria2
    listen: "$listen_ip"
    port: $hysteria_port
    users:
      user1: $hy_pass
    alpn:
      - h3
    certificate: $CERT_FILE
    private-key: $KEY_FILE
EOF

cat > "$OUT_FILE" <<EOF
proxies:
  - name: Hysteria2-$index
    type: hysteria2
    server: $PUBLIC_IP
    port: $hysteria_port
    password: $hy_pass
    sni: $domain
    skip-cert-verify: true
    alpn:
      - h3
EOF

echo "hysteria2://$hy_pass@$PUBLIC_IP:$hysteria_port?sni=$domain&insecure=1&alpn=h3#HY2-$index" > "$SHARE_FILE"

    print_ok "Hysteria2 配置生成成功"
    echo "公网 IP: $PUBLIC_IP" >&2
    echo "入站配置: $IN_FILE" >&2
    echo "客户端配置: $OUT_FILE" >&2
    echo "分享链接: $SHARE_FILE" >&2
}

# ================================
# 查看配置
# ================================
list_configs() {
    print_title "Hysteria2 配置列表"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    [[ ${#files[@]} -eq 0 ]] && print_error "没有配置" && return

    for f in "${files[@]}"; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        port=$(grep -E "port:" "$f" | awk '{print $2}')
        password=$(grep -E "user1:" "$f" | awk '{print $2}')
        printf "${GREEN}%s${RESET}) 端口:${BLUE}%s${RESET} 密码:${MAGENTA}%s${RESET}\n" "$num" "$port" "$password" >&2
    done
}

# ================================
# 删除配置
# ================================
delete_config() {
    print_title "删除 Hysteria2 配置"

    list_configs

    printf "\n请输入要删除的编号: " >&2
    read num; num=$(clean_input "$num")

    IN_FILE="$CONF_DIR/$PROTO-$(printf "%02d" "$num").yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$(printf "%02d" "$num").yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$(printf "%02d" "$num").txt"

    [[ ! -f "$IN_FILE" ]] && print_error "编号不存在" && return

    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE"

    print_ok "已删除配置 $num"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Mihomo Hysteria2 管理面板"

        echo "1) 查看配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c; c=$(clean_input "$c")

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
