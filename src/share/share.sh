#!/usr/bin/env bash
# =============================================================
# 分享链接管理 (share)
#
#   节点 → 生成 token → TTL / max_uses → 客户端拉取 → 自动导入
#
# 数据格式为 Mihomo 原生的 `proxies:` YAML,
# 客户端可直接作为 proxy-provider 消费, 无需任何转换器。
# =============================================================

# 允许独立 source: 这里把依赖的路径全部自给自足,
# 否则被父级以非默认路径调用时会写出 OUT_DIR= / MIHOMO_SERVICE= 的空环境变量,
# 服务能启动但永远返回 503。
: "${SRV_ROOT:=/root/catmi/mihomo}"
: "${SRV_OUT:=$SRV_ROOT/out}"
: "${SRV_SERVICE:=mihomo}"
: "${SRV_CONF:=$SRV_ROOT/conf}"
: "${SRV_ENV:=$SRV_ROOT/install_info.env}"
: "${SHARE_DIR:=$SRV_ROOT/share}"
: "${SHARE_PORT:=9443}"
: "${SHARE_SERVICE:=mihomo-share}"

# 客户端侧没有 out/*_client-*.yaml, 节点都在 conf/providers/*.yaml 里。
# 服务端留空即可; 客户端由 client.sh 设成 $SRV_CONF/providers。
# 每份 provider 会单开一个 tag, 这样可以只分享其中一份订阅。
: "${SHARE_PROVIDERS_DIR:=}"

# 自身目录 —— 被父级 source 时 SELF_SHARE_DIR 可能为空,
# 导致 systemd 的 ExecStart 变成 "/share_server.py"。
SH_SHARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# 从 /tmp 之类的临时副本 source 时, 上面的推导会指向那个副本,
# 于是装出来的 unit 里 ExecStart 指向一个下次重启就不存在的文件。
# 所以先验一下 share_server.py 是不是真在这儿, 不是就退回安装目录。
if [[ ! -f "$SH_SHARE_DIR/share_server.py" ]]; then
    for cand in "${SRV_ROOT:-}/src/share" "${SRV_ROOT:-}/share"; do
        [[ -n "$cand" && -f "$cand/share_server.py" ]] && { SH_SHARE_DIR="$cand"; break; }
    done
fi

if ! declare -F m_get_env >/dev/null 2>&1; then
    ENVTOOL="${ENVTOOL:-$(dirname "$SH_SHARE_DIR")/lib/envtool.py}"
    m_get_env() { python3 "$ENVTOOL" get "$1" "$2"; }
fi
: "${BUILD_SUB:=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/build_sub.py}"

SHARES="$SHARE_DIR/shares"

# 允许单独 source (不经过 server.sh)。父级已定义时不覆盖, 保持父级配色。
# UI 原语统一来自 src/lib/ui.sh。被 server.sh source 时那边已经加载过;
# 单独 source (不经父级) 时这里兜一道。
# 之前这里自己定义了一套中文标签 [成功], 与协议脚本的 [OK] 不一致。
_MUI="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/ui.sh"
# shellcheck source=/dev/null
if ! declare -F print_info >/dev/null 2>&1 && [[ -f "$_MUI" ]]; then
    source "$_MUI"
fi

