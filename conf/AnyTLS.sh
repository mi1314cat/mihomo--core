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
CERT_DIR="$BASE_DIR/conf/certs"

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

# ================================
# 特性询问（mTLS / smux 可选项）
# 选择持久化到 config.d 片的注释行: # mtls: true / # smux: <档位>
# ================================
ask_features() {
    local yn
    MTLS_ENABLED=false
    SMUX_PROFILE=""

    printf "启用 mTLS 客户端证书认证？(y/N): " >&2
    read -r yn
    [[ "$(clean_input "$yn")" =~ ^[yY]$ ]] && MTLS_ENABLED=true

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
read_features() {
    local f="$1"
    MTLS_ENABLED=false
    SMUX_PROFILE=""
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
    [[ -z "$SMUX_PROFILE" ]] && return
    local mc ms mn
    read -r mc mn ms <<< "$(smux_profile "$SMUX_PROFILE")"
    SMUX_BLOCK="    smux:
      enabled: true
      protocol: smux
      max-connections: $mc
      min-streams: $mn
      max-streams: $ms"
}

# 生成节点专属 mTLS 证书（CA + 客户端证书）；返回 MTLS_CA 与内联 PEM 变量
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
            -subj "/CN=anytls-client-$idx" >/dev/null 2>&1
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
    index=$(get_next_index)

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

    # 7. 询问可选特性 (mTLS / smux)
    ask_features
    if $MTLS_ENABLED; then
        gen_mtls_cert "$index"
    fi
    render_smux

    # 8. 写入入站配置（Mihomo AnyTLS）
cat > "$IN_FILE" <<EOF
# mtls: $MTLS_ENABLED
# smux: ${SMUX_PROFILE:-false}
listeners:
  - name: anytls-$index
    type: anytls
    listen: "0.0.0.0"
    port: $ANYTLS_PORT
    users:
      $UUID: $PASSWORD
    certificate: $CERT_FILE
    private-key: $KEY_FILE
$([ "$MTLS_ENABLED" = true ] && printf '    client-auth-type: RequireAndVerifyClientCert\n    client-auth-cert: %s' "$MTLS_CA")
EOF

    # 9. 写入客户端配置（Clash Meta）
cat > "$OUT_FILE" <<EOF
proxies:
  
  - name: anytls
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    password: $PASSWORD
    sni: $DOMAIN
    client-fingerprint: chrome
    udp: true
    idle-session-check-interval: 30
    idle-session-timeout: 30
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF

    # 10. 写入分享链接
echo "anytls://$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1#AnyTLS-$index" > "$SHARE_FILE"

    # 11. 输出信息
    print_ok "AnyTLS 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $ANYTLS_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "密码: $PASSWORD" >&2
    echo -e "SNI: $DOMAIN" >&2
    $MTLS_ENABLED && echo -e "mTLS: 已启用 (客户端证书: $CERT_DIR/mtls-$PROTO-$index/)" >&2
    [[ -n "$SMUX_PROFILE" ]] && echo -e "smux: 已启用 ($SMUX_PROFILE 档)" >&2
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
        uuid=$(grep -A1 -E "^[[:space:]]*users:" "$f" | tail -1 | awk -F: '{print $1}' | tr -d ' ')
        pass=$(grep -A1 -E "^[[:space:]]*users:" "$f" | tail -1 | awk -F: '{print $2}' | tr -d ' ')
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
    num2=$(printf "%02d" "$num")

    IN_FILE="$CONF_DIR/$PROTO-$num2.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"
   

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$num"
        return
    fi

    

    # 删除 AnyTLS 相关文件
    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE" 

    print_ok "已删除 AnyTLS 配置 $num"
}

