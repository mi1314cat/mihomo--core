#!/usr/bin/env bash
# =============================================================
# check_manifest.sh — 校验 src/manifest.txt 与实际文件是否一致
#
# 为什么需要它:
#   install.sh 曾经把下载清单硬编码在脚本里, 后来新增了 cert.sh /
#   preset.sh / cdn.sh 却没人同步, 全新安装直接缺 8 个文件。更麻烦的是
#   **面板仍然能启动** —— 只在启动瞬间刷三行 "No such file or directory",
#   用户点「添加节点」时才发现命令不存在。
#
#   清单挪进 src/manifest.txt 之后, 靠这个脚本把漂移卡在提交/CI 阶段。
#
# 用法:
#   bash tools/check_manifest.sh          # 检查, 有问题退出码 1
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

MF="src/manifest.txt"
[[ -f "$MF" ]] || { echo "❌ 找不到 $MF"; exit 2; }

# 从清单取出条目 (去注释/空行)
listed=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && listed+=("$line")
done < "$MF"

# 实际应当被下载的文件: src/lib、src/conf、src/share 下的脚本 + 三个入口
actual=()
for d in src/lib src/conf src/share; do
    for f in "$d"/*.sh "$d"/*.py; do
        [[ -f "$f" ]] || continue
        actual+=("$f")
    done
done
actual+=("src/core_install.sh" "src/server.sh" "src/client.sh")

rc=0

echo "════ 清单里有、但文件不存在 ════"
missing=0
for f in "${listed[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "  ❌ $f"
        missing=$((missing + 1)); rc=1
    fi
done
[[ "$missing" -eq 0 ]] && echo "  ✅ 无"

echo ""
echo "════ 文件存在、但不在清单里 (新增文件忘了登记) ════"
ignored=0
for f in "${actual[@]}"; do
    found=0
    for g in "${listed[@]}"; do
        [[ "$f" == "$g" ]] && { found=1; break; }
    done
    if [[ "$found" -eq 0 ]]; then
        echo "  ❌ $f"
        ignored=$((ignored + 1)); rc=1
    fi
done
[[ "$ignored" -eq 0 ]] && echo "  ✅ 无"

echo ""
if [[ "$rc" -eq 0 ]]; then
    echo "✅ 清单一致 (${#listed[@]} 个文件)"
else
    echo "❌ 清单漂移: 缺失 $missing, 未登记 $ignored"
    echo "   修好 $MF 后重跑本脚本"
fi
exit "$rc"
