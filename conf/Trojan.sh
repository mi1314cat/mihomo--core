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
PROTO="trojan"
BASE_DIR="/root/catmi/mihomo"
CONF_DIR="$BASE_DIR/conf/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$BASE_DIR/conf/certs"
PUB_DIR="$OUT_DIR/pub"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR" "$PUB_DIR"

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
# 自动生成自签证书（兜底用）
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
# 特性询问（模式 + mTLS + smux）
# 选择持久化到 config.d 片的注释行:
#   # mode: tls|reality
#   # mtls: true
#   # smux: <档位>
# ================================
ask_features() {
    local yn
    TROJAN_MODE=""        # tls | reality
    MTLS_ENABLED=false
    SMUX_PROFILE=""

    echo "  安全模式:" >&2
    echo "  1) 纯 TLS (需域名证书, 流量形似 HTTPS)" >&2
    echo "  2) Reality (无需证书, 伪装访问真实站点)" >&2
    printf "  选择 (默认2): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        1) TROJAN_MODE="tls" ;;
        *) TROJAN_MODE="reality" ;;
    esac

    # mTLS 仅纯 TLS 模式有意义 (Reality 用真站握手, 无本端证书)
    if [[ "$TROJAN_MODE" = "tls" ]]; then
        printf "启用 mTLS 客户端证书认证？(y/N): " >&2
        read -r yn
        [[ "$(clean_input "$yn")" =~ ^[yY]$ ]] && MTLS_ENABLED=true
    fi

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
    TROJAN_MODE=""
    MTLS_ENABLED=false
    SMUX_PROFILE=""
    if grep -qE "^[[:space:]]*# mode: (tls|reality)" "$f"; then
        TROJAN_MODE=$(grep -oE "^[[:space:]]*# mode: (tls|reality)" "$f" | awk '{print $3}')
    fi
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
            -subj "/CN=trojan-client-$idx" >/dev/null 2>&1
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
# 生成 Reality x25519 密钥对
# 输出: REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY
# ================================
gen_reality_keys() {
    local tmpdir="/tmp/mihomo-reality-$$"
    mkdir -p "$tmpdir"

    openssl genpkey -algorithm X25519 -out "$tmpdir/k.key" 2>/dev/null
    openssl pkey -in "$tmpdir/k.key" -pubout -outform DER -out "$tmpdir/k.pub.der" 2>/dev/null
    openssl pkey -in "$tmpdir/k.key" -text -noout > "$tmpdir/k.txt" 2>/dev/null

    REALITY_PUBLIC_KEY=$(python3 - "$tmpdir" <<'PY'
import sys, base64, re
d = sys.argv[1]
pub = open(d + "/k.pub.der","rb").read()[-32:]
# Reality 密钥要求 URL-safe base64 (RFC4648), 无填充
b64_pub = base64.urlsafe_b64encode(pub).decode().rstrip("=")
txt = open(d + "/k.txt").read()
priv_section = txt.split("priv:")[1].split("pub:")[0]
priv_hex = re.sub(r"[^0-9a-fA-F]", "", priv_section)
b64_priv = base64.urlsafe_b64encode(bytes.fromhex(priv_hex)).decode().rstrip("=")
print(b64_pub)
open(d + "/priv.b64","w").write(b64_priv)
PY
    )
    REALITY_PRIVATE_KEY=$(cat "$tmpdir/priv.b64")
    rm -rf "$tmpdir"
}