# ---------- 小工具 ----------
# 取本机对外地址。
# 注意: 很多机器开着透明代理 (tproxy/redirect), 连 --noproxy 都绕不出去,
# api.ipify 会返回**代理出口 IP**而不是服务器自己的 IP —— 那样生成的
# 分享链接客户端根本连不上。所以优先级是:
#   1) install_info.env 里管理员自己填的 PUBLIC_IP / link_ip (最可靠)
#   2) 直连 IPv6 (通常不受 IPv4 透明代理影响)
#   3) 最后才用 ipify, 并明确提示可能是出口 IP
# 另外无论如何都会让用户确认一次。
_share_addr() {
    local a=""

    if [[ -n "${SRV_ENV:-}" && -f "${SRV_ENV:-}" ]]; then
        a=$(m_get_env "$SRV_ENV" PUBLIC_IP 2>/dev/null) || a=""
        [[ -z "$a" ]] && a=$(m_get_env "$SRV_ENV" link_ip 2>/dev/null) || a=""
        [[ -n "$a" ]] && { printf "%s" "$a"; return; }
    fi

    # 外部探测回来的地址**必须自检是不是本机真有的地址**。
    # WARP / 透明代理下 curl 拿到的是代理出口地址, 而那个地址并不在本机接口上,
    # 写进分享链接的结果是: 面板显示生成成功, 客户端却连不上。
    # 踩过的坑: 探测回 WARP 出口地址, 而本机地址列表里根本没有它。
    local cand
    for cand in $(curl -s6 --max-time 6 https://api64.ipify.org 2>/dev/null) \
                 $(curl -s4 --max-time 6 https://api.ipify.org 2>/dev/null); do
        [[ -n "$cand" ]] || continue
        if _addr_is_local "$cand"; then
            printf "%s" "$cand"
            return
        fi
        print_warn "探测到地址 $cand 不在本机接口上 (多半是 WARP/透明代理的出口), 已丢弃"
    done

    # 兜底: 直接从本机接口上取, 宁可给一个不完美但一定可达的地址
    _local_addr
}

# 该地址是否挂在本机某个接口上
_addr_is_local() {
    local a="$1"
    [[ -n "$a" ]] || return 1
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$a"
}

# 本机第一个全局单播地址 (优先 IPv4, 兼容性最好)
_local_addr() {
    local v4 v6
    v4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$v4" ]] && { printf "%s" "$v4"; return; }
    v6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^fe80:' | head -1)
    [[ -n "$v6" ]] && { printf "%s" "$v6"; return; }
    return 1
}

# IPv6 字面量必须写成 [addr], 否则 http://2a09::1:9443/ 解析不出来
# 委托给 env.sh 的 m_uri_host —— 分享链接与服务地址用的是同一套规则,
# 两份实现迟早漂移 (这次就差点漂了: 这里只管服务地址, 节点链接全裸着)。
_share_host() {
    m_uri_host "${1:-}"
}

_share_status() {   # 输出 中文状态
    local meta="$1" now
    now=$(date +%s)
    if [[ "$(printf '%s' "$meta" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("enabled",True))' 2>/dev/null)" != "True" ]]; then
        printf "已禁用"; return
    fi
    local exp used maxu
    exp=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("expires_at",0)))' 2>/dev/null)
    used=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("used_count",0)))' 2>/dev/null)
    maxu=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("max_uses",0)))' 2>/dev/null)
    if [[ "$exp" != "0" && "$now" -gt "$exp" ]]; then printf "已过期"; return; fi
    if [[ "$maxu" != "0" && "$used" -ge "$maxu" ]]; then printf "已用尽"; return; fi
    printf "可用"
}

_share_expiry_str() {
    local exp
    exp=$(printf '%s' "$1" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("expires_at",0)))' 2>/dev/null)
    if [[ "$exp" == "0" ]]; then printf "永久"; return; fi
    date -d "@$exp" '+%Y-%m-%d %H:%M' 2>/dev/null || printf "?"
}

