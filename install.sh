#!/usr/bin/env bash
# =============================================================
# mihomo--core 安装引导
#
#   bash <(curl -fsSL <仓库>/install.sh)              # 服务器 + 客户端 菜单
#   bash <(curl -fsSL <仓库>/install.sh) server
#   bash <(curl -fsSL <仓库>/install.sh) client
#
# 客户端与服务端装在不同目录, 共用一个内核安装器, 但 systemd 服务名不同。
# =============================================================
set -uo pipefail

REPO_RAW="${REPO_RAW:-https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main}"

# 镜像链: 国内机器经常连不上 github.com, 单个镜像又不够稳, 所以按顺序全试一遍。
# 每个前缀后面直接拼 <相对路径> 即可, 结构一致。
#
# 顺序很讲究:
#   * ghproxy / gh-proxy 是**实时回源**的, 能立刻拿到刚推上去的版本
#   * jsdelivr 是 CDN **带缓存**的 —— 实测推完 commit 后它仍然返回旧文件,
#     加时间戳也绕不过去。所以只能放最后兜底。
#   * cfgithub 在部分机器上直接超时, 排中间。
REPO_MIRRORS=(
    "https://ghproxy.net/https://raw.githubusercontent.com/mi1314cat/mihomo--core/main"
    "https://gh-proxy.com/https://raw.githubusercontent.com/mi1314cat/mihomo--core/main"
    "${REPO_PROXY:-https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main}"
    "https://cdn.jsdelivr.net/gh/mi1314cat/mihomo--core@main"
    "https://fastly.jsdelivr.net/gh/mi1314cat/mihomo--core@main"
)

SRV_ROOT="${SRV_ROOT:-/root/catmi/mihomo}"
CLI_ROOT="${CLI_ROOT:-/root/catmi/mihomo-client}"

# install.sh 是独立下载执行的, 拿不到 src/lib/ui.sh, 所以这几行在本地再写一份。
# 颜色存**真正的 ESC 字节**: 存字面量时只有 printf "格式串"/echo -e 会解转义,
# printf '%s' "$CYAN" 会原样打印反斜杠, 颜色全废。
_esc() { printf '%b' "$1"; }
GREEN="$(_esc '\e[32m')"; RED="$(_esc '\e[31m')"; YELLOW="$(_esc '\e[33m')"
CYAN="$(_esc '\e[96m')"; MAGENTA="$(_esc '\e[95m')"
BOLD="$(_esc '\e[1m')"; RESET="$(_esc '\e[0m')"

ui_menu() { printf "  ${CYAN}%2s${RESET}. %s\n" "$1" "$2"; }

say()  { printf "${CYAN}[Info]${RESET} %s\n" "$1"; }
ok()   { printf "${GREEN}[OK]${RESET} %s\n" "$1"; }
err()  { printf "${RED}[Error]${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}[Warn]${RESET} %s\n" "$1"; }
die()  { err "$1"; exit 1; }

[[ "$(id -u)" == "0" ]] || die "请使用 root 权限运行"
command -v curl >/dev/null || die "缺少 curl"
command -v python3 >/dev/null || die "缺少 python3"

# Python 依赖: merge.py / validate.py / build_sub.py 都要 yaml
ensure_yaml() {
    python3 -c "import yaml" 2>/dev/null && return 0
    say "安装 Python 依赖 (PyYAML)..."
    if command -v apt-get >/dev/null; then
        apt-get install -y python3-yaml >/dev/null 2>&1
    elif command -v yum >/dev/null; then
        yum install -y python3-pyyaml >/dev/null 2>&1
    else
        python3 -m pip install --break-system-packages pyyaml >/dev/null 2>&1 \
            || python3 -m pip install pyyaml >/dev/null 2>&1
    fi
    python3 -c "import yaml" 2>/dev/null || die "PyYAML 安装失败"
    ok "PyYAML 就绪"
}

