#!/usr/bin/env bash
# =============================================================
# mihomo--core · 域名分流 (rules 绑定) —— 客户端
#
# 需求: 「出站有些域名, 我可能会使用其他的出站, 所以说需要有一个绑定」
# 即: 把指定域名绑到指定的节点/组上, 而不是一律走 MATCH,PROXY。
#
# Mihomo 的 rules 是**先匹配先赢**, 而且没有任何优化 —— 靠前的规则把流量全
# 接走, 后面的永远匹配不到。所以:
#   * 用户绑定的规则必须插到默认规则**之前**, 否则永远是死代码;
#   * 同一个域名再绑一次必须**替换**而不是追加 —— 追加的那条永远匹配不到,
#     而面板会显示"已添加成功", 用户以为流量已经切过去了。
#     这个坑 SB 自己踩过并改成替换 (outbound.sh split_add), 这里一开始就避开。
#
# 目标可选: 具体节点 / 代理组 / DIRECT (直连) / REJECT (拦截)。
# =============================================================

# 用户自定义规则的起始标记。配置文件里用注释锚定边界, 这样:
#   1. 面板只改自己那段, 不碰系统默认规则 (GEOSITE/GEOIP/MATCH)
#   2. 配置被外部工具重写时, 能靠标记识别出来而不是当成垃圾清掉
RULES_BEGIN="# >>> mihomo-panel 分流规则 BEGIN (面板管理, 请勿手改) >>>"
RULES_END="# <<< mihomo-panel 分流规则 END <<<"

rules_conf() { printf '%s\n' "$CLI_CONF/config.yaml"; }

# 列出可绑定的目标: 节点名 + 代理组名 + DIRECT/REJECT
_rules_targets() {
    local f; f=$(rules_conf)
    [[ -f "$f" ]] || return 0
    python3 - "$f" <<'PY'
import sys, re
txt = open(sys.argv[1], encoding="utf-8").read()
# 代理组名: "  - name: XXX"
for m in re.finditer(r'^\s*-\s*name:\s*(.+?)\s*$', txt, re.M):
    print(m.group(1).strip().strip('"\''))
print("DIRECT")
print("REJECT")
PY
}

_rules_list() {
    local f; f=$(rules_conf)
    [[ -f "$f" ]] || return 0
    python3 - "$f" <<'PY'
import sys
txt = open(sys.argv[1], encoding="utf-8").read()
b = "# >>> mihomo-panel 分流规则 BEGIN"
e = "# <<< mihomo-panel 分流规则 END"
if b not in txt:
    sys.exit(0)
body = txt.split(b, 1)[1].split(e, 1)[0]
n = 0
for line in body.splitlines():
    line = line.strip()
    # 必须整行以 "- " 开头才算规则 —— 段内的注释行也要滤掉。
    # 原来只判 startswith("#"), 而 BEGIN 标记被 b 切掉后残留成
    # "(面板管理, 请勿手改) >>>" 一行, 于是清单里多出一条假规则。
    if not line.startswith("- "):
        continue
    n += 1
    print(f"{n}|{line}")
PY
}

