#!/usr/bin/env bash
# =============================================================
# mihomo--core · 端口占用检测 (portcheck.sh)
#
# 端口冲突这件事的表现极具误导性: 面板显示"运行中", 节点配好了, 分享也发出
# 去了, 但客户端就是连不上 —— 因为 mihomo 根本没监听那个端口, 或者监听了
# 却被**别的程序**占着, 进程一起来就退出。
#
# 踩过的坑: 全新安装默认 mixed-port 7890, 而这台机器上
# 另一个项目的 mihomo 正占着 7890/9090。新客户端静默启动失败, 面板却显示
# "运行中"。用户看到的是"装好了但用不了"的死局。
#
# 安装时已由 m_resolve_ports 自动避让。但那是**一次性**的: 用户事后手动改
# 端口、改了别的程序占位、或者换机器部署, 都会再次撞上。所以这里把它提到
# 台面上做成一个能随时看的页面。
#
# 对齐 SB 的 port_check_menu。
# =============================================================

# 端口被谁占了。ss 的进程列是**进程名** (users:(("nginx",pid=...))),
# 不是可执行文件全路径 —— 拿配置里的路径去 grep 永远匹配不上。
port_holder() {
    local p="$1" nm
    nm=$( { ss -tlnp 2>/dev/null; ss -ulnp 2>/dev/null; } \
          | grep -E "[:.]${p}[[:space:]]" \
          | grep -oE '\("[^"]+"' | head -1 | tr -d '("' )
    printf '%s\n' "${nm:-未知}"
}

# 端口状态: 空闲 / 已被本服务占用 / 被其它程序占用
port_state_mark() {
    local p="$1" mine="$2" h
    [[ -z "$p" ]] && { printf '%s\n' "未设置"; return; }
    h=$(port_holder "$p")
    [[ "$h" == "无" || -z "$h" || "$h" == "未知" ]] && { printf '%s\n' "空闲"; return; }
    if [[ -n "$mine" && "$h" == "$mine" ]]; then
        printf '\033[32m本服务\033[0m'
    else
        printf '\033[31m%s\033[0m' "$h"
    fi
}

# 建议换到哪个端口。
#
# 这里不直接调 m_free_port —— 那在 env.sh 里, 而客户端不加载 env.sh。
# 依赖一个用不上的函数会让"建议"永远显示 ? (踩过)。自己实现一份。
port_suggest() {
    local want="$1" i p
    [[ -z "$want" ]] && { printf '%s' "?"; return; }
    if ! port_in_use "$want"; then printf '%s' "$want"; return; fi
    for (( i = 1; i <= 200; i++ )); do
        p=$(( want + i ))
        (( p <= 65535 )) || break
        port_in_use "$p" || { printf '%s' "$p"; return; }
    done
    printf '%s' "?"
}

# 端口是否已被占用 (TCP 或 UDP 都要看 —— QUIC 节点只占 UDP)
port_in_use() { m_port_listening "$1"; }

# 简短说明: 端口是不是本服务自己在用
port_desc() {
    local p="$1"
    [[ -z "$p" ]] && { printf '\n'; return; }
    if [[ -n "${CLI_SERVICE:-}" ]] && systemctl is-active --quiet "$CLI_SERVICE" 2>/dev/null; then
        printf '\033[2m(服务在跑)\033[0m\n'
    else
        printf '\033[2m(服务未运行, 状态仅供参考)\033[0m\n'
    fi
}

port_check_show() {
    local svc_bin="$1"
    ui_title "端口占用检测"
    printf "    %-12s %s\n" "端口" "状态" >&2
    ui_kv_ascii "HTTP/SOCKS" "$PORT_MIXED   $(port_state_mark "$PORT_MIXED" "$svc_bin")   $(port_desc "$PORT_MIXED")"
    ui_kv_ascii "控制面板"    "$PORT_CTRL   $(port_state_mark "$PORT_CTRL" "$svc_bin")   $(port_desc "$PORT_CTRL")"
    echo >&2

    # 两个端口撞在一起是最典型的翻车方式: 面板看起来正常, 但 Clash API
    # 根本没起来, 于是 Web UI 一直连不上。
    if [[ "$PORT_MIXED" == "$PORT_CTRL" ]]; then
        print_error "两个端口相同! 面板会起不来, 请到「客户端设置」改掉一个"
    fi

    # 被别的程序占了却不自知 —— 这是最难查的一种, 因为面板照样显示"运行中"
    local h
    for h in "$PORT_MIXED" "$PORT_CTRL"; do
        local who; who=$(port_holder "$h")
        if [[ -n "$who" && "$who" != "未知" && "$who" != "$svc_bin" && -n "$svc_bin" ]]; then
            print_warn "端口 $h 被 [$who] 占用, 不是本服务"
            print_warn "  本服务实际连不上。到「客户端设置」改成 $h→$(port_suggest "$h")"
        fi
    done

    ui_hint "端口冲突不会在配置校验时暴露, 只会在启动失败时显现 —— 所以这一页要随手看一眼"
    echo >&2
    printf "  ${CYAN}本机监听端口${RESET}: " >&2
    ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ' >&2
    echo >&2; echo >&2
}