# ---------- 生成 ----------
share_create() {
    print_title "生成分享链接"

    # 选节点范围
    printf "\n分享哪些节点?\n"
    printf "  1) 全部节点 (all)\n"
    local i=2 tagname
    local tags
    # ★ 用 --list-tags (每行一个 tag), **不要**去 awk --list 的表格。
    #   原来这里写的是 `awk 'NF==2 && $1!="合计"{print $1}'`, 而 --list 的输出
    #   是 "  trojan_trojan 1 个" = **3 个字段**, 于是过滤**永远为空**:
    #   菜单里除了 "1) 全部节点" 再也列不出任何协议桶, 且没有任何报错 ——
    #   按协议分享这个功能实际是死的。格式一变就静默变空, 这类
    #   "两处必须一致但无机制保证" 是本项目的头号 bug 类, 故改为稳定接口。
    if [[ -n "$SHARE_PROVIDERS_DIR" && -d "$SHARE_PROVIDERS_DIR" ]]; then
        print_info "分享来源: proxy-providers ($SHARE_PROVIDERS_DIR)"
        tags=$(python3 "$BUILD_SUB" --out-dir "$SRV_OUT" \
               --providers-dir "$SHARE_PROVIDERS_DIR" --list-tags 2>/dev/null)
    else
        # 带 --conf-dir: 按 .managed.json 过滤陈旧产物, 列表与实际生成的订阅一致
        tags=$(python3 "$BUILD_SUB" --out-dir "$SRV_OUT" \
               --conf-dir "$SRV_CONF" --list-tags 2>/dev/null)
    fi
    for tagname in $tags; do
        printf "  %d) 仅 %s\n" "$i" "$tagname"; i=$((i+1))
    done
    printf "\n请选择 [默认 1]: "
    local c; read -r c; c="${c:-1}"

    local TAG="all"
    if [[ "$c" =~ ^[0-9]+$ && "$c" -gt 1 ]]; then
        # ★ pick 的初值必须是**空串**, 不能是 0。
        #   原来写 `local idx=2 pick=0`, 而下面判空用的是 `[[ -n "$pick" ]]` ——
        #   "0" 是非空字符串, 所以只要没匹配到 (tag 列表为空, 或用户输入越界编号),
        #   TAG 就会变成字面量 "0"。而 "0" 不是任何协议桶, 于是生成的订阅**是空的**:
        #   用户拿到一条能打开、但里面一个节点都没有的链接, 且全程无提示。
        #   实测在真实部署上复现过 (选 "2" 且列表为空 → tag=0)。
        local idx=2 pick=""
        for tagname in $tags; do
            if [[ "$idx" -eq "$c" ]]; then pick="$tagname"; break; fi
            idx=$((idx+1))
        done
        if [[ -n "$pick" ]]; then
            TAG="$pick"
        else
            print_warn "编号 $c 不在范围内, 已回退为「全部节点」"
        fi
    fi

    # max_uses
    printf "\n最多可拉取次数 (0=不限, 回车=1): "
    local mu; read -r mu; mu="${mu:-1}"
    [[ "$mu" =~ ^[0-9]+$ ]] || { print_error "必须是非负整数"; return 1; }

    # TTL
    printf "\n有效期:\n"
    printf "  1) 1 小时\n  2) 24 小时 (默认)\n  3) 7 天\n  4) 30 天\n  5) 永久\n  6) 自定义小时\n"
    printf "请选择 [默认 2]: "
    local t; read -r t; t="${t:-2}"
    local hours
    case "$t" in
        1) hours=1 ;; 2) hours=24 ;; 3) hours=168 ;; 4) hours=720 ;;
        5) hours=0 ;;
        6) printf "请输入小时数 (0=永久): "; read -r hours; hours="${hours:-24}" ;;
        *) hours=24 ;;
    esac
    [[ "$hours" =~ ^[0-9]+$ ]] || { print_error "必须是非负整数"; return 1; }

    local token expires now
    now=$(date +%s)
    expires=0; [[ "$hours" -gt 0 ]] && expires=$((now + hours * 3600))
    token=$(openssl rand -hex 16)

    # 地址一定要人工确认: 透明代理环境下自动探测经常拿到的是代理出口 IP
    local addr; addr=$(_share_addr)
    printf '\n分享服务对外地址: \033[1m%s\033[0m\n' "$addr"
    printf '若不对 (例如探测到了代理出口 IP), 请直接输入正确地址; 回车表示使用上面的:\n请输入: '
    local a2; read -r a2
    a2=$(clean_input "${a2:-}")
    # 校验: 输错一个字符就会生成一条**永远打不开**的链接, 而界面照样显示
    # 「已生成分享链接」, 用户要等到客户端拉取失败才发现。
    if [[ -n "$a2" ]]; then
        local a2c="${a2#http://}"; a2c="${a2c#https://}"; a2c="${a2c%%/*}"
        # 主机名或 IP。纯数字且看着像端口号的 (输成 "0"/"9443") 会被这条挡掉
        if [[ "$a2c" =~ ^[A-Za-z0-9.:_-]+$ ]] \
           && ! [[ "$a2c" =~ ^[0-9]{1,5}$ ]]; then
            addr="$a2"
        else
            print_error "地址不合法, 已忽略, 继续用上面探测到的: $addr"
        fi
    fi

    mkdir -p "$SHARES"
    python3 - "$SHARES/$token.json" "$token" "$TAG" "$mu" "$expires" <<'PY'
import json, os, sys, time
path, token, tag, maxu, exp = sys.argv[1:6]
meta = {"share_token": token, "tag": tag, "created_at": int(time.time()),
        "expires_at": int(exp), "max_uses": int(maxu), "used_count": 0,
        "enabled": True, "last_used_at": 0}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=1)
