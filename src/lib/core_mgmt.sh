#!/usr/bin/env bash
# =============================================================
# mihomo--core · 内核与面板版本管理 (core_mgmt.sh)
#
# 三件事, 边界与 参考实现 一致 —— 那套是用户长期打磨过的:
#   1. 内核:   安装/重装 / 更新 / 版本管理 / 卸载(保留配置)
#   2. 脚本:   自更新 (与内核更新**分开**, 互不牵连)
#   3. 状态:   当前版本 / 最新版本 对比
#
# 为什么把"脚本更新"和"内核更新"分开:
#   面板挂了还能 curl 一次重装, 内核挂了面板根本起不来显示错误 —— 两者的
#   失败后果和修复手段完全不同, 捆在一起意味着更新面板时顺手把内核也换了,
#   出问题连是哪一层引起的都分不清。SB 在这点上是对的。
# =============================================================

# ---------- 版本查询 ----------

# 远端最新版本。只取 tag, 拿不到就返回空 (调用方决定要不要问用户)。
# 远端最新版本。
# 取最新**不要**依赖 /releases/latest —— 它和列表端点一样会限流,
# 还得再兜一层 git ls-remote (该写法在 core_install.sh 里已验证可靠)。
core_latest_tag() {
    local url raw tag
    for url in \
        "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
        "https://gh-proxy.com/https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    do
        raw=$(curl -fsSL --max-time 15 "$url" 2>/dev/null) || continue
        tag=$(printf '%s' "$raw" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]+"' \
              | head -1 | sed 's/.*"\(v[^"]*\)"/\1/')
        [[ -n "$tag" ]] && { printf '%s\n' "$tag"; return 0; }
    done
    core_list_tags 2>/dev/null | tail -1
}

# 远端可选版本列表 (给"安装指定版本"用)。
#
# 三级兜底的顺序是按实测可靠度排的:
#   1. GitHub API     最直接, 但 /releases 列表端点限流比 /latest 严得多,
#                     服务端 这类数据中心 IP 上实测直接 403
#   2. gh-proxy       转发 GitHub, 实测可用
#   3. git ls-remote  不走 API, 只读 git 协议, 实测最稳 (core_install.sh 同款)
#
# 每级都是**先捕获再判断**, 不写成 `... | head -30 && return 0`:
# head 拿不到输入也返回 0, 于是第一个源失败时会带着空结果提前 return,
# 后面的源根本没机会试 —— 这个坑踩过一次。
core_list_tags() {
    local url raw out
    for url in \
        "https://api.github.com/repos/MetaCubeX/mihomo/releases?per_page=30" \
        "https://gh-proxy.com/https://api.github.com/repos/MetaCubeX/mihomo/releases?per_page=30"
    do
        raw=$(curl -fsSL --max-time 20 "$url" 2>/dev/null) || continue
        out=$(printf '%s' "$raw" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]+"' \
              | sed 's/.*"\(v[^"]*\)"/\1/' | head -30)
        [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    done
    raw=$(git ls-remote --tags --refs https://github.com/MetaCubeX/mihomo.git 2>/dev/null) \
        || raw=$(git ls-remote --tags --refs \
                    https://ghproxy.net/https://github.com/MetaCubeX/mihomo.git 2>/dev/null) || return 1
    out=$(printf '%s' "$raw" | awk '{print $2}' | sed 's#refs/tags/##' \
          | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -30)
    [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    return 1
}

# 本机当前版本 (只取 vX.Y.Z, 去掉构建信息)
core_current_version() {
    local bin="$1"
    [[ -x "$bin" ]] || { printf '未安装\n'; return 1; }
    "$bin" -v 2>/dev/null | head -1 \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# 版本号比较: a 比 b 新返回 0
core_ver_gt() {
    local a="${1#v}" b="${2#v}"
    [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" && "$a" != "$b" ]]
}

# ---------- 内核操作 ----------

# 装/重装内核。走 core_install.sh, 它内部已有: 上传目录优先 / 镜像链 /
# 校验和 / 解压冒烟测试 / 失败回滚。
#
# 传 MIHOMO_SKIP_IF_PRESENT=0 强制重装 —— core_install.sh 默认见到可用内核
# 就跳过 (对齐 SB 的 `if [[ ! -x core ]]`), 但"重装"这个菜单项要的是
# 无条件重来。
core_do_install() {
    local root="$1" svc="$2"
    MIHOMO_SKIP_IF_PRESENT=0 \
    INSTALL_DIR="$root" SERVICE_NAME="$svc" \
        bash "$root/src/core_install.sh"
}

core_do_update() {
    local root="$1" svc="$2"
    print_info "当前: $(core_current_version "$root/mihomo")"
    local latest
    latest=$(core_latest_tag) || { print_error "查不到最新版本 (网络不通?)"; return 1; }
    print_info "最新: $latest"
    local cur; cur=$(core_current_version "$root/mihomo")
    if [[ "$cur" == "$latest" ]]; then
        print_ok "已是最新, 无需更新"
        return 0
    fi
    if ! core_ver_gt "$latest" "$cur"; then
        print_warn "远端版本不比本地新, 仍要继续? (y/N)"
        local a; read -r a
        [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; return 0; }
    fi
    ui_tip "回滚点会保留为 mihomo.bak, 新版起不来可手动换回"
    MIHOMO_SKIP_IF_PRESENT=0 MIHOMO_FORCE_TAG="$latest" \
    INSTALL_DIR="$root" SERVICE_NAME="$svc" \
        bash "$root/src/core_install.sh"
}

# 卸载内核但保留配置/节点/证书。
# 这是与"完整卸载面板"分开的一档 —— 用户想换内核时不会连节点一起丢。
core_do_uninstall() {
    local root="$1" svc="$2"
    print_warn "将删除内核二进制与 systemd 服务, 保留配置/节点/证书"
    print_warn "目录: $root"
    printf "  ${CYAN}确认卸载内核? (y/N)${RESET}: " >&2
    local a; read -r a
    [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; return 0; }
    [[ -f "$root/mihomo" ]] && cp -f "$root/mihomo" "$root/mihomo.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    systemctl stop "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
    rm -f "/etc/systemd/system/$svc.service" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    rm -f "$root/mihomo"
    print_ok "内核已卸载 (备份保留在 $root/mihomo.bak.*)"
    ui_hint "配置与节点未动, 重新执行安装即可装回"
}

# ---------- 面板脚本自更新 ----------

# 从 GitHub 重新拉一遍面板文件。
#
# 不走 git: 现场安装的机器大多没有 .git (install.sh 是 curl 下来解包的),
# git pull 无从谈起。直接按文件列表重新拉更符合实际。
#
# 先拉到临时目录, 全下成功才覆盖 —— 半途失败不能把面板打成半残。
core_update_scripts() {
    local root="$1"
    local tmp; tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    # ---------- 要更新哪些文件: 以 manifest.txt 为准 ----------
    #
    # 这里原本硬编码 23 个文件名, 而 manifest.txt 有 31 个 —— 于是从面板
    # 「更新脚本」会有 8 个文件**永远不更新**:
    #     cdn.sh cert.sh dl_route.sh fw.sh lan_dispatch.sh
    #     preset.sh rules_bind.sh simple_proxy.sh
    # 其余文件往前走了, 这 8 个留在旧版本 —— 而它们之间是互相调用的
    # (cert.sh 被 server.sh source、cdn.sh 被 all.sh 用…), 半新半旧比全旧更难查。
    #
    # 这是 K-14 (install.sh 漏下 8 个文件) 的翻版, 只是发生在另一条路径上。
    # 所以改成和 install.sh 同一套: **清单是唯一真源**, 拉不到才用兜底。
    local files=()
    local line
    if m_fetch_any "src/manifest.txt" "$tmp/manifest.txt" 2>/dev/null; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(printf '%s' "$line" | tr -d '[:space:]')"
            [[ -n "$line" ]] && files+=("$line")
        done < "$tmp/manifest.txt"
    fi
    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "清单拉取失败, 使用内置兜底清单"
        files=(
            "src/lib/env.sh" "src/lib/ui.sh" "src/lib/core_mgmt.sh" "src/lib/webui.sh" "src/lib/portcheck.sh"
            "src/lib/cert.sh" "src/lib/preset.sh" "src/lib/cdn.sh" "src/lib/fw.sh"
            "src/lib/rules_bind.sh" "src/lib/lan_dispatch.sh" "src/lib/dl_route.sh" "src/lib/simple_proxy.sh"
            "src/lib/server_extra.sh"
            "src/lib/dns.sh" "src/lib/dns_edit.py"
            "src/lib/envtool.py" "src/lib/merge.py" "src/lib/validate.py"
            "src/conf/Reality.sh" "src/conf/VLESS.sh" "src/conf/Trojan.sh"
            "src/conf/hysteria2.sh" "src/conf/TUIC.sh" "src/conf/AnyTLS.sh"
            "src/conf/all.sh" "src/conf/XRevise.sh" "src/conf/nginx_apply.py"
            "src/share/share.sh" "src/share/share_server.py" "src/share/build_sub.py"
            "src/core_install.sh" "src/server.sh" "src/client.sh"
        )
    fi

    print_info "拉取面板文件 (${#files[@]} 个)"
    # 走 m_fetch_any: 它会依次试整条镜像链, 并在直连全灭时带上本机代理。
    # 原来是裸的 github.com 直连 —— 在国内机器上这一项**根本不可能成功**,
    # 而"连不上 GitHub"恰恰是用户最需要这个功能的场景。
    local f n=0
    for f in "${files[@]}"; do
        mkdir -p "$tmp/$(dirname "$f")"
        if m_fetch_any "$f" "$tmp/$f" 2>/dev/null; then
            n=$((n + 1))
            printf "\r  已拉取 $n/${#files[@]}" >&2
        else
            printf "\n" >&2
            print_error "下载失败: $f"
            print_error "面板未做任何修改"
            return 1
        fi
    done
    printf "\r  已拉取 $n/${#files[@]}\n" >&2

    # 全部下完才覆盖 —— 避免失败时面板变成半新半旧
    for f in "${files[@]}"; do
        mkdir -p "$root/$(dirname "$f")"
        cp -f "$tmp/$f" "$root/$f" || { print_error "覆盖失败: $f"; return 1; }
    done
    chmod +x "$root"/src/*.sh "$root"/src/conf/*.sh "$root"/src/core_install.sh 2>/dev/null
    print_ok "面板文件已更新 ($n 个)"
    ui_tip "当前面板进程仍在跑旧代码, 下次启动生效"
}

# ---------- 菜单 ----------

core_version_menu() {
    local root="$1"
    local c
    while true; do
        print_title "内核版本管理"
        ui_kv_ascii "当前版本" "$(core_current_version "$root/mihomo")"
        echo >&2
        ui_menu 1 "查看远端最新版本"
        ui_menu 2 "安装指定版本"
        ui_menu 3 "安装最新版本"
        ui_menu 4 "安装最新 pre-release (不推荐)"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || return 0
        c=$(clean_input "$c")
        case "$c" in
            1)
                local t; t=$(core_latest_tag) \
                    && print_ok "远端最新: $t" \
                    || print_error "查不到 (网络不通?)"
                ;;
            2)
                local tags; tags=$(core_list_tags) || { print_error "取版本列表失败"; continue; }
                [[ -n "$tags" ]] || { print_error "版本列表为空"; continue; }
                echo >&2; print_info "可选版本 (前 20 个):"
                printf '%s\n' "$tags" | head -20 | nl -w2 -s'. ' | sed 's/^/    /' >&2
                printf "  ${CYAN}输入要安装的版本号${RESET} (如 v1.19.32, 留空取消): " >&2
                local pick; read -r pick; pick=$(clean_input "$pick")
                [[ -n "$pick" ]] || { print_info "已取消"; continue; }
                [[ "$pick" == v* ]] || pick="v$pick"
                MIHOMO_SKIP_IF_PRESENT=0 MIHOMO_FORCE_TAG="$pick" \
                INSTALL_DIR="$root" SERVICE_NAME="${2:-mihomo}" \
                    bash "$root/src/core_install.sh"
                ;;
            3)
                local t; t=$(core_latest_tag) || { print_error "查不到最新版本"; continue; }
                print_info "将安装 $t"
                MIHOMO_SKIP_IF_PRESENT=0 MIHOMO_FORCE_TAG="$t" \
                INSTALL_DIR="$root" SERVICE_NAME="${2:-mihomo}" \
                    bash "$root/src/core_install.sh"
                ;;
            4)
                print_warn "pre-release 是预发布版, 可能不稳定"
                printf "  ${CYAN}仍要继续? (y/N)${RESET}: " >&2
                local a; read -r a
                [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; continue; }
                MIHOMO_SKIP_IF_PRESENT=0 MIHOMO_ALLOW_PRERELEASE=1 \
                INSTALL_DIR="$root" SERVICE_NAME="${2:-mihomo}" \
                    bash "$root/src/core_install.sh"
                ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}

# ★ systemd unit 不存在时, 提前把话说清楚。
#
# 背景: 「初始化基础配置」只建 conf/, **不装 systemd 服务** —— unit 是
# core_install.sh 写的。所以在一台"只跑面板"的机器上, 用户会一路顺利地
# 初始化完配置、生成节点, 直到点「启动」才看到:
#     Failed to start mihomo.service: Unit mihomo.service not found.
# 这条英文错完全没指向真正的原因 (缺的是 unit, 不是配置), 而配置已经建好,
# 用户很难往回退两步去想"我是不是压根没装服务"。
#
# 在这里提示, 是因为这是**唯一**一个还能低成本补救的位置: 配置还没生成,
# 重跑一次安装脚本代价最小。
_core_warn_missing_unit() {
    local root="$1" svc="$2" f="/etc/systemd/system/$svc.service"
    [[ -f "$f" ]] && return 0
    print_warn "还没安装系统服务 ($svc.service 不存在)"
    print_info "「初始化基础配置」只生成配置文件, **不会**装 systemd 服务 —— 那一步在安装脚本里。"
    print_info "不装的话, 后面点「服务管理 → 启动」会报 Unit not found。"
    print_info "继续的话请运行:  bash $root/src/core_install.sh"
    printf '  %b还要继续初始化吗? [y/N]: ' "${CYAN:-}" >&2
    local a; read -r a || a=""
    a=$(clean_input "$a")
    case "$a" in
        y|Y|yes|YES) return 0 ;;
        # ⚠ 返回值必须被调用方用 if 接住。上一版写的是
        #   _core_warn_missing_unit ... ; bash ... init
        #   两句之间没有 &&, 于是 return 1 只让**这一句**返回非零, 后面的
        #   init 照跑不误 —— 用户选 n, 屏幕显示"已取消初始化", 转头发现
        #   conf/certs、config.d/.managed.json、config.yaml、out/ 全建好了。
        #   取消一个动作却留下了全部副作用, 比不取消更糟。
        *) print_info "已取消初始化"; return 1 ;;
    esac
}

core_menu() {   # <安装根目录> <服务名>
    local root="$1" svc="${2:-mihomo}"
    local c
    while true; do
        print_title "安装 / 内核管理"
        ui_kv_ascii "内核" "$(core_current_version "$root/mihomo")"
        # systemctl 未运行时退出码非 0, stdout 已经打了 "inactive";
        # 再 || echo inactive 就是**同一行打印两遍**, 界面上一条
        # "服务 : inactive" 下面孤零零多一个 inactive。
        local _svcstate; _svcstate=$(systemctl is-active "$svc" 2>/dev/null) || _svcstate="inactive"
        ui_kv_ascii "服务" "$_svcstate"
        echo >&2
        ui_menu 1 "初始化基础配置"
        ui_menu 2 "安装 / 重装内核"
        ui_menu 3 "更新内核 (已是最新则跳过)"
        ui_menu 4 "版本管理 (当前/最新/指定)"
        ui_menu 5 "卸载内核 (保留配置与节点)"
        ui_menu 6 "更新管理脚本 (与内核更新分离)"
        ui_menu 7 "完整卸载面板"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || return 0
        c=$(clean_input "$c")
        case "$c" in
            1) if _core_warn_missing_unit "$root" "$svc"; then
                   if [[ "$svc" == "mihomo" ]]; then
                     bash "$root/src/server.sh" init \
                       || print_error "初始化失败, 见上面输出"
                   else
                     bash "$root/src/client.sh" init \
                       || print_error "初始化失败, 见上面输出"
                   fi
               fi ;;
            2) core_do_install "$root" "$svc" ;;
            3) core_do_update "$root" "$svc" ;;
            4) core_version_menu "$root" "$svc" ;;
            5) core_do_uninstall "$root" "$svc" ;;
            6) core_update_scripts "$root" ;;
            7) # 去掉 2>/dev/null: 现在子命令真的存在了, 卸载过程中的提示
               # (删了哪些 unit、回收了哪些端口) 对用户是有用信息, 不该吞掉。
               if [[ "$svc" == "mihomo" ]]; then
                   bash "$root/src/server.sh" uninstall \
                     || print_warn "请用面板的「卸载服务端」"
               else
                   bash "$root/src/client.sh" uninstall \
                     || print_warn "请用面板的「卸载客户端」"
               fi ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}

# =============================================================
# 切换到另一端 (服务端 <-> 客户端)
# =============================================================
#
# 它的配置里面有一个切换的方式"。
#
# 两边的安装目录是 install.sh 定死的默认值 (都允许用环境变量覆盖), 所以这里
# 按同一套默认值推导另一端在哪 —— 不去猜, 也不写死第二份。
#
# 注意本函数**不自己实现下载**: 装另一端的活交回 install.sh。它是唯一知道
# 仓库地址与整条镜像链的地方, 在这儿再写一份下载逻辑就是第二个真源, 迟早漂移
# (那正是 K-14 那类问题的成因)。
#
# 但 install.sh 得先下下来才谈得上交给它 —— 那一步本身就要求仓库可达, 而
# "仓库不可达"恰恰是用户点这个菜单的原因。所以这里必须有一条自己的取件路径,
# 于是就有了下面这份与 install.sh 同源的镜像链。
#
# 两份必须一致, 所以 tools/check_mirrors.sh 会机械比对它们 —— 不靠"记得同步"。
m_repo_mirrors() {   # 输出 install.sh 里同一条链, 一行一个 base
    local repo="${MIHOMO_REPO:-https://github.com/mi1314cat/mihomo--core}"
    local branch="${MIHOMO_BRANCH:-main}"
    printf '%s/raw/refs/heads/%s\n' "$repo" "$branch"
    printf '%s\n' \
        "https://ghproxy.net/https://raw.githubusercontent.com/mi1314cat/mihomo--core/main" \
        "https://gh-proxy.com/https://raw.githubusercontent.com/mi1314cat/mihomo--core/main" \
        "${REPO_PROXY:-https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main}" \
        "https://cdn.jsdelivr.net/gh/mi1314cat/mihomo--core@main" \
        "https://fastly.jsdelivr.net/gh/mi1314cat/mihomo--core@main"
}

# 依次试镜像链, 成功则把内容写到 $2。顺带支持本机代理兜底。
m_fetch_any() {      # $1=相对路径  $2=落地文件
    local rel="$1" out="$2" base code
    local -a extra=()
    # 用户显式设过代理 -> curl 自己就认, 不用额外参数
    if [[ -z "${https_proxy:-}${http_proxy:-}" ]]; then
        scan_proxy 2>/dev/null || true
        ((${#_PROXY_CAND[@]})) && extra=(--proxy "${_PROXY_CAND[0]}")
    fi
    while IFS= read -r base; do
        [[ -n "$base" ]] || continue
        code=$(curl -fsSL --max-time 45 "${extra[@]}" "$base/$rel" -o "$out" 2>/dev/null && echo ok || echo fail)
        [[ "$code" == "ok" && -s "$out" ]] && return 0
    done < <(m_repo_mirrors)
    return 1
}

switch_side() {
    local here="$1"
    local srv="${SRV_ROOT_OTHER:-/root/catmi/mihomo}"
    local cli="${CLI_ROOT_OTHER:-/root/catmi/mihomo-client}"
    local other script label sub

    if [[ "$here" == "$cli" ]]; then
        other="$srv"; script="server.sh"; label="服务端"; sub="server"
    else
        other="$cli"; script="client.sh"; label="客户端"; sub="client"
    fi

    print_title "切换到$label"

    # 已经装了就直接进 —— 这是最常见的情况, 也是"切换"该有的手感
    if [[ -f "$other/src/$script" ]]; then
        print_ok "本机已安装$label, 直接进入面板"
        ui_kv_ascii "目录" "$other"
        pause
        bash "$other/src/$script"
        return 0
    fi

    print_info "本机还没装$label"
    ui_kv_ascii "安装目录" "$other"
    echo >&2
    printf "  现在安装? [y/N]: " >&2
    local a; read -r a || return 0
    [[ "$a" == [yY]* ]] || { print_info "已取消"; return 0; }

    local t; t="$(mktemp -d)"
    print_info "拉取安装脚本..."
    if m_fetch_any "install.sh" "$t/install.sh"; then
        # 把两个根目录都显式传过去: 用户可能自定义过路径, 让 install.sh 按
        # 同一套路径装, 而不是用它的默认值再装出第三个目录。
        SRV_ROOT="$srv" CLI_ROOT="$cli" bash "$t/install.sh" "$sub"
    else
        # 全部镜像 + 本机代理都不通。这时不该只丢一句"失败", 而要给出可执行
        # 的下一步 —— 用户手上可能有别的通道 (手机热点/另一台机器/手动下载)。
        print_error "所有下载通道都不通 (已试镜像链 + 本机代理)"
        echo >&2
        print_info "三个办法, 任选其一:"
        printf '    1) 本机开代理后重试 (脚本会自动探测 7890/7891/1080 等端口)\n' >&2
        printf '    2) 手动下载 install.sh 后执行: bash install.sh %s\n' "$sub" >&2
        printf '    3) 直接在有网的机器上跑: bash <(curl -fsSL %s/raw/refs/heads/%s/install.sh) %s\n' \
            "${MIHOMO_REPO:-https://github.com/mi1314cat/mihomo--core}" \
            "${MIHOMO_BRANCH:-main}" "$sub" >&2
    fi
    rm -rf "$t"
    return 0
}
