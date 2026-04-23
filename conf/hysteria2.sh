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

# ================================
# 打印函数（全部输出到 stderr）
# ================================
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
PROTO="hysteria2"
BASE_DIR="/root/catmi/mihomo"
CONF_DIR="$BASE_DIR/conf/inbounds.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$BASE_DIR/Hysteria2"
ENV_FILE="$BASE_DIR/install_info.env"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR"

# ================================
# 输入清理
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

safe_read() {
    local prompt="$1"
    local default="$2"
    local input

    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

# ================================
# 端口工具
# ================================
port_in_use() {
    ss -tuln | awk '{print $5}' | grep -E -q "(:|])$1$"
}

random_port() { shuf -i 10000-60000 -n 1; }

random_free_port() {
    while true; do
        port=$(random_port)
        if ! port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
}

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
        port_in_use "$port" && { print_error "端口已占用"; continue; }

        echo "$port"
        return
    done
}

# ================================
# IP 检测
# ================================
detect_listen_ip() {
    local has_ipv4=false
    local has_ipv6=false

    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true

    if $has_ipv4 && ! $has_ipv6; then echo "ipv4"
    elif ! $has_ipv4 && $has_ipv6; then echo "ipv6"
    elif $has_ipv4 && $has_ipv6; then echo "dual"
    else echo "none"
    fi
}

choose_listen_ip() {
    local detect="$1"

    print_info "自动检测结果："
    [[ "$detect" == "ipv4" ]] && echo "  - 检测到 IPv4" >&2
    [[ "$detect" == "ipv6" ]] && echo "  - 检测到 IPv6" >&2
    [[ "$detect" == "dual" ]] && echo "  - 检测到 IPv4 + IPv6" >&2
    [[ "$detect" == "none" ]] && echo "  - 未检测到公网 IP" >&2

    echo >&2
    echo "请选择监听地址：" >&2
    echo "1) IPv4 (0.0.0.0)" >&2
    echo "2) IPv6 (::)" >&2
    echo "3) 自动推荐" >&2

    printf "选择 (默认 1): " >&2
    read choice
    choice=$(clean_input "$choice")

    case "$choice" in
        2) echo "::" ;;
        3)
            case "$detect" in
                ipv4) echo "0.0.0.0" ;;
                ipv6) echo "::" ;;
                dual) echo "0.0.0.0" ;;
                none) echo "0.0.0.0" ;;
            esac
            ;;
        *) echo "0.0.0.0" ;;
    esac
}

# ================================
# 自动编号
# ================================
get_next_index() {
    ls "$CONF_DIR"/$PROTO-*.yaml 2>/dev/null | \
    sed -E 's/.*-([0-9]+)\.yaml/\1/' | sort -n | tail -1
}

# ================================
# 生成证书（HY2 专用）
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
# 预留：新增配置
# ================================
add_config() {
    print_title "新增 Hysteria2 配置"

    # ================================
    # 1. 加载 install_info.env
    # ================================
    if [ ! -f "$ENV_FILE" ]; then
        print_error "未找到 install_info.env，请先运行 mihomo-env.sh"
        return
    fi

    source "$ENV_FILE"

    # ================================
    # 2. 自动检测监听地址
    # ================================
    detect=$(detect_listen_ip)
    listen_ip=$(choose_listen_ip "$detect")

    # ================================
    # 3. 自动端口
    # ================================
    default_port=$(random_free_port)
    hysteria_port=$(safe_read_port "$default_port")

    # ================================
    # 4. 自动生成密码（HY2 密码）
    # ================================
    hy_pass=$(openssl rand -hex 16)

    # ================================
    # 5. 自动生成域名（用于证书）
    # ================================
    domain="bing.com"   # HY2 推荐固定 SNI，不用随机域名

    # ================================
    # 6. 自动生成证书
    # ================================
    generate_self_signed_cert "$domain"

    # ================================
    # 7. 自动编号
    # ================================
    next=$(get_next_index)
    next=$((next + 1))
    index=$(printf "%02d" $next)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # ================================
    # 8. 写入入站配置（Mihomo YAML）
    # ================================
cat > "$IN_FILE" <<EOF
# 自动生成：Hysteria2 入站配置
- name: hysteria2-$index
  type: hysteria2
  listen: "$listen_ip"
  port: $hysteria_port
  users:
    user1: $hy_pass
  ignore-client-bandwidth: false
  alpn:
    - h3
  certificate: $CERT_FILE
  private-key: $KEY_FILE
EOF

    # ================================
    # 9. 写入客户端配置（Clash Meta）
    # ================================
cat > "$OUT_FILE" <<EOF
# 自动生成：Hysteria2 客户端配置（Clash Meta）
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

    # ================================
    # 10. 写入分享链接
    # ================================
echo "hysteria2://$hy_pass@$link_ip:$hysteria_port?sni=$domain&insecure=1&alpn=h3#HY2-$index" > "$SHARE_FILE"

    # ================================
    # 11. 输出信息
    # ================================
    print_ok "Hysteria2 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $hysteria_port" >&2
    echo -e "密码: $hy_pass" >&2
    echo -e "域名: $domain" >&2
    echo -e "监听: $listen_ip" >&2
    echo -e "入站配置: $IN_FILE" >&2
    echo -e "客户端配置: $OUT_FILE" >&2
    echo -e "分享链接: $SHARE_FILE" >&2
}


# ================================
# 预留：查看配置
# ================================
list_configs() {
    print_title "Hysteria2 配置列表"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有找到任何 Hysteria2 配置"
        return
    fi

    for f in "${files[@]}"; do
        # 取编号
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')

        # 解析 YAML（不依赖 yq）
        port=$(grep -E "^[[:space:]]*port:" "$f" | awk '{print $2}')
        password=$(grep -E "^[[:space:]]*user1:" "$f" | awk '{print $2}')
        cert=$(grep -E "^[[:space:]]*certificate:" "$f" | awk '{print $2}')
        domain=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET}  " "$port" >&2
        printf "密码:${MAGENTA}%s${RESET}  " "$password" >&2
        printf "域名:${YELLOW}%s${RESET}\n" "$domain" >&2
    done
}


# ================================
# 预留：删除配置
# ================================
delete_config() {
    print_title "删除 Hysteria2 配置"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有可删除的配置"
        return
    fi

    # 先列出配置
    list_configs

    printf "\n请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")

    # 生成文件路径
    IN_FILE="$CONF_DIR/$PROTO-$(printf "%02d" "$num").yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$(printf "%02d" "$num").yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$(printf "%02d" "$num").txt"

    # 检查入站文件是否存在
    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$num"
        return
    fi

    # 从 YAML 中提取证书域名
    cert=$(grep -E "^[[:space:]]*certificate:" "$IN_FILE" | awk '{print $2}')
    domain=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

    CERT_FILE="$CERT_DIR/cert-$domain.crt"
    KEY_FILE="$CERT_DIR/key-$domain.key"

    # 删除入站配置
    rm -f "$IN_FILE"

    # 删除客户端配置
    rm -f "$OUT_FILE"

    # 删除分享链接
    rm -f "$SHARE_FILE"

    # 删除证书
    rm -f "$CERT_FILE" "$KEY_FILE"

    print_ok "已删除配置 $num"
    echo -e "删除文件：" >&2
    echo -e " - 入站: $IN_FILE" >&2
    echo -e " - 客户端: $OUT_FILE" >&2
    echo -e " - 分享链接: $SHARE_FILE" >&2
    echo -e " - 证书: $CERT_FILE" >&2
    echo -e " - 密钥: $KEY_FILE" >&2
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
