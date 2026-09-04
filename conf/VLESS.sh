#!/bin/bash

# ================================
# VLESS 内核服务端生成脚本 (WS / XHTTP 二选一 + TLS)
# 基于 Trojan.sh 框架:
#   - 传输: 1) WS (CDN友好)  2) XHTTP (XHTTP+CDN)
#   - TLSS: 真实域名证书 (走 CDN 伪装)
#   - smux: 可选 (3档: web/video/download, 客户端侧)
#   - mTLS: 可选 (服务端 client-auth 双向认证)
#   - ECH:  可选 (Cloudflare 侧自动检测/开启 + 客户端 enable)
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
PROTO="vless"
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
# 定位/安装 Cloudflare API 管理器 cf-manager.sh
# 优先级: RN 本地路径 -> PATH -> 询问从 GitHub 安装 (cfapi/)
# 输出: 全局 CFMGR 变量 + stdout 打印路径 (无则空, 返回失败)
# 短链: -A <域名> <IP> [--proxy on|off|auto]  DNS ensure (幂等)
#       -E <域名>  ECH enable (幂等)   -S <域名>  ssl status   -P <域名> <端口>  origin port
# ================================
CFMGR=""
_cfmgr_asked=0

cfmgr() {
    local path="" yn
    if [[ -x "/root/catmi/cloudflare/cf-manager.sh" ]]; then
        path="/root/catmi/cloudflare/cf-manager.sh"
    elif command -v cf-manager.sh >/dev/null 2>&1; then
        path=$(command -v cf-manager.sh)
    fi
    if [[ -n "$path" ]]; then
        CFMGR="$path"
        echo "$path"
        return 0
    fi

    # 本地未找到: 询问是否从 GitHub 自动安装 (只询问一次, 防重复打扰)
    if [[ "$_cfmgr_asked" -eq 1 ]]; then
        CFMGR=""
        return 1
    fi
    _cfmgr_asked=1

    printf "未找到 cf-manager.sh, 是否自动从 GitHub 安装到 /root/catmi/cloudflare/？(y/N): " >&2
    read -r yn
    if [[ "$(clean_input "$yn")" =~ ^[yY]$ ]]; then
        local install_dir="/root/catmi/cloudflare"
        local base_url="https://raw.githubusercontent.com/mi1314cat/One-click-script/main/cfapi"
        local f
        mkdir -p "$install_dir/modules"
        print_info "从 GitHub 下载 cf-manager.sh 及 modules/ ..."
        if curl -fsSL "$base_url/cf-manager.sh" -o "$install_dir/cf-manager.sh"; then
            chmod +x "$install_dir/cf-manager.sh"
            for f in common context account zone dns ech ssl origin cert; do
                curl -fsSL "$base_url/modules/$f.sh" -o "$install_dir/modules/$f.sh" || true
            done
        else
            print_error "下载 cf-manager.sh 失败"
            CFMGR=""
            return 1
        fi
        # 校验 modules/common.sh (GitHub cfapi/ 缺 modules/ 目录时)
        if [[ -f "$install_dir/modules/common.sh" ]]; then
            CFMGR="$install_dir/cf-manager.sh"
            echo "$CFMGR"
            return 0
        fi
        print_warn "GitHub cfapi/ 缺少 modules/ 目录, 请手动上传 modules/ 或本地安装 cf-manager"
    fi
    CFMGR=""
    return 1
}

