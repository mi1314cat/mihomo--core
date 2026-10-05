#!/usr/bin/env bash
# =============================================================
# 分享链接管理 (share)
#
#   节点 → 生成 token → TTL / max_uses → 客户端拉取 → 自动导入
#
# 数据格式为 Mihomo 原生的 `proxies:` YAML,
# 客户端可直接作为 proxy-provider 消费, 无需任何转换器。
# =============================================================

# 允许独立 source: 这里把依赖的路径全部自给自足,
# 否则被父级以非默认路径调用时会写出 OUT_DIR= / MIHOMO_SERVICE= 的空环境变量,
# 服务能启动但永远返回 503。
: "${SRV_ROOT:=/root/catmi/mihomo}"
: "${SRV_OUT:=$SRV_ROOT/out}"
: "${SRV_SERVICE:=mihomo}"
: "${SRV_CONF:=$SRV_ROOT/conf}"
: "${SRV_ENV:=$SRV_ROOT/install_info.env}"
: "${SHARE_DIR:=$SRV_ROOT/share}"
: "${SHARE_PORT:=9443}"
: "${SHARE_SERVICE:=mihomo-share}"

# 自身目录 —— 被父级 source 时 SELF_SHARE_DIR 可能为空,
# 导致 systemd 的 ExecStart 变成 "/share_server.py"。
SH_SHARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# 从 /tmp 之类的临时副本 source 时, 上面的推导会指向那个副本,
# 于是装出来的 unit 里 ExecStart 指向一个下次重启就不存在的文件。
# 所以先验一下 share_server.py 是不是真在这儿, 不是就退回安装目录。
if [[ ! -f "$SH_SHARE_DIR/share_server.py" ]]; then
    for cand in "${SRV_ROOT:-}/src/share" "${SRV_ROOT:-}/share"; do
        [[ -n "$cand" && -f "$cand/share_server.py" ]] && { SH_SHARE_DIR="$cand"; break; }
    done
fi

if ! declare -F m_get_env >/dev/null 2>&1; then
    ENVTOOL="${ENVTOOL:-$(dirname "$SH_SHARE_DIR")/lib/envtool.py}"
    m_get_env() { python3 "$ENVTOOL" get "$1" "$2"; }
fi
: "${BUILD_SUB:=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/build_sub.py}"

SHARES="$SHARE_DIR/shares"

# 允许单独 source (不经过 server.sh)。父级已定义时不覆盖, 保持父级配色。
if ! declare -F print_info >/dev/null 2>&1; then
    GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"
    CYAN="\033[36m"; MAGENTA="\033[35m"; BOLD="\033[1m"; RESET="\033[0m"
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
fi

# ---------- 小工具 ----------
# 取本机对外地址。
# 注意: 很多机器开着透明代理 (tproxy/redirect), 连 --noproxy 都绕不出去,
# api.ipify 会返回**代理出口 IP**而不是服务器自己的 IP —— 那样生成的
# 分享链接客户端根本连不上。所以优先级是:
#   1) install_info.env 里管理员自己填的 PUBLIC_IP / link_ip (最可靠)
#   2) 直连 IPv6 (通常不受 IPv4 透明代理影响)
#   3) 最后才用 ipify, 并明确提示可能是出口 IP
# 另外无论如何都会让用户确认一次。
_share_addr() {
    local a=""

    if [[ -n "${SRV_ENV:-}" && -f "${SRV_ENV:-}" ]]; then
        a=$(m_get_env "$SRV_ENV" PUBLIC_IP 2>/dev/null) || a=""
        [[ -z "$a" ]] && a=$(m_get_env "$SRV_ENV" link_ip 2>/dev/null) || a=""
        [[ -n "$a" ]] && { printf "%s" "$a"; return; }
    fi

    a=$(curl -s6 --max-time 6 https://api64.ipify.org 2>/dev/null)
    [[ -n "$a" ]] && { printf "%s" "$a"; return; }

    a=$(curl -s4 --max-time 6 https://api.ipify.org 2>/dev/null)
    printf "%s" "$a"
}

# IPv6 字面量必须写成 [addr], 否则 http://2a09::1:9443/ 解析不出来
_share_host() {
    local h="${1:-}"
    [[ -n "$h" ]] || return 0
    case "$h" in
        *:*) printf '[%s]' "$h" ;;
        *)   printf '%s' "$h" ;;
    esac
}

