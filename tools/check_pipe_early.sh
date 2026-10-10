#!/usr/bin/env bash
# ================================================================
# check_pipe_early.sh — `set -e` + 命令替换里的早退读取器 = 随机猝死
#
# 事故原型（X 内核客户端实测）:
#
#     ver=$("$XBD_XRAY" version | head -1)
#
# head 拿到第一行就退出, xray 还在写第二行, 于是 xray 吃 SIGPIPE
# （退出码 141）。脚本开着 `set -euo pipefail`, 管道整体非零 → 赋值
# 失败 → set -e 当场杀掉脚本。12 次里死了 4 次 —— 用户看到的是
# "菜单只闪了一下版本号就回到命令行", 时好时坏, 根本没法复现。
#
# 判据很干净: 早退读取器只有 head / grep -q / grep -m。
# awk、sed、sort、tail -n 都会读完输入才结束, 不会让上游吃 SIGPIPE。
#
# 两个例外, 不算问题:
#   * 同一行有 `|| true`  —— 显式吞掉了退出码
#   * head 出现在管道的**产出方**位置（`... || head -c 12 /dev/urandom | od`),
#     它自己在读 /dev/urandom, 不是读取器
#
# 修法: 换掉早退读取器, 而不是换掉产出方。
#   sed -n 's/../p' f | head -1   →   sed -n 's/../p' f | awk 'NR==1'
#   cmd | head -1                 →   先 out=$(cmd), 再 printf '%s\n' "$out" | awk 'NR==1'
# awk 不早退, 会读完输入; 产出方因此永远写得上, 不可能吃 SIGPIPE。
# ================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

python3 - <<'PY'
import os, re, sys

FILES = []
for dirpath, dirnames, filenames in os.walk("."):
    dirnames[:] = [d for d in dirnames
                   if d not in (".git", "out", "node_modules", "dist")]
    for f in filenames:
        if f.endswith(".sh"):
            FILES.append(os.path.normpath(os.path.join(dirpath, f)))
FILES = sorted(set(FILES))

# 读取位置的早退读取器: 前面是单个 `|`（不是 `||`）
EARLY = re.compile(r"(?<!\|)\|(?!\|)\s*(?:head\b|grep\s+-[a-zA-Z]*[qm]\b)")
# 变量赋值形式: var=$(...) / local var=$(...)
ASSIGN = re.compile(r"^\s*(?:local\s+|declare\s+|readonly\s+)?[A-Za-z_][A-Za-z0-9_]*=\$\(")

hits = []
for rel in FILES:
    try:
        lines = open(rel, encoding="utf-8").read().splitlines()
    except Exception:
        continue
    # 只查真正开着 errexit 的文件（lib 是被 source 的, 看调用方）
    if not re.search(r"^set -[a-z]*e", "\n".join(lines[:40]), re.M):
        continue
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        if "|| true" in line:
            continue
        if ASSIGN.match(line) and EARLY.search(line):
            hits.append(f"{rel}:{i}")

if hits:
    print("❌ set -e 文件里的早退管道会让上游吃 SIGPIPE(141), 随机杀脚本:")
    for h in hits:
        print(f"     {h}")
    print("   修法: 先读完再切行（别用 `| head`）")
    sys.exit(1)
print("✅ 没有早退管道（set -e 下不会随机吃 SIGPIPE）")
PY