# ================================
# 纯 TLS 模式证书来源选择
#   1) 已有证书 (ssl.sh 申请, /root/catmi/<域名>.crt|.key)
#   2) 现在调用 ssl.sh 申请
#   3) 自签证书 (兜底)
# 输出: CERT_FILE / KEY_FILE / CERT_DOMAIN
# ================================
ask_cert() {
    local yn domain

    echo "  证书来源:" >&2
    echo "  1) 已有证书 (ssl.sh 申请过, /root/catmi/ 下)" >&2
    echo "  2) 现在申请 (调用 ssl.sh)" >&2
    echo "  3) 自签证书 (内测/无域名兜底)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2)
            print_info "调用 ssl.sh 申请证书..."
            bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/ssl.sh) || {
                print_error "ssl.sh 运行失败, 退回自签"
                generate_cert "cloudflare.com"
                CERT_DOMAIN="cloudflare.com"
                return
            }
            # ssl.sh 产出 /root/catmi/<域名>.crt/.key; 让用户输入域名
            printf "请输入刚申请的域名: " >&2
            read -r domain
            domain=$(clean_input "$domain" | tr '[:upper:]' '[:lower:]')
            if [[ -f "/root/catmi/$domain.crt" && -f "/root/catmi/$domain.key" ]]; then
                CERT_FILE="/root/catmi/$domain.crt"
                KEY_FILE="/root/catmi/$domain.key"
                CERT_DOMAIN="$domain"
            else
                print_error "未找到 /root/catmi/$domain.crt, 退回自签"
                generate_cert "cloudflare.com"
                CERT_DOMAIN="cloudflare.com"
            fi
            ;;
        3)
            generate_cert "cloudflare.com"
            CERT_DOMAIN="cloudflare.com"
            ;;
        *)
            # 默认1: 已有证书
            shopt -s nullglob
            local existing=("/root/catmi"/*.crt)
            if [[ ${#existing[@]} -gt 0 ]]; then
                echo "  检测到已有证书:" >&2
                local i=0
                for c in "${existing[@]}"; do
                    i=$((i+1))
                    local d
                    d=$(basename "$c" .crt)
                    echo "    $i) $d" >&2
                done
                printf "  选择编号 (默认1): " >&2
                read -r yn
                yn=$(clean_input "$yn")
                [[ "$yn" =~ ^[0-9]+$ && "$yn" -ge 1 && "$yn" -le ${#existing[@]} ]] || yn=1
                local chosen="${existing[$((yn-1))]}"
                CERT_FILE="$chosen"
                KEY_FILE="${chosen%.crt}.key"
                CERT_DOMAIN=$(basename "$chosen" .crt)
                if [[ ! -f "$KEY_FILE" ]]; then
                    print_error "缺少私钥 ${CERT_FILE%.crt}.key, 退回自签"
                    generate_cert "cloudflare.com"
                    CERT_DOMAIN="cloudflare.com"
                fi
            else
                print_info "无已有证书, 使用自签"
                generate_cert "cloudflare.com"
                CERT_DOMAIN="cloudflare.com"
            fi
            ;;
    esac
}

# ================================
# 新增 Trojan 配置
# ================================
add_config() {
    print_title "新增 Trojan 配置"

    # 1. 自动生成 UUID 与密码
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASSWORD=$(openssl rand -hex 16)

    # 2. 自动生成端口
    default_port=$(random_port)
    TROJAN_PORT=$(safe_read_port "$default_port")

    # 3. 自动编号
    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # 4. 获取服务器 IP
    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)

    if [[ "$SERVER_IP" =~ : ]]; then
        LINK_IP="[$SERVER_IP]"
    else
        LINK_IP="$SERVER_IP"
    fi

    # 5. 询问特性 (模式/smux/mTLS)
    ask_features

    # 6. 按模式准备安全参数
    if [[ "$TROJAN_MODE" = "reality" ]]; then
        gen_reality_keys
        REALITY_DEST="www.bing.com"
        REALITY_SHORT_ID=$(openssl rand -hex 8)
        read -p "Reality 伪装目标域名 (默认 www.bing.com): " REALITY_DEST_INPUT
        REALITY_DEST=$(clean_input "${REALITY_DEST_INPUT:-www.bing.com}")
    else
        ask_cert
        if $MTLS_ENABLED; then
            gen_mtls_cert "$index"
        fi
    fi
    render_smux

    # 7. 写入入站配置
    if [[ "$TROJAN_MODE" = "reality" ]]; then
cat > "$IN_FILE" <<EOF
# mode: reality
# smux: ${SMUX_PROFILE:-false}
listeners:
  - name: trojan-$index
    type: trojan
    listen: "0.0.0.0"
    port: $TROJAN_PORT
    users:
      - username: $UUID
        password: $PASSWORD
    reality-config:
      dest: $REALITY_DEST:443
      private-key: $REALITY_PRIVATE_KEY
      short-id:
        - $REALITY_SHORT_ID
      server-names:
        - $REALITY_DEST
EOF
    else
cat > "$IN_FILE" <<EOF
# mode: tls
# mtls: $MTLS_ENABLED
# smux: ${SMUX_PROFILE:-false}
listeners:
  - name: trojan-$index
    type: trojan
    listen: "0.0.0.0"
    port: $TROJAN_PORT
    users:
      - username: $UUID
        password: $PASSWORD
    certificate: $CERT_FILE
    private-key: $KEY_FILE
$([ "$MTLS_ENABLED" = true ] && printf '    client-auth-type: RequireAndVerifyClientCert\n    client-auth-cert: %s' "$MTLS_CA")
EOF
    fi

    # 8. 保存 Reality public-key（按编号）
    if [[ "$TROJAN_MODE" = "reality" ]]; then
        echo "TROJAN_PUBKEY_${index}=$REALITY_PUBLIC_KEY" >> "$PUB_DIR/trojan_public_key.env"
    fi

    # 9. 写入客户端配置
    if [[ "$TROJAN_MODE" = "reality" ]]; then
cat > "$OUT_FILE" <<EOF
proxies:
  - name: trojan-$index
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $REALITY_DEST
    client-fingerprint: chrome
    udp: true
    network: tcp
    tls: true
    reality-opts:
      public-key: $REALITY_PUBLIC_KEY
      short-id: $REALITY_SHORT_ID
$SMUX_BLOCK
EOF
    else
cat > "$OUT_FILE" <<EOF
proxies:
  - name: trojan-$index
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $CERT_DOMAIN
    tls: true
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
    fi

    # 10. 写入分享链接
    if [[ "$TROJAN_MODE" = "reality" ]]; then
        echo "trojan://$PASSWORD@$LINK_IP:$TROJAN_PORT?security=reality&sni=$REALITY_DEST&type=tcp&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID#Trojan-$index" > "$SHARE_FILE"
    else
        echo "trojan://$PASSWORD@$LINK_IP:$TROJAN_PORT?security=tls&sni=$CERT_DOMAIN&type=tcp&fp=chrome#Trojan-$index" > "$SHARE_FILE"
    fi

    # 11. 输出信息
    print_ok "Trojan 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $TROJAN_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "密码: $PASSWORD" >&2
    [[ "$TROJAN_MODE" = "reality" ]] && echo -e "模式: Reality (伪装: $REALITY_DEST)" >&2 || echo -e "模式: 纯 TLS (域名: $CERT_DOMAIN)" >&2
    $MTLS_ENABLED && echo -e "mTLS: 已启用 (客户端证书: $CERT_DIR/mtls-$PROTO-$index/)" >&2
    [[ -n "$SMUX_PROFILE" ]] && echo -e "smux: 已启用 ($SMUX_PROFILE 档)" >&2
    echo -e "入站配置: $IN_FILE" >&2
    echo -e "客户端配置: $OUT_FILE" >&2
    echo -e "分享链接: $SHARE_FILE" >&2
}

# ================================
# 查看 Trojan 配置
# ================================
list_configs() {
    print_title "Trojan 配置列表"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有找到任何 Trojan 配置"
        return
    fi

    for f in "${files[@]}"; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        port=$(grep -E "^[[:space:]]*port:" "$f" | awk '{print $2}')
        uuid=$(grep -E "username:" "$f" | awk '{print $2}' | tr -d ' ')
        pass=$(grep -E "password:" "$f" | head -1 | awk '{print $2}' | tr -d ' ')
        mode=$(grep -oE "^[[:space:]]*# mode: (tls|reality)" "$f" | awk '{print $3}')
        mode=${mode:-tls}

        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET}  " "$port" >&2
        printf "模式:${MAGENTA}%s${RESET}  " "$mode" >&2
        printf "UUID:${WHITE}%s${RESET}  " "$uuid" >&2
        printf "密码:${YELLOW}%s${RESET}\n" "$pass" >&2
    done
}

# ================================
# 删除 Trojan 配置
# ================================
delete_config() {
    print_title "删除 Trojan 配置"

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

    # 删除 Trojan 相关文件
    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE"

    # 删除对应 public-key
    if [[ -f "$PUB_DIR/trojan_public_key.env" ]]; then
        sed -i "/^TROJAN_PUBKEY_${num2}=/d" "$PUB_DIR/trojan_public_key.env"
    fi

    print_ok "已删除 Trojan 配置 $num"
}

# ================================
# 手动重建客户端文件
# ================================
rebuild_client() {
    print_title "重建 Trojan 客户端文件"

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

    # 提取字段
    PASSWORD=$(grep -E "password:" "$IN_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
    TROJAN_PORT=$(grep -E "^[[:space:]]*port:" "$IN_FILE" | awk '{print $2}')

    read_features "$IN_FILE"
    render_smux

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

    if [[ "$TROJAN_MODE" = "reality" ]]; then
        REALITY_DEST=$(grep -A1 "server-names:" "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
        REALITY_SHORT_ID=$(grep -A1 "short-id:" "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
        REALITY_PUBLIC_KEY=$(grep -E "^TROJAN_PUBKEY_${num2}=" "$PUB_DIR/trojan_public_key.env" 2>/dev/null | sed "s/^TROJAN_PUBKEY_${num2}=//")
    else
        cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
        CERT_DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')
        if $MTLS_ENABLED; then
            MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
            MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
        fi
    fi

    if [[ "$TROJAN_MODE" = "reality" ]]; then
cat > "$OUT_FILE" <<EOF
proxies:
  - name: trojan-$num2
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $REALITY_DEST
    client-fingerprint: chrome
    udp: true
    network: tcp
    tls: true
    reality-opts:
      public-key: $REALITY_PUBLIC_KEY
      short-id: $REALITY_SHORT_ID
$SMUX_BLOCK
EOF
        SHARE_LINK="trojan://$PASSWORD@$LINK_IP:$TROJAN_PORT?security=reality&sni=$REALITY_DEST&type=tcp&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID#Trojan-$num2"
    else
cat > "$OUT_FILE" <<EOF
proxies:
  - name: trojan-$num2
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $CERT_DOMAIN
    tls: true
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
        SHARE_LINK="trojan://$PASSWORD@$LINK_IP:$TROJAN_PORT?security=tls&sni=$CERT_DOMAIN&type=tcp&fp=chrome#Trojan-$num2"
    fi

    echo "$SHARE_LINK" > "$SHARE_FILE"

    print_ok "客户端文件已重建：$num2"

    echo -e "\n${CYAN}===== 客户端 YAML =====${RESET}"
    cat "$OUT_FILE"

    echo -e "\n${CYAN}===== 分享链接 =====${RESET}"
    echo "$SHARE_LINK"
}

# ================================
# 静默重建（订阅用）
# ================================
rebuild_client_silent() {
    local num2="$1"

    IN_FILE="$CONF_DIR/$PROTO-$num2.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    [[ -f "$IN_FILE" ]] || return 0

    PASSWORD=$(grep -E "password:" "$IN_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
    TROJAN_PORT=$(grep -E "port:" "$IN_FILE" | awk '{print $2}')

    read_features "$IN_FILE"
    render_smux

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

    if [[ "$TROJAN_MODE" = "reality" ]]; then
        REALITY_DEST=$(grep -A1 "server-names:" "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
        REALITY_SHORT_ID=$(grep -A1 "short-id:" "$IN_FILE" | tail -1 | sed 's/- //' | xargs)
        REALITY_PUBLIC_KEY=$(grep -E "^TROJAN_PUBKEY_${num2}=" "$PUB_DIR/trojan_public_key.env" 2>/dev/null | sed "s/^TROJAN_PUBKEY_${num2}=//")
    else
        cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
        CERT_DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')
        if $MTLS_ENABLED; then
            MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
            MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
        fi
    fi

    if [[ "$TROJAN_MODE" = "reality" ]]; then
cat > "$OUT_FILE" <<EOF
proxies:
  - name: trojan-$num2
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $REALITY_DEST
    client-fingerprint: chrome
    udp: true
    network: tcp
    tls: true
    reality-opts:
      public-key: $REALITY_PUBLIC_KEY
      short-id: $REALITY_SHORT_ID
$SMUX_BLOCK
EOF
        SHARE_LINK="trojan://$PASSWORD@$LINK_IP:$TROJAN_PORT?security=reality&sni=$REALITY_DEST&type=tcp&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID#Trojan-$num2"
    else
cat > "$OUT_FILE" <<EOF
proxies:
  - name: trojan-$num2
    type: trojan
    server: $SERVER_IP
    port: $TROJAN_PORT
    password: $PASSWORD
    sni: $CERT_DOMAIN
    tls: true
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
        SHARE_LINK="trojan://$PASSWORD@$LINK_IP:$TROJAN_PORT?security=tls&sni=$CERT_DOMAIN&type=tcp&fp=chrome#Trojan-$num2"
    fi

    echo "$SHARE_LINK" > "$SHARE_FILE"
}

# ================================
# 导出订阅
# ================================
export_subscription() {
    print_title "导出所有 Trojan 节点订阅（展开格式）"

    SUB_FILE="$OUT_DIR/trojan_subscribe.yaml"
    echo "# Trojan 全节点订阅（自动生成）" > "$SUB_FILE"
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
# Trojan-$num2
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
        print_title "Mihomo Trojan 管理面板"

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