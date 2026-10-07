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
PROTO="reality"
# 根目录解析。原来这里是裸的 BASE_DIR="/root/catmi/mihomo" (硬编码生产路径),
# 后面又用 SRV_ROOT="$BASE_DIR" 盖回去 —— 面板装在别处时会读写错目录, 测试时
# 只传 SRV_ROOT 也无效 (会被改回真实路径)。语义与 server.sh 对齐。
if [[ -z "${BASE_DIR:-}" ]]; then
    if [[ -n "${SRV_ROOT:-}" ]]; then
        BASE_DIR="$SRV_ROOT"
    else
        _bd="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
        if [[ -n "$_bd" && -d "$_bd/src/lib" ]]; then BASE_DIR="$_bd"; else BASE_DIR="/root/catmi/mihomo"; fi
        unset _bd
    fi
fi
CONF_DIR="$BASE_DIR/conf/config.d"
OUT_DIR="$BASE_DIR/out"
ENV_FILE="$BASE_DIR/install_info.env"
PUB_DIR="$OUT_DIR/pub"
PUB_ENV="$PUB_DIR/public_key.env"


# ---------- 共享库 (src/lib/env.sh) ----------
# 提供: 路径常量 / 环境变量读写 / Reality dest 选择 / 合并+严格校验+重载闭环
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRV_ROOT="$BASE_DIR"
MIHOMO_BIN="$BASE_DIR/mihomo"
source "$SELF_DIR/../lib/env.sh"

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
    # 六份重复实现已收敛到 env.sh 的 m_safe_read_port:
    #   拒绝 1-1023 特权端口与系统常用端口, TCP/UDP 双查占用, EOF 安全退出。
    m_safe_read_port "$1"
}

# ★ 端口区间必须与 all.sh 的 PORT_CURSOR 起点 (20000) 和界面口径一致。
#   原来这里是 10000-60000, 而 all.sh 从 20000 起顺延, 统计口径又是
#   20000-29999 —— 三者各说各话。后果: 手工建的节点约 60% 落在 30000 以上,
#   状态栏「运行中的协议端口」**少报甚至报 0** (实测 4 个真实 socket 显示 1),
#   用户会以为节点没起来。update_config 的"占用端口"列表也用同一个过滤器,
#   同样漏 (31 个节点只列 23 个)。
random_port() { shuf -i 20000-29999 -n 1; }

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

# ================================================================
# 选配 (M 内核 / mihomo v1.19.32 特有字段)
# 每条都标了内核源码位置; 没有源码依据的一律不做。
# ================================================================

# ---------- ① client-fingerprint (★ Reality 的硬约束) ----------
#   字段: adapter/outbound/vless.go:90
#   ⚠ **硬约束**: REALITY 基于 uTLS, 不配 client-fingerprint 会在**首次 TLS 握手**报
#     "REALITY is based on uTLS, please set a client-fingerprint"
#     (transport/vmess/tls.go:130-132) —— `mihomo -t` 抓不到, 只有真连才炸。
#   取值表 component/tls/utls.go:78-101 (init() 动态追加 randomized, :103-111)
#   ⚠ 未知值只 log.Warnln 后**静默降级成原生 TLS** (utls.go:56-59) —— 必须从枚举里选
CLIENT_FP="chrome"

# ---------- ② xudp / packet-addr 二选一 ----------
#   字段: adapter/outbound/vless.go:68 (packet-addr) / :69 (xudp)
#   语义 adapter/outbound/vless.go:474-485:
#     packet-encoding 只认 "packetaddr"/"packet" (:475); 其它值全落 default 分支,
#     default 分支做的是 `if !PacketAddr { XUDP = true }` (:478-481) —— 所以原来写的
#     `packet-encoding: xudp` 并不是"被忽略", 而是被 default 分支顺手打开了 xudp;
#     但它是 legacy 别名, 语义不直白, 改成 `xudp: true` 更清楚。
#     另外 :483-485 `if XUDP { PacketAddr = false }` —— 两者同时写时 xudp 赢,
#     所以这里做成二选一, 不给用户"两个都开"的假选项。
#   ⚠ 但要如实告知: 本脚本 listener 端固定 flow: xtls-rprx-vision, 而
#     vision 流在**服务端根本不接受 UDP** (listener/sing_vless/service.go:136-139
#     "xtls-rprx-vision flow does not support UDP"), 所以这两种封装方式在
#     Reality+vision 组合下实际都是空转 —— 选了会明确提示。
# PKT_MODE: xudp | packet-addr | off
PKT_MODE="xudp"

