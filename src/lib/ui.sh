#!/usr/bin/env bash
# =============================================================
# mihomo--core · UI 基座 (ui.sh)
#
# 统一全项目的终端表现: 颜色、消息分级、标题、横线、键值对齐、菜单项。
# 借鉴 参考实现 的界面 (那边是长期打磨过的成熟版本), 但用 Mihomo
# 自己的内核语义实现同一套体验。
#
# 为什么单独抽一个文件:
#   改之前 print_* / 颜色常量在 11 个文件里各定义一份 —— 改一处要改十一处,
#   漏掉的那份就悄悄成了另一套样子 (标签一个中文一个英文)。现在只有这一份。
#
# 用途: 被 src/lib/env.sh source, 从而被所有 src/conf/*.sh 与 src/*.sh 带上。
# =============================================================

# ---------- 颜色 ----------
#
# 一律存**真正的 ESC 字节**, 不存字面量 "\e[96m"。
# 区别很要紧: 存字面量时只有 `printf "格式串"` 和 `echo -e` 会解释转义;
# `printf '%s' "$CYAN"` 不会 —— 终端上会原样显示 \e[96m, 颜色全废, 而且那些
# 反斜杠留在屏幕上, 复制粘贴必带垃圾。
# 归一化成真字节后, 这两种写法都能正常上色。
_sb_esc() { printf '%b' "$1"; }
RED="$(_sb_esc '\e[31m')"
GREEN="$(_sb_esc '\e[32m')"
YELLOW="$(_sb_esc '\e[33m')"
MAGENTA="$(_sb_esc '\e[95m')"
CYAN="$(_sb_esc '\e[96m')"
BLUE="$(_sb_esc '\e[94m')"
WHITE="$(_sb_esc '\e[97m')"
BOLD="$(_sb_esc '\e[1m')"
DIM="$(_sb_esc '\e[2m')"
RESET="$(_sb_esc '\e[0m')"

# ---------- 输出流 ----------
#
# 给人看的 UI 文本一律写 stderr, 留给 stdout 的是真正的数据。
# 两个原因, 都是踩出来的:
#   1) stdout 被 UI 文本污染后, `$(...)` 捕获到的"配置内容"里会混进中文,
#      而结果看着完全正常 —— 这类 bug 最难查。
#   2) 两个流缓冲策略不同 (stderr 无缓冲, stdout 管道下块缓冲), 混着输出时
#      顺序会错。实测 print_title(stderr) 排到了 status_block(stdout) 前面,
#      屏幕上就是"状态先于标题出现"。
#
# 唯一的例外是 ui_w: 它是取值函数, 靠 $(ui_w) 拿终端宽度, 必须留 stdout。

# ---------- 消息分级 ----------
print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET} %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

# ---------- 方框标题 ----------
# 用于顶层菜单: 有明确的"进入了一个新界面"的感觉。
print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ---------- 横线标题 (子页面 / 状态页) ----------
# 比方框轻, 同一屏里能放好几个而不显得吵。子页面统一用它。

# 规则线宽度: 跟随终端, 夹在 [36,66]
# 注意: 不能用 [[ -t 1 ]] 判断 —— 命令替换的子 shell 里 stdout 是管道,
# 恒为假, 于是永远退化到 80。tput 在子 shell 里仍能读到真实宽度。
ui_w() {
    local w="${COLUMNS:-}"
    [[ "$w" =~ ^[0-9]+$ ]] || w="$(tput cols 2>/dev/null || true)"
    [[ "$w" =~ ^[0-9]+$ ]] || w=80
    (( w > 66 )) && w=66
    (( w < 36 )) && w=36
    echo $(( w - 4 ))
}

ui_rule() {
    local n i line=""
    n=$(ui_w)
    for (( i = 0; i < n; i++ )); do line+="─"; done
    printf "${CYAN}%s${RESET}\n" "$line" >&2
}

ui_title() {
    ui_rule
    printf "  %s%s%s\n" "$CYAN" "$1" "$RESET" >&2
    ui_rule
}

# 键值行。ui_kv 用全角对齐(中文标签), ui_kv_ascii 用固定宽度(ASCII 标签)
ui_kv()       { printf "  %s   %s\n" "$1" "$2" >&2; }
ui_kv_ascii() { printf "    %-12s : %s\n" "$1" "$2" >&2; }

ui_clear() { clear 2>/dev/null || printf '\033[H\033[2J\033[3J'; }

# ---------- 菜单项 ----------
#
# %2s 是关键: 不补齐的话第 8 项和第 10 项的描述会错开一格, 一屏里看着就是歪的。
# 超过 9 项的菜单一定要走这个函数, 不要手写 echo。
ui_menu()   { printf "  ${CYAN}%2s${RESET}. %s\n" "$1" "$2" >&2; }
ui_menu_k() { printf "  ${CYAN}%2s${RESET}. ${BOLD}%s${RESET}\n" "$1" "$2" >&2; }

# 无效选项: 回显用户敲的东西, 否则他不知道是把 x 敲错了还是空格没去掉
ui_invalid() { printf "  ${RED}无效选项: %s${RESET}\n" "$1" >&2; }

# ---------- 输入 ----------
#
# clean_input 剥掉控制字符再 trim: 粘贴分享链接时常常带进 ANSI 序列或行尾空白,
# 不清掉会在后面所有比较里阴魂不散地失败。
clean_input() { echo "$1" | tr -d '\000-\037' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

pause() { printf "\n${CYAN}按回车继续...${RESET}" >&2; read -r || { printf "\n" >&2; exit 0; }; }

# safe_read <提示> <默认值> —— 回车即取默认值
safe_read() {
    local input
    printf '%s (默认: %s): ' "$1" "$2" >&2
    read -r input
    input=$(clean_input "$input")
    echo "${input:-$2}"
}

# ---------- 通用装饰 ----------
ui_hint() { printf "  ${DIM}%s${RESET}\n" "$1" >&2; }          # 灰色补充说明
ui_tip()  { printf "  ${CYAN}提示${RESET}: %s\n" "$1" >&2; }    # 青色操作提示

# ---------- 端口探测 ----------
#
# ss 的列号会随参数变: `ss -tulHn`(无表头) 的监听地址在**第 4 列**,
# 而带表头时列号整体后移。写死 $5 的话, 判定会永远拿到 `0.0.0.0:*` 这一列,
# 于是所有"端口是否被占"的结论全是错的 —— 而且静默错, 没有任何报错。
# 所以一律用整行匹配, 不依赖列号。
#
# TCP 与 UDP 都要看: QUIC 系节点只占 UDP, 只看 TCP 会漏判成"端口空闲"。
m_listening_ports() {
    # 两个坑叠在一起, 必须都避开:
    #   1) 列号会随表头变 -> 用 $(NF-1) 而不是 $4/$5, 本地地址恒是倒数第二列;
    #   2) 不能先 grep '[0-9]+$' 再取列 —— 行尾是 `0.0.0.0:*` 不是数字,
    #      整行匹配不到任何东西, 结果是**所有端口都判成空闲**。
    # 先切出本地地址字段, 再从里面取端口。
    { ss -tulHn 2>/dev/null || true; } | awk '{print $(NF-1)}' \
        | grep -oE '[0-9]+$' | sort -un
}

m_port_listening() {   # $1=端口 -> 0=在监听
    m_listening_ports | grep -qxF "$1"
}
