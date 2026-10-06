#!/usr/bin/env bash
# =============================================================
# cdn.sh — CDN 前置 (Cloudflare 回源) 的编排层
#
# 原理:
#   Cloudflare 边缘 --回源 443--> 你的 Nginx --按 path--> 127.0.0.1:<节点端口>
#
#   CDN 模式下节点只监听 127.0.0.1, 端口不再对外暴露; 客户端连你的域名
#   而不是服务器 IP, 由 Cloudflare 隐藏源站。
#
# 本模块负责:
#   1. 判定某传输能否走 CDN (只有跑在 HTTP 上的才行)
#   2. 渲染 location 片段
#   3. 安全写入你的 Nginx 站点 (交给 nginx_apply.py: 备份 + nginx -t + 回滚)
#   4. 记录「节点 <-> 域名/站点」绑定, 使删节点时能精确回删并 reload
#
# 与 SB (参考实现) 的差异, 以及为什么:
#   SB 的 cdn.sh 明确「绝不碰你的 Nginx」, 只打印片段让用户手工粘贴。
#   本项目的 nginx_apply.py 已经能做到安全写入 —— 先备份、只在已存在的
#   匹配 server 块内插入、插完 nginx -t 校验、失败自动回滚、通过才 reload。
#   经确认后本项目采用**自动写入**, 并额外补上 SB 没有的**回删**能力。
#
#   但 location 的内容 (各级指令与踩过的坑) 完全照搬 SB 的实测结论,
#   不自己造轮子。见 cdn_render_location 里逐条标注的来源。
#
# 依赖: ui.sh, cert.sh ; 调用 src/conf/nginx_apply.py
# =============================================================

: "${SRV_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

CDN_APPLY_PY="${CDN_APPLY_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../conf" && pwd)/nginx_apply.py}"
CDN_BIND_FILE="${CDN_BIND_FILE:-$SRV_ROOT/cdn_bindings.tsv}"

# 只有跑在 HTTP 上的传输才能被 Cloudflare 代理。
#   ws / httpupgrade : HTTP/1.1 升级
#   grpc / h2        : HTTP/2
# REALITY / AnyTLS / Hysteria2 / TUIC / SS / ShadowTLS 是原生 TCP/UDP
# 或专用协议, Cloudflare 代理不了, 必须直连。 (与 SB 一致)
CDN_TRANSPORTS="ws grpc h2 httpupgrade xhttp"
CDN_FRAG_DIR="${CDN_FRAG_DIR:-$SRV_ROOT/out/cdn}"

# =============================================================
# 一、能力判定
# =============================================================
cdn_supported_transport() {
    local t="${1:-}"
    local x
    for x in $CDN_TRANSPORTS; do [[ "$t" == "$x" ]] && return 0; done
    return 1
}

# 节点所在传输能否走 CDN; 不可走时打印原因
cdn_check_node() { # <transport> <域名>
    local t="${1:-}" dom="${2:-}"
    if ! cdn_supported_transport "$t"; then
        print_error "传输 '$t' 不能走 CDN"
        print_info "只有跑在 HTTP 上的传输能被 Cloudflare 代理: $CDN_TRANSPORTS"
        print_info "REALITY / AnyTLS / Hysteria2 / TUIC / SS / ShadowTLS 是"
        print_info "原生 TCP/UDP 或专用协议, Cloudflare 代理不了, 必须直连。"
        return 1
    fi
    if [[ -z "$dom" ]]; then
        print_error "缺域名 —— 走 CDN 必须有一个你自己的域名"
        return 1
    fi
    return 0
}

# =============================================================
# 二、探测本机 Nginx (全部委托 nginx_apply.py, 不重复实现)
# =============================================================
cdn_available() { [[ -f "$CDN_APPLY_PY" ]] && command -v python3 >/dev/null 2>&1; }

cdn_probe() {
    cdn_available || { print_error "缺少 nginx_apply.py 或 python3"; return 1; }
    python3 "$CDN_APPLY_PY" --probe
}

cdn_list_sites() {
    cdn_available || return 1
    python3 "$CDN_APPLY_PY" --list
}

