#!/usr/bin/env bash
# =============================================================
# dns.sh —— 服务端 DNS 管理
#
# 为什么要有这一块:
#   服务端此前**完全没有 dns 段**。config.yaml 由 merge.py 生成, 它只合并
#   listeners, 其余键原样保留 —— 保留的前提是"有人先写进去", 而没有任何
#   菜单能写。于是内核只能用内置默认解析: 明文、无 fallback、域名解析结果
#   不可控。这既是最容易出问题的地方 (解析不了 = 全机节点连不上上游), 也是
#   当前服务端最大的功能空洞。
#
# 设计原则:
#   * **默认安全**: 一键套用的模板里, listen 只绑回环、ipv6 关闭、主解析全部
#     加密、fallback 惰性查询 (fallback-lazy-query) —— 这几条是踩过泄露链路
#     之后定下来的, 不能因为"做成可配"就丢掉。
#   * **改错不能把机器弄死**: 每次写盘都走 m_sync_reload 的三道关
#     (merge → validate.py → mihomo -t), 任何一道不过就自动回滚成旧配置。
#   * 服务端**不用 fake-ip**: fake-ip 是给本地设备流量用的, 服务端只解析
#     自己的出站域名, 用 fake-ip 会让上游地址变成 198.18.x.x 而直接连不上。
#
# 依赖: src/lib/dns_edit.py (结构化 YAML 编辑), m_sync_reload (src/lib/env.sh)
# =============================================================

# ---------- 内部 ----------

_dns_py() { printf '%s/dns_edit.py' "$M_LIB"; }