_share_status() {   # 输出 中文状态
    local meta="$1" now
    now=$(date +%s)
    if [[ "$(printf '%s' "$meta" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("enabled",True))' 2>/dev/null)" != "True" ]]; then
        printf "已禁用"; return
    fi
    local exp used maxu
    exp=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("expires_at",0)))' 2>/dev/null)
    used=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("used_count",0)))' 2>/dev/null)
    maxu=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("max_uses",0)))' 2>/dev/null)
    if [[ "$exp" != "0" && "$now" -gt "$exp" ]]; then printf "已过期"; return; fi
    if [[ "$maxu" != "0" && "$used" -ge "$maxu" ]]; then printf "已用尽"; return; fi
    printf "可用"
}

_share_expiry_str() {
    local exp
    exp=$(printf '%s' "$1" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("expires_at",0)))' 2>/dev/null)
    if [[ "$exp" == "0" ]]; then printf "永久"; return; fi
    date -d "@$exp" '+%Y-%m-%d %H:%M' 2>/dev/null || printf "?"
}

# ---------- 生成 ----------
share_create() {
    print_title "生成分享链接"

    # 选节点范围
    printf "\n分享哪些节点?\n"
    printf "  1) 全部节点 (all)\n"
    local i=2 tagname
    local tags; tags=$(python3 "$BUILD_SUB" --out-dir "$SRV_OUT" --list 2>/dev/null | awk 'NF==2 && $1!="合计"{print $1}')
    for tagname in $tags; do
        printf "  %d) 仅 %s\n" "$i" "$tagname"; i=$((i+1))
    done
    printf "\n请选择 [默认 1]: "
    local c; read -r c; c="${c:-1}"

    local TAG="all"
    if [[ "$c" =~ ^[0-9]+$ && "$c" -gt 1 ]]; then
        local idx=2 pick=0
        for tagname in $tags; do
            if [[ "$idx" -eq "$c" ]]; then pick="$tagname"; break; fi
            idx=$((idx+1))
        done
        [[ -n "$pick" ]] && TAG="$pick"
    fi

    # max_uses
    printf "\n最多可拉取次数 (0=不限, 回车=1): "
    local mu; read -r mu; mu="${mu:-1}"
    [[ "$mu" =~ ^[0-9]+$ ]] || { print_error "必须是非负整数"; return 1; }

    # TTL
    printf "\n有效期:\n"
    printf "  1) 1 小时\n  2) 24 小时 (默认)\n  3) 7 天\n  4) 30 天\n  5) 永久\n  6) 自定义小时\n"
    printf "请选择 [默认 2]: "
    local t; read -r t; t="${t:-2}"
    local hours
    case "$t" in
        1) hours=1 ;; 2) hours=24 ;; 3) hours=168 ;; 4) hours=720 ;;
        5) hours=0 ;;
        6) printf "请输入小时数 (0=永久): "; read -r hours; hours="${hours:-24}" ;;
        *) hours=24 ;;
    esac
    [[ "$hours" =~ ^[0-9]+$ ]] || { print_error "必须是非负整数"; return 1; }

    local token expires now
    now=$(date +%s)
    expires=0; [[ "$hours" -gt 0 ]] && expires=$((now + hours * 3600))
    token=$(openssl rand -hex 16)

    # 地址一定要人工确认: 透明代理环境下自动探测经常拿到的是代理出口 IP
    local addr; addr=$(_share_addr)
    printf '\n分享服务对外地址: \033[1m%s\033[0m\n' "$addr"
    printf '若不对 (例如探测到了代理出口 IP), 请直接输入正确地址; 回车表示使用上面的:\n请输入: '
    local a2; read -r a2
    [[ -n "$a2" ]] && addr="$a2"

    mkdir -p "$SHARES"
    python3 - "$SHARES/$token.json" "$token" "$TAG" "$mu" "$expires" <<'PY'
import json, os, sys, time
path, token, tag, maxu, exp = sys.argv[1:6]
meta = {"share_token": token, "tag": tag, "created_at": int(time.time()),
        "expires_at": int(exp), "max_uses": int(maxu), "used_count": 0,
        "enabled": True, "last_used_at": 0}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=1)
