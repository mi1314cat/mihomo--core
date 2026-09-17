#!/bin/bash
# Hysteria2 管理脚本（M 内核 / mihomo, 合并主配置模式, 删除同步）
# 说明：
# - 子配置保存在 conf/config.d/hysteria2-XX.yaml
# - 主配置 conf/config.yaml 为合并后的 YAML（listeners 下包含所有子配置 listeners 项）
# - 证书双方案: 扫描本机已有 CA 证书(引用原路径) 或 自签(ECDSA, 落 conf/certs)
# - 端口跳跃（可选, iptables DNAT, 默认不开启）
# - 分享链接/客户端 YAML 按证书类型自动分支（真证书 insecure=0; 自签 pin/fingerprint）
# - 与 X 内核版 (xray conf/hysteria2.sh → hy2gen.sh) 保持同一套交互与逻辑

set -o pipefail

# ================================
# 彩色定义
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

# ================================
# 基础路径（M 内核专用）
# ================================
PROTO="hysteria2"
BASE_DIR="/root/catmi/mihomo"

CONF_ROOT="$BASE_DIR/conf"
CONF_DIR="$CONF_ROOT/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$CONF_ROOT/certs"   # 仅自签证书; 外部证书引用原路径

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR"

# 全局: 证书选择结果
CERT_MODE=""
CERT_FILE=""
KEY_FILE=""
CERT_DOMAIN=""
CERT_TRUSTED=false

# 自签域名候选
SIGN_DOMAINS=("cloudflare.com" "bing.com" "addons.mozilla.org")

# ================================
# 工具函数
# ================================
clean_input() { echo "$1" | tr -d '\000-\037'; }

port_in_use() {
    # TCP + UDP 都查（QUIC 冲突必须看 UDP）
    ss -ulHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | grep -qx "$1"
    ss -tlHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | grep -qx "$1"
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
        if ! read -r input; then echo >&2; return 1; fi
        input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口已占用"; continue; }

        echo "$port"; return
    done
}

# ================================
# 编号系统（核心）
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
    if ! read -r choice; then echo >&2; return 1; fi
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

# 修复: 网卡公网 IP 优先, 外部查询作兜底 (防 WARP/代理污染, 与 X 内核版一致)
detect_public_ip() {
    local local_ip public_ip ip
    local_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | \
        while read -r ip; do
            [[ "$ip" == 172.* || "$ip" == 10.* || "$ip" == 127.* || "$ip" == 192.168.* ]] || echo "$ip"
        done | head -1)
    public_ip=$(curl -s --max-time 8 -4 api.ipify.org 2>/dev/null || true)
    if [[ -n "$public_ip" && "$public_ip" != "$local_ip" ]]; then
        print_warn "出口IP($public_ip) != 网卡IP($local_ip), 可能走了代理, 默认用网卡IP"
    fi
    local ip="${local_ip:-$public_ip}"
    if [[ -z "$ip" ]]; then
        print_error "获取本机公网 IP 失败"
        read -r -p "请输入公网IP: " ip
        ip=$(clean_input "$ip")
    fi
    echo "$ip"
}

# ================================
# 从证书提取域名 (三级回退: SAN → CN → 文件名)
# ================================
extract_cert_domain() {
    local crt="$1" dom=""
    if command -v openssl >/dev/null 2>&1 && [[ -f "$crt" ]]; then
        dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null |
            grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
        [[ -z "$dom" ]] && dom=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null |
            grep -oE "CN *= *[^,]+" | head -1 | sed 's/.*CN *= *//' | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//' | sed 's/^cert-//')
    echo "$dom"
}

cert_not_expired() {
    [[ -f "$1" ]] || return 1
    openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1
}

cert_is_trusted() {
    local issuer
    issuer=$(openssl x509 -in "$1" -noout -issuer 2>/dev/null)
    echo "$issuer" | grep -qiE "Let['\x27]?s Encrypt|ZeroSSL|Sectigo|Google Trust|DigiCert|GlobalSign|R[0-9]{2,}|Polaris"
}

