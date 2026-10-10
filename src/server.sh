#!/usr/bin/env bash
# =============================================================
# mihomo--core 服务端面板
#
#   添加节点 → 合并校验 → 热重载 → 生成分享 → 客户端拉取
#
# 与旧版 ts.sh 的差别:
#   * 每次改动都走 merge.py → validate.py → mihomo -t 三道关,
#     任一不过就整体回滚, 不再出现"配置写坏了照样重启"。
#   * 分享链接带 token / 有效期 / 次数限制, 且支持一键禁用。
#   * 所有外部脚本依赖已本地化, 只剩证书签发仍走 acme.sh。
# =============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M_LIB="$HERE/lib"
SRV_ROOT="${SRV_ROOT:-/root/catmi/mihomo}"
SRV_CONF="$SRV_ROOT/conf"
SRV_CONFIGD="$SRV_CONF/config.d"
SRV_CERTS="$SRV_CONF/certs"
SRV_OUT="$SRV_ROOT/out"
SRV_ENV="$SRV_ROOT/install_info.env"
SRV_BIN="$SRV_ROOT/mihomo"
SRV_SERVICE="mihomo"
MIHOMO_BIN="$SRV_BIN"
BASE_DIR="$SRV_ROOT"

# shellcheck source=/dev/null
source "$M_LIB/env.sh"

# 证书体系 (扫描/识别/生成/钉扎/回收) —— 唯一真源, 协议脚本不再各写一份。
# 必须在 env.sh 之后 (依赖 ui.sh 的 print_*/safe_read)。
# shellcheck source=/dev/null
source "$M_LIB/cert.sh"

# CDN 回源编排 (渲染 location / 安全写入 Nginx / 删节点时回删)
# shellcheck source=/dev/null
source "$M_LIB/cdn.sh"

# 推荐配置预置 (每协议多套方案; all.sh 批量时按预置生成)
# shellcheck source=/dev/null
source "$M_LIB/preset.sh"

# UI 原语 (颜色/消息分级/标题/菜单) 统一来自 src/lib/ui.sh, 由上面的 env.sh 带入。

# 本地覆盖 pause(): ui.sh 那版遇到 EOF 直接 exit, 这里要 return 1 把控制权交回
# 调用方 —— 主菜单靠它退出循环, 而不是连整个脚本一起带走。
pause() { printf "\n${CYAN}按回车继续...${RESET}"; read -r || return 1; }

ensure_dirs() { mkdir -p "$SRV_CONF" "$SRV_CONFIGD" "$SRV_CERTS" "$SRV_OUT"; }