# 加/改一条分流。$1=域名 $2=目标 $3=匹配类型 (suffix 默认)
_rules_set() {
    local dom="$1" out="$2" kind="${3:-suffix}"
    local f; f=$(rules_conf)
    [[ -f "$f" ]] || { print_error "找不到配置文件"; return 1; }
    dom=$(clean_input "$dom"); out=$(clean_input "$out")
    [[ -n "$dom" ]] || { print_error "未输入域名"; return 1; }
    [[ -n "$out" ]] || { print_error "未选择目标"; return 1; }
    dom="${dom#\*}"; dom="${dom%.}"

    local TYPE
    case "$kind" in
        exact)  TYPE="DOMAIN" ;;
        keyword) TYPE="DOMAIN-KEYWORD" ;;
        regex)  TYPE="DOMAIN-REGEX" ;;
        *)      TYPE="DOMAIN-SUFFIX" ;;
    esac

    cp -f "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null

    local replaced
    replaced=$(python3 - "$f" "$TYPE" "$dom" "$out" <<'PY'
import sys, re
path, typ, dom, out = sys.argv[1:5]
B = "# >>> mihomo-panel 分流规则 BEGIN (面板管理, 请勿手改) >>>"
E = "# <<< mihomo-panel 分流规则 END <<<"
txt = open(path, encoding="utf-8").read()

rule = f"- {typ},{dom},{out}"
key = f",{dom},"

if B in txt:
    head, rest = txt.split(B, 1)
    body, tail = rest.split(E, 1)
else:
    # 首次使用: 插到 rules: 之后, 也就是系统默认规则**之前**。
    # 插在后面的话这些规则永远匹配不到 —— 先匹配先赢, 前面的 MATCH 接走了。
    # [ \t]* 而不是 \s*: 在 re.M 下 \s 会**吃掉换行符**, m.end() 越过行尾,
    # 于是 head+B 拼成 `rules:# >>> ...` —— YAML 解析直接报 line NN: could not find expected ':'
    m = re.search(r'^rules:[ \t]*$', txt, re.M)
    if not m:
        sys.exit(3)
    head = txt[:m.end()]
    tail = txt[m.end():]
    body = "\n"

lines = [l for l in body.splitlines() if l.strip()]
# 同域名替换而不是追加 —— 追加的那条是死代码 (见文件头说明)
hit = 0
new = []
for l in lines:
    s = l.strip()
    if s.startswith("- ") and key in s and typ in s:
        new.append(rule); hit += 1
    else:
        new.append(l)
if not hit:
    new.append(rule)

newbody = "\n" + "\n".join(new) + "\n"
# head 停在 "rules:" 行尾、不含换行; tail 以换行+缩进规则开头。
# 三段拼接时必须各自带上换行, 否则拼成 `rules:# >>> ...` ——
# YAML 报 "could not find expected ':'", 而报错行号还指向 rules 段之外, 极难定位。
open(path, "w", encoding="utf-8").write(head + "\n" + B + "\n" + newbody + E + "\n" + tail)
print(hit)
PY
    )
    local rc=$?
    if (( rc == 3 )); then
        print_error "配置文件里找不到 rules: 段, 已中止"
        return 1
    fi
    if (( rc != 0 )); then
        print_error "写入失败, 已保留备份"
        return 1
    fi
    [[ "$replaced" =~ ^[0-9]+$ && "$replaced" -gt 0 ]] \
        && print_info "已替换同域名 $dom 的既有规则 $replaced 条 (追加会变成永远匹配不到的死代码)"

    ui_tip "$TYPE,$dom -> $out"
    if _rules_reload; then print_ok "分流已生效"; fi
}

# 删除一条 (0 = 全部)
_rules_del() {
    local n="$1" f; f=$(rules_conf)
    [[ -f "$f" ]] || { print_error "找不到配置文件"; return 1; }
    local total; total=$(_rules_list | wc -l | tr -d ' ')
    if [[ "$n" == "0" ]]; then
        (( total > 0 )) || { print_info "没有分流规则"; return 0; }
        print_warn "将删除全部 $total 条分流规则"
        printf "  ${CYAN}确认? (y/N)${RESET}: " >&2
        local a; read -r a
        [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; return 0; }
    fi
    cp -f "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    python3 - "$f" "$n" <<'PY'
import sys, re
path, n = sys.argv[1], sys.argv[2]
B = "# >>> mihomo-panel 分流规则 BEGIN (面板管理, 请勿手改) >>>"
E = "# <<< mihomo-panel 分流规则 END <<<"
txt = open(path, encoding="utf-8").read()
if B not in txt:
    sys.exit(0)
head, rest = txt.split(B, 1)
body, tail = rest.split(E, 1)
keep, i = [], 0
for l in body.splitlines():
    s = l.strip()
    if s.startswith("- "):
        i += 1
        if n == "0" or str(i) == n:
            continue
    keep.append(l)
newbody = "\n" + "\n".join(keep) + "\n" if keep else "\n"
open(path, "w", encoding="utf-8").write(head + "\n" + B + "\n" + newbody + E + "\n" + tail)
PY
    if _rules_reload; then print_ok "分流规则已更新"; fi
}

