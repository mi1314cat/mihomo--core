#!/usr/bin/env bash
# =============================================================
# server_extra.sh — 服务端「出站 / 规则集 / 端口转发」
#
# 为什么放在一个文件里而不是三个:
#   三者的生命周期完全一致 —— 都由服务端面板菜单挂载, 都落在 conf/config.d/
#   下的独立片段里, 都走「合并 → 严格校验 → mihomo -t → 重载」同一条通道。
#   拆三个文件只是让 manifest 多三行, 不会让任何一处更清楚。
#
# 三者与已有功能的关系 (避免重复造轮子):
#   * 出站   —— 服务端自己的出站。客户端的 simple_proxy.sh 只做「接其它内核的
#              HTTP/SOCKS」, 那是**客户端**的事; 这里做的是服务端转发用的出站。
#   * 规则集 —— 服务端用 rule-provider 做分流。与客户端 rules_bind.sh 的
#              「域名 → 节点/组」不是一回事: 那改的是客户端 config.yaml,
#              这里改的是服务端 config.d/。
#   * 端口转发 —— direct listener, 把本机一个端口的数据直接送到目标地址。
#              mihomo 原生支持 (type: tunnel), 已用内核 -t 逐字段实测验证。
#
# 存储布局 (都放 config.d/, 由 merge.py 自动合并进主配置):
#   conf/config.d/outbound-NN.yaml   outbounds 段
#   conf/config.d/ruleset-NN.yaml    rule-providers + 自己的 rules 段
#   conf/config.d/pfwd-NN.yaml       端口转发 listener
#
# 片段顶部都写自己的 tag 注释, 删节点时按 tag 精确摘除, 不误伤别人。
# =============================================================

# =============================================================
# 一、通用: 片段读写
# =============================================================

_extra_dir() { printf '%s' "$CONF_DIR"; }

_extra_next_index() { # <前缀> -> 第一个空位 NN
    local pre="$1" i
    for (( i = 1; i < 100; i++ )); do
        [[ -f "$(_extra_dir)/$pre-$(printf '%02d' "$i").yaml" ]] || { printf '%02d' "$i"; return; }
    done
    printf '01'
}

_extra_count() { # <前缀> -> 数量
    local pre="$1" i n=0 f
    for (( i = 1; i < 100; i++ )); do
        printf -v f '%s/%s-%02d.yaml' "$(_extra_dir)" "$pre" "$i"
        [[ -f "$f" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
}

_extra_list() { # <前缀> -> 逐条打印 "NN<TAB>摘要"
    local pre="$1" f i idx
    for (( i = 1; i < 100; i++ )); do
        printf -v f '%s/%s-%02d.yaml' "$(_extra_dir)" "$pre" "$i"
        [[ -f "$f" ]] || continue
        idx=$(printf '%02d' "$i")
        printf '%s\t%s\n' "$idx" "$(_extra_summary "$f")"
    done
}

# 从片段里抽一行人话摘要 (不是给机器解析的, 只为菜单显示)
_extra_summary() {
    local f="$1"
    python3 - "$f" <<'PY' 2>/dev/null || printf '(无法解析)'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("(无法解析)"); raise SystemExit
if not isinstance(d, dict):
    print("(无法解析)"); raise SystemExit
# 端口转发
for l in (d.get("listeners") or []):
    if isinstance(l, dict) and l.get("type") == "tunnel":
        net = l.get("network") or []
        if isinstance(net, list):
            net = "/".join(str(x) for x in net)
        print(f"{l.get('listen','0.0.0.0')}:{l.get('port')} ({net}) -> {l.get('target','?')}")
        raise SystemExit
# 出站
ob = d.get("outbounds") or []
if ob:
    print(", ".join(f"{o.get('name')} ({o.get('type')})" for o in ob
                    if isinstance(o, dict)))
    raise SystemExit
# 规则集
rp = d.get("rule-providers") or {}
if rp:
    print(", ".join(f"{k}({v.get('behavior','?')})" for k, v in rp.items()
                    if isinstance(v, dict)))
    raise SystemExit
print("(空)")
PY
}

_extra_del() { # <前缀> <NN>
    local pre="$1" idx="$2" f
    f=$(printf '%s/%s-%s.yaml' "$(_extra_dir)" "$pre" "$idx")
    [[ -f "$f" ]] || { print_error "没有 $pre-$idx"; return 1; }
    rm -f "$f" && print_ok "已删除 $pre-$idx"
}

# 三个功能共用的收尾: 合并 -> 校验 -> 重载
_extra_apply() {
    printf '\n  应用配置...\n'
    if m_sync_reload; then
        print_ok "已生效"
    else
        print_error "校验未通过, 已回滚"
        return 1
    fi
}

# =============================================================
# 二、出站管理
# =============================================================
#
# mihomo 的 outbounds 是服务端**主动连出去**时用的。场景:
#   * 节点监听器后面要指定走哪条链路 (走本地另有一个内核/落地机)
#   * 想把某些目标定向到 reject / direct 而不是默认规则
#
# 内核实测: outbounds 段写 type: direct / reject / socks5 / http 均通过 -t。
_extra_ask_outbound_type() {
    printf '\n  出站类型:\n' >&2
    printf '    1) direct  直连 (本机自己出去)\n' >&2
    printf '    2) reject  拒绝\n' >&2
    printf '    3) socks5  转发给另一个 SOCKS 代理\n' >&2
    printf '    4) http    转发给一个 HTTP 代理\n' >&2
    printf '  请选择 [1]: ' >&2
    local c; read -r c || return 1
    case "$c" in 2) printf 'reject' ;; 3) printf 'socks5' ;; 4) printf 'http' ;; *) printf 'direct' ;; esac
}

