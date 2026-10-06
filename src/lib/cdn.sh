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
#   SB 用 conf/cdn_apply.py 把 location 块插进站点配置, 标记是
#   "# >>> SB-Panel CDN 开始 (自动生成, 请勿手改) >>>" —— 注意这个标记
#   **不含域名**。插入前备份、插完 nginx -t 校验、通过才 reload。
#   备份/校验/回滚/重载这一套**与我们的做法一致**, 我们照搬。
#
#   注意: SB 的 cdn.sh 头部注释写着"绝不自动写入你的 Nginx 配置目录, 绝不
#   reload", 那是**过期的注释** —— 它的实际行为是插入 + 校验 + reload。
#   以代码为准, 不要以注释为准。
#
#   本项目额外补上 SB 没有的**按节点回删**:
#   SB 的标记不含域名, 且清除用的是 re.sub (默认替换**全部**匹配), 所以它
#   回答不了"哪一段是我的" —— 一个站点文件挂多个域名时, 插第二个域名会把
#   第一个一起抹掉, 删一个域名会连带删掉全部 (已实测复现)。
#   我们的标记带域名 (# >>> mihomo-core-cdn BEGIN <域名> >>>), 删除时只动
#   本域名那一段; 同一域名下的多个节点共用一段, 内容由绑定表
#   (tag -> 域名/站点) 重渲染得出, 所以删一个节点只掉它自己那个 location。
#
#   location 的内容 (各级指令与坑) 照搬 SB 的实测结论, 不自己造轮子。
#   见 cdn_render_location 里逐条标注的来源。
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

# 注意: **不能**写成 grep -c . file || echo 0 ——
# grep -c 在无匹配时**同时**输出 "0" 并返回退出码 1, 于是 || 又追加一个 0,
# 结果拿到的是 "0\n0", 之后 (( ... )) 直接报 syntax error。
# 必须先捕获再兜底, 不能靠 || 拼接。
cdn_bind_count() {
    cdn_bind_init
    local n
    n=$(grep -c . "$CDN_BIND_FILE" 2>/dev/null) || true
    printf '%s' "${n:-0}"
}

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
    # 同上: 先捕获再兜底, 不能 grep -c ... || echo 0
    left=$(cdn_bind_by_domain "$dom" | grep -c . 2>/dev/null) || true
    left=${left:-0}
    if (( left > 0 )); then
        cdn_apply_domain "$dom" "$site"
    else
        cdn_remove_domain "$dom" "$site"
    fi
}

# =============================================================
# 五之二、节点生命周期钩子
#
# 绑定键统一用**节点片段文件名去掉扩展名** (如 vless-01 / trojan-02)。
# 原因: 创建流程知道 (PROTO + 序号), 删除流程也只知道这个 ——
# 两边唯一都拿得到的稳定标识就是它。用显示用的节点名当键会失败,
# 因为节点名改过之后就对不上了。
# =============================================================
cdn_bind_node() { # <管理协议> <序号> <域名> <站点文件> <传输> <路径> <端口>
    cdn_bind_add "${1}-${2}" "$3" "$4" "$5" "$6" "$7"
}

