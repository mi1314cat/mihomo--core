#!/usr/bin/env bash
# =============================================================
# check_yaml_guard.sh — 校验「safe_load 之后必须先判 dict」
# =============================================================
#
# 为什么需要它:
#
#   yaml.safe_load() 对**顶层不是映射**的文件返回 str / list, 不是 dict。
#   紧接着写 d.get(...) 就会:
#
#       AttributeError: 'str' object has no attribute 'get'
#
#   触发条件非常常见: 被截断的节点文件、写了一半的 YAML、根本不是 YAML 的
#   文本 —— 全都返回 str。也就是说**任何一次异常中断留下的坏文件**都会踩到。
#
#   实际后果取决于调用方有没有兜底, 但两类都糟:
#     * 没有兜底 → 脚本带非 0 退出码继续跑, 半截结果被当成完整结果用
#       (all.sh 的端口表就是这样: 表不全 → 已占用的端口被重新分配 →
#        新节点启动即 bind 失败, 而报错现场完全看不出根因在另一个文件)
#     * 有兜底   → 坏文件被静默显示成 "0 个节点" 或空白, 用户以为文件是空的
#
#   加一句 isinstance 判断就能根治, 所以这里机械地挡住。
#
# 用法: bash tools/check_yaml_guard.sh   退出码 0=通过 1=有裸 get
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

RED=$'\e[31m'; GREEN=$'\e[32m'; RESET=$'\e[0m'

python3 - <<'PY'
import io, os, re, sys

# 找出所有 src/ 下的 .sh, 定位内嵌 python 里的 safe_load, 检查后续是否
# 在**没有 isinstance 保护**的情况下用了 .get(
FILES = []
for root, _, names in os.walk('src'):
    for n in names:
        if n.endswith(('.sh', '.py')):
            FILES.append(os.path.join(root, n))
for n in ('install.sh',):
    if os.path.exists(n):
        FILES.append(n)

bad = []
for path in sorted(FILES):
    try:
        text = io.open(path, encoding='utf-8').read()
    except Exception:
        continue
    lines = text.split('\n')
    for i, line in enumerate(lines):
        if 'safe_load' not in line:
            continue
        # 从这个 safe_load 往后看 8 行, 找 d.get( / data.get( 之类
        window = lines[i:i + 8]
        guarded = any('isinstance' in w for w in window)
        for j, w in enumerate(window):
            m = re.search(r'\b(\w+)\.get\(', w)
            if not m:
                continue
            # 排除 isinstance(x, dict) and x.get(...) 同行写法
            if 'isinstance' in w:
                continue
            if guarded:
                continue
            bad.append((path, i + 1 + j, w.strip(), m.group(1)))
            break

if bad:
    print(f'{len(bad)} 处 safe_load 之后没有 isinstance 保护:')
    for path, ln, code, var in bad:
        print(f'  {path}:{ln}')
        print(f'      {code}')
        print(f'      → {var} 可能是 str/list, .get() 会抛 AttributeError')
    sys.exit(1)
print('safe_load 之后都有 dict 判断')
sys.exit(0)
PY
rc=$?

if (( rc == 0 )); then
    printf "  ${GREEN}✅${RESET} %s\n" "safe_load 后都有 dict 判断"
    exit 0
fi
printf "  ${RED}❌${RESET} %s\n" "有 safe_load 后直接 .get() 的地方"
exit 1
