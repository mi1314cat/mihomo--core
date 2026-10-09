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

# ---------- 本机代理兜底 ----------
#
# 客户端的机器常常"网络不行", 这是安装路径上最先撞到的墙。三道防线:
#   1. 用户显式设过 http_proxy/https_proxy -> curl 原生就认, 不用管
#   2. 镜像链 (上面那 6 条)
#   3. 本机自己开着代理, 但代理只写在 /etc/profile.d 下 —— 而
#      `bash <(curl ...)`、ssh 非登录 shell、cron 都不加载那个文件。
#      于是"明明开着代理, 却一路直连到超时"。
#
# 扫端口本质是猜 —— 实测有过扫描表"命中"四个端口、结果全是别的服务。
# 所以按可靠性从高到低找, 扫端口放最后:
#   1. 显式环境变量
#   2. 本项目自己的 mixed-port (我们亲手写下去的值, 最对得上)
#   3. 系统配置文件里真写着的 (/etc/profile.d、~/.bashrc、git config)
#   4. 手动输入
#   5. 端口扫描
_PROXY=""

# 从本项目自己的配置里读 mixed-port
_own_mixed_port() {
    local root="$1" f p
    f="$root/settings.env"
    if [[ -f "$f" ]]; then
        p=$(sed -n 's/^PORT_MIXED=["]*\([0-9]\{2,5\}\)["]*$/\1/p' "$f" 2>/dev/null | head -1)
        [[ -n "$p" && "$p" != "0" ]] && { printf '%s' "$p"; return 0; }
    fi
    f="$root/conf/config.yaml"
    if [[ -f "$f" ]]; then
        p=$(sed -n 's/^mixed-port:[[:space:]]*\([0-9]\{2,5\}\)$/\1/p' "$f" 2>/dev/null | head -1)
        [[ -n "$p" && "$p" != "0" ]] && { printf '%s' "$p"; return 0; }
    fi
    return 1
}

# 从系统配置文件里读真实写过的代理
_sys_file_proxies() {
    local f v
    for f in /etc/environment /etc/profile /etc/wgetrc /etc/curlrc \
             "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.curlrc" \
             /etc/profile.d/*.sh; do
        [[ -f "$f" ]] || continue
        v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?\(https\?\|all\)_proxy[[:space:]]*=[[:space:]]*["'"'"']\?\([^"'"'"'[:space:]]\+\)["'"'"']\?.*/\3/ip' "$f" 2>/dev/null | head -1)
        [[ -n "$v" ]] && printf '%s\n' "$v"
    done
    v=$(git config --global --get http.proxy 2>/dev/null)
    [[ -n "$v" ]] && printf '%s\n' "$v"
    return 0
}

