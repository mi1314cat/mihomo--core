#!/bin/bash

# ================================
# 彩色定义
# ================================
RED="\e[31m"
# UI 原语统一来自 src/lib/ui.sh (颜色/消息分级/标题), 此处不再重复定义。
# 被父级 source 时已加载; 单独运行时由下面的兜底 source 补上。

# ================================
# 基础路径
# ================================
PROTO="anytls"
BASE_DIR="/root/catmi/mihomo"
CONF_DIR="$BASE_DIR/conf/config.d"
OUT_DIR="$BASE_DIR/out"
CERT_DIR="$BASE_DIR/conf/certs"


# ---------- 共享库 (src/lib/env.sh) ----------
# 提供: 路径常量 / 环境变量读写 / Reality dest 选择 / 合并+严格校验+重载闭环
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRV_ROOT="$BASE_DIR"
MIHOMO_BIN="$BASE_DIR/mihomo"
source "$SELF_DIR/../lib/env.sh"

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
    # 六份重复实现已收敛到 env.sh 的 m_safe_read_port:
    #   拒绝 1-1023 特权端口与系统常用端口, TCP/UDP 双查占用, EOF 安全退出。
    m_safe_read_port "$1"
}

# ================================================================
# 选配 (M 内核 / mihomo v1.19.32 特有字段)
# 每条都标了内核源码位置; 没有源码依据的一律不做。
# ================================================================

# ---------- ① padding-scheme 抗主动探测填充 (★ 只有 listener 能配) ----------
#   listener/inbound/anytls.go:24  inbound:"padding-scheme"
#   消费点 listener/anytls/server.go:127-133
#     ⚠ 格式错 → listener 启动直接失败: incorrect padding scheme format (:129)
#     ⚠ 唯一硬要求: 必须有可 Atoi 的 stop=  (transport/anytls/padding/padding.go:51-55)
#   ⚠ **proxy 侧没有这个字段** (adapter/outbound/anytls.go:27-51 全文),
#     客户端无条件用内置默认 (transport/anytls/client.go:49-50);
#     真实方案由服务端通过 cmdUpdatePaddingScheme 帧下发
#     (transport/anytls/session/frame.go:14 + session/session.go:274-283)。
#     → 所以这个选配**只在服务端生效**, 客户端不需要也不能配。
#   键 = 十进制报文类型序号 (padding.go:60-61); 值 = 逗号分隔的 min-max 或字面量 c
#     (:62-88); <=0 的项静默丢弃 (:77-79); min>max 自动交换 (:74-76)
# 内置默认方案逐字抄自 transport/anytls/padding/padding.go:17-25
ANYTLS_PADDING_DEFAULT="stop=8
0=30-30
1=100-400
2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
3=9-9,500-1000
4=500-1000
5=500-1000
6=500-1000
7=500-1000"

PADDING_BLOCK=""

# 渲染 listener 侧 padding-scheme (YAML 块标量 |, 键缩进 4, 内容缩进 6)
render_padding_block() {
    local scheme="$1" line
    [[ -n "$scheme" ]] || return 0
    echo "    padding-scheme: |"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        echo "      $line"
    done <<< "$scheme"
    return 0
}

