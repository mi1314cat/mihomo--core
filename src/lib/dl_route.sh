#!/usr/bin/env bash
# =============================================================
# mihomo--core · 下载通道 (dl_route.sh)
#
# 需求来源: SB 客户端设置里有「下载通道 (拉订阅/内核/UI 走不走代理)」。
# 代理的。它有一个专门设置的地方, 我们这边有吗?"
#
# 为什么必须是一个**统一**的设置:
#   很多机器上「能连 GitHub」和「能拉订阅」根本不是同一条路。典型是国内机器
#   直连 GitHub 超时、必须走代理; 而订阅服务器往往就在国内, 走代理反而更慢
#   甚至被墙。所以三件事要能各自设置, 而不是一个开关管全部。
#
# ---------------------------------------------------------------
# 这个模块曾经是个**幽灵模块**:
#   * dl_curl 定义在, 全项目**零调用** —— 菜单让你设通道, 但没有任何东西读它;
#   * dl_route_set_* 三个函数**完全忽略传进来的 scope 参数**, 都写同一个文件,
#     于是"内核下载单独设置"会**覆盖全局**;
#   * dl_route_get 不接 scope, 分项值**根本读不回来**。
#
# 净效果比"没有这个功能"更糟: 用户设了、以为生效了, 其实没有。
# 现在由 tools/check_wiring.sh 机械保证 dl_curl 真的被调用。
# ---------------------------------------------------------------
#
# 通道取值:
#   direct  直连
#   local   走本机已配置的节点 (通过 mixed-port)
#   custom  手动填 socks5:// 或 http:// 代理地址
#   unset   跟随全局 (只有分项能用)
#
# 作用域: global / kernel / sub / ui
# =============================================================

DL_ROUTE_FILE=""      # 保存选择的文件, 由 dl_route_init 赋值

dl_route_init() {
    DL_ROUTE_FILE="${CLI_ROOT:-${SRV_ROOT:-/root/catmi/mihomo}}/.dl-route"
}

# ---------- 读写 ----------
#
# 文件格式是一行一个 `scope=mode`, 例如:
#     global=local
#     kernel=direct
#     sub=unset
#     ui=unset
#
# 用"每行带 key"而不是"一个文件一个值", 是因为分项设置必须能**并存** ——
# 这正是旧实现丢掉的东西。

# dl_route_get [scope] -> 该作用域**实际生效**的通道
# 不传 scope 时等同于 global (兼容旧调用点)。
dl_route_get() {
    local scope="${1:-global}"
    dl_route_init
    local v=""
    [[ -f "$DL_ROUTE_FILE" ]] && \
        v=$(sed -n "s/^${scope}=//p" "$DL_ROUTE_FILE" 2>/dev/null | tail -1)
    # 分项为 unset/空 -> 跟随 global
    if [[ "$scope" != "global" && ( -z "$v" || "$v" == "unset" ) ]]; then
        v=$(sed -n 's/^global=//p' "$DL_ROUTE_FILE" 2>/dev/null | tail -1)
    fi
    [[ -z "$v" || "$v" == "unset" ]] && v="direct"
    printf '%s\n' "$v"
}

# dl_route_get_raw [scope] -> 该作用域**存的原值** (可能是 unset), 给菜单显示用
dl_route_get_raw() {
    local scope="${1:-global}"
    dl_route_init
    local v=""
    [[ -f "$DL_ROUTE_FILE" ]] && \
        v=$(sed -n "s/^${scope}=//p" "$DL_ROUTE_FILE" 2>/dev/null | tail -1)
    printf '%s\n' "${v:-unset}"
}

# dl_route_set <scope> <mode>
dl_route_set() {
    local scope="${1:-global}" mode="${2:-direct}"
    dl_route_init
    mkdir -p "$(dirname "$DL_ROUTE_FILE")" 2>/dev/null
    local tmp; tmp=$(mktemp) || return 1
    # 保留其它作用域的行, 只替换本作用域 —— 旧实现是整体覆盖, 所以设一项会清掉别的
    if [[ -f "$DL_ROUTE_FILE" ]]; then
        grep -v "^${scope}=" "$DL_ROUTE_FILE" 2>/dev/null > "$tmp"
    fi
    printf '%s=%s\n' "$scope" "$mode" >> "$tmp"
    mv -f "$tmp" "$DL_ROUTE_FILE"
    chmod 600 "$DL_ROUTE_FILE" 2>/dev/null
}