ask_client_fp() {
    echo "  TLS 客户端指纹 client-fingerprint (REALITY 硬性要求, 缺失首次握手即报错):" >&2
    echo "  1) chrome (默认)" >&2
    echo "  2) firefox" >&2
    echo "  3) safari" >&2
    echo "  4) edge" >&2
    echo "  5) ios" >&2
    echo "  6) android" >&2
    echo "  7) random (加权随机 chrome6/safari3/ios2/firefox1)" >&2
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
}

ask_pkt_mode() {
    echo "  UDP 封装方式 (xudp / packet-addr 二选一, 内核里同时写时 xudp 优先):" >&2
    echo "  1) xudp (默认; XUDP 封装)" >&2
    echo "  2) packet-addr (全包地址)" >&2
    echo "  3) 不写 (走内核默认)" >&2
    printf "  选择 (默认1): " >&2
    local c=""
    read -r c || c=""
    c=$(clean_input "$c")
    case "$c" in
        2) PKT_MODE="packet-addr" ;;
        3) PKT_MODE="off" ;;
        *) PKT_MODE="xudp" ;;
    esac
    if [[ "$PKT_MODE" != "off" ]]; then
        print_warn "本脚本 Reality 服务端固定 flow: xtls-rprx-vision, 而 vision 流在服务端拒绝 UDP"
        print_warn "(listener/sing_vless/service.go:136-139), 因此 ${PKT_MODE} 在本节点上不会真正生效"
    fi
    return 0
}

# 渲染 UDP 封装块 (缩进 4)
render_pkt_block() {
    case "$PKT_MODE" in
        xudp)       echo "    xudp: true" ;;
        packet-addr) echo "    packet-addr: true" ;;
    esac
    return 0
}

# ================================================================
# 特性询问（smux / xudp 可选项）
# 选择持久化到 config.d 片的注释行: # smux: <档位> / # xudp: true / # fp: <指纹>
# ================================================================
ask_features() {
    local yn
    SMUX_PROFILE=""
    XUDP_ENABLED=false

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

    # ---- 选配: UDP 封装 (原来是 legacy 的 packet-encoding: xudp) ----
    ask_pkt_mode

    # ---- 选配: client-fingerprint (原本硬编码 chrome) ----
    ask_client_fp
}

# 读取 config.d 片注释中的特性标记（供重建/导出时同步）
# 兼容旧格式 "# smux: true" -> 视为 web 档
read_features() {
    local f="$1"
    SMUX_PROFILE=""
    XUDP_ENABLED=false
    CLIENT_FP="chrome"
    PKT_MODE="xudp"
    if grep -qE "^[[:space:]]*# smux: (web|video|download)" "$f"; then
        SMUX_PROFILE=$(grep -oE "^[[:space:]]*# smux: (web|video|download)" "$f" | awk '{print $3}')
    elif grep -qE "^[[:space:]]*# smux: true" "$f"; then
        SMUX_PROFILE="web"
    fi
    grep -qE "^[[:space:]]*# xudp: true" "$f" && XUDP_ENABLED=true
    # 选配回读: 新写法优先; 没有注释的老配置按老标记 (xudp: true -> xudp, 否则 off)
    local v
    v=$(grep -E "^[[:space:]]*# pkt-mode:" "$f" | head -1 | sed -E 's/.*# pkt-mode:[[:space:]]*//')
    if [[ -n "$v" ]]; then
        PKT_MODE="$v"
    elif grep -qE "^[[:space:]]*# xudp: true" "$f"; then
        PKT_MODE="xudp"
    else
        PKT_MODE="off"
    fi
    v=$(grep -E "^[[:space:]]*# fp:" "$f" | head -1 | sed -E 's/.*# fp:[[:space:]]*//')
    [[ -n "$v" ]] && CLIENT_FP="$v"
    return 0
}

