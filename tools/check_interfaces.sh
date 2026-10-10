#!/usr/bin/env bash
# =============================================================
# 接口一致性检查
#
# 检查什么
# --------
# Bash 调 Python 工具时, 参数是**字符串**; 一旦调用方写了一个生产者不认识的
# 开关, 或者按一个生产者不产出的格式去解析输出, 失败方式几乎都是
# **静默的**: 列表变空、循环不执行、检查器打印 "没有发现问题"。
#
# 本项目已经踩过三次, 全是同一类:
#   * share.sh 用 `awk 'NF==2'` 解析 `build_sub.py --list`,
#     而该表格是 3 列 ("tag  N 个") → tag 列表恒空 →
#     "分享哪些节点" 永远只列出 "全部节点"。
#   * cdn.sh 用 `awk -F'|' '{...$2}'` 解析 `nginx_apply.py --list`,
#     而该表格是空格分隔 → 站点文件列表恒空 →
#     "幽灵配置" 自检恒打印 "没有幽灵配置"。
#   * 同类的还有: 调用方传了生产者根本没定义的 flag (argparse 会报错退出,
#     但被 `2>/dev/null` 吞掉, 于是同样是静默变空)。
#
# 因此本检查做两件事:
#   ① 源码里每一处 `python3 "$X" ... --flag` 的 --flag, 必须能在目标脚本里
#      找到对应的 add_argument / argv 解析, 否则报错。
#   ② 禁止再用"按字段数/分隔符"的方式解析**给人看的表格** —— 必须走
#      生产者提供的机器可读开关 (--list-tags / --list-paths 这类)。
#
# 为什么需要它
# ------------
# 「两处必须一致但没有机制保证」是本项目最主要的缺陷来源。文档写一百遍
# "记得改两处" 都没用; 只有机械检查能拦住。
#
# 退出码: 0 = 通过, 1 = 发现问题
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$(pwd)"
fail=0

hr() { printf '%s\n' "────────────────────────────────────────────"; }

echo "接口一致性检查"
hr

# -------------------------------------------------------------
# ① 每个 `python3 "<脚本>" --flag` 里的 flag, 目标脚本必须认识
# -------------------------------------------------------------
echo "[1/2] 调用方使用的 flag 是否被生产者支持"

# 建立 路径 -> 源码 的映射
declare -A SRC_OF
for f in $(find "$ROOT/src" -name '*.py' | sort); do
    SRC_OF["$(basename "$f")"]="$f"
done

n_checked=0
while IFS= read -r line; do
    # 形如: python3 "$BUILD_SUB" --out-dir "$SRV_OUT" --list-tags
    # 取变量名和该行出现的所有 --flag
    var=$(printf '%s' "$line" | grep -oE '\$[A-Z_]+' | awk 'NR==1' | tr -d '$')
    [[ -n "$var" ]] || continue
    flags=$(printf '%s' "$line" | grep -oE '\-\-[a-z][a-z0-9-]*' | sort -u)
    [[ -n "$flags" ]] || continue

    # 变量名 -> 实际脚本文件: 在 src 里找 `VAR=` 定义
    target=""
    def=$(grep -rhoE "${var}=.*" "$ROOT/src" --include='*.sh' 2>/dev/null | awk 'NR==1')
    for f in $(find "$ROOT/src" -name '*.py' | sort); do
        # 别写 `printf ... | grep -q "$(basename "$f")"`: grep -q 早退会让
        # printf 吃 SIGPIPE, 本脚本开着 pipefail, 明明命中也会走 false。
        _bn=$(basename "$f")
        if printf '%s' "$def" | grep "$_bn" >/dev/null; then target="$f"; break; fi
    done
    # 变量名与脚本同名时的兜底 (BUILD_SUB -> build_sub.py)
    if [[ -z "$target" ]]; then
        low=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
        for f in $(find "$ROOT/src" -name '*.py' | sort); do
            if [[ "$(basename "$f" .py)" == "$low" ]]; then target="$f"; break; fi
        done
    fi
    [[ -n "$target" ]] || continue

    for fl in $flags; do
        n_checked=$((n_checked + 1))
        if ! grep -qE "[\"']${fl}[\"']" "$target"; then
            echo "  ❌ $var 传了 $fl, 但 $(basename "$target") 里没有这个参数"
            fail=1
        fi
    done
done < <(grep -rhoE 'python3 "\$[A-Z_]+"[^|]*' "$ROOT/src" --include='*.sh' 2>/dev/null | sort -u)

echo "     检查了 $n_checked 处 flag 引用"

# -------------------------------------------------------------
# ② 禁止按字段数 / 分隔符解析给人看的表格
# -------------------------------------------------------------
echo "[2/2] 是否还在解析「给人看的表格」"

# 只找**真实代码行**, 跳过注释 (本项目大量注释里引用了旧写法作说明)
bad=0
while IFS= read -r hit; do
    file="${hit%%:*}"; rest="${hit#*:}"; ln="${rest%%:*}"
    # 该行是否以 # 开头 (允许前导空白)
    txt=$(sed -n "${ln}p" "$file")
    case "$(printf '%s' "$txt" | sed 's/^[[:space:]]*//')" in
        \#*) continue ;;
    esac
    printf '  ❌ %s:%s 按字段数/分隔符解析表格\n' "${file#"$ROOT"/}" "$ln"
    printf '     %s\n' "$(printf '%s' "$txt" | sed 's/^[[:space:]]*//')"
    bad=1
done < <(grep -rnE "awk[^|]*(-F'\\|'|NF *== *[0-9])" "$ROOT/src" --include='*.sh' 2>/dev/null)

if (( bad )); then
    fail=1
    echo "     说明: 表格是给人看的, 格式随时会变。请让生产者提供机器可读开关"
    echo "           (例如 build_sub.py --list-tags / nginx_apply.py --list-paths)。"
else
    echo "  ✅ 没有按字段数/分隔符解析表格的代码"
fi

hr
if (( fail )); then
    echo "❌ 接口一致性检查未通过"
    exit 1
fi
echo "✅ 接口一致性检查通过"
exit 0
