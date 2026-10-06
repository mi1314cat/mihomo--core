#!/usr/bin/env bash
# =============================================================
# check_menu_ids.sh — 菜单编号与 case 分支号必须一致
# =============================================================
#
# 为什么需要它:
#
# 服务端 svc_menu 曾经是:
#     ui_menu 1 "启动"
#     ui_menu 2 "停止"
#     ui_menu 4 "重启"          ← 标签是 4
#     ui_menu 5 "状态"          ← 标签是 5
#     ui_menu 6 "开机自启"
#     ui_menu 7 "手动上传内核"
#     case "$c" in
#         1) start ;; 2) stop ;; 3) restart ;; 4) status ;; 5) enable ;; 6) kernel ;;
#
# 标签从 2 直接跳到 4, case 却是 1..6 连续。于是**每个操作都错位一格**:
#     按 "4) 重启"     -> 执行的是"状态"
#     按 "5) 状态"     -> 执行的是"开机自启"
#     按 "6) 开机自启" -> 执行的是"手动上传内核"
#     按 "7) 上传内核" -> **什么都不发生**
#
# log_menu 是同一类的第二处 (1/2/4/5 对 1/2/3/4)。
#
# 这类 bug 的可怕之处: **不报错、不崩溃、界面看起来完全正常**。用户按了
# "重启", 服务没重启, 他只会以为"面板坏了"或者"内核有问题", 绝不会想到
# 是菜单编号写错了。
#
# ---------------------------------------------------------------
# 判定规则 (两条, 都是为了不误报):
#
#   1. 只看函数里**第一个** case —— 嵌套 case (如"选通道"里再套一层"选模式")
#      的内层 ui_menu 会被排除, 否则会误报。
#   2. case 里有 `*)` 兜底分支时, 未被显式列出的编号降级为**警告**而不是错误。
#      例: choose_listen_ip 的菜单 1="IPv4 (0.0.0.0)", 而 `*)` 正是
#      `echo "0.0.0.0"` —— 行为正确, 只是没写显式 `1)` 分支。
#      但如果**没有** `*)`, 缺号就是硬错误 (svc_menu / log_menu 都没有)。
#
# 用法: bash tools/check_menu_ids.sh    退出码 0=通过 1=有错位
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
fail=0
ok()   { printf "  ${GREEN}✅${RESET} %s\n" "$1"; }
bad()  { printf "  ${RED}❌${RESET} %s\n" "$1"; fail=1; }
warn() { printf "  ${YELLOW}⚠${RESET}  %s\n" "$1"; }

printf "\n═══ 菜单编号 ↔ case 分支号 一致性 ═══\n\n"

# awk 状态机: 按函数切分, 输出
#   文件|函数名|菜单号列表|分支号列表|是否有*兜底
scan() {
    awk '
    function flush() {
        # 只在**真的有 case** 时才输出 —— 有些菜单用 [[ "$t" == "2" ]] 处理,
        # 根本没有 case (如 simple_add_menu), 那不是错位, 不该报。
        if (fn != "" && nmenu > 0 && sawcase) {
            printf "%s|%s|%s|%s|%s\n", file, fn, menu, cases, (hasstar ? "Y" : "N")
        }
        fn=""; menu=""; cases=""; nmenu=0; depth=0; seen_case=0; hasstar=0; sawcase=0
    }
    FNR == 1 { flush() }
    # 函数定义
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
        flush()
        fn = $0; sub(/\(\).*/, "", fn)
        file = FILENAME
        next
    }
    # 函数结束 (行首 })
    /^\}/ { flush(); next }

    # 菜单项: 只收集**第一个 case 之前**的 ui_menu
    !seen_case && /ui_menu[[:space:]]+[0-9]+/ {
        if (match($0, /ui_menu[[:space:]]+[0-9]+/)) {
            s = substr($0, RSTART, RLENGTH)
            sub(/ui_menu[[:space:]]+/, "", s)
            menu = menu " " s; nmenu++
        }
        next
    }
    # case ... in
    /case[[:space:]]+.*[[:space:]]in[[:space:]]*$/ {
        seen_case = 1
        sawcase = 1
        depth++
        next
    }
    # 分支号: 只在**最外层** (depth==1) 收集
    # 支持 1) / 1|2) / 1|2|3|4) 这类多号分支
    depth == 1 && /^[[:space:]]+[0-9]+[)|]/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/\).*/, "", line)          # 去掉 ) 之后的内容
        sub(/[[:space:]].*/, "", line) # 去掉空白之后的内容
        nsplit = split(line, parts, "|")
        for (i = 1; i <= nsplit; i++) {
            if (parts[i] ~ /^[0-9]+$/) cases = cases " " parts[i]
        }
        next
    }
    # * 兜底分支 (只在最外层)
    depth == 1 && /^[[:space:]]*\*[)|]/ { hasstar = 1; next }
    # esac
    /^[[:space:]]*esac/ { if (depth > 0) depth--; if (depth == 0) seen_case = 1 }
    END { flush() }
    ' "$@"
}