_normalize_proxy() {
    local v="$1"
    v="${v// /}"
    [[ -z "$v" ]] && return 1
    # 端口必须 <=65535 —— 只按位数判会放过 99999 这种不存在的端口
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        (( v >= 1 && v <= 65535 )) && { printf 'http://127.0.0.1:%s' "$v"; return 0; }
        return 1
    fi
    if [[ "$v" =~ ^([^:/]+):([0-9]+)$ ]]; then
        (( BASH_REMATCH[2] >= 1 && BASH_REMATCH[2] <= 65535 )) || return 1
        printf 'http://%s:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0
    fi
    [[ "$v" =~ ^(https?|socks5h?|socks4a?):// ]] && { printf '%s' "$v"; return 0; }
    return 1
}

_proxy_works() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
           --proxy "$1" https://api.github.com/ 2>/dev/null)
    [[ "$code" =~ ^[1-4] ]]
}

# 扫端口: 最后的兜底
_scan_ports() {
    local host port code
    for host in 127.0.0.1 localhost; do
        for port in 7890 7891 7897 10808 10809 8080 8118 1080 1081 20171 33211 9444; do
            (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null || continue
            exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
            _proxy_works "http://$host:$port" && printf '%s\n' "http://$host:$port"
        done
    done
    return 0
}

# 找代理。找到就设 _PROXY, 返回 0
_find_proxy() {
    # 用户显式设过 -> 不打扰, curl 自己会认
    [[ -n "${https_proxy:-}${http_proxy:-}${HTTPS_PROXY:-}${HTTP_PROXY:-}" ]] && return 0

    local -a cand=()
    local p mp
    # 2. 本项目自己的 mixed-port
    for p in "$CLI_ROOT" "$SRV_ROOT"; do
        mp="$(_own_mixed_port "$p" 2>/dev/null)" || continue
        cand+=("http://127.0.0.1:$mp")
    done
    # 3. 系统配置文件
    while IFS= read -r p; do [[ -n "$p" ]] && cand+=("$p"); done < <(_sys_file_proxies)

    # 逐个验证
    for p in "${cand[@]}"; do
        if _proxy_works "$p"; then
            _PROXY="$p"
            say "直连全不通, 但读到本机代理: $_PROXY (改走它)"
            return 0
        fi
    done

    # 4. 手动输入 (只在交互时问)
    if [[ -t 0 ]]; then
        printf "  直连与镜像都不通。若你知道本机代理端口, 现在可以填 (直接回车=跳过): " >&2
        local man; read -r man || man=""
        if [[ -n "${man// /}" ]]; then
            local nv; nv="$(_normalize_proxy "$man")" || nv=""
            if [[ -n "$nv" ]] && _proxy_works "$nv"; then
                _PROXY="$nv"
                say "使用手动指定的代理: $_PROXY"
                return 0
            fi
            err "这个代理连不通 (拿 api.github.com 试过)"
        fi
    fi

    # 5. 扫端口
    while IFS= read -r p; do
        [[ -n "$p" ]] && { _PROXY="$p"; say "扫描发现可用代理: $_PROXY"; return 0; }
    done < <(_scan_ports)
    return 1
}

# curl 参数: 有代理就带上
_cargs() { [[ -n "$_PROXY" ]] && printf '%s' "--proxy $_PROXY"; }

_pick_source() {
    [[ -n "$_SRC" ]] && return 0
    local base probe="$1" i
    # 第一轮: 直连 / 镜像
    for base in "$REPO_RAW" "${REPO_MIRRORS[@]}"; do
        # 探测给 25 秒而不是 12 秒, 且每个源试两次。
        #
        # 实测: github.com 在那台机器上是连接超时而非拒绝,
        # 12 秒的探测窗口会把本来能用的镜像也判成"不通", 结果整条链全废、
        # 安装直接卡死。而 cdn.jsdelivr.net / ghproxy.net 实际都能通,
        # 只是首包慢 —— 给够时间 + 重试一次就下来了。
        for i in 1 2; do
            if curl -fsSL --max-time 25 $(_cargs) "$base/$probe" -o /dev/null 2>/dev/null; then
                _SRC="$base"
                [[ "$base" == "$REPO_RAW" ]] || say "主站不通, 已选用镜像: $(echo "$base" | cut -d/ -f3)"
                return 0
            fi
        done
    done
    # 第二轮: 按可靠性找本机代理, 带着它把整条链再走一遍
    if _find_proxy; then
        for base in "$REPO_RAW" "${REPO_MIRRORS[@]}"; do
            if curl -fsSL --max-time 25 $(_cargs) "$base/$probe" -o /dev/null 2>/dev/null; then
                _SRC="$base"
                say "已选用: $(echo "$base" | cut -d/ -f3) (经代理 $_PROXY)"
                return 0
            fi
        done
    fi
    return 1
}

fetch() {  # fetch <远端相对路径> <本地路径>
    local rel="$1" dst="$2" base
    mkdir -p "$(dirname "$dst")"
    rm -f "$dst"
    _pick_source "README.md" || {
        err "所有下载通道都不可用 (github.com + 各镜像 + 本机代理)"
        err "可先在本机开好代理再重跑; 或用有网的机器下载后 scp 过来"
        return 1
    }
    # 下载超时 90 秒: 内核解压脚本之类的文件在慢网线上确实要这个量级
    for base in "$_SRC"; do
        if curl -fsSL --max-time 90 -H 'Cache-Control: no-cache' $(_cargs) "$base/$rel" -o "$dst" 2>/dev/null && [[ -s "$dst" ]]; then
            return 0
        fi
    done
    # 选中的源中途挂了, 换一个再来
    _SRC=""
    for base in "$REPO_RAW" "${REPO_MIRRORS[@]}"; do
        if curl -fsSL --max-time 90 -H 'Cache-Control: no-cache' $(_cargs) "$base/$rel" -o "$dst" 2>/dev/null && [[ -s "$dst" ]]; then
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
    "src/lib/cdn.sh" "src/lib/cert.sh" "src/lib/cert_sync.sh" "src/lib/core_mgmt.sh"
    "src/lib/dl_route.sh" "src/lib/dns.sh" "src/lib/dns_edit.py"
    "src/lib/env.sh" "src/lib/envtool.py"
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
        1) install_server; enter_panel "$SRV_ROOT" server.sh ;;
        2) install_client; enter_panel "$CLI_ROOT" client.sh ;;
        3) install_server; install_client; enter_panel "$CLI_ROOT" client.sh ;;
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
# ==================== 进面板前的自动更新 ====================
#
# 目标: 每次 `bash <(curl .../install.sh)` 进面板时自动比对 GitHub, 有新版就
#       静默更新, 不用再手动去菜单里找「更新脚本」。
#
# ★ 铁律: **任何情况下都不能把人挡在面板外面。**
#   fetch() 网络失败会 die 直接退出整个脚本 —— 自动更新绝不能走那条路:
#   GitHub 连不上只是"这次没更新成", 用本地版本继续才是对的。
#   状态码: 0=已更新  10=已是最新  2=取不到(网络/仓库)  3=取到了但落地失败
#
# ★ 为什么放在 install.sh 而不是 server.sh/client.sh 里:
#   进入面板前更新完, 紧接着执行的 `bash src/server.sh` 拿到的**就是新代码**。
#   若放在面板自己里面, bash 早已把脚本读进内存, 更新完界面上仍毫无变化 ——
#   用户会判定成"更新没用"。实测就是这个症状。