PY

    printf '%s' "$addr" > "$SRV_OUT/share_addr.txt"
    printf 'http://%s:%s/share/%s\n' "$(_share_host "$addr")" "$SHARE_PORT" "$token" > "$SRV_OUT/share_tag-$TAG.txt"

    print_ok "已生成分享链接"
    printf '  地址    : %s\n' "$addr"
    printf '  节点范围: %s\n' "$TAG"
    printf '  次数    : %s\n' "$([[ "$mu" == "0" ]] && echo '不限' || echo "$mu")"
    printf '  有效期至: %s\n' "$([[ "$expires" == "0" ]] && echo '永久' || date -d "@$expires" '+%Y-%m-%d %H:%M')"
    printf '\n  链接:\n    \033[1mhttp://%s:%s/share/%s\033[0m\n\n' "$(_share_host "$addr")" "$SHARE_PORT" "$token"

    if [[ "$TAG" == "all" ]] && python3 - "$SRV_OUT" <<'PY' 2>/dev/null | grep -q yes; then
import glob, sys, yaml
for f in glob.glob(sys.argv[1] + "/*_client-*.yaml"):
    try:
        for p in (yaml.safe_load(open(f)) or {}).get("proxies") or []:
            if isinstance(p, dict) and (p.get("private-key") or "").strip():
                print("yes"); raise SystemExit
    except SystemExit:
        raise
    except Exception:
        pass
PY
        print_warn "注意: 订阅里包含 mTLS 客户端私钥, 请勿使用永久 / 不限次数的链接"
    fi
}

