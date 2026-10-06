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
# UI 原语统一来自 src/lib/ui.sh (颜色/消息分级/标题), 此处不再重复定义。
# 被父级 source 时已加载; 单独运行时由下面的兜底 source 补上。

# ================================
# 基础路径（M 内核专用）
# ================================
PROTO="hysteria2"
BASE_DIR="/root/catmi/mihomo"

CONF_ROOT="$BASE_DIR/conf"
CONF_DIR="$CONF_ROOT/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$CONF_ROOT/certs"   # 仅自签证书; 外部证书引用原路径


# ---------- 共享库 (src/lib/env.sh) ----------
# 提供: 路径常量 / 环境变量读写 / Reality dest 选择 / 合并+严格校验+重载闭环
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRV_ROOT="$BASE_DIR"
MIHOMO_BIN="$BASE_DIR/mihomo"
source "$SELF_DIR/../lib/env.sh"

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
    ss -tlHn 2>/dev/null | grep -oE '[0-9]+$' | grep -qx "$1"
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
    # 六份重复实现已收敛到 env.sh 的 m_safe_read_port:
    #   拒绝 1-1023 特权端口与系统常用端口, TCP/UDP 双查占用, EOF 安全退出。
    m_safe_read_port "$1"
}

# ================================================================
# 选配 (M 内核 / mihomo v1.19.32 特有字段)
# 每条都标了内核源码位置; 没有源码依据的一律不做。
# ================================================================

# ---------- ① obfs 混淆 (hy2 最核心的抗探测手段, 之前完全没做) ----------
#   proxy   : obfs / obfs-password          adapter/outbound/hysteria2.go:49-50
#             obfs-min/max-packet-size      adapter/outbound/hysteria2.go:51-52
#   listener: 完全对称                      listener/inbound/hysteria2.go:15-18
#   取值 salamander / gecko                  docs/config.yaml:1244
#   ⚠ 有 obfs 无 obfs-password → 硬报错 missing obfs password
#       (adapter/outbound/hysteria2.go:150-152 / listener/sing_hysteria2/server.go:106-108)
#   ⚠ 只有 obfs-password 没有 obfs → 静默忽略 (守卫是 if len(option.Obfs)>0, :149)
#   ⚠ obfs-min/max-packet-size 仅 gecko 生效 (:158-159), 配 salamander 静默无效
#   ⚠ 未知 type → 硬报错 unknown obfs type (:161 / server.go:117)
HY_OBFS=""
HY_OBFS_PASSWORD=""
HY_OBFS_MIN=""
HY_OBFS_MAX=""

# ask_uint <提示> <默认值> <最小值> —— 通用正整数提问 (EOF 安全)
ask_uint() {
    local p="$1" d="$2" min="$3" input v
    while true; do
        printf "%s (默认: %s): " "$p" "$d" >&2
        if ! read -r input; then echo >&2; return 1; fi
        input=$(clean_input "$input")
        v="${input:-$d}"
        [[ "$v" =~ ^[0-9]+$ ]] || { print_error "请输入数字"; continue; }
        (( v >= min )) || { print_error "不能小于 $min"; continue; }
        printf '%s' "$v"
        return 0
    done
}

ask_obfs() {
    HY_OBFS=""; HY_OBFS_PASSWORD=""; HY_OBFS_MIN=""; HY_OBFS_MAX=""

    echo "  obfs 混淆 (M 内核原生, 抗主动探测):" >&2
    echo "  1) 关闭 (默认)" >&2
    echo "  2) salamander (官方标准, 推荐)" >&2
    echo "  3) gecko (实验性, 可额外调包长)" >&2
    printf "  选择 (默认1): " >&2
    if ! read -r choice; then echo >&2; return 1; fi
    case "$(clean_input "$choice")" in
        2) HY_OBFS="salamander" ;;
        3) HY_OBFS="gecko" ;;
        *) return 0 ;;
    esac

    local pw
    pw=$(openssl rand -hex 16)
    HY_OBFS_PASSWORD=$(safe_read_prompt "  obfs 密码 (两侧必须一致)" "$pw") || return 1

    if [[ "$HY_OBFS" == "gecko" ]]; then
        HY_OBFS_MIN=$(ask_uint "  gecko 最小包长 (仅 gecko 生效)" "512" 1) || return 1
        HY_OBFS_MAX=$(ask_uint "  gecko 最大包长 (仅 gecko 生效)" "1200" 1) || return 1
        (( HY_OBFS_MAX <= HY_OBFS_MIN )) && print_warn "最大包长应大于最小包长"
    else
        print_info "obfs-min/max-packet-size 仅 gecko 生效, 当前算法为 salamander 故不写"
    fi
    return 0
}