rebuild_client() {
    print_title "重建 AnyTLS 客户端文件"

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

    # ====== 使用与 list_configs() 完全一致的提取方式 ======
    UUID=$(grep -A1 -E "^[[:space:]]*users:" "$IN_FILE" | tail -1 | awk -F: '{print $1}' | tr -d ' ')
    PASSWORD=$(grep -A1 -E "^[[:space:]]*users:" "$IN_FILE" | tail -1 | awk -F: '{print $2}' | tr -d ' ')
    ANYTLS_PORT=$(grep -E "^[[:space:]]*port:" "$IN_FILE" | awk '{print $2}')

    cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
    DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

    read_features "$IN_FILE"
    render_smux

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"
    if $MTLS_ENABLED; then
        MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
        MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
    fi

cat > "$OUT_FILE" <<EOF
proxies:
  - name: anytls-$num2
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    password: $PASSWORD
    sni: $DOMAIN
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF

    SHARE_LINK="anytls://$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1#AnyTLS-$num2"
    echo "$SHARE_LINK" > "$SHARE_FILE"

    print_ok "客户端文件已重建：$num2"

    echo -e "\n${CYAN}===== 客户端 YAML =====${RESET}"
    cat "$OUT_FILE"

    echo -e "\n${CYAN}===== 分享链接 =====${RESET}"
    echo "$SHARE_LINK"
}

export_subscription() {
    print_title "导出所有 AnyTLS 节点订阅（展开格式）"

    SUB_FILE="$OUT_DIR/anytls_subscribe.yaml"
    echo "# AnyTLS 全节点订阅（自动生成）" > "$SUB_FILE"
    echo "proxies:" >> "$SUB_FILE"

    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.yaml; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        num2=$(printf "%02d" "$num")

        UUID=$(grep -A1 -E "^[[:space:]]*users:" "$f" | tail -1 | awk -F: '{print $1}' | tr -d ' ')
        PASSWORD=$(grep -A1 -E "^[[:space:]]*users:" "$f" | tail -1 | awk -F: '{print $2}' | tr -d ' ')
        ANYTLS_PORT=$(grep -E "port:" "$f" | awk '{print $2}')
        cert=$(grep -E "certificate:" "$f" | awk '{print $2}')
        DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

        read_features "$f"
        if $MTLS_ENABLED; then
            MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
            MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
        fi

        SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)
        [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

        SHARE_LINK="anytls://$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1#AnyTLS-$num2"

cat >> "$SUB_FILE" <<EOF

# ============================
# AnyTLS-$num2$($MTLS_ENABLED && echo " (mTLS)")$([[ -n "$SMUX_PROFILE" ]] && echo " ($SMUX_PROFILE smux)")
# ============================
  - name: anytls-$num2
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    password: $PASSWORD
    sni: $DOMAIN
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK

  $SHARE_LINK

EOF

    done

    print_ok "订阅文件已生成：$SUB_FILE"

    echo -e "\n${CYAN}===== 订阅内容预览 =====${RESET}"
    cat "$SUB_FILE"

    
}

rebuild_client_silent() {
    local num2="$1"

    IN_FILE="$CONF_DIR/$PROTO-$num2.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"
    

    UUID=$(grep -A1 -E "^[[:space:]]*users:" "$IN_FILE" | tail -1 | awk -F: '{print $1}' | tr -d ' ')
    PASSWORD=$(grep -A1 -E "^[[:space:]]*users:" "$IN_FILE" | tail -1 | awk -F: '{print $2}' | tr -d ' ')
    ANYTLS_PORT=$(grep -E "port:" "$IN_FILE" | awk '{print $2}')
    cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
    DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')

    read_features "$IN_FILE"
    render_smux

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"
    if $MTLS_ENABLED; then
        MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
        MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
    fi

cat > "$OUT_FILE" <<EOF
proxies:
  - name: anytls-$num2
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    password: $PASSWORD
    sni: $DOMAIN
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF

    SHARE_LINK="anytls://$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1#AnyTLS-$num2"
    echo "$SHARE_LINK" > "$SHARE_FILE"

    
}


# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Mihomo AnyTLS 管理面板（独立版）"

        echo "1) 查看配置"
        echo "2) 新增配置"
        echo "3) 删除配置"
        echo "4) 重建客户端文件"
        echo "5) 导出所有节点订阅（Clash/Mihomo）"
        echo "0) 退出"


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