# 校验 scheme: 每行 k=v; v 为逗号分隔的 min-max 或 c; 必须含 stop=
_validate_padding_scheme() {
    local scheme="$1" line key val item has_stop=false
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == *=* ]] || { print_error "每行必须写成 k=v (例: stop=8), 收到: $line"; return 1; }
        key="${line%%=*}"; val="${line#*=}"
        [[ "$key" =~ ^[0-9]+$ || "$key" == "stop" ]] || {
            print_error "键只能是 stop 或十进制报文序号 0..N, 收到: $key"; return 1; }
        [[ "$key" == "stop" ]] && has_stop=true
        for item in ${val//,/ }; do
            if [[ "$item" != "c" && ! "$item" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
                print_error "值只能写 数字 / 数字-数字 / 字面量 c, 收到: $item (在 $key 行)"
                return 1
            fi
            if [[ "$item" =~ ^[0-9]+$ ]] && (( item <= 0 )); then
                print_warn "$key=$item 会被内核静默丢弃 (padding.go:77-79)"
            fi
        done
    done <<< "$scheme"
    if [[ "$has_stop" != "true" ]]; then
        print_error "必须有 stop=<整数>, 否则 listener 启动报 incorrect padding scheme format"
        return 1
    fi
    return 0
}

ask_padding() {
    PADDING_BLOCK=""
    echo "  抗主动探测填充 padding-scheme (服务端侧选配):" >&2
    echo "  ⚠ 只有 listener 能配这个字段; 客户端走内置默认, 真实方案由服务端协议帧下发。" >&2
    echo "    (依据: listener/inbound/anytls.go:24 有; adapter/outbound/anytls.go:27-51 没有)" >&2
    echo "  1) 不写 (内核默认, 推荐)" >&2
    echo "  2) 显式写入内核默认 (行为一致, 只是配置里看得见)" >&2
    echo "  3) 自定义 (每行 k=v, 必须含 stop=)" >&2
    printf "  选择 (默认1): " >&2
    local c="" scheme=""
    read -r c || c=""
    c=$(clean_input "$c")
    case "$c" in
        2)
            scheme="$ANYTLS_PADDING_DEFAULT"
            ;;
        3)
            print_info "逐行输入 k=v, 空行结束。键: stop 或报文序号; 值: min-max / c / 它们的逗号组合"
            local line
            while true; do
                printf "    > " >&2
                read -r line || { echo >&2; break; }
                line=$(clean_input "$line")
                line="${line#"${line%%[![:space:]]*}"}"
                [[ -z "$line" ]] && break
                scheme+="$line"$'\n'
            done
            _validate_padding_scheme "$scheme" || { print_error "自定义方案不合法, 已放弃 (不写该字段)"; return 0; }
            ;;
        *)
            return 0
            ;;
    esac
    PADDING_BLOCK="$(render_padding_block "$scheme")"
    return 0
}

# ---------- ② client-fingerprint (AnyTLS 是三个 QUIC 协议里唯一有这个字段的) ----------
#   adapter/outbound/anytls.go:39
#   取值表 component/tls/utls.go:78-101 (init() 动态追加 randomized, :103-111)
#   ⚠ 未知值只 log.Warnln 并**静默降级成原生 TLS** (utls.go:56-59) —— 必须从枚举里选
#   ⚠ 不暴露 deprecated 的 5 个 (chrome_psk 等, utls.go:94-99 注释已标 deprecated)
#   ⚠ 'none'/空 = 关闭 uTLS 用原生 Go TLS (:43-45) —— 抗识别最差, 不进菜单
CLIENT_FP="chrome"

ask_fp() {
    echo "  TLS 客户端指纹 client-fingerprint (抗 JA3/JA4 识别):" >&2
    echo "  1) chrome (默认)" >&2
    echo "  2) firefox" >&2
    echo "  3) safari" >&2
    echo "  4) edge" >&2
    echo "  5) ios" >&2
    echo "  6) android" >&2
    echo "  7) random (每次启动加权随机: chrome6/safari3/ios2/firefox1)" >&2
    printf "  选择 (默认1): " >&2
    local c=""
    read -r c || c=""
    c=$(clean_input "$c")
    case "$c" in
        2) CLIENT_FP="firefox" ;;
        3) CLIENT_FP="safari" ;;
        4) CLIENT_FP="edge" ;;
        5) CLIENT_FP="ios" ;;
        6) CLIENT_FP="android" ;;
        7) CLIENT_FP="random" ;;
        *) CLIENT_FP="chrome" ;;
    esac
    return 0
}

# ---------- ③ idle-session-* 会话复用参数 (仅客户端) ----------
#   adapter/outbound/anytls.go:47-48
#   ⚠ <=5 秒会被内核**静默抬成 30 秒** (transport/anytls/session/client.go:50-55)
#     → 菜单里只给 >= 6 的值
IDLE_CHECK="30"
IDLE_TIMEOUT="30"

ask_idle() {
    IDLE_CHECK="30"; IDLE_TIMEOUT="30"
    while true; do
        printf "  空闲会话检查间隔 idle-session-check-interval 秒 (默认 30, 最小 6): " >&2
        local v=""
        read -r v || v=""
        v=$(clean_input "$v")
        [[ -z "$v" ]] && v="30"
        [[ "$v" =~ ^[0-9]+$ ]] || { print_error "请输入正整数"; continue; }
        (( v >= 6 )) || { print_error "必须 >= 6 秒 (小于等于 5 秒会被内核静默抬成 30 秒)"; continue; }
        IDLE_CHECK="$v"
        break
    done
    while true; do
        printf "  空闲会话超时 idle-session-timeout 秒 (默认 30, 最小 6): " >&2
        local v=""
        read -r v || v=""
        v=$(clean_input "$v")
        [[ -z "$v" ]] && v="30"
        [[ "$v" =~ ^[0-9]+$ ]] || { print_error "请输入正整数"; continue; }
        (( v >= 6 )) || { print_error "必须 >= 6 秒 (小于等于 5 秒会被内核静默抬成 30 秒)"; continue; }
        IDLE_TIMEOUT="$v"
        break
    done
    return 0
}