dns_available() {
    [[ -f "$SRV_CONF/config.yaml" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    [[ -f "$(_dns_py)" ]] || return 1
    return 0
}

# 读当前 dns 段 (JSON)。没有 dns 段时输出 {}。
dns_read() {
    python3 "$(_dns_py)" --conf "$SRV_CONF" --get 2>/dev/null || printf '{}'
}

# 写 dns 段并重载。$1 = JSON。
#
# 失败时 m_sync_reload 会把 config.yaml 恢复成改动前的内容, 所以这里不需要
# 自己再回滚 —— 两处都做反而容易出现"回滚回滚了别人"的竞态。
dns_write() {
    local json="${1:-}"
    [[ -n "$json" ]] || { print_error "内部错误: 空配置"; return 1; }

    if ! python3 "$(_dns_py)" --conf "$SRV_CONF" --set-json "$json" >/dev/null 2>&1; then
        print_error "写入 DNS 配置失败 (config.yaml 未改动)"
        return 1
    fi

    if ! m_sync_reload quiet; then
        print_error "DNS 配置未通过校验, 已自动回滚 —— 服务仍在用旧配置运行"
        print_info "回滚后当前 DNS: $(dns_read | tr -d '\n' | cut -c1-120)"
        return 1
    fi
    print_ok "DNS 配置已生效"
    return 0
}

# 把一段用户输入拆成列表。接受逗号/空格分隔。
_dns_split() {
    printf '%s' "$1" | tr ',;' '  ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

# 校验一条 nameserver 写法。返回 0 = 合法。
#   明文 IPv4 / IPv6       223.5.5.5
#   DoH                    https://dns.alidns.com/dns-query
#   DoT                    tls://dns.google
#   可选 #策略后缀          https://dns.alidns.com/dns-query#PROXY
_dns_valid_ns() {
    local s="${1:-}"
    [[ -n "$s" ]] || return 1
    case "$s" in
        https://*|http://*|tls://*|quic://*|dhcp://*) return 0 ;;
        *://*) return 1 ;;                       # 其它协议一律拒
    esac
    # 纯地址形态: 只允许 IPv4/IPv6/端口
    [[ "$s" =~ ^[0-9a-fA-F:.]+$ ]] && return 0
    return 1
}

# 交互式收一串 nameserver, 逐个校验。结果写进全局 _DNS_LIST。
_dns_ask_ns_list() {
    local prompt="$1" def="${2:-}" raw item
    _DNS_LIST=()
    raw=$(safe_read "$prompt" "$def")
    raw=$(clean_input "$raw")
    [[ -n "$raw" ]] || return 1
    local bad=""
    while read -r item; do
        [[ -n "$item" ]] || continue
        if _dns_valid_ns "$item"; then
            _DNS_LIST+=("$item")
        else
            bad="$item"
        fi
    done < <(_dns_split "$raw" | tr ' ' '\n')
    if [[ -n "$bad" ]]; then
        print_error "不认识的地址写法: $bad"
        print_info "支持: 223.5.5.5 / https://.../dns-query / tls://dns.google (可加 #PROXY)"
        return 1
    fi
    (( ${#_DNS_LIST[@]} > 0 )) || return 1
    return 0
}

# ---------- 展示 ----------

dns_show() {
    print_title "当前 DNS 配置"
    if ! dns_available; then
        print_warn "还没有 config.yaml 或缺少 dns_edit.py, 无法读取"
        return 1
    fi
    local json; json=$(dns_read)
    if [[ "$json" == "{}" ]]; then
        print_warn "当前**没有 dns 段** —— 内核在用内置默认解析"
        print_info "内置默认是明文解析且不可控, 建议套用安全默认"
        return 0
    fi
    python3 - "$json" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("  (解析失败)"); raise SystemExit
def show(k, label, note=""):
    if k in d:
        v = d[k]
        if isinstance(v, list):
            v = " ".join(str(x) for x in v)
        elif isinstance(v, dict):
            v = json.dumps(v, ensure_ascii=False)
        print(f"  {label:<22} {v}  {note}")
show("enable",       "启用",            "")
show("listen",       "监听",            "只绑回环最安全")
show("ipv6",         "IPv6 解析",       "关掉可避免拿到无路由的 v6")
show("enhanced-mode","模式",            "服务端建议 normal (非 fake-ip)")
show("default-nameserver", "引导解析",  "明文, 代理起来之前用")
show("nameserver",   "主解析",          "建议全部加密")
show("proxy-server-nameserver", "节点域名解析", "必须直连, 否则死循环")
show("fallback",     "境外解析",        "")
show("fallback-lazy-query", "惰性查询", "true 才不会被并发双发")
show("fallback-filter", "境外判定",     "")
show("nameserver-policy", "域名策略",   "把域名解析钉死, 防泄露")
show("respect-rules","DNS 走路由规则",  "需要先有 rules 段")
show("cache-algorithm", "缓存算法",     "")
show("cache-max-size",  "缓存条数",     "")
PY
}

# ---------- 安全默认模板 ----------

# 服务端安全默认。逐条都是踩过的坑, 注释写在 JSON 上方的说明里。
dns_preset_safe() {
    cat <<'JSON'
{
  "enable": true,
  "listen": "127.0.0.1:1053",
  "ipv6": false,
  "use-hosts": true,
  "use-system-hosts": true,
  "enhanced-mode": "normal",
  "default-nameserver": ["223.5.5.5", "119.29.29.29"],
  "nameserver": ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"],
  "proxy-server-nameserver": ["https://dns.alidns.com/dns-query"],
  "fallback": ["https://1.0.0.1/dns-query", "tls://dns.google"],
  "fallback-lazy-query": true,
  "fallback-filter": {"geoip": true, "geoip-code": "CN"},
  "cache-algorithm": "arc",
  "cache-max-size": 4096
}
JSON
}

# 客户端安全默认 (2026-10-07 新增)
#
# 与服务端的差别不是"随便换一套", 而是**客户端才需要的四样东西**:
#   1. fake-ip —— 客户端拿到的应该是 198.18.x.x 假地址, 真实 IP 只在 mihomo
#      内部使用。没有它, 应用层拿到真实 IP 就可能绕过代理 (QUIC、STUN 打洞
#      尤其明显)。
#   2. fake-ip-filter —— **没有它 fake-ip 会坏事**, 而且症状极具误导性:
#      QUIC/STUN 打洞失败、NTP 校时卡住、iCloud 中继连不上。用户看到这些
#      第一反应是"关掉 fake-ip", 于是反而引入了真实 DNS 泄露。
#      这是本模板里最不能省的一行。
#   3. nameserver / fallback 带 #PROXY —— 让 DNS 流量自己走代理。
#      不带的话加密 DNS 是**直连**出去的, 等于换了个协议的泄露。
#   4. proxy-server-nameserver —— 解析代理节点自身域名必须**直连**,
#      否则第一次启动时还没有可用链路, 会死循环。
#
# listen 跟随 bind 地址 (不是硬编码 0.0.0.0): 开了局域网访问时 DNS 口跟着
# 对外开是合理的 (给局域网设备用), 但**默认不开放**。
dns_preset_client() {
    cat <<'JSON'
{
  "enable": true,
  "listen": "127.0.0.1:1053",
  "ipv6": false,
  "use-hosts": true,
  "enhanced-mode": "fake-ip",
  "fake-ip-range": "198.18.0.1/16",
  "fake-ip-filter": [
    "*.lan", "localhost", "*.local", "+.msftconnecttest.com",
    "+.stun.*", "+.stun.*.*", "time.*", "+.pool.ntp.org",
    "+.apple.com", "+.icloud.com", "+.icloud-content.com"
  ],
  "default-nameserver": ["223.5.5.5", "119.29.29.29"],
  "nameserver": ["https://dns.alidns.com/dns-query#PROXY",
                 "https://doh.pub/dns-query#PROXY"],
  "proxy-server-nameserver": ["https://dns.alidns.com/dns-query"],
  "fallback": ["https://1.0.0.1/dns-query#PROXY", "tls://dns.google#PROXY"],
  "fallback-lazy-query": true,
  "fallback-filter": {"geoip": true, "geoip-code": "CN"},
  "respect-rules": true,
  "cache-algorithm": "arc",
  "cache-max-size": 4096
}
JSON
}

# 套用哪一个: DNS_MODE=client 时用客户端模板。
# 不用"看有没有 CLI_CONF"来判断 —— 分享功能也会 export SRV_CONF,
# 那时候我们仍然在服务端上下文里。
_dns_preset_pick() {
    case "${DNS_MODE:-server}" in
        client) dns_preset_client ;;
        *)      dns_preset_safe ;;
    esac
}

_dns_apply_preset() {
    print_info "将套用安全默认:"
    printf "     %b·%b listen 只绑 127.0.0.1:1053 (不做开放解析器)\n" "${DIM:-}" "${RESET:-}" >&2
    printf "     %b·%b 关闭 IPv6 解析 (避免拿到没有出口的 v6 地址)\n" "${DIM:-}" "${RESET:-}" >&2
    printf "     %b·%b 主解析全部加密 (DoH), 引导解析走明文\n" "${DIM:-}" "${RESET:-}" >&2
    printf "     %b·%b fallback 惰性查询 (不被并发双发, 减少泄露面)\n" "${DIM:-}" "${RESET:-}" >&2
    printf "     %b·%b 不用 fake-ip —— 服务端用了会让上游变成 198.18.x.x\n" "${DIM:-}" "${RESET:-}" >&2
    printf "继续? [Y/n]: "
    local a; read -r a
    case "$(clean_input "${a:-}")" in
        n|N|no|NO) print_info "已取消"; return 0 ;;
    esac
    if [[ "${DNS_MODE:-server}" == "client" ]]; then
        printf "     %b·%b fake-ip + fake-ip-filter (后者不能省, 否则 QUIC/STUN/NTP 会坏)\n" "${DIM:-}" "${RESET:-}" >&2
        printf "     %b·%b nameserver/fallback 带 #PROXY —— DNS 自己也走代理, 不直连泄露\n" "${DIM:-}" "${RESET:-}" >&2
        printf "     %b·%b proxy-server-nameserver 直连解析节点域名, 避免首次启动死循环\n" "${DIM:-}" "${RESET:-}" >&2
    fi
    dns_write "$(_dns_preset_pick | tr -d '\n')"
}

# ---------- 单项设置 ----------

_dns_set_nameserver() {
    local json; json=$(dns_read)
    _dns_ask_ns_list "主解析地址 (逗号分隔)" "https://dns.alidns.com/dns-query" || return 1
    json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); d["nameserver"]=json.loads(sys.argv[2]); print(json.dumps(d,ensure_ascii=False))
' "$json" "$(printf '%s\n' "${_DNS_LIST[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')") || return 1
    dns_write "$json"
}

_dns_set_default_ns() {
    local json; json=$(dns_read)
    _dns_ask_ns_list "引导解析地址 (明文, 逗号分隔)" "223.5.5.5, 119.29.29.29" || return 1
    json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); d["default-nameserver"]=json.loads(sys.argv[2]); print(json.dumps(d,ensure_ascii=False))
' "$json" "$(printf '%s\n' "${_DNS_LIST[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')") || return 1
    dns_write "$json"
}

