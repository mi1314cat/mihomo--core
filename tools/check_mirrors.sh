#!/usr/bin/env bash
# =============================================================
# 重复常量漂移检查
# =============================================================
#
# 为什么需要这个:
#
# install.sh 是**引导脚本** —— 它靠 `bash <(curl ...)` 直接执行, 那一刻磁盘上
# 什么都没有, 所以它**不能 source src/lib/ 下的任何东西**。于是它必须自带一份
# 镜像链和一份代理探测逻辑, 而这两样在 src/lib/core_mgmt.sh 和
# src/core_install.sh 里也各有一份。
#
# "两处必须一致, 但没有机制保证一致" 是本项目最主要的 bug 来源 —— 光这一轮就
# 撞了 5 次 (K-14 清单漂移、K-16 监听键、K-17 幽灵函数、K-18 漏 source、
# K-19 漏判能力)。所以这里把重复的常量**机械比对**, 而不是靠"记得同步"。
#
# 用法: bash tools/check_mirrors.sh
# 退出码: 0=一致  1=有漂移
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
fail=0
say_ok()   { printf "  ${GREEN}✅${RESET} %s\n" "$1"; }
say_bad()  { printf "  ${RED}❌${RESET} %s\n" "$1"; fail=1; }
say_warn() { printf "  ${YELLOW}⚠${RESET}  %s\n" "$1"; }

printf "\n═══ 重复常量漂移检查 ═══\n\n"

# ---------- 1. 镜像链 ----------
# install.sh 的 REPO_MIRRORS 数组 vs core_mgmt.sh 的 m_repo_mirrors()
extract_install_mirrors() {
    sed -n '/^REPO_MIRRORS=(/,/^)/p' install.sh \
        | sed -n 's/^[[:space:]]*"\(https\?:\/\/[^"]*\)".*/\1/p' \
        | sort
}
extract_mgmt_mirrors() {
    # 只取**行首引号包起来的字面 URL** —— 不能顺手抓 ${REPO_PROXY:-https://...}
    # 里那个默认值, 否则会把 "https://github.com/mi1314cat/mihomo--core" 这种
    # 半截地址也算成一条镜像, 报出假漂移 (第一版就踩了这个坑)。
    sed -n '/^m_repo_mirrors()/,/^}/p' src/lib/core_mgmt.sh \
        | sed -n 's/^[[:space:]]*"\(https\?:\/\/[^"]*\)".*/\1/p' \
        | sort
}

A="$(extract_install_mirrors)"
B="$(extract_mgmt_mirrors)"

if [[ -z "$A" ]]; then
    say_bad "install.sh 里没解析到 REPO_MIRRORS (结构变了? 请同步更新本检查)"
elif [[ -z "$B" ]]; then
    say_bad "core_mgmt.sh 里没解析到 m_repo_mirrors (结构变了? 请同步更新本检查)"
else
    # 只比"镜像"部分: install.sh 的第一条是 REPO_RAW 变量, 不是字面 URL
    # core_mgmt 的第一条是 printf 的 %s 形式, 两边都拿不到, 所以只比字面量。
    if diff <(printf '%s\n' "$A") <(printf '%s\n' "$B") >/dev/null 2>&1; then
        say_ok "镜像链一致 ($(printf '%s\n' "$A" | wc -l) 条)"
    else
        say_bad "镜像链漂移:"
        diff <(printf '%s\n' "$A") <(printf '%s\n' "$B") | sed 's/^/      /'
    fi
fi

# ---------- 2. 代理扫描端口表 ----------
# install.sh 的 _scan_ports vs core_install.sh 的 scan_proxy
extract_ports() {
    sed -n "/for port in /,/; do/p" "$1" | awk 'NR==1' \
        | grep -oE '[0-9]{2,5}' | sort -n | tr '\n' ' '
}
P1="$(extract_ports install.sh)"
P2="$(extract_ports src/core_install.sh)"

if [[ -z "$P1" || -z "$P2" ]]; then
    say_bad "端口表没解析到 (install.sh='$P1' core_install.sh='$P2')"
elif [[ "$P1" == "$P2" ]]; then
    say_ok "代理扫描端口表一致 ($(echo "$P1" | wc -w) 个)"
else
    say_bad "代理扫描端口表漂移:"
    printf "      install.sh      : %s\n" "$P1"
    printf "      core_install.sh : %s\n" "$P2"
fi

# ---------- 3. _normalize_proxy 必须逐字一致 ----------
extract_fn() { sed -n "/^_normalize_proxy() {/,/^}/p" "$1"; }
N1="$(extract_fn install.sh)"
N2="$(extract_fn src/core_install.sh)"
if [[ -z "$N1" || -z "$N2" ]]; then
    say_bad "_normalize_proxy 没解析到"
elif [[ "$N1" == "$N2" ]]; then
    say_ok "_normalize_proxy 实现一致"
else
    say_bad "_normalize_proxy 实现漂移 (同一份输入会得到不同结果):"
    diff <(printf '%s\n' "$N1") <(printf '%s\n' "$N2") | sed 's/^/      /'
fi

# ---------- 4. _own_mixed_port 的读取口径 ----------
# 两边都要认 settings.env 的 PORT_MIXED 和 config.yaml 的 mixed-port
for f in install.sh src/core_install.sh; do
    body="$(sed -n "/^_own_mixed_port() {/,/^}/p" "$f")"
    miss=""
    [[ "$body" == *'settings.env'* ]]      || miss="$miss settings.env"
    [[ "$body" == *'PORT_MIXED'* ]]        || miss="$miss PORT_MIXED"
    [[ "$body" == *'config.yaml'* ]]       || miss="$miss config.yaml"
    [[ "$body" == *'mixed-port'* ]]        || miss="$miss mixed-port"
    if [[ -n "$miss" ]]; then
        say_bad "$f 的 _own_mixed_port 少了:$miss"
    else
        say_ok "$f 的 _own_mixed_port 读取口径完整"
    fi
done

# ---------- 5. install.sh 的 REPO_MIRRORS 条数 ----------
n=$(grep -cE '^\s*"https://' <(sed -n '/^REPO_MIRRORS=(/,/^)/p' install.sh) 2>/dev/null || echo 0)
if (( n >= 4 )); then
    say_ok "install.sh 镜像条数: $n"
else
    say_warn "install.sh 镜像条数偏少 ($n) —— 国内机器可能没有可用源"
fi

printf "\n"
if (( fail )); then
    printf "${RED}═══ 有漂移, 请修 ═══${RESET}\n\n"
    exit 1
fi
printf "${GREEN}═══ 全部一致 ═══${RESET}\n\n"
exit 0