# 渲染 smux 客户端配置块（按档位）；输出到变量 SMUX_BLOCK
render_smux() {
    SMUX_BLOCK=""
    _smux_on "${SMUX_PROFILE-}" || return
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
# 新增 Reality 配置
# ================================
add_config() {
    print_title "新增 Reality 配置"

    # 环境准备: 复用/生成 install_info.env
    # 原先依赖 One-click-script 的 update_env.sh + load_env.sh + domains.sh,
    # 现改为本地实现 (src/lib/env.sh), 外部脚本不可达时不再整条链路失败。
    if [[ ! -x "$MIHOMO_BIN" ]]; then
        print_error "未找到 mihomo 内核: $MIHOMO_BIN"
        print_info "请先从主菜单安装 Mihomo"
        return
    fi

    if [[ ! -f "$ENV_FILE" ]] || ! m_load_env "$ENV_FILE"; then
        print_info "首次使用, 正在生成环境变量..."
        bash "$SELF_DIR/XRevise.sh" || { print_error "环境变量生成失败"; return; }
    fi
    m_load_env "$ENV_FILE"

    # Reality dest 站点
    #
    # 顺序: 先从用户在 One-click-script/domains.sh 里**统一维护**的域名池现取,
    # 取不到才退回本地名单 (REALITY_DESTS)。
    #
    # 为什么不直接用本地名单: 那 8 个是写死在 env.sh 里的快照, 而域名池是
    # 用户经常维护的。域名会过期 (换 CDN / 改 ALPN / 下线), REALITY 的失败
    # 方式又极其隐蔽 —— 客户端报 "REALITY authentication failed", 服务端
    # 一条日志都没有, 面板全绿, 只有用户连不上。用户更新了域名池, 这边却
    # 还在用几个月前的快照, 那这个"统一管理"就白做了。
    #
    # ⚠ 不能复用已加载的 $dest_server: install_info.env 里的旧值正是
    #   陈旧值的来源, 复用它就等于永远不刷新。
    REALITY_DEST_FROM_POOL=""
    if _rd=$(m_auto_website 2>/dev/null) && [[ -n "$_rd" ]]; then
        REALITY_DEST_FROM_POOL="$_rd"
        print_info "REALITY 伪装域名 (来自 domains.sh 域名池): $REALITY_DEST_FROM_POOL"
    else
        print_warn "未能从 domains.sh 取到伪装域名, 改用本地候选名单"
    fi
    m_pick_dest "$REALITY_DEST_FROM_POOL" || return
    # 同步: m_pick_dest 设的是 DEST_SERVER, 本文件消费的是 dest_server。
    # 不加这一行, 上面从域名池取来的域名会被丢掉, 节点里写的还是 env 旧值。
    dest_server="$DEST_SERVER"

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

    # 4.5 先问"要哪种推荐配置" —— 与 VLESS/Trojan/AnyTLS 等保持一致。
    #     REALITY 预设以前挂在 vless 段, 而 VLESS.sh 产不出 REALITY, 于是
    #     「① 隐匿优先 · REALITY」静默降级成纯 TLS。现在挂回这里 ——
    #     **抗 DPI 最强的那档, 本来就该在这里**。
    preset_ask reality "REALITY 推荐配置"

    # 询问可选特性 (smux / xudp)
    # ⚠ preset_reset 必须放在 ask_features **之后** —— 它会清掉
    #   M_PRESET_APPLIED / M_PRESET_TR, 而 ask_features 靠这两个跳过提问。
    ask_features
    render_smux
    preset_reset

    # 写 Reality 入站配置
NODE_TAG="$(m_node_tag VLESS "$index" reality)"
cat > "$IN_FILE" <<EOF
# smux: ${SMUX_PROFILE:-false}
# xudp: $XUDP_ENABLED
# pkt-mode: $PKT_MODE
# fp: $CLIENT_FP
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "0.0.0.0"
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
    #
    # 对外地址必须走 m_server_ip: 它会自检"这个地址是否真在本机网卡上"。
    # 套 WARP / 透明代理时 install_info.env 里的 PUBLIC_IP 很可能是**出口地址**,
    # 直接写进去客户端一个都连不上 —— 实测本机写出 <WARP_EXIT_IP> (WARP 出口),
    # 真实地址是 <REAL_SERVER_IP>, 分享链接与客户端配置双双作废。
    # 其余协议脚本 (VLESS/Trojan/TUIC/AnyTLS/hysteria2) 与 all.sh 早就走
    # m_server_ip, 这里此前是全项目唯一的例外。
    SERVER_IP=$(m_server_ip)
    if [[ -z "$SERVER_IP" ]]; then
        print_error "拿不到对外地址, 无法生成客户端配置 (可在 install_info.env 里设 PUBLIC_IP)"
        return 1
    fi
    [[ "$SERVER_IP" =~ : ]] && LINK_IP="[$SERVER_IP]" || LINK_IP="$SERVER_IP"

    # 编号变量是 $index; $num 在 add_config 里从未赋值, 而 m_node_tag 对空 index
    # 直接 return 1 -> 客户端 name 写成空串 -> build_sub.py 丢掉空名节点,
    # Reality 节点因此从不出现在任何分享/订阅里。
NODE_TAG="$(m_node_tag VLESS "$index" reality)"
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
    type: vless
    server: $SERVER_IP
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
    client-fingerprint: $CLIENT_FP
$SMUX_BLOCK
$(render_pkt_block)
EOF

    # 写 Reality 分享链接
    # 同样用自检过的 $LINK_IP, 不用 install_info.env 里的 $link_ip —— 后者可能是
    # WARP/代理出口地址, 分享出去对方必然连不上。
echo "vless://$UUID@$LINK_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=$CLIENT_FP&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#Reality-$index" > "$SHARE_FILE"

    print_ok "Reality 配置生成成功"
    echo -e "编号: $index" >&2
    echo -e "端口: $REALITY_PORT" >&2
    echo -e "UUID: $UUID" >&2
    echo -e "SNI: $dest_server" >&2
    _smux_on "${SMUX_PROFILE-}" && echo -e "smux: 已启用 ($SMUX_PROFILE 档)" >&2
    $XUDP_ENABLED && echo -e "xudp: 已启用" >&2
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

    # 删除节点时同步清理它的 Nginx 回源配置并 reload。
    # 键用片段文件名 (vless-01 / trojan-02), 与创建时登记的一致;
    # 没有 CDN 绑定的节点这里直接返回 0, 不会有副作用。
    cdn_node_unregister "$(basename "$IN_FILE" .yaml)" 2>/dev/null || true
    rm -f "$IN_FILE"
    # 产物有两套命名 (单协议 / 批量 all.sh), 两套都要删, 否则批量生成的节点
    # 会留下孤儿产物 —— 它照样被 build_sub.py 收进订阅。见 m_out_rm_artifacts。
    m_out_rm_artifacts "$PROTO" "$num2" >/dev/null

    # 记下"这次删掉的是哪个协议桶", 供菜单项在**重载成功之后**吊销分享链接。
    # 不能在这里直接吊销: 重载失败会回滚, 那时节点还在, 链接却已经废了
    # (清空路径 server.sh 里记过这个反序踩坑)。
    _DELETED_PROTO_TAG="$PROTO"

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

    read_features "$IN_FILE"
    render_smux

    SERVER_IP=$(m_server_ip)

NODE_TAG="$(m_node_tag VLESS "$num" reality)"
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
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
    client-fingerprint: $CLIENT_FP
$SMUX_BLOCK
$(render_pkt_block)
EOF

    SHARE_LINK="vless://$uuid@$SERVER_IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=$CLIENT_FP&pbk=$public_key&sid=$short_id&type=tcp#Reality-$num"

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

    read_features "$IN_FILE"
    render_smux

    SERVER_IP=$(m_server_ip)

NODE_TAG="$(m_node_tag VLESS "$num" reality)"
cat > "$OUT_FILE" <<EOF
proxies:
  - name: $NODE_TAG
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
    client-fingerprint: $CLIENT_FP
$SMUX_BLOCK
$(render_pkt_block)
EOF

    echo "vless://$uuid@$SERVER_IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=$CLIENT_FP&pbk=$public_key&sid=$short_id&type=tcp#Reality-$num" > "$SHARE_FILE"
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

        ui_menu 1 "查看配置"
        ui_menu 2 "新增配置"
        ui_menu 3 "删除配置"
        ui_menu 4 "重建客户端文件"
        ui_menu 5 "导出所有节点订阅"
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
# 直接跑本脚本 = 管理面板 (查看/新增/删除)。
# 从服务端面板「添加节点」进来时, 目标是**新增一个**, 不该再让人选一次
# 「2) 新增配置」—— 那层二级菜单在"一路回车"的批量场景下会把所有回车
# 吃成「无效选项:」, 最后节点数仍是 0, 而界面没有任何异常提示。
case "${1:-}" in
    add|"")
        if [[ "${1:-}" == "add" ]]; then
            add_config; m_sync_reload
            exit 0
        fi
        ;;
esac
main_menu
