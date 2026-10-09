#!/usr/bin/env bash
# =============================================================
# mihomo--core · 局域网配置分发 (客户端)
#
# 用途: 把本客户端**正在用的这份完整配置**以 URL 形式提供给局域网里的其他
# 设备, 让它们导入后直接可用。
#
# 不是中转代理 —— 别的设备拿到配置后自己连服务器、自己解析 DNS。
#
# 为什么单独起一个 HTTP 服务, 而不是复用 Clash API 的端口:
#   - external-controller 只暴露 /proxies 这类运行时接口, 不提供任意文件下载;
#   - mixed-port 走的是代理流量, 不能混;
#   - 端口独立, 换端口不影响客户端本身。
#
# 对齐 SB 的 SUB_SERVER 设计。两条必须照搬的原则:
#   1. **每次请求实时合并配置**, 不读快照 —— 否则会出现"节点早删了、快照
#      还没刷新", 别的设备拿到的是已经废弃的节点。
#   2. **分发前剥掉本机专属段** (mixed-port / external-controller / external-ui
#      / secret)。这些是本机绝对路径和端口, 硬塞到别的设备上要么端口冲突,
#      要么把本机代理暴露出去。
#
# 分发内容经过防火墙登记 (fw_open_port), 关闭时按登记表精确回收。
# =============================================================

SUB_STATE_DIR=""                       # share-state 目录, 由 lan_dispatch_init 赋值
SUB_TOKEN_FILE=""

lan_dispatch_init() {
    SUB_STATE_DIR="${CLI_ROOT}/share-state"
    SUB_TOKEN_FILE="${SUB_STATE_DIR}/sub-token"
    : "${LAN_SUB_PORT:=19100}"
}

