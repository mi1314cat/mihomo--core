#!/bin/bash
# Hysteria2 管理脚本（合并主配置模式，删除同步）
# 说明：
# - 子配置保存在 conf/config.d/hysteria2-XX.yaml
# - 主配置 conf/config.yaml 为合并后的 YAML（listeners: 下包含所有子配置的 listeners 列表项）
# - 删除/新增后会自动重建主配置
# - 提供简单的 YAML 校验（需要 python3 + PyYAML）

set -o errexit
set -o nounset
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
# 基础路径
# ================================
PROTO="hysteria2"
BASE_DIR="/root/catmi/mihomo"

CONF_ROOT="$BASE_DIR/conf"
CONF_DIR="$CONF_ROOT/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$CONF_ROOT/certs"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERT_DIR"

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

    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done

    printf "%02d\n" "$i"
}

# ================================
# 清理非法文件（只提示不删除）
# ================================
clean_invalid_files() {
    shopt -s nullglob
    for f in "$CONF_DIR"/*; do
        name=$(basename "$f")
        if ! [[ "$name" =~ ^$PROTO-[0-9]{2}\.yaml$ ]]; then
            print_warn "非法文件已忽略: $name"
        fi
    done
}

# ================================
# IP检测
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
# 证书
# ================================
generate_self_signed_cert() {
    local domain="$1"

    CERT_FILE="$CERT_DIR/cert-$domain.crt"
    KEY_FILE="$CERT_DIR/key-$domain.key"

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_info "证书已存在: $CERT_FILE"
        return
    fi

    print_info "生成证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -subj "/CN=$domain" >/dev/null 2>&1 || {
            print_error "openssl 生成证书失败"
            return 1
        }

    print_ok "证书生成完成: $CERT_FILE"
}

# ================================
# 主配置（合并 listeners 模式）
# ================================
# 说明：
# - 生成 conf/config.yaml，内容为:
#   listeners:
#     - <来自每个子文件的 listeners 下的列表项>
# - 仅提取每个子文件中 listeners: 之后的内容（保留原有缩进）
# - 最后进行简单的 YAML 校验（如果 python3 + PyYAML 可用）

# ================================
# 新增配置
# ================================
add_config() {
    print_title "新增配置"

    local detect listen_ip port password domain PUBLIC_IP index IN_FILE OUT_FILE SHARE_FILE

    detect=$(detect_listen_ip_mode)
    listen_ip=$(choose_listen_ip "$detect")

    port=$(safe_read_port "$(random_free_port)")
    password=$(openssl rand -hex 16)
    # 默认 SNI/证书域名，可按需修改或改为交互式
    domain="bing.com"
    PUBLIC_IP=$(detect_public_ip)

    generate_self_signed_cert "$domain"

    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    cat > "$IN_FILE" <<EOF
listeners:
  - name: hysteria2-$index
    type: hysteria2
    listen: "$listen_ip"
    port: $port
    users:
      user1: $password
    certificate: $CERT_FILE
    private-key: $KEY_FILE
EOF

    cat > "$OUT_FILE" <<EOF
proxies:
  - name: Hysteria2-$index
    type: hysteria2
    server: $PUBLIC_IP
    port: $port
    password: $password
    sni: $domain
    skip-cert-verify: true
EOF

    echo "hysteria2://$password@$PUBLIC_IP:$port?sni=$domain&insecure=1#HY2-$index" > "$SHARE_FILE"

    print_ok "创建完成: $index"

   
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
        pass=$(grep -E '^[[:space:]]*user1:' "$f" | head -1 | awk -F: '{gsub(/ /,"",$2); print $2}')

        printf "${GREEN}%s${RESET}) 端口:${BLUE}%s${RESET} 密码:${MAGENTA}%s${RESET}\n" \
            "$num" "${port:-N/A}" "${pass:-N/A}" >&2
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
        rm -f "$CONF_DIR/$PROTO-$num.yaml" \
              "$OUT_DIR/${PROTO}_client-$num.yaml" \
              "$OUT_DIR/${PROTO}_share-$num.txt"

        print_ok "已删除 $num"

       
    else
        print_info "已取消删除"
    fi
}

# ================================
# 主菜单
# ================================
main_menu() {
    clean_invalid_files

    

    while true; do
        print_title "Hysteria2 管理面板"

        echo "1) 查看配置"
        echo "2) 新增配置"
        echo "3) 删除配置"
        echo "0) 退出配置"

        read -r -p "选择: " c

        case "$c" in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        read -r -p "回车继续..."
    done
}

# ================================
# 入口
# ================================
main_menu
