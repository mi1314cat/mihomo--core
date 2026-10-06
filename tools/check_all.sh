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
if miss:
    for k, v in sorted(miss.items()):
        print(f'❌ {k} 未定义, 被引用: {", ".join(v[:3])}')
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