# ================================
# 获取公网 IP (交互确认; echo 输出 IP 到 stdout, 所有 print_* 与 read -p 提示走 stderr)
# IPv4 优先, API 失败时 api64.ipify.org (IPv6) 兜底, 再不行手动输入
# ================================
detect_public_ip() {
    local ip user_ip
    ip=$(curl -s https://api.ipify.org || curl -s https://api64.ipify.org || curl -s https://ifconfig.me || true)
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
# URL 编码 (分享链接 ech= 参数用)
# ================================
urlencode() {
    local s="$1" i c out=""
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9_.~-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

# CDN-ECH 分享链接参数: DNS 查询形式 (v2rayN/v2rayNG/edgetunnel 通用)
# cloudflare-ech.com+https://dns.alidns.com/dns-query
ECH_QUERY_PARAM="cloudflare-ech.com+https://dns.alidns.com/dns-query"

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
    VLESS_TRANSPORT=""   # ws | xhttp (二选一)
    ACCESS_MODE="cdn"    # cdn(CF直连 0.0.0.0) | nginx(nginx转发 127.0.0.1)
    MTLS_ENABLED=false
    SMUX_PROFILE=""
    ECH_ENABLED=false

    echo "  传输方式 (二选一):" >&2
    echo "  1) WS (WebSocket, CDN 最兼容, 推荐)" >&2
    echo "  2) XHTTP (XHTTP+CDN, 抗识别更强, 需 Cloudflare 支持)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) VLESS_TRANSPORT="xhttp" ;;
        *) VLESS_TRANSPORT="ws" ;;
    esac

    echo "  接入方式:" >&2
    echo "  1) CF 直连 (监听 0.0.0.0, Cloudflare Origin Rules 直接回源到端口)" >&2
    echo "  2) Nginx 转发 (监听 127.0.0.1, 走 nginx 路径匹配统一入口)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) ACCESS_MODE="nginx" ;;
        *) ACCESS_MODE="cdn" ;;
    esac

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

    printf "启用 ECH (Encrypted Client Hello, 需 Cloudflare 支持)? (y/N): " >&2
    read -r yn
    if [[ "$(clean_input "$yn")" =~ ^[yY]$ ]]; then
        ECH_ENABLED=true
        # ECH = 走 CDN, TLS 终止于 Cloudflare, 客户端证书到不了服务器
        # mTLS(服务端 client-auth) 与此冲突, 强制跳过
        print_warn "ECH 已启用(走 CDN): mTLS 与 ECH 冲突, 已自动跳过 mTLS"
        MTLS_ENABLED=false
    else
        printf "启用 mTLS 客户端证书认证？(y/N): " >&2
        read -r yn
        [[ "$(clean_input "$yn")" =~ ^[yY]$ ]] && MTLS_ENABLED=true
    fi
}

