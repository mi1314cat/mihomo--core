#!/usr/bin/env bash
# =============================================================
# mihomo 内核安装 (服务端 / 客户端共用)
#
# 相对旧版 mihomo-down.sh 的改动:
#   * 校验 sha256, 防止下载到半截文件还照样安装
#   * 生成基础 conf/config.yaml —— 旧版从不生成, 新装完直接起不来
#   * 启动失败自动回滚到上一个能跑的内核
#   * 保留 x86_64 的 v3 / compatible 指令集自动选择
# =============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/root/catmi/mihomo}"
SERVICE_NAME="${SERVICE_NAME:-mihomo}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GITHUB_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
MIRROR_API="https://cfgithub.gw2333.workers.dev/https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

# 必须写 stderr: 这些函数会在 $(...) 里被调用, 走 stdout 会污染返回值
say()  { printf "  %s\n" "$1" >&2; }
warn() { printf "\033[33m  ⚠ %s\033[0m\n" "$1" >&2; }
die()  { printf "\033[31m[错误]\033[0m %s\n" "$1" >&2; exit 1; }

# 默认值是服务端路径, 但这个脚本服务端客户端共用。目标位置已经是文件时
# 早失败并说人话 —— 原来的报错是 mkdir: cannot create directory
# '/root/catmi/mihomo': Not a directory, 完全看不出是路径撞了文件。
# (实测 客户端 上 /root/catmi/mihomo 是个 ELF 二进制, 属于另一个项目)
if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
    die "$INSTALL_DIR 已存在且不是目录
  本脚本是安装内核的, 客户端请用:
    bash <(curl -fsSL <仓库>/install.sh) client
  或显式指定安装目录:
    INSTALL_DIR=/root/catmi/mihomo-client bash core_install.sh"
fi

# ---------- 本机代理探测 ----------
# 借鉴 参考实现 的 sb_proxy_scan。curl 本身支持 http_proxy/https_proxy,
# 但很多机器只把代理写在 /etc/profile.d/ 下, 而 ssh host 'cmd'、面板内执行、
# cron 都不加载那个文件 —— 结果本机明明开着代理, 下载却走直连直到超时。
# 踩过的坑: raw.githubusercontent.com 不可达导致一键安装失败,
# 而该机本地 7890 就有可用代理, 脚本却完全没去问。
# 原则:
#   1. 用户显式设过 http_proxy/https_proxy → 原样用, 不干预
#   2. 否则扫常见端口, 逐个真发请求验证; 多个可用时列出让用户选
#   3. 非交互 (无 TTY) 不提问, 静默用第一个
#   4. 一个都没有 → 直连, 不打扰
# 只用于下载路径。
_PROXY_CAND=()
scan_proxy() {
    _PROXY_CAND=()
    [[ -n "${https_proxy:-}${http_proxy:-}${HTTPS_PROXY:-}${HTTP_PROXY:-}" ]] && return 0
    local host port code
    for host in 127.0.0.1 localhost; do
        for port in 7890 7891 7897 10808 10809 8080 8118 1080 1081 20171 33211 9444; do
            (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null || continue
            exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
                   --proxy "http://$host:$port" https://api.github.com/ 2>/dev/null)
            # 1xx~4xx 都算可用 (GitHub 会 3xx 重定向 / 403 限流); 000 才是不可用
            [[ "$code" =~ ^[1-4] ]] && _PROXY_CAND+=("http://$host:$port")
        done
    done
}
# =============================================================
# 下载代理: 先"读确定的地方", 再"猜端口"
# =============================================================
#
# 需求来源: 允许手动指定代理端口。
#
# 扫端口本质是猜, 而且有实测反例: 扫描表 (7890/7891/1080/8080...) 在某台机器上
# "命中"了 10808/10809/8080/1080 四个端口, 但那四个是**别的服务**, 真实代理
# 根本不在表里。**扫端口本质是猜**, 只能当最后一道。
#
# 所以按可靠性从高到低排:
#   1. 显式环境变量            —— 用户亲手设的, curl 原生就认
#   2. 本项目自己的配置         —— 我们亲手写下的 mixed-port, 就是我们自己
#                                 内核正在听的那个口, 100% 对得上
#   3. 系统配置文件里真写着的    —— /etc/profile.d/*、~/.bashrc、git config
#                                 这些是**持久化过的**真实设置, 不是猜
#   4. 手动输入                —— 用户知道自己用的什么, 永远该给这个口子
#   5. 端口扫描                —— 兜底
#
# 第 2 条特别值得强调: 客户端装好之后, "本机代理"往往就是**它自己**。那我们还
# 猜什么端口? 直接读自己写下去的值就行。

# 从本项目自己的配置里读 mixed-port。$1 = 根目录
_own_mixed_port() {
    local root="$1" f p
    # settings.env 优先: 那是面板在端口冲突顺延后写下的**最终值**
    f="$root/settings.env"
    if [[ -f "$f" ]]; then
        p=$(sed -n 's/^PORT_MIXED=["]*\([0-9]\{2,5\}\)["]*$/\1/p' "$f" 2>/dev/null | head -1)
        [[ -n "$p" && "$p" != "0" ]] && { printf '%s' "$p"; return 0; }
    fi
    # 退而读生成好的 config.yaml
    f="$root/conf/config.yaml"
    if [[ -f "$f" ]]; then
        p=$(sed -n 's/^mixed-port:[[:space:]]*\([0-9]\{2,5\}\)$/\1/p' "$f" 2>/dev/null | head -1)
        [[ -n "$p" && "$p" != "0" ]] && { printf '%s' "$p"; return 0; }
    fi
    return 1
}

# 从系统配置文件里读真实写过的代理 (只认明确赋值的行)
_sys_file_proxies() {
    local f v
    for f in /etc/environment /etc/profile /etc/wgetrc /etc/curlrc \
             "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.curlrc"; do
        [[ -f "$f" ]] || continue
        # 取 = 或空格赋值的 http_proxy / https_proxy, 且行首不是注释
        v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?\(https\?\|all\)_proxy[[:space:]]*=[[:space:]]*["'"'"']\?\([^"'"'"'[:space:]]\+\)["'"'"']\?.*/\3/ip' "$f" 2>/dev/null | head -1)
        [[ -n "$v" ]] && printf '%s\n' "$v"
    done
    # /etc/profile.d/*.sh 是最常见的"只写在这里"的位置
    for f in /etc/profile.d/*.sh; do
        [[ -f "$f" ]] || continue
        v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?\(https\?\|all\)_proxy[[:space:]]*=[[:space:]]*["'"'"']\?\([^"'"'"'[:space:]]\+\)["'"'"']\?.*/\3/ip' "$f" 2>/dev/null | head -1)
        [[ -n "$v" ]] && printf '%s\n' "$v"
    done
    # git 的 http.proxy
    v=$(git config --global --get http.proxy 2>/dev/null)
    [[ -n "$v" ]] && printf '%s\n' "$v"
    return 0
}

# 把用户输入规整成 curl 能用的 URL。接受:
#   7890                  -> http://127.0.0.1:7890
#   127.0.0.1:7890        -> http://127.0.0.1:7890
#   socks5://1.2.3.4:1080 -> 原样
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

# 真发一个请求验证代理确实能用 (1xx~4xx 都算通; 000 才是不可用)
_proxy_works() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
           --proxy "$1" https://api.github.com/ 2>/dev/null)
    [[ "$code" =~ ^[1-4] ]]
}