# 校验命令前缀。
#   容器化必须用 docker exec —— 否则 nginx -t 验的是宿主那份, 而宿主那份
#   可能根本没挂进容器, 验过了也不代表真正生效的配置没问题。
#   (实测 2026-10-06 就是容器场景, 宿主目录是空的。)
cdn_check_cmd() {
    local chk="none" cname
    if command -v docker >/dev/null 2>&1; then
        cname=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
                | awk 'tolower($0) ~ /nginx/ {print $1; exit}')
        [[ -n "$cname" ]] && chk="docker exec $cname nginx"
    fi
    [[ "$chk" == "none" ]] && command -v nginx >/dev/null 2>&1 && chk="nginx"
    printf '%s' "$chk"
}

# =============================================================
# 三、绑定登记表
#
# 为什么需要它: nginx_apply.py 的插入标记是**按域名**索引的 (幂等设计),
# 所以"删掉这个节点对应的 nginx 配置"不能只靠域名反查 —— 同一个域名下
# 可能有多个节点, 按域名删会把别人的一起删掉。必须有一张 tag->域名/站点
# 的对照表, 删除时按 tag 精确摘除, 再**重渲染该域名的剩余节点**。
#
# 格式 (TSV, 一行一个绑定):
#   <tag>\t<域名>\t<站点文件>\t<传输>\t<路径或service_name>\t<节点端口>
# =============================================================
cdn_bind_init() {
    [[ -f "$CDN_BIND_FILE" ]] || : > "$CDN_BIND_FILE"
}

cdn_bind_add() { # <tag> <域名> <站点文件> <传输> <路径> <端口>
    cdn_bind_init
    local tag="$1" dom="$2" site="$3" tr="$4" path="$5" port="$6"
    cdn_bind_del "$tag" >/dev/null 2>&1
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$dom" "$site" "$tr" "$path" "$port" >> "$CDN_BIND_FILE"
}

cdn_bind_del() { # <tag>
    cdn_bind_init
    local tag="${1:-}" tmp
    [[ -n "$tag" ]] || return 1
    tmp=$(mktemp)
    awk -F'\t' -v t="$tag" '$1 != t' "$CDN_BIND_FILE" > "$tmp" 2>/dev/null
    : > "$CDN_BIND_FILE"
    cat "$tmp" >> "$CDN_BIND_FILE"
    rm -f "$tmp"
}

cdn_bind_get() { # <tag> -> 整行
    cdn_bind_init
    awk -F'\t' -v t="${1:-}" '$1 == t { print; exit }' "$CDN_BIND_FILE"
}

# 某域名下的全部绑定
cdn_bind_by_domain() { # <域名>
    cdn_bind_init
    awk -F'\t' -v d="${1:-}" '$2 == d { print }' "$CDN_BIND_FILE"
}

cdn_bind_count() { cdn_bind_init; grep -c . "$CDN_BIND_FILE" 2>/dev/null || echo 0; }

