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
    local svc="未运行" ver="-" frag
    systemctl is-active --quiet "$SRV_SERVICE" && svc="${GREEN}运行中${RESET}"
    [[ -x "$SRV_BIN" ]] && ver=$("$SRV_BIN" -v 2>/dev/null | head -1)
    frag=$(ls "$SRV_CONFIGD"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
    printf "  服务: %-16s 内核: %s\n" >&2 "$svc" "$ver"
    printf "  监听配置: %-8s 节点: %-4s 分享端口: %s\n" >&2 "$frag" "$(node_count)" "${SHARE_PORT:-9443}"
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
        | awk '$1 >= 20000 && $1 <= 29999' | sort -un | wc -l | tr -d ' ' )
    printf "  运行中的协议端口: %s (TCP+UDP, 20000-29999)\n" >&2 "${p:-0}"
}

node_count() {
    local n=0 f
    for f in "$SRV_OUT"/*_client-*.yaml; do
        [[ -f "$f" ]] || continue
        n=$((n + $(python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1])) or {}
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
d=yaml.safe_load(open(sys.argv[1])) or {}
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
PROTO_SCRIPTS=(Reality.sh VLESS.sh Trojan.sh hysteria2.sh TUIC.sh AnyTLS.sh)
PROTO_LABELS=("Reality (VLESS+Reality)" "VLESS" "Trojan" "Hysteria2" "TUIC v5" "AnyTLS")

# 协议脚本跑完后的收口: 为本次新增的节点文件放行防火墙端口。
#
# 只碰**未登记**的端口 —— 已有的节点反复放行没意义, 而全目录无条件扫描会
# 把别的协议的端口也过一遍, 出问题时分不清是哪一步动的。
fw_after_node_change() {
    declare -F fw_open_node_file >/dev/null 2>&1 || return 0
    local nf first
    for nf in "$SRV_CONFIGD"/*.yaml; do
        [[ -f "$nf" ]] || continue
        first=$(fw_ports_in_file "$nf" | head -1)
        fw_is_registered "$first" && continue
        fw_open_node_file "$nf"
    done
}


add_node() {
    print_title "添加节点"
    local i
    for i in "${!PROTO_SCRIPTS[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${PROTO_LABELS[$i]}"
    done
    # 批量入口。
    #
    # all.sh 早就存在 (1050 行 / 13 类节点 / --dry-run --no-tls --only --fp),
    # 但一直没有菜单入口 —— 只能手动敲命令。对照 SB: 它的
    # 「节点管理 → 11) 全协议一键生成」是常驻菜单项, 而 all.sh 的批量档位
    # 设计 (--dry-run / --only) 本来就是照着这个思路做的, 却没有出口。
    printf "  %d) \033[1m全协议一键生成\033[0m (推荐先试这个)\n" "$(( ${#PROTO_SCRIPTS[@]} + 1 ))"
    printf "\n请选择 [1-%d]: " "$(( ${#PROTO_SCRIPTS[@]} + 1 ))"
    local c; read -r c
    local batch_idx=$(( ${#PROTO_SCRIPTS[@]} + 1 ))
    if [[ "$c" == "$batch_idx" ]]; then
        all_menu; return
    fi
    [[ "$c" =~ ^[1-6]$ ]] || { ui_invalid "$c"; return 1; }
    local script="$HERE/conf/${PROTO_SCRIPTS[$((c-1))]}"
    [[ -f "$script" ]] || { print_error "脚本缺失: $script"; return 1; }
    BASE_DIR="$SRV_ROOT" MIHOMO_BIN="$SRV_BIN" SELF_DIR="$HERE/conf" bash "$script"
    fw_after_node_change
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
    printf "    1) \033[36m先预览\033[0m (dry-run, 不写入任何文件)  ★推荐第一次选这个\n"
    printf "    2) 直接生成全部协议\n"
    printf "    3) 生成全部, 但不生成需要证书的协议\n"
    printf "    4) 只生成指定协议 (逐个选)\n"
    printf "    0) 返回\n"
    printf "请选择: "
    local c; read -r c
    case "$c" in
        1) _all_run --dry-run ;;
        2) _all_run ;;
        3) _all_run --no-tls ;;
        4) _all_pick ;;
        0) return ;;
        *) ui_invalid "$c" ;;
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
    for i in "${!PROTO_SCRIPTS[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${PROTO_LABELS[$i]}"
    done
    # 红字标不可逆 —— 与 SB 的菜单约定一致 (batch.sh:117 破坏性操作必须
    # 手打 yes 才执行)。这里先标出来, 执行时还有第二道确认。
    printf "  \033[31m%d) 清空全部节点\033[0m  (不可逆, 会备份后删除所有节点)\n" "$(( ${#PROTO_SCRIPTS[@]} + 1 ))"
    printf "\n请选择 [1-%d]: " "$(( ${#PROTO_SCRIPTS[@]} + 1 ))"
    local c; read -r c
    if [[ "$c" == "$(( ${#PROTO_SCRIPTS[@]} + 1 ))" ]]; then
        wipe_all_nodes; return
    fi
    [[ "$c" =~ ^[1-6]$ ]] || { ui_invalid "$c"; return 1; }
    local script="$HERE/conf/${PROTO_SCRIPTS[$((c-1))]}"
    [[ -f "$script" ]] || { print_error "脚本缺失: $script"; return 1; }
    BASE_DIR="$SRV_ROOT" MIHOMO_BIN="$SRV_BIN" SELF_DIR="$HERE/conf" bash "$script"
    fw_after_node_change
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
            "$(grep -hoE 'name: *m[A-Za-z0-9_-]+' "$f" 2>/dev/null | head -1 | sed 's/name: *//')"
    done
    printf "\n  \033[33m保留\033[0m: 证书 / out/ 客户端产物 / 服务单元 / 分享记录\n"
    printf "  \033[31m删除\033[0m: conf/config.d/*.yaml + 已发出的分享链接 (全部吊销)\n"

    # 两级确认 —— 与 SB 一致: 普通操作 [y/N], 破坏性必须手打 yes
    local a
    printf "\n请输入 \033[1myes\033[0m 确认清空 (其它任何输入都取消): "
    read -r a || { print_info "已取消"; return; }
    [[ "$a" == "yes" ]] || { print_info "已取消 (需要输入 yes 才会执行)"; return; }

    # 先备份 —— 清空是不可逆的, 出问题要能捞回来
    local bak="$SRV_ROOT/nodes.bak.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bak" || { print_error "备份目录创建失败, 已中止"; return 1; }
    cp -a "$SRV_CONFIGD"/*.yaml "$bak"/ 2>/dev/null
    print_ok "已备份 $n 个节点到: $bak"

    rm -f "$SRV_CONFIGD"/*.yaml

    # 重新合并 + 校验。**顺序很重要**: token 吊销放在校验通过之后 ——
    # 否则一旦校验失败回滚了配置, token 却已经吊销, 用户手里的链接
    # 莫名其妙全废了。
    #
    # 校验不过就把备份捞回来 —— 宁可停在旧状态, 也不要留一个跑不起来的服务。
    if ! python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1; then
        print_error "配置合并失败, 正在回滚"
        cp -a "$bak"/*.yaml "$SRV_CONFIGD"/ 2>/dev/null
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
        python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1
        systemctl restart "$SRV_SERVICE" 2>/dev/null
        print_ok "已回滚到清空前的状态"
        return 1
    fi

    # 到这一步才算真的清成功, 此时才吊销 token。
    # 节点都没了, 链接留着只会让客户端反复去拉、拉回来一份空配置。
    local revoked=0
    if [[ -d "$SRV_ROOT/share/shares" ]]; then
        local t
        for t in "$SRV_ROOT/share/shares"/*.json; do
            [[ -f "$t" ]] || continue
            python3 -c '
import json,sys
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: sys.exit(0)
d["enabled"]=False
json.dump(d,open(p,"w"),ensure_ascii=False)
' "$t" 2>/dev/null && revoked=$((revoked+1))
        done
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
d=yaml.safe_load(open(sys.argv[1])) or {}
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
    print_title "更新配置"
    ensure_dirs
    print_info "1/3 合并 conf/config.d → conf/config.yaml"
    python3 "$M_LIB/merge.py" --conf "$SRV_CONF" || {
        print_error "合并失败"; return 1; }

    print_info "2/3 严格字段校验"
    if ! python3 "$M_LIB/validate.py" --conf "$SRV_CONF"; then
        print_error "字段校验未通过, 配置未生效"; return 1; fi

    print_info "3/3 内核校验 (mihomo -t)"
    "$SRV_BIN" -t -d "$SRV_CONF" >/tmp/mihomo_t.log 2>&1 || {
        tail -8 /tmp/mihomo_t.log >&2
        print_error "内核校验失败, 配置未生效"; return 1; }
    print_ok "全部校验通过"

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
        printf "  Mihomo  : %s\n" "$("$SRV_BIN" -v 2>/dev/null | head -1)"
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
        ufw status 2>/dev/null | head -6 | sed 's/^/    /'
    else
        printf "    (未检测到 firewall-cmd / ufw)\n"
    fi
}

uninstall_service() {
    print_title "卸载 Mihomo 服务端"
    # 与客户端同理由: SRV_ROOT 可被环境变量改掉, 这时这两个服务名可能属于
    # 别的 mihomo 实例。unit 文件里写了 ExecStart 路径, 对不上就不碰。
    local svc="$SRV_SERVICE" shsvc="$SHARE_SERVICE"
    _srv_unit_owned_by_me "$svc"   || { svc="";   print_warn "$SRV_SERVICE 的 unit 不属于 $SRV_ROOT, 不会删除"; }
    _srv_unit_owned_by_me "$shsvc" || { shsvc=""; print_warn "$SHARE_SERVICE 的 unit 不属于 $SRV_ROOT, 不会删除"; }
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
           rm -f "$SRV_CONFIGD"/*.yaml
           python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1 || true
           print_ok "节点配置已删除"
           print_info "证书/out/分享记录已保留在 $SRV_ROOT" ;;
        3) _uninstall_all "$svc" "$shsvc" ;;
        "") print_info "已取消" ;;
        *)  ui_invalid "$c" ;;
    esac
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
    [[ -n "$shsvc" ]] || shsvc=$(_srv_unit_owned_by_me "$SHARE_SERVICE" && echo "$SHARE_SERVICE")
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
        4) systemctl status "$SRV_SERVICE" --no-pager | head -15 ;;
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
            inner=$(unzip -Z1 "$f" 2>/dev/null | grep -E '(^|/)mihomo$' | head -1)
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
        ver=$("$probe" -v 2>/dev/null | head -1)
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
main_menu() {
    local c
    while true; do
        print_title "Mihomo 服务端面板"
        status_block
        echo >&2
        ui_menu 1  "添加节点"
        ui_menu 2  "管理节点"
        ui_menu 3  "安装 / 内核管理 (版本/更新/脚本)"
        ui_menu 4  "防火墙 (放行/孤儿清理/SSH 保护)"
        ui_rule
        ui_menu 5  "生成分享链接"
        ui_menu 6  "拉取节点"
        ui_menu 7  "更新配置"
        ui_menu 8  "服务管理"
        ui_menu 9  "查看当前节点"
        ui_menu 10 "查看已拉取订阅"
        ui_menu 11 "查看日志"
        ui_menu 12 "查看节点分享内容"
        ui_menu 13 "系统信息"
        ui_menu 14 "卸载服务端"
        ui_menu 15 "切换到客户端面板 (装/进另一端)"
        ui_menu 0  "退出"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || { printf '\n' >&2; print_info "非交互环境 (stdin 已关闭), 已退出"; break; }
        c=$(clean_input "$c")
        case "$c" in
            1)  add_node ;;
            2)  manage_node ;;
            3)  core_menu "$SRV_ROOT" "$SRV_SERVICE" ;;
            4)  fw_menu ;;
            5)  install_share ;;
            6)  pull_node ;;
            7)  update_config ;;
            8)  svc_menu ;;
            9)  list_nodes ;;
            10) list_imported ;;
            11) log_menu ;;
            12) show_client_files ;;
            13) sys_info ;;
            14) uninstall_service ;;
            15) switch_side "$SRV_ROOT" ;;
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