# 探测一次可用源, 结果记在 _SRC 里, 后面所有文件直接用它。
# 之前是每个文件都把整条镜像链重试一遍, 在只能走镜像的国内机器上
# 14 个文件要磨好几十分钟 —— 实测 4 分钟才下完 2 个。
_SRC=""
_pick_source() {
    [[ -n "$_SRC" ]] && return 0
    local base probe="$1"
    for base in "$REPO_RAW" "${REPO_MIRRORS[@]}"; do
        # 探测给 25 秒而不是 12 秒, 且每个源试两次。
        #
        # 实测: github.com 在那台机器上是连接超时而非拒绝,
        # 12 秒的探测窗口会把本来能用的镜像也判成"不通", 结果整条链全废、
        # 安装直接卡死。而 cdn.jsdelivr.net / ghproxy.net 实际都能通,
        # 只是首包慢 —— 给够时间 + 重试一次就下来了。
        local i
        for i in 1 2; do
            if curl -fsSL --max-time 25 "$base/$probe" -o /dev/null 2>/dev/null; then
                _SRC="$base"
                [[ "$base" == "$REPO_RAW" ]] || say "主站不通, 已选用镜像: $(echo "$base" | cut -d/ -f3)"
                return 0
            fi
        done
    done
    return 1
}

fetch() {  # fetch <远端相对路径> <本地路径>
    local rel="$1" dst="$2" base
    mkdir -p "$(dirname "$dst")"
    rm -f "$dst"
    _pick_source "README.md" || { err "所有下载源都不可用 (github.com 及各镜像)"; return 1; }
    # 下载超时 90 秒: 内核解压脚本之类的文件在慢网线上确实要这个量级
    for base in "$_SRC"; do
        if curl -fsSL --max-time 90 "$base/$rel" -o "$dst" 2>/dev/null && [[ -s "$dst" ]]; then
            return 0
        fi
    done
    # 选中的源中途挂了, 换一个再来
    _SRC=""
    for base in "$REPO_RAW" "${REPO_MIRRORS[@]}"; do
        if curl -fsSL --max-time 90 "$base/$rel" -o "$dst" 2>/dev/null && [[ -s "$dst" ]]; then
            _SRC="$base"
            [[ "$base" == "$REPO_RAW" ]] || say "切换到镜像: $(echo "$base" | cut -d/ -f3)"
            return 0
        fi
        rm -f "$dst"
    done
    return 1
}

# 兜底清单 —— 只在连 src/manifest.txt 都拉不下来时使用。
#
# 为什么不把清单直接写死在这里: 原先就是写死的, 后来新增了 cert.sh /
# preset.sh / cdn.sh 却没人记得同步, 于是全新安装缺了 8 个文件:
# 证书、推荐配置、CDN、防火墙四块功能全部失效, 而**面板照样能启动** ——
# 报错只在启动瞬间刷三行, 用户根本不会注意到, 直到点「添加节点」才发现
# 命令不存在。清单挪进仓库变成 src/manifest.txt 之后, 它和代码在同一个
# 提交里, 改代码时更容易被一起改到, 而且能用 tools/check_manifest.sh 卡住。
_FALLBACK_FILES=(
    "src/lib/cdn.sh" "src/lib/cert.sh" "src/lib/core_mgmt.sh"
    "src/lib/dl_route.sh" "src/lib/env.sh" "src/lib/envtool.py"
    "src/lib/fw.sh" "src/lib/lan_dispatch.sh" "src/lib/merge.py"
    "src/lib/portcheck.sh" "src/lib/preset.sh" "src/lib/rules_bind.sh"
    "src/lib/simple_proxy.sh" "src/lib/ui.sh" "src/lib/validate.py"
    "src/lib/webui.sh"
    "src/conf/AnyTLS.sh" "src/conf/Reality.sh" "src/conf/TUIC.sh"
    "src/conf/Trojan.sh" "src/conf/VLESS.sh" "src/conf/XRevise.sh"
    "src/conf/all.sh" "src/conf/hysteria2.sh" "src/conf/nginx_apply.py"
    "src/share/build_sub.py" "src/share/share.sh" "src/share/share_server.py"
    "src/core_install.sh" "src/server.sh" "src/client.sh"
)