# 读取 config.d 片注释中的特性标记（供重建/导出时同步）
# 兼容旧格式 "# smux: true" -> 视为 web 档
read_features() {
    local f="$1"
    VLESS_TRANSPORT=""
    ACCESS_MODE="cdn"
    MTLS_ENABLED=false
    SMUX_PROFILE=""
    ECH_ENABLED=false
    if grep -qE "^[[:space:]]*# transport: (ws|xhttp)" "$f"; then
        VLESS_TRANSPORT=$(grep -oE "^[[:space:]]*# transport: (ws|xhttp)" "$f" | awk '{print $3}')
    fi
    if grep -qE "^[[:space:]]*# access: (cdn|nginx)" "$f"; then
        ACCESS_MODE=$(grep -oE "^[[:space:]]*# access: (cdn|nginx)" "$f" | awk '{print $3}')
    fi
    grep -qE "^[[:space:]]*# mtls: true" "$f" && MTLS_ENABLED=true
    grep -qE "^[[:space:]]*# ech: true" "$f" && ECH_ENABLED=true
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
# 生成 Nginx location 转发片段 (可选接入方式, 存文件供复制)
# 输入: VLESS_TRANSPORT / VLESS_PORT / WS_PATH / XHTTP_PATH / ACCESS_MODE
# 输出: Nginx 配置片段写入 NGINX_FILE (out/${PROTO}_nginx-<index>.conf)
# ================================
render_nginx_conf() {
    local path idx
    idx="${index:-$num2}"
    NGINX_FILE="$OUT_DIR/${PROTO}_nginx-$idx.conf"
    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
        path="$XHTTP_PATH"
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (XHTTP, 端口 $VLESS_PORT)
# 放入 nginx conf.d 站点 server{} 块内即可 (回源走 TLS)
location $path {
    proxy_ssl_server_name on;
    proxy_pass https://127.0.0.1:$VLESS_PORT;
    proxy_http_version 1.1;
}
EOF
    else
        path="$WS_PATH"
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (WS, 端口 $VLESS_PORT)
# 放入 nginx conf.d 站点 server{} 块内即可 (回源走 TLS + WebSocket 升级)
location $path {
    proxy_ssl_server_name on;                 # 回源时 TLS SNI
    proxy_pass https://127.0.0.1:$VLESS_PORT; # https:// -> nginx 做 TLS 回源
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;      # WebSocket 升级 (map.conf 已备)
    proxy_set_header Connection \$connection_upgrade;
}
EOF
    fi
    print_ok "Nginx 转发片段: $NGINX_FILE"
    echo -e "${CYAN}  ----- Nginx 配置片段 -----${RESET}" >&2
    cat "$NGINX_FILE" >&2
}
# ================================
# Cloudflare ECH 检测/开启 (可选特性)
# 逻辑: 已有 API Key 缓存 -> 查询 zone -> GET ech setting -> 已开跳过 / 未开 PATCH 开启
# 输出: CF_ECH_READY=true 表示 ECH 已在 Cloudflare 侧生效
# ================================
CF_CRED_FILE="$BASE_DIR/conf/.cf_api_key"

cf_ech_ensure() {
    local domain="$1"
    local email key zone_id ech_status

    # 0. 优先使用 cf-manager 短链 (幂等, 已开则提示 already enabled 退出 0)
    # 注意: 必须直接调用 cfmgr 而不是 $(cfmgr) —— 命令替换在子 shell 执行, 会丢掉 CFMGR 赋值
    if cfmgr; then
        print_info "通过 cf-manager 开启 ECH: $domain"
        if "$CFMGR" -E "$domain"; then
            print_ok "Cloudflare ECH 已确认开启 (cf-manager)"
            CF_ECH_READY=true
            return 0
        else
            print_warn "cf-manager 开启 ECH 失败, 降级为手动 API..."
        fi
    else
        print_warn "未找到 cf-manager, 使用手动 API 方式..."
    fi

    # 1. 获取 Cloudflare API Key (优先读缓存)
    if [[ -f "$CF_CRED_FILE" ]]; then
        email=$(awk -F= '/^EMAIL=/{print $2}' "$CF_CRED_FILE")
        key=$(awk -F= '/^KEY=/{print $2}' "$CF_CRED_FILE")
        print_info "使用已保存的 Cloudflare API Key (缓存: $CF_CRED_FILE)"
    else
        printf "请输入 Cloudflare 登录邮箱: " >&2
        read -r email
        email=$(clean_input "$email")
        printf "请输入 Cloudflare Global API Key: " >&2
        read -r key
        key=$(clean_input "$key")
        # 缓存 (供后续重建复用)
        mkdir -p "$BASE_DIR/conf"
        echo "EMAIL=$email" > "$CF_CRED_FILE"
        echo "KEY=$key" >> "$CF_CRED_FILE"
        chmod 600 "$CF_CRED_FILE"
        print_ok "API Key 已缓存到 $CF_CRED_FILE (可删除该文件重新输入)"
    fi

    # 2. 根据域名查找 zone_id
    print_info "正在查询域名 $domain 的 Cloudflare zone..."
    zone_id=$(curl -sS -4 -X GET "https://api.cloudflare.com/client/v4/zones?name=$domain" \
        -H "X-Auth-Email: $email" -H "X-Auth-Key: $key" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('success') and d['result'] else '')")
    if [[ -z "$zone_id" ]]; then
        print_error "无法找到域名 $domain 的 zone (API Key 可能无效或域名不在该账户)"
        print_warn "请手动确认后重试; 节点仍会生成, 但 ECH 未启用"
        return 1
    fi
    print_ok "zone_id: $zone_id"

    # 3. 查询当前 ECH 状态
    ech_status=$(curl -sS -4 -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/settings/ech" \
        -H "X-Auth-Email: $email" -H "X-Auth-Key: $key" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['value'] if d.get('success') else '')")

    # 4. 已开启则跳过, 未开启则 PATCH
    if [[ "$ech_status" == "on" ]]; then
        print_ok "Cloudflare ECH 已开启, 跳过"
        CF_ECH_READY=true
        return 0
    fi
    print_warn "Cloudflare ECH 当前未开启, 正在通过 API 开启..."
    if curl -sS -4 -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/settings/ech" \
        -H "X-Auth-Email: $email" -H "X-Auth-Key: $key" \
        -H "Content-Type: application/json" \
        --data '{"value": "on"}' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if d.get('success') else 'FAIL')" | grep -q OK; then
        print_ok "Cloudflare ECH 已成功开启"
        CF_ECH_READY=true
    else
        print_error "Cloudflare ECH 开启失败 (API 权限或配置问题), 请手动到 Cloudflare 后台确认"
    fi
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
            -subj "/CN=vless-client-$idx" >/dev/null 2>&1
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
                CERT_DOMAIN=$(basename "$chosen" .crt | sed 's/cert-//; s/\.crt//')
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
# 新增 VLESS 配置
# ================================
add_config() {
    print_title "新增 VLESS 配置"

    # 1. 自动生成 UUID (VLESS 用 uuid)
    UUID=$(cat /proc/sys/kernel/random/uuid)

    # 2. 自动生成端口
    default_port=$(random_port)
    VLESS_PORT=$(safe_read_port "$default_port")

    # 3. 自动编号
    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # 4. 获取服务器 IP (交互确认)
    print_info "检测服务器公网 IP..."
    SERVER_IP=$(detect_public_ip)

    if [[ -z "$SERVER_IP" ]]; then
        print_error "获取公网 IP 失败, 节点无 IP 无法生成分享链接"
        return 1
    fi

    if [[ "$SERVER_IP" =~ : ]]; then
        LINK_IP="[$SERVER_IP]"
    else
        LINK_IP="$SERVER_IP"
    fi

    # 5. 询问特性 (传输二选一 / smux / mTLS / ECH)
    ask_features

    # 6. TLS 证书来源 (VLESS 恒 TLS, 无 Reality 分支)
    ask_cert

    # 7. 传输路径 (防御初始化, 防止任何路径下为空)
    WS_PATH="/ws-$index"
    XHTTP_PATH="/xh-$index"
    XHTTP_MODE="auto"
    CF_ECH_READY=false

    # 8. 可选: mTLS 证书
    if $MTLS_ENABLED; then
        gen_mtls_cert "$index"
    fi

    # 9. 可选: ECH (Cloudflare 检测/开启)
    CF_ECH_READY=false
    CLIENT_SNI="$CERT_DOMAIN"
    if $ECH_ENABLED; then
        print_info "ECH 已选择, 正在检查 Cloudflare 侧配置..."
        # 优化: 先检测域名是否已开启 ECH; 已开启则跳过开启步骤 (cf-manager ech status)
        if cfmgr && "$CFMGR" ech status "$CERT_DOMAIN" --json 2>/dev/null | grep -q '"ech":"on"'; then
            print_ok "域名 $CERT_DOMAIN 已开启 ECH (检测确认), 跳过开启步骤"
            CF_ECH_READY=true
        else
            cf_ech_ensure "$CERT_DOMAIN" || true
        fi
        # ECH 模式: SNI 保持真实域名, mihomo ech-opts 自动将外层 SNI 伪装为 cloudflare-ech.com
        CLIENT_SNI="$CERT_DOMAIN"
    fi

    # 9.1 可选: DNS 绑定域名到本机 IP (cf-manager: 橙云/CDN 或灰云直连)
    # Bug7 fix: 自签兜底 CERT_DOMAIN=cloudflare.com 占位名, 不询问绑定 (避免误导)
    if [[ "$ECH_ENABLED" = true || -n "$CERT_DOMAIN" ]] && [[ "$CERT_DOMAIN" != "cloudflare.com" ]]; then
        local yn
        echo "  是否将域名 $CERT_DOMAIN 的 DNS 绑定到本机 IP ($SERVER_IP)？(y/N)" >&2
        read -r yn
        if [[ "$(clean_input "$yn")" =~ ^[yY]$ ]]; then
            if cfmgr; then
                echo "  DNS 记录代理模式:" >&2
                echo "  1) 橙云 (CDN 代理, 默认)" >&2
                echo "  2) 灰云 (仅 DNS 直连)" >&2
                printf "  选择 (默认1): " >&2
                read -r yn
                local proxy_mode="on"
                case "$(clean_input "$yn")" in
                    2) proxy_mode="off" ;;
                esac
                if "$CFMGR" -A "$CERT_DOMAIN" "$SERVER_IP" --proxy "$proxy_mode"; then
                    print_ok "DNS 绑定成功: $CERT_DOMAIN -> $SERVER_IP (cf-manager)"
                else
                    print_warn "DNS 绑定失败, 节点仍会生成, 请稍后手动处理"
                fi
            else
                print_warn "未找到 cf-manager, 跳过 DNS 绑定"
            fi
        fi
    fi

    render_smux

    # 9.5 监听地址: cdn -> 0.0.0.0, nginx -> 127.0.0.1 (仅本机经 nginx 接入)
    LISTEN_ADDR="0.0.0.0"
    [[ "$ACCESS_MODE" = "nginx" ]] && LISTEN_ADDR="127.0.0.1"

    # 10. 写入入站配置 (Nginx 片段无轮何种模式都生成)
    render_nginx_conf

    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
cat > "$IN_FILE" <<EOF
# transport: xhttp
# access: $ACCESS_MODE
# mtls: $MTLS_ENABLED
# ech: $ECH_ENABLED
# smux: ${SMUX_PROFILE:-false}
listeners:
  - name: vless-$index
    type: vless
    listen: "$LISTEN_ADDR"
    port: $VLESS_PORT
    users:
      - username: vless-$index
        uuid: $UUID
    certificate: $CERT_FILE
    private-key: $KEY_FILE
    xhttp-config:
      mode: $XHTTP_MODE
      path: $XHTTP_PATH
$([ "$MTLS_ENABLED" = true ] && printf '    client-auth-type: RequireAndVerifyClientCert
    client-auth-cert: %s' "$MTLS_CA")
EOF
    else
cat > "$IN_FILE" <<EOF
# transport: ws
# access: $ACCESS_MODE
# mtls: $MTLS_ENABLED
# ech: $ECH_ENABLED
# smux: ${SMUX_PROFILE:-false}
listeners:
  - name: vless-$index
    type: vless
    listen: "$LISTEN_ADDR"
    port: $VLESS_PORT
    users:
      - username: vless-$index
        uuid: $UUID
    certificate: $CERT_FILE
    private-key: $KEY_FILE
    ws-path: $WS_PATH
$([ "$MTLS_ENABLED" = true ] && printf '    client-auth-type: RequireAndVerifyClientCert
    client-auth-cert: %s' "$MTLS_CA")
EOF
    fi

    # 11. 写入客户端配置
    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
cat > "$OUT_FILE" <<EOF
$([ "$ECH_ENABLED" = true ] && printf '# ECH: 已启用 (mihomo ech-opts 自动发现 Cloudflare ECH, 外层 SNI=cloudflare-ech.com)\n')
proxies:
  - name: vless-$index
    type: vless
    server: $CERT_DOMAIN
    port: 443
    uuid: $UUID
    sni: $CLIENT_SNI
    client-fingerprint: chrome
    udp: true
    network: xhttp
    tls: true
    skip-cert-verify: true
    xhttp-opts:
      mode: $XHTTP_MODE
      path: $XHTTP_PATH
$([ "$ECH_ENABLED" = true ] && printf '    ech-opts:
      enable: true
      query-server-name: %s' "$CERT_DOMAIN")
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
    else
cat > "$OUT_FILE" <<EOF
$([ "$ECH_ENABLED" = true ] && printf '# ECH: 已启用 (mihomo ech-opts 自动发现 Cloudflare ECH, 外层 SNI=cloudflare-ech.com)\n')
proxies:
  - name: vless-$index
    type: vless
    server: $CERT_DOMAIN
    port: 443
    uuid: $UUID
    sni: $CLIENT_SNI
    client-fingerprint: chrome
    udp: true
    network: ws
    tls: true
    skip-cert-verify: true
    ws-opts:
      path: $WS_PATH
      headers:
        Host: $CERT_DOMAIN
$([ "$ECH_ENABLED" = true ] && printf '    ech-opts:\n      enable: true\n      query-server-name: %s' "$CERT_DOMAIN")
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
    fi

    # 12. 写入分享链接
    local ech_param=""
    if $ECH_ENABLED; then
        ech_param="&ech=$(urlencode "$ECH_QUERY_PARAM")"
    fi
    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
        echo "vless://$UUID@$CERT_DOMAIN:443?encryption=none&security=tls&sni=$CLIENT_SNI&fp=chrome&type=xhttp&mode=$XHTTP_MODE&path=$XHTTP_PATH${ech_param}#VLESS-XHTTP-$index" > "$SHARE_FILE"
    else
        echo "vless://$UUID@$CERT_DOMAIN:443?encryption=none&security=tls&sni=$CLIENT_SNI&fp=chrome&type=ws&path=$WS_PATH&host=$CERT_DOMAIN${ech_param}#VLESS-WS-$index" > "$SHARE_FILE"
    fi

    # 13. 输出信息
    print_ok "VLESS 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $VLESS_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "传输: $VLESS_TRANSPORT (路径: ${VLESS_TRANSPORT/ws/$WS_PATH})" >&2
    echo -e "域名: $CERT_DOMAIN" >&2
    $MTLS_ENABLED && echo -e "mTLS: 已启用 (客户端证书: $CERT_DIR/mtls-$PROTO-$index/)" >&2
    $ECH_ENABLED && echo -e "ECH: 已启用 (Cloudflare: ${CF_ECH_READY:-未确认})" >&2 || true
    [[ -n "$SMUX_PROFILE" ]] && echo -e "smux: 已启用 ($SMUX_PROFILE 档)" >&2
    echo -e "入站配置: $IN_FILE" >&2
    echo -e "客户端配置: $OUT_FILE" >&2
    echo -e "分享链接: $SHARE_FILE" >&2
}

# ================================
# 查看 VLESS 配置
# ================================
list_configs() {
    print_title "VLESS 配置列表"

    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.yaml)

    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有找到任何 VLESS 配置"
        return
    fi

    for f in "${files[@]}"; do
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        port=$(grep -E "^[[:space:]]*port:" "$f" | awk '{print $2}')
        uuid=$(grep -E "uuid:" "$f" | head -1 | awk '{print $2}' | tr -d ' ')
        transport=$(grep -oE "^[[:space:]]*# transport: (ws|xhttp)" "$f" | awk '{print $3}')
        transport=${transport:-ws}

        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET}  " "$port" >&2
        printf "传输:${MAGENTA}%s${RESET}  " "$transport" >&2
        printf "UUID:${WHITE}%s${RESET}\n" "$uuid" >&2
    done
}

# ================================
# 删除 VLESS 配置
# ================================
delete_config() {
    print_title "删除 VLESS 配置"

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

    # 删除 VLESS 相关文件
    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE"

    # VLESS 无 Reality, 无 public-key 文件需要清理

    print_ok "已删除 VLESS 配置 $num"
}

# ================================
# 手动重建客户端文件
# ================================
rebuild_client() {
    print_title "重建 VLESS 客户端文件"

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

    # 提取字段 (VLESS: uuid + 传输)
    VLESS_UUID=$(grep -E "uuid:" "$IN_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
    VLESS_PORT=$(grep -E "^[[:space:]]*port:" "$IN_FILE" | awk '{print $2}')

    read_features "$IN_FILE"
    render_smux

    # 传输路径 (ws-path 或 xhttp-config.path)
    if grep -qE "ws-path:" "$IN_FILE"; then
        WS_PATH=$(grep -E "ws-path:" "$IN_FILE" | awk '{print $2}' | tr -d ' ')
    else
        XHTTP_PATH=$(grep -A2 "xhttp-config:" "$IN_FILE" | grep "path:" | awk '{print $2}' | tr -d ' ')
    fi

    cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
    CERT_DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')
    CLIENT_SNI="$CERT_DOMAIN"
    LISTEN_ADDR="0.0.0.0"
    [[ "$ACCESS_MODE" = "nginx" ]] && LISTEN_ADDR="127.0.0.1"
    render_nginx_conf
    if $MTLS_ENABLED; then
        MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
        MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
    fi

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
cat > "$OUT_FILE" <<EOF
$([ "$ECH_ENABLED" = true ] && printf '# ECH: 已启用 (mihomo ech-opts 自动发现 Cloudflare ECH, 外层 SNI=cloudflare-ech.com)\n')
proxies:
  - name: vless-$num2
    type: vless
    server: $CERT_DOMAIN
    port: 443
    uuid: $VLESS_UUID
    sni: $CLIENT_SNI
    client-fingerprint: chrome
    udp: true
    network: xhttp
    tls: true
    skip-cert-verify: true
    xhttp-opts:
      mode: auto
      path: $XHTTP_PATH
$([ "$ECH_ENABLED" = true ] && printf '    ech-opts:\n      enable: true\n      query-server-name: %s' "$CERT_DOMAIN")
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
        SHARE_LINK="vless://$VLESS_UUID@$CERT_DOMAIN:443?encryption=none&security=tls&sni=$CLIENT_SNI&fp=chrome&type=xhttp&mode=auto&path=$XHTTP_PATH$([ "$ECH_ENABLED" = true ] && echo "&ech=$(urlencode "$ECH_QUERY_PARAM")")#VLESS-XHTTP-$num2"
    else
cat > "$OUT_FILE" <<EOF
$([ "$ECH_ENABLED" = true ] && printf '# ECH: 已启用 (mihomo ech-opts 自动发现 Cloudflare ECH, 外层 SNI=cloudflare-ech.com)\n')
proxies:
  - name: vless-$num2
    type: vless
    server: $CERT_DOMAIN
    port: 443
    uuid: $VLESS_UUID
    sni: $CLIENT_SNI
    client-fingerprint: chrome
    udp: true
    network: ws
    tls: true
    skip-cert-verify: true
    ws-opts:
      path: $WS_PATH
      headers:
        Host: $CERT_DOMAIN
$([ "$ECH_ENABLED" = true ] && printf '    ech-opts:\n      enable: true\n      query-server-name: %s' "$CERT_DOMAIN")
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
        SHARE_LINK="vless://$VLESS_UUID@$CERT_DOMAIN:443?encryption=none&security=tls&sni=$CLIENT_SNI&fp=chrome&type=ws&path=$WS_PATH&host=$CERT_DOMAIN$([ "$ECH_ENABLED" = true ] && echo "&ech=$(urlencode "$ECH_QUERY_PARAM")")#VLESS-WS-$num2"
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
# ================================
# 查看所有节点的 Nginx 转发配置 (面板菜单 6)
# ================================
view_nginx_conf() {
    print_title "Nginx 转发配置"

    local found=false
    local f
    for f in "$OUT_DIR"/${PROTO}_nginx-*.conf; do
        [[ -f "$f" ]] || continue
        found=true
        echo -e "\n${CYAN}===== $(basename "$f") =====${RESET}" >&2
        cat "$f" >&2
    done

    if ! $found; then
        print_warn "暂无生成的 Nginx 配置片段 (请先在新增配置时生成)"
        # 尝试从 config.d 重建
        local num nginx_file
        for f in "$CONF_DIR"/$PROTO-*.yaml; do
            [[ -f "$f" ]] || continue
            num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
            nginx_file="$OUT_DIR/${PROTO}_nginx-$num.conf"
            if [[ ! -f "$nginx_file" ]]; then
                rebuild_client_silent "$num"
                [[ -f "$nginx_file" ]] && { echo -e "\n${CYAN}===== $(basename "$nginx_file") =====${RESET}" >&2; cat "$nginx_file" >&2; }
            fi
        done
    fi
    echo -e "\n${YELLOW}提示: 将片段放入 nginx conf.d 里站点配置的 server{} 块中即可${RESET}" >&2
}

rebuild_client_silent() {
    local num2="$1"

    IN_FILE="$CONF_DIR/$PROTO-$num2.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    [[ -f "$IN_FILE" ]] || return 0

    VLESS_UUID=$(grep -E "uuid:" "$IN_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
    VLESS_PORT=$(grep -E "^[[:space:]]*port:" "$IN_FILE" | awk '{print $2}')

    read_features "$IN_FILE"
    render_smux

    if grep -qE "ws-path:" "$IN_FILE"; then
        WS_PATH=$(grep -E "ws-path:" "$IN_FILE" | awk '{print $2}' | tr -d ' ')
    else
        XHTTP_PATH=$(grep -A2 "xhttp-config:" "$IN_FILE" | grep "path:" | awk '{print $2}' | tr -d ' ')
    fi

    cert=$(grep -E "certificate:" "$IN_FILE" | awk '{print $2}')
    CERT_DOMAIN=$(basename "$cert" | sed 's/cert-//; s/\.crt//')
    CLIENT_SNI="$CERT_DOMAIN"
    LISTEN_ADDR="0.0.0.0"
    [[ "$ACCESS_MODE" = "nginx" ]] && LISTEN_ADDR="127.0.0.1"
    render_nginx_conf
    if $MTLS_ENABLED; then
        MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
        MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
    fi

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
cat > "$OUT_FILE" <<EOF
$([ "$ECH_ENABLED" = true ] && printf '# ECH: 已启用 (mihomo ech-opts 自动发现 Cloudflare ECH, 外层 SNI=cloudflare-ech.com)\n')
proxies:
  - name: vless-$num2
    type: vless
    server: $CERT_DOMAIN
    port: 443
    uuid: $VLESS_UUID
    sni: $CLIENT_SNI
    client-fingerprint: chrome
    udp: true
    network: xhttp
    tls: true
    skip-cert-verify: true
    xhttp-opts:
      mode: auto
      path: $XHTTP_PATH
$([ "$ECH_ENABLED" = true ] && printf '    ech-opts:\n      enable: true\n      query-server-name: %s' "$CERT_DOMAIN")
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
        SHARE_LINK="vless://$VLESS_UUID@$CERT_DOMAIN:443?encryption=none&security=tls&sni=$CLIENT_SNI&fp=chrome&type=xhttp&mode=auto&path=$XHTTP_PATH$([ "$ECH_ENABLED" = true ] && echo "&ech=$(urlencode "$ECH_QUERY_PARAM")")#VLESS-XHTTP-$num2"
    else
cat > "$OUT_FILE" <<EOF
$([ "$ECH_ENABLED" = true ] && printf '# ECH: 已启用 (mihomo ech-opts 自动发现 Cloudflare ECH, 外层 SNI=cloudflare-ech.com)\n')
proxies:
  - name: vless-$num2
    type: vless
    server: $CERT_DOMAIN
    port: 443
    uuid: $VLESS_UUID
    sni: $CLIENT_SNI
    client-fingerprint: chrome
    udp: true
    network: ws
    tls: true
    skip-cert-verify: true
    ws-opts:
      path: $WS_PATH
      headers:
        Host: $CERT_DOMAIN
$([ "$ECH_ENABLED" = true ] && printf '    ech-opts:\n      enable: true\n      query-server-name: %s' "$CERT_DOMAIN")
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF
        SHARE_LINK="vless://$VLESS_UUID@$CERT_DOMAIN:443?encryption=none&security=tls&sni=$CLIENT_SNI&fp=chrome&type=ws&path=$WS_PATH&host=$CERT_DOMAIN$([ "$ECH_ENABLED" = true ] && echo "&ech=$(urlencode "$ECH_QUERY_PARAM")")#VLESS-WS-$num2"
    fi

    echo "$SHARE_LINK" > "$SHARE_FILE"
}

# ================================
# 导出订阅
# ================================
export_subscription() {
    print_title "导出所有 VLESS 节点订阅（展开格式）"

    SUB_FILE="$OUT_DIR/vless_subscribe.yaml"
    echo "# VLESS 全节点订阅（自动生成）" > "$SUB_FILE"
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
# vless-$num2
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
        print_title "Mihomo VLESS 管理面板"

        echo "1) 查看配置"
        echo "2) 新增配置"
        echo "3) 删除配置"
        echo "4) 重建客户端文件"
        echo "5) 导出所有节点订阅（Clash/Mihomo）"
        echo "6) 查看 Nginx 转发配置"
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
            6) view_nginx_conf ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        printf "按回车继续..." >&2
        read
    done
}

main_menu