# 改完必须校验 + 重载, 不能只写文件就说生效
_rules_reload() {
    local f; f=$(rules_conf)
    if ! "$CLI_ROOT/mihomo" -t -d "$CLI_ROOT/conf" >/tmp/_rcchk.$$ 2>&1; then
        print_error "配置校验不通过, 已回滚"
        local b; b=$(ls -t "$f".bak.* 2>/dev/null | head -1)
        [[ -n "$b" ]] && { cp -f "$b" "$f"; print_info "已回滚到修改前"; }
        rm -f /tmp/_rcchk.$$
        return 1
    fi
    rm -f /tmp/_rcchk.$$
    systemctl restart "$CLI_SERVICE" 2>/dev/null
    sleep 2
    return 0
}

rules_menu() {
    local c dom out kind choices i idx sel
    while true; do
        print_title "域名分流 (域名 -> 节点/组)"
        local rows; rows=$(_rules_list)
        if [[ -n "$rows" ]]; then
            echo >&2
            while IFS='|' read -r idx sel; do
                [[ -n "$idx" ]] && ui_kv_ascii "$idx" "$sel"
            done <<< "$rows"
        else
            echo >&2; print_info "当前没有分流规则 (所有流量走默认策略)"
        fi
        echo >&2
        ui_menu 1 "新增/修改分流"
        ui_menu 2 "删除分流"
        ui_menu 3 "查看可绑定的目标"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || return 0
        c=$(clean_input "$c")
        case "$c" in
            1)
                printf "  ${CYAN}域名${RESET} (如 example.com 或 a.example.com): " >&2
                read -r dom; dom=$(clean_input "$dom")
                [[ -n "$dom" ]] || { ui_invalid "$dom"; continue; }
                echo >&2; ui_title "匹配方式"
                ui_menu 1 "后缀匹配  *.example.com 都走 (推荐)"
                ui_menu 2 "精确匹配  只匹配这一个域名"
                ui_menu 3 "关键字匹配  域名含该片段就走"
                ui_menu 4 "正则匹配"
                echo >&2
                printf "  ${CYAN}请选择${RESET}: " >&2
                local k; read -r k; k=$(clean_input "$k")
                kind="suffix"
                case "$k" in 2) kind="exact" ;; 3) kind="keyword" ;; 4) kind="regex" ;; esac

                choices=($(_rules_targets))
                (( ${#choices[@]} )) || { print_error "没有可绑定的目标"; continue; }
                echo >&2; ui_title "目标"
                i=1
                for idx in "${choices[@]}"; do ui_menu "$i" "$idx"; i=$((i + 1)); done
                echo >&2
                printf "  ${CYAN}选择目标${RESET} (编号或直接输入名称): " >&2
                read -r sel; sel=$(clean_input "$sel")
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#choices[@]} )); then
                    out="${choices[$((sel-1))]}"
                else
                    out="$sel"
                fi
                _rules_set "$dom" "$out" "$kind"
                ;;
            2)
                printf "  ${CYAN}删除第几条 (0=全部)${RESET}: " >&2
                local n; read -r n; n=$(clean_input "$n")
                [[ "$n" =~ ^[0-9]+$ ]] || { ui_invalid "$n"; continue; }
                _rules_del "$n"
                ;;
            3)
                echo >&2
                local t; t=$(printf '%s\n' "${choices[@]:-}")
                printf '%s\n' "$(_rules_targets)" | nl -w2 -s'. ' | sed 's/^/    /' >&2
                ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}