fetch_repo() {  # 把面板需要的文件拉到本地
    local base="$1"
    local files=()
    local mf="$base/src/manifest.txt"

    # 清单优先走仓库 —— 它是唯一真源
    local tmp; tmp="$(mktemp)"
    if fetch "src/manifest.txt" "$tmp" 2>/dev/null; then
        local line
        while IFS= read -r line; do
            line="${line%%#*}"                    # 去注释
            line="$(printf '%s' "$line" | tr -d '[:space:]')"
            [[ -n "$line" ]] && files+=("$line")
        done < "$tmp"
    fi
    rm -f "$tmp"

    if [[ ${#files[@]} -eq 0 ]]; then
        say "清单拉取失败, 使用内置兜底清单"
        files=("${_FALLBACK_FILES[@]}")
    fi

    local f
    for f in "${files[@]}"; do
        fetch "$f" "$base/$f" || { err "下载失败: $f"; return 1; }
    done
    chmod +x "$base/src/core_install.sh" 2>/dev/null
    [[ -f "$base/src/server.sh" ]] && chmod +x "$base/src/server.sh" 2>/dev/null
    [[ -f "$base/src/client.sh" ]] && chmod +x "$base/src/client.sh" 2>/dev/null
    ok "面板文件已就绪 ($base/src, ${#files[@]} 个文件)"
}

# 与面板 print_title 同款: 左边一个空格 + %-42s + 一个空格, 框才是方的。
# 之前左边写了两个空格右边不写, 右边框线被顶掉一格, 看着就是歪的。
banner() {
    printf "${MAGENTA}${BOLD}╔══════════════════════════════════════════════╗\n"
    printf "║ %-42s ║\n" "$1"
    printf "╚══════════════════════════════════════════════╝${RESET}\n"
}

install_server() {
    banner "服务端安装"
    ensure_yaml
    fetch_repo "$SRV_ROOT" || die "面板文件下载失败"

    INSTALL_DIR="$SRV_ROOT" SERVICE_NAME="mihomo" \
        bash "$SRV_ROOT/src/core_install.sh" || die "内核安装失败"

    # 服务端需要的依赖
    [[ -f "$SRV_ROOT/src/server.sh" ]] || {
        fetch "src/server.sh" "$SRV_ROOT/src/server.sh" || die "服务端面板下载失败"
    }
    chmod +x "$SRV_ROOT/src/server.sh"

    ok "服务端安装完成"
    printf '\n  启动面板:\n    \033[1mbash %s/src/server.sh\033[0m\n\n' "$SRV_ROOT"
}

install_client() {
    banner "客户端安装"
    ensure_yaml
    fetch_repo "$CLI_ROOT" || die "面板文件下载失败"

    INSTALL_DIR="$CLI_ROOT" SERVICE_NAME="mihomo-client" \
        bash "$CLI_ROOT/src/core_install.sh" || die "内核安装失败"

    # fetch_repo 已经按清单拉过了, 这里只是兜底 (与服务端那段保持一致)
    [[ -f "$CLI_ROOT/src/client.sh" ]] || {
        fetch "src/client.sh" "$CLI_ROOT/src/client.sh" || die "客户端面板下载失败"
    }
    chmod +x "$CLI_ROOT/src/client.sh"

    # 客户端的配置目录名与服务端一致 (core_install.sh 统一用 conf/)
    ok "客户端安装完成"
    printf '\n  启动面板:\n    \033[1mbash %s/src/client.sh\033[0m\n\n' "$CLI_ROOT"
}

menu() {
    banner "mihomo--core 安装"
    ui_menu 1 "安装服务端 (建节点、发分享)"
    ui_menu 2 "安装客户端 (拉节点、出网)"
    ui_menu 3 "两边都装"
    ui_menu 0 "退出"
    printf "\n  ${CYAN}请选择${RESET}: "
    local c; read -r c
    case "$c" in
        1) install_server ;;
        2) install_client ;;
        3) install_server; install_client ;;
        0) exit 0 ;;
        *) err "无效选项: $c" ;;
    esac
}

# ---------- 进面板 ----------
#
# install.sh 同时是"装"和"进面板"的入口 —— 用户的其它脚本直接调它进面板,
# 所以这里统一收尾: 装完(发现内核已存在而跳过下载也一样)直接拉起面板。
#
# 为什么放在 install.sh 而不是 core_install.sh: 面板脚本 (server.sh /
# client.sh) 是 core_install **之后**才下载的, 从 core_install 里拉会找不到
# 文件 —— 那正是最容易在旧机器上踩到的顺序问题。
enter_panel() {
    local root="$1" script="$2"
    [[ -f "$root/src/$script" ]] || { err "面板未就绪, 请手动运行 $root/src/$script"; return 0; }
    printf '\n'
    bash "$root/src/$script"
}

case "${1:-}" in
    server) install_server; enter_panel "$SRV_ROOT" server.sh ;;
    client) install_client; enter_panel "$CLI_ROOT" client.sh ;;
    all)    install_server; install_client; enter_panel "$CLI_ROOT" client.sh ;;
    *)      menu ;;
esac