outbound_add() {
    print_title "添加服务端出站"
    local t; t=$(_extra_ask_outbound_type) || return 1

    local name default_port
    case "$t" in
        socks5|reject) default_port="" ;;
        http) default_port="" ;;
        *) default_port="" ;;
    esac

    printf '\n  出站名称 (规则里用它引用, 建议用英文/短横线):\n  名称: ' >&2
    local name; read -r name || return 1
    name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9_-')
    [[ -n "$name" ]] || { print_error "名称不能为空 (只能用字母/数字/下划线/短横线)"; return 1; }

    # 名字撞了不静默覆盖 —— 规则里引用的是名字, 改了名字等于悄悄改坏规则
    if python3 - "$CONF_DIR" "$name" <<'PY' 2>/dev/null
import sys, glob, yaml
want = sys.argv[2]
for f in glob.glob(sys.argv[1] + "/outbound-*.yaml"):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception:
        continue
    for o in (d.get("outbounds") or []) if isinstance(d, dict) else []:
        if isinstance(o, dict) and o.get("name") == want:
            raise SystemExit(0)
raise SystemExit(1)
PY
    then
        print_error "已存在同名出站 '$name' —— 请换个名字 (规则按名字引用, 覆盖会改坏已有规则)"
        return 1
    fi

    local extra=""
    case "$t" in
        socks5|http)
            printf '  上游地址 (如 127.0.0.1:1080): ' >&2
            local up; read -r up || return 1
            [[ -n "$up" ]] || { print_error "地址不能为空"; return 1; }
            extra="$up"
            ;;
    esac

    local idx
    idx=$(_extra_next_index outbound)
    local f
    f=$(printf '%s/outbound-%s.yaml' "$(_extra_dir)" "$idx")

    python3 - "$f" "$name" "$t" "$extra" <<'PY'
import sys
path, name, t, extra = sys.argv[1:5]
L = [f"# 服务端出站 · {name} ({t}) —— 由面板生成, 删除请用面板菜单"]
if t == "socks5":
    h, _, p = extra.rpartition(":")
    L += ["outbounds:", f"  - name: {name}", "    type: socks5",
          f"    server: {h or extra}", f"    port: {int(p) if p.isdigit() else 1080}"]
elif t == "http":
    h, _, p = extra.rpartition(":")
    L += ["outbounds:", f"  - name: {name}", "    type: http",
          f"    server: {h or extra}", f"    port: {int(p) if p.isdigit() else 8080}"]
else:
    L += ["outbounds:", f"  - name: {name}", f"    type: {t}"]
open(path, "w", encoding="utf-8").write("\n".join(L) + "\n")
PY

    print_ok "已创建 outbound-$idx ($name)"
    _extra_apply
}