lan_sub_token() {
    lan_dispatch_init
    [[ -f "$SUB_TOKEN_FILE" ]] || (mkdir -p "$SUB_STATE_DIR" && \
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$SUB_TOKEN_FILE")
    cat "$SUB_TOKEN_FILE"
}

# 局域网可达的本机地址。
# 不能用 127.0.0.1 —— 别的设备访问不到。取默认路由的源地址最准。
lan_host_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
    [[ -n "$ip" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s\n' "${ip:-127.0.0.1}"
}

# 生成可分发的配置 —— **唯一实现**在 src/share/lan_config.py。
#
# ★ 这里原先有一份 40 行的内联 python, 与 share_server.py 的 build_lan_config()
#   重复, 而且已经漂移: 这边没剥 `profile`, 实际分发那边剥了。实测在真实客户端上
#   "预览版本 profile 出现 1 处 / 实际分发 0 处" —— 用户看到的不是别人拿到的。
#   现在两份实现收敛成一份, 谁都不会再单独漂。
#
# 输出契约 (保持不变): 配置内容 + **最后一行节点数**。
#   调用方一直用 `| tail -1` 取节点数、`head -60` 做预览, 形状不能改。
lan_gen_config() {
    local out="$1" lib="${CLI_ROOT}/src/share/lan_config.py"
    if [[ ! -f "$lib" ]]; then
        print_error "缺少 lan_config.py: $lib" >&2
        return 1
    fi
    if [[ "$out" == "/dev/stdout" ]]; then
        python3 "$lib" --root "$CLI_ROOT"
    else
        python3 "$lib" --root "$CLI_ROOT" --out "$out"
    fi
}

# 端口回避 —— 首选端口被占就自动找一个空闲的, 并把结果**记住**。
#
# 记住是必需的: 分发地址已经给了局域网里别的设备, 每次重启都换端口会让
# 那些设备全部失效。只在"上次的端口也用不了"时才重新挑。
lan_pick_port() {
    local f="$SUB_STATE_DIR/sub-port" old
    if [[ -f "$f" ]]; then
        old=$(cat "$f" 2>/dev/null)
        if [[ "$old" =~ ^[0-9]+$ ]] && ! m_port_listening "$old"; then
            LAN_SUB_PORT="$old"; return 0
        fi
    fi
    if ! m_port_listening "$LAN_SUB_PORT"; then
        [[ -f "$f" ]] || printf '%s' "$LAN_SUB_PORT" > "$f"
        return 0
    fi
    local i
    for ((i = LAN_SUB_PORT + 1; i <= LAN_SUB_PORT + 200; i++)); do
        if ! m_port_listening "$i"; then
            print_warn "端口 $LAN_SUB_PORT 已被占用, 端口回避 -> $i"
            LAN_SUB_PORT="$i"
            mkdir -p "$SUB_STATE_DIR"
            printf '%s' "$i" > "$f"
            return 0
        fi
    done
    print_error "端口区间内没有空闲端口"
    return 1
}

lan_sub_is_running() {
    lan_dispatch_init
    m_port_listening "$LAN_SUB_PORT"
}

lan_dispatch_start() {
    lan_dispatch_init
    lan_pick_port || return 1
    local tok; tok=$(lan_sub_token)
    local n
    n=$(lan_gen_config /dev/stdout 2>/dev/null | tail -1)
    if [[ -z "$n" || "$n" == "0" ]]; then
        print_error "当前没有节点, 分发出去也没用 —— 先添加节点"
        return 1
    fi
    # lan_server.py 全用环境变量传参, 没有 argparse —— 跟着它, 不另立一套。
    # 环境变量名保持与拆分前一致 (LAN_ROOT/LAN_TOKEN/LAN_TMP/SHARE_PORT),
    # 这样调用点只有可执行文件这一处变化。
    LAN_ROOT="$CLI_ROOT" LAN_TOKEN="$tok" LAN_TMP="$SUB_STATE_DIR/tmp" \
    SHARE_PORT="$LAN_SUB_PORT" \
        python3 "$CLI_ROOT/src/share/lan_server.py" >/dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$SUB_STATE_DIR/sub.pid"
    sleep 2
    if ! lan_sub_is_running; then
        print_error "分发服务起不来, 端口 $LAN_SUB_PORT 可能被占"
        return 1
    fi
    declare -F fw_open_port >/dev/null 2>&1 && fw_open_port "$LAN_SUB_PORT"
    print_ok "配置分发已启动 (PID $pid)"
    print_info "节点数: $n"
}

lan_dispatch_stop() {
    lan_dispatch_init
    [[ -f "$SUB_STATE_DIR/sub.pid" ]] && kill "$(cat "$SUB_STATE_DIR/sub.pid")" 2>/dev/null
    rm -f "$SUB_STATE_DIR/sub.pid"
    # 按登记表回收端口 —— fw_close_port 自带 sshd 保护
    declare -F fw_close_port >/dev/null 2>&1 && fw_close_port "$LAN_SUB_PORT" "配置分发"
    print_ok "配置分发已停止"
}

lan_dispatch_menu() {
    lan_dispatch_init
    local c ip url tok
    while true; do
        print_title "局域网配置分发"
        if lan_sub_is_running; then
            ip=$(lan_host_ip)
            tok=$(lan_sub_token)
            url="http://${ip}:${LAN_SUB_PORT}/sub/${tok}"
            ui_kv_ascii "状态" "${GREEN}运行中${RESET}"
            ui_kv_ascii "本机地址" "$ip"
            ui_kv_ascii "分发地址" "$url"
            ui_kv_ascii "节点数" "$(lan_gen_config /dev/stdout 2>/dev/null | tail -1)"
        else
            ui_kv_ascii "状态" "${YELLOW}未运行${RESET}"
            ui_kv_ascii "分发端口" "$LAN_SUB_PORT"
        fi
        echo >&2
        ui_menu 1 "启动分发服务"
        ui_menu 2 "停止分发服务"
        ui_menu 3 "复制分发地址"
        ui_menu 4 "查看将要分发的配置"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || return 0
        c=$(clean_input "$c")
        case "$c" in
            1) lan_dispatch_start ;;
            2) lan_sub_is_running && lan_dispatch_stop || print_info "本来就没运行" ;;
            3)
                lan_sub_is_running || { print_error "服务未运行, 没有地址可复制"; continue; }
                url="http://$(lan_host_ip):${LAN_SUB_PORT}/sub/$(lan_sub_token)"
                printf '%s' "$url"
                if command -v xclip >/dev/null 2>&1; then echo "$url" | xclip -selection clipboard && print_ok "已复制" >&2
                else print_ok "(无剪贴板工具, 请手动复制)" >&2; fi
                ;;
            4)
                echo >&2
                lan_gen_config /dev/stdout 2>/dev/null | head -60 | sed 's/^/    /' >&2
                ui_hint "分发前会剥掉 mixed-port / external-controller / secret 等本机专属段"
                ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}