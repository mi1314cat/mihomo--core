#!/usr/bin/env bash
# =============================================================
# check_wiring.sh — 校验「设了就该生效」的设置真的被读了
# =============================================================
#
# 为什么需要它:
#
# dl_route.sh (下载通道) 曾经是个**幽灵模块** —— 菜单里能设, 但:
#   * dl_curl 定义在, 全项目**零调用**;
#   * 订阅拉取是裸 curl, 完全不走通道;
#   * 分项设置函数忽略 scope 参数, 设"内核下载"会覆盖全局。
#
# 净效果**比没有这个功能更糟**: 用户设了、以为生效了, 其实没有 —— 而且
# 面板上看起来一切正常。这类 bug 不会自己暴露, 只能靠机械校验。
#
# 这个脚本回答一个问题:
#   **「面板里能设的每一个开关, 有没有代码真的读它?」**
#
# 用法: bash tools/check_wiring.sh    退出码 0=通过 1=有断线
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
fail=0
ok()   { printf "  ${GREEN}✅${RESET} %s\n" "$1"; }
bad()  { printf "  ${RED}❌${RESET} %s\n" "$1"; fail=1; }
warn() { printf "  ${YELLOW}⚠${RESET}  %s\n" "$1"; }

printf "\n═══ 设置项接线检查 ═══\n\n"

# 所有 shell 文件 (排除工具自身, 它必然会提到这些名字)
mapfile -t SHELLS < <(find src -name '*.sh' | sort)
SHELLS+=(install.sh)

# 统计"在某文件里被真正调用"的次数 —— 排除定义行与注释行
count_calls() {
    local fn="$1" f n=0
    for f in "${SHELLS[@]}"; do
        [[ -f "$f" ]] || continue
        # 去掉注释行, 去掉函数定义行, 再数出现次数
        local c
        c=$(sed 's/#.*//' "$f" 2>/dev/null \
            | grep -v "^[[:space:]]*${fn}()" \
            | grep -c "\b${fn}\b" 2>/dev/null || true)
        n=$(( n + ${c:-0} ))
    done
    printf '%s' "$n"
}

# ---------- 1. dl_route: 下载通道 ----------
printf "── 下载通道 (dl_route.sh) ──\n"

for fn in dl_curl dl_curl_code dl_route_resolve; do
    defined=0; called=0
    for f in "${SHELLS[@]}"; do
        grep -qE "^[[:space:]]*${fn}\(\)" "$f" 2>/dev/null && defined=$((defined+1))
    done
    called=$(count_calls "$fn")
    # 注意: count_calls 已用 grep -v 排除了定义行, 所以**不要再减 defined**。
    # (第一版多减了一次, 于是 dl_curl 明明被 webui.sh 调用了却报"零调用")
    if (( defined == 0 )); then
        bad "$fn 未定义"
    elif (( called <= 0 )); then
        bad "$fn 已定义但**零调用** —— 这个设置没人读 (幽灵模块)"
    else
        ok "$fn 定义 $defined 处, 被调用 $called 处"
    fi
done

# 订阅拉取必须走通道, 不能裸 curl
bare_sub=$(grep -n 'curl .*-w .%{http_code}.*' src/client.sh 2>/dev/null | grep -c 'http_code' || true)
if [[ "${bare_sub:-0}" -gt 0 ]]; then
    bad "src/client.sh 里还有裸 curl 拉订阅 (应走 dl_curl_code)"
else
    ok "订阅拉取全部走下载通道"
fi

# ---------- 2. 分项设置必须真的分项 ----------
printf "\n── 分项设置 ──\n"
if grep -qE '^[[:space:]]*dl_route_set\(\)' src/lib/dl_route.sh 2>/dev/null; then
    if grep -qE 'local scope=' src/lib/dl_route.sh 2>/dev/null; then
        ok "dl_route_set 接受并使用了 scope"
    else
        bad "dl_route_set 没有用 scope 参数 —— 分项设置会互相覆盖"
    fi
else
    warn "没找到 dl_route_set (结构变了? 请同步更新本检查)"
fi

# 旧的那三个忽略参数的 setter 不该再存在
if grep -qE '^[[:space:]]*dl_route_set_(direct|local|custom)\(\)' src/lib/dl_route.sh 2>/dev/null; then
    bad "旧的 dl_route_set_direct/local/custom 还在 —— 它们忽略 scope 参数"
else
    ok "旧的忽略参数的 setter 已清除"
fi

# ---------- 3. .dl-route 读取口径必须一致 ----------
printf "\n── .dl-route 读取口径 (必然有两份实现) ──\n"
# dl_route.sh 用 dl_route_get; core_install.sh 独立进程, 直接读文件
for pat in 'kernel=' 'global=' 'unset'; do
    a=$(grep -c "$pat" src/lib/dl_route.sh 2>/dev/null || true)
    b=$(grep -c "$pat" src/core_install.sh 2>/dev/null || true)
    if [[ "${a:-0}" -gt 0 && "${b:-0}" -gt 0 ]]; then
        ok "两份实现都认 '$pat'"
    else
        bad "读取口径不一致: '$pat' 在 dl_route.sh=$a 处, core_install.sh=$b 处"
    fi
done

# 两者都必须处理"分项 unset -> 跟随 global"
if grep -q 'unset' src/lib/dl_route.sh && grep -q 'unset' src/core_install.sh; then
    ok "两份都处理了 unset -> 跟随全局"
fi

# ---------- 4. 手动上传通道仍然可用 ----------
printf "\n── 手动上传 (下载全灭时的最后一条路) ──\n"
if grep -qE '^[[:space:]]*kernel_upload_menu\(\)' src/client.sh 2>/dev/null; then
    if grep -qE 'kernel_upload_menu' src/client.sh 2>/dev/null && \
       [[ "$(grep -c 'kernel_upload_menu' src/client.sh)" -ge 2 ]]; then
        ok "kernel_upload_menu 已定义且接进了菜单"
    else
        bad "kernel_upload_menu 定义了但没接进菜单"
    fi
else
    bad "客户端没有手动上传内核的入口 —— 下载全灭时用户没有出路"
fi
for fmt in 'gz' 'zip'; do
    if grep -q "\.${fmt}" src/client.sh 2>/dev/null; then
        ok "支持 .$fmt 格式"
    else
        warn "没找到 .$fmt 支持"
    fi
done

printf "\n"
if (( fail )); then
    printf "${RED}═══ 有断线, 请修 ═══${RESET}\n\n"
    exit 1
fi
printf "${GREEN}═══ 接线完整 ═══${RESET}\n\n"
exit 0
