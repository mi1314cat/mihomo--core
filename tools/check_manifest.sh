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
echo "════ 各处硬编码清单 vs manifest (必须一致) ════"
#
# 除了 install.sh 会按清单下载, 面板的「更新脚本」(core_mgmt.sh) 也要拉一整套。
# 那份原本也是硬编码, 且比清单少 8 个文件 —— 从面板更新会留下半新半旧的面板。
# 现在它也是"清单优先 + 兜底", 但兜底那份仍必须和清单一致, 否则清单拉取失败时
# 就会悄悄少更新几个文件。这里把每个兜底清单都比一遍。
check_list_against_manifest() {
    local label="$1" file="$2" startpat="$3"
    local -a got=()
    local line
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [[ -n "$line" ]] && got+=("$line")
    # 只取形如 src/... 的路径 —— 否则会把上面"读清单"那段代码里的
    # $tmp/manifest.txt、$(printf ...) 之类也当成清单条目。
    done < <(sed -n "/${startpat}/,/^[[:space:]]*)/p" "$file" \
             | grep -oE '"[^"]+"' | tr -d '"' | grep -E '^src/')
    if [[ ${#got[@]} -eq 0 ]]; then
        echo "  ⚠  $label: 没解析到清单 (结构变了? 请同步更新本检查)"
        return 0
    fi
    local diff_n=0 f found
    for f in "${listed[@]}"; do
        found=0
        for g in "${got[@]}"; do [[ "$f" == "$g" ]] && { found=1; break; }; done
        [[ "$found" -eq 0 ]] && { echo "  ❌ $label 少了: $f"; diff_n=$((diff_n + 1)); }
    done
    for f in "${got[@]}"; do
        found=0
        for g in "${listed[@]}"; do [[ "$f" == "$g" ]] && { found=1; break; }; done
        [[ "$found" -eq 0 ]] && { echo "  ❌ $label 多了: $f"; diff_n=$((diff_n + 1)); }
    done
    if [[ "$diff_n" -eq 0 ]]; then
        echo "  ✅ $label 与清单一致 (${#got[@]} 条)"
    else
        rc=1
    fi
}

check_list_against_manifest "core_mgmt.sh 兜底清单" "src/lib/core_mgmt.sh" "files=($"

echo ""
if [[ "$rc" -eq 0 ]]; then
    echo "✅ 清单一致 (${#listed[@]} 个文件)"
else
    echo "❌ 清单漂移: 缺失 $missing, 未登记 $ignored"
    echo "   修好 $MF 后重跑本脚本"
fi
exit "$rc"