_dns_set_fallback() {
    local json; json=$(dns_read)
    _dns_ask_ns_list "境外解析地址 (逗号分隔, 回车=清空)" "" || {
        print_info "已取消"; return 0
    }
    json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); d["fallback"]=json.loads(sys.argv[2]); print(json.dumps(d,ensure_ascii=False))
' "$json" "$(printf '%s\n' "${_DNS_LIST[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')") || return 1
    dns_write "$json"
}

_dns_toggle_fakeip() {
    local json; json=$(dns_read)
    local cur; cur=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); print(d.get("enhanced-mode","normal"))
' "$json")
    if [[ "$cur" == "fake-ip" ]]; then
        json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); d["enhanced-mode"]="normal"; d.pop("fake-ip-range",None); d.pop("fake-ip-filter",None)
print(json.dumps(d,ensure_ascii=False))
' "$json") || return 1
        print_info "已关闭 fake-ip (服务端推荐 normal)"
    else
        print_warn "服务端开 fake-ip 通常会让上游域名解析成 198.18.x.x 而连不上。"
        printf "仍要开启? [y/N]: "
        local a; read -r a
        case "$(clean_input "${a:-}")" in
            y|Y|yes|YES) ;;
            *) print_info "已取消"; return 0 ;;
        esac
        json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); d["enhanced-mode"]="fake-ip"; d["fake-ip-range"]="198.18.0.1/16"
