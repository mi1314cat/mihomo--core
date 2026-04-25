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
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }

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
PUB_DIR="$OUT_DIR/pub"
PUB_ENV="$PUB_DIR/public_key.env"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$PUB_DIR"

# ================================
# 工具函数
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

trim() {
    echo "$1" | sed 's/^[ \t]*//;s/[ \t]*$//'
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
        uuid=$(grep -E "uuid:" "$f" | sed -E 's/.*uuid:[[:space:]]*//' | xargs)
        sni=$(grep -E "server-names:" -A1 "$f" | tail -1 | sed 's/- //' | xargs)

        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET}  " "$port" >&2
        printf "UUID:${MAGENTA}%s${RESET}  " "$uuid" >&2
        printf "SNI:${YELLOW}%s${RESET}\n" "$sni" >&2
    done
}

# ================================
# 新增 Reality 配置
# ================================
add_config() {
    print_title "新增 Reality 配置"

    DINSTALL_CATMI="/root/catmi"
    CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

    # 更新环境（模式：mihomo）
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
    update_env "$CATMIENV_FILE" mode mihomo

    # 域名选择
    bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh)

    # 重新生成所有变量
    print_info "正在重新生成环境变量..."
    bash <(curl -fsSL https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/XRevise.sh)

    # 加载 ENV
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
    load_env "$ENV_FILE"

    required_vars=(UUID PRIVATE_KEY PUBLIC_KEY SHORT_ID dest_server PUBLIC_IP link_ip REALITY_PORT)
    for v in "${required_vars[@]}"; do
        if [ -z "${!v}" ]; then
            print_error "缺少必要变量：$v"
            return
        fi
    done

    echo -e "默认 Reality 端口: ${GREEN}$REALITY_PORT${RESET}" >&2
    read -p "是否修改端口？直接回车使用默认: " custom_port
    custom_port=$(clean_input "$custom_port")

    if [[ -n "$custom_port" ]]; then
        [[ "$custom_port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; return; }
        REALITY_PORT="$custom_port"
    fi

    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # 写 Reality 入站配置
cat > "$IN_FILE" <<EOF
listeners:

  - name: reality-$index
    type: vless
    listen: "::"
    port: $REALITY_PORT
    users:
      - uuid: $UUID
        flow: xtls-rprx-vision
    reality-config:
      dest: $dest_server:443
      private-key: $PRIVATE_KEY
      short-id:
        - $SHORT_ID
      server-names:
        - $dest_server
EOF

    # 保存 public-key（按编号）
    mkdir -p "$PUB_DIR"
    echo "PUBKEY_${index}=$PUBLIC_KEY" >> "$PUB_ENV"

    # 写 Reality 客户端配置（Clash Meta）
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
    servername: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: chrome
EOF

    # 写 Reality 分享链接
echo "vless://$UUID@$link_ip:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#Reality-$index" > "$SHARE_FILE"

    print_ok "Reality 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $REALITY_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "SNI: $dest_server" >&2
    echo -e "入站配置: $IN_FILE" >&2
    echo -e "客户端配置: $OUT_FILE" >&2
    echo -e "分享链接: $SHARE_FILE" >&2
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
    num2=$(printf "%02d" "$num")

    IN_FILE="$CONF_DIR/$PROTO-$num2.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$num2"
        return
    fi

    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE"

    # 删除对应 public-key
    if [[ -f "$PUB_ENV" ]]; then
        sed -i "/^PUBKEY_${num2}=/d" "$PUB_ENV"
    fi

    print_ok "已删除 Reality 配置 $num2"
}

# ================================
# 重建 Reality 客户端文件
# ================================
rebuild_client() {
    print_title "重建 Reality 客户端文件"

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

    port=$(grep -E '^[[:space:]]*port:' "$IN_FILE" | awk '{print $2}')
    uuid=$(grep -E "uuid:" "$IN_FILE" | sed -E 's/.*uuid:[[:space:]]*//' | xargs)
    sni=$(grep -E "server-names:" -A1 "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
    short_id=$(grep -E "short-id:" -A1 "$IN_FILE" | tail -1 | sed 's/- //' | xargs)

    if [[ -f "$PUB_ENV" ]]; then
        public_key=$(grep -E "^PUBKEY_${num}=" "$PUB_ENV" | sed "s/^PUBKEY_${num}=//")
    fi

    if [[ -z "$public_key" ]]; then
        print_warn "未找到对应 public-key，pbk 将为空"
    fi

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)

cat > "$OUT_FILE" <<EOF
proxies:
  - name: Reality-$num
    type: vless
    server: $SERVER_IP
    port: $port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $sni
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    client-fingerprint: chrome
EOF

    SHARE_LINK="vless://$uuid@$SERVER_IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#Reality-$num"

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

    port=$(grep -E '^[[:space:]]*port:' "$IN_FILE" | awk '{print $2}')
    uuid=$(grep -E "uuid:" "$IN_FILE" | sed -E 's/.*uuid:[[:space:]]*//' | xargs)
    sni=$(grep -E "server-names:" -A1 "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
    short_id=$(grep -E "short-id:" -A1 "$IN_FILE" | tail -1 | sed 's/- //' | xargs)

    if [[ -f "$PUB_ENV" ]]; then
        public_key=$(grep -E "^PUBKEY_${num}=" "$PUB_ENV" | sed "s/^PUBKEY_${num}=//")
    fi

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)

cat > "$OUT_FILE" <<EOF
proxies:
  - name: Reality-$num
    type: vless
    server: $SERVER_IP
    port: $port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $sni
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    client-fingerprint: chrome
EOF

    echo "vless://$uuid@$SERVER_IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#Reality-$num" > "$SHARE_FILE"
}

# ================================
# 导出订阅（展开 YAML + 链接）
# ================================
export_subscription() {
    print_title "导出所有 Reality 节点订阅（展开格式）"

    SUB_FILE="$OUT_DIR/reality_subscribe.yaml"
    echo "# Reality 全节点订阅（自动生成）" > "$SUB_FILE"
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
# Reality-$num2
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
        print_title "Mihomo Reality 管理面板"

        echo "1) 查看配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "4) 重建客户端文件" >&2
        echo "5) 导出所有节点订阅" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case $c in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            4) rebuild_client ;;
            5) export_subscription ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        printf "按回车继续..." >&2
        read
    done
}

main_menu