outbound_list() {
    print_title "服务端出站"
    local n; n=$(_extra_count outbound)
    if [[ "$n" == "0" ]]; then
        printf '\n  (还没有出站)\n\n' >&2
        return 0
    fi
    printf '\n  %-6s %s\n' "编号" "出站" >&2
    printf '  %s\n' "--------------------------------" >&2
    _extra_list outbound | while IFS=$'\t' read -r idx sum; do
        printf '  %-6s %s\n' "$idx" "$sum" >&2
    done
    printf '\n' >&2
}

outbound_del() {
    print_title "删除服务端出站"
    outbound_list
    printf '  要删除的编号 (回车取消): ' >&2
    local idx; read -r idx || return 1
    [[ -n "$idx" ]] || return 0
    _extra_del outbound "$idx"
    _extra_apply
}

outbound_menu() {
    while true; do
        print_title "出站管理"
        ui_menu 1 "添加出站"
        ui_menu 2 "列出出站"
        ui_menu 3 "删除出站"
        ui_rule
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        local c; c=$(clean_input "$(read -r)") || break
        case "$c" in
            1) outbound_add; pause ;;
            2) outbound_list; pause ;;
            3) outbound_del; pause ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}

# =============================================================
# 三、规则集管理
# =============================================================
#
# mihomo rule-provider 的 type (vehicle) 只有三种, 已用 mihomo -t 实测:
#   * inline —— 规则直接写在配置的 payload 里 (本面板用它, 不依赖外部文件/网络)
#   * file   —— 本地文件
#   * http   —— 远程规则集
#
# ⚠ **不是 "payload"**。凭直觉写 type: payload 内核不认, 报的是
#   "unsupported vehicle type: payload" —— 错误名里没有 rule-provider,
#   很容易误以为是别的段坏了, 而 listeners/proxies 都与它无关。
#
# 这里做 payload 型: 用户在菜单里一行一行加域名/关键词, 生成
# rule-providers + 对应的 RULE-SET 规则。行为 domain / ipcidr / classical。
# 内核实测三种 behavior 均通过 -t。
_extra_ask_ruleset_behavior() {
    printf '\n  规则类型:\n' >&2
    printf '    1) domain   域名 (含子域)\n' >&2
    printf '    2) ip-cidr  IP 段\n' >&2
    printf '    3) classical 经典规则 (DOMAIN-SUFFIX / GEOIP 等)\n' >&2
    printf '  请选择 [1]: ' >&2
    local c; read -r c || return 1
    case "$c" in 2) printf 'ipcidr' ;; 3) printf 'classical' ;; *) printf 'domain' ;; esac
}