# key 配对: 给定 crt 尽力找到对应 key
find_key_for_cert() {
    local crt="$1" k
    k="${crt%.crt}.key"; [[ -f "$k" ]] && { echo "$k"; return; }
    k="${crt%.pem}.key"; [[ -f "$k" ]] && { echo "$k"; return; }
    k="${crt%_cert.pem}_key.pem"; [[ -f "$k" ]] && { echo "$k"; return; }
    k="$(dirname "$crt")/server.key"; [[ -f "$k" ]] && { echo "$k"; return; }
    echo ""
}

# ================================
# 证书扫描 (与 X 内核版一致: 多路径 + key 配对 + 过期剔除)
# ================================
scan_certs() {
    FOUND_CERTS=()
    SEEN_CERTS_TMP=()
    local f k d i src cid
    shopt -s nullglob
    local -a search_dirs=() labels=()

    [[ -d /root/catmi/cloudflare/certs ]] && { search_dirs+=(/root/catmi/cloudflare/certs); labels+=(catmi/cloudflare-certs); }
    [[ -d /root/catmi/mihomo/conf/certs ]] && { search_dirs+=(/root/catmi/mihomo/conf/certs); labels+=(mihomo-certs); }
    [[ -d /root/catmi ]] && { search_dirs+=(/root/catmi); labels+=(catmi-root); }
    [[ -d /etc/v2ray-agent/tls ]] && { search_dirs+=(/etc/v2ray-agent/tls); labels+=(v2ray-agent); }
    [[ -d /root/.acme.sh ]] && { search_dirs+=(/root/.acme.sh); labels+=(acme.sh); }
    [[ -d /etc/nginx/certs ]] && { search_dirs+=(/etc/nginx/certs); labels+=(nginx-certs); }
    [[ -d /home/web/certs ]] && { search_dirs+=(/home/web/certs); labels+=(web-certs); }

    if command -v docker >/dev/null 2>&1; then
        cid=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx | head -1)
        if [[ -n "$cid" ]]; then
            src=$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/certs"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
            [[ -n "$src" && -d "$src" ]] && { search_dirs+=("$src"); labels+=("docker-nginx($cid)"); }
        fi
    fi

    for ((i=0; i<${#search_dirs[@]}; i++)); do
        d="${search_dirs[$i]}"
        for f in "$d"/*.pem "$d"/*.crt; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *_key.pem || "$f" == *key*.pem ]] && continue
            case "$(basename "$f")" in
                ca.cer|fullchain.cer|*.issuer.cer|chain.cer|key.pem) continue ;;
            esac

            local dup=false sf
            for sf in "${SEEN_CERTS_TMP[@]:-}"; do [[ "$sf" == "$f" ]] && dup=true && break; done
            $dup && continue
            SEEN_CERTS_TMP+=("$f")

            openssl x509 -in "$f" -noout -text 2>/dev/null | grep -q "CA:TRUE" && continue
            cert_not_expired "$f" || continue

            local k
            k=$(find_key_for_cert "$f")
            FOUND_CERTS+=("$f|$k|${labels[$i]}")
        done
    done
    shopt -u nullglob
}

# ================================
# 生成自签证书 (ECDSA P-256 + SAN, 10 年)
# ================================
generate_cert() {
    local dom
    dom=$(safe_read_prompt "自签证书域名(伪装域名)" "$(random_domain)")
    [[ -z "$dom" ]] && dom=$(random_domain)

    CERT_DOMAIN="$dom"
    CERT_FILE="$CERT_DIR/cert-$dom.crt"
    KEY_FILE="$CERT_DIR/key-$dom.key"

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_ok "已有自签证书: $dom"
        CERT_TRUSTED=false
        return 0
    fi

    print_info "生成自签证书 (ECDSA P-256, 10年): $dom"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve -nodes \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
        -subj "/CN=$dom" \
        -addext "subjectAltName=DNS:$dom" >/dev/null 2>&1 || {
            print_error "openssl 生成证书失败"
            return 1
        }

    CERT_TRUSTED=false
    print_ok "自签证书生成完成: $CERT_FILE"
}

safe_read_prompt() {
    local p="$1" d="$2" input
    printf "%s (默认: %s): " "$p" "$d" >&2
    if ! read -r input; then echo >&2; return 1; fi
    input=$(clean_input "$input")
    echo "${input:-$d}"
}

# ================================
# 证书选择 (扫描 / 手动 / 自签, 失败退自签)
# ================================
ask_cert() {
    local choice f pair k lbl next_idx default_choice=""
    echo "  证书方案：" >&2
    echo "  1) 扫描本机已有证书 (ACME/nginx/CF Origin CA, CA可信)" >&2
    echo "  2) 手动输入证书路径" >&2
    echo "  3) 生成自签证书 (无需域名)" >&2
    printf "  选择 (默认1): " >&2
    if ! read -r choice; then return 1; fi
    choice=$(clean_input "$choice")

    case "$choice" in
        2)
            printf "  证书 crt 路径: " >&2; read -r f
            CERT_FILE=$(clean_input "$f")
            printf "  证书 key 路径: " >&2; read -r f
            KEY_FILE=$(clean_input "$f")
            if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
                cert_not_expired "$CERT_FILE" || { print_error "证书已过期"; return 1; }
                CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE")
                if cert_is_trusted "$CERT_FILE"; then CERT_TRUSTED=true; else CERT_TRUSTED=false; fi
                print_ok "使用手动证书: $CERT_DOMAIN (crt=$CERT_FILE)"
                return 0
            fi
            print_error "证书路径无效, 退回自签"
            generate_cert
            return $?
            ;;
        3)
            generate_cert
            return $?
            ;;
    esac

    # 自动扫描
    scan_certs
    if ((${#FOUND_CERTS[@]} > 0)); then
        echo "  检测到已有证书:" >&2
        local i=1 usable=()
        for pair in "${FOUND_CERTS[@]}"; do
            f="${pair%%|*}"; k="${pair#*|}"; k="${k%%|*}"; lbl="${pair##*|}"
            if [[ -n "$k" && -f "$k" ]] && cert_not_expired "$f"; then
                echo "    $i) $(extract_cert_domain "$f") (有密钥, 来源: $lbl)" >&2
                [[ -z "$default_choice" ]] && default_choice="$i"
                usable+=("$i|$f|$k")
            else
                echo "    $i) $(extract_cert_domain "$f") (无密钥或已过期, 忽略)" >&2
            fi
            ((i++))
        done
        echo "    $i) 手动输入路径" >&2
        echo "    $((i+1))) 生成自签证书" >&2
        printf "  选择 (默认 ${default_choice:-自签}): " >&2
        read -r choice
        choice=$(clean_input "$choice")

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
            :
        elif [[ -n "$default_choice" ]]; then
            choice="$default_choice"
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
            for pair in "${usable[@]}"; do
                if [[ "${pair%%|*}" == "$choice" ]]; then
                    CERT_FILE="${pair#*|}"; CERT_FILE="${CERT_FILE%%|*}"
                    KEY_FILE="${pair##*|}"
                    CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE")
                    if cert_is_trusted "$CERT_FILE"; then CERT_TRUSTED=true; else CERT_TRUSTED=false; fi
                    print_ok "使用证书: $CERT_DOMAIN (crt=$CERT_FILE key=$KEY_FILE)"
                    return 0
                fi
            done
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice == i )); then
            printf "  证书 crt 路径: " >&2; read -r f
            CERT_FILE=$(clean_input "$f")
            printf "  证书 key 路径: " >&2; read -r f
            KEY_FILE=$(clean_input "$f")
            if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
                cert_not_expired "$CERT_FILE" || { print_error "证书已过期"; return 1; }
                CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE")
                if cert_is_trusted "$CERT_FILE"; then CERT_TRUSTED=true; else CERT_TRUSTED=false; fi
                print_ok "使用手动证书: $CERT_DOMAIN (crt=$CERT_FILE)"
                return 0
            fi
            print_error "证书路径无效, 退回自签"
            generate_cert
            return $?
        fi
        generate_cert
        return $?
    fi

    print_warn "未扫描到任何可用证书"
    generate_cert
}

# ================================
# 证书指纹 (hex)
# ================================
calc_pin() {
    local cert="$1"
    CERT_PIN=""
    [[ -s "$cert" ]] || return 0
    CERT_PIN=$(openssl x509 -in "$cert" -outform der 2>/dev/null | sha256sum | awk '{print tolower($1)}')
    [[ "$CERT_PIN" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]] && CERT_PIN=""
}


# ================================
# 证书副本同步: SRC_CERT/SRC_KEY 保存外部证书源路径; add/rebuild/export 时哈希比对刷新

# 检查既有配置的副本是否过期(用于 list/rebuild 前置告警)
check_copy_staleness() {
    local cert="${1:-}" src
    [[ -n "$cert" && -f "$cert" && "$cert" == "$CERT_DIR"/* ]] || return 0
    local dom; dom=$(extract_cert_domain "$cert")
    local src_crt="$HOME_WEBCERTS/${dom}_cert.pem"
    src_key="$HOME_WEBCERTS/${dom}_key.pem"
    [[ -f "$src_crt" ]] || return 0
    if ! cmp -s "$src_crt" "$cert"; then
        print_warn "证书副本已过期: $cert (源 $src_crt 有更新!) 建议重建或重启同步"
        return 1
    fi
}
export HOME_WEBCERTS="/home/web/certs"

# ================================
# 客户端 YAML 生成 (按证书类型分支)
# AGENT 格式说明:
#   真证书 -> 正常校验 (无 skip-cert-verify)
#   自签   -> fingerprint = hex指纹 (锁证书, 免 skip-cert-verify)
# ================================
render_client_yaml() {
    local out_file="$1" num="$2" server_ip="$3" port="$4" password="$5"
    calc_pin "$CERT_FILE"
    {
        echo "proxies:"
        echo "  - name: Hysteria2-$num"
        echo "    type: hysteria2"
        echo "    server: $server_ip"
        echo "    port: $port"
        echo "    up: \"50 Mbps\""
        echo "    down: \"200 Mbps\""
        echo "    password: $password"
        echo "    sni: $CERT_DOMAIN"
        if [[ "$CERT_TRUSTED" == "true" || -z "$CERT_PIN" ]]; then
            echo "    skip-cert-verify: false"
        else
            echo "    fingerprint: $CERT_PIN"
        fi
        echo "    alpn:"
        echo "      - h3"
    } > "$out_file"
}

hy2_link() {
    local pw="$1" ip="$2" port="$3" num="$4"
    calc_pin "$CERT_FILE"
    local q
    if [[ "$CERT_TRUSTED" == "true" ]]; then
        q="sni=$CERT_DOMAIN&insecure=0&alpn=h3&obfs=none&upmbps=50&downmbps=200"
    else
        q="sni=$CERT_DOMAIN&alpn=h3&obfs=none&pin=$CERT_PIN&upmbps=50&downmbps=200"
    fi
    echo "hysteria2://$pw@$ip:$port?$q#HY2-$num"
}

# ================================
# 端口跳跃 (可选, iptables DNAT, 6 道防呆, 与 X 内核版一致)
# ================================
ask_port_hopping() {
    HOP_RANGE=""
    local yn range start end used_ports conflicts

    printf "是否开启 UDP 端口跳跃? (默认: 否, y/N): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        y|Y) ;;
        *) return 0 ;;
    esac

    used_ports=$(ss -ulHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)

    while true; do
        printf "跳跃范围 (默认: 30000-31000): " >&2
        if ! read -r range; then echo >&2; return 1; fi
        range=$(clean_input "$range")
        [[ -z "$range" ]] && range="30000-31000"

        if ! echo "$range" | grep -qE '^[0-9]+-[0-9]+$'; then
            print_error "范围格式应为 起始-结束, 例如 30000-31000"
            continue
        fi
        start="${range%-*}"; end="${range#*-}"

        (( start >= 1024 && start <= end && end <= 65535 )) || {
            print_error "范围不合法: $range (要求 1024 ≤ 起始 ≤ 结束 ≤ 65535)"
            continue
        }

        (( end - start > 10000 )) && \
            print_warn "跨度 $((end-start)) 个端口偏大, 建议缩小到 1-2 千"

        conflicts=$(seq "$start" "$end" | grep -Fxf <(echo "$used_ports") | head -5 | paste -sd' ')
        if [[ -n "$conflicts" ]]; then
            print_error "范围 $range 与已监听 UDP 服务冲突: $conflicts"
            print_warn "请换一段范围"
            continue
        fi

        if iptables -t nat -S PREROUTING 2>/dev/null | grep -q "dport $start:$end"; then
            print_error "PREROUTING 已存在 $start:$end 的 REDIRECT 规则 (重复添加会覆盖)"
            continue
        fi

        if (( start <= $1 && $1 <= end )); then
            print_warn "范围 $range 包含本配置端口 $1 (REDIRECT 回自身会空转)"
            continue
        fi

        break
    done

    HOP_RANGE="$range"

    if command -v iptables >/dev/null; then
        iptables -t nat -C PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$1" 2>/dev/null || \
            iptables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$1"
        iptables -t nat -C OUTPUT -p udp --dport "$start:$end" -j REDIRECT --to-ports "$1" 2>/dev/null || \
            iptables -t nat -A OUTPUT -p udp --dport "$start:$end" -j REDIRECT --to-ports "$1"
        print_ok "iptables 端口跳跃规则已添加: $range (udp → $1)"
        print_warn "规则重启后不保留, 如需持久化请 iptables-persistent (netfilter-persistent save)"
    else
        print_error "未找到 iptables, 端口跳跃无法生效"
        HOP_RANGE=""
    fi
}

remove_port_hopping() {
    local range="$1" target="$2" start end
    [[ -n "$range" ]] || return 0
    start="${range%-*}"; end="${range#*-}"
    if command -v iptables >/dev/null; then
        iptables -t nat -D PREROUTING -p udp -m udp --dport "$start:$end" -j REDIRECT --to-ports "$target" 2>/dev/null
        iptables -t nat -D OUTPUT -p udp -m udp --dport "$start:$end" -j REDIRECT --to-ports "$target" 2>/dev/null
        print_ok "端口跳跃规则已移除: $range"
    fi
}

# ================================
# YAML 校验 (python3 + PyYAML)
# ================================
validate_yaml() {
    local file="$1"
    if command -v python3 >/dev/null && python3 -c "import yaml" 2>/dev/null; then
        python3 -c "import yaml,sys; yaml.safe_load(open('$file'))" 2>/dev/null
    else
        return 0  # 无 PyYAML 时跳过校验
    fi
}

# ================================
# 从子配置读取证书路径/域名/密码 (重建、导出共用)
# ================================
load_server_meta() {
    local in_file="$1"
    CERT_FILE=$(grep -E '^[[:space:]]*certificate:' "$in_file" | head -1 | awk '{print $2}' | tr -d '\047\042')
    KEY_FILE=$(grep -E '^[[:space:]]*private-key:' "$in_file" | head -1 | awk '{print $2}' | tr -d '\047\042')
    if [[ -f "$CERT_FILE" ]]; then
        CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE")
        if cert_is_trusted "$CERT_FILE"; then CERT_TRUSTED=true; else CERT_TRUSTED=false; fi
    else
        CERT_DOMAIN=$(basename "$CERT_FILE" | sed 's/cert-//; s/\.crt//')
        CERT_TRUSTED=false
    fi
}

# ================================
# 新增配置
# ================================
add_config() {
    print_title "新增配置"

    local detect listen_ip port password PUBLIC_IP index
    local IN_FILE OUT_FILE SHARE_FILE

    detect=$(detect_listen_ip_mode)
    listen_ip=$(choose_listen_ip "$detect") || return 1

    port=$(safe_read_port "$(random_free_port)") || return 1
    password=$(openssl rand -hex 16)

    # ---- 证书选择 (双方案) ----
    ask_cert || { print_error "证书选择失败"; return 1; }

    # ---- M 内核特有: 证书路径限制 ----
    # mihomo 要求 certificate/private-key 必须在其 home 目录(-d conf 所在目录)子路径下,
    # 外部路径(如 /home/web/certs)会报 SAFE_PATHS 错误且 listener 静默不监听。
    # -> 真/外部证书必须复制副本到 conf/certs/
    if [[ "$CERT_FILE" != "$CERT_DIR"/* ]]; then
        local cdom dst_crt dst_key
        dom=$(extract_cert_domain "$CERT_FILE")
        dst_crt="$CERT_DIR/cert-$dom.crt"; dst_key="$CERT_DIR/key-$dom.key"
        cp -f "$CERT_FILE" "$dst_crt" && cp -f "$KEY_FILE" "$dst_key"
        SRC_CERT="$CERT_FILE"; SRC_KEY="$KEY_FILE"
        CERT_FILE="$dst_crt"; KEY_FILE="$dst_key"
        print_ok "外部证书已复制到 M 内核路径: $dst_crt (副本可经「4)重建客户端文件」或每日 timer 刷新)"
    fi

    ask_port_hopping "$port"

    local public_ip
    PUBLIC_IP=$(detect_public_ip) || return 1

    local index
    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"
    META_FILE="$OUT_DIR/${PROTO}_meta-$index.json"

    cat > "$IN_FILE" <<EOF
listeners:
  - name: hysteria2-$index
    type: hysteria2
    listen: "$listen_ip"
    port: $port
    users:
      user1: $password
    masquerade: https://bing.com
    certificate: $CERT_FILE
    private-key: $KEY_FILE
EOF

    if ! validate_yaml "$IN_FILE"; then
        print_error "服务端 YAML 校验失败, 已删除"
        rm -f "$IN_FILE"
        return 1
    fi

    render_client_yaml "$OUT_FILE" "$index" "$PUBLIC_IP" "$port" "$password"

    local share_link
    share_link=$(hy2_link "$password" "$PUBLIC_IP" "$port" "$index")
    echo "$share_link" > "$SHARE_FILE"

    if validate_yaml "$OUT_FILE"; then
        print_ok "客户端 YAML 校验通过"
    fi

    # 持久化元数据 (跳跃范围 + 端口 + 证书路径)
    echo "{\"index\":\"$index\",\"hop_range\":\"$HOP_RANGE\",\"port\":$port,\"cert\":\"$CERT_FILE\"}" | \
        ${DJQ:-jq} . > "$META_FILE" 2>/dev/null || echo "{\"index\":\"$index\",\"hop_range\":\"$HOP_RANGE\",\"port\":$port,\"cert\":\"$CERT_FILE\"}" > "$META_FILE"

    # 分享链接去重写入全局 txt
    grep -vF "$share_link" "$OUT_DIR/hysteria2.txt" 2>/dev/null > "$OUT_DIR/hysteria2.txt.tmp" || true
    mv -f "$OUT_DIR/hysteria2.txt.tmp" "$OUT_DIR/hysteria2.txt"
    echo "$share_link" >> "$OUT_DIR/hysteria2.txt"

    echo "$share_link" >&2
    print_ok "创建完成: $index (port=$port, cert=$([[ "$CERT_TRUSTED" == "true" ]] && echo "CA可信真证书" || echo "自签"))"
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
        local cert
        cert=$(grep -E '^[[:space:]]*certificate:' "$f" | head -1 | awk '{print $2}' | tr -d '\047\042')
        local dom
        dom=$(extract_cert_domain "$cert" 2>/dev/null)

        check_copy_staleness "$cert" 2>/dev/null || cert="$cert  ⚠副本已过期(源已续期)"
        printf "${GREEN}%s${RESET}) 端口:${BLUE}%s${RESET} 域名:${YELLOW}%s${RESET} 证书:${CYAN}%s${RESET}\n" \
            "$num" "${port:-N/A}" "${dom:-N/A}" "${cert:-N/A}" >&2
    done
}

# ================================
# 删除 (含自签证书), 同步清理客户端/分享/订阅条目
# ================================
delete_config() {
    print_title "删除配置"

    list_configs
    printf "输入编号: " >&2
    read -r num
    num=$(clean_input "$num")
    local pad
    pad=$(printf "%02d" "$num" 2>/dev/null)
    [[ -z "$pad" ]] && { print_error "编号必须是数字"; return 1; }
    [[ "$pad" =~ ^[0-9]{2}$ ]] || pad="$num"

    local IN_FILE="$CONF_DIR/$PROTO-$pad.yaml"
    if [[ ! -f "$IN_FILE" ]]; then
        print_error "不存在: $IN_FILE"
        return
    fi

    printf "确认删除? (y/N): " >&2
    if ! read -r c; then return; fi

    if [[ "$c" =~ ^[yY]$ ]]; then
        local cert_file
        cert_file=$(grep -E '^[[:space:]]*certificate:' "$IN_FILE" | head -1 | awk '{print $2}' | tr -d '\047\042')

        # 撤销端口跳跃
        if [[ -f "$OUT_DIR/${PROTO}_meta-$pad.json" ]]; then
            local hop p
            hop=$(jq -r '.hop_range // empty' "$OUT_DIR/${PROTO}_meta-$pad.json")
            p=$(jq -r '.port // empty' "$OUT_DIR/${PROTO}_meta-$pad.json")
            remove_port_hopping "$hop" "$p"
        fi

        rm -f "$IN_FILE" \
              "$OUT_DIR/${PROTO}_client-$pad.yaml" \
              "$OUT_DIR/${PROTO}_share-$pad.txt" \
              "$OUT_DIR/${PROTO}_meta-$pad.json"

        # 只删本脚本自签的证书; 外部证书保留原文件
        if [[ "$cert_file" == "$CERT_DIR"/cert-* ]]; then
            local dom
            dom=$(extract_cert_domain "$cert_file")
            rm -f "$CERT_DIR/cert-$dom.crt" "$CERT_DIR/key-$dom.key"
            print_ok "已删除 $pad（含自签证书）"
        else
            print_ok "已删除 $pad（外部证书保留: $cert_file）"
        fi

        # 从 hysteria2 同步剔除这条链接
        sed -i "/#HY2-$pad$/d" "$OUT_DIR/hysteria2.txt" 2>/dev/null

        print_info "提醒: mihomo 主配置含 listeners 时需重启/热重载以卸载该监听"
    else
        print_info "已取消删除"
    fi
}

# ================================
# 重建客户端文件
# ================================
rebuild_client() {
    print_title "重建 Hysteria2 客户端文件"

    list_configs

    printf "\n请输入要重建的编号: " >&2
    read -r num
    local pad
    pad=$(printf "%02d" "$num" 2>/dev/null)

    local IN_FILE="$CONF_DIR/$PROTO-$pad.yaml"
    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$pad"
        return
    fi

    load_server_meta "$IN_FILE" || return 1

    # 先刷新可能过期的证书副本
    local dom src_crt src_key syncc
    dom=$(extract_cert_domain "$CERT_FILE")
    src_crt="$HOME_WEBCERTS/${dom}_cert.pem"; src_key="$HOME_WEBCERTS/${dom}_key.pem"
    if [[ -f "$src_crt" && "$CERT_FILE" == "$CERT_DIR"/* ]] && ! cmp -s "$src_crt" "$CERT_FILE"; then
        cp -f "$src_crt" "$CERT_FILE" && cp -f "$src_key" "$KEY_FILE"
        print_ok "证书副本已从源刷新: $CERT_FILE"
        print_warn "mihomo 需重启以加载新副本: systemctl restart mihomo"
    fi

    local port password SERVER_IP
    port=$(grep -E '^[[:space:]]*port:' "$IN_FILE" | awk -F: '{gsub(/ /,"",$2); print $2}')
    password=$(grep -E '^[[:space:]]*user1:' "$IN_FILE" | awk -F: '{gsub(/ /,"",$2); print $2}')
    SERVER_IP=$(detect_public_ip)

    local OUT_FILE="$OUT_DIR/${PROTO}_client-$pad.yaml" SHARE_FILE="$OUT_DIR/${PROTO}_share-$pad.txt"
    render_client_yaml "$OUT_FILE" "$pad" "$SERVER_IP" "$port" "$password"
    echo "$(hy2_link "$password" "$SERVER_IP" "$port" "$pad")" > "$SHARE_FILE"

    print_ok "客户端文件已重建：$pad"

    echo -e "\n${CYAN}===== 客户端 YAML =====${RESET}"
    cat "$OUT_FILE"

    echo -e "\n${CYAN}===== 分享链接 =====${RESET}"
    echo "$(cat "$SHARE_FILE")"
}

rebuild_client_silent() {
    local pad
    pad=$(printf "%02d" "$1" 2>/dev/null || echo "$1")
    local in_file="$CONF_DIR/$PROTO-$pad.yaml"
    load_server_meta "$in_file" || return 1

    local dom src_crt src_key
    dom=$(extract_cert_domain "$CERT_FILE" 2>/dev/null)
    src_crt="$HOME_WEBCERTS/${dom}_cert.pem"; src_key="$HOME_WEBCERTS/${dom}_key.pem"
    [[ -f "$src_crt" && "$CERT_FILE" == "$CERT_DIR"/* ]] && { cmp -s "$src_crt" "$CERT_FILE" || { cp -f "$src_crt" "$CERT_FILE"; cp -f "$src_key" "$KEY_FILE"; }; }

    local port password SERVER_IP
    port=$(grep -E '^[[:space:]]*port:' "$in_file" | awk -F: '{gsub(/ /,"",$2); print $2}')
    password=$(grep -E '^[[:space:]]*user1:' "$in_file" | awk -F: '{gsub(/ /,"",$2); print $2}')
    SERVER_IP=$(detect_public_ip)

    render_client_yaml "$OUT_DIR/${PROTO}_client-$pad.yaml" "$pad" "$SERVER_IP" "$port" "$password"
    echo "$(hy2_link "$password" "$SERVER_IP" "$port" "$pad")" > "$OUT_DIR/${PROTO}_share-$pad.txt"
}

# ================================
# 导出所有节点订阅
# ================================
export_subscription() {
    print_title "导出所有 Hysteria2 节点订阅（展开格式）"

    SUB_FILE="$OUT_DIR/hysteria2_subscribe.yaml"
    echo "# Hysteria2 全节点订阅（自动生成）" > "$SUB_FILE"
    echo "proxies:" >> "$SUB_FILE"

    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.yaml; do
        local num
        num=$(basename "$f" .yaml | sed -E 's/.*-([0-9]+)/\1/')
        num2=$(printf "%02d" "$num")
        rebuild_client_silent "$num2" || continue

        local client_file="$OUT_DIR/${PROTO}_client-$num2.yaml"
        cat >> "$SUB_FILE" <<EOF

# ============================
# Hysteria2-$num2
# ============================
$(sed 's/^/  /' "$client_file" | sed 's/^proxies:$//')

EOF
    done
    shopt -u nullglob

    # 追加分享链接列表
    {
        echo ""
        echo "# ===== 分享链接 ====="
        cat "$OUT_DIR/hysteria2.txt" 2>/dev/null
    } >> "$SUB_FILE"

    print_ok "订阅文件已生成：$SUB_FILE"

    echo -e "\n${CYAN}===== 订阅内容预览 =====${RESET}"
    cat "$SUB_FILE"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Hysteria2 管理面板"

        echo "1) 查看配置"
        echo "2) 新增配置"
        echo "3) 删除配置"
        echo "4) 重建客户端文件"
        echo "5) 导出所有节点订阅"
        echo "0) 退出"

        printf "选择: " >&2
        if ! read -r c; then echo >&2; exit 0; fi   # EOF 防刷屏
        c=$(clean_input "$c")

        case "$c" in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            4) rebuild_client ;;
            5) export_subscription ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        printf "回车继续..." >&2
        if ! read -r; then echo >&2; exit 0; fi     # EOF 防刷屏
    done
}

main_menu