# 取版本标记 (src/VERSION, 内容哈希, 只有 12 字节)。
#
# ★ 这是整个自动更新里唯一的**必经网络请求**, 正常情况下就这一次。
#   原来的做法是进面板前把 34 个文件全下下来比一遍, 实测要 7~17 秒,
#   慢一点的网络就是好几分钟 —— 面板卡在"检测到已安装, 直接进入面板"不动,
#   看着像面板坏了。
#   先用一个 12 字节的探针判断, 真的有新版再去下全部。
#
# 超时给得很短 (默认 8 秒): 连不上就跳过更新, 照常进面板。
# 让人多等十几秒去换一个"可能根本没更新", 不划算。
_probe_version() {   # 远端版本号取不到返回非 0
    local t out; t=$(mktemp) || return 1
    out=$(curl -fsSL --max-time "${_VERSION_PROBE_TIMEOUT:-8}" -H 'Cache-Control: no-cache' \
            $(_cargs) "${REPO_RAW}/src/VERSION" -o "$t" 2>/dev/null) || true
    if [[ -s "$t" ]]; then
        tr -d '[:space:]' < "$t"; rm -f "$t"; return 0
    fi
    rm -f "$t"; return 1
}

# 取新版到临时目录, 只返回状态码, 从不退出。
fetch_soft() {
    local tmp; tmp="$(mktemp -d)" || return 2
    local f n=0
    local mf="$tmp/manifest.txt"
    if ! fetch "src/manifest.txt" "$mf" 2>/dev/null; then
        rm -rf "$tmp"; return 2
    fi
    local files=() line
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [[ -n "$line" ]] && files+=("$line")
    done < "$mf"
    (( ${#files[@]} > 0 )) || { rm -rf "$tmp"; return 2; }

    for f in "${files[@]}"; do
        mkdir -p "$tmp/$(dirname "$f")"
        fetch "$f" "$tmp/$f" >/dev/null 2>&1 || { rm -rf "$tmp"; return 3; }
        n=$((n+1))
    done
    printf '%s\n' "$tmp"
    return 0
}

# 更新前备份。静默改自己的代码必须留退路 —— 万一新版有问题, 没有备份就只能
# 靠用户手工抢救。
backup_scripts() {
    local root="$1"
    local b="$root/backup/scripts-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$b" 2>/dev/null || { printf ''; return 1; }
    cp -rf "$root/src" "$b/" 2>/dev/null
    printf '%s' "$b"
}

restore_scripts() {
    local b="$1" root="$2"
    [[ -n "$b" && -d "$b/src" ]] || return 1
    cp -rf "$b/src/." "$root/src/" 2>/dev/null || return 1
    return 0
}

# 更新后的脚本必须全部通过语法检查, 否则立刻回滚。
# 有语法错误的面板会直接起不来, 而用户此刻正要进面板 —— 那等于把门锁死了。
scripts_sane() {
    local root="$1" f
    for f in "$root"/src/*.sh "$root"/src/conf/*.sh "$root"/src/lib/*.sh; do
        [[ -f "$f" ]] || continue
        bash -n "$f" 2>/dev/null || return 1
    done
    local py
    for py in "$root"/src/lib/*.py "$root"/src/conf/*.py "$root"/src/share/*.py; do
        [[ -f "$py" ]] || continue
        python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$py" 2>/dev/null || return 1
    done
    return 0
}

# 自动更新。0=已更新  10=已是最新  其它=没更新成 (调用方照常进面板)
auto_update() {
    local root="$1" rc=0 t0=$SECONDS tmp
    [[ -d "$root/src" ]] || return 2

    # ---- 第一步: 12 字节探针, 绝大多数情况到这就结束了 ----
    local cur rem
    cur=$(head -1 "$root/src/VERSION" 2>/dev/null | tr -d '[:space:]')
    if rem=$(_probe_version) && [[ -n "$rem" ]]; then
        if [[ "$cur" == "$rem" ]]; then
            return 10          # 已是最新, 一个文件都不用下
        fi
        say "面板有新版本 (${cur:-未知} → $rem), 正在更新…"
    else
        warn "暂时连不上 GitHub, 跳过更新 (不影响使用)"
        return 2
    fi

    tmp=$(fetch_soft) || rc=$?
    case $rc in
        2) warn "暂时连不上 GitHub, 这次跳过更新 (不影响使用)"; return 2 ;;
        3) warn "新版文件没取全, 已保留本地版本"; return 1 ;;
    esac
    [[ -d "$tmp" ]] || { warn "更新失败, 已保留本地版本"; return 1; }

    # 内容一致就别白覆盖一遍 (每次进面板都重写文件 + 建备份, 用户会以为在改动)。
    #
    # ⚠ 必须**逐个清单文件**比对, 不能 diff -rq 整个 src 目录:
    #   src/manifest.txt 是清单自己, 不会列进自己, 于是 diff 永远报
    #   "Only in src: manifest.txt" —— 每次进面板都判定为"有更新",
    #   白跑一遍下载还建一个备份目录。同理用户自己加的本地文件也会被算进去。
    local same=1 f2
    while IFS= read -r f2; do
        f2="${f2%%#*}"
        f2="$(printf '%s' "$f2" | tr -d '[:space:]')"
        [[ -n "$f2" ]] || continue
        cmp -s "$tmp/$f2" "$root/$f2" || { same=0; break; }
    done < "$tmp/manifest.txt"
    if (( same )); then
        rm -rf "$tmp"; return 10
    fi

    local bak; bak=$(backup_scripts "$root")
    [[ -n "$bak" ]] || warn "备份目录创建失败, 继续更新 (出问题请手动回滚)"

    cp -rf "$tmp/src/." "$root/src/" || { rm -rf "$tmp"; warn "覆盖失败, 已保留本地版本"; return 1; }
    chmod +x "$root"/src/*.sh "$root"/src/conf/*.sh "$root"/src/lib/*.sh 2>/dev/null
    rm -rf "$tmp"

    if ! scripts_sane "$root"; then
        warn "新版脚本没通过语法检查, 已自动回滚"
        restore_scripts "$bak" "$root" && ok "已回滚到更新前的版本"
        return 1
    fi
    ok "已自动更新到最新版本  [$((SECONDS - t0))s]"
    [[ -n "$bak" ]] && say "旧版本备份: $bak"
    return 0
}

enter_panel() {
    local root="$1" script="$2"
    [[ -f "$root/src/$script" ]] || { err "面板未就绪, 请手动运行 $root/src/$script"; return 0; }
    printf '\n'
    # 进面板前先自动更新 —— 这样紧接着执行的 server.sh/client.sh 拿到的
    # 就是新代码, 当场生效 (见 auto_update 上面的说明)。
    auto_update "$root" || true
    bash "$root/src/$script"
}

# ---------- 已装检测: 这条命令的心智模型是"进面板", 不是"安装" ----------
#
# 对齐 SB install.sh 的 existing():
#
#     if systemctl is-active sing-box && [[ -x "$SRV_ROOT/sing-box.sh" ]]; then
#         existing; exit $?        # 装过的机器再跑一次 -> 整个安装菜单直接跳过
#     fi
#
# 它那条一键命令的意思是"**进入面板**"。第一次跑是装完进面板, 第一百次跑是
# 直接进面板 —— 用户永远不需要记住"我这边到底是客户端还是服务端"。
#
# 我们之前没这一步: 每次跑都先甩一个"1. 服务端 / 2. 客户端"的安装菜单,
# 用户明明已经装好了客户端, 还是得先回答一个和当下意图无关的问题, 然后
# 打完安装日志就退出 (menu() 当时没接 enter_panel) —— 一点都不丝滑。
#
# 我们比 SB 多一侧 (服务端 + 客户端), 所以规则按"装了几侧"分:
#   只装了一侧 -> 直接进那一侧   (用户不用回忆自己在哪边)
#   两侧都装了 -> 让用户选进哪边 (不猜, 猜错比多问一句更烦)
#   一侧都没装 -> 走安装菜单
_panel_ready() { [[ -f "$1/src/$2" ]]; }

smart_entry() {
    local s=0 c=0
    _panel_ready "$SRV_ROOT" server.sh && s=1
    _panel_ready "$CLI_ROOT" client.sh && c=1

    if (( s && c )); then
        banner "mihomo--core"
        say "本机已装: 服务端 + 客户端"
        ui_menu 1 "进入服务端面板 (建节点、发分享)"
        ui_menu 2 "进入客户端面板 (拉节点、出网)"
        ui_menu 3 "重新安装 / 安装另一端"
        ui_menu 0 "退出"
        printf "\n  ${CYAN}请选择${RESET}: "
        local k; read -r k
        case "$k" in
            1) enter_panel "$SRV_ROOT" server.sh ;;
            2) enter_panel "$CLI_ROOT" client.sh ;;
            3) menu ;;
            0) exit 0 ;;
            *) err "无效选项: $k" ;;
        esac
    elif (( c )); then
        say "检测到已安装客户端, 直接进入面板"
        enter_panel "$CLI_ROOT" client.sh
    elif (( s )); then
        say "检测到已安装服务端, 直接进入面板"
        enter_panel "$SRV_ROOT" server.sh
    else
        menu
    fi
}

# 面板里的"切换到另一端"会以 `install.sh client` / `install.sh server` 回来,
# 所以这两条子命令必须既能装也能进 —— 装完直接进, 已装则直接进。
case "${1:-}" in
    server)  install_server; enter_panel "$SRV_ROOT" server.sh ;;
    client)  install_client; enter_panel "$CLI_ROOT" client.sh ;;
    all)     install_server; install_client; enter_panel "$CLI_ROOT" client.sh ;;
    install) menu ;;        # 想强制走安装菜单时用 (不给就按已装情况智能进)
    *)       smart_entry ;;
esac
