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

    local files=(
        "src/lib/env.sh" "src/lib/ui.sh" "src/lib/core_mgmt.sh" "src/lib/webui.sh" "src/lib/portcheck.sh"
        "src/lib/envtool.py" "src/lib/merge.py" "src/lib/validate.py"
        "src/conf/Reality.sh" "src/conf/VLESS.sh" "src/conf/Trojan.sh"
        "src/conf/hysteria2.sh" "src/conf/TUIC.sh" "src/conf/AnyTLS.sh"
        "src/conf/all.sh" "src/conf/XRevise.sh" "src/conf/nginx_apply.py"
        "src/share/share.sh" "src/share/share_server.py" "src/share/build_sub.py"
        "src/core_install.sh" "src/server.sh" "src/client.sh"
    )

    # 仓库地址优先取本机记录的, 取不到用默认
    local repo="${MIHOMO_REPO:-https://github.com/mi1314cat/mihomo--core}"
    local branch="${MIHOMO_BRANCH:-main}"
    local base="$repo/raw/refs/heads/$branch"

    print_info "从 $base 拉取面板文件"
    local f n=0
    for f in "${files[@]}"; do
        mkdir -p "$tmp/$(dirname "$f")"
        if curl -fsSL --max-time 45 "$base/$f" -o "$tmp/$f" 2>/dev/null; then
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

core_menu() {   # <安装根目录> <服务名>
    local root="$1" svc="${2:-mihomo}"
    local c
    while true; do
        print_title "安装 / 内核管理"
        ui_kv_ascii "内核" "$(core_current_version "$root/mihomo")"
        ui_kv_ascii "服务" "$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
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
            1) bash "$root/src/server.sh" init 2>/dev/null || _core_init_base "$root" ;;
            2) core_do_install "$root" "$svc" ;;
            3) core_do_update "$root" "$svc" ;;
            4) core_version_menu "$root" "$svc" ;;
            5) core_do_uninstall "$root" "$svc" ;;
            6) core_update_scripts "$root" ;;
            7) if [[ "$svc" == "mihomo" ]]; then
                   bash "$root/src/server.sh" uninstall 2>/dev/null \
                     || { print_warn "请用面板的「卸载服务端」"; }
               else
                   bash "$root/src/client.sh" uninstall 2>/dev/null \
                     || { print_warn "请用面板的「卸载客户端」"; }
               fi ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}