mapfile -t SHELLS < <(find src -name '*.sh' | sort)

tmpf=$(mktemp)
scan "${SHELLS[@]}" > "$tmpf" 2>/dev/null

checked=0; warned=0
while IFS='|' read -r file fn menu cases hasstar; do
    [[ -z "$fn" || -z "$menu" ]] && continue
    checked=$((checked + 1))

    # ---- 方向 1: 菜单里有的号, case 里必须有 ----
    # 抓: 菜单写 "7) 上传内核" 但 case 只有 1..6 (svc_menu 原样) -> 按 7 无反应
    missing=""
    for m in $menu; do
        found=0
        for c in $cases; do
            [[ "$m" == "$c" ]] && { found=1; break; }
        done
        [[ "$found" -eq 0 ]] && missing="$missing $m"
    done

    # ---- 方向 2: case 里有的号, 菜单里必须有 ----
    # 抓: 菜单 1,2,3,5,6 而 case 1..6 —— 所有菜单号都在 case 里, 方向 1 查不出来,
    # 但分支 4 没有任何菜单项指向它, 且"5) 状态"实际执行的是 enable。
    # 第一版只查了方向 1, 所以这种"缺号变体"漏过去了。
    orphan=""
    for c in $cases; do
        [[ "$c" == "0" ]] && continue     # 0=返回 常不写进 ui_menu, 不算
        found=0
        for m in $menu; do
            [[ "$m" == "$c" ]] && { found=1; break; }
        done
        [[ "$found" -eq 0 ]] && orphan="$orphan $c"
    done

    if [[ -n "$missing" ]]; then
        if [[ "$hasstar" == "Y" ]]; then
            # 有 * 兜底 -> 可能是有意的默认项, 降级为警告
            warned=$((warned + 1))
            warn "$file :: $fn —— 编号$(printf '%s' "$missing" | tr -s ' ') 未显式列出, 由 *) 兜底"
            printf "        确认 *) 的行为 == 该菜单项宣称的行为 (否则是错位)\n"
        else
            bad "$file :: $fn —— 菜单项没有对应的 case 分支"
            printf "        菜单里有但 case 里没有的分支号:%s\n" "$missing"
            printf "        菜单: %s\n" "$(printf '%s' "$menu" | tr -s ' ')"
            printf "        分支: %s\n" "$(printf '%s' "$cases" | tr -s ' ')"
            fail=1
        fi
    fi

    if [[ -n "$orphan" ]]; then
        if [[ "$hasstar" == "Y" ]]; then
            warn "$file :: $fn —— case 分支$(printf '%s' "$orphan" | tr -s ' ') 没有菜单项 (可能由 *) 覆盖)"
        else
            bad "$file :: $fn —— case 分支没有菜单项指向它 (标签会整体错位)"
            printf "        case 里有但菜单里没有的分支号:%s\n" "$orphan"
            printf "        菜单: %s\n" "$(printf '%s' "$menu" | tr -s ' ')"
            printf "        分支: %s\n" "$(printf '%s' "$cases" | tr -s ' ')"
            fail=1
        fi
    fi
done < "$tmpf"
rm -f "$tmpf"

if (( checked == 0 )); then
    warn "没有扫到任何菜单函数 (结构变了? 请同步更新本检查)"
elif (( fail == 0 )); then
    ok "$checked 个菜单函数, 编号全部对得上"
fi

printf "\n"
if (( fail )); then
    printf "${RED}═══ 有编号错位, 请修 ═══${RESET}\n\n"
    exit 1
fi
printf "${GREEN}═══ 编号一致 ═══${RESET}\n\n"
exit 0