print(json.dumps(d,ensure_ascii=False))
' "$json") || return 1
    fi
    dns_write "$json"
}

_dns_set_policy() {
    local json; json=$(dns_read)
    printf "格式: 域名=解析地址, 多个用逗号分隔\n" >&2
    printf "  例: +.example.com=https://dns.alidns.com/dns-query\n" >&2
    local raw; raw=$(safe_read "域名策略" "")
    raw=$(clean_input "$raw")
    if [[ -z "$raw" ]]; then
        json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); d.pop("nameserver-policy",None); print(json.dumps(d,ensure_ascii=False))
' "$json") || return 1
        print_info "已清空域名策略"
        dns_write "$json"
        return $?
    fi
    json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); pol={}
for part in sys.argv[2].replace(",","\n").split("\n"):
    part=part.strip()
    if not part: continue
    if "=" not in part: print(f"格式错误: {part}", file=sys.stderr); raise SystemExit(2)
    dom,_,val=part.partition("=")
    pol[dom.strip()]=[x.strip() for x in val.split() if x.strip()]
d["nameserver-policy"]=pol
print(json.dumps(d,ensure_ascii=False))
' "$json" "$raw") || { print_error "域名策略格式不正确"; return 1; }
    dns_write "$json"
}

_dns_toggle_respect_rules() {
    local json; json=$(dns_read)
    local cur; cur=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); print("true" if d.get("respect-rules") else "false")