# 汇总候选 (按可靠性排序), 结果放 _PCAND
_collect_proxy_candidates() {
    _PCAND=()
    local p
    # 1. 显式环境变量
    for p in "${https_proxy:-}" "${http_proxy:-}" "${HTTPS_PROXY:-}" "${HTTP_PROXY:-}"; do
        [[ -n "$p" ]] && _PCAND+=("$p")
    done
    # 2. 本项目自己的 mixed-port (客户端 + 服务端两处都看)
    for p in "${CLI_ROOT:-/root/catmi/mihomo-client}" "${SRV_ROOT:-/root/catmi/mihomo}"; do
        local mp; mp="$(_own_mixed_port "$p" 2>/dev/null)" || continue
        _PCAND+=("http://127.0.0.1:$mp")
    done
    # 3. 系统配置文件
    while IFS= read -r p; do
        [[ -n "$p" ]] && _PCAND+=("$p")
    done < <(_sys_file_proxies)
    # 去重, 保序
    local -a uniq=()
    local seen="|"
    for p in "${_PCAND[@]}"; do
        [[ "$seen" == *"|$p|"* ]] && continue
        seen="$seen$p|"; uniq+=("$p")
    done
    _PCAND=("${uniq[@]}")
}

# ---------------------------------------------------------------
# 读面板里设的「下载通道 → 内核下载」
# ---------------------------------------------------------------
#
# 面板的内核管理会 `bash core_install.sh` —— 那是**独立进程**, source 不到
# src/lib/dl_route.sh。所以这里直接读那个文件。
#
# 这是本项目"必然有两份实现"的又一处 (引导/独立脚本不能 source 库),
# 所以读取口径由 tools/check_mirrors.sh 机械比对, 不靠"记得同步"。
#
# 文件格式: 一行一个 `scope=mode`
#     global=local
#     kernel=direct
#
# 输出: curl --proxy 可用的值 (空 = 直连); 返回 0 表示"文件里明确设过",
#       返回 1 表示"没设过, 交给 pick_proxy 现场探测"。
_route_proxy_from_file() {
    local f="${DL_ROUTE_FILE:-${INSTALL_DIR:-/root/catmi/mihomo}/.dl-route}"
    [[ -f "$f" ]] || return 1
    local k g
    k=$(sed -n 's/^kernel=//p' "$f" 2>/dev/null | tail -1)
    # 分项 unset -> 跟随全局
    if [[ -z "$k" || "$k" == "unset" ]]; then
        g=$(sed -n 's/^global=//p' "$f" 2>/dev/null | tail -1)
        k="${g:-unset}"
    fi
    [[ -z "$k" || "$k" == "unset" ]] && return 1   # 没设过 -> 交给 pick_proxy

    case "$k" in
        direct) printf ''; return 0 ;;
        local)
            # mixed-port 从 settings.env / config.yaml 读, 读不到才退 7890
            local mp="" root="${INSTALL_DIR:-/root/catmi/mihomo}"
            mp=$(sed -n 's/^PORT_MIXED=["]*\([0-9]\+\)["]*$/\1/p' "$root/settings.env" 2>/dev/null | head -1)
            [[ "$mp" =~ ^[0-9]+$ ]] || \
                mp=$(sed -n 's/^mixed-port:[[:space:]]*\([0-9]\+\)$/\1/p' "$root/conf/config.yaml" 2>/dev/null | head -1)
            [[ "$mp" =~ ^[0-9]+$ ]] || mp=7890
            printf 'http://127.0.0.1:%s' "$mp"; return 0 ;;
        custom)
            cat "${f}.custom" 2>/dev/null; return 0 ;;
        *) return 1 ;;
    esac
}