PY

    printf '%s' "$addr" > "$SRV_OUT/share_addr.txt"
    printf 'http://%s:%s/share/%s\n' "$(_share_host "$addr")" "$SHARE_PORT" "$token" > "$SRV_OUT/share_tag-$TAG.txt"

    print_ok "已生成分享链接"
    printf '  地址    : %s\n' "$addr"
    printf '  节点范围: %s\n' "$TAG"
    printf '  次数    : %s\n' "$([[ "$mu" == "0" ]] && echo '不限' || echo "$mu")"
    printf '  有效期至: %s\n' "$([[ "$expires" == "0" ]] && echo '永久' || date -d "@$expires" '+%Y-%m-%d %H:%M')"
    printf '\n  链接:\n    \033[1mhttp://%s:%s/share/%s\033[0m\n\n' "$(_share_host "$addr")" "$SHARE_PORT" "$token"

    # ★ 链接打印出来了, 但**没人保证它真的能访问**。
    #   安装分享服务是**另一个菜单项** (share_service_install), 用户完全可以
    #   只生成链接就走 —— 于是拿到一个永远拉不动的 URL: token 文件确实建好了,
    #   但端口上没有任何进程监听, 客户端那边只有 "Connection refused",
    #   而面板这边显示一切正常。实测踩过: 客户端拉取报 Connection refused,
    #   而同一台机器上另一个分享服务的端口却能秒连 —— 网络完全正常, 是服务
    #   压根没起。两处信息对不上, 排查方向很容易被带偏到防火墙上去。
    #
    #   宁可当场说"服务没起", 也不要给一个注定连不上的链接 —— 后者会让人
    #   以为是网络问题、去查防火墙、去换客户端, 方向完全错了。
    if ! systemctl is-active --quiet "$SHARE_SERVICE" 2>/dev/null; then
        # 别只丢一句警告就把一个拉不动的链接交出去 —— 那等于把问题留给用户,
        # 而用户能做的只有"看不懂、换客户端、查防火墙"。直接把它起起来。
        local unit="/etc/systemd/system/$SHARE_SERVICE.service"
        if [[ -f "$unit" ]]; then
            systemctl start "$SHARE_SERVICE" >/dev/null 2>&1
        else
            # 单元还没装 (生成链接和安装服务是两个独立菜单项, 用户只做了前者)
            print_info "分享服务还没安装, 正在安装并启动..."
            share_service_install >/dev/null 2>&1
            systemctl enable --now "$SHARE_SERVICE" >/dev/null 2>&1
        fi
        if systemctl is-active --quiet "$SHARE_SERVICE" 2>/dev/null; then
            print_ok "分享服务已启动, 这个链接现在就能拉取"
        else
            print_warn "分享服务 ($SHARE_SERVICE) 没能启动, 链接暂时拉不动"
            printf '  手动启动: \033[1msystemctl start %s\033[0m\n' "$SHARE_SERVICE"
            print_info "token 已存到 $SHARES/$token.json, 服务起来后链接立即可用, 不用重新生成"
        fi
    fi

    if [[ "$TAG" == "all" ]] && python3 - "$SRV_OUT" <<'PY' 2>/dev/null | grep -q yes; then
import glob, sys, yaml
for f in glob.glob(sys.argv[1] + "/*_client-*.yaml"):
    try:
        for p in (yaml.safe_load(open(f)) or {}).get("proxies") or []:
            if isinstance(p, dict) and (p.get("private-key") or "").strip():
                print("yes"); raise SystemExit
    except SystemExit:
        raise
    except Exception:
        pass
PY
        print_warn "注意: 订阅里包含 mTLS 客户端私钥, 请勿使用永久 / 不限次数的链接"
    fi
}

# ---------- 列表 ----------
# 展示用: 表格一律打到 stdout, 仅供人看。
# 注意 share_list 与 share_pick 必须严格分开:
#   share_list  → 只负责"看", 全部走 stdout
#   share_pick  → 只负责"选", 选中的路径走全局变量 _SHARE_PICKED
# 早期版本让 share_pick 把 share_list 的表格和文件名一起 printf, 捕获方
# 拿到的是"整张表 + 末行文件名", 于是 rm -f 对着垃圾执行返回 0 → 假成功。
_SHARE_PICKED=""

