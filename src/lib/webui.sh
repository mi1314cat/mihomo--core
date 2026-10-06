#!/usr/bin/env bash
# =============================================================
# mihomo--core · Web UI (仪表盘) 管理 (webui.sh)
#
# mihomo 的 external-controller 提供 Clash API, 配上仪表盘就是可视化管理:
# 实时流量、连接列表、策略切换、日志。Mihomo 生态里这是主流用法 ——
# 但面板只把 external-controller 打开了, 从没给用户装仪表盘的入口,
# 于是用户要么自己搜文档, 要么就用不上。
#
# 对齐 SB 的 webui_menu: 启用 / 停用 / 重新下载 / 查看访问地址。
# 差别只在 SB 下的是 metacubexd 的 sing-box 变体, 这里用 Mihomo 原生的
# metacubexd (Mihomo 内核的 API 与 Clash 一致, 同一个 UI 通用)。
# =============================================================

# 仪表盘 zip 的下载地址与目标目录名。
# metacubexd 的 release 里统一是 metacubexd-gh-pages。
WEBUI_NAME="metacubexd"
WEBUI_URLS=(
    "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
    "https://gh-proxy.com/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
    "https://ghfast.top/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
)

print_hint_url() { printf "    %s\n" "$1" >&2; }

webui_installed() { [[ -f "$1/index.html" ]]; }

webui_state() {   # 输出: 已启用(<目录>) / 未安装 / 已装未启用
    if webui_installed "$CLI_UI"; then printf '已启用 (%s)\n' "$CLI_UI"
    else printf '未安装\n'; fi
}

# 下载并解压仪表盘。
#
# 先解到临时目录确认里面有 index.html 再搬进 $CLI_UI —— 直接往目标目录解,
# 中途失败会留下半个 UI, 而 external-ui 指向一个不完整的目录时,
# 面板是能打开但一片空白, 用户会以为是仪表盘坏了。
webui_download() {
    local tmp; tmp=$(mktemp -d)
    local u
    for u in "${WEBUI_URLS[@]}"; do
        print_info "下载 $WEBUI_NAME ..."
        print_hint_url "$u"
        if curl -fsSL --max-time 180 "$u" -o "$tmp/ui.zip" 2>/dev/null; then
            break
        fi
        rm -f "$tmp/ui.zip"
    done
    if [[ ! -s "$tmp/ui.zip" ]]; then
        print_error "下载失败 (试了 ${#WEBUI_URLS[@]} 个源)"
        print_info "也可以手动下载后解压到: $CLI_UI"
        rm -rf "$tmp"; return 1
    fi
    unzip -q -o "$tmp/ui.zip" -d "$tmp/x" 2>/dev/null || {
        print_error "解压失败 (需要 unzip)"; rm -rf "$tmp"; return 1; }
    # zip 里是 metacubexd-gh-pages/ 这一层
    local src=""
    [[ -f "$tmp/x/metacubexd-gh-pages/index.html" ]] && src="$tmp/x/metacubexd-gh-pages"
    [[ -z "$src" && -f "$tmp/x/index.html" ]] && src="$tmp/x"
    if [[ -z "$src" ]]; then
        print_error "压缩包结构不对, 找不到 index.html"; rm -rf "$tmp"; return 1
    fi
    local old="$CLI_UI.bak.$(date +%Y%m%d-%H%M%S)"
    [[ -d "$CLI_UI" ]] && mv "$CLI_UI" "$old" 2>/dev/null
    mkdir -p "$(dirname "$CLI_UI")"
    mv "$src" "$CLI_UI" || { print_error "安装失败"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    print_ok "$WEBUI_NAME 已就绪: $CLI_UI"
    [[ -d "$old" ]] && ui_hint "原目录已备份到 $old"
    return 0
}

webui_disable() {
    if [[ ! -d "$CLI_UI" ]]; then
        print_info "本来就没装"
        return 0
    fi
    local old="$CLI_UI.disabled.$(date +%Y%m%d-%H%M%S)"
    mv "$CLI_UI" "$old" && print_ok "已停用 (目录改名保留: $old)" \
        || print_error "改名失败, 可能有权限问题"
    ui_hint "重新启用: 把目录名改回 $CLI_UI"
}

# 把 external-ui 写进 config.yaml。返回 0=已启用 1=需重启
webui_enable_in_config() {
    local conf="$CLI_CONF/config.yaml"
    [[ -f "$conf" ]] || { print_error "找不到配置: $conf"; return 1; }
    if grep -qE "^external-ui:" "$conf" 2>/dev/null; then
        print_ok "配置里已启用 external-ui"
        return 0
    fi
    printf 'external-ui: %s\n' "$CLI_UI" >> "$conf"
    print_ok "已写入 external-ui"
    return 1     # 需要重启才生效
}

webui_menu() {
    local c url
    while true; do
        print_title "Web UI / 仪表盘"
        ui_kv_ascii "状态" "$(webui_state)"
        ui_kv_ascii "访问地址" "http://127.0.0.1:${PORT_CTRL:-9090}/ui/"
        ui_kv_ascii "密钥" "${CLI_SECRET:+已设置 (在客户端设置里查看)}"
        echo >&2
        ui_menu 1 "启用 Web UI (下载并启用 $WEBUI_NAME)"
        ui_menu 2 "停用 Web UI (保留文件)"
        ui_menu 3 "重新下载 / 修复"
        ui_menu 4 "复制访问地址"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || return 0
        c=$(clean_input "$c")
        case "$c" in
            1)
                webui_download || { pause; continue; }
                if webui_enable_in_config; then
                    print_ok "可以访问: http://127.0.0.1:${PORT_CTRL}/ui/"
                else
                    print_warn "需要重启服务才生效"
                    printf "  ${CYAN}现在重启? (y/N)${RESET}: " >&2
                    local a; read -r a
                    [[ "$a" =~ ^[yY]$ ]] && { systemctl restart "$CLI_SERVICE"; sleep 2; print_ok "已重启"; }
                fi
                ;;
            2) webui_disable ;;
            3) webui_download ;;
            4)
                url="http://127.0.0.1:${PORT_CTRL}/ui/"
                printf '%s' "$url"
                if command -v xclip >/dev/null 2>&1; then echo "$url" | xclip -selection clipboard && print_ok "已复制" >&2
                elif command -v xsel >/dev/null 2>&1; then echo "$url" | xsel -b && print_ok "已复制" >&2
                else print_ok "(本机无剪贴板工具, 请手动复制)" >&2; fi
                ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}