# ---------- 通道 -> curl 参数 ----------

# 把通道翻译成 curl 可用的代理参数。
# $1 = 用途 (global/kernel/sub/ui)  $2 = mixed-port
# stdout: 可直接塞给 curl --proxy 的值 (空=直连)
dl_route_resolve() {
    local scope="${1:-global}" mixed="${2:-7890}"
    case "$(dl_route_get "$scope")" in
        direct) printf '' ;;
        local)
            # 走本机 mixed-port。用 127.0.0.1 而不是监听地址 —— 监听地址
            # 可能是 0.0.0.0, 那不是能连的地址。
            printf 'http://127.0.0.1:%s' "$mixed" ;;
        custom)
            dl_route_init
            cat "${DL_ROUTE_FILE}.custom" 2>/dev/null ;;
        *) printf '' ;;
    esac
}

# ---------- 统一的 curl 包装 ----------
#
# **所有**"从网上拉东西"的地方都该走这里, 而不是各自裸调 curl。
# 这是本模块存在的全部意义: 一个设置, 处处生效。
#
# $1=URL  $2=输出文件 (或 "-" 表示 stdout)  $3=用途
dl_curl() {
    local url="$1" out="$2" scope="${3:-global}"
    local mixed; mixed=$(dl_mixed_port)
    local px; px=$(dl_route_resolve "$scope" "$mixed")

    local -a args=(-fsSL --max-time "${DL_TIMEOUT:-60}")
    [[ -n "$px" ]] && args+=(--proxy "$px")

    local i rc=1
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

# 带 HTTP 状态码的版本 —— 订阅拉取要靠状态码区分 404/410/503 (一次性链接
# 用尽 vs 服务端故障), 不能只靠 curl 的退出码。
# $1=URL $2=输出文件 $3=用途 ; stdout = HTTP 状态码
dl_curl_code() {
    local url="$1" out="$2" scope="${3:-global}"
    local mixed; mixed=$(dl_mixed_port)
    local px; px=$(dl_route_resolve "$scope" "$mixed")
    local -a args=(-sSL --max-time "${DL_TIMEOUT:-60}" -o "$out" -w '%{http_code}')
    [[ -n "$px" ]] && args+=(--proxy "$px")
    curl "${args[@]}" "$url" 2>/dev/null
}

# 本机 mixed-port。
#
# settings.env 在**根目录**, 不是 conf/ 下 —— 早先写成 conf/settings.env,
# 于是永远读不到, 一路退回 7890, 而实际是安装时协商出来的另一个端口:
# "走本机节点"会指向一个没人在听的端口, 而且看不出问题。
# 读不到时以 config.yaml 为准 —— 那才是内核真正在用的端口。
dl_mixed_port() {
    local root="${CLI_ROOT:-}" v=""
    local s="$root/settings.env"
    if [[ -r "$s" ]]; then
        v=$(sed -n 's/^PORT_MIXED=["]*\([0-9]\+\)["]*$/\1/p' "$s" 2>/dev/null | head -1)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }

    local c="$root/conf/config.yaml"
    if [[ -r "$c" ]]; then
        v=$(sed -n 's/^mixed-port:[[:space:]]*\([0-9]\+\)$/\1/p' "$c" 2>/dev/null | head -1)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }
    printf '7890'
}

# ---------- 界面 ----------

_dl_mode_label() {
    case "$1" in
        direct) printf '直连' ;;
        local)  printf '走本机节点 (mixed-port)' ;;
        custom) printf '自定义代理' ;;
        unset)  printf '跟随全局' ;;
        *)      printf '%s' "$1" ;;
    esac
}