_share_sorted_files() {
    shopt -s nullglob
    local files=("$SHARES"/*.json)
    shopt -u nullglob
    printf '%s\n' "${files[@]}" | sort
}

share_list() {
    print_title "分享链接列表"
    [[ -d "$SHARES" ]] || { print_info "还没有任何分享链接"; return; }
    shopt -s nullglob
    local files=("$SHARES"/*.json)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then print_info "还没有任何分享链接"; return; fi

    printf '\n%-4s %-12s %-34s %-8s %-10s %-18s\n' "编号" "节点" "Token" "状态" "已用/上限" "过期时间"
    printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"
    local i=1 f meta
    for f in $(_share_sorted_files); do
        meta=$(cat "$f" 2>/dev/null) || continue
        local tag tok st used maxu exp
        tag=$(printf '%s' "$meta"  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag","?"))' 2>/dev/null)
        tok=$(printf '%s' "$meta"  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("share_token","?"))' 2>/dev/null)
        used=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("used_count",0)))' 2>/dev/null)
        maxu=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("max_uses",0)))' 2>/dev/null)
        st=$(_share_status "$meta")
        [[ "$st" == "可用" ]] && st="${GREEN}可用${RESET}" || st="${YELLOW}${st}${RESET}"
        printf '%-4s %-12s %-34s %-18b %-10s %-18s\n' \
            "$i" "$tag" "$tok" "$st" \
            "$used/$([[ "$maxu" == "0" ]] && echo ∞ || echo "$maxu")" \
            "$(_share_expiry_str "$meta")"
        i=$((i+1))
    done
    printf '\n'
}

# 交互式选一条分享链接。
# 选中的完整路径写入全局 _SHARE_PICKED, **不往 stdout 打任何东西** ——
# 调用方一律用 _SHARE_PICKED 取值, 绝不要写 f=$(share_pick)。
# 成功返回 0, 取消/无效返回 1。
share_pick() {
    _SHARE_PICKED=""
    # 表格必须走 stderr。
    #
    # 这个函数会被包在命令替换里: f=$(share_pick)。share_list 的 printf 默认
    # 走 stdout, 于是**整张表格和文件名一起被捕获**成 f, 实测后果:
    #   share_delete → rm -f "<整张表格>\n<文件名>" 对不存在的路径返回 0
    #                 → 打印"已删除"而文件纹丝不动
    #   share_toggle → 文件名不合法 → FileNotFoundError, 整张表格进 traceback
    #   share_regen  → 静默什么都没做
    # print_title / print_info 本来就写 stderr, 只有表格这几行 printf 是
    # stdout, 所以这里只重定向 share_list。
    share_list >&2
    printf '请输入编号 [回车取消]: ' >&2
    local n; read -r n
    [[ -n "$n" && "$n" =~ ^[0-9]+$ ]] || { print_info "已取消"; return 1; }
    local -a files=()
    local line
    while IFS= read -r line; do [[ -n "$line" ]] && files+=("$line"); done < <(_share_sorted_files)
    (( n >= 1 && n <= ${#files[@]} )) || { print_error "编号不存在"; return 1; }
    _SHARE_PICKED="${files[$((n-1))]}"
    [[ -f "$_SHARE_PICKED" ]] || { print_error "文件不存在: $_SHARE_PICKED"; _SHARE_PICKED=""; return 1; }
    return 0
}

# ---------- 操作 ----------

# 按 tag 吊销分享链接 —— 删节点时用。
#
# 为什么是"禁用"而不是"删除": 节点删掉后这条链接已经没用了, 但直接删文件
# 会让用户失去记录 (发给谁、什么时候、用过几次)。禁用让它**立刻返回 410**,
# 记录还在, 需要时可以再启用。这与分享服务端的约定一致
# (share_server.py: "200 订阅 / 404 不存在 / 410 失效 / 503 暂不可用")。
#
# ★ 匹配规则 (mode):
#     prefix (默认) —— tag 相同, **或以 "<tag>_" 开头**
#     exact        —— tag 完全相同
#
#   默认必须是 prefix, 因为产物命名有**两套**:
#     单协议菜单  → out/<proto>_client-NN.yaml
#     批量 all.sh → out/<mproto>_<proto>_client-NN.yaml
#                   (前缀是为避免同协议多变体互相覆盖, all.sh 里有注释说明)
#   而 build_sub.py 的 CLIENT_RE 取的是 "_client-" 之前的**全部**内容:
#     CLIENT_RE = r"^(?P<proto>.+?)_client-(?P<num>\d+)\.yaml$"
#   于是同一个 trojan 节点, 走单协议得到 tag=`trojan`,
#   走批量得到 tag=`trojan_trojan` / `trojan_trojan-grpc` / `trojan_trojan-tls`。
#   只按 exact 匹配的话, 批量生成的节点吊销会**静默失效** —— 面板报成功,
#   链接照旧能拉。实测过: 传 `trojan` 时 tag=`trojan_trojan` 的那条纹丝不动。
#
# 结果写进全局 _SHARE_REVOKED_N, 供调用方决定要不要提示。
share_revoke_by_tag() {
    local tag="${1:-}" mode="${2:-prefix}"
    _SHARE_REVOKED_N=0
    [[ -n "$tag" ]] || return 0
    [[ -d "${SHARES:-}" ]] || return 0
    local f out
    for f in "$SHARES"/*.json; do
        [[ -f "$f" ]] || continue
        # python 的输出要自己收, 不能裸跑 (裸跑时 stdout 混进面板流)
        out=$(python3 - "$f" "$tag" "$mode" <<'PY' 2>/dev/null
import json, sys, time
p, tag, mode = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    m = json.load(open(p, encoding="utf-8"))
except Exception:
    raise SystemExit(0)
have = m.get("tag")
if not isinstance(have, str):
    raise SystemExit(0)
ok = (have == tag) if mode == "exact" else (have == tag or have.startswith(tag + "_"))
if not ok:
    raise SystemExit(0)
if not m.get("enabled", True):
    raise SystemExit(0)
m["enabled"] = False
m["revoked_at"] = int(time.time())
m["revoked_reason"] = "node deleted"
with open(p, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=1, ensure_ascii=False)
print("revoked")
PY
        )
        [[ "$out" == "revoked" ]] && _SHARE_REVOKED_N=$(( _SHARE_REVOKED_N + 1 ))
    done
    return 0
}

# 删节点后的用户可见提示。
#
# ★ 调用时机有硬约束: **必须在校验通过之后**。清空路径 (server.sh) 里记过
#   这个坑 —— 校验失败会回滚配置, 那时节点还在, 而 token 已经吊销了, 用户
#   手里的链接就莫名其妙全废。所以调用点是
#       delete_config; m_sync_reload && share_revoke_on_delete ...
#   而不是在 delete_config 内部。
share_revoke_on_delete() {
    local tag="${1:-}" label="${2:-${1:-}}"
    # 空 tag = 这次没有真的删掉任何节点 (比如用户输了个不存在的编号),
    # 静默返回, 既不吊销也不提示。
    [[ -n "$tag" ]] || return 0
    share_revoke_by_tag "$tag"
    if (( ${_SHARE_REVOKED_N:-0} > 0 )); then
        print_info "已吊销 ${label} 的分享链接 ${_SHARE_REVOKED_N} 条 (立即返回 410)"
        print_warn "分享粒度是协议桶不是单节点 —— 同协议其它节点的链接也一并失效了"
    fi
    # tag=all 的链接**不吊销**: 它还包含其它节点, 吊销它会误伤。但要说清楚。
    local alln=0
    if [[ -d "${SHARES:-}" ]]; then
        alln=$(grep -l '"tag"[[:space:]]*:[[:space:]]*"all"' "$SHARES"/*.json 2>/dev/null | wc -l) || alln=0
    fi
    (( alln > 0 )) && print_info "另有 ${alln} 条 tag=all 的链接仍可用 (它们还包含其它节点)"
    return 0
}

share_delete() {
    print_title "删除分享链接"
    share_pick || return
    local f="$_SHARE_PICKED"
    local tok; tok=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("share_token","?"))' "$f" 2>/dev/null || echo "?")
    rm -f "$f" || { print_error "删除失败: $f"; return; }
    # 必须回读确认, 否则 rm 静默失败时仍会报"已删除"(实测过的假成功)
    [[ -e "$f" ]] && { print_error "删除失败, 文件仍在: $f"; return; }
    print_ok "已删除分享链接 (token ${tok:0:12}...)"
}

share_toggle() {
    print_title "启用 / 禁用分享链接"
    share_pick || return
    local f="$_SHARE_PICKED"
    # python 的输出要自己收, 不能裸跑 (裸跑时 stdout 混进面板流)
    local out rc
    out=$(python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m["enabled"] = not m.get("enabled", True)
with open(p, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=1)
print("enabled" if m["enabled"] else "disabled")
PY
) || { print_error "切换失败: $f"; return; }
    # 回读确认真的落盘了
    local now; now=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("enabled"))' "$f" 2>/dev/null)
    case "$out" in
        enabled)  [[ "$now" == "True" ]] && print_ok "已启用" || print_error "启用未生效" ;;
        disabled) [[ "$now" == "False" ]] && print_ok "已禁用" || print_error "禁用未生效" ;;
        *) print_error "切换失败 (未知返回: $out)" ;;
    esac
}

share_regen() {
    print_title "重新生成 Token"
    share_pick || return
    local f="$_SHARE_PICKED"
    local old; old=$(basename "$f" .json)
    printf '重新生成后旧链接立即失效 (404)。确认? (y/N): '
    local c; read -r c
    [[ "$c" =~ ^[yY]$ ]] || { print_info "已取消"; return; }
    local new; new=$(openssl rand -hex 16)
    mv -f "$f" "$SHARES/$new.json" || { print_error "移动失败"; return; }
    python3 - "$SHARES/$new.json" "$new" <<'PY' || { print_error "写入新 token 失败"; return; }
import json, sys
p, tok = sys.argv[1], sys.argv[2]
m = json.load(open(p))
m["share_token"] = tok
with open(p, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=1)
PY
    # 回读确认 token 真的换了 (实测过静默不生效)
    local got; got=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("share_token"))' "$SHARES/$new.json" 2>/dev/null)
    [[ "$got" == "$new" ]] || { print_error "token 未生效 (当前: ${got:-无})"; return; }
    print_ok "已重新生成"
    printf '  旧: %s\n  新: %s\n' "$old" "$new"
}

share_show_url() {
    print_title "查看分享链接"
    share_pick || return
    local f="$_SHARE_PICKED"
    local tag addr
    tag=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("tag","all"))' "$f")
    addr=$(_share_addr)
    local tok; tok=$(basename "$f" .json)
    printf '\n  自动探测地址: %s\n' "$addr"
    printf '若不对请输入正确地址, 回车使用上面: '
    local a2; read -r a2
    [[ -n "$a2" ]] && addr="$a2"
    printf '\n  http://%s:%s/share/%s\n\n' "$(_share_host "$addr")" "$SHARE_PORT" "$tok"
    printf '  客户端: 把这行填进「添加节点 → 分享链接」即可\n\n'
}

# ---------- 服务 ----------
share_service_status() {
    local st
    st=$(systemctl is-active "$SHARE_SERVICE" 2>/dev/null)
    if [[ "$st" == "active" ]]; then
        printf '  %s运行中%s  端口 %s\n' "$GREEN" "$RESET" "$SHARE_PORT"
    else
        printf '  %s未运行%s  (分享链接暂时无法访问)\n' "$YELLOW" "$RESET"
    fi
}

share_service_install() {
    print_title "安装分享服务"
    local unit="/etc/systemd/system/$SHARE_SERVICE.service"
    cat > "$unit" <<EOF
[Unit]
Description=Mihomo Share Service (token/TTL/max_uses)
After=network-online.target $SRV_SERVICE.service
Wants=network-online.target

[Service]
Type=simple
Environment=SHARE_DIR=$SHARE_DIR
Environment=SHARE_PORT=$SHARE_PORT
Environment=OUT_DIR=$SRV_OUT
Environment=CONF_DIR=$SRV_CONF
Environment=BUILD_SUB=$BUILD_SUB
Environment=MIHOMO_SERVICE=$SRV_SERVICE
Environment=PROVIDERS_DIR=$SHARE_PROVIDERS_DIR
ExecStart=/usr/bin/python3 ${SELF_SHARE_DIR:-$SH_SHARE_DIR}/share_server.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SHARE_SERVICE" >/dev/null 2>&1

    # 先停掉旧实例并清掉可能残留的手工进程, 否则会
    # "Address already in use" 反复重启
    systemctl stop "$SHARE_SERVICE" 2>/dev/null
    for pid in $(pgrep -f "[s]hare_server.py" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
    sleep 1

    systemctl restart "$SHARE_SERVICE" && print_ok "分享服务已启动" || print_error "启动失败"
    sleep 1
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SHARE_PORT/status" 2>/dev/null)
    [[ "$code" == "200" ]] && print_ok "健康检查通过" || print_warn "健康检查未通过 (HTTP $code)"

    # 防火墙: 只提示, 不擅自改。
    # 真正放行了的话登记进 .fw-ports, 卸载时按清单精确回收 ——
    # 借鉴 参考实现 的做法: 不扫防火墙全表, 避免误删用户自己的规则。
    printf '\n'
    printf "  %s[信息]%s 若外部访问不通, 请放行端口:\n" "$CYAN" "$RESET" >&2
    printf "    firewall-cmd --add-port=%s/tcp --permanent && firewall-cmd --reload\n" "$SHARE_PORT" >&2
    printf "    或 ufw allow %s/tcp\n" "$SHARE_PORT" >&2
    printf "    (手动放行的端口卸载时不会自动回收, 需要的话请自己撤)\n" >&2

    # 顺带检查: 端口在本机监听但防火墙没放行, 是"生成分享链接却拉不到"
    # 的最常见原因, 值得当场指出
    if ss -lntH 2>/dev/null | grep -qE ":${SHARE_PORT}[[:space:]]"; then
        if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw status 2>/dev/null | grep -q "${SHARE_PORT}/tcp" \
                || print_warn "ufw 已启用但未放行 ${SHARE_PORT}/tcp, 外部将无法访问"
        elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --list-ports 2>/dev/null | grep -q "${SHARE_PORT}" \
                || print_warn "firewalld 已启用但未放行 ${SHARE_PORT}/tcp, 外部将无法访问"
        fi
    fi
}

share_service_restart() {
    systemctl restart "$SHARE_SERVICE" && print_ok "已重启" || print_error "重启失败"
}

share_service_stop() {
    systemctl stop "$SHARE_SERVICE" && print_ok "已停止" || print_warn "停止失败"
}

# ---------- 菜单 ----------
share_menu() {
    while true; do
        print_title "分享链接管理"
        share_service_status
        printf '\n'
        ui_menu 1 "生成分享链接"
        ui_menu 2 "查看全部分享链接"
        ui_menu 3 "查看链接地址"
        ui_menu 4 "禁用 / 启用"
        ui_menu 5 "重新生成 Token"
        ui_menu 6 "删除分享链接"
        ui_menu 7 "安装 / 启用分享服务"
        ui_menu 8 "重启分享服务"
        ui_menu 9 "停止分享服务"
        ui_menu 0 "返回"
        printf "\n请选择 [0-9]: "
        local c; read -r c || { printf "\n[信息] 非交互环境 (stdin 已关闭), 已退出\n" >&2; break; }
        case "$c" in
            1) share_create ;;
            2) share_list ;;
            3) share_show_url ;;
            4) share_toggle ;;
            5) share_regen ;;
            6) share_delete ;;
            7) share_service_install ;;
            8) share_service_restart ;;
            9) share_service_stop ;;
            0) return ;;
            *) ui_invalid "$c" ;;
        esac
        printf "\n按回车继续..."; read -r || break
    done
}

# 直接执行时进入菜单
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source "$(dirname "$SH_SHARE_DIR")/lib/env.sh"
    share_menu
fi
# ---------- 非交互生成: 批量生成完直接给一条能用的链接 ----------
#
# 为什么要有这个: 交互式那条 (share_gen_tag) 会问"对外地址对不对", 因为透明
# 代理环境下自动探测经常拿到代理出口 IP, 输错一个字符就会生成一条永远打不开
# 的链接。**这个判断必须保留**, 所以批量生成完不能替用户瞎选一个地址。
#
# 折中: 用探测到的地址生成, 但**把地址显示出来并说明可以自己改**; 同时把
# token 落盘, 用户随后在面板里改了地址也不用重新生成节点, 换一个链接即可。
#
# 参数: <tag> <次数 0=不限> <有效期小时 0=永久>
share_gen_tag_auto() {
    local TAG="${1:-all}" MU="${2:-1}" HOURS="${3:-24}"
    [[ "$MU" =~ ^[0-9]+$ ]] || MU=1
    [[ "$HOURS" =~ ^[0-9]+$ ]] || HOURS=24
    declare -F _share_addr >/dev/null 2>&1 || { printf '0'; return 1; }

    local now expires token addr
    now=$(date +%s)
    expires=0; [[ "$HOURS" -gt 0 ]] && expires=$((now + HOURS * 3600))
    token=$(openssl rand -hex 16)
    addr=$(_share_addr)

    mkdir -p "$SHARES"
    python3 - "$SHARES/$token.json" "$token" "$TAG" "$MU" "$expires" <<'PY'
import json, sys, time
path, token, tag, maxu, exp = sys.argv[1:6]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"share_token": token, "tag": tag, "created_at": int(time.time()),
               "expires_at": int(exp), "max_uses": int(maxu), "used_count": 0,
               "enabled": True, "last_used_at": 0}, fh, indent=1)
PY
    printf '%s' "$addr" > "$SRV_OUT/share_addr.txt"
    printf 'http://%s:%s/share/%s\n' "$(_share_host "$addr")" "$SHARE_PORT" "$token" > "$SRV_OUT/share_tag-$TAG.txt"

    # 服务没起就直接拉起 —— 否则刚生成的链接当场就是拉不动的
    if ! systemctl is-active --quiet "$SHARE_SERVICE" 2>/dev/null; then
        local unit="/etc/systemd/system/$SHARE_SERVICE.service"
        if [[ -f "$unit" ]]; then
            systemctl start "$SHARE_SERVICE" >/dev/null 2>&1
        else
            share_service_install >/dev/null 2>&1
            systemctl enable --now "$SHARE_SERVICE" >/dev/null 2>&1
        fi
    fi

    local link; link="http://$(_share_host "$addr"):$SHARE_PORT/share/$token"
    printf '\n  %s一次性分享链接%s  %s用 %s 次 · %s 小时后过期%s\n' \
        "$GREEN" "$RESET" "$DIM" "$MU" "$([[ "$HOURS" -gt 0 ]] && echo "$HOURS" || echo "永久")" "$RESET"
    printf '  %s%s%s\n' "$BOLD" "$link" "$RESET"
    if ! systemctl is-active --quiet "$SHARE_SERVICE" 2>/dev/null; then
        printf '  %s分享服务没能启动, 上面这条暂时拉不动%s\n' "$YELLOW" "$RESET"
    else
        printf '  %s地址探测自本机; 若客户端拉不到, 面板「生成分享链接」里可改地址重发%s\n' "$DIM" "$RESET"
    fi
    return 0
}
