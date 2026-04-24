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
PROTO="reality"
BASE_DIR="/root/catmi/mihomo"
CONF_DIR="$BASE_DIR/conf/config.d"
OUT_DIR="$BASE_DIR/out"
ENV_FILE="$BASE_DIR/install_info.env"

mkdir -p "$CONF_DIR" "$OUT_DIR"

# ================================
# 输入清理
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
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

        ss -tuln | awk '{print $5}' | grep -E -q "(:|])$port$" && {
            print_error "端口已占用"
            continue
        }

        echo "$port"
        return
    done
}

random_port() { shuf -i 10000-60000 -n 1; }

# ================================
# 自动编号
# ================================
get_next_index() {
    ls "$CONF_DIR"/$PROTO-*.yaml 2>/dev/null | \
    sed -E 's/.*-([0-9]+)\.yaml/\1/' | sort -n | tail -1
}

# ================================
# 新增 Reality 配置
# ================================

add_config() {
    print_title "新增 Reality 配置"

    # ================================
    # 1. 重新生成所有变量（必须）
    # ================================
    print_info "正在重新生成环境变量..."
    bash <(curl -fsSL https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/XRevise.sh)

    # ================================
    # 2. 加载 ENV（必须）
    # ================================
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
    load_env "$ENV_FILE"

    # 检查必要变量
    required_vars=(UUID PRIVATE_KEY PUBLIC_KEY SHORT_ID DEST_SERVER PUBLIC_IP link_ip REALITY_PORT)
    for v in "${required_vars[@]}"; do
        if [ -z "${!v}" ]; then
            print_error "缺少必要变量：$v"
            return
        fi
    done

    # ================================
    # 3. 端口来自 ENV，可选择覆盖
    # ================================
    echo -e "默认 Reality 端口: ${GREEN}$REALITY_PORT${RESET}" >&2
    read -p "是否修改端口？直接回车使用默认: " custom_port
    custom_port=$(clean_input "$custom_port")

    if [[ -n "$custom_port" ]]; then
        [[ "$custom_port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; return; }
        REALITY_PORT="$custom_port"
    fi

    # ================================
    # 4. 自动编号
    # ================================
    next=$(get_next_index)
    next=$((next + 1))
    index=$(printf "%02d" $next)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # ================================
    # 5. 写 Reality 入站配置
    # ================================
cat > "$IN_FILE" <<EOF
# 自动生成：Reality 入站配置
- name: reality-$index
  type: vless
  listen: "::"
  port: $REALITY_PORT
  users:
    - uuid: $UUID
      flow: xtls-rprx-vision
  reality-config:
    dest: $DEST_SERVER:443
    private-key: $PRIVATE_KEY
    short-id:
      - $SHORT_ID
    server-names:
      - $DEST_SERVER
EOF

    # ================================
    # 6. 写 Reality 客户端配置（Clash Meta）
    # ================================
cat > "$OUT_FILE" <<EOF
proxies:
  - name: Reality-$index
    type: vless
    server: $PUBLIC_IP
    port: $REALITY_PORT
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $DEST_SERVER
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: chrome
EOF

    # ================================
    # 7. 写 Reality 分享链接
    # ================================
echo "vless://$UUID@$link_ip:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DEST_SERVER&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#Reality-$index" > "$SHARE_FILE"

    # ================================
    # 8. 输出信息
    # ================================
    print_ok "Reality 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $REALITY_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "SNI: $DEST_SERVER" >&2
    echo -e "入站配置: $IN_FILE" >&2
    echo -e "客户端配置: $OUT_FILE" >&2
    echo -e "分享链接: $SHARE_FILE" >&2
}

# ================================
# 查看 Reality 配置
# ================================
list_configs() {
    print_title "Reality 配置列表"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有找到任何 Reality 配置"
        return
    fi

    for f in "${files[@]}"; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        port=$(grep -E "^[[:space:]]*port:" "$f" | awk '{print $2}')
        uuid=$(grep -E "uuid:" "$f" | awk '{print $2}')
        sni=$(grep -E "server-names:" -A1 "$f" | tail -1 | awk '{print $2}')

        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET}  " "$port" >&2
        printf "UUID:${MAGENTA}%s${RESET}  " "$uuid" >&2
        printf "SNI:${YELLOW}%s${RESET}\n" "$sni" >&2
    done
}

# ================================
# 删除 Reality 配置
# ================================
delete_config() {
    print_title "删除 Reality 配置"

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

    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE"

    print_ok "已删除 Reality 配置 $num"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Mihomo Reality 管理面板"

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