dl_route_page() {
    print_title "下载通道"
    local g; g=$(dl_route_get global)
    ui_kv_ascii "全局" "$(_dl_mode_label "$g")"
    echo >&2
    local sc label raw eff
    for sc in kernel sub ui; do
        case "$sc" in
            kernel) label="内核下载" ;;
            sub)    label="订阅拉取" ;;
            ui)     label="UI 下载"  ;;
        esac
        raw=$(dl_route_get_raw "$sc"); eff=$(dl_route_get "$sc")
        if [[ "$raw" == "unset" ]]; then
            ui_kv_ascii "$label" "跟随全局 ($(_dl_mode_label "$eff"))"
        else
            ui_kv_ascii "$label" "$(_dl_mode_label "$eff")"
        fi
    done
    echo >&2
    ui_kv_ascii "本机 mixed" "$(dl_mixed_port)"
    echo >&2
    case "$g" in
        direct) ui_hint "全局直连 —— 国内机器连 GitHub 会超时" ;;
        local)  ui_hint "全局走本机 mixed-port 指定的节点" ;;
        custom) ui_hint "全局走自定义代理: $(cat "${DL_ROUTE_FILE}.custom" 2>/dev/null)" ;;
    esac
    echo >&2
    ui_hint "订阅服务器常在国内 —— 直连往往比走代理更快"
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
                local scope="global" what="全局"
                [[ "$c" == 2 ]] && { scope="kernel"; what="内核下载"; }
                [[ "$c" == 3 ]] && { scope="sub";    what="订阅拉取"; }
                [[ "$c" == 4 ]] && { scope="ui";     what="UI 下载";  }
                echo >&2; ui_title "$what 的通道"
                ui_kv_ascii "当前" "$(_dl_mode_label "$(dl_route_get "$scope")")"
                echo >&2
                ui_menu 1 "直连"
                ui_menu 2 "走本机节点 (mixed-port)"
                ui_menu 3 "自定义代理"
                # global 自己不能"跟随全局", 否则就是循环
                [[ "$scope" != "global" ]] && ui_menu 4 "跟随全局"
                echo >&2
                printf "  ${CYAN}请选择${RESET}: " >&2
                local k; read -r k; k=$(clean_input "$k")
                case "$k" in
                    1) dl_route_set "$scope" direct; print_ok "$what -> 直连" ;;
                    2) dl_route_set "$scope" local;  print_ok "$what -> 走本机节点" ;;
                    3) dl_route_set "$scope" custom; print_ok "$what -> 自定义代理" ;;
                    4) if [[ "$scope" != "global" ]]; then
                           dl_route_set "$scope" unset; print_ok "$what -> 跟随全局"
                       else
                           ui_invalid "$k"
                       fi ;;
                    *) ui_invalid "$k" ;;
                esac
                ;;
            5)
                printf "  ${CYAN}代理地址${RESET} (socks5://host:port 或 http://host:port): " >&2
                local u; read -r u; u=$(clean_input "$u")
                if [[ "$u" =~ ^(socks5h?|https?)://[^[:space:]]+ ]]; then
                    printf '%s\n' "$u" > "${DL_ROUTE_FILE}.custom"
                    chmod 600 "${DL_ROUTE_FILE}.custom" 2>/dev/null
                    print_ok "自定义代理已保存: $u"
                else
                    print_error "格式不对 (示例 socks5://127.0.0.1:1080)"
                fi
                ;;
            6)
                echo >&2
                local sc px code tgt
                tgt="https://api.github.com/repos/MetaCubeX/mihomo"
                for sc in global kernel sub ui; do
                    px=$(dl_route_resolve "$sc" "$(dl_mixed_port)")
                    code=$(curl -fsSL --max-time 20 ${px:+--proxy "$px"} \
                           -o /dev/null -w '%{http_code}' "$tgt" 2>/dev/null)
                    if [[ "$code" == "200" ]]; then
                        print_ok   "$sc: 可达 (HTTP $code)${px:+ via $px}"
                    elif [[ -z "$code" ]]; then
                        print_error "$sc: 连不上${px:+ via $px}"
                    else
                        print_warn "$sc: HTTP $code${px:+ via $px}"
                    fi
                done
                ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}