' "$json")
    if [[ "$cur" == "true" ]]; then
        json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); d.pop("respect-rules",None); print(json.dumps(d,ensure_ascii=False))
' "$json") || return 1
        print_info "已关闭 respect-rules (DNS 出站不受路由规则约束)"
    else
        # 这条有硬依赖: respect-rules 需要 rules 段存在, 否则 DNS 出站无从判定。
        # 报表里记过这个死锁 (写出引用不存在 tag 的配置)。
        if ! grep -qE '^[[:space:]]*rules:' "$SRV_CONF/config.yaml" 2>/dev/null; then
            print_warn "当前 config.yaml 没有 rules 段。"
            print_warn "respect-rules 需要路由规则才能判定 DNS 出站, 硬开可能让解析失效。"
            printf "仍要开启? [y/N]: "
            local a; read -r a
            case "$(clean_input "${a:-}")" in
                y|Y|yes|YES) ;;
                *) print_info "已取消"; return 0 ;;
            esac
        fi
        json=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); d["respect-rules"]=True; print(json.dumps(d,ensure_ascii=False))
' "$json") || return 1
    fi
    dns_write "$json"
}

_dns_disable() {
    print_warn "关闭 DNS 段会让内核退回内置默认解析 (明文、不可控)。"
    printf "确认关闭? [y/N]: "
    local a; read -r a
    case "$(clean_input "${a:-}")" in
        y|Y|yes|YES) ;;
        *) print_info "已取消"; return 0 ;;
    esac
    local bak; bak=$(mktemp)
    cp -f "$SRV_CONF/config.yaml" "$bak" 2>/dev/null || true
    if python3 "$(_dns_py)" --conf "$SRV_CONF" --del >/dev/null 2>&1 && m_sync_reload quiet; then
        rm -f "$bak"; print_ok "已删除 dns 段"; return 0
    fi
    cp -f "$bak" "$SRV_CONF/config.yaml" 2>/dev/null
    rm -f "$bak"
    print_error "删除失败, 已回滚"
    return 1
}

# ---------- 菜单 ----------

dns_menu() {
    local c
    while true; do
        if [[ "${DNS_MODE:-server}" == "client" ]]; then
            print_title "DNS 管理 (客户端)"
            ui_hint "客户端默认用 fake-ip。fake-ip-filter 不能删 —— 少了它 QUIC/STUN/NTP 会坏, 而用户常误以为要关 fake-ip。"
        else
            print_title "DNS 管理 (服务端)"
            ui_hint "解析不了 = 全机节点连不上上游。改动都会先过三道校验, 不过就自动回滚。"
        fi
        ui_menu 1 "查看当前 DNS 配置"
        ui_menu 2 "套用安全默认 (推荐)"
        ui_menu 3 "设置主解析 (加密 DoH/DoT)"
        ui_menu 4 "设置引导解析 (明文)"
        ui_menu 5 "设置境外解析 fallback"
        ui_menu 6 "开关 fake-ip (服务端建议关 / 客户端建议开)"
        ui_menu 7 "设置域名解析策略 (防泄露)"
        ui_menu 8 "开关 respect-rules"
        ui_rule
        ui_menu 9 "关闭 DNS (退回内核默认)"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || { printf '\n' >&2; print_info "非交互环境, 已退出"; return 0; }
        c=$(clean_input "$c")
        case "$c" in
            1) dns_show ;;
            2) _dns_apply_preset ;;
            3) _dns_set_nameserver ;;
            4) _dns_set_default_ns ;;
            5) _dns_set_fallback ;;
            6) _dns_toggle_fakeip ;;
            7) _dns_set_policy ;;
            8) _dns_toggle_respect_rules ;;
            9) _dns_disable ;;
            0) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        echo >&2
        printf "  ${DIM}按回车继续...${RESET}" >&2
        read -r _ || true
    done
}