# 从子配置顶部的注释行读回仅客户端的选配
read_client_opts() {
    local f="$1" v=""
    CLIENT_FP="chrome"
    IDLE_CHECK="30"
    IDLE_TIMEOUT="30"
    v=$(grep -E '^[[:space:]]*# fp:' "$f" | head -1 | sed -E 's/.*# fp:[[:space:]]*//') || true
    [[ -n "$v" ]] && CLIENT_FP="$v"
    v=$(grep -E '^[[:space:]]*# idle:' "$f" | head -1 | sed -E 's/.*# idle:[[:space:]]*//') || true
    if [[ -n "$v" ]]; then
        IDLE_CHECK="${v%%/*}"
        IDLE_TIMEOUT="${v#*/}"
    fi
    return 0
}

# 渲染仅客户端的选配块 (缩进 4, 与 add/rebuild/export/silent 四条路径共用)
render_client_opts() {
    echo "    client-fingerprint: $CLIENT_FP"
    echo "    idle-session-check-interval: $IDLE_CHECK"
    echo "    idle-session-timeout: $IDLE_TIMEOUT"
    return 0
}

# ================================
# 自动生成证书
# ================================

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
    # 必须检查返回值: m_safe_read_port 在 stdin 关闭 (EOF) 时返回 1 且不输出,
    # 不检查就会写出一个 `port:` 为空的死节点, 而校验链全放行
    ANYTLS_PORT=$(safe_read_port "$default_port") || {
        print_error "未指定端口, 已取消创建"
        return 1
    }
    [[ -n "$ANYTLS_PORT" ]] || { print_error "端口为空, 已取消创建"; return 1; }

    # 4. 自动生成域名（证书）
    DOMAIN="cloudflare.com"
    generate_cert "$DOMAIN"

    # 5. 自动编号
    index=$(get_next_index)

    IN_FILE="$CONF_DIR/$PROTO-$index.yaml"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$index.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$index.txt"

    # 6. 获取服务器 IP
    SERVER_IP=$(m_server_ip)

    if [[ "$SERVER_IP" =~ : ]]; then
        LINK_IP="[$SERVER_IP]"
    else
        LINK_IP="$SERVER_IP"
    fi

    # 7. 询问可选特性 (mTLS / smux / 指纹 / 空闲会话 / 服务端 padding)
    ask_features
    if $MTLS_ENABLED; then
        gen_mtls_cert "$index"
    fi
    render_smux
    ask_fp
    ask_idle
    ask_padding

    # 8. 写入入站配置（Mihomo AnyTLS）
NODE_TAG="$(m_node_tag AnyTLS "$index" tls)"
cat > "$IN_FILE" <<EOF
# mtls: $MTLS_ENABLED
# smux: ${SMUX_PROFILE:-false}
# fp: $CLIENT_FP
# idle: $IDLE_CHECK/$IDLE_TIMEOUT
listeners:
  - name: $NODE_TAG
    type: anytls
    listen: "0.0.0.0"
    port: $ANYTLS_PORT
    users:
      $UUID: $PASSWORD
    certificate: $CERT_FILE
    private-key: $KEY_FILE
$([ "$MTLS_ENABLED" = true ] && printf '    client-auth-type: RequireAndVerifyClientCert\n    client-auth-cert: %s' "$MTLS_CA")
$PADDING_BLOCK
EOF

    # 9. 写入客户端配置（Clash Meta）
NODE_TAG="$(m_node_tag AnyTLS "$num2" tls)"
cat > "$OUT_FILE" <<EOF
proxies:
  - name: anytls
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    password: $PASSWORD
    sni: $DOMAIN
$(render_client_opts)
    udp: true
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF

    # 10. 写入分享链接
