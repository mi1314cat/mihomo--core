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

GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; CYAN="\033[36m"
MAGENTA="\033[35m"; BLUE="\033[34m"; BOLD="\033[1m"; RESET="\033[0m"

print_info()  { printf "${CYAN}[信息]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[成功]${RESET} %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[警告]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[错误]${RESET} %s\n" "$1" >&2; }
print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}
pause() { printf "\n${CYAN}按回车继续...${RESET}"; read -r; }

ensure_dirs() { mkdir -p "$SRV_CONF" "$SRV_CONFIGD" "$SRV_CERTS" "$SRV_OUT"; }

# =============================================================
# 状态
# =============================================================
status_block() {
    local svc="未运行" ver="-" frag
    systemctl is-active --quiet "$SRV_SERVICE" && svc="${GREEN}运行中${RESET}"
    [[ -x "$SRV_BIN" ]] && ver=$("$SRV_BIN" -v 2>/dev/null | head -1)
    frag=$(ls "$SRV_CONFIGD"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
    printf "  服务: %-16s 内核: %s\n" "$svc" "$ver"
    printf "  监听配置: %-8s 节点: %-4s 分享端口: %s\n" "$frag" "$(node_count)" "${SHARE_PORT:-9443}"
    local p; p=$(ss -tlnp 2>/dev/null | grep -c "$SRV_BIN" || true)
    printf "  运行中的协议端口: %s\n" "${p:-0}"
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

add_node() {
    print_title "添加节点"
    local i
    for i in "${!PROTO_SCRIPTS[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${PROTO_LABELS[$i]}"
    done
    printf "\n请选择 [1-6]: "
    local c; read -r c
    [[ "$c" =~ ^[1-6]$ ]] || { print_error "无效选项"; return 1; }
    local script="$HERE/conf/${PROTO_SCRIPTS[$((c-1))]}"
    [[ -f "$script" ]] || { print_error "脚本缺失: $script"; return 1; }
    BASE_DIR="$SRV_ROOT" MIHOMO_BIN="$SRV_BIN" SELF_DIR="$HERE/conf" bash "$script"
}

manage_node() {
    print_title "管理节点"
    local i
    for i in "${!PROTO_SCRIPTS[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${PROTO_LABELS[$i]}"
    done
    printf "\n请选择 [1-6]: "
    local c; read -r c
    [[ "$c" =~ ^[1-6]$ ]] || { print_error "无效选项"; return 1; }
    local script="$HERE/conf/${PROTO_SCRIPTS[$((c-1))]}"
    [[ -f "$script" ]] || { print_error "脚本缺失: $script"; return 1; }
    BASE_DIR="$SRV_ROOT" MIHOMO_BIN="$SRV_BIN" SELF_DIR="$HERE/conf" bash "$script"
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
    echo "1) 实时查看运行日志 (tail -f)"
    echo "2) 查看错误日志"
    echo "3) 清空日志文件"
    echo "4) 查看内核最近 100 行"
    printf "请选择: "; local c; read -r c
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
    printf "  监听端口:\n"
    ss -tlnp 2>/dev/null | grep "$SRV_BIN" | awk '{printf "    %s\n", $4}' | sort -u
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
    cat <<'EOF'
  将删除:
    - systemd 服务并停止
    - conf/config.d 下的节点配置
  保留 (默认):
    - 证书、out/ 里的分享文件、install_info.env

  节点配置一旦删除, 对应监听端口会立即消失。
EOF
    printf '\n确认卸载? 输入 YES 继续: '; read -r a
    [[ "$a" == "YES" ]] || { print_info "已取消"; return; }

    systemctl stop "$SRV_SERVICE" 2>/dev/null
    systemctl disable "$SRV_SERVICE" 2>/dev/null
    rm -f "/etc/systemd/system/$SRV_SERVICE.service"
    systemctl daemon-reload
    print_ok "服务已移除"

    printf '\n是否同时删除全部节点配置 (conf/config.d/*.yaml)? 输入 YES: '; read -r b
    if [[ "$b" == "YES" ]]; then
        rm -f "$SRV_CONFIGD"/*.yaml
        python3 "$M_LIB/merge.py" --conf "$SRV_CONF" >/dev/null 2>&1
        print_ok "节点配置已删除"
    else
        print_info "已保留节点配置"
    fi
    print_info "如需彻底删除: rm -rf $SRV_ROOT"
}

show_logs() {
    print_title "运行日志"
    journalctl -u "$SRV_SERVICE" -n 60 --no-pager 2>/dev/null || tail -60 "$SRV_ROOT/mihomo.log" 2>/dev/null
}

svc_menu() {
    print_title "服务管理"
    echo "1) 启动   2) 停止   3) 重启   4) 状态   5) 开机自启"
    printf "请选择: "; local c; read -r c
    case "$c" in
        1) systemctl start "$SRV_SERVICE" && print_ok "已启动" ;;
        2) systemctl stop "$SRV_SERVICE" && print_ok "已停止" ;;
        3) systemctl restart "$SRV_SERVICE" && print_ok "已重启" ;;
        4) systemctl status "$SRV_SERVICE" --no-pager | head -15 ;;
        5) systemctl enable "$SRV_SERVICE" && print_ok "已设置开机自启" ;;
    esac
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
    while true; do
        print_title "Mihomo 服务端面板"
        status_block
        printf '\n'
        echo "1) 添加节点"
        echo "2) 管理节点"
        echo "3) 生成分享链接"
        echo "4) 拉取节点"
        echo "5) 更新配置"
        printf -- "----------------------------------------\n"
        echo "6) 服务管理"
        echo "7) 查看当前节点"
        echo "8) 查看已拉取订阅"
        echo "9) 查看日志"
        echo "a) 查看节点分享内容"
        echo "b) 系统信息"
        echo "c) 卸载服务端"
        printf "0) 退出\n"
        printf "\n请选择: "
        local c; read -r c
        case "$c" in
            1) add_node ;;
            2) manage_node ;;
            3) install_share ;;
            4) pull_node ;;
            5) update_config ;;
            6) svc_menu ;;
            7) list_nodes ;;
            8) list_imported ;;
            9) log_menu ;;
            a) show_client_files ;;
            b) sys_info ;;
            c) uninstall_service ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        pause
    done
}

main_menu "$@"