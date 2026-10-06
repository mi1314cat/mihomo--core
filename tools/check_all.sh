#!/usr/bin/env bash
# =============================================================
# check_all.sh — 一次跑完所有机械校验
# =============================================================
#
# 为什么要有这个:
#
# 本项目的**主导 bug 类型**是「两处必须一致, 但没有任何机制保证」。已经
# 出现过 10+ 次, 每一次都是同一副面孔: 面板能启动、界面正常、设置能保存,
# 但某个地方悄悄不生效。
#
# 单点修复是不够的 —— 修完这次, 下次改动还会漂。所以每修一处, 就配一个
# 机械校验, 全部挂到这里。改完代码跑一遍, 比人眼可靠。
#
# 用法: bash tools/check_all.sh
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; RESET=$'\e[0m'

total=0; failed=0
declare -a FAILED_NAMES=()

run_gate() {
    local name="$1"; shift
    total=$((total + 1))
    printf "  ${CYAN}▸${RESET} %-26s " "$name"
    local out rc
    out=$("$@" 2>&1); rc=$?
    if (( rc == 0 )); then
        printf "${GREEN}✅${RESET}\n"
    else
        printf "${RED}❌${RESET}\n"
        failed=$((failed + 1))
        FAILED_NAMES+=("$name")
        printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '❌|⚠|不|错|缺|漂移|断线' | head -8 | sed 's/^/      /'
    fi
}

printf "\n${CYAN}═══ 全部机械校验 ═══${RESET}\n\n"

printf "${CYAN}── 一致性闸门 ──${RESET}\n"
run_gate "清单漂移"     bash tools/check_manifest.sh
run_gate "常量漂移"     bash tools/check_mirrors.sh
run_gate "接线完整"     bash tools/check_wiring.sh
run_gate "菜单编号"     bash tools/check_menu_ids.sh
run_gate "yaml 取值守卫" bash tools/check_yaml_guard.sh
# 调用方 vs 生产者: flag 必须存在, 且不许按"给人看的表格"的字段数/分隔符解析。
# 这一类 bug 全部是**静默失败** (列表变空 → 循环不跑 → 检查器打印"没问题"),
# 已经踩过三次 (share 的 NF==2、cdn 的 -F'|'、以及被 2>/dev/null 吞掉的 flag 错)。
run_gate "接口一致"     bash tools/check_interfaces.sh

# pre-push 钩子是否已安装。
#
# 钩子本体在 tools/git-hooks/pre-push (版本控制的一部分), 但 git 只认
# .git/hooks/ 下的副本 —— 换台机器 clone 出来是没有的, 于是「推 main 把
# 远端推回退」那个坑会重新出现。所以这里查一次。
#
# 这个坑实际踩了三次, 每次都报 forced update 且**退出码 0**, 看起来像成功。
git_hook() {
    local src=tools/git-hooks/pre-push dst=.git/hooks/pre-push
    [[ -f "$src" ]] || { printf "❌ 钩子源文件缺失: %s\n" "$src"; return 1; }
    if [[ ! -x "$dst" ]]; then
        printf "❌ pre-push 钩子未安装 (或不可执行): %s\n" "$dst"
        printf "   安装: cp %s %s && chmod 755 %s\n" "$src" "$dst" "$dst"
        return 1
    fi
    # 内容必须一致 —— 只存在但内容过期同样没意义
    if ! cmp -s "$src" "$dst"; then
        printf "❌ pre-push 钩子内容过期: %s\n" "$dst"
        printf "   更新: cp %s %s\n" "$src" "$dst"
        return 1
    fi
    return 0
}
run_gate "pre-push 钩子" git_hook