# 从节点片段里读回它的传输与路径, 供删除时兜底 (片段是唯一真源)
cdn_node_meta_from_fragment() { # <片段文件> -> stdout: 传输|路径
    local f="${1:-}"
    [[ -f "$f" ]] || { printf '||'; return 0; }
    local tr path
    if grep -q 'xhttp-config:' "$f"; then
        tr="xhttp"
        path=$(awk '/xhttp-config:/{f=1;next} f && $1=="path:"{print $2; exit}' "$f")
    elif grep -qE '^[[:space:]]*ws-path:' "$f"; then
        tr="ws"; path=$(awk '/^[[:space:]]*ws-path:/{print $2; exit}' "$f")
    elif grep -qE '^[[:space:]]*grpc-service-name:' "$f"; then
        tr="grpc"; path=$(awk '/^[[:space:]]*grpc-service-name:/{print $2; exit}' "$f")
    elif grep -qE '^[[:space:]]*# h2-path:' "$f"; then
        tr="h2"; path=$(awk '/^[[:space:]]*# h2-path:/{print $3; exit}' "$f")
    else
        tr="tcp"; path=""
    fi
    printf '%s|%s' "$tr" "$path"
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

# =============================================================
# 七、CDN 菜单
#
# ★ 原来的 cdn_menu 是坏的, 而且是**看不见的坏**:
#
#     ui_menu "探测 Nginx 部署方式" "列出所有站点" "查看当前绑定" "重新应用全部绑定" "返回"
#
#   ui_menu 只接受 2 个参数 ($1 编号 / $2 文本)。一次传 5 个, 于是整张
#   菜单只渲染出一行:
#
#       探测 Nginx 部署方式. 列出所有站点
#
#   后面 4 项被静默丢弃 —— 用户看不到任何选项, 只能盲敲数字。
#   而 case 分支还写着 1) 2) 3) 4) 5), 所以敲对了也能用, 更不容易发现。
#
#   这是「两处必须一致但无机制保证」的又一个实例: 菜单的**项**与 case 的
#   **编号**必须一致, 而 ui_menu 的参数个数从来没人检查。
#   已在 tools/check_menu_ids.sh 补上机械校验 (见该脚本"ui_menu 参数个数")。
#
# 菜单项对齐 SB 的 CDN 菜单 (9 项), 但保留我们比 SB 强的两点:
#   * 自动写入 + nginx -t 校验 (与 SB 的 cdn_apply.py 一致)
#   * 按节点回删 (SB 没有 —— 它的插入标记按域名索引, 删一个会连累同域名下别的节点)
# =============================================================

# 列出节点, 并逐个标注能否走 CDN。
# SB 有 `5) 列出节点 (哪些能走 CDN)` —— 用户配 CDN 前第一件想知道的事。
cdn_list_nodes() {
    local f base tr n_total=0 n_cdn=0
    printf '  %-22s %-9s %s\n' "节点" "传输" "能否走 CDN" >&2
    printf '  %s\n' "──────────────────────────────────────────────────────" >&2
    local glob
    for f in $(ls "$SRV_CONFIGD"/*.yaml 2>/dev/null | sort); do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .yaml)
        tr=$(cdn_node_meta_from_fragment "$f" | cut -d'|' -f1)
        n_total=$((n_total + 1))
        if cdn_supported_transport "$tr"; then
            printf '  %-22s %-9s %s\n' "$base" "$tr" "${GREEN}✅ 可以${RESET}" >&2
            n_cdn=$((n_cdn + 1))
        else
            printf '  %-22s %-9s %s\n' "$base" "$tr" "— 原生 TCP/UDP, Cloudflare 代理不了" >&2
        fi
    done
    printf '\n' >&2
    if (( n_total == 0 )); then
        print_info "还没有任何节点"
    else
        print_info "共 $n_total 个节点, 其中 $n_cdn 个能走 CDN"
        print_info "可走 CDN 的传输: $CDN_TRANSPORTS"
    fi
}

# 检查残留 —— 三处状态必须一致, 不一致就是残留:
#   ① 绑定表有, 节点片段已删  → 悬空绑定 (删节点时没走 cdn_node_unregister)
#   ② nginx 有插入标记, 绑定表没有 → 幽灵配置 (手工贴过 / 绑定表被清)
#   ③ 绑定表有, nginx 没标记   → 未生效 (apply 失败过)
#
# SB 有 `8) 检查残留 (节点删了配置还在?)`。这类"删除不干净"的问题
# 不主动查就永远发现不了, 所以值得单独一个菜单项。
cdn_check_residue() {
    cdn_bind_init
    local bad=0
    local t d s tr p pt

    # ① 悬空绑定
    printf '  %s\n' "① 绑定表 → 节点片段" >&2
    local dangling=0
    while IFS=$'\t' read -r t d s tr p pt; do
        [[ -n "$t" ]] || continue
        if [[ ! -f "$SRV_CONFIGD/$t.yaml" ]]; then
            print_warn "  悬空: $t (绑定到 $d, 但节点片段 $t.yaml 已不存在)"
            dangling=$((dangling + 1)); bad=$((bad + 1))
        fi
    done < "$CDN_BIND_FILE"
    (( dangling == 0 )) && print_ok "  没有悬空绑定"

    # ② 幽灵配置 (nginx 里有我们的标记, 但绑定表里没这个 tag)
    printf '\n  %s\n' "② Nginx 插入标记 → 绑定表" >&2
    local ghost=0 marker
    marker="# 由 mihomo--core 面板自动插入"
    while IFS= read -r site; do
        [[ -f "$site" ]] || continue
        while IFS= read -r tag_in_file; do
            [[ -n "$tag_in_file" ]] || continue
            if [[ -z "$(cdn_bind_get "$tag_in_file")" ]]; then
                print_warn "  幽灵: $tag_in_file 的配置还在 $site, 但绑定表里没有"
                ghost=$((ghost + 1)); bad=$((bad + 1))
            fi
        done < <(grep -oE "mihomo-cdn:[^ ]+" "$site" 2>/dev/null | sed 's/^mihomo-cdn://' | sort -u)
    done < <(cdn_site_files_all)
    (( ghost == 0 )) && print_ok "  没有幽灵配置"

    # ③ 绑定表有, 但站点文件里找不到对应标记
    printf '\n  %s\n' "③ 绑定表 → Nginx 插入标记" >&2
    local notapplied=0
    while IFS=$'\t' read -r t d s tr p pt; do
        [[ -n "$t" ]] || continue
        [[ -n "$s" && -f "$s" ]] || continue
        if ! grep -q "mihomo-cdn:$t" "$s" 2>/dev/null; then
            print_warn "  未生效: $t 已登记绑定, 但 $s 里没有它的插入标记"
            notapplied=$((notapplied + 1)); bad=$((bad + 1))
        fi
    done < "$CDN_BIND_FILE"
    (( notapplied == 0 )) && print_ok "  所有绑定都已写入 Nginx"

    printf '\n' >&2
    if (( bad == 0 )); then
        print_ok "三处状态一致, 没有残留"
    else
        print_warn "共发现 $bad 处不一致。用 9) 移除配置 或 7) 重新应用全部绑定 处理。"
    fi
}

# 所有候选站点文件 (去重)。cdn_list_sites 是给人看的表格, 这里要的是路径列表。
#
# ★ 必须用 --list-paths (每行一个路径), **不要**去解析 --list 的表格。
#   原来写的是 `awk -F'|' '{...$2...}'`, 即按**竖线**取第 2 列; 而 --list 的实际
#   格式是 "  {mode:8} {sn:30} {f}" —— **空格分隔**, 根本没有竖线。
#   于是这个函数**永远返回空**, 于是 cdn.sh 的"幽灵配置"自检循环一次都不执行,
#   恒打印 "没有幽灵配置": 一个查不到东西就报成功的假绿灯。
#   与 share_create 的 `awk 'NF==2'` 完全同类 —— 生产者和消费者对格式的理解
#   不一致, 且没有机制保证一致。改用稳定接口, 不再依赖表格长什么样。
cdn_site_files_all() {
    cdn_available || return 0
    python3 "$CDN_APPLY_PY" --list-paths 2>/dev/null
}

# CDN 接入说明。SB 有 `9) CDN 接入说明` —— 把"怎么接"写进面板,
# 用户不用去翻文档。
cdn_help() {
    printf '%s\n' \
"  ── CDN 回源是怎么工作的 ──" \
"" \
"     客户端 ──TLS──> Cloudflare 边缘 ──回源 443──> 你的 Nginx" \
"                                                        │" \
"                                              按 path 分流 │" \
"                                                        ▼" \
"                                              127.0.0.1:<节点端口>" \
"" \
"  要点:" \
"    * 节点只监听 127.0.0.1, 端口不再对外暴露; 客户端连的是你的**域名**," \
"      由 Cloudflare 隐藏源站 IP。" \
"    * 只有跑在 HTTP 上的传输能被 Cloudflare 代理:" \
"        $CDN_TRANSPORTS" \
"      REALITY / AnyTLS / Hysteria2 / TUIC / SS / ShadowTLS 是原生 TCP/UDP" \
"      或专用协议, 代理不了, 必须直连。" \
"    * 域名必须已经在 Cloudflare 上, 且 **橙色云朵已开启** (走代理)。" \
"      灰色云朵 = DNS only, 流量不过 Cloudflare, 这个配置没意义。" \
"    * Cloudflare 免费版回源端口受限, 用 443 最稳。" \
"" \
"  ── 怎么接 ──" \
"    1. 先在 Cloudflare 把这个域名解析到本机, 并打开代理 (橙色云朵)" \
"    2. 用 1) 自动插入, 或 5) 生成片段手工粘贴" \
"    3. 用 8) 检查残留 确认三处状态一致" \
"    4. 删节点时走正常删除流程, 会自动同步清理 Nginx" \
"" \
"  ── 本机情况 ──" >&2
    cdn_probe 2>&1 | sed 's/^/    /' >&2
}

# 导出 CDN 版客户端产物。
#
# 直连节点和 CDN 节点必须能分别取用: 前者的客户端配置写服务器 IP, 后者写
# 域名 (由 Cloudflare 边缘终止 TLS 再按 path 回源), 两者的 host/sni/path
# 完全不同, 混在一起分发必然有人拿到连不上的那份。
#
# 节点片段本身已经按传输区分 (out/<mproto>_<proto>_client-<idx>.yaml,
# CDN 变体的 proto 里带 -cdn), 所以这里**不重新生成配置**, 只做两件事:
#   1. 把已绑定 CDN 的节点挑出来, 在 out/cdn/ 下放一份带 .cdn 标记的副本
#      —— 批量收集/分发时一眼能区分, 不用去猜文件名里的 -cdn 后缀
#   2. 写一份 manifest.tsv, 注明每个产物对应哪个域名和路径
#
# 与 SB 的 cdn_node.sh 同一个思路 (它也复用 to_mihomo.py 而不另写转换),
# 区别是我们的产物已经按传输分好, 不需要二次转换。
cdn_export_artifacts() {
    cdn_bind_init
    if (( $(cdn_bind_count) == 0 )); then
        print_warn "还没有登记任何 CDN 绑定, 没有可导出的产物"
        print_info "先用「1) 自动插入 / 更新回源配置」把节点挂到域名上"
        return 0
    fi

    local dst="$SRV_OUT/cdn"
    mkdir -p "$dst" || { print_error "无法创建 $dst"; return 1; }
    # manifest 每次重写 —— 追加会让上一次的条目残留成"幽灵产物"
    : > "$dst/manifest.tsv"

    local tag dom site tr path port mproto idx n=0 miss=0
    while IFS=$'\t' read -r tag dom site tr path port; do
        [[ -n "$tag" ]] || continue
        # tag 形如 <mproto>-<idx>; 客户端产物形如 <mproto>_<proto>_client-<idx>.yaml
        mproto="${tag%-*}"
        idx="${tag##*-}"
        local src="" f
        for f in "$SRV_OUT/${mproto}_"*"_client-${idx}.yaml"; do
            [[ -f "$f" ]] && { src="$f"; break; }
        done
        if [[ -z "$src" ]]; then
            print_warn "$tag: 找不到客户端产物 (节点可能还没生成或已被删)"
            miss=$(( miss + 1 ))
            continue
        fi
        if ! cp -f "$src" "$dst/${tag}.cdn.yaml" 2>/dev/null; then
            print_warn "$tag: 复制失败"
            miss=$(( miss + 1 ))
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "${tag}.cdn.yaml" "$dom" "$tr" "${path:-/}" "$port" \
            >> "$dst/manifest.tsv"
        n=$(( n + 1 ))
    done < "$CDN_BIND_FILE"

    printf '\n' >&2
    print_ok "已导出 $n 个 CDN 版产物到 $dst"
    (( miss > 0 )) && print_warn "$miss 个绑定没有对应产物 (见上)"
    if (( n > 0 )); then
        printf '\n  %-24s %-30s %s\n' "文件" "域名" "路径" >&2
        printf '  %s\n' "──────────────────────────────────────────────────────────────" >&2
        while IFS=$'\t' read -r tag dom site tr path port; do
            [[ -n "$tag" ]] || continue
            [[ -f "$dst/${tag}.cdn.yaml" ]] || continue
            printf '  %-24s %-30s %s\n' "${tag}.cdn.yaml" "$dom" "${path:-/}" >&2
        done < "$CDN_BIND_FILE"
    fi
    printf '\n' >&2
    print_info "这些配置的服务器地址是域名而非 IP, 只能配合 CDN 使用"
    return 0
}

cdn_menu() {
    while true; do
        ui_clear
        ui_title "CDN 回源管理"
        printf "  登记中的绑定: %s\n" "$(cdn_bind_count)" >&2
        printf "  可走 CDN 的传输: %s\n" "$CDN_TRANSPORTS" >&2
        printf "\n" >&2
        ui_menu  1 "自动插入 / 更新回源配置 (推荐)"
        ui_menu  2 "检测证书 (看有哪些可用)"
        ui_menu  3 "列出站点 (域名 → 配置文件)"
        ui_menu  4 "列出节点 (哪些能走 CDN)"
        ui_menu  5 "生成片段, 手工粘贴到 Nginx"
        ui_menu  6 "查看当前绑定"
        ui_menu  7 "重新应用全部绑定"
        ui_menu  8 "检查残留 (节点删了配置还在?)"
        ui_menu  9 "移除已插入的配置"
        ui_menu 10 "探测 Nginx 部署方式"
        ui_menu 11 "CDN 接入说明"
        ui_menu 12 "导出 CDN 版客户端产物 (out/cdn/)"
        ui_menu  0 "返回"
        local c; c=$(safe_read "选择" "0")
        c=$(clean_input "${c:-}")
        case "$c" in
            1)
                # 从节点列表里选一个挂上去
                local tag
                ui_clear; ui_title "挂到 CDN 的节点"
                cdn_list_nodes
                printf '\n' >&2
                tag=$(safe_read "节点名 (如 vless-01, 留空取消)" "")
                [[ -n "$tag" ]] || continue
                if [[ ! -f "$SRV_CONFIGD/$tag.yaml" ]]; then
                    print_error "找不到节点片段: $SRV_CONFIGD/$tag.yaml"; pause; continue
                fi
                local tr path port
                tr=$(cdn_node_meta_from_fragment "$SRV_CONFIGD/$tag.yaml" | cut -d'|' -f1)
                path=$(cdn_node_meta_from_fragment "$SRV_CONFIGD/$tag.yaml" | cut -d'|' -f2)
                port=$(awk '/^[[:space:]]*port:/{print $2; exit}' "$SRV_CONFIGD/$tag.yaml")
                cdn_bind_menu "$tag" "${port:-0}" "$tr" "$path"
                pause ;;
            2)
                ui_clear; ui_title "本机可用证书"
                if declare -F scan_certs >/dev/null 2>&1; then
                    scan_certs 2>&1 | sed 's/^/  /' >&2
                else
                    print_warn "cert.sh 未加载, 无法扫描证书"
                fi
                pause ;;
            3) cdn_list_sites 2>&1 | sed 's/^/  /' >&2; pause ;;
            4) ui_clear; ui_title "节点与 CDN 适用性"; cdn_list_nodes; pause ;;
            5)
                local dom
                dom=$(safe_read "回源域名" "${CERT_DOMAIN:-}")
                if [[ -z "$dom" ]]; then print_warn "未填域名"; pause; continue; fi
                mkdir -p "$CDN_FRAG_DIR"
                if cdn_render_fragment "$dom" "$CDN_FRAG_DIR/${dom}.conf" >/dev/null; then
                    print_ok "片段已生成: $CDN_FRAG_DIR/${dom}.conf"
                    print_info "贴进 $dom 对应 server{} 内, 然后 nginx -t && nginx -s reload"
                else
                    print_error "生成失败 (该域名下没有可走 CDN 的节点?)"
                fi
                pause ;;
            6)
                ui_clear; ui_title "CDN 绑定"
                if (( $(cdn_bind_count) == 0 )); then
                    print_info "暂无绑定"
                else
                    while IFS=$'\t' read -r t d s tr p pt; do
                        [[ -n "$t" ]] && printf '  %-24s -> %-28s [%s %s] %s\n' "$t" "$d" "$tr" "$p" "$s" >&2
                    done < "$CDN_BIND_FILE"
                fi
                pause ;;
            7)
                local ok=0 bad=0 t d s tr p pt
                while IFS=$'\t' read -r t d s tr p pt; do
                    [[ -n "$t" ]] || continue
                    if cdn_apply_domain "$d" "$s" >/dev/null 2>&1; then ok=$((ok+1)); else bad=$((bad+1)); fi
                done < "$CDN_BIND_FILE"
                print_ok "重新应用完成: 成功 $ok, 失败 $bad"; pause ;;
            8) ui_clear; ui_title "CDN 残留检查"; cdn_check_residue; pause ;;
            9)
                local t d s tr p pt n=0
                while IFS=$'\t' read -r t d s tr p pt; do
                    [[ -n "$t" ]] || continue
                    n=$((n + 1))
                    printf '  %2d) %-22s %s\n' "$n" "$t" "$d" >&2
                done < "$CDN_BIND_FILE"
                if (( n == 0 )); then print_info "暂无绑定, 无需移除"; pause; continue; fi
                local pick
                pick=$(safe_read "要移除的编号 (留空取消)" "")
                [[ -n "$pick" ]] || continue
                local i=0
                while IFS=$'\t' read -r t d s tr p pt; do
                    [[ -n "$t" ]] || continue
                    i=$((i + 1))
                    if [[ "$i" == "$pick" ]]; then
                        cdn_node_unregister "$t"
                        print_ok "已移除 $t 的回源配置"
                        break
                    fi
                done < "$CDN_BIND_FILE"
                pause ;;
            10) cdn_probe 2>&1 | sed 's/^/  /' >&2; pause ;;
            11) ui_clear; ui_title "CDN 接入说明"; cdn_help; pause ;;
            12) ui_clear; ui_title "导出 CDN 版客户端产物"; cdn_export_artifacts; pause ;;
            0|"") return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}