ruleset_add() {
    print_title "添加规则集"
    printf '\n  规则集名称 (小写字母/数字/短横线):\n  名称: ' >&2
    local name; read -r name || return 1
    name=$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')
    [[ -n "$name" ]] || { print_error "名称不合法"; return 1; }
    [[ "$name" != *-* ]] || { print_error "名称里不要用短横线 (YAML 键名会难读, 用下划线)"; return 1; }

    if python3 - "$CONF_DIR" "$name" <<'PY' 2>/dev/null
import sys, glob, yaml
want = sys.argv[2]
for f in glob.glob(sys.argv[1] + "/ruleset-*.yaml"):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception:
        continue
    if isinstance(d, dict) and want in (d.get("rule-providers") or {}):
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
        print_error "已存在同名规则集 '$name'"; return 1
    fi

    local beh; beh=$(_extra_ask_ruleset_behavior) || return 1

    printf '\n  逐条输入规则 (留空结束):\n' >&2
    local -a items=()
    while true; do
        printf '    规则 (如 example.com): ' >&2
        local it; read -r it || break
        [[ -n "$it" ]] || break
        items+=("$it")
    done
    (( ${#items[@]} > 0 )) || { print_error "至少要一条规则"; return 1; }

    # 命中的目标: 直接 还是 某个出站
    printf '\n  命中后走哪里:\n' >&2
    printf '    1) DIRECT 直连\n' >&2
    printf '    2) REJECT 拒绝\n' >&2
    local oc; printf '  请选择 [1]: ' >&2
    read -r oc || oc=1
    local target="DIRECT"; [[ "$oc" == "2" ]] && target="REJECT"

    local idx; idx=$(_extra_next_index ruleset)
    local f; f=$(printf '%s/ruleset-%s.yaml' "$(_extra_dir)" "$idx")

    python3 - "$f" "$name" "$beh" "$target" "${items[@]}" <<'PY'
import sys
path, name, beh, target = sys.argv[1:5]
items = sys.argv[5:]
L = [f"# 规则集 · {name} ({beh}) —— 由面板生成, 删除请用面板菜单",
     "rule-providers:", f"  {name}:", f"    type: inline",
     f"    behavior: {beh}", "    payload:"]
L += [f"      - {it!r}" for it in items]
L += ["", "rules:", f"  - RULE-SET,{name},{target}"]
open(path, "w", encoding="utf-8").write("\n".join(L) + "\n")
PY

    print_ok "已创建 ruleset-$idx ($name, ${#items[@]} 条)"
    _extra_apply
}

ruleset_list() {
    print_title "规则集"
    local n; n=$(_extra_count ruleset)
    if [[ "$n" == "0" ]]; then
        printf '\n  (还没有规则集)\n\n' >&2
        return 0
    fi
    printf '\n  %-6s %s\n' "编号" "规则集" >&2
    printf '  %s\n' "--------------------------------" >&2
    _extra_list ruleset | while IFS=$'\t' read -r idx sum; do
        printf '  %-6s %s\n' "$idx" "$sum" >&2
    done
    printf '\n' >&2
}

ruleset_del() {
    print_title "删除规则集"
    ruleset_list
    printf '  要删除的编号 (回车取消): ' >&2
    local idx; read -r idx || return 1
    [[ -n "$idx" ]] || return 0
    _extra_del ruleset "$idx"
    _extra_apply
}

ruleset_menu() {
    while true; do
        print_title "规则集管理"
        ui_menu 1 "添加规则集"
        ui_menu 2 "列出规则集"
        ui_menu 3 "删除规则集"
        ui_rule
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        local c; c=$(clean_input "$(read -r)") || break
        case "$c" in
            1) ruleset_add; pause ;;
            2) ruleset_list; pause ;;
            3) ruleset_del; pause ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}

