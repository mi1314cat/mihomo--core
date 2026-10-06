#!/usr/bin/env bash
# =============================================================
# mihomo--core · 下载通道 (dl_route.sh)
#
# 需求来源: SB 客户端设置里有「下载通道 (拉订阅/内核/UI 走不走代理)」。
#
# 现在这三件事各自为政:
#   内核下载  core_install.sh 的 pick_proxy —— 每次现场探测本机代理并询问,
#             答完就丢, 下次还问;
#   订阅拉取  没有通道概念, 直连;
#   UI 下载   webui.sh 里三个镜像源顺序试, 全直连。
#
# 问题在于: 很多机器上「能连 GitHub」和「能拉订阅」根本不是同一条路。
# 典型是国内机器直连 GitHub 超时, 必须走代理; 而订阅服务器往往就在国内,
# 走代理反而更慢甚至被墙。SB 把这个做成一个统一的、可持久保存的设置,
# 这里照搬。
#
# 通道取值:
#   direct  直连
#   proxy   走本机已配置的节点 (通过 mixed-port)
#   自定义  手动填 socks5:// 或 http:// 代理地址
# =============================================================

DL_ROUTE_FILE=""      # 保存选择的文件, 由 dl_route_init 赋值

dl_route_init() {
    DL_ROUTE_FILE="${CLI_ROOT:-${SRV_ROOT:-/root/catmi/mihomo}}/.dl-route"
}

dl_route_get() {      # 输出 global / kernel / sub / ui
    dl_route_init
    [[ -f "$DL_ROUTE_FILE" ]] && cat "$DL_ROUTE_FILE" 2>/dev/null || printf 'direct\n'
}

dl_route_set() {
    local v="$1"
    dl_route_init
    mkdir -p "$(dirname "$DL_ROUTE_FILE")" 2>/dev/null
    printf '%s\n' "$v" > "$DL_ROUTE_FILE"
}

# 把通道翻译成 curl 可用的代理参数。
# $1 = 用途 (global/kernel/sub/ui)  $2 = 当前通道  $3 = mixed-port
# stdout: 可直接塞给 curl --proxy 的值 (空=直连)
dl_route_resolve() {
    local scope="$1" mode="$2" mixed="${3:-7890}"
    # global 覆盖所有; 其余各自独立, 未设则跟随 global
    local m="$mode"
    [[ "$m" == "unset" || -z "$m" ]] && m="$(dl_route_get)"
    [[ "$m" == "global" ]] && m="$(dl_route_get)"

    case "$m" in
        direct)
            printf ''
            ;;
        local)
            # 走本机 mixed-port。用 127.0.0.1 而不是监听地址 —— 监听地址
            # 可能是 0.0.0.0, 那不是能连的地址。
            printf 'http://127.0.0.1:%s' "$mixed"
            ;;
        custom)
            dl_route_init
            local u; u=$(cat "${DL_ROUTE_FILE}.custom" 2>/dev/null)
            printf '%s' "$u"
            ;;
        *)
            printf ''
            ;;
    esac
}

# 统一的 curl 包装: 带超时与失败重试, 通道由通道设置决定。
# $1=URL $2=输出文件 $3=用途
dl_curl() {
    local url="$1" out="$2" scope="${3:-global}"
    local mixed; mixed=$(dl_mixed_port)
    local px; px=$(dl_route_resolve "$scope" unset "$mixed")

    local -a args=(-fsSL --max-time "${DL_TIMEOUT:-60}")
    [[ -n "$px" ]] && args+=(--proxy "$px")

    local i rc
    for (( i = 1; i <= 3; i++ )); do
        if [[ "$out" == "-" ]]; then
            curl "${args[@]}" "$url" && return 0
        else
            curl "${args[@]}" "$url" -o "$out" && return 0
        fi
        rc=$?
        [[ $i -lt 3 ]] && sleep $(( i * 2 ))
    done
    return $rc
}