# 从子配置读回 obfs (重建/导出时保持两侧一致)
read_obfs_opts() {
    local f="$1"
    HY_OBFS=$(grep -E '^[[:space:]]*obfs:' "$f" | head -1 | sed -E 's/^[[:space:]]*obfs:[[:space:]]*//' | tr -d "\"'")
    HY_OBFS_PASSWORD=$(grep -E '^[[:space:]]*obfs-password:' "$f" | head -1 | sed -E 's/^[[:space:]]*obfs-password:[[:space:]]*//' | tr -d "\"'")
    HY_OBFS_MIN=$(grep -E '^[[:space:]]*obfs-min-packet-size:' "$f" | head -1 | sed -E 's/^[[:space:]]*obfs-min-packet-size:[[:space:]]*//' | tr -d "\"'")
    HY_OBFS_MAX=$(grep -E '^[[:space:]]*obfs-max-packet-size:' "$f" | head -1 | sed -E 's/^[[:space:]]*obfs-max-packet-size:[[:space:]]*//' | tr -d "\"'")
}

# 渲染 obfs 块 (缩进 4 空格, 服务端/客户端通用 —— 字段名两侧完全一致)
render_obfs_block() {
    [[ -n "$HY_OBFS" ]] || return 0
    echo "    obfs: $HY_OBFS"
    echo "    obfs-password: $HY_OBFS_PASSWORD"
    [[ -n "$HY_OBFS_MIN" ]] && echo "    obfs-min-packet-size: $HY_OBFS_MIN"
    [[ -n "$HY_OBFS_MAX" ]] && echo "    obfs-max-packet-size: $HY_OBFS_MAX"
    return 0
}

# ---------- ② 原生端口跳跃 (客户端侧, 比 iptables DNAT 更优) ----------
#   ports         adapter/outbound/hysteria2.go:44  语法 "30000-31000" 或 "1000-2000,3000"
#                 逗号/斜杠都接受, 最多 28 段 (common/utils/ranges.go:24-28)
#   hop-interval  adapter/outbound/hysteria2.go:45  ⚠ string 类型、单位秒
#                 只能是单区间 "15-30", 写 "15,30" → invalid range (:248,261-262)
#                 0 < 值 < 5 会被抬到 5s (:253-257)
#   ⚠ listener 侧**没有**这两个字段 (listener/inbound/hysteria2.go:12-42 全文) —— 纯客户端行为
HY_PORTS=""
HY_HOP_INTERVAL=""

read_hop_opts() {
    local f="$1"
    HY_PORTS=$(grep -E '^[[:space:]]*ports:' "$f" | head -1 | sed -E 's/^[[:space:]]*ports:[[:space:]]*//' | tr -d "\"'")
    HY_HOP_INTERVAL=$(grep -E '^[[:space:]]*hop-interval:' "$f" | head -1 | sed -E 's/^[[:space:]]*hop-interval:[[:space:]]*//' | tr -d "\"'")
}

render_hop_block() {
    [[ -n "$HY_PORTS" ]] || return 0
    echo "    ports: \"$HY_PORTS\""
    [[ -n "$HY_HOP_INTERVAL" ]] && echo "    hop-interval: \"$HY_HOP_INTERVAL\""
    return 0
}