printf "\n${CYAN}── 语法 ──${RESET}\n"
syntax_shell() {
    local bad=0 f
    for f in src/*.sh src/lib/*.sh src/conf/*.sh src/share/*.sh tools/*.sh install.sh; do
        [[ -f "$f" ]] || continue
        bash -n "$f" 2>/dev/null || { printf "❌ %s\n" "$f"; bad=1; }
    done
    return $bad
}
syntax_py() {
    local bad=0 f
    for f in src/lib/*.py src/conf/*.py tools/*.py src/share/*.py; do
        [[ -f "$f" ]] || continue
        python3 -m py_compile "$f" 2>/dev/null || { printf "❌ %s\n" "$f"; bad=1; }
    done
    find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
    return $bad
}
run_gate "shell 语法"   syntax_shell
run_gate "python 语法"  syntax_py

printf "\n${CYAN}── 发布脱敏 ──${RESET}\n"
scrub_scan() {
    # GitHub 只给我们自己用, 是功能性的 —— 不能把部署信息带上去。
    #
    # 为什么必须做成门: 这个坑**重犯过**。历史上手动跑过一次脱敏, 之后又改
    # 了代码, 新写的注释里把真实 IP / 隧道地址 / SSH 端口又带回来了。手工
    # 跑一次的检查不是检查。
    #
    # 只查 git 跟踪的文件 —— 未被跟踪的 docs/private/ 本来就不上传。
    #
    # ★ 这里**不再排除 tools/scrub.py**。以前排除它, 理由是"它的 RULES 里
    #   就是这些模式的正则文本, 查它必然自命中" —— 但这个理由本身是错的:
    #   正因为把**真实值**写进了公开的正则, 这份工具才变成了泄露索引
    #   (确切的出口 IPv6 段 / 主机名 / 自有域名 / SSH 端口 / 内部别名全在里面)。
    #   现在 scrub.py 只放通用规则, 具体值在 gitignored 的 scrub-private.py。
    #   于是校验器可以、也必须校验自己。
    local files
    files=$(git ls-files | grep -v '^tools/scrub-private\.py$')
    [[ -n "$files" ]] || { printf "❌ 没拿到文件清单 (不在 git 仓库里?)\n"; return 1; }
    # shellcheck disable=SC2086
    python3 tools/scrub.py --check $files
}
run_gate "发布脱敏"     scrub_scan

printf "\n${CYAN}── 幽灵函数 (定义了但没人调) ──${RESET}\n"
phantom_scan() {
    python3 - <<'PY'
import io, os, re, sys
files = [os.path.join(r, f) for r, _, fs in os.walk('src') for f in fs if f.endswith('.sh')]
files.append('install.sh')
defined = set()
for p in files:
    defined |= set(re.findall(r'^\s*([_a-zA-Z]\w*)\(\)\s*\{', io.open(p, encoding='utf-8').read(), re.M))
miss = {}
for p in files:
    for i, l in enumerate(io.open(p, encoding='utf-8').read().split('\n'), 1):
        c = l.split('#')[0]
        c = re.sub(r'\$\{[^}]*\}', ' ', c)
        c = re.sub(r'\$\w+', ' ', c)
        for m in re.finditer(r'(?:^|[;|&(]\s*|\$\()\s*(_[a-z]\w*)\s', c):
            if m.group(1) not in defined:
                miss.setdefault(m.group(1), []).append(f'{os.path.basename(p)}:{i}')
miss = {k: v for k, v in miss.items() if k != '_n'}

# ---- 孤立菜单函数 ----
#
# 上面的扫描只看 `_[a-z]` 开头的函数, 所以 `cdn_menu` 这种**没下划线**的
# 菜单函数漏网了。实测: cdn_menu 定义在 cdn.sh:639, 全仓库
# **零调用点** —— 整个 CDN 回源管理菜单没有任何入口, 用户根本进不去。
# 而它内部还藏着一个渲染 bug (ui_menu 传了 5 个参数), 一直没人发现。
#
# 教训: 一个够不到的菜单等于不存在, 而且它的问题永远不会暴露。
# 所以单独查一遍所有 *_menu 函数的调用点。
orphan_menu = []
for p in files:
    src = io.open(p, encoding='utf-8').read()
    for i, l in enumerate(src.split('\n'), 1):
        m = re.match(r'^([a-zA-Z_]\w*_menu)\(\)\s*\{', l)
        if not m:
            continue
        name = m.group(1)
        if name == 'ui_menu':          # 是渲染原语, 由 install.sh 定义
            continue
        calls = 0
        for q in files:
            for j, ll in enumerate(io.open(q, encoding='utf-8').read().split('\n'), 1):
                code = ll.split('#')[0]
                if re.match(r'^\s*' + re.escape(name) + r'\(\)', ll):
                    continue           # 定义行本身
                if re.search(r'(?<![\w-])' + re.escape(name) + r'(?=[\s;|&)]|$)', code):
                    calls += 1
        if calls == 0:
            orphan_menu.append(f'{os.path.basename(p)}:{i} {name}')

if miss:
    for k, v in sorted(miss.items()):
        print(f'❌ {k} 未定义, 被引用: {", ".join(v[:3])}')
if orphan_menu:
    for o in orphan_menu:
        print(f'❌ 孤立菜单函数 (零调用点, 用户进不去): {o}')
if miss or orphan_menu:
    sys.exit(1)
PY
}
run_gate "幽灵函数"     phantom_scan

printf "\n"
if (( failed )); then
    printf "${RED}═══ %d/%d 项未通过 ═══${RESET}\n" "$failed" "$total"
    printf "  失败: %s\n\n" "${FAILED_NAMES[*]}"
    exit 1
fi
printf "${GREEN}═══ 全部 %d 项通过 ═══${RESET}\n\n" "$total"
exit 0