# =============================================================
# 四、端口转发
# =============================================================
#
# 内核实测字段 (mihomo -t v1.19.32 逐字段验证):
#   listeners:
#     - name: pf-01
#       type: tunnel            # ★ 不是 direct —— 内核没有 direct 这个 listener
#       listen: 0.0.0.0
#       port: <本机监听端口>
#       network:                # ★ 必须是列表, 写标量报 "'network' is not a slice"
#         - tcp                 #   可选 tcp / udp
#       target: <目标 host:port> # 无 ,omitempty => 缺了报 "has unset fields"
#       override-destination: false
#
# override-destination 是关键: 不开它 target 是唯一出口 (更安全, 默认档);
# 开了之后客户端可以在请求里指定别的目标, 相当于一个不改内容的转发代理。
pfwd_add() {
    print_title "添加端口转发"
    printf '\n  本机监听地址 [0.0.0.0]: ' >&2
    local laddr; read -r laddr || return 1
    laddr="${laddr:-0.0.0.0}"
    # IPv6 的 [::1] 写法先剥掉方括号再校验 ——
    # 正则里不能写 [\[\]]: bash 的 ERE 把括号类内的 \[ \] 当成一个**区间**,
    # 结果 0.0.0.0 这种最正常的地址反而匹配不上 (实测踩过)。
    local lchk="${laddr#[}"; lchk="${lchk%]}"
    [[ "$lchk" =~ ^[0-9A-Za-z._:-]+$ ]] || { print_error "监听地址不合法: $laddr"; return 1; }

    printf '  本机监听端口 (如 23389): ' >&2
    local lport; read -r lport || return 1
    [[ "$lport" =~ ^[0-9]{1,5}$ ]] && (( lport >= 1 && lport <= 65535 )) \
        || { print_error "端口必须是 1-65535 的数字"; return 1; }

    # 端口占用预检 —— 否则 mihomo 启动时 bind 失败, 整个服务端起不来
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$lport\$"; then
        print_error "端口 $lport 已被占用, 换一个"
        return 1
    fi

    printf '  目标地址 (如 127.0.0.1:3000 或 example.com:443): ' >&2
    local target; read -r target || return 1
    # 同样避开括号类里的 [] —— IPv6 目标 [::1]:22 先剥方括号
    local tchk="${target#[}"; tchk="${tchk%]}"
    [[ "$tchk" =~ ^[0-9A-Za-z._:-]+:[0-9]+$ ]] || { print_error "目标格式应为 host:port"; return 1; }

    printf '\n  转发哪些协议?\n' >&2
    printf '    1) tcp\n' >&2
    printf '    2) tcp + udp\n' >&2
    printf '  请选择 [1]: ' >&2
    local nc; read -r nc || nc=1
    local netblock="      - tcp"
    [[ "$nc" == "2" ]] && netblock="      - tcp\n      - udp"

    local od="false"
    printf '\n  是否允许客户端指定真实目标 (override-destination)?\n' >&2
    printf '    1) 否 —— 所有流量都送到上面那个目标 (推荐, 更安全)\n' >&2
    printf '    2) 是 —— 客户端可以在请求里指定别的目标\n' >&2
    printf '  请选择 [1]: ' >&2
    local oc; read -r oc || oc=1
    [[ "$oc" == "2" ]] && od="true"

    local idx; idx=$(_extra_next_index pfwd)
    local f; f=$(printf '%s/pfwd-%s.yaml' "$(_extra_dir)" "$idx")

    # ★ type 必须是 tunnel, 不是 direct —— 内核没有 direct 这个 listener 类型,
    #   写成 direct 会让 mihomo -t 报 "unsupport proxy type: direct", 而这会
    #   因为 listeners 是共享数组而**整批配置**校验不过 (节点也一起起不来)。
    #   network 必须是**列表**, 写成标量报 "'network' is not a slice"。
    printf '# 端口转发 · %s:%s -> %s —— 由面板生成, 删除请用面板菜单\n' \
        "$laddr" "$lport" "$target" > "$f"
    printf 'listeners:\n' >> "$f"
    printf '  - name: pf-%s\n' "$idx" >> "$f"
    printf '    type: tunnel\n' >> "$f"
    printf '    listen: "%s"\n' "$laddr" >> "$f"
    printf '    port: %s\n' "$lport" >> "$f"
    printf '    network:\n%s\n' "$netblock" >> "$f"
    printf '    target: "%s"\n' "$target" >> "$f"
    printf '    override-destination: %s\n' "$od" >> "$f"

    print_ok "已创建 pfwd-$idx ($laddr:$lport -> $target)"
    _extra_apply
}

pfwd_list() {
    print_title "端口转发"
    local n; n=$(_extra_count pfwd)
    if [[ "$n" == "0" ]]; then
        printf '\n  (还没有端口转发)\n\n' >&2
        return 0
    fi
    printf '\n  %-6s %s\n' "编号" "监听 -> 目标" >&2
    printf '  %s\n' "--------------------------------" >&2
    _extra_list pfwd | while IFS=$'\t' read -r idx sum; do
        printf '  %-6s %s\n' "$idx" "$sum" >&2
    done
    printf '\n' >&2
}

pfwd_del() {
    print_title "删除端口转发"
    pfwd_list
    printf '  要删除的编号 (回车取消): ' >&2
    local idx; read -r idx || return 1
    [[ -n "$idx" ]] || return 0
    _extra_del pfwd "$idx"
    _extra_apply
}

pfwd_menu() {
    while true; do
        print_title "端口转发"
        ui_menu 1 "添加转发"
        ui_menu 2 "列出转发"
        ui_menu 3 "删除转发"
        ui_rule
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        local c; c=$(clean_input "$(read -r)") || break
        case "$c" in
            1) pfwd_add; pause ;;
            2) pfwd_list; pause ;;
            3) pfwd_del; pause ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}

# =============================================================
# 五、卸载时要一并清掉的片段
#
# 与 _uninstall_all 的清单放在一起 (见 server.sh)。这里只提供名字列表,
# 免得那处再手写一遍前缀。
_extra_fragment_prefixes() { printf 'outbound ruleset pfwd'; }
