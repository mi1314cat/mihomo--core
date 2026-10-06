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

# 生成可分发的配置: 实时合并 conf/ 下所有片段, 剥掉本机专属段。
lan_gen_config() {
    local out="$1"
    python3 - "$CLI_ROOT" "$out" <<'PY'
import sys, os, glob, re
root, out = sys.argv[1], sys.argv[2]
confdir = os.path.join(root, "conf")

# 合并 config.d/*.yaml 与节点片段。Mihomo 的 -d 目录语义就是合并所有 yaml,
# 这里只把"片段文件"读进来, 主配置 config.yaml 原样保留。
merged = ""
for f in sorted(glob.glob(os.path.join(confdir, "config.d", "*.yaml"))) + \
         sorted(glob.glob(os.path.join(confdir, "providers", "*.yaml"))):
    try:
        merged += open(f, encoding="utf-8").read() + "\n"
    except Exception as e:
        sys.stderr.write(f"跳过 {f}: {e}\n")

main = os.path.join(confdir, "config.yaml")
txt = open(main, encoding="utf-8").read() if os.path.exists(main) else ""

# 剥掉本机专属段 —— 这些换台设备全都对不上
# 不带尾部冒号: 比较的是 line.split(":", 1)[0] (见上一行), 带了永远匹配不上。
DROP_PREFIX = ("mixed-port", "port", "socks-port", "redir-port", "tproxy-port",
               "allow-lan", "bind-address", "external-controller", "external-ui",
               "secret", "log-level", "mode")
kept, skip = [], False
for line in txt.splitlines():
    if line and not line[0].isspace() and ":" in line:
        skip = line.split(":", 1)[0].strip() in DROP_PREFIX
    if not skip:
        kept.append(line)

# 把节点片段拼在主配置之后 (规则仍以主配置的为准)
result = "\n".join(kept).rstrip() + "\n" + merged
open(out, "w", encoding="utf-8").write(result)

# 统计一下有没有节点 —— 没有节点的分发是没意义的
n = len(re.findall(r'^\s*-\s*name:', merged, re.M))
print(n)
PY
}

lan_sub_is_running() {
    lan_dispatch_init
    m_port_listening "$LAN_SUB_PORT"
}

lan_dispatch_start() {
    lan_dispatch_init
    local tok; tok=$(lan_sub_token)
    local n
    n=$(lan_gen_config /dev/stdout 2>/dev/null | tail -1)
    if [[ -z "$n" || "$n" == "0" ]]; then
        print_error "当前没有节点, 分发出去也没用 —— 先添加节点"
        return 1
    fi
    # share_server.py 全用环境变量传参, 没有 argparse —— 跟着它, 不另立一套
    MODE=lan LAN_ROOT="$CLI_ROOT" LAN_TOKEN="$tok" LAN_TMP="$SUB_STATE_DIR/tmp" \
    SHARE_PORT="$LAN_SUB_PORT" SHARE_DIR="$SUB_STATE_DIR" OUT_DIR="$SUB_STATE_DIR/out" \
        python3 "$CLI_ROOT/src/share/share_server.py" >/dev/null 2>&1 &
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