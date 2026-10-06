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

GREEN="\033[32m"; RED="\033[31m"; CYAN="\033[36m"
MAGENTA="\033[35m"; BOLD="\033[1m"; RESET="\033[0m"
say()  { printf "${CYAN}[信息]${RESET} %s\n" "$1"; }
ok()   { printf "${GREEN}[成功]${RESET} %s\n" "$1"; }
err()  { printf "${RED}[错误]${RESET} %s\n" "$1"; }
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

fetch_repo() {  # 把面板需要的文件拉到本地
    local base="$1"
    local files=(
        "src/lib/env.sh" "src/lib/envtool.py" "src/lib/merge.py" "src/lib/validate.py"
        "src/conf/Reality.sh" "src/conf/VLESS.sh" "src/conf/Trojan.sh"
        "src/conf/hysteria2.sh" "src/conf/TUIC.sh" "src/conf/AnyTLS.sh"
        "src/conf/all.sh" "src/conf/XRevise.sh"
        "src/share/share.sh" "src/share/share_server.py" "src/share/build_sub.py"
        "src/core_install.sh"
    )
    local f
    for f in "${files[@]}"; do
        fetch "$f" "$base/$f" || { err "下载失败: $f"; return 1; }
    done
    chmod +x "$base/src/core_install.sh" 2>/dev/null
    ok "面板文件已就绪 ($base/src)"
}

banner() {
    printf "${MAGENTA}${BOLD}╔══════════════════════════════════════════════╗\n"
    printf "║  %-42s ║\n" "$1"
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

    fetch "src/client.sh" "$CLI_ROOT/src/client.sh" || die "客户端面板下载失败"
    chmod +x "$CLI_ROOT/src/client.sh"

    # 客户端的配置目录名与服务端一致 (core_install.sh 统一用 conf/)
    ok "客户端安装完成"
    printf '\n  启动面板:\n    \033[1mbash %s/src/client.sh\033[0m\n\n' "$CLI_ROOT"
}

menu() {
    banner "mihomo--core 安装"
    echo "1) 安装服务端 (建节点、发分享)"
    echo "2) 安装客户端 (拉节点、出网)"
    echo "3) 两边都装"
    printf "0) 退出\n"
    printf "\n请选择: "
    local c; read -r c
    case "$c" in
        1) install_server ;;
        2) install_client ;;
        3) install_server; install_client ;;
        0) exit 0 ;;
        *) die "无效选项" ;;
    esac
}

case "${1:-}" in
    server) install_server ;;
    client) install_client ;;
    all)    install_server; install_client ;;
    *)      menu ;;
esac