# =============================================================
# 四、渲染 location 片段
#
# ★ 各级指令与坑全部来自 SB 的实测结论 (cdn.sh:cdn_render_location),
#   照搬不自己造轮子。逐条保留了原因注释。
# =============================================================
cdn_render_location() { # <缩进> <tag> <端口> <传输> <路径> <是否TLS>
    local pad="$1" tag="$2" port="$3" ttype="$4" path="$5" tls="${6:-1}"
    local loc

    printf '%s# ---- %s  (回源 -> 127.0.0.1:%s, %s) ----\n' "$pad" "$tag" "$port" "$ttype"
    case "$ttype" in
        xhttp)
            # ★ xHTTP 过 Nginx 与其它传输**不一样**: 必须用 grpc_pass,
            #   不能用 proxy_pass。
            #
            #   原因: xHTTP 默认伪装成 gRPC —— 会带上
            #   `Content-Type: application/grpc` 并对上行做 gRPC 分帧
            #   (上游为此专门加过 PR, 目的就是穿透"会缓存上行请求"的中间盒)。
            #   nginx 只有 grpc_pass 会按 gRPC 语义转发; 用 proxy_pass 会因为
            #   逐请求缓冲而卡死上行。
            #
            #   代价 (作者原话): 「Nginx 使用 grpc_pass 反代 xhttp 时不支持
            #   http/1.1, 如果要支持请使用 proxy_pass (建议舍弃 http/1.1,
            #   因为 grpc_pass 性能更好)」。
            #    => 本分支只对走 HTTP/2 的客户端有效。
            #
            #   另外必须确认 Cloudflare 缓存规则**排除该 path**, 否则会被缓存。
            loc="$path"
            [[ "$loc" != /* ]] && loc="/$loc"
            printf '%s# xHTTP 专属: 用 grpc_pass (xhttp 默认伪装成 gRPC), 非 proxy_pass\n' "$pad"
            printf '%s# 依赖 http{}/server{} 层: client_max_body_size 0;\n' "$pad"
            printf '%s#                       proxy_request_buffering off;\n' "$pad"
            printf '%s#                       proxy_buffering off;\n' "$pad"
            printf '%slocation %s {\n' "$pad" "$loc"
            printf '%s    grpc_buffer_size 16k;\n' "$pad"
            printf '%s    grpc_socket_keepalive on;\n' "$pad"
            printf '%s    grpc_read_timeout 1h;\n' "$pad"
            printf '%s    grpc_send_timeout 1h;\n' "$pad"
            # 空串是刻意的: gRPC 不允许 Connection 头, 透传会让上游拒绝
            printf '%s    grpc_set_header Connection "";\n' "$pad"
            printf '%s    grpc_set_header Host $host;\n' "$pad"
            printf '%s    grpc_set_header X-Real-IP $remote_addr;\n' "$pad"
            printf '%s    grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n' "$pad"
            printf '%s    grpc_set_header X-Forwarded-Proto $scheme;\n' "$pad"
            printf '%s    grpc_set_header X-Forwarded-Port $server_port;\n' "$pad"
            printf '%s    grpc_set_header X-Forwarded-Host $host;\n' "$pad"
            if [[ "$tls" == "1" ]]; then
                printf '%s    grpc_pass grpcs://127.0.0.1:%s;\n' "$pad" "$port"
            else
                printf '%s    grpc_pass grpc://127.0.0.1:%s;\n' "$pad" "$port"
            fi
            printf '%s}\n' "$pad"
            # 上限保护: client_max_body_size 默认 1m, xhttp 上行远大于此, 必须放开
            printf '%s# 若上游仍 413, 检查 http{}/server{} 是否设了 client_max_body_size 0;\n' "$pad"
            ;;
        grpc|h2)
            # location 路径要**恰好一个**前导斜杠:
            #   grpc 的 service_name 不带斜杠 -> 补一个
            #   h2   的 path 本身就带斜杠     -> 不能再补
            # 无脑写 location /%s 的话 h2 会变成 //abc, 匹配不到。
            loc="$path"
            [[ "$loc" != /* ]] && loc="/$loc"
            printf '%s# 坑: proxy_http_version 2 在 nginx < 1.29.4 直接\n' "$pad"
            printf '%s#     [emerg] invalid value "2", 整份配置起不来;\n' "$pad"
            printf '%s#     而 grpc_pass grpc:// 指向开了 TLS 的节点会 502。\n' "$pad"
            printf '%s#     正确解是 grpcs:// (节点开 TLS 时)。\n' "$pad"
            printf '%slocation %s {\n' "$pad" "$loc"
            if [[ "$tls" == "1" ]]; then
                printf '%s    grpc_pass grpcs://127.0.0.1:%s;\n' "$pad" "$port"
            else
                printf '%s    grpc_pass grpc://127.0.0.1:%s;\n' "$pad" "$port"
            fi
            # 这行不能少: grpc_pass 默认把上游地址当 Host 发出去, 而
            # sing-box 的 http 传输会拿 Host 做白名单校验, 少了它服务端
            # 直接 "bad host: 127.0.0.1:<port>" 拒收。
            # (gRPC 不校验 Host, 所以只有 http 传输踩这个坑。)
            printf '%s    grpc_set_header Host $host;\n' "$pad"
            printf '%s    grpc_set_header X-Real-IP $remote_addr;\n' "$pad"
            printf '%s    grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n' "$pad"
            printf '%s    grpc_read_timeout 600s;\n' "$pad"
            printf '%s    grpc_send_timeout 600s;\n' "$pad"
            printf '%s}\n' "$pad"
            ;;
        *)
            # ws / httpupgrade: HTTP/1.1 升级
            loc="$path"
            [[ "$loc" != /* ]] && loc="/$loc"
            printf '%slocation %s {\n' "$pad" "$loc"
            # 回源 TLS 的 SNI; Origin CA 不在系统信任库里, 所以不校验
            printf '%s    proxy_ssl_server_name on;\n' "$pad"
            printf '%s    proxy_ssl_verify off;\n' "$pad"
            printf '%s    proxy_pass https://127.0.0.1:%s;\n' "$pad" "$port"
            # ws / httpupgrade 都是 1.1 升级 —— 不能写 2
            printf '%s    proxy_http_version 1.1;\n' "$pad"
            printf '%s    proxy_set_header Upgrade $http_upgrade;\n' "$pad"
            printf '%s    proxy_set_header Connection $connection_upgrade;\n' "$pad"
            printf '%s    proxy_set_header Host $host;\n' "$pad"
            printf '%s    proxy_set_header X-Real-IP $remote_addr;\n' "$pad"
            printf '%s    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n' "$pad"
            printf '%s    proxy_buffering off;\n' "$pad"
            printf '%s    proxy_read_timeout 600s;\n' "$pad"
            printf '%s    proxy_send_timeout 600s;\n' "$pad"
            printf '%s}\n' "$pad"
            ;;
    esac
}

# 为某域名渲染**全部**已绑定节点的片段 (+ 自动附上 ws 需要的 map 块说明)。
# 同名 location 会让 nginx 起不来, 所以这里必须去重。
cdn_render_fragment() { # <域名> <输出去向: 文件路径>
    local dom="${1:-}" outfile="${2:-}"
    local seen="" rows line tag port tr path n=0 dup
    rows=$(cdn_bind_by_domain "$dom")
    [[ -n "$rows" ]] || { print_error "域名 $dom 下没有已登记的节点"; return 1; }

    {
        # 注意: 这里**不能**输出 '# >>> mihomo-core-cdn ... >>>' 形式的标记。
        # nginx_apply.py 用它自己的 BEGIN/END 包裹整段, 而它的 TAG_RE 是
        # 宽松匹配 (# >>> mihomo-core-cdn ... <域名> >>>), 我们的 FRAGMENT
        # 标记会被当成第二个 >>> 从而**改变它识别的区间** ——
        # 实测回删后会把 BEGIN/END 两行连同注释残留成孤儿。
        printf '# CDN 回源片段 —— 由 mihomo--core 面板生成 (域名 %s)。\n' "$dom" 
        printf '# 回源链路: Cloudflare -> Nginx(443) -> 127.0.0.1:<节点端口>\n'
        printf '# 依赖: $connection_upgrade 这个 map 必须已在 http{} 层定义,\n'
        printf '#       否则 nginx -t 会报 unknown "connection_upgrade" variable。\n'
        printf '\n'
        while IFS=$'\t' read -r tag _dom _site tr path port; do
            [[ -n "$tag" ]] || continue
            [[ "$_dom" == "$dom" ]] || continue
            # 去重: 归一化后的 location 路径
            local loc="$path"; [[ "$loc" != /* ]] && loc="/$loc"
            dup=0
            for seen_loc in $seen; do [[ "$seen_loc" == "$loc" ]] && dup=1 && break; done
            if (( dup )); then
                printf '# [跳过] 路径重复: %s (%s) —— 同名 location 会让 nginx 起不来\n\n' "$loc" "$tag"
                continue
            fi
            seen="$seen $loc"
            cdn_render_location "    " "$tag" "$port" "$tr" "$path" 1
            printf '\n'
            n=$((n+1))
        done <<< "$rows"
    } > "$outfile" 2>/dev/null

    (( n > 0 )) || { print_error "该域名下所有节点的 location 路径都重复, 无可插入内容"; return 1; }
    printf '%s' "$n"
}

# =============================================================
# 四之二、前置要求检查
#
# nginx_apply.py 只往 server{} 里插 location —— 但 CDN 回源有几个指令
# 必须出现在 server{}/http{} 层, 插在 location 里无效。缺了它们的后果:
#
#   client_max_body_size     默认 1m。xhttp/ws 上行会超过 -> 413,
#                            客户端表现为"握手能过、一传数据就断"。
#   proxy_request_buffering  默认 on。xhttp 的流式上行会被 nginx 整个
#                            缓冲住不转发 -> 连接建立但不通。
#                            (这是 xhttp 过 nginx 最经典的坑)
#   proxy_buffering          默认 on。响应侧同理, 长连接流式会被攒批。
# =============================================================
cdn_required_directives() { printf 'client_max_body_size\nproxy_request_buffering\nproxy_buffering\n'; }

cncd_check_line() { :; }   # 占位, 避免旧调用点报未定义

cdn_check_requirements() { # <站点文件>
    local site="${1:-}" miss="" k
    [[ -f "$site" ]] || return 0
    grep -qE '^[[:space:]]*client_max_body_size[[:space:]]+0[[:space:]]*;' "$site" \
        || miss="$miss client_max_body_size=0"
    grep -qE '^[[:space:]]*proxy_request_buffering[[:space:]]+off[[:space:]]*;' "$site" \
        || miss="$miss proxy_request_buffering=off"
    grep -qE '^[[:space:]]*proxy_buffering[[:space:]]+off[[:space:]]*;' "$site" \
        || miss="$miss proxy_buffering=off"
    if [[ -n "$miss" ]]; then
        print_warn "该站点缺少 CDN 回源所需指令:$miss"
        print_info "这些指令必须写在 server{} 或 http{} 层 (location 里无效)。"
        print_info "缺 client_max_body_size 0    -> 上行超过 1m 时 413"
        print_info "缺 proxy_request_buffering off -> xhttp 流式上行会被缓冲住, 连接不通"
        return 1
    fi
    return 0
}

# =============================================================
# 五、写入 / 回删
# =============================================================
cdn_apply_domain() { # <域名> <站点文件>
    local dom="${1:-}" site="${2:-}" frag chk n
    cdn_available || { print_error "nginx_apply.py 不可用"; return 1; }
    [[ -n "$dom" && -n "$site" && -f "$site" ]] || { print_error "域名或站点文件无效"; return 1; }

    cdn_check_requirements "$site" || print_warn "仍会继续写入 location, 但上面的指令需要你手工补"

    mkdir -p "$CDN_FRAG_DIR"
    frag="$CDN_FRAG_DIR/${dom}.conf"
    if ! n=$(cdn_render_fragment "$dom" "$frag"); then return 1; fi
    chk=$(cdn_check_cmd)

    print_info "渲染了 $n 个 location 片段: $frag"
    print_info "写入站点: $site   (校验: $chk)"
    python3 "$CDN_APPLY_PY" --domain "$dom" --file "$site" \
            --block "$frag" --nginx "$chk" 2>&1 | sed 's/^/    /'
    local rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then
        print_ok "Nginx 已更新并重载 (回源域名 $dom)"
    else
        print_error "写入失败 (退出码 $rc) —— nginx_apply.py 已自动回滚, 你的站点未被改动"
    fi
    return $rc
}

cdn_remove_domain() { # <域名> <站点文件>
    local dom="${1:-}" site="${2:-}" chk
    cdn_available || return 1
    [[ -n "$dom" && -n "$site" && -f "$site" ]] || return 1
    chk=$(cdn_check_cmd)
    python3 "$CDN_APPLY_PY" --domain "$dom" --file "$site" --remove --nginx "$chk" 2>&1 | sed 's/^/    /'
    local rc=${PIPESTATUS[0]}
    (( rc == 0 )) && print_ok "已从 $site 移除 $dom 的回源片段并重载" \
                  || print_warn "移除失败 (退出码 $rc), 请手工检查 $site"
    return $rc
}

# 节点删除钩子 —— 由节点管理流程调用。
#   1. 摘掉该 tag 的绑定
#   2. 该域名还有别的节点 -> 重渲染并覆盖写入
#      没有别的节点了   -> --remove 整段摘除
#   两种情况都由 nginx_apply.py 负责 reload。
cdn_node_unregister() { # <tag>
    local tag="${1:-}" line dom site left
    line=$(cdn_bind_get "$tag")
    if [[ -z "$line" ]]; then
        return 0   # 该节点没走 CDN, 正常
    fi
    IFS=$'\t' read -r _ dom site _ _ _ <<< "$line"
    print_info "该节点绑定了 CDN 回源 ($dom), 同步清理 Nginx..."
    cdn_bind_del "$tag"
    left=$(cdn_bind_by_domain "$dom" | grep -c . 2>/dev/null || echo 0)
    if (( left > 0 )); then
        cdn_apply_domain "$dom" "$site"
    else
        cdn_remove_domain "$dom" "$site"
    fi
}

# =============================================================
# 六、交互菜单 (节点创建时挂载)
# =============================================================
cdn_bind_menu() { # <tag> <端口> <传输> <路径>
    local tag="$1" port="$2" tr="$3" path="$4" dom site n
    if ! cdn_supported_transport "$tr"; then
        print_info "传输 '$tr' 不能走 CDN (只有 $CDN_TRANSPORTS 可以), 跳过"
        return 0
    fi
    cdn_available || { print_warn "本机没找到 nginx_apply.py, 跳过 CDN 配置"; return 0; }

    printf '\n  要不要把这个节点挂到 CDN (Cloudflare 回源)？\n' >&2
    printf '    1) 是, 自动写入我的 Nginx 站点\n' >&2
    printf '    2) 只生成片段, 我自己粘贴\n' >&2
    printf '    3) 不用 CDN, 跳过\n' >&2
    local c; c=$(safe_read "选择" "3")
    case "$c" in 1|2) ;; *) return 0 ;; esac

    dom=$(safe_read "回源域名 (必须是已解析到 Cloudflare 的域名)" "${CERT_DOMAIN:-}")
    [[ -n "$dom" ]] || { print_warn "未填域名, 跳过"; return 0; }

    cdn_bind_init
    # 临时登记以便渲染
    cdn_bind_add "$tag" "$dom" "" "$tr" "$path" "$port"
    mkdir -p "$CDN_FRAG_DIR"

    if [[ "$c" == "2" ]]; then
        n=$(cdn_render_fragment "$dom" "$CDN_FRAG_DIR/${dom}.conf") || return 0
        print_ok "片段已生成 ($n 个 location): $CDN_FRAG_DIR/${dom}.conf"
        print_info "把它贴进 $dom 对应 server{} 内, 然后 nginx -t && nginx -s reload"
        cdn_bind_del "$tag"
        return 0
    fi

    printf '\n  可选站点:\n' >&2
    cdn_list_sites 2>&1 | sed 's/^/    /' >&2
    site=$(safe_read "要写入的站点配置文件路径 (留空取消)" "")
    if [[ -z "$site" || ! -f "$site" ]]; then
        print_warn "未指定有效文件, 已取消 (绑定已撤销)"
        cdn_bind_del "$tag"
        return 0
    fi
    if cdn_apply_domain "$dom" "$site"; then
        cdn_bind_add "$tag" "$dom" "$site" "$tr" "$path" "$port"
        print_ok "已登记绑定: $tag -> $dom"
    else
        cdn_bind_del "$tag"
        print_error "写入失败, 绑定已撤销"
    fi
}

cdn_menu() {
    while true; do
        ui_clear
        ui_title "CDN 回源管理"
        echo "  登记中的绑定: $(cdn_bind_count)" >&2
        echo "  可走 CDN 的传输: $CDN_TRANSPORTS" >&2
        echo "" >&2
        ui_menu "探测 Nginx 部署方式" "列出所有站点" "查看当前绑定" "重新应用全部绑定" "返回"
        local c; c=$(safe_read "选择" "5")
        case "$c" in
            1) cdn_probe 2>&1 | sed 's/^/  /' >&2; pause ;;
            2) cdn_list_sites 2>&1 | sed 's/^/  /' >&2; pause ;;
            3)
                ui_clear; ui_title "CDN 绑定"
                if (( $(cdn_bind_count) == 0 )); then
                    print_info "暂无绑定"
                else
                    while IFS=$'\t' read -r t d s tr p pt; do
                        [[ -n "$t" ]] && printf '  %-24s -> %-28s [%s %s] %s\n' "$t" "$d" "$tr" "$p" "$s" >&2
                    done < "$CDN_BIND_FILE"
                fi
                pause ;;
            4)
                local ok=0 bad=0
                while IFS=$'\t' read -r t d s tr p pt; do
                    [[ -n "$t" ]] || continue
                    if cdn_apply_domain "$d" "$s" >/dev/null 2>&1; then ok=$((ok+1)); else bad=$((bad+1)); fi
                done < "$CDN_BIND_FILE"
                print_ok "重新应用完成: 成功 $ok, 失败 $bad"; pause ;;
            5|"") return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}