# ---------- 列表 ----------
share_list() {
    print_title "分享链接列表"
    [[ -d "$SHARES" ]] || { print_info "还没有任何分享链接"; return; }
    shopt -s nullglob
    local files=("$SHARES"/*.json)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then print_info "还没有任何分享链接"; return; fi

    printf '\n%-4s %-12s %-34s %-8s %-10s %-18s\n' "编号" "节点" "Token" "状态" "已用/上限" "过期时间"
    printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"
    local i=1 f meta
    for f in $(printf '%s\n' "${files[@]}" | sort); do
        meta=$(cat "$f" 2>/dev/null) || continue
        local tag tok st used maxu exp
        tag=$(printf '%s' "$meta"  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag","?"))' 2>/dev/null)
        tok=$(printf '%s' "$meta"  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("share_token","?"))' 2>/dev/null)
        used=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("used_count",0)))' 2>/dev/null)
        maxu=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("max_uses",0)))' 2>/dev/null)
        st=$(_share_status "$meta")
        [[ "$st" == "可用" ]] && st="${GREEN}可用${RESET}" || st="${YELLOW}${st}${RESET}"
        printf '%-4s %-12s %-34s %-18b %-10s %-18s\n' \
            "$i" "$tag" "$tok" "$st" \
            "$used/$([[ "$maxu" == "0" ]] && echo ∞ || echo "$maxu")" \
            "$(_share_expiry_str "$meta")"
        i=$((i+1))
    done
    printf '\n'
}

_share_pick() {
    share_list
    printf '请输入编号 [回车取消]: '
    local n; read -r n
    [[ -n "$n" && "$n" =~ ^[0-9]+$ ]] || { print_info "已取消"; return 1; }
    shopt -s nullglob
    local files=("$SHARES"/*.json)
    shopt -u nullglob
    (( n >= 1 && n <= ${#files[@]} )) || { print_error "编号不存在"; return 1; }
    printf '%s' "${files[$((n-1))]}"
}

# ---------- 操作 ----------
share_delete() {
    print_title "删除分享链接"
    local f; f=$(_share_pick) || return
    rm -f "$f"
    print_ok "已删除"
}

share_toggle() {
    print_title "启用 / 禁用分享链接"
    local f; f=$(_share_pick) || return
    python3 - "$f" <<'PY'
import json, os, sys
p = sys.argv[1]
m = json.load(open(p))
m["enabled"] = not m.get("enabled", True)
with open(p, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=1)
print("已启用" if m["enabled"] else "已禁用")
PY
}

share_regen() {
    print_title "重新生成 Token"
    local f; f=$(_share_pick) || return
    local old; old=$(basename "$f" .json)
    printf '重新生成后旧链接立即失效 (404)。确认? (y/N): '
    local c; read -r c
    [[ "$c" =~ ^[yY]$ ]] || { print_info "已取消"; return; }
    local new; new=$(openssl rand -hex 16)
    mv -f "$f" "$SHARES/$new.json"
    python3 - "$SHARES/$new.json" "$new" <<'PY'
import json, sys
p, tok = sys.argv[1], sys.argv[2]
m = json.load(open(p))
m["share_token"] = tok
with open(p, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=1)
PY
    print_ok "已重新生成"
    printf '  旧: %s\n  新: %s\n' "$old" "$new"
}

share_show_url() {
    print_title "查看分享链接"
    local f; f=$(_share_pick) || return
    local tag addr
    tag=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("tag","all"))' "$f")
    addr=$(_share_addr)
    local tok; tok=$(basename "$f" .json)
    printf '\n  自动探测地址: %s\n' "$addr"
    printf '若不对请输入正确地址, 回车使用上面: '
    local a2; read -r a2
    [[ -n "$a2" ]] && addr="$a2"
    printf '\n  http://%s:%s/share/%s\n\n' "$(_share_host "$addr")" "$SHARE_PORT" "$tok"
    printf '  客户端: 把这行填进「添加节点 → 分享链接」即可\n\n'
}

# ---------- 服务 ----------
share_service_status() {
    local st
    st=$(systemctl is-active "$SHARE_SERVICE" 2>/dev/null)
    if [[ "$st" == "active" ]]; then
        printf '  %s运行中%s  端口 %s\n' "$GREEN" "$RESET" "$SHARE_PORT"
    else
        printf '  %s未运行%s  (分享链接暂时无法访问)\n' "$YELLOW" "$RESET"
    fi
}

share_service_install() {
    print_title "安装分享服务"
    local unit="/etc/systemd/system/$SHARE_SERVICE.service"
    cat > "$unit" <<EOF
[Unit]
Description=Mihomo Share Service (token/TTL/max_uses)
After=network-online.target $SRV_SERVICE.service
Wants=network-online.target

[Service]
Type=simple
Environment=SHARE_DIR=$SHARE_DIR
Environment=SHARE_PORT=$SHARE_PORT
Environment=OUT_DIR=$SRV_OUT
Environment=BUILD_SUB=$BUILD_SUB
Environment=MIHOMO_SERVICE=$SRV_SERVICE
ExecStart=/usr/bin/python3 ${SELF_SHARE_DIR:-$SH_SHARE_DIR}/share_server.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SHARE_SERVICE" >/dev/null 2>&1

    # 先停掉旧实例并清掉可能残留的手工进程, 否则会
    # "Address already in use" 反复重启
    systemctl stop "$SHARE_SERVICE" 2>/dev/null
    for pid in $(pgrep -f "[s]hare_server.py" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
    sleep 1

    systemctl restart "$SHARE_SERVICE" && print_ok "分享服务已启动" || print_error "启动失败"
    sleep 1
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SHARE_PORT/status" 2>/dev/null)
    [[ "$code" == "200" ]] && print_ok "健康检查通过" || print_warn "健康检查未通过 (HTTP $code)"

    # 防火墙提示 (不擅自改防火墙, 只提示)
    printf '\n'
    # 注意: print_info 只接收一个参数, 带占位符要用 printf 直接输出
    printf "  %s[信息]%s 若外部访问不通, 请放行端口:\n" "$CYAN" "$RESET" >&2
    printf "    firewall-cmd --add-port=%s/tcp --permanent && firewall-cmd --reload\n" "$SHARE_PORT" >&2
    printf "    或 ufw allow %s/tcp\n" "$SHARE_PORT" >&2
}

share_service_restart() {
    systemctl restart "$SHARE_SERVICE" && print_ok "已重启" || print_error "重启失败"
}

share_service_stop() {
    systemctl stop "$SHARE_SERVICE" && print_ok "已停止" || print_warn "停止失败"
}

# ---------- 菜单 ----------
share_menu() {
    while true; do
        print_title "分享链接管理"
        share_service_status
        printf '\n'
        echo "1) 生成分享链接"
        echo "2) 查看全部分享链接"
        echo "3) 查看链接地址"
        echo "4) 禁用 / 启用"
        echo "5) 重新生成 Token"
        echo "6) 删除分享链接"
        echo "7) 安装 / 启用分享服务"
        echo "8) 重启分享服务"
        echo "9) 停止分享服务"
        echo "0) 返回"
        printf "\n请选择 [0-9]: "
        local c; read -r c
        case "$c" in
            1) share_create ;;
            2) share_list ;;
            3) share_show_url ;;
            4) share_toggle ;;
            5) share_regen ;;
            6) share_delete ;;
            7) share_service_install ;;
            8) share_service_restart ;;
            9) share_service_stop ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        printf "\n按回车继续..."; read -r
    done
}

# 直接执行时进入菜单
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source "$(dirname "$SH_SHARE_DIR")/lib/env.sh"
    share_menu
fi