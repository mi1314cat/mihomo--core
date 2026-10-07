#!/bin/bash

# UI 原语统一来自 src/lib/ui.sh (颜色/消息分级/标题), 此处不再重复定义。
# 这个脚本会被父级 source, 也可能被单独执行, 所以自己兜一道。
_MUI="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/ui.sh"
# shellcheck source=/dev/null
[[ -f "$_MUI" ]] && source "$_MUI"
# 旧脚本里管重置叫 PLAIN, 统一后仍留着这个别名免得下面的用法失效
PLAIN="$RESET"

INSTALL_DIR="/root/catmi/mihomo"
ENV_FILE="$INSTALL_DIR/install_info.env"
MIHOMO_BIN="$INSTALL_DIR/mihomo"

mkdir -p "$INSTALL_DIR"

# -------------------------
# update_env（与你 xray 脚本完全一致）
# -------------------------
update_env() {
    local key="$1"
    local value="$2"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "Invalid key: $key"
        return 1
    }

    mkdir -p "$(dirname "$ENV_FILE")"
    [ -f "$ENV_FILE" ] || touch "$ENV_FILE"

    local mode owner group
    if mode=$(stat -c "%a" "$ENV_FILE" 2>/dev/null); then
        owner=$(stat -c "%u" "$ENV_FILE")
        group=$(stat -c "%g" "$ENV_FILE")
    else
        mode=$(stat -f "%Lp" "$ENV_FILE")
        owner=$(stat -f "%u" "$ENV_FILE")
        group=$(stat -f "%g" "$ENV_FILE")
    fi

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    (
        flock 200

        local tmp_file
        tmp_file=$(mktemp "$(dirname "$ENV_FILE")/.env.tmp.XXXXXX")

        chmod "$mode" "$tmp_file"
        chown "$owner":"$group" "$tmp_file" 2>/dev/null || true

        awk -v k="$key" 'index($0, k"=") != 1' "$ENV_FILE" > "$tmp_file"

        printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"

        mv "$tmp_file" "$ENV_FILE"

    ) 200>"$ENV_FILE.lock"
}