# 选一个代理打印到 stdout; 没有可用代理返回 1
pick_proxy() {
    # 面板里明确设过通道 -> 以它为准, 不再现场探测/追问。
    # 用户既然在面板里做过选择, 就不该在这里被再问一遍, 更不该被忽略。
    local _pfx
    if _pfx=$(_route_proxy_from_file); then
        [[ -n "$_pfx" ]] && say "使用面板设定的下载通道: $_pfx"
        printf '%s' "$_pfx"; return 0
    fi
    # 非交互: 有环境变量就用, 没有就静默直连 (与 SB 一致)
    if [[ ! -t 0 ]]; then
        [[ -n "${https_proxy:-}${http_proxy:-}" ]] && { printf '%s' "${https_proxy:-$http_proxy}"; return 0; }
        _collect_proxy_candidates
        local q
        for q in "${_PCAND[@]}"; do _proxy_works "$q" && { printf '%s' "$q"; return 0; }; done
        return 1
    fi

    _collect_proxy_candidates
    # 扫端口只作为**追加**的兜底候选, 不抢占前面的可靠来源
    scan_proxy
    local p
    for p in "${_PROXY_CAND[@]}"; do _PCAND+=("$p"); done

    # 逐个验证, 只留真能用的
    local -a ok=()
    for p in "${_PCAND[@]}"; do _proxy_works "$p" && ok+=("$p"); done
    _PCAND=("${ok[@]}")

    ((${#_PCAND[@]})) || return 1

    say "检测到可用代理 (内核下载将走其中之一):"
    local i=1
    for p in "${_PCAND[@]}"; do say "  $i) $p"; i=$((i+1)); done
    say "  m) 手动输入 (推荐: 填你自己知道的端口)"
    say "  0) 不用代理, 直连"
    printf "  用哪个? [默认 1]: " >&2
    local c; read -r c
    c="${c// /}"

    if [[ "$c" == [mM] ]]; then
        printf "  输入代理 (端口如 7890 / 地址如 127.0.0.1:7890 / 完整如 socks5://1.2.3.4:1080): " >&2
        local man; read -r man
        local nv; nv="$(_normalize_proxy "$man")" || { say "格式认不出来, 已改为直连"; return 1; }
        if _proxy_works "$nv"; then
            printf '%s' "$nv"; return 0
        fi
        say "这个代理连不通 (拿 api.github.com 试过), 已改为直连"
        return 1
    fi
    [[ -z "$c" ]] && c=1
    [[ "$c" =~ ^[0-9]+$ ]] || return 1
    (( c >= 1 && c <= ${#_PCAND[@]} )) || return 1
    printf '%s' "${_PCAND[$((c-1))]}"
}

[[ "$(id -u)" == "0" ]] || die "请使用 root 权限运行"

printf "\033[35m\033[1m╔══════════════════════════════════════════════╗\n"
printf "║  Mihomo 内核安装                                 ║\n"
printf "╚══════════════════════════════════════════════╝\033[0m\n"
printf "  下载不通? 可把内核手动传到:\n"
printf "    \033[36m%s\033[0m\n" "${MIHOMO_KERNEL_DIR:-${INSTALL_DIR%/*}/mihomo-kernels}"
printf "  (支持 .gz / .zip / 裸二进制, 会自动认架构并校验)\n"

# ---------- 架构 ----------
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "不支持的架构: $(uname -m)" ;;
esac

SUFFIX=""
if [[ "$ARCH" == "amd64" ]]; then
    FLAGS=$(grep -m1 '^flags' /proc/cpuinfo)
    if grep -qw avx2 <<<"$FLAGS" && grep -qw bmi2 <<<"$FLAGS" && grep -qw fma <<<"$FLAGS"; then
        SUFFIX="-v3"; say "CPU 支持 x86_64-v3, 使用高性能版"
    else
        SUFFIX="-compatible"; say "CPU 不支持 v3, 使用兼容版"
    fi
fi
say "架构: $ARCH${SUFFIX}"

# ---------- 版本 ----------
# 依次尝试: GitHub API → 镜像 API → 302 重定向 → git ls-remote(含镜像)。
# 每一步都带上已探测到的本地代理: 很多机器 api.github.com 通但 github.com 不通,
# 不带代理时中间几步纯属白跑。
resolve_tag() {
    local t="" u raw=""
    local -a cargs=()

      # 面板的「版本管理 → 安装指定版本」走这里: 指定了 tag 就不再查最新,
      # 省掉一次 API 往返, 也避免用户选的版本被自动更新顶掉。
      # 注意输出**不带 v 前缀** —— 下面拼的是 .../releases/download/${LATEST_TAG},
      # GitHub 两种都收, 但保持与 resolve_tag 原有行为一致更不容易出错。
      if [[ -n "${MIHOMO_FORCE_TAG:-}" ]]; then
          printf '%s' "${MIHOMO_FORCE_TAG#v}"
          return
      fi
    [[ -n "${PX:-}" ]] && cargs=(--proxy "$PX")

    t=$(curl -fsSL --max-time 20 "${cargs[@]}" "$GITHUB_API" 2>/dev/null | grep -m1 tag_name | cut -d '"' -f4) || true
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    say "  API 不可用, 走镜像 API"

    t=$(curl -fsSL --max-time 20 "${cargs[@]}" "$MIRROR_API" 2>/dev/null | grep -m1 tag_name | cut -d '"' -f4) || true
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    say "  镜像 API 不可用, 走重定向"

    t=$(curl -fsSLI --max-time 20 "${cargs[@]}" -o /dev/null -w '%{redirect_url}' \
        "https://github.com/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
        | sed -n 's#.*/tag/##p') || true
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    say "  重定向不可用, 走 git ls-remote"

    for u in "https://github.com/MetaCubeX/mihomo.git" \
             "https://ghproxy.net/https://github.com/MetaCubeX/mihomo.git"; do
        if [[ -n "${PX:-}" ]]; then
            raw=$(git -c http.proxy="$PX" ls-remote --tags --refs "$u" 2>/dev/null)
        else
            raw=$(git ls-remote --tags --refs "$u" 2>/dev/null)
        fi
        t=$(printf '%s' "$raw" | awk '{print $2}' | sed 's#refs/tags/##' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
        [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    done
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------- 本地内核文件 ----------
# 用户手动上传的内核放到一个固定目录, 装之前/装坏了都能拿来用。
#
# 为什么要有这个: 内核下载是整个安装流程里唯一依赖外网的一步。实测
# () 一台机器上 GitHub 主站不通、5 个镜像里只有 ghproxy.net 勉强
# 能通但只有 11KB/s, 20.8MB 要 31 分钟。这时候"让用户自己下一个包传上来"
# 比继续折腾网络可靠得多。
#
# 支持两种来源:
#   MIHOMO_LOCAL_BIN  直接指定文件 (原有行为, 优先)
#   内核上传目录      $INSTALL_DIR/../mihomo-kernels/
#                     也可以是环境变量 MIHOMO_KERNEL_DIR
# 两种都支持 .gz / .zip / 裸二进制。
KERNEL_DIR="${MIHOMO_KERNEL_DIR:-${INSTALL_DIR%/*}/mihomo-kernels}"

# 判断文件是不是 mihomo 内核: 看 ELF 头 + 能不能自报版本。
# 只查 ELF 头是不够的 —— 随便一个 amd64 二进制都能通过, 装完才发现跑不了。
_mihomo_probe() {   # $1=可执行文件
    local f="$1" hdr
    [[ -f "$f" ]] || return 1
    [[ -s "$f" ]] || return 1
    hdr=$(head -c 4 "$f" 2>/dev/null)
    [[ "$hdr" == $'\x7fELF' ]] || return 1
    # 真跑一下 —— 这是唯一可靠的判据。
    #
    # 必须**先整体捕获再匹配**, 不能写成 "$f" -v 2>/dev/null | grep -qi mihomo:
    # grep -q 一命中就退出, 上游 mihomo 写管道时收到 SIGPIPE (退出码 141),
    # 而本脚本开头是 `set -euo pipefail`, 管道因此被判为失败。
    #
    # 致命的是这是竞态 —— 取决于内核把版本行写完的快慢, 同一台机器时灵时不灵。
    # 实测 上连跑 12 次, 管道式挂了 7 次 (全是 141), 捕获式 12/12。
    #
    # 影响的不只是这里: _kernel_from_dir (上传目录扫描) 也调它, 于是
    # "手动上传内核" 在 服务端 上约六成概率被误判成"目录里没有可用的内核"。
    # 这种时灵时不灵比一直坏更难查 —— 用户传了、提示说没有、又传一次。
    out="$("$f" -v 2>/dev/null)" || return 1
    [[ "$out" =~ [Mm][Ii][Hh][Oo][Mm][Oo] ]] || return 1
    return 0
}

# 解压出可执行文件 (支持 .gz / .zip / 裸文件)
_kernel_extract() {  # $1=源文件  $2=目标路径
    local src="$1" dst="$2" base
    base=$(basename "$src")
    case "${base,,}" in
        *.gz)
            say "  解压 gzip..."
            gunzip -c "$src" > "$dst" 2>/dev/null || { warn "gzip 解压失败: $src"; return 1; }
            ;;
        *.zip)
            say "  解压 zip..."
            if ! command -v unzip >/dev/null; then
                warn "本机没有 unzip, 请先安装 (apt install unzip) 或上传 .gz / 裸文件"
                return 1
            fi
            # zip 里可能套一层目录 (mihomo-linux-arm64/mihomo), 递归找那个二进制
            local inner
            inner=$(unzip -Z1 "$src" 2>/dev/null | grep -E '^[^/]+/mihomo$|^mihomo$' | head -1)
            if [[ -n "$inner" ]]; then
                unzip -p "$src" "$inner" > "$dst" 2>/dev/null \
                    || { warn "从 zip 中提取 $inner 失败"; return 1; }
            else
                unzip -p "$src" > "$dst" 2>/dev/null \
                    || { warn "zip 中找不到 mihomo 可执行文件"; return 1; }
            fi
            ;;
        *)
            cp -f "$src" "$dst" || return 1
            ;;
    esac
    chmod +x "$dst" 2>/dev/null
    return 0
}

# 在上传目录里挑一个可用的内核。挑不到就返回 1。
_kernel_from_dir() {
    local dir="$1" f cand
    [[ -d "$dir" ]] || return 1
    # 排除自己正在写出的 .part
    shopt -s nullglob
    for f in "$dir"/*; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.part ]] && continue
        cand="$f"
        # 压缩包先解到临时位置再验
        case "${f,,}" in
            *.gz|*.zip)
                _kernel_extract "$f" "$TMP/kernel_probe" 2>/dev/null || continue
                cand="$TMP/kernel_probe"
                ;;
        esac
        if _mihomo_probe "$cand"; then
            printf '%s' "$f"
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

# ---------- 已装且可用 → 直接跳过 ----------
#
# 对齐 SB 的 install.sh:
#     if [[ ! -x "$CLI_ROOT/core/sing-box" ]]; then ... 安装 ... fi
# 有就不装。
#
# 为什么需要: install.sh 兼任「装」和「进面板」两个角色 (用户的其它脚本
# 直接调它进面板), 所以会被反复执行。之前每次都重下一遍内核 —— 一是慢,
# 二是网络不通时 install.sh 直接 die, 明明本机已经有能跑的内核却进不去面板。
#
# 判据用 _mihomo_probe (真跑一次取版本) 而不是只看 -x: 架构不对的文件同样
# 有执行权限, 那种情况必须继续往下走去装对的, 不能在这里糊弄过去。
# MIHOMO_SKIP_IF_PRESENT=0 表示"无条件重装"(面板的"重装内核"菜单项用的)。
# 默认 1 = 见到可用内核就跳过 (对齐 SB 的 `if [[ ! -x core ]]`)。
if [[ "${MIHOMO_SKIP_IF_PRESENT:-1}" != "0" \
   && -z "${MIHOMO_LOCAL_BIN:-}" && -x "$INSTALL_DIR/mihomo" ]] \
   && _mihomo_probe "$INSTALL_DIR/mihomo"; then
    say "检测到本机已有可用内核, 跳过内核安装"
    say "  版本: $("$INSTALL_DIR/mihomo" -v 2>/dev/null | head -1)"
    say "  位置: $INSTALL_DIR/mihomo"
    say "  需要换版本请用面板: 服务管理 → 手动上传内核"
    _SKIP_CORE=1
else
    _SKIP_CORE=0
fi

LOCAL_BIN="${MIHOMO_LOCAL_BIN:-}"
LOCAL_SRC=""

if [[ -n "$LOCAL_BIN" && ! -x "$LOCAL_BIN" ]]; then
    # 指了路径但没有执行权限 —— 很可能是压缩包, 或者忘了 chmod
    if [[ -f "$LOCAL_BIN" ]]; then
        chmod +x "$LOCAL_BIN" 2>/dev/null || true
    fi
    [[ -x "$LOCAL_BIN" ]] || {
        # 试试当压缩包解
        if _kernel_extract "$LOCAL_BIN" "$TMP/mihomo"; then
            _mihomo_probe "$TMP/mihomo" || die "解包后的文件不是可用的 mihomo 内核: $LOCAL_BIN"
            say "已从压缩包提取内核: $LOCAL_BIN"
            cp -f "$TMP/mihomo" "$TMP/mihomo.work"
            LOCAL_SRC="$TMP/mihomo.work"
        else
            die "指定的文件不可用: $LOCAL_BIN
  (它必须是一个可执行的 mihomo, 或 .gz / .zip 压缩包)"
        fi
    }
fi

# 上传目录里的内核 —— 用户手动传包的标准位置
if [[ -z "$LOCAL_BIN" && -d "$KERNEL_DIR" ]]; then
    warn "检测到内核上传目录: $KERNEL_DIR"
    if pick_from_dir=$(_kernel_from_dir "$KERNEL_DIR"); then
        LOCAL_SRC="$pick_from_dir"
        say "使用上传的内核: $pick_from_dir"
        _kernel_extract "$pick_from_dir" "$TMP/mihomo" \
            || die "从上传文件提取内核失败: $pick_from_dir"
    else
        warn "目录里没有可用的 mihomo 内核 (已跳过)"
        warn "  放入 .gz / .zip / 裸二进制均可, 建议放最新的一个"
        warn "  目录: $KERNEL_DIR"
    fi
fi

# 内核获取整段: 只在"本机还没装出可用内核"时才走。
# 已经装好的情况在上面就短路返回 _SKIP_CORE=1, 不重复下载。
if [[ "$_SKIP_CORE" -eq 0 ]]; then
if [[ -n "$LOCAL_BIN" && -x "$LOCAL_BIN" ]]; then
    say "使用指定内核: $LOCAL_BIN"
    say "  版本: $("$LOCAL_BIN" -v 2>/dev/null | head -1)"
    # 架构自检: 架构不对的话, 装完 systemctl start 才炸, 现场很难查
    if ! "$LOCAL_BIN" -v >/dev/null 2>&1; then
        die "内核无法在本机执行 (架构不匹配?)
  本机架构: $(uname -m)  需要: $ARCH${SUFFIX:-}
  上传目录里的内核要选对架构, 或换 $KERNEL_DIR 下的其它文件"
    fi
    cp -f "$LOCAL_BIN" "$TMP/mihomo"
    chmod +x "$TMP/mihomo"
elif [[ -n "$LOCAL_SRC" ]]; then
    _mihomo_probe "$TMP/mihomo" || die "上传的内核无法在本机执行 (架构不匹配?)
  本机架构: $(uname -m)"
    say "内核可执行: $("$TMP/mihomo" -v | head -1)"
else

say "查询最新版本..."
# 代理要提前选好: resolve_tag 也在下载段之前, 它挂掉连版本号都拿不到,
# 后面 5 个镜像连拼 URL 的机会都没有。
PX=""; PX=$(pick_proxy) || PX=""
LATEST_TAG=$(resolve_tag)
LATEST_TAG="${LATEST_TAG//[$'\r\n']/}"
[[ -n "$LATEST_TAG" ]] || die "获取版本失败
  本机可能无法访问 GitHub。三种办法任选其一:
    1) 已有可用内核:
         MIHOMO_LOCAL_BIN=/path/to/mihomo bash core_install.sh
    2) 本机有代理, 显式指定后重跑:
         https_proxy=http://127.0.0.1:7890 bash core_install.sh
    3) 开通能访问 GitHub 的网络后重试"
say "版本: $LATEST_TAG"

BASE="mihomo-linux-${ARCH}${SUFFIX}-${LATEST_TAG}"
DL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}"

say "下载 ${BASE}.gz"
# 镜像链: 面板文件有 5 条 (install.sh 的 REPO_MIRRORS), 内核原来只有 cfgithub
# 一条, 而它实测在部分机器上直接超时 —— 面板装好了、内核下不来, 卡在最后一步。
# 排序同 install.sh 的结论: 实时回源优先, 带缓存的 CDN 兜底。
DL_MIRRORS=(
    "https://ghproxy.net/${DL}"
    "https://gh-proxy.com/${DL}"
    "${REPO_PROXY:-https://cfgithub.gw2333.workers.dev/${DL}}"
    "https://cdn.jsdelivr.net/gh/MetaCubeX/mihomo@${LATEST_TAG}"
    "https://fastly.jsdelivr.net/gh/MetaCubeX/mihomo@${LATEST_TAG}"
)
# 所有源都写同一个 .part, 失败即清, 成功才改名 —— 避免半截文件被当成内核。
DL_OK=0
_dl_try() {   # $1=url; 代理走全局 PX
    local -a args=(-L --retry 2 --retry-delay 2 --fail
                   --connect-timeout 15 --speed-time 60 --speed-limit 1024
                   -o "$TMP/mihomo.gz.part")
    [[ -n "${PX:-}" ]] && args+=(--proxy "$PX")
    # --speed-limit 1024: 低于 1KB/s 持续 60s 就判定这条源废了。
    # 原来的 --max-time 300 在慢速源上是硬伤: 20.8MB @11KB/s 要 31 分钟,
    # 300s 必然掐断 —— 即使网络"可用"也装不完 (实测 客户端 退出码 124)。
    curl "${args[@]}" "$1" 2>/dev/null
}

if _dl_try "$DL/${BASE}.gz"; then
    [[ -n "$PX" ]] && say "  经代理 $PX 下载成功"
    DL_OK=1
else
    rm -f "$TMP/mihomo.gz.part"
    say "  GitHub 主站${PX:+ (经代理 $PX)} 不可用, 依次尝试镜像..."
fi
if (( ! DL_OK )); then
    for base in "${DL_MIRRORS[@]}"; do
        say "  试镜像: $(printf '%s' "$base" | cut -d/ -f3)"
        if _dl_try "${base}/${BASE}.gz"; then
            say "  镜像可用"; DL_OK=1; break
        fi
        rm -f "$TMP/mihomo.gz.part"
    done
fi
if (( DL_OK )); then
    mv -f "$TMP/mihomo.gz.part" "$TMP/mihomo.gz"
    [[ -s "$TMP/mihomo.gz" ]] || die "下载到的内核文件为空, 请重试"
else
    die "内核下载失败 (GitHub 主站 + 本地代理 + 5 个镜像均不可达)
  本机可能无法访问 GitHub。三种办法任选其一:
    1) 手动上传 (最可靠, 推荐):
         把 mihomo 内核传到 $KERNEL_DIR 再重跑本脚本
         支持 .gz / .zip / 裸二进制, 脚本会自动认架构并校验
         本机需要的架构: linux-${ARCH}${SUFFIX}
           (下载地址: https://github.com/MetaCubeX/mihomo/releases/latest)
    2) 本机已有可用内核, 直接指定:
         MIHOMO_LOCAL_BIN=/path/to/mihomo bash core_install.sh
    3) 本机有代理, 显式指定后重跑:
         https_proxy=http://127.0.0.1:7890 bash core_install.sh"
fi

# ---------- 校验 ----------
# Mihomo 官方并未为每个 .gz 发布 .sha256, 因此这里是"有就验, 没有就跳过",
# 但只要拿到就必须对上 —— 防止下到半截文件还照样安装。
EXPECT=""
# 校验和同样要能走代理/镜像: 只查主站的话, 走镜像下到内核的机器会
# "拿不到校验和"从而跳过校验, 正好在最需要校验的场景失去保护。
for u in "${DL}/${BASE}.gz.sha256" \
         "${DL_MIRRORS[0]}/${BASE}.gz.sha256" \
         "${DL_MIRRORS[1]}/${BASE}.gz.sha256" \
         "${DL_MIRRORS[2]}/${BASE}.gz.sha256"; do
    if [[ -n "${PX:-}" ]]; then
        curl -fsSL --max-time 15 --proxy "$PX" -o "$TMP/sum.txt" "$u" 2>/dev/null || continue
    else
        curl -fsSL --max-time 15 -o "$TMP/sum.txt" "$u" 2>/dev/null || continue
    fi
    EXPECT=$(grep -oiE '[0-9a-f]{64}' "$TMP/sum.txt" 2>/dev/null | head -1)
    [[ -n "$EXPECT" ]] && break
done
if [[ -n "$EXPECT" ]]; then
    ACTUAL=$(sha256sum "$TMP/mihomo.gz" | cut -d' ' -f1)
    [[ "$EXPECT" == "$ACTUAL" ]] || die "sha256 校验失败
  期望: $EXPECT
  实际: $ACTUAL"
    say "sha256 校验通过"
else
    # 没有官方校验和时, 用"能解压 + 能自报版本"作为最低限度的完整性检查
    say "官方未提供校验和, 改用解压与冒烟测试兜底"
fi

gunzip -c "$TMP/mihomo.gz" > "$TMP/mihomo" || die "解压失败"
fi

# ---------- 冒烟测试 ----------
chmod +x "$TMP/mihomo"
"$TMP/mihomo" -v >/dev/null 2>&1 || die "内核无法执行, 架构或指令集不匹配"
say "内核可执行: $("$TMP/mihomo" -v | head -1)"
fi

# ---------- 目录 ----------
mkdir -p "$INSTALL_DIR/conf/config.d" "$INSTALL_DIR/conf/certs" "$INSTALL_DIR/out"

# ---------- geo 数据库 ----------
# 客户端规则会用 GEOSITE/GEOIP, 但这些 .dat/.metadb 文件常常已经存在于机器上
# (别的 mihomo / sing-box 装过)。找出来复制到配置目录, 省掉一次 GitHub 下载
# —— 很多机器根本访问不了 GitHub。
#
# 搜索范围要宽: 别的 mihomo 实例的 conf 目录里通常就有全套。
# 踩过的坑: 原实现只搜 /root/catmi 顶层, 找到 geoip.metadb
# 却漏了 GeoSite.dat (它在 mihomo-client/conf/ 下)。而生成的配置里带着
# geosite 规则 → mihomo 启动时去下载 GeoSite 下不到 → **卡在
# "Start initial configuration" 永不 bind 端口**, systemd 却报 active、
# 面板报"运行中"。所以缺 geosite 不是"降级", 是"服务起不来"。
GEO_IP_NAMES=(geoip.metadb GeoIP.dat country.mmdb)
GEO_SITE_NAMES=(GeoSite.dat geosite.dat)

_geo_search_dirs() {
    local d
    for d in "$INSTALL_DIR/../conf" "$INSTALL_DIR/conf" \
             /root/catmi/mihomo/conf /root/catmi/mihomo-client/conf \
             /root/catmi/*/conf /opt/*/conf /etc/mihomo /etc/sing-box; do
        [[ -d "$d" ]] && printf '%s\n' "$d"
    done
    printf '%s\n' /root/catmi /usr/local/share/mihomo /usr/share/mihomo "$INSTALL_DIR/.."
}

_geo_seed_one() {
    local name="$1" d f
    [[ -f "$INSTALL_DIR/conf/$name" ]] && return 0
    while IFS= read -r d; do
        f="$d/$name"
        [[ -f "$f" && -s "$f" ]] || continue
        cp -f "$f" "$INSTALL_DIR/conf/$name" 2>/dev/null || continue
        say "复用已有 geo 数据库: $name (来自 $f)"
        return 0
    done < <(_geo_search_dirs)
    return 1
}

# 配置里是否真的引用了 geo 数据库。
# 检查对象是 config.d 全部片段 + config.yaml, 因为规则可能写在任一处
# (客户端规则通常在片段里, 服务端基础配置里也可能有)。
_geo_rules_used() {
    grep -rqiE '(^|[^a-z])(geosite|geoip)[\s:,-]|GEOIP|GEOSITE' \
        "$INSTALL_DIR"/conf/config.d/*.yaml "$INSTALL_DIR/conf/config.yaml" 2>/dev/null
}

seed_geodata() {
    local name have_ip=0 have_site=0
    for name in "${GEO_IP_NAMES[@]}"; do
        _geo_seed_one "$name" && { have_ip=1; break; }
    done
    for name in "${GEO_SITE_NAMES[@]}"; do
        _geo_seed_one "$name" && { have_site=1; break; }
    done
    (( have_ip && have_site )) && return 0

    # 关键: 先看**配置里到底用不用** geo 规则。
    #
    # 不看就警告是误报 —— 实测 服务端 13 个节点全是
    # Reality / 自签 TLS, 配置里一条 geosite 规则都没有, 却被警告
    # "缺 GeoSite 会导致 mihomo 卡在启动阶段"。用户看到这种与本机无关的
    # 警告只会怀疑面板坏了, 真正的危险（配置确实要用却缺文件）反而被淹没。
    #
    # 所以顺序必须是: 先确认要用 → 确认没有 → 才告警。
    if ! _geo_rules_used; then
        say "本机配置未使用 GEOSITE/GEOIP 规则, 无需 geo 数据库"
        return 0
    fi

    local missing=()
    (( have_ip ))   || missing+=("geoip (GEOIP 规则用)")
    (( have_site )) || missing+=("geosite (geosite 规则用)")
    warn "缺少 geo 数据库: ${missing[*]}"
    # 后果要说准: 缺 geosite 时 mihomo 启动阶段会尝试联网下载, 下载不通就
    # 一直卡住不 bind 端口, 表现为"服务运行中但没有代理口"。
    warn "规则仍会写进配置, mihomo 启动时会尝试联网下载这些文件。"
    warn "若本机访问不了 GitHub, mihomo 会卡在启动阶段、不监听任何端口。"
    warn "手动放一份即可 (机器上任意一份有效的都行):"
    warn "  cp <任意mihomo实例>/conf/GeoSite.dat  $INSTALL_DIR/conf/"
    warn "  cp <任意mihomo实例>/conf/geoip.metadb $INSTALL_DIR/conf/"
    warn "或删掉配置里的 GEOSITE/GEOIP 规则。"
}

# 注意: seed_geodata 在**基础配置生成之后**才调用 (见文件末尾)。
# _geo_rules_used 要读 config.d/*.yaml 和 config.yaml 才能判断"配置是否真的
# 用到 geo 规则", 提前调用的话那两个文件都还不存在, 判断必然是"没用"——
# 于是客户端那套真的含 geosite:cn,private 的规则永远收不到告警,
# 正好漏掉最需要提醒的场景。

# ---------- 基础配置 ----------
CONF="$INSTALL_DIR/conf/config.yaml"
if [[ ! -f "$CONF" ]]; then
    say "生成基础配置 $CONF"
    cat > "$CONF" <<'EOF'
# mihomo--core 基础配置
#
# 服务端模式: 节点写在 conf/config.d/<proto>-<NN>.yaml,
# 每次增删都会由 merge.py 合并进本文件的 listeners。
# 不要手工改 listeners, 会被覆盖。

mixed-port: 0
allow-lan: false
mode: rule
log-level: info
ipv6: true
external-controller: 127.0.0.1:9090
secret: ""

profile:
  store-selected: true

listeners: []

proxy-groups: []

rules:
  - MATCH,DIRECT
EOF
fi

# ---------- 替换内核 (保留旧版以便回滚) ----------
# 跳过时不能动内核: 老内核正跑着, 无谓地 cp 一份 .bak 再原样写回去,
# 只会凭空多出个 mihomo.bak, 让人以为"刚才换过版本"。
OLD=""
if [[ "$_SKIP_CORE" -eq 0 ]]; then
    if [[ -x "$INSTALL_DIR/mihomo" ]]; then
        OLD="$INSTALL_DIR/mihomo.bak"
        cp -f "$INSTALL_DIR/mihomo" "$OLD"
    fi
    cp -f "$TMP/mihomo" "$INSTALL_DIR/mihomo"
    chmod +x "$INSTALL_DIR/mihomo"
fi

# ---------- systemd ----------
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/mihomo -d $INSTALL_DIR/conf
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=3
LimitNOFILE=1048576

StandardOutput=append:$INSTALL_DIR/mihomo.log
StandardError=append:$INSTALL_DIR/error-mihomo.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

# ---------- 启动 + 回滚 ----------
say "启动服务..."
if systemctl restart "$SERVICE_NAME"; then
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        printf "\033[32m[成功]\033[0m 内核安装并启动成功\n"
    else
        printf "\033[33m[警告]\033[0m 进程已退出, 正在回滚\n" >&2
        [[ -n "$OLD" ]] && cp -f "$OLD" "$INSTALL_DIR/mihomo" && systemctl restart "$SERVICE_NAME"
        journalctl -u "$SERVICE_NAME" -n 15 --no-pager >&2 || true
    fi
else
    printf "\033[33m[警告]\033[0m 启动失败, 回滚到上一个内核\n" >&2
    [[ -n "$OLD" ]] && cp -f "$OLD" "$INSTALL_DIR/mihomo" && systemctl restart "$SERVICE_NAME"
    journalctl -u "$SERVICE_NAME" -n 15 --no-pager >&2 || true
fi

printf '\n  安装目录: %s\n  配置目录: %s\n  节点目录: %s/conf/config.d\n' \
    "$INSTALL_DIR" "$INSTALL_DIR/conf" "$INSTALL_DIR"

# 面板脚本名按本机实际存在的那一个来定 —— 服务端是 server.sh, 客户端是
# client.sh, 而这个脚本两边共用。
#
# 这里原来写的是 `bash <(curl -fsSL <仓库地址>/install.sh)` —— 一个从没被
# 填上的占位符, 用户照着敲只会得到一条无效命令。改成指本机面板: 不依赖网络、
# 不依赖仓库地址, 而且一定指向"这个目录下真正存在的那个面板"。
# 按**这次装的是哪一端**决定, 不是"目录里恰好存在哪个文件"。
# 原判据是「client.sh 存在就用 client.sh」, 而服务端目录里两个面板都在,
# 于是服务端装完提示的是客户端面板命令 —— 用户敲进去进的是另一端的界面。
_panel="server.sh"
[[ "${ROLE:-server}" == "client" || "${CLI_ROLE:-}" == "1" ]] && _panel="client.sh"
[[ -f "$INSTALL_DIR/src/server.sh" ]] || _panel="client.sh"
printf '  管理面板: bash %s/src/%s\n\n' "$INSTALL_DIR" "$_panel"

# ---------- geo 数据库 (放在最后) ----------
# 必须等配置全部生成完再跑: _geo_rules_used 要读到真实的规则才能判断该不该
# 告警。在配置生成前调用, 判断永远是"没用", 客户端那套含 geosite:cn,private
# 的规则就永远收不到提示 —— 而那正是会让 mihomo 卡在启动阶段的场景。
seed_geodata

# ---------- 公共分享服务 (放在最后, 且失败不影响安装) ----------
#
# ★ 分享的存储与生命周期归**公共基础服务** proxy-share-service (独立项目),
#   M / SB / X 共用。这里只做"检查 → 不存在才装 → 启动", 装过就是空操作,
#   所以后装的内核不会重复安装、不会重新占端口、不会覆盖已有分享数据。
#
#   直接调 share_client.py, **不 source share.sh** —— 这个脚本在安装阶段跑,
#   那些 UI 函数还没就位; 依赖它们只会得到一个静默失效的检查。
#
#   失败**绝不能**让安装失败 —— 分享不是 M 的核心功能, 没有它 M 照样能用。
#   装不上只提示, 用户之后在面板「分享链接管理 → 7」里还能重试。
_pss_client="$INSTALL_DIR/src/share/share_client.py"
if [[ "${ROLE:-server}" != "client" && -f "$_pss_client" ]]; then
    printf '  公共分享服务: ' >&2
    # 端口可能因端口回避而不是 9443, 所以取它**打印出来的值**, 不猜。
    if _pss_port=$(python3 "$_pss_client" ensure 2>/dev/null) && [[ -n "$_pss_port" ]]; then
        printf '已就绪 (端口 %s)\n' "$_pss_port" >&2
    else
        printf '未就绪 (不影响使用; 面板「分享链接管理 → 7」可重试)\n' >&2
    fi
fi