echo "anytls://$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1&fp=$CLIENT_FP#AnyTLS-$index" > "$SHARE_FILE"

    # 11. 输出信息
    print_ok "AnyTLS 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $ANYTLS_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "密码: $PASSWORD" >&2
    echo -e "SNI: $DOMAIN" >&2
    echo -e "指纹: $CLIENT_FP | 空闲会话: ${IDLE_CHECK}s/${IDLE_TIMEOUT}s" >&2
    [[ -n "$PADDING_BLOCK" ]] && echo -e "padding-scheme: 已显式写入 (仅服务端 listener 生效, 客户端由服务端帧下发)" >&2
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
    # 删除节点时同步清理它的 Nginx 回源配置并 reload。
    # 键用片段文件名 (vless-01 / trojan-02), 与创建时登记的一致;
    # 没有 CDN 绑定的节点这里直接返回 0, 不会有副作用。
    cdn_node_unregister "$(basename "$IN_FILE" .yaml)" 2>/dev/null || true
    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE" 

    # 记下"这次删掉的是哪个协议桶", 供菜单项在**重载成功之后**吊销分享链接。
    # 不能在这里直接吊销: 重载失败会回滚, 那时节点还在, 链接却已经废了
    # (清空路径 server.sh 里记过这个反序踩坑)。
    _DELETED_PROTO_TAG="$PROTO"

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
    read_client_opts "$IN_FILE"
    render_smux

    SERVER_IP=$(m_server_ip)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"
    if $MTLS_ENABLED; then
        MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
        MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
    fi

NODE_TAG="$(m_node_tag AnyTLS "$num2" tls)"
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    password: $PASSWORD
    sni: $DOMAIN
$(render_client_opts)
    udp: true
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF

    SHARE_LINK="anytls://$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1&fp=$CLIENT_FP#AnyTLS-$num2"
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
        read_client_opts "$f"
        if $MTLS_ENABLED; then
            MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
            MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
        fi

        SERVER_IP=$(m_server_ip)
        [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

        SHARE_LINK="anytls://$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1&fp=$CLIENT_FP#AnyTLS-$num2"

cat >> "$SUB_FILE" <<EOF

# ============================
# AnyTLS-$num2$($MTLS_ENABLED && echo " (mTLS)")$([[ -n "$SMUX_PROFILE" ]] && echo " ($SMUX_PROFILE smux)")
# ============================
  - name: $NODE_TAG
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    password: $PASSWORD
    sni: $DOMAIN
$(render_client_opts)
    udp: true
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
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
    read_client_opts "$IN_FILE"
    render_smux

    SERVER_IP=$(m_server_ip)
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"
    if $MTLS_ENABLED; then
        MTLS_CLIENT_CERT=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.pem")
        MTLS_CLIENT_KEY=$(awk 'NF' "$CERT_DIR/mtls-$PROTO-$num2/client.key")
    fi

NODE_TAG="$(m_node_tag AnyTLS "$num2" tls)"
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: anytls
    server: $SERVER_IP
    port: $ANYTLS_PORT
    password: $PASSWORD
    sni: $DOMAIN
$(render_client_opts)
    udp: true
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
$([ "$MTLS_ENABLED" = true ] && printf '    certificate: |\n%s\n    private-key: |\n%s' "$(echo "$MTLS_CLIENT_CERT" | sed 's/^/      /')" "$(echo "$MTLS_CLIENT_KEY" | sed 's/^/      /')")
$SMUX_BLOCK
EOF

    SHARE_LINK="anytls://$PASSWORD@$LINK_IP:$ANYTLS_PORT?sni=$DOMAIN&insecure=1&fp=$CLIENT_FP#AnyTLS-$num2"
    echo "$SHARE_LINK" > "$SHARE_FILE"

    
}


# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Mihomo AnyTLS 管理面板（独立版）"

        ui_menu 1 "查看配置"
        ui_menu 2 "新增配置"
        ui_menu 3 "删除配置"
        ui_menu 4 "重建客户端文件"
        ui_menu 5 "导出所有节点订阅（Clash/Mihomo）"
        ui_menu 0 "退出"


        printf "请选择: " >&2
        read c || { printf "\n[信息] 非交互环境 (stdin 已关闭), 已退出\n" >&2; break; }
        c=$(clean_input "$c")

        case $c in
            1) list_configs ;;
            2) add_config; m_sync_reload ;;
            3) _DELETED_PROTO_TAG=""; delete_config; m_sync_reload && share_revoke_on_delete "${_DELETED_PROTO_TAG:-}" ;;
            4) rebuild_client ;;
            5) export_subscription ;;
            0) exit 0 ;;
            *) ui_invalid "$c" ;;
        esac

        printf "按回车继续..." >&2
        read || break
    done
}

main_menu