# =============================================================
# 状态
# =============================================================
status_block() {
    # 输出统一走 stderr: UI 文本混进 stdout 会污染 $(...) 捕获的数据, 而且
# 两个流缓冲策略不同, 与 print_title(stderr) 混排时顺序会颠倒 ——
# 实测出现过"状态先于标题出现"。
    local svc ver pid frag
    pid=$(systemctl show -p MainPID --value "$SRV_SERVICE" 2>/dev/null) || pid=""
    [[ "$pid" == "0" ]] && pid=""
    if systemctl is-active --quiet "$SRV_SERVICE"; then
        svc="${GREEN}● 运行中${RESET}${pid:+ (PID $pid)}"
    else
        svc="${YELLOW}○ 未运行${RESET}"
    fi
    ver="未安装"
    [[ -x "$SRV_BIN" ]] && ver=$("$SRV_BIN" -v 2>/dev/null | awk 'NR==1' | awk '{print $3}')
    [[ -n "$ver" ]] || ver="未知"
    frag=$(ls "$SRV_CONFIGD"/*.yaml 2>/dev/null | wc -l | tr -d ' ')

    ui_kv "服务状态" "$svc"
    # ★ 数的是**实际配置了**的节点, 不是 out/ 里的客户端产物。
    #   原来调 node_count() 去数 out/*_client-*.yaml 里的 proxies —— 而清空
    #   节点时产物是**故意保留**的 (菜单里明写"保留 out/ 客户端产物")。
    #   结果用户清空了全部节点, 面板还显示"节点数量 61": 那 61 个节点早就
    #   不在配置里了, 只是产物文件还在, 数出来的数字与实际状态相反,
    #   比不显示更糟 —— 用户会以为删除没生效。
    #   产物数量另起一行标成"历史产物", 不与在用节点混在一起。
    ui_kv "节点数量" "${frag:-0}"
    local _art; _art=$(node_count)
    [[ "${_art:-0}" != "0" ]] && ui_kv "历史产物" "$_art ${DIM}(out/ 里的客户端配置, 清空节点时会保留)${RESET}"
    ui_kv "内核版本" "$ver"

    # ---------- 对外地址 ----------
    # 显示面板选定的那个地址族, 以及本机真实持有哪些地址。
    # 套了 WARP 时外部探测会拿到 WARP 出口, 隧道接口上的地址也不可对外 ——
    # 所以只认网卡上真实存在、且排除隧道接口的那些。
    echo >&2
    printf "  ${CYAN}对外地址${RESET}  ${DIM}产物将使用 ${RESET}${RESET}$(m_addr_family_label)\n" >&2
    ui_kv_i "IPv4" "$(m_addr4_real 2>/dev/null || echo "${DIM}(无)${RESET}")"
    ui_kv_i "IPv6" "$(m_addr6_real  2>/dev/null || echo "${DIM}(无)${RESET}")"
    m_warp_active && ui_kv_i "隧道" "${YELLOW}WARP 在跑, 其地址已排除${RESET}"
    ui_kv_i "分享端口" "${SHARE_PORT:-9443}"
    ui_kv_i "客户端指纹" "$(m_fp_get)"
    # 注意: ss -tlnp 的进程列是**进程名**(users:(("mihomo",pid=...))),
    # 不是可执行文件全路径。拿 $SRV_BIN (/root/catmi/mihomo/mihomo) 去 grep
    # 永远匹配不上 —— 面板于是永远显示 0, 哪怕十几个端口都在监听。
    #
    # 还要 TCP+UDP 都数: hysteria2 和 tuic 是 QUIC 协议, **只监听 UDP**,
    # 只数 TCP 会永远少 2 个, 让人以为有节点没起来 (实测 13 个节点显示 12)。
    #
    # 只统计协议端口区间, 不统计 9090 之类的管理口, 也不统计 mihomo 内部的
    # QUIC 辅助 socket —— 否则数字会比节点数还大, 同样让人困惑。
    local nm p
    nm=$(basename "$SRV_BIN")
    p=$( { ss -tlnp 2>/dev/null; ss -ulnp 2>/dev/null; } \
        | grep "(\"$nm\"," \
        | awk '{print $4}' | sed -n 's/.*:\([0-9]\{1,5\}\)$/\1/p' \
        | awk -v lo=$PROTO_PORT_LO -v hi=$PROTO_PORT_HI '$1 >= lo && $1 <= hi' | sort -un | wc -l | tr -d ' ' )
    ui_kv "协议端口" "${p:-0} ${DIM}个在监听 (TCP+UDP, ${PROTO_PORT_LO}-${PROTO_PORT_HI})${RESET}"
}

node_count() {
    local n=0 f
    for f in "$SRV_OUT"/*_client-*.yaml; do
        [[ -f "$f" ]] || continue
        n=$((n + $(python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
if not isinstance(d, dict): d = {}
print(len(d.get('proxies') or []))" "$f" 2>/dev/null || echo 0)))
    done
    printf '%s' "$n"
}

list_nodes() {
    print_title "当前节点"
    local f found=0
    for f in $(ls "$SRV_CONFIGD"/*.yaml 2>/dev/null | sort); do
        local base; base=$(basename "$f" .yaml)
        local proto="${base%-*}" num="${base##*-}"
        printf '  \033[1m%-24s\033[0m %-8s %s\n' "$base" "$proto" \
            "$(python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
if not isinstance(d, dict): d = {}
l=d.get('listeners') or [d]
for x in l:
    if isinstance(x,dict): print(x.get('name','?'), x.get('listen',''), x.get('port',''), sep='/')
" "$f" 2>/dev/null)"
        found=1
    done
    [[ $found -eq 0 ]] && print_info "还没有任何节点"
    return 0
}

# =============================================================
# 添加 / 管理节点 —— 委托给各协议脚本
# =============================================================
# 协议节点端口区间。三处口径必须一致: 各协议脚本的 random_port、
# all.sh 的 PORT_CURSOR 起点、状态栏的统计过滤。任何一个单独改都会
# 让「运行中的协议端口」少报。
PROTO_PORT_LO=20000
PROTO_PORT_HI=29999
PROTO_SCRIPTS=(Reality.sh VLESS.sh Trojan.sh hysteria2.sh TUIC.sh AnyTLS.sh)
PROTO_LABELS=("Reality (VLESS+Reality)" "VLESS" "Trojan" "Hysteria2" "TUIC v5" "AnyTLS")
# 每项的**变体与限制**, 内联在菜单里。
#
# 节点菜单的说明写法:
#     7. 添加 VMess 节点 (ws/grpc/h2/tcp + TLS/Reality)
#     6. 添加 TUIC 节点 (v5 · 仅 TLS, 不支持 Reality)
#     3. 添加 AnyTLS 节点 (可选 REALITY · 非 Reality 形态 mihomo 也能用)
# 进菜单前就知道有哪些传输、有什么限制, 不用进去试错才知道。
# 第 6 项那种"主动说明限制"尤其重要 —— 它省掉的是一次白跑。
#
# 内容来自各脚本的实际分支, 不是猜的:
#   Reality.sh:  tcp/grpc/xhttp  + reality
#   VLESS.sh:    ws/xhttp/grpc/h2/tcp + 仅 tls (无 reality 分支); 另有 cdn/nginx 接入方式
#   Trojan.sh:   tcp/ws/grpc + tls 或 reality
#   hysteria2.sh / TUIC.sh: QUIC(UDP), 仅 tls
#   AnyTLS.sh:   TCP, 仅 tls
PROTO_HINTS=(
    "TCP / gRPC / xHTTP + Reality"
    "WS / xHTTP / gRPC / H2 / TCP · 仅 TLS"
    "TCP / WS / gRPC · TLS 或 Reality"
    "QUIC (UDP) · 仅 TLS"
    "QUIC (UDP) · 仅 TLS, 不支持 Reality"
    "TCP · 仅 TLS"
)

# 内核支持、all.sh 也早就能生成, 但**没有独立协议脚本**的协议。
#
# 核实:
#   * all.sh 的 ALL_GEN_IDS 有 21 种组合, 其中包含 vmess / ss / snell;
#   * 但 add_node 的菜单只挂了 6 个脚本, 这三种**没有任何入口** ——
#     能批量生成, 却不能单独添加一个。
#   * 实测 mihomo 入站支持: vmess ✅ ss ✅ snell ✅
#                        shadowtls ❌ naive ❌ (内核只能做出站, 做不了服务端)
#     —— 后两个是**内核限制**, 不是漏搬, 所以不在这里列。
#
# 做法: 直接复用 `all.sh --only <ids>`, **不新写协议脚本**。
# 与 SB 的 batch.sh 一致 —— 编排层不重实现协议。
BATCH_PROTO_LABELS=("VMess" "Shadowsocks" "Snell")
BATCH_PROTO_HINT=(
    "TCP+Reality / gRPC+Reality 两种一起生成 (WS 档走 CDN, 见全协议一键)"
    "无需证书, 兼容性最好"
    "无需证书, 轻量"
)
# ⚠ 这里的 id 必须与 all.sh 的 ALL_GEN_IDS 对得上 —— id 不存在时
#   check_only_tokens 整批中止, 表现为该协议一个节点都建不出来。
# tools/check_all.sh 有关卡盯着这份列表。
BATCH_PROTO_ONLY=("vmess-reality,vmess-grpc" "ss" "snell")

# 协议脚本跑完后的收口: 为本次新增的节点文件放行防火墙端口。
#
# 只碰**未登记**的端口 —— 已有的节点反复放行没意义, 而全目录无条件扫描会
# 把别的协议的端口也过一遍, 出问题时分不清是哪一步动的。
fw_after_node_change() {
    declare -F fw_open_node_file >/dev/null 2>&1 || return 0
    local nf first
    for nf in "$SRV_CONFIGD"/*.yaml; do
        [[ -f "$nf" ]] || continue
        first=$(fw_ports_in_file "$nf" | awk 'NR==1')
        fw_is_registered "$first" && continue
        fw_open_node_file "$nf"
    done
}


# 节点变更后刷新已有分享链接的内容。
#
# 幂等且**安静**: 没有分享、或公共服务不在、或内容没变, 都一声不吭。
# share.sh 未必已加载 (用户可能直接删/加节点而没进过分享菜单), 所以这里
# 按需 source 一次 —— 与 all.sh 的做法一致。
_share_refresh_after_change() {
    if ! declare -F share_refresh_all >/dev/null 2>&1; then
        # shellcheck disable=SC1090
        source "$HERE/share/share.sh" 2>/dev/null || return 0
    fi
    declare -F share_refresh_all >/dev/null 2>&1 && share_refresh_all >/dev/null 2>&1
    return 0
}

add_node() {
    print_title "添加节点"
    local i
    local n_single=${#PROTO_SCRIPTS[@]}
    local n_batch=${#BATCH_PROTO_LABELS[@]}

    # 分两段列 —— 单协议 / 批量。SB 的菜单也是这样分组的, 用户一眼能看出
    # "哪个是加一个节点, 哪个是一次生成一批"。
    for i in "${!PROTO_SCRIPTS[@]}"; do
        printf "  ${CYAN}%2d${RESET}) %-24s ${DIM}(%s)${RESET}\n" \
            "$((i+1))" "${PROTO_LABELS[$i]}" "${PROTO_HINTS[$i]}"
    done
    for i in "${!BATCH_PROTO_LABELS[@]}"; do
        printf "  ${CYAN}%2d${RESET}) %s ${DIM}(%s)${RESET}\n" \
            "$((n_single+i+1))" "${BATCH_PROTO_LABELS[$i]}" "${BATCH_PROTO_HINT[$i]}"
    done

    # 批量入口。
    #
    # all.sh 早就存在 (1050 行 / 13 类节点 / --dry-run --no-tls --only --fp),
    # 但一直没有菜单入口 —— 只能手动敲命令。对照 SB: 它的
    # 「节点管理 → 11) 全协议一键生成」是常驻菜单项, 而 all.sh 的批量档位
    # 设计 (--dry-run / --only) 本来就是照着这个思路做的, 却没有出口。
    local batch_idx=$(( n_single + n_batch + 1 ))
    printf "  ${DIM}────────────────────────────────${RESET}\n"
    printf "  ${CYAN}%2d${RESET}) ${BOLD}全协议一键生成${RESET} ${DIM}(推荐先试这个)${RESET}\n" "$batch_idx"
    printf "  ${CYAN}%2d${RESET}) 返回\n" "0"
    printf "\n请选择 [1-%d, 0=返回]: " "$batch_idx"
    local c; read -r c
    c=$(clean_input "${c:-}")

    [[ "$c" == "0" ]] && return 0
    if [[ "$c" == "$batch_idx" ]]; then
        all_menu; return
    fi

    # 没有独立脚本的协议 -> 走 all.sh --only
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c > n_single && c <= n_single + n_batch )); then
        local bi=$(( c - n_single - 1 ))
        print_info "生成 ${BATCH_PROTO_LABELS[$bi]} (走 all.sh --only ${BATCH_PROTO_ONLY[$bi]})"
        _all_run --only "${BATCH_PROTO_ONLY[$bi]}"
        fw_after_node_change
        declare -F m_publish_addrs >/dev/null 2>&1 && m_publish_addrs
        return
    fi

    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n_single )) || { ui_invalid "$c"; return 1; }
    local script="$HERE/conf/${PROTO_SCRIPTS[$((c-1))]}"
    [[ -f "$script" ]] || { print_error "脚本缺失: $script"; return 1; }
    # 传 add 子命令: 直接进新增向导, 不先进协议脚本自己的管理面板。
    # 少了它, 「添加节点 → 2) VLESS」会先显示"查看/新增/删除配置", 得再选一次 2;
    # 一路回车时那些回车全被二级菜单吃掉成「无效选项:」, 结果节点数仍是 0。
    BASE_DIR="$SRV_ROOT" MIHOMO_BIN="$SRV_BIN" SELF_DIR="$HERE/conf" bash "$script" add
    fw_after_node_change
    declare -F m_publish_addrs >/dev/null 2>&1 && m_publish_addrs
    # 节点变了 → 刷新已有分享链接的内容 (token/URL/TTL/次数全不变, 只换内容)。
    # 放在这里而不是每个协议脚本里: 六份协议脚本各加一次必然漂移, 一处足够。
    _share_refresh_after_change
}

# all.sh 的菜单外壳。
#
# 职责边界: all.sh 自己管参数和生成, 这里只做「以菜单形式把参数收上来」。
# 不重复实现任何协议 —— 和 SB 的 batch.sh 思路一致 (编排层不重实现协议)。
all_menu() {
    local script="$HERE/conf/all.sh"
    if [[ ! -f "$script" ]]; then
        print_error "批量生成脚本缺失: $script"
        print_info "请重新运行安装脚本补齐文件"
        return 1
    fi
    print_title "全协议一键生成"
    cat <<'EOF'
  一次性生成全部支持协议, 端口自动顺延不冲突, 失败不中断整批。

  生成前可以先预览 (强烈建议先做这一步):
EOF
    printf "    1) \033[36m先预览\033[0m (dry-run, 不写入任何文件)     \033[2m★推荐第一次选这个\033[0m\n"
    printf "    2) \033[36m快速生成\033[0m                           \033[2m端口自动分配, 不提问 · 已存在的节点跳过\033[0m\n"
    printf "    3) \033[36m逐项生成\033[0m                           \033[2m会问端口区间, 其余自动 · 已存在的节点跳过\033[0m\n"
    printf "    4) \033[33m重建\033[0m                               \033[2m先清掉同协议旧节点再重新生成 ⚠ 会覆盖\033[0m\n"
    printf "    5) 不含证书                               \033[2m跳过所有需要证书的协议\033[0m\n"
    printf "    6) 只生成指定协议                         \033[2m逐个选\033[0m\n"
    printf "    7) \033[36m自签全量生成\033[0m                       \033[2m没有真证书时生成自签, TLS 协议也全量产出\033[0m\n"
    printf "    0) 返回\n"
    printf "请选择 [1-7, 0=返回]: "
    local c; read -r c
    c=$(clean_input "${c:-}")
    case "$c" in
        1) _all_run --dry-run ;;
        2) _all_run --quick ;;
        3) _all_run ;;
        4) _all_rebuild ;;
        5) _all_run --no-tls ;;
        6) _all_pick ;;
        7) _all_self_sign ;;
        0) return ;;
        *) ui_invalid "$c" ;;
    esac
}

# 自签全量生成。自签的代价要当面讲清: 客户端靠 skip-cert-verify 跳过校验,
# 而**过 CDN 必然失败** (Cloudflare 回源不认自签 CA), 所以 CDN 档位会照旧跳过。
_all_self_sign() {
    print_warn "将生成一张自签证书, 让需要证书的协议也全量产出。"
    print_info "客户端已写 skip-cert-verify; 但 CDN 档位仍会跳过 —— CF 回源不认自签 CA。"
    printf "继续? [Y/n]: "
    local a; read -r a
    case "$(clean_input "${a:-}")" in
        n|N|no|NO) print_info "已取消" ;;
        *) _all_run --quick --self-sign ;;
    esac
}

# 「重建」是唯一会删东西的档位, 所以单独确认一次。
#
# 提醒它"校验不过会自动还原"是有意义的: 用户对"重建"最大的顾虑就是
# "万一失败了我是不是一个节点都没了"。说清楚回滚存在, 他才敢用。
_all_rebuild() {
    print_warn "重建会先清掉同协议的全部旧节点, 再按当前设置重新生成。"
    print_info "如果末尾校验不通过, 旧节点会**自动还原**, 不会丢。"
    printf "确认重建? [y/N]: "
    local a; read -r a
    case "$(clean_input "${a:-}")" in
        y|Y|yes|YES) _all_run --force ;;
        *) print_info "已取消" ;;
    esac
}

_all_run() {
    local script="$HERE/conf/all.sh"
    BASE_DIR="$SRV_ROOT" MIHOMO_BIN="$SRV_BIN" SELF_DIR="$HERE/conf" \
        bash "$script" "$@"
}

_all_pick() {
    local script="$HERE/conf/all.sh"
    local -a ids=()
    local line
    printf "\n可用协议标识 (空格分隔, 直接回车=全部):\n"
    sed -n 's/^ALL_GEN_IDS="\(.*\)"/\1/p' "$script" | tr ' ' '\n' | while read -r line; do
        [[ -n "$line" ]] && printf "  %s\n" "$line"
    done
    printf "\n请输入: "
    local only; read -r only
    only=$(printf '%s' "$only" | tr -d '[:space:]')
    if [[ -z "$only" ]]; then
        _all_run
        return
    fi
    # 只接受标识符, 拼进 --only 之前先挡掉分号/引号/反引号
    if [[ "$only" =~ [^a-zA-Z0-9_-] ]]; then
        print_error "只能包含字母、数字、- 和 _"
        return 1
    fi
    _all_run --only "$only"
}

manage_node() {
    print_title "管理节点"
    local i
    local n_single=${#PROTO_SCRIPTS[@]}
    for i in "${!PROTO_SCRIPTS[@]}"; do
        printf "  ${CYAN}%2d${RESET}) %-24s ${DIM}(%s)${RESET}\n" \
            "$((i+1))" "${PROTO_LABELS[$i]}" "${PROTO_HINTS[$i]}"
    done
    # 红字标不可逆 —— 与 SB 的菜单约定一致 (batch.sh:117 破坏性操作必须
    # 手打 yes 才执行)。这里先标出来, 执行时还有第二道确认。
    printf "  ${RED}%2d${RESET}) 清空全部节点  ${DIM}(不可逆, 会备份后删除所有节点)${RESET}\n" "$((n_single+1))"
    printf "  ${CYAN}%2d${RESET}) 返回\n" "0"
    printf "\n请选择 [1-%d, 0=返回]: " "$((n_single+1))"
    local c; read -r c
    c=$(clean_input "${c:-}")
    [[ "$c" == "0" ]] && return 0
    if [[ "$c" == "$((n_single+1))" ]]; then
        wipe_all_nodes; return
    fi
    # 上界跟着数组长度走, 不再写死 —— 写死的那版在加协议时会被静默漏掉。
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n_single )) || { ui_invalid "$c"; return 1; }
    local script="$HERE/conf/${PROTO_SCRIPTS[$((c-1))]}"
    [[ -f "$script" ]] || { print_error "脚本缺失: $script"; return 1; }
    BASE_DIR="$SRV_ROOT" MIHOMO_BIN="$SRV_BIN" SELF_DIR="$HERE/conf" bash "$script"
    fw_after_node_change
    declare -F m_publish_addrs >/dev/null 2>&1 && m_publish_addrs
}

# 清空全部节点 (保留服务、证书、out/)
#
# 对齐 SB 的 wipe_all_nodes (batch.sh 侧的 12) 清空全部节点):
#   备份 → 两级确认 → 删配置 → 吊销分享 token → 重新校验并重载 → 失败回滚
#
# 与「卸载服务+节点」(uninstall_service 里的模式 2) 的区别:
#   那个会连带停服务删 unit; 这个只清节点, 服务继续跑。
#
# 为什么必须吊销 token: 分享链接里带的是节点地址和凭据。节点都删了,
# 链接还"有效"会让客户端反复去拉、拉回来的却是一份空配置。
wipe_all_nodes() {
    print_title "清空全部节点"
    local n; n=$(ls "$SRV_CONFIGD"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
    [[ "$n" -gt 0 ]] || { print_info "当前没有节点, 无需清空"; return; }

    # 实际会删什么 —— 先摆出来让用户看清楚, 不给"惊喜删除"
    printf "  将删除以下 %d 个节点配置:\n" "$n"
    local f
    for f in "$SRV_CONFIGD"/*.yaml; do
        [[ -f "$f" ]] || continue
        printf "    %-24s %s\n" "$(basename "$f")" \
            "$(grep -hoE 'name: *m[A-Za-z0-9_-]+' "$f" 2>/dev/null | awk 'NR==1' | sed 's/name: *//')"
    done
    # out/ 里的客户端产物**一起删**。服务端配置都没了, 那些产物指向的端口
    # 早已没人监听, 留着只会让人把死配置分发出去 —— 面板曾经显示
    # "节点数量 61" 就是这么来的 (它数的就是产物)。
    local n_art; n_art=$(ls "$SRV_OUT"/*_client-*.yaml 2>/dev/null | wc -l | tr -d ' ')
    printf "\n  \033[33m保留\033[0m: 证书 / 服务单元 / 分享记录\n"
    printf "  \033[31m删除\033[0m: conf/config.d/*.yaml + out/ 客户端产物 (%s 个) + 已发出的分享链接 (全部吊销)\n" "${n_art:-0}"

    # 两级确认 —— 与 SB 一致: 普通操作 [y/N], 破坏性必须手打 yes
    local a
    printf "\n请输入 \033[1myes\033[0m 确认清空 (其它任何输入都取消): "
    read -r a || { print_info "已取消"; return; }
    [[ "$a" == "yes" ]] || { print_info "已取消 (需要输入 yes 才会执行)"; return; }

    # 先备份 —— 清空是不可逆的, 出问题要能捞回来
    local bak="$SRV_ROOT/nodes.bak.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bak" || { print_error "备份目录创建失败, 已中止"; return 1; }
    cp -a "$SRV_CONFIGD"/*.yaml "$bak"/ 2>/dev/null
    # 产物一并备份 —— 删了就找不回来, 留一份跟节点放在一起才对称
    mkdir -p "$bak/out" 2>/dev/null
    cp -a "$SRV_OUT"/*.yaml "$SRV_OUT"/*.txt "$bak/out"/ 2>/dev/null
    print_ok "已备份 $n 个节点 + ${n_art:-0} 个产物到: $bak"

    # 先摘 Nginx 上的回源片段, 再删片段。
    # 反过来的话绑定表先没了, 就再也看不出这些节点当初挂在哪个域名下,
    # 站点里那段 location 会永远留着 (指向早已没人监听的端口)。
    declare -F cdn_wipe_all >/dev/null 2>&1 && {
        print_info "清理 Nginx 上的 CDN 回源配置..."
        cdn_wipe_all
    }

    rm -f "$SRV_CONFIGD"/*.yaml
    # 产物同步删。单节点删除早就走 m_out_rm_artifacts 清产物了 (见 Reality.sh),
    # 唯独批量清空漏掉 —— 于是 out/ 越积越多, 且每个都还能被 build_sub.py
    # 收进订阅, 用户拿到的是一批连不上的节点。
    rm -f "$SRV_OUT"/*_client-*.yaml 2>/dev/null
    print_ok "已删除 ${n_art:-0} 个客户端产物"

    # 重新合并 + 校验。**顺序很重要**: token 吊销放在校验通过之后 ——
    # 否则一旦校验失败回滚了配置, token 却已经吊销, 用户手里的链接
    # 莫名其妙全废了。
    #
    # 校验不过就把备份捞回来 —— 宁可停在旧状态, 也不要留一个跑不起来的服务。
    if ! python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1; then
        print_error "配置合并失败, 正在回滚"
        cp -a "$bak"/*.yaml "$SRV_CONFIGD"/ 2>/dev/null
        # 产物一并还原 —— 回滚只恢复片段的话, out/ 里那批产物就回不来了,
        # 用户手里的分享链接会指向一个不存在的节点集合
        [[ -d "$bak/out" ]] && cp -a "$bak/out"/. "$SRV_OUT"/ 2>/dev/null
        python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1
        systemctl restart "$SRV_SERVICE" 2>/dev/null
        print_ok "已回滚到清空前的状态"
        return 1
    fi
    # 用项目统一的校验写法: -d 指向 conf 目录, mihomo 自动读其中的
    # config.yaml。写成 -f "$SRV_CONF" (SRV_CONF 是**目录**) 会让 mihomo
    # 拿目录当配置文件, 必然失败 —— wipe 走到这步就永远触发回滚。
    if ! "$SRV_BIN" -t -d "$SRV_CONF" >/dev/null 2>&1; then
        print_error "内核校验不通过, 正在回滚"
        cp -a "$bak"/*.yaml "$SRV_CONFIGD"/ 2>/dev/null
        # 产物一并还原 (同上: 回滚只恢复片段的话产物就永久没了)
        [[ -d "$bak/out" ]] && cp -a "$bak/out"/. "$SRV_OUT"/ 2>/dev/null
        python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1
        systemctl restart "$SRV_SERVICE" 2>/dev/null
        print_ok "已回滚到清空前的状态"
        return 1
    fi

    # 到这一步才算真的清成功, 此时才吊销 token。
    # 节点都没了, 链接留着只会让客户端反复去拉、拉回来一份空配置。
    #
    # ★ 改走公共分享服务。原来这里是**直接改本地 share/shares/*.json** ——
    #   存储搬到公共服务之后那个目录里只剩下 .migrated 文件, 循环匹配到 0 个,
    #   于是"清空全部节点"**不再吊销任何链接**, 而且一声不吭 (实测发现)。
    if ! declare -F share_revoke_all >/dev/null 2>&1; then
        # shellcheck disable=SC1090
        source "$HERE/share/share.sh" 2>/dev/null || true
    fi
    local revoked=0
    if declare -F share_revoke_all >/dev/null 2>&1; then
        share_revoke_all
        revoked=${_SHARE_REVOKED_N:-0}
    fi
    [[ "$revoked" -gt 0 ]] && print_ok "已吊销 $revoked 条分享链接"

    systemctl restart "$SRV_SERVICE" 2>/dev/null
    print_ok "已清空全部节点, 服务已重启"
    print_info "备份保留在: $bak (确认无需后可自行删除)"
}

# =============================================================
# 拉取节点 (把外部订阅并进来, 统一用本项目的分享发出去)
# =============================================================
IMPORT_DIR="$SRV_ROOT/share/imported"

pull_node() {
    print_title "拉取节点"
    printf '\n输入外部订阅地址 (http/https):\n请输入: '
    local url; read -r url
    [[ "$url" == http://* || "$url" == https://* ]] || { print_error "需要 http/https 链接"; return 1; }

    local tmp; tmp=$(mktemp -d)
    printf '\n正在拉取...'
    local code
    code=$(curl -sSL --max-time 40 -o "$tmp/sub.yaml" -w '%{http_code}' "$url" 2>/dev/null)
    printf '\n'
    if [[ "$code" != "200" ]]; then print_error "拉取失败 HTTP $code"; rm -rf "$tmp"; return 1; fi

    # 校验: 必须是 Mihomo 订阅格式
    local n
    n=$(python3 - "$tmp/sub.yaml" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(d, dict) or not isinstance(d.get("proxies"), list):
    print(-1); raise SystemExit
good = [p for p in d["proxies"]
        if isinstance(p, dict) and p.get("name") and p.get("type")
        and "server" in p and "port" in p]
print(len(good))
PY
)
    if [[ "$n" == "-1" || -z "$n" ]]; then
        print_error "不是 Mihomo 订阅格式 (需要顶层 proxies: 列表)"
        print_info "若对方只提供 vless:// / trojan:// 等裸链接, 请让对方导出为 YAML 订阅"
        rm -rf "$tmp"; return 1
    fi
    [[ "$n" == "0" ]] && { print_error "订阅里没有有效节点"; rm -rf "$tmp"; return 1; }

    local name; name=$(printf '%s' "${url##*/}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
    [[ -z "$name" || "$name" == "sub" || "$name" == "share" ]] && name="imp$(date +%m%d%H%M)"
    local base="$name" k=1
    while [[ -f "$IMPORT_DIR/$name.yaml" ]]; do name="${base}_$k"; k=$((k+1)); done

    mkdir -p "$IMPORT_DIR"
    python3 - "$tmp/sub.yaml" "$IMPORT_DIR/$name.yaml" "$url" <<'PY'
import sys, yaml, datetime
src, dst, url = sys.argv[1:4]
d = yaml.safe_load(open(src, encoding="utf-8"))
good = [p for p in d["proxies"]
        if isinstance(p, dict) and p.get("name") and p.get("type")
        and "server" in p and "port" in p]
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(f"# 拉取自 {url}\n")
    fh.write(f"# {datetime.datetime.now().isoformat(timespec='seconds')}\n\n")
    yaml.safe_dump({"proxies": good}, fh, sort_keys=False,
                   allow_unicode=True, default_flow_style=False)
PY
    printf '%s\n' "$url" > "$IMPORT_DIR/$name.url"
    rm -rf "$tmp"
    print_ok "已导入 $n 个节点 → $name"
    print_info "分享时选择「仅 imported」即可只发这批, 选「全部」则与自建节点一起发"
}

list_imported() {
    print_title "已拉取的外部订阅"
    local f found=0
    for f in "$IMPORT_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        local name; name=$(basename "$f" .yaml)
        local n; n=$(python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
if not isinstance(d, dict): d = {}
print(len(d.get('proxies') or []))" "$f" 2>/dev/null)
        printf '  \033[1m%-20s\033[0m %s 个节点\n' "$name" "$n"
        found=1
    done
    [[ $found -eq 0 ]] && print_info "还没有拉取过外部订阅"
    return 0
}

# =============================================================
# 更新配置 —— 三道关 + 回滚
# =============================================================
update_config() {
    # 标题改成 SB 的叫法 (「校验配置 + 重载」)。
    #
    # 为什么: 用户想**确认配置没问题**时的第一反应是找"校验"。
    # 原来这一项叫"更新配置", 听起来像"会改动东西", 于是想只看一眼的人
    # 不敢点 —— 他会去"系统信息"里找, 而那里没有校验。
    # SB 把它单列成主菜单第 6 项, 名字就是"校验配置 + 重载"。
    print_title "校验配置 + 重载"
    ensure_dirs
    print_info "1/4 合并 conf/config.d → conf/config.yaml"
    python3 "$M_LIB/merge.py" --conf "$SRV_CONF" || {
        print_error "合并失败"; return 1; }

    print_info "2/4 严格字段校验"
    if ! python3 "$M_LIB/validate.py" --conf "$SRV_CONF"; then
        print_error "字段校验未通过, 配置未生效"; return 1; fi

    # 3/4 证书落位。
    #
    # ★ 为什么单列这一步: 合并 / 严格字段 / `mihomo -t` **都不看证书文件**。
    #   实测把 certificate 指到不存在的文件、或塞一份垃圾进去, `mihomo -t`
    #   依旧输出 "test is successful" —— 而监听起不来只进日志, 面板全绿。
    #   证书是这份配置里唯一"内核不替你把关"的外部依赖, 所以自己查一遍。
    print_info "3/4 证书落位 (文件在不在 / 私钥配不配)"
    if declare -F cert_verify_referenced >/dev/null 2>&1; then
        cert_verify_referenced "$SRV_CONF"/config.yaml "$SRV_CONFIGD"/*.yaml || {
            print_error "证书有问题, 配置未生效 (上面已逐条列出)"; return 1; }
        print_ok "证书文件与配对均正常"
    fi

    print_info "4/4 内核校验 (mihomo -t)"
    "$SRV_BIN" -t -d "$SRV_CONF" >/tmp/mihomo_t.log 2>&1 || {
        tail -8 /tmp/mihomo_t.log >&2
        print_error "内核校验失败, 配置未生效"; return 1; }
    print_ok "全部校验通过"

    # 校验完**顺手把状态摆出来**, 而不是只报一句"通过"就走。
    # 用户刚做完"确认配置"这件事, 最想知道的就是"现在到底什么状态":
    #     校验结果: 通过
    #     运行状态: active
    #     内核版本: <版本号>
    #     占用端口: 53,80,443,2087,...
    printf '\n' >&2
    local st ver ports
    st=$(systemctl is-active "$SRV_SERVICE" 2>/dev/null || echo "unknown")
    if [[ "$st" == "active" ]]; then
        printf "  运行状态: ${GREEN}%s${RESET}\n" "$st" >&2
    else
        printf "  运行状态: ${RED}%s${RESET}\n" "$st" >&2
    fi
    ver=$("$SRV_BIN" -v 2>/dev/null | awk 'NR==1')
    printf "  内核版本: %s\n" "${ver:--}" >&2
    # 只列协议端口区间 (20000-29999), 与 status_block 口径一致 ——
    # 全量列会把 9090 / SSH / nginx 都倒出来, 反而看不出节点情况。
    ports=$( { ss -tlnp 2>/dev/null; ss -ulnp 2>/dev/null; } \
        | grep "(\"$(basename "$SRV_BIN")\"," 2>/dev/null \
        | awk '{print $4}' | sed -n 's/.*:\([0-9]\{1,5\}\)$/\1/p' \
        | awk '$1 >= 20000 && $1 <= 29999' | sort -un | tr '\n' ' ' )
    printf "  占用端口: %s\n" "${ports:-（无）}" >&2

    m_sync_reload
}

show_client_files() {
    print_title "节点分享内容 (out/)"
    local f found=0
    for f in "$SRV_OUT"/*_client-*.yaml; do
        [[ -f "$f" ]] || continue
        printf "\n\033[1m--- %s ---\033[0m\n" "$(basename "$f")"
        cat "$f"
        found=1
    done
    for f in "$SRV_OUT"/*.txt; do
        [[ -f "$f" ]] || continue
        printf "\n\033[1m--- %s ---\033[0m\n" "$(basename "$f")"
        cat "$f"
        found=1
    done
    [[ $found -eq 0 ]] && print_info "out/ 还是空的"
    return 0
}

log_menu() {
    print_title "日志"
    # 同 svc_menu: 菜单编号必须和 case 分支号逐一对应。
    # 这里原来写的是 1/2/4/5 而 case 是 1/2/3/4 —— 于是:
    #     按 "4) 清空日志"        -> 执行的是"查看内核最近 100 行"
    #     按 "5) 查看内核最近100行"-> **什么都不发生** (没有 case 5)
    #     真正清空日志的分支 3, 菜单里**根本没列出来**
    # 由 tools/check_menu_ids.sh 机械拦截。
    ui_menu 1 "实时查看运行日志 (tail -f)"
    ui_menu 2 "查看错误日志"
    ui_menu 3 "清空日志文件"
    ui_menu 4 "查看内核最近 100 行"
    echo >&2
    printf "  ${CYAN}请选择${RESET}: "; local c; read -r c
    c=$(clean_input "$c")
    case "$c" in
        1) print_info "Ctrl+C 退出"; tail -f "$SRV_ROOT/mihomo.log" 2>/dev/null ;;
        2) journalctl -u "$SRV_SERVICE" -p err -n 80 --no-pager 2>/dev/null \
              || tail -80 "$SRV_ROOT/error-mihomo.log" 2>/dev/null ;;
        3) printf '确认清空日志? (y/N): '; read -r a
           [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; return; }
           : > "$SRV_ROOT/mihomo.log" 2>/dev/null
           : > "$SRV_ROOT/error-mihomo.log" 2>/dev/null
           journalctl --rotate --vacuum-time=1s >/dev/null 2>&1
           print_ok "日志已清空" ;;
        4) journalctl -u "$SRV_SERVICE" -n 100 --no-pager 2>/dev/null \
              || tail -100 "$SRV_ROOT/mihomo.log" 2>/dev/null ;;
    esac
}

sys_info() {
    print_title "系统信息"
    local memfree
    memfree=$(df -h / | awk 'NR==2{print $4}')
    printf "  系统    : %s\n" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
    printf "  架构    : %s\n" "$(uname -m)"
    printf "  内核    : %s\n" "$(uname -r)"
    printf "  磁盘可用: %s\n" "$memfree"
    printf "  运行时长: %s\n" "$(uptime -p 2>/dev/null)"
    if [[ -x "$SRV_BIN" ]]; then
        printf "  Mihomo  : %s\n" "$("$SRV_BIN" -v 2>/dev/null | awk 'NR==1')"
    fi
    # 同上: 按进程名匹配 (ss 只显示进程名), 且 TCP+UDP 都要列 ——
    # hysteria2 / tuic 是 QUIC 协议, 只监听 UDP, 只列 TCP 会漏掉它们。
    printf "  监听端口:\n"
    { ss -tlnp 2>/dev/null; ss -ulnp 2>/dev/null; } \
        | grep "(\"$(basename "$SRV_BIN")\"," \
        | awk '{printf "    %s %s\n", $1, $4}' | sort -u -k2,2
    printf "  防火墙:\n"
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --list-ports 2>/dev/null | sed 's/^/    /'
    elif command -v ufw >/dev/null; then
        ufw status 2>/dev/null | awk 'NR<=6' | sed 's/^/    /'
    else
        printf "    (未检测到 firewall-cmd / ufw)\n"
    fi
}

uninstall_service() {
    print_title "卸载 Mihomo 服务端"
    # 与客户端同理由: SRV_ROOT 可被环境变量改掉, 这时这两个服务名可能属于
    # 别的 mihomo 实例。unit 文件里写了 ExecStart 路径, 对不上就不碰。
    # ★ 分享单元**不再取 $SHARE_SERVICE**: 它的默认值在两处不一致
    #   (lib/env.sh: mihomo-share / share/share.sh: proxy-share-service),
    #   谁生效取决于 source 顺序。一旦取到 proxy-share-service, 而 SRV_ROOT
    #   又恰好是 unit 文件路径的前缀 (实测 SRV_ROOT=/opt 或 / 就会),
    #   归属判断会通过, 卸载 M 就把**公共基础服务**删了。
    #   所以这里只认历史上确实属于本内核的单元名。
    local svc="$SRV_SERVICE" shsvc="mihomo-share"
    _srv_unit_owned_by_me "$svc"   || { svc="";   print_warn "$SRV_SERVICE 的 unit 不属于 $SRV_ROOT, 不会删除"; }
    _srv_unit_owned_by_me "$shsvc" || shsvc=""
    _srv_report_shared_untouched
    cat <<EOF
  1) 仅卸载服务     停服务+删 unit, 保留配置/证书/out/分享记录
  2) 卸载服务+节点  上面这些, 再删 conf/config.d 下的节点配置
  3) 彻底删除       本脚本在本机创建的全部内容, 见下方清单

  当前安装目录: $SRV_ROOT
  服务: ${svc:-无} (本机)  分享服务: ${shsvc:-无} (本机)
EOF
    printf '\n请选择 [1-3, 回车取消]: '
    local mode; read -r mode
    case "$mode" in
        1) [[ -n "$svc" ]]   && _uninstall_unit "$svc"
           [[ -n "$shsvc" ]] && _uninstall_unit "$shsvc"
           print_info "配置与数据已保留在 $SRV_ROOT" ;;
        2) [[ -n "$svc" ]]   && _uninstall_unit "$svc"
           [[ -n "$shsvc" ]] && _uninstall_unit "$shsvc"
           declare -F cdn_wipe_all >/dev/null 2>&1 && cdn_wipe_all
           rm -f "$SRV_CONFIGD"/*.yaml
           # 客户端产物一起清 —— 服务配置都没了, 产物指向的端口没人监听
           rm -f "$SRV_OUT"/*_client-*.yaml 2>/dev/null
           python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1 || true
           print_ok "节点配置与客户端产物已删除 (Nginx 回源片段同步清理)"
           print_info "证书/out/分享记录已保留在 $SRV_ROOT" ;;
        3) _uninstall_all "$svc" "$shsvc" ;;
        "") print_info "已取消" ;;
        *)  ui_invalid "$c" ;;
    esac
}

# ---------------------------------------------------------------- 公共基础服务
# 被 M / SB / X **共用**的单元。卸载任何一个内核都不能带走它:
# 删了不只是本内核的链接失效 —— 另外两个内核已经发出去的链接会一起断,
# 而且现场看不出是谁删的。
_SRV_SHARED_UNITS=(proxy-share-service)

_srv_is_shared_unit() {
    local s="${1:-}" u
    for u in "${_SRV_SHARED_UNITS[@]}"; do [[ "$s" == "$u" ]] && return 0; done
    return 1
}

# 卸载时把"公共基础服务不动"这件事**说出来**。不说的话用户会以为
# 面板漏删了, 转头自己去 systemctl disable —— 那才是真正的事故现场。
_srv_report_shared_untouched() {
    local u
    for u in "${_SRV_SHARED_UNITS[@]}"; do
        [[ -f "/etc/systemd/system/$u.service" ]] || continue
        print_info "公共基础服务 $u 不在卸载范围内 (M/SB/X 共用, 删了会连带打断其它内核的链接)"
        print_info "  要单独卸载它: git clone https://github.com/mi1314cat/Share-Service && bash Share-Service/install.sh uninstall"
    done
}

# 该 systemd unit 是不是本安装目录的?
# unit 里写着 ExecStart=<SRV_ROOT>/mihomo, 对不上就不能删 ——
# 否则 SRV_ROOT 指向别处时会误删另一个 mihomo 实例的服务。
_srv_unit_owned_by_me() {
    local s="${1:-}" f
    # set -u 下 "$1" 未传会直接报错中断整个面板 —— 这类"内部工具函数"
    # 必须容错, 传空就当"不归我管"
    [[ -n "$s" ]] || return 1
    f="/etc/systemd/system/$s.service"
    [[ -f "$f" ]] || return 1
    grep -qF -- "$SRV_ROOT" "$f" 2>/dev/null || return 1
    return 0
}

_uninstall_unit() {
    local s="$1"
    # 兜底闸门: 就算调用方算错了名字, 这里也不动公共基础服务。
    if _srv_is_shared_unit "$s"; then
        print_warn "$s 是 M/SB/X 共用的公共基础服务, 拒绝删除"
        return 1
    fi
    systemctl stop "$s" 2>/dev/null
    systemctl disable "$s" 2>/dev/null
    rm -f "/etc/systemd/system/$s.service"
    systemctl daemon-reload 2>/dev/null
    print_ok "服务已移除: $s"
}

# 彻底删除: 停所有服务 → 删 unit → 删安装目录 → 删本脚本自己下载到别处的残留。
# 借鉴 参考实现 的做法: 放行过的端口登记在 .fw-ports, 卸载时按清单精确
# 回收, 不扫防火墙全表 (避免误删用户自己的规则)。
_uninstall_all() {
    local svc="${1:-}" shsvc="${2:-}"
    [[ -n "$svc" ]]   || svc=$(_srv_unit_owned_by_me "$SRV_SERVICE"   && echo "$SRV_SERVICE")
    [[ -n "$shsvc" ]] || shsvc=$(_srv_unit_owned_by_me "mihomo-share" && echo "mihomo-share")
    cat <<EOF

  即将【永久删除】以下内容 (不可恢复, 建议先备份):

    服务      : ${svc:-无}${svc:+, }${shsvc:-无} 的 systemd unit
    目录      : $SRV_ROOT
                ├─ mihomo            内核
                ├─ src/              面板脚本
                ├─ conf/             配置、节点、证书
                ├─ out/              客户端配置文件与分享链接
                ├─ share/            分享服务与全部分享记录
                └─ install_info.env  安装信息 (含域名/IP)
    防火墙    : 只回收本程序登记在 .fw-ports 里的端口, 不动其它规则
    不含      : 公共基础服务 proxy-share-service (M/SB/X 共用) 及其数据

  确认彻底删除? 输入 DELETE 继续 (其它任何输入都取消):
EOF
    local a; read -r a
    [[ "$a" == "DELETE" ]] || { print_info "已取消, 未删除任何内容"; return; }

    # 传空串就跳过 —— uninstall_service 已按 unit 归属做过校验
    [[ -n "$svc" ]]   && _uninstall_unit "$svc"
    [[ -n "$shsvc" ]] && _uninstall_unit "$shsvc"

    # 端口回收: 只按自己的登记表逐个走 fw_close_port。
    #
    # 原来这里是内联实现, 只认 ufw/firewalld/iptables 三家, 且**没有 SSH 保护** ——
    # 登记表里万一混进了 sshd 端口, 这段会直接把 SSH 规则删掉, 然后人就再也连不上了。
    # fw_close_port 三道闸门: 登记表 / sshd 实测监听 / 系统常用端口, 任何一道不过就不动防火墙。
    declare -F fw_close_port >/dev/null 2>&1 && {
        local _p _n=0 _fw="$SRV_ROOT/.fw-ports"
        if [[ -f "$_fw" ]]; then
            while IFS= read -r _p; do
                [[ "$_p" =~ ^[0-9]+$ ]] || continue
                fw_close_port "$_p" "卸载" && _n=$((_n + 1))
            done < "$_fw"
        fi
        print_ok "已回收登记的防火墙端口: $_n 个"
    }

    rm -rf "$SRV_ROOT"
    if [[ -e "$SRV_ROOT" ]]; then
        print_error "删除失败, 目录仍在: $SRV_ROOT"
        print_error "请检查权限 (是否有进程占用), 或手动执行: rm -rf $SRV_ROOT"
        return 1
    fi
    print_ok "已彻底删除: $SRV_ROOT"

    # 最后确认: 端口是否真的全部释放
    local left
    left=$(m_listening_ports | awk '$1>=20000 && $1<=20100' | tr '\n' ' ')
    [[ -n "$left" ]] && print_warn "这些端口仍在监听 (可能属于其它程序): $left"
    return 0
}

show_logs() {
    print_title "运行日志"
    journalctl -u "$SRV_SERVICE" -n 60 --no-pager 2>/dev/null || tail -60 "$SRV_ROOT/mihomo.log" 2>/dev/null
}

svc_menu() {
    print_title "服务管理"
    # 菜单编号必须和下面 case 的分支号**逐一对应**。
    #
    # 实测 bug: 这里原来写的是 1/2/4/5/6/7 —— 从 2 直接跳到 4,
    # 而 case 里是 1/2/3/4/5/6 连续排的。于是每个操作都**错位一格**:
    #     菜单显示 "4) 重启"       -> 按下 4 得到的是"状态"
    #     菜单显示 "5) 状态"       -> 按下 5 得到的是"开机自启"
    #     菜单显示 "6) 开机自启"   -> 按下 6 得到的是"手动上传内核"
    #     菜单显示 "7) 手动上传内核"-> 按下 7 **什么都不发生** (没有 case 7)
    # 六个操作全错, 最后一个彻底失效。这类"标签和分支号不一致"不会报错,
    # 只会安静地做错事 —— 由 tools/check_menu_ids.sh 机械拦截。
    ui_menu 1 "启动"
    ui_menu 2 "停止"
    ui_menu 3 "重启"
    ui_menu 4 "状态"
    ui_menu 5 "开机自启"
    ui_menu 6 "手动上传内核 (下载不通时用)"
    printf "请选择: "; local c; read -r c
    case "$c" in
        1) systemctl start "$SRV_SERVICE" && print_ok "已启动" ;;
        2) systemctl stop "$SRV_SERVICE" && print_ok "已停止" ;;
        3) systemctl restart "$SRV_SERVICE" && print_ok "已重启" ;;
        4) systemctl status "$SRV_SERVICE" --no-pager | awk 'NR<=15' ;;
        5) systemctl enable "$SRV_SERVICE" && print_ok "已设置开机自启" ;;
        6) srv_kernel_menu ;;
    esac
}

# ---------- 手动上传内核 ----------
# 客户端有同名功能 (check_menu → 4)。这里保持一致, 只是路径不同。
# 认架构的方式两边都一样: 读 ELF 头的 e_machine, 再真跑一次取版本。
srv_kernel_menu() {
    print_title "手动上传内核"
    local kdir="${MIHOMO_KERNEL_DIR:-${SRV_ROOT%/*}/mihomo-kernels}"
    local want; want=$(kernel_want_arch)
    # 用 printf 而不是 cat <<EOF:
    # heredoc 里写 \033[36m 只会被原样打印成字面量 "\033[36m" ——
    # 转义是 POSIX 正则的写法, shell 不解释它。实测输出里那串转义码
    # 直接暴露在路径前面, 复制粘贴会带上垃圾字符。
    printf "\n  把 mihomo 内核压缩包传到这台机器的:\n\n"
    printf "    \033[36m%s\033[0m\n" "$kdir"
    printf "\n  支持 .gz / .zip / 裸二进制, 里面套一层目录也没关系。\n"
    printf "  需要 linux-%s  ·  下载: https://github.com/MetaCubeX/mihomo/releases/latest\n" "$want"
    printf "\n  传完后选择操作:\n"
    printf "    1) 校验已上传的内核 (不动现有内核)\n"
    printf "    2) 用上传的内核重装并重启\n"
    printf "    0) 返回\n"
    printf "请选择: "; local c; read -r c
    case "$c" in
        1) kernel_verify "$kdir" ;;
        2) kernel_install "$kdir" ;;
    esac
}

kernel_want_arch() {
    [[ "$(uname -m)" == "x86_64" ]] && echo amd64 || echo arm64
}

# ELF 头 e_machine: 0x3e=x86-64  0xb7=AArch64
kernel_arch_of() {
    local f="$1" m
    [[ -f "$f" ]] || { echo "?"; return; }
    m=$(od -An -tx1 -j18 -N2 "$f" 2>/dev/null | tr -d ' \n')
    case "$m" in
        3e00) echo amd64 ;;
        b700) echo arm64 ;;
        *)    echo "未知($m)" ;;
    esac
}

kernel_probe() {   # $1=文件  $2=解包目标
    local f="$1" out="$2" inner
    case "${f,,}" in
        *.gz)
            gunzip -c "$f" > "$out" 2>/dev/null || return 1 ;;
        *.zip)
            command -v unzip >/dev/null || return 1
            inner=$(unzip -Z1 "$f" 2>/dev/null | grep -E '(^|/)mihomo$' | awk 'NR==1')
            [[ -n "$inner" ]] || return 1
            unzip -p "$f" "$inner" > "$out" 2>/dev/null || return 1 ;;
        *)
            cp -f "$f" "$out" || return 1 ;;
    esac
    chmod +x "$out" 2>/dev/null
    [[ -s "$out" ]] || return 1
    # 真跑 —— 这是唯一可靠的判据。
    #
    # 必须**先整体捕获再匹配**, 不能写成 "$out" -v 2>/dev/null | grep -qi mihomo:
    # grep -q 一命中就退出, 上游 mihomo 写管道时收到 SIGPIPE (141), 而本脚本
    # 开头是 `set -euo pipefail`, 管道因此被判为失败。
    #
    # 致命的是这是竞态 —— 取决于内核把版本行写完的快慢, 同一台机器时灵时不灵。
    # 实测 上连跑 12 次, 管道式挂了 7 次 (全是 141), 捕获式 12/12。
    # 用户传了好端端的内核却被判成"不可用", 再传一次又"可用" —— 比一直坏更难查。
    _v="$("$out" -v 2>/dev/null)" || return 1
    [[ "$_v" =~ [Mm][Ii][Hh][Oo][Mm][Oo] ]] || return 1
    return 0
}

kernel_verify() {
    local kdir="$1"
    if [[ ! -d "$kdir" ]]; then
        print_error "目录不存在: $kdir"
        print_info "先执行: mkdir -p $kdir, 再把内核文件传进来"
        return 1
    fi
    # 直接输出, 不包在 $(...) 里。
    #
    # 之前用 out=$(...) 捕获再 printf 回来, 踩了三个坑:
    #   1. print_error/print_ok 走 **stderr**, 不进 $(...) → 和 stdout 内容
    #      交错, 用户看到的是 "[成功] mihomo-raw" 紧跟着别的文件的错误行,
    #      完全对不上号;
    #   2. 子 shell 里 $(kernel_want_arch) 拿不到父 shell 状态;
    #   3. 就算捕获到了, 颜色码还得再转义一次, 容易丢。
    #
    # 只把 nullglob 隔离, 输出让它直接落到终端。
    #
    # 注意 f 必须 local: kernel_probe 内部有 local f="$1", 如果这里不声明,
    # 循环变量 f 泄漏成全局, 与子函数的同名局部在某些 bash 版本下会互相踩,
    # 实测导致 .gz 文件被误判为不可用 (单独测 kernel_probe 却完全正常)。
    local probe found="" any=0 base ver arch f
    shopt -s nullglob
    local files=("$kdir"/*)
    shopt -u nullglob

    if (( ${#files[@]} == 0 )); then
        print_error "目录里没有任何文件: $kdir"
        print_info "先 mkdir -p $kdir, 再把内核文件传进来"
        return 1
    fi

    # 解包到临时文件复用。放在循环外, 不必每个文件 mktemp 一次。
    probe=$(mktemp)
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.part ]] && continue
        any=1
        base=$(basename "$f")
        if ! kernel_probe "$f" "$probe"; then
            print_error "$base"
            printf "    不是可用的 mihomo 内核 (无法解压或无法执行)\n\n" >&2
            continue
        fi
        ver=$("$probe" -v 2>/dev/null | awk 'NR==1')
        arch=$(kernel_arch_of "$probe")
        print_ok "$base"
        printf "    版本: %s\n" "$ver" >&2
        printf "    架构: %s\n" "$arch" >&2
        if [[ "$arch" == "$(kernel_want_arch)" ]]; then
            printf "    \033[32m✓ 与本机架构匹配\033[0m (%s)\n\n" "$(uname -m)" >&2
            found=1
        else
            printf "    \033[33m✗ 架构不匹配\033[0m 本机是 %s, 这个是 %s\n\n" \
                "$(uname -m)" "$arch" >&2
        fi
    done
    rm -f "$probe"

    (( any )) || { print_error "目录里没有可用的文件: $kdir"; return 1; }
    if [[ -z "$found" ]]; then
        print_error "没有找到与本机架构匹配的可执行内核"
        print_info "本机需要: linux-$(kernel_want_arch)"
        print_info "下载地址: https://github.com/MetaCubeX/mihomo/releases/latest"
        return 1
    fi
    print_ok "有可用内核"
}

kernel_install() {
    local kdir="$1"
    kernel_verify "$kdir" || return 1
    printf "确认用上传的内核重装? [y/N]: "; local a; read -r a
    [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; return; }

    [[ -f "$M_LIB/../core_install.sh" || -f "$SRV_ROOT/src/core_install.sh" ]] || {
        print_error "缺少 core_install.sh, 无法重装"
        return 1
    }
    local ci="$SRV_ROOT/src/core_install.sh"
    local backup="$SRV_ROOT/mihomo.bak.$(date +%Y%m%d-%H%M%S)"
    cp -f "$SRV_BIN" "$backup" 2>/dev/null \
        && print_ok "已备份当前内核: $(basename "$backup")"

    if bash "$ci" INSTALL_DIR="$SRV_ROOT" SERVICE_NAME="$SRV_SERVICE" \
              MIHOMO_KERNEL_DIR="$kdir" < /dev/null; then
        systemctl restart "$SRV_SERVICE" 2>/dev/null
        print_ok "内核已更新并重启"
        return 0
    fi
    print_error "重装失败, 正在回滚"
    if [[ -f "$backup" ]]; then
        cp -f "$backup" "$SRV_BIN"
        systemctl restart "$SRV_SERVICE" 2>/dev/null
        print_ok "已回滚到原内核"
    fi
    return 1
}

install_share() {
    # shellcheck source=/dev/null
    source "$HERE/share/share.sh"
    share_menu
}

# =============================================================
# 主菜单
# =============================================================
# =============================================================
# 出站 / 规则集 / 端口转发 —— 三个子功能聚合入口
#
# 为什么聚合而不是各占主菜单一个位置: 主菜单已经有 17 项, 再拆三个是 20 项,
# 而这三项的使用频率都远低于「加节点」。合成一个子菜单, 加节点仍一步到位。
# =============================================================
# ================================================================
# 客户端产物设置 (指纹 / 连接地址) —— 生成节点时就写进去
#
# 放在服务端做, 因为**只有服务端知道自己的 IPv4 和 IPv6**。客户端拿到的订阅里
# 只有一个地址, 它无从切换; 产物生成时写对, 客户端拿到的就已经是对���那个。
# ================================================================
# ================================================================
# 导出汇总: 全部节点分享链接 + 订阅短链, 拼成一个文件方便复制
#
# 放在服务端: 只有这里同时有 out/ 下的全部节点产物和 share/ 的订阅链接。
# ================================================================
export_all_nodes() {
    print_title "导出全部 (节点链接 + 订阅短链)"
    local dir="$SRV_OUT"
    mkdir -p "$dir"
    local stamp file; stamp=$(date +%Y%m%d-%H%M%S)
    file="$dir/all-nodes-$stamp.txt"
    {
        echo "# mihomo--core 节点汇总"
        echo "# 生成时间: $(date '+%F %T')"
        echo
    } > "$file"

    local total=0 links
    # 1. 订阅短链 (给别的客户端直接拉)
    local sh
    sh=$(ls "$dir"/share_tag-*.txt 2>/dev/null)
    if [[ -n "$sh" ]]; then
        echo "## 订阅地址" >> "$file"; echo >> "$file"
        while read -r sh; do
            [[ -f "$sh" ]] || continue
            printf '# %s: ' "$(basename "$sh" .txt | sed 's/^share_tag-//')" >> "$file"
            cat "$sh" >> "$file"; echo >> "$file"
        done <<<"$sh"
        total=$((total+1))
    fi

    # 2. 各协议节点的分享链接
    local proto f n=0
    for proto in reality vless vmess trojan hysteria2 tuicv5 anytls ss snell; do
        links=$(ls "$dir"/${proto}_share-*.txt 2>/dev/null | sort)
        [[ -n "$links" ]] || continue
        echo "## $proto" >> "$file"; echo >> "$file"
        while read -r f; do
            [[ -f "$f" ]] || continue
            cat "$f" >> "$file"; echo >> "$file"; n=$((n+1))
        done <<<"$links"
    done
    [[ $n -gt 0 ]] && total=$((total+1))
    [[ $total -eq 0 ]] && { print_warn "out/ 下还没有节点产物, 先建几个节点"; return 1; }

    print_ok "已导出: $file"
    echo "  段落 $total  节点链接 $n" >&2
    echo >&2
    printf '显示内容? [Y/n]: ' >&2
    local a; read -r a
    case "$(clean_input "${a:-y}")" in n|N) return 0 ;; esac
    echo >&2; cat "$file"
    printf '\n按回车继续...' >&2; read -r
}

# 顶部显示一下产物规模 —— 不然用户不知道"已有产物"到底指多少个,
# 也看不出清理残留有没有生效 (上一版显示 61 个节点, 实际早就清空了)。
_ca_show_artifact_count() {
    local na ns; na=$(ls "$SRV_OUT"/*_client-*.yaml 2>/dev/null | wc -l | tr -d ' ')
    ns=$(ls "$SRV_OUT"/*_share-*.txt 2>/dev/null | wc -l | tr -d ' ')
    ui_kv_ascii "已有产物" "${na:-0} 个客户端配置 / ${ns:-0} 条分享链接"
}

_ca_clean_orphan() {
    ui_clear; print_title "清理无对应节点的残留产物"
    local r n del; r=$(m_artifacts_clean_orphan 1); n=${r%% *}; del=${r##* }
    if [[ "${n:-0}" == "0" ]]; then
        print_ok "没有残留产物, out/ 与当前节点一一对应"
        return 0
    fi
    print_warn "发现 $n 个产物找不到对应节点 —— 这些是节点删掉后留下的"
    print_info "它们的 server 指向早已没人监听的端口, 但仍会被 build_sub.py 收进订阅"
    echo
    printf "  确认清理这 ${CYAN}%s${RESET} 个? ${DIM}[y/N]: ${RESET}" "$n" >&2
    local a; read -r a
    case "$(clean_input "${a:-}")" in y|Y) ;; *) print_info "已取消"; return 0 ;; esac
    r=$(m_artifacts_clean_orphan); del=${r##* }
    print_ok "已清理 $del 个残留产物 (对应的分享链接一并清理)"
    _ca_show_artifact_count
}

client_artifact_menu() {
    while true; do
        print_title "客户端产物设置 (生成节点时写入)"
        echo >&2
        ui_kv_ascii "当前指纹"   "$(m_fp_get)"
        ui_kv_ascii "当前地址族" "$(m_addr_family_label)"
        ui_kv_ascii "本机 IPv4"  "$(m_addr4_real 2>/dev/null || echo '(无)')"
        ui_kv_ascii "本机 IPv6"  "$(m_addr6_real  2>/dev/null || echo '(无)')"
        m_warp_active && print_warn "检测到 WARP/隧道接口 —— 其上的地址已排除, 不会被写进产物"
        echo >&2
        _ca_show_artifact_count
        echo >&2
        ui_menu 1 "改指纹 (会同步改掉已有产物)"
        ui_menu 2 "改连接地址族 (会同步改掉已有产物)"
        ui_menu 3 "导出全部节点与订阅链接"
        ui_menu 4 "清理无对应节点的残留产物"
        ui_menu 5 "给已有节点名补地区旗帜 (重写产物与分享链接)"
        ui_menu 0 "返回"
        printf "请选择: " >&2
        local c; read -r c || return 0
        c=$(clean_input "${c:-}")
        case "$c" in
            1) _ca_pick_fp ;;
            2) _ca_pick_family ;;
            3) export_all_nodes ;;
            4) _ca_clean_orphan ;;
            5) _ca_apply_flag ;;
            0) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}

# 「给已有节点名补地区旗帜」—— 先给用户看要改什么, 确认后再写。
#
# 旗帜是给人看的（客户端列表里区分服务器/地区）, 服务端一个字节都不用动,
# 所以这是纯产物重写 + 订阅重生成, 不需要重载内核。
_ca_apply_flag() {
    print_title "给已有节点名补地区旗帜"
    local flag; flag=$(m_flag_emoji)
    if [[ -z "$flag" ]]; then
        print_warn "查不到本机归属地, 拿不到旗帜（网络不通? 或设了 M_SKIP_FLAG）"
        print_info "已有节点名保持不变, 新节点也一样会带不上旗帜"
        return 0
    fi
    ui_kv_ascii "本机旗帜" "$flag"
    echo >&2
    local n_art; n_art=$(ls "$SRV_OUT"/*_client-*.yaml 2>/dev/null | wc -l | tr -d ' ')
    (( n_art > 0 )) || { print_info "还没有客户端产物, 新节点会直接用上"; return 0; }

    local n
    n=$(m_artifacts_apply_flag 1)      # 先只报告
    if [[ "${n:-0}" == "0" ]]; then
        print_ok "现有 $n_art 个产物都已经带旗帜, 无需改动"
        return 0
    fi
    echo >&2
    printf "  要改 %s 处节点名, 同步重生成订阅。继续吗? ${DIM}[Y/n]: ${RESET}" "$n" >&2
    local a; read -r a
    case "$(clean_input "${a:-y}")" in n|N) print_info "已取消"; return 0 ;; esac
    n=$(m_artifacts_apply_flag)
    (( n > 0 )) && print_ok "已更新 $n 处节点名" || { print_warn "没有需要改的产物"; return 0; }
    _ca_regen_sub
    # 已发出去的分享链接内容也要跟着更新（token 与地址不变）
    if declare -F share_refresh_all >/dev/null 2>&1; then
        share_refresh_all >/dev/null 2>&1 && print_ok "分享链接内容已刷新"
    fi
    print_info "客户端下次更新订阅即可看到带旗帜的节点名"
}

_ca_pick_fp() {
    print_title "TLS 客户端指纹 (写进客户端产物)"
    local i=1 k cur; cur=$(m_fp_get)
    for k in "${M_UTLS_FINGERPRINTS[@]}"; do
        printf '  %s%2d%s) %-12s %s\n' "${CYAN}" "$i" "${RESET}" "$k" \
            "$( [[ "$k" == "$cur" ]] && echo "← 当前" )" >&2
        i=$((i+1))
    done
    printf '\n请选择 [默认 1]: ' >&2
    local n; read -r n; n=$(clean_input "${n:-1}")
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#M_UTLS_FINGERPRINTS[@]} )) || n=1
    local pick="${M_UTLS_FINGERPRINTS[$((n-1))]}"
    m_fp_set "$pick" || { print_error "非法指纹: $pick"; return 1; }
    print_ok "指纹已设为 $pick"
    _ca_apply_to_existing "client-fingerprint" "fp=$pick"
}

# 改完设置后问一句要不要落到已有产物上。
#
# 原来只写状态文件并注明"新生成的节点生效", 想换指纹就得把全部节点重新生成
# 一遍 —— 端口与凭据全变, 已经发出去的分享链接全部失效。而指纹只是客户端
# 表现层字段, 服务端一个字节都不用动, 所以直接重写产物就够了。
_ca_apply_to_existing() { # <改了什么, 显示用>
    local what="$1"
    local n_art; n_art=$(ls "$SRV_OUT"/*_client-*.yaml 2>/dev/null | wc -l | tr -d ' ')
    (( n_art > 0 )) || { print_info "还没有产物, 新节点会直接用上"; return 0; }
    echo >&2
    printf "  当前有 %s 个客户端产物, 要同步改掉吗? ${DIM}[Y/n]: ${RESET}" "$n_art" >&2
    local a; read -r a
    case "$(clean_input "${a:-y}")" in n|N) print_info "已保留现有产物 (以后生成的用新设置)"; return 0 ;; esac

    local n
    n=$(m_artifacts_apply_fp "$(m_fp_get)")
    (( n > 0 )) && print_ok "已更新 $n 处产物与分享链接 ($what)" \
                 || print_warn "没有需要改的产物"
    _ca_regen_sub
}

# 订阅是聚合产物, 单节点改了不重生成它就会与单节点对不上
_ca_regen_sub() {
    [[ -f "$M_LIB/build_sub.py" || -f "$M_LIB/share/build_sub.py" ]] || return 0
    local py="$M_LIB/build_sub.py"
    [[ -f "$py" ]] || py="$M_LIB/share/build_sub.py"
    python3 "$py" >/dev/null 2>&1 && print_ok "订阅已重新生成" || print_warn "订阅重新生成失败"
}

_ca_pick_family() {
    print_title "客户端产物里的连接地址"
    echo >&2
    ui_kv_ascii "IPv4" "$(m_addr4_real 2>/dev/null || echo '(本机无真实 IPv4)')"
    ui_kv_ascii "IPv6" "$(m_addr6_real  2>/dev/null || echo '(本机无真实 IPv6, 隧道地址已排除)')"
    echo >&2
    printf "  %s1%s) IPv4\n  %s2%s) IPv6\n" "${CYAN}" "${RESET}" "${CYAN}" "${RESET}" >&2
    printf '请选择 [默认 1]: ' >&2
    local n; read -r n; n=$(clean_input "${n:-1}")
    case "$n" in 2) m_addr_family_set v6 ;; *) m_addr_family_set v4 ;; esac
    if [[ "$(m_addr_family_get)" == "v6" ]] && [[ -z "$(m_addr6_real 2>/dev/null)" ]]; then
        print_warn "本机没有可用的真实 IPv6, 新节点仍会用 IPv4 地址"
    fi
    print_ok "连接地址已设为 $(m_addr_family_label)"

    # 换地址族要改产物里的 server 和分享链接里的 @host
    local want newip oldip n_art
    want=$(m_addr_family_get)
    if [[ "$want" == "v6" ]]; then newip=$(m_addr6_real 2>/dev/null); else newip=$(m_addr4_real 2>/dev/null); fi
    oldip=$(m_addr4_real 2>/dev/null)
    n_art=$(ls "$SRV_OUT"/*_client-*.yaml 2>/dev/null | wc -l | tr -d ' ')
    if [[ -n "$newip" && -n "$oldip" && "$newip" != "$oldip" && "$n_art" -gt 0 ]]; then
        echo >&2
        printf "  %d 个客户端产物当前指向 %s, 要改成 %s 吗? ${DIM}[Y/n]: ${RESET}" \
            "$n_art" "$oldip" "$newip" >&2
        local a; read -r a
        if [[ "$(clean_input "${a:-y}")" != "n" && "$(clean_input "${a:-y}")" != "N" ]]; then
            local n; n=$(m_artifacts_apply_addr "$newip" "$oldip")
            (( n > 0 )) && print_ok "已更新 $n 处产物与分享链接" || print_warn "没有需要改的产物"
            _ca_regen_sub
        else
            print_info "已保留现有产物 (以后生成的用新地址)"
        fi
    fi
}

extra_menu() {
    while true; do
        print_title "出站 / 规则集 / 端口转发"
        ui_menu 1 "出站管理 (direct/reject/socks5/http)"
        ui_menu 2 "规则集管理 (按域名/IP 分流)"
        ui_menu 3 "端口转发 (把本机端口送到目标地址)"
        ui_rule
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        local c; c=$(clean_input "$(read -r)") || return 0
        case "$c" in
            1) outbound_menu ;;
            2) ruleset_menu ;;
            3) pfwd_menu ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}

main_menu() {
    # 无感自愈: 面板启动时确认"续期后自动同步"在位。
    #
    # 为什么放这里: 从面板「更新脚本」或 install.sh 更新之后, 新代码是落盘了,
    # 但定时器可能是旧的、甚至不存在 (旧实现装的是 tools/ 下的路径)。这一句
    # 让更新过的机器**下次进面板就自动补齐**, 不需要用户知道有这回事。
    #
    # 它只在"本机确实在用 Let's Encrypt 证书"且"定时器缺失或指向旧路径"时
    # 才动手, 其余情况一个字都不输出。
    cert_sync_ensure_timer
    local c
    while true; do
        ui_rule
        printf "  ${CYAN}${BOLD}Mihomo 服务端${RESET}\n" >&2
        ui_rule
        echo >&2
        # ── 每项内联子项说明 ──
        #
        # 每个菜单项后面都跟着括号说明,
        # 例 "1. 安装 / 内核 (初始化/安装/更新/版本/卸载/脚本更新)"。
        # 进菜单前就知道里面有什么, 不用靠记忆或试错。
        #
        # 原来我们 15 项里只有 4 项有说明。
        ui_sec "节点"
        ui_menu  1 "添加节点 (单协议 · 或全协议一键生成)"
        ui_menu  2 "拉取节点 (从订阅导入)"
        ui_menu  3 "管理节点 (查看/删除/改端口)"
        echo >&2
        ui_sec "服务与内核"
        ui_menu  4 "安装 / 内核管理 (版本/更新/脚本)"
        ui_menu  5 "服务管理 (启动/停止/重启)"
        ui_menu  6 "校验配置 + 重载 (合并/字段/内核三道关)"
        echo >&2
        ui_sec "网络"
        ui_menu  7 "防火墙 (放行/孤儿清理/SSH 保护)"
        ui_menu  8 "CDN 回源 (Nginx 自动插入/证书/残留检查)"
        ui_menu  9 "DNS 管理 (解析/加密/防泄露)"
        ui_menu 10 "出站 / 规则集 / 端口转发"
        ui_menu 11 "SOCKS 入站 (自己 / 内网用)"
        echo >&2
        ui_sec "分享与分发"
        ui_menu 12 "生成分享链接 (单节点/全部)"
        ui_menu 13 "客户端产物设置 (指纹 / IP 地址)"
        ui_menu 14 "查看节点分享内容"
        echo >&2
        ui_sec "查看"
        ui_menu 15 "查看当前节点"
        ui_menu 16 "查看已拉取订阅"
        ui_menu 17 "查看日志"
        ui_menu 18 "系统信息 (端口/IP/资源)"
        echo >&2
        ui_sec "其他"
        ui_menu 19 "卸载服务端"
        ui_menu 20 "切换到客户端面板 (装/进另一端)"
        ui_menu  0 "退出"
        echo >&2
        ui_rule
        # ── 状态放菜单**下方**, 紧贴提示符 ──
        #
        # 原来 status_block 在菜单上方。SB 把它放在菜单之后、提示符之前,
        # 于是视线顺序是「菜单 → 状态 → 提示符」, 敲数字前最后一眼看的是
        # 状态 —— 服务在不在、几个节点, 每次进菜单都过一遍眼, 不用特意去
        # 看"系统信息"。
        status_block
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || { printf '\n' >&2; print_info "非交互环境 (stdin 已关闭), 已退出"; break; }
        c=$(clean_input "$c")
        case "$c" in
            1)  add_node ;;
            2)  pull_node ;;
            3)  manage_node ;;
            4)  core_menu "$SRV_ROOT" "$SRV_SERVICE" ;;
            5)  svc_menu ;;
            6)  update_config ;;
            7)  fw_menu ;;
            8)  cdn_menu ;;
            9)  dns_menu ;;
            10) extra_menu ;;
            11) socks_menu ;;
            12) install_share ;;
        13) client_artifact_menu ;;
            14) show_client_files ;;
            15) list_nodes ;;
            16) list_imported ;;
            17) log_menu ;;
            18) sys_info ;;
            19) uninstall_service ;;
            20) switch_side "$SRV_ROOT" ;;
            0|q|Q) exit 0 ;;
            *)  ui_invalid "$c" ;;
        esac
        pause
    done
}

# =============================================================
# 入口 / 子命令
#
# `init` 与 `uninstall` 是给 core_menu (src/lib/core_mgmt.sh) 调的 ——
# 那边一直写着:
#     bash "$root/src/server.sh" init
#     bash "$root/src/server.sh" uninstall
#
# 但这里以前只有 `main_menu "$@"`, 而 main_menu 从不读 $1。于是这两个
# "子命令"实际会**递归打开一个完整面板**: 调用处又带了 2>/dev/null,
# 用户什么都看不到, 子面板却会抢走 stdin —— 表现为"点了没反应, 后面
# 几个按键全乱"。core_mgmt.sh 里那个兜底的 _core_init_base 更是全项目
# 从未定义过 (git log -S 查过), 所以连报错都报不出个所以然。
#
# 现在按调用处的本意把子命令补齐 —— 调用点写的是对的, 缺的是这里。
# =============================================================
case "${1:-}" in
    init)
        # 建目录 + 用 merge.py 生成基础 config.yaml (配置生成的唯一真源)
        ensure_dirs || exit 1
        python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1 || exit 1
        exit 0 ;;
    uninstall)
        uninstall_service ;;
    *)
        main_menu "$@" ;;
esac