# -------------------------
# 工具函数
# -------------------------
generate_ws_path() {
    echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# -------------------------
# 生成 Reality 密钥
# -------------------------
get_reality_keypair() {
    if [ ! -x "$MIHOMO_BIN" ]; then
        print_error "未找到 mihomo 可执行文件：$MIHOMO_BIN"
        exit 1
    fi

    print_info "正在生成 Reality 密钥对..."

    local key_pair
    key_pair=$("$MIHOMO_BIN" generate reality-keypair)

    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')

    short_id=$(openssl rand -hex 8)
    hy_password=$(openssl rand -hex 16)

    update_env PRIVATE_KEY "$private_key"
    update_env PUBLIC_KEY "$public_key"
    update_env SHORT_ID "$short_id"
    update_env HY_PASSWORD "$hy_password"

    print_info "Reality 密钥生成完成"
}

# -------------------------
# 生成所有 env
# -------------------------
generate_all_env() {

    # -------------------------
    # 端口
    # -------------------------
    read -p "请输入 reality 监听端口 (默认随机): " reality_port
    if [[ -z "$reality_port" ]]; then
        reality_port=$((RANDOM % 55535 + 10000))
    fi

    hysteria2_port=$((reality_port + 1))
    tuic_port=$((reality_port + 2))
    anytls_port=$((reality_port + 3))
    vmess_port=$((reality_port + 4))

    print_info "端口已生成："
    echo "reality:   $reality_port"
    echo "hysteria2: $hysteria2_port"
    echo "tuic:      $tuic_port"
    echo "anytls:    $anytls_port"
    echo "vmess:     $vmess_port"

    update_env REALITY_PORT "$reality_port"
    update_env HY2_PORT "$hysteria2_port"
    update_env TUIC_PORT "$tuic_port"
    update_env ANYTLS_PORT "$anytls_port"
    update_env VMESS_PORT "$vmess_port"

    # -------------------------
    # UUID & WS
    # -------------------------
    UUID=$(generate_uuid)
    WS_PATH=$(generate_ws_path)
    WS_PATH1=$(generate_ws_path)

    print_info "UUID: $UUID"
    print_info "WS_PATH: $WS_PATH"
    print_info "WS_PATH1: $WS_PATH1"

    update_env UUID "$UUID"
    update_env WS_PATH "$WS_PATH"
    update_env WS_PATH1 "$WS_PATH1"

    # -------------------------
    # Reality 密钥
    # -------------------------
    get_reality_keypair

    # -------------------------
    # 公网 IP
    # -------------------------
    #
    # ★ 顺序很重要: **先读本机网卡, 再考虑外部探测**。
    #
    # 原实现直接问 api.ipify.org 并把答案落盘。套了 WARP / 透明代理时,
    # 那条查询本身就走隧道, 拿回来的是**代理出口地址**而不是本机地址 ——
    # 实测本机被写进 <WARP_EXIT_IP> (WARP 出口), 真实网卡地址是
    # <REAL_SERVER_IP>, 于是所有分享链接与客户端配置全指向一个从外部
    # 连不通的 IP, 而面板一切显示正常, 直到客户端 19 个节点全连不上。
    #
    # env.sh 的 m_server_ip / m_iface_public_addr 早就实现了
    # "读网卡 + 排除隧道/私网 + 外部探测自检", 这里此前是全项目唯一绕过它
    # 的地方 —— 同一件事两套实现必然漂移。下面优先复用 env.sh; 拿不到
    # (XRevise.sh 可能被单独执行, 那时 env.sh 没被 source) 就用同口径内联版。
    _xr_iface_ip() {
        if declare -F m_iface_public_addr >/dev/null 2>&1; then
            local v
            v=$(m_iface_public_addr 2>/dev/null) && [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
        fi
        ip -o addr show scope global 2>/dev/null | awk '{print $2, $4}' \
            | sed 's|/[0-9]*$||' \
            | while read -r dev ip; do
                  case "$dev" in
                      warp|wg[0-9]*|awg[0-9]*|tun[0-9]*|tap[0-9]*|utun[0-9]*|tailscale|ts[0-9]*|docker[0-9]*|br-[0-9a-f]+|veth.*|virbr[0-9]*) continue ;;
                  esac
                  case "$ip" in
                      10.*|127.*|192.168.*|169.254.*|0.*) continue ;;
                      172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
                      100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) continue ;;
                      198.1[89].*|198.51.100.*|192.0.2.*|203.0.113.*) continue ;;
                      *:*) continue ;;
                  esac
                  printf '%s\n' "$ip"; break
              done | head -1
    }

    local _iface_ip
    _iface_ip=$(_xr_iface_ip || true)

    if [[ -n "$_iface_ip" ]]; then
        # 网卡上就有全局地址 -> 这就是正解, 不必联网、也不必问
        PUBLIC_IP="$_iface_ip"
        IP_CHOICE=1
        print_info "本机对外地址: $PUBLIC_IP (取自网卡, 已排除 WARP/隧道/私网)"
    else
        # 网卡上没有全局地址 (NAT 机器) -> 只能靠外部探测, 但必须过自检
        PUBLIC_IP_V4=$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null || true)
        PUBLIC_IP_V6=$(curl -s6 --max-time 8 https://api64.ipify.org 2>/dev/null || true)

        if [ -z "$PUBLIC_IP_V4" ] && [ -z "$PUBLIC_IP_V6" ]; then
            print_error "无法检测公网 IP"
            exit 1
        fi

        # 开透明代理时上面两个值很可能是**代理出口 IP**而不是本机 IP,
        # 选错会导致所有生成分享链接的节点从外部连不上。
        echo "请选择要使用的公网 IP 地址:"
        echo "(若本机开了透明代理/机场, 请先确认下面不是代理出口 IP)"
        [ -n "$PUBLIC_IP_V4" ] && echo "1. IPv4: $PUBLIC_IP_V4"
        [ -n "$PUBLIC_IP_V6" ] && echo "2. IPv6: $PUBLIC_IP_V6"
        read -p "请输入对应数字 [默认1]: " IP_CHOICE
        IP_CHOICE=${IP_CHOICE:-1}

        if [ "$IP_CHOICE" -eq 2 ] && [ -n "$PUBLIC_IP_V6" ]; then
            PUBLIC_IP="$PUBLIC_IP_V6"
        else
            PUBLIC_IP="${PUBLIC_IP_V4:-$PUBLIC_IP_V6}"
        fi

        if declare -F m_addr_is_local >/dev/null 2>&1 && ! m_addr_is_local "$PUBLIC_IP"; then
            print_warn "注意: $PUBLIC_IP 不在本机任何网卡上 —— 若它是代理/WARP 出口地址,"
            print_warn "      客户端将无法连接。确认后可在面板里重新设置 PUBLIC_IP。"
        fi
    fi

    if [[ "$PUBLIC_IP" =~ : ]]; then
        link_ip="[$PUBLIC_IP]"
    else
        link_ip="$PUBLIC_IP"
    fi

    print_info "选定公网 IP: $PUBLIC_IP"

    update_env PUBLIC_IP "$PUBLIC_IP"
    update_env IP_CHOICE "$IP_CHOICE"
    update_env link_ip "$link_ip"

    print_info "所有环境变量已写入：$ENV_FILE"
}

# 入口
generate_all_env