# 本机 mixed-port。
#
# settings.env 在**根目录**, 不是 conf/ 下 —— 早先写成 conf/settings.env,
# 于是永远读不到, 一路退回 7890, 而实际端口是 17890:
# "走本机节点"会指向一个没人在听的端口, 而且看不出问题。
# 读不到时以 config.yaml 为准 —— 那才是内核真正在用的端口。
dl_mixed_port() {
    local root="${CLI_ROOT:-}" v=""
    local s="$root/settings.env"
    if [[ -r "$s" ]]; then
        v=$(grep -E '^PORT_MIXED=' "$s" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"\047 ')
    fi
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }

    local c="$root/conf/config.yaml"
    if [[ -r "$c" ]]; then
        v=$(grep -E '^mixed-port:' "$c" 2>/dev/null | head -1 | sed 's/[^0-9]//g')
    fi
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }
    printf '7890'
}

dl_route_page() {
    local cur
    print_title "下载通道"
    cur=$(dl_route_get)
    ui_kv_ascii "当前通道" "$cur"
    ui_kv_ascii "本机 mixed" "$(dl_mixed_port)"
    echo >&2
    case "$cur" in
        direct) ui_hint "全部直连 —— 国内机器连 GitHub 会超时" ;;
        local)  ui_hint "走本机 mixed-port 指定的节点" ;;
        custom) ui_hint "走自定义代理: $(cat "${DL_ROUTE_FILE}.custom" 2>/dev/null)" ;;
    esac
}

dl_route_menu() {
    local c
    dl_route_init
    while true; do
        dl_route_page
        echo >&2
        ui_menu 1 "全局通道 (三项统一)"
        ui_menu 2 "内核下载单独设置"
        ui_menu 3 "订阅拉取单独设置"
        ui_menu 4 "UI 下载单独设置"
        ui_menu 5 "自定义代理地址"
        ui_menu 6 "测试当前通道"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || return 0
        c=$(clean_input "$c")
        case "$c" in
            1|2|3|4)
                local what="全局"
                [[ "$c" == 2 ]] && what="内核下载"
                [[ "$c" == 3 ]] && what="订阅拉取"
                [[ "$c" == 4 ]] && what="UI 下载"
                echo >&2; ui_title "$what 的通道"
                ui_menu 1 "直连"
                ui_menu 2 "走本机节点 (mixed-port)"
                ui_menu 3 "自定义代理"
                ui_menu 4 "跟随全局"
                echo >&2
                printf "  ${CYAN}请选择${RESET}: " >&2
                local k; read -r k; k=$(clean_input "$k")
                case "$k" in
                    1) dl_route_set_direct "$what"; print_ok "$what -> 直连" ;;
                    2) dl_route_set_local  "$what"; print_ok "$what -> 走本机节点" ;;
                    3) dl_route_set_custom "$what"; print_ok "$what -> 自定义代理" ;;
                    4) print_info "$what -> 跟随全局" ;;
                    *) ui_invalid "$k" ;;
                esac
                ;;
            5)
                printf "  ${CYAN}代理地址${RESET} (socks5://host:port 或 http://host:port): " >&2
                local u; read -r u; u=$(clean_input "$u")
                if [[ "$u" =~ ^(socks5h?|https?)://[^[:space:]]+ ]]; then
                    printf '%s\n' "$u" > "${DL_ROUTE_FILE}.custom"
                    dl_route_set custom
                    print_ok "自定义代理已保存"
                else
                    print_error "格式不对 (示例 socks5://127.0.0.1:1080)"
                fi
                ;;
            6)
                local px; px=$(dl_route_resolve global unset "$(dl_mixed_port)")
                echo >&2
                if [[ -z "$px" ]]; then print_info "当前通道: 直连"; fi
                if [[ -n "$px" ]]; then print_info "当前通道: $px"; fi
                printf "  ${CYAN}测试 GitHub 连通性${RESET} ... " >&2
                local code
                code=$(curl -fsSL --max-time 20 ${px:+--proxy "$px"} \
                       -o /dev/null -w '%{http_code}' \
                       https://api.github.com/repos/MetaCubeX/mihomo 2>/dev/null)
                if [[ "$code" == "200" ]]; then
                    print_ok "GitHub 可达 (HTTP $code)"
                elif [[ -z "$code" ]]; then
                    print_error "连不上 —— 换个通道试试"
                else
                    print_warn "GitHub 返回 HTTP $code (被限流或需要代理)"
                fi
                ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}

dl_route_set_direct() { printf 'direct\n'  > "$DL_ROUTE_FILE"; }
dl_route_set_local()  { printf 'local\n'   > "$DL_ROUTE_FILE"; }
dl_route_set_custom() { printf 'custom\n'  > "$DL_ROUTE_FILE"; }