ask_native_hopping() {
    local range s lo hi bad hop
    local -a segs=()

    while true; do
        printf "  跳跃端口范围 (默认: 30000-31000, 也支持 1000-2000,3000): " >&2
        if ! read -r range; then echo >&2; return 1; fi
        range=$(clean_input "$range")
        [[ -z "$range" ]] && range="30000-31000"

        echo "$range" | grep -qE '^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$' || {
            print_error "格式应为 30000-31000 或 1000-2000,3000"; continue; }

        # 内核把 ports 交给 utils.NewUnsignedRanges[uint16] (adapter/outbound/hysteria2.go:239),
        # 逗号先被换成 / 再切分, 段数 > 28 直接报错 (common/utils/ranges.go:24-28)。
        IFS=',' read -ra segs <<< "$range"
        (( ${#segs[@]} > 28 )) && { print_error "最多 28 段 (内核硬限制, common/utils/ranges.go:26-28)"; continue; }

        bad=0
        # ⚠ 必须先切数组再遍历: "${range//,/ }" 外面带引号不会分词, 循环只会跑一次
        for s in "${segs[@]}"; do
            # 单端口 "5000" 时 %%-* / #*- 都不匹配, lo=hi=5000 —— 行为正确
            lo="${s%%-*}"; hi="${s#*-}"
            # 与面板端口策略一致: 跳跃端口同样拒绝 1-1023 特权段
            (( lo < 1024 || lo > 65535 )) && { print_error "端口越界: $s (需在 1024-65535)"; bad=1; break; }
            if [[ "$s" == *-* ]]; then
                (( hi < lo || hi > 65535 )) && { print_error "端口区间非法: $s"; bad=1; break; }
            fi
        done
        (( bad )) && continue
        break
    done
    HY_PORTS="$range"

    while true; do
        printf "  跳跃间隔 hop-interval 秒 (默认: 30, 可写区间 15-30): " >&2
        if ! read -r hop; then echo >&2; return 1; fi
        hop=$(clean_input "$hop")
        [[ -z "$hop" ]] && hop="30"
        echo "$hop" | grep -qE '^[0-9]+(-[0-9]+)?$' || {
            print_error "格式应为 30 或 15-30 (内核只接受单区间, 写 15,30 会报 invalid range)"; continue; }
        break
    done
    HY_HOP_INTERVAL="$hop"

    local h1="${hop%%-*}"
    (( h1 > 0 && h1 < 5 )) && print_warn "小于 5 秒会被内核静默抬到 5 秒 (adapter/outbound/hysteria2.go:253-257)"
    print_ok "原生端口跳跃: ports=$HY_PORTS hop-interval=$HY_HOP_INTERVAL (仅客户端侧生效)"
    return 0
}

# 端口跳跃总入口: 原生 / iptables / 不开
ask_port_hopping_mode() {
    echo "  端口跳跃 (UDP, 抗封锁):" >&2
    echo "  1) 内核原生 ports/hop-interval (仅客户端, 不动防火墙, 重启不失效)" >&2
    echo "  2) iptables DNAT (服务端改防火墙, 重启后需重加)" >&2
    echo "  3) 不开启" >&2
    printf "  选择 (默认3): " >&2
    if ! read -r choice; then echo >&2; return 1; fi
    case "$(clean_input "$choice")" in
        1) ask_native_hopping "$1" || return 1 ;;
        2) ask_port_hopping "$1" ;;
        *) return 0 ;;
    esac
}

# ---------- ③ masquerade 伪装站 (之前硬编码 https://bing.com) ----------
#   listener/inbound/hysteria2.go:29
#   scheme 仅接受 file / http / https, 否则硬报错 unknown masquerade URL scheme
#   (listener/sing_hysteria2/server.go:155)
#   ⚠ proxy 侧没有该字段, validate.py 也禁止写在 proxies 里
HY_MASQUERADE=""

ask_masquerade() {
    HY_MASQUERADE=""
    echo "  masquerade 伪装站 (被探测时返回的假站点):" >&2
    echo "  1) https://www.bing.com" >&2
    echo "  2) https://www.cloudflare.com" >&2
    echo "  3) 自定义 URL (仅 http/https/file)" >&2
    echo "  4) 关闭" >&2
    printf "  选择 (默认1): " >&2
    if ! read -r choice; then echo >&2; return 1; fi
    case "$(clean_input "$choice")" in
        2) HY_MASQUERADE="https://www.cloudflare.com" ;;
        3)
            printf "  伪装站 URL (例如 https://example.com): " >&2
            if ! read -r u; then echo >&2; return 1; fi
            u=$(clean_input "$u")
            echo "$u" | grep -qE '^(https?|file)://[^[:space:]]+$' || {
                print_error "必须以 http:// / https:// / file:// 开头 (否则内核报 unknown masquerade URL scheme)"
                return 1; }
            HY_MASQUERADE="$u" ;;
        4) return 0 ;;
        *) HY_MASQUERADE="https://www.bing.com" ;;
    esac
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

    ui_menu 1 "IPv4 (0.0.0.0)"
    ui_menu 2 "IPv6 (::)"
    ui_menu 3 "自动"

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
    public_ip=$(m_server_ip)
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
    NODE_TAG="$(m_node_tag Hysteria2 "$num" tls)"
    calc_pin "$CERT_FILE"
    {
        echo "proxies:"
        echo "  - name: $NODE_TAG"
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
        # ---- 选配: 原生端口跳跃 (与 obfs 无互斥, 顺序固定在最后) ----
        render_hop_block
        # ---- 选配: obfs 混淆 (必须与服务端逐字一致) ----
        render_obfs_block
    } > "$out_file"
}

hy2_link() {
    local pw="$1" ip="$2" port="$3" num="$4"
    calc_pin "$CERT_FILE"
    local q obfs_q=""
    if [[ "$CERT_TRUSTED" == "true" ]]; then
        q="sni=$CERT_DOMAIN&insecure=0&alpn=h3&upmbps=50&downmbps=200"
    else
        q="sni=$CERT_DOMAIN&alpn=h3&pin=$CERT_PIN&upmbps=50&downmbps=200"
    fi
    # obfs 分量: 与 YAML 同名字段, 服务端/客户端需逐字一致
    if [[ -n "$HY_OBFS" ]]; then
        obfs_q="&obfs=$HY_OBFS&obfs-password=$HY_OBFS_PASSWORD"
    else
        obfs_q="&obfs=none"
    fi
    echo "hysteria2://$pw@$ip:$port?$q$obfs_q#HY2-$num"
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

    ask_port_hopping_mode "$port" || return 1

    # ---- 选配: obfs 混淆 (服务端/客户端对称) ----
    ask_obfs || return 1

    # ---- 选配: masquerade 伪装站 ----
    ask_masquerade || return 1

    local public_ip
    PUBLIC_IP=$(detect_public_ip) || return 1

    local index
    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"
    META_FILE="$OUT_DIR/${PROTO}_meta-$index.json"

    NODE_TAG="$(m_node_tag Hysteria2 "$index" tls)"
    cat > "$IN_FILE" <<EOF
listeners:
  - name: $NODE_TAG
    type: hysteria2
    listen: "$listen_ip"
    port: $port
    users:
      user1: $password
$(render_obfs_block)
$([[ -n "$HY_MASQUERADE" ]] && printf '    masquerade: %s' "$HY_MASQUERADE")
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
        local obfs
        obfs=$(grep -E '^[[:space:]]*obfs:' "$f" | head -1 | sed -E 's/^[[:space:]]*obfs:[[:space:]]*//')
        printf "${GREEN}%s${RESET}) 端口:${BLUE}%s${RESET} 域名:${YELLOW}%s${RESET} 混淆:${MAGENTA}%s${RESET} 证书:${CYAN}%s${RESET}\n" \
            "$num" "${port:-N/A}" "${dom:-N/A}" "${obfs:-关}" "${cert:-N/A}" >&2
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
            # 即使是自签, 也可能有别的节点在用同一份 —— 实测一个 cert 被
            # 5 个节点共用, 删掉会让其余 TLS 节点全部 parse certificate
            # failed, 而面板当时还显示"运行中"。m_cert_gc 会先查引用。
            if m_cert_gc "$CERT_DIR/cert-$dom.crt" "$CERT_DIR/key-$dom.key"; then
                : # 已按引用情况处理
            fi
            print_ok "已删除 $pad"
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
    # 选配: 读回 obfs / 原生端口跳跃, 保证重建后与子配置一致
    read_obfs_opts "$IN_FILE"
    read_hop_opts "$IN_FILE"
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
    # 选配: 读回 obfs / 原生端口跳跃
    read_obfs_opts "$in_file"
    read_hop_opts "$in_file"
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

        ui_menu 1 "查看配置"
        ui_menu 2 "新增配置"
        ui_menu 3 "删除配置"
        ui_menu 4 "重建客户端文件"
        ui_menu 5 "导出所有节点订阅"
        ui_menu 0 "退出"

        printf "选择: " >&2
        if ! read -r c; then echo >&2; exit 0; fi   # EOF 防刷屏
        c=$(clean_input "$c")

        case "$c" in
            1) list_configs ;;
            2) add_config; m_sync_reload ;;
            3) delete_config; m_sync_reload ;;
            4) rebuild_client ;;
            5) export_subscription ;;
            0) exit 0 ;;
            *) ui_invalid "$c" ;;
        esac

        printf "回车继续..." >&2
        if ! read -r; then echo >&2; exit 0; fi     # EOF 防刷屏
    done
}

main_menu
