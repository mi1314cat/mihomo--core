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
: "${SHARE_SERVICE:=proxy-share-service}"

# 客户端侧没有 out/*_client-*.yaml, 节点都在 conf/providers/*.yaml 里。
# 服务端留空即可; 客户端由 client.sh 设成 $SRV_CONF/providers。
# 每份 provider 会单开一个 tag, 这样可以只分享其中一份订阅。
: "${SHARE_PROVIDERS_DIR:=}"

# 自身目录 —— 被父级 source 时 SELF_SHARE_DIR 可能为空。
SH_SHARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# 从 /tmp 之类的临时副本 source 时, 上面的推导会指向那个副本。
# 用 build_sub.py 作为"这个目录是不是真的 share 目录"的判据 ——
# 它一直在, 而 share_server.py 已经拆掉了 (/share/ 归公共服务,
# /sub/ 归 lan_server.py)。
if [[ ! -f "$SH_SHARE_DIR/build_sub.py" ]]; then
    for cand in "${SRV_ROOT:-}/src/share" "${SRV_ROOT:-}/share"; do
        [[ -n "$cand" && -f "$cand/build_sub.py" ]] && { SH_SHARE_DIR="$cand"; break; }
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


# =============================================================
# 公共分享服务适配层
#
# ★ 架构: 分享的存储与生命周期 (Token / TTL / max_uses / 次数 / 过期) 归
#   **公共服务** proxy-share-service —— 它是服务器上的公共基础服务,
#   不是 M 的子服务。SB / X 以后接的是同一个它。
#
#   M 只负责: 生成内容、决定什么时候创建与刷新、面板怎么展示。
#   本文件通过 share_client.py 调它。**面板九项菜单与全部文案保持不变。**
#
#   provider 固定为 mihomo —— 公共服务的列表与删除接口**强制**要求带
#   provider 参数, 所以 M 在结构上不可能看到、也不可能误删 SB/X 的分享。
# =============================================================
SHARE_CLIENT="${SHARE_CLIENT:-${SH_SHARE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}/share_client.py}"

# 公共服务的实际端口 —— 它可能因端口回避而**不是** 9443, 绝不能写死
_share_port() {
    local p=""
    [[ -f "$SHARE_CLIENT" ]] && p=$(python3 "$SHARE_CLIENT" port 2>/dev/null)
    printf '%s' "${p:-${SHARE_PORT:-9443}}"
}

# 确保公共服务在位 (不存在则从独立项目安装)。失败不致命 —— 面板照常能开。
share_service_ensure() {
    [[ -f "$SHARE_CLIENT" ]] || return 1
    python3 "$SHARE_CLIENT" ensure >/dev/null 2>&1
}

_share_api() { python3 "$SHARE_CLIENT" "$@"; }

# 列出 M 自己的分享 (JSON 数组, 创建时间倒序)。可选按 type 过滤。
_share_api_list() {
    if [[ -n "${1:-}" ]]; then _share_api list --type "$1" 2>/dev/null
    else _share_api list 2>/dev/null; fi
}

_share_status() {   # 输出 中文状态  (入参: 公共服务的记录 JSON)
    local st
    st=$(printf '%s' "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("state",""))' 2>/dev/null)
    case "$st" in
        active)   printf '可用' ;;
        disabled) printf '已禁用' ;;
        expired)  printf '已过期' ;;
        used_up)  printf '已用尽' ;;
        *)        printf '未知' ;;
    esac
}


_share_expiry_str() {
    local exp
    exp=$(printf '%s' "$1" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("expires_at",0)))' 2>/dev/null)
    if [[ "$exp" == "0" ]]; then printf "永久"; return; fi
    date -d "@$exp" '+%Y-%m-%d %H:%M' 2>/dev/null || printf "?"
}

# =============================================================
# 三家互通 · 两个产品 + 内核声明
#
# 设计: proxy-node-compat/docs/three-way-interop.md (参照实现: xray--core,
# 真机验收: research/integration/three-way-interop-x.md)
#
#   普通话 (URI 列表)  = 主记录, 任何客户端都能读 (xbd / sb-client / mihomo / 第三方)
#   原生   (mihomo YAML) = 附带记录, 只有 mihomo 内核读
#
# 为什么 M 也要这么发: M 的原生产品是 `proxies:` YAML, 跨内核客户端 (Xray 的
#   xbd) 读不了 —— 实测对 mihomo YAML 解析出 19 个空壳、导入 **0/19**。这不是
#   谁的 bug, 是跨生态格式边界; 解法不是让 xbd 学 YAML, 而是 M 也产出普通话。
#
# 声明写在**地址的查询串**里: 公共服务的路由先剥查询串再分发, 所以带声明的
#   地址对第三方客户端零影响(拿到的仍是原来那份载荷)。放响应头/独立 /meta
#   端点两条路都被冻结的公共服务堵死了(设计文档 §1)。
#
# ★ 一条分享 = **两条记录**: 停用 / 撤销 / 删除 / 重建 token 必须成对处理 ——
#   只动主记录会留下一条还活着的原生记录: 用户以为停了/撤了, 带声明的地址却
#   依然能拉到同一批节点。这个错误是静默的(面板上主记录显示"已停用")。
# =============================================================
INTEROP_PY="${INTEROP_PY:-${SH_SHARE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}/../lib/interop.py}"
BUILD_URI="${BUILD_URI:-${SH_SHARE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}/build_uri.py}"

# 本机内核事实(真探测: mihomo -v)。探测不到发行版 → **不产出原生、不声明原生**:
# 不猜一个默认值(声明里的标签必须和 compat 判能力用的标签是同一个字符串)。
_share_self_facts() { python3 "$INTEROP_PY" self 2>/dev/null; }
_share_fact() { # <facts json> <字段名>
    printf '%s' "$1" | python3 -c 'import sys, json
try: print((json.load(sys.stdin) or {}).get(sys.argv[1], "") or "")
except Exception: print("")' "$2" 2>/dev/null
}

# 普通话产品正文 → 打印文件路径(失败返回 1)。与 _share_make_content 同形。
_share_make_uri_content() { # <tag> <输出文件>
    local tag="$1" out="$2"
    if [[ -n "${SHARE_PROVIDERS_DIR:-}" && -d "${SHARE_PROVIDERS_DIR:-}" ]]; then
        python3 "$BUILD_URI" --out-dir "$SRV_OUT" \
            --providers-dir "$SHARE_PROVIDERS_DIR" --tag "$tag" -o "$out" \
            >/dev/null 2>"$out.loss" || return 1
    else
        python3 "$BUILD_URI" --out-dir "$SRV_OUT" --conf-dir "$SRV_CONF" \
            --tag "$tag" -o "$out" >/dev/null 2>"$out.loss" || return 1
    fi
    # 一条链接都做不出来 = 空产品, 不许当成成功发出去
    grep -qE '^[a-z0-9+.-]+://' "$out" 2>/dev/null || return 1
    return 0
}

# 把声明并进订阅地址 —— 声明只有 interop.py 一处实现(客户端读的是同一份定义)
#
# ★ 两处收束 (2026-10-11, 用户拍板"链接太长, 该收束的收束"):
#   1) **不再产出 `version`**。版本没有丢: 原生产品的 record meta 里自描述
#      `{"interop":1,"kernel":…,"distribution":…,"version":…}` (见 _share_create_records)。
#      解析侧**仍然接受** version(第三方可能写), 只是它不参与决策。
#   2) 原生产品**同源时写相对路径** `/share/<token>`, 异源才写绝对地址。
#      解析侧按主地址的 `scheme://netloc` 拼回 (src/lib/interop.py:_resolve_native_ref);
#      旧实现看到相对路径判 `bad-native-url` → 回退普通话(**安全且可见**),
#      所以不需要 bump schema。
_share_declare_url() { # <主地址> <发行版> [原生地址(绝对)]
    local url="$1" dist="$2" native="${3:-}"
    local -a extra=()
    [[ -n "$native" && -n "$dist" ]] \
        && extra=(--url-"$dist" "$(_share_native_ref "$url" "$native")")
    python3 "$INTEROP_PY" declare --kernel mihomo --distribution "$dist" \
        --url "$url" "${extra[@]}" 2>/dev/null
}

# 原生取件地址的形态: **同源 → 相对路径, 异源 → 绝对地址**。
#
# "同源" 严格按 (scheme, host:port) 相等判 —— 只比 host 不比端口的话, 同一台机器
# 上不同端口的分享服务会被误判成同源, 拼出来的相对路径会指向**另一个服务**。
_share_native_ref() { # <主地址> <原生绝对地址>
    python3 - "$1" "$2" <<'PYN'
import sys, urllib.parse
main = urllib.parse.urlsplit(sys.argv[1])
nat = urllib.parse.urlsplit(sys.argv[2])
if (main.scheme, main.netloc) == (nat.scheme, nat.netloc) and nat.path:
    print(urllib.parse.urlunsplit(("", "", nat.path, nat.query, nat.fragment)))
else:
    print(sys.argv[2])
PYN
}

# 一条分享记录 meta 里的字段(点分路径)。取不到打印空串 —— 调用方一律按
# "空 = 旧记录 / 没有原生产物"处理, 不许猜。
_share_meta_field() { # <token> <点分路径>
    local rec
    rec=$(_share_api get --token "$1" 2>/dev/null) || return 0
    [[ -n "$rec" ]] || return 0
    printf '%s' "$rec" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print(d if isinstance(d, str) else ("" if d is None else d))' "$2" 2>/dev/null
}

# 一条分享记录的原生产物 token(没有则空)
_share_native_of() { _share_meta_field "$1" meta.native_token; }

# 一条记录的角色(primary / native / 空=旧记录)
_share_role_of() { _share_meta_field "$1" meta.role; }

# 用户选中的 token 若是**原生产物**, 换成它的主记录 —— 两个方向都要能处理:
# 列表里点的那条可能是任意一条, 而"停用/撤销"必须成对生效。
_share_primary_of() {
    local tok="$1" role parent
    role=$(_share_role_of "$tok")
    [[ "$role" == "native" ]] || { printf '%s' "$tok"; return 0; }
    parent=$(_share_meta_field "$tok" meta.parent)
    printf '%s' "${parent:-$tok}"
}

# 一条主记录 → 它自己 + 它的原生记录(每行一个 token; 不存在的行不打印)
_share_pair_of() {
    local tok="$1" role ntok
    role=$(_share_role_of "$tok")
    if [[ "$role" == "native" ]]; then
        tok=$(_share_primary_of "$tok")
        role=$(_share_role_of "$tok")
    fi
    printf '%s\n' "$tok"
    ntok=$(_share_native_of "$tok")
    [[ -n "$ntok" ]] && printf '%s\n' "$ntok"
    return 0
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

    local token

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

    # 内容由 M 生成 (公共服务不解析它), 交给公共服务保存并管理生命周期
    local ttl_s
    ttl_s=0; [[ "$hours" -gt 0 ]] && ttl_s=$((hours * 3600))
    local recrec
    if ! recrec=$(_share_create_records "$TAG" "$mu" "$ttl_s" "$addr"); then
        print_error "公共服务创建分享失败 —— 服务是否在运行? (面板选项 7 可检查)"
        return 1
    fi
    local tok ntok declared
    tok=$(printf '%s' "$recrec" | awk -F'\t' '{print $1}')
    ntok=$(printf '%s' "$recrec" | awk -F'\t' '{print $2}')
    declared=$(printf '%s' "$recrec" | awk -F'\t' '{print $3}')
    local rec
    rec=$(_share_api get --token "$tok" 2>/dev/null)
    token="$tok"

    printf '%s' "$addr" > "$SRV_OUT/share_addr.txt"
    # ★ 落盘的是**带声明的地址** —— 用户从这里复制才带内核声明; 复制裸地址的话
    #   客户端永远只能走普通话(声明缺失), 且没有任何报错。
    printf '%s\n' "$declared" > "$SRV_OUT/share_tag-$TAG.txt"

    print_ok "已生成分享链接"
    printf '  地址    : %s\n' "$addr"
    printf '  节点范围: %s\n' "$TAG"
    printf '  次数    : %s\n' "$([[ "$mu" == "0" ]] && echo '不限' || echo "$mu")"
    # 有效期从**公共服务返回的记录**里取 —— 原来这里用的是本地算的 $expires,
    # 那个变量在改成"由公共服务生成 token/有效期"之后已经不存在了, 于是
    # 面板会打出 `date: invalid date '@'` (实测踩到)。
    local exp_s
    exp_s=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("expires_at",0)))' 2>/dev/null)
    if [[ "${exp_s:-0}" == "0" ]]; then
        printf '  有效期至: 永久\n'
    else
        printf '  有效期至: %s\n' "$(date -d "@$exp_s" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    fi
    # ★ 打印**带声明的地址**(客户端据此决定拉原生还是普通话), 以及"这次发了
    #   哪几种格式" —— 用户要能一眼看出这条链接发的是什么。
    printf '\n  链接 (带内核声明, 客户端据此选格式):\n    \033[1m%s\033[0m\n\n' "$declared"
    if [[ -n "$ntok" ]]; then
        print_info "格式: 普通话(URI 列表) + 原生(mihomo YAML —— 同内核同发行版自动拉原生, 其余走普通话)"
    else
        print_info "格式: 仅普通话(URI 列表) —— 地址上仍带声明, 客户端据此走通用格式"
    fi
    # ★ 主地址从 YAML 换成了 URI 列表, 这对**客户端**有一个前提: 它得认得
    #   一行行分享链接。仓库自 2026-10-10 23:32 (60fb4c5) 起支持; 更早的构建
    #   对主地址会报"[ERR] 不是合法的 Mihomo 订阅 (需要顶层 proxies: 列表)"
    #   (真机实测: CC 上那份 2026-10-10 12:22 的构建就是这样)。
    #   已发出的旧链接内容不变、照旧可用 —— 受影响的只有**新建**的分享。
    print_info "提示: 客户端需认得 URI 列表 (仓库 2026-10-10 23:32 起); 更早的构建请先更新客户端"

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
    # ★ 判据改成**公共服务的健康检查**, 不再看 mihomo-share 这个旧单元名。
    #   原来这里 `systemctl is-active mihomo-share` 一律返回 false (服务已经
    #   改名了), 于是每次都误报"分享服务还没安装"、还去尝试启动一个不存在的
    #   单元, 并打印一句早已不成立的"token 已存到 local/*.json"(实测踩到)。
    if [[ -f "$SHARE_CLIENT" ]] && ! python3 "$SHARE_CLIENT" health >/dev/null 2>&1; then
        print_info "公共分享服务未运行, 正在启动..."
        share_service_install >/dev/null 2>&1
        if python3 "$SHARE_CLIENT" health >/dev/null 2>&1; then
            print_ok "公共分享服务已就绪, 这个链接现在就能拉取"
        else
            print_warn "公共分享服务没能启动, 链接暂时拉不动"
            printf '  排查: \033[1mbash /root/Share-Service/install.sh --check\033[0m\n'
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



# 把 M 自己的分享渲染成表格行: 类型/范围 \t 状态 \t 已用 \t 上限 \t token
#
# ★ node 与 config 两类资源在这里**必须能区分** —— 这是面板对用户的责任,
#   公共服务那边两者行为完全一致, 区别只在展示。
_share_rows() {
    _share_api_list | python3 -c '
import sys, json
try:
    recs = json.load(sys.stdin)
except Exception:
    recs = []
for r in recs:
    t = r.get("type", "")
    m = r.get("meta") or {}
    if t == "config":
        scope = "[配置] 完整配置"
    else:
        scope = "[节点] " + (str(m.get("tag") or "-"))
    role = m.get("role") or ""
    fmts = m.get("formats") or []
    if isinstance(fmts, str): fmts = [fmts]
    if role == "native":
        kind = "原生"
    elif fmts:
        kind = "普通话+" + ",".join(x for x in fmts if x != "uri")
    elif role == "primary":
        kind = "普通话"
    else:
        kind = "旧记录(YAML)"
    print("%s\t%s\t%s\t%s\t%s\t%s\t%s" % (
        t, scope, r.get("token", ""), r.get("state", ""),
        int(r.get("used_count", 0)), int(r.get("max_uses", 0)), kind))
' 2>/dev/null
}

share_list() {
    print_title "分享链接列表"
    local rows; rows=$(_share_rows)
    if [[ -z "$rows" ]]; then
        print_info "还没有任何分享链接"
        _share_legacy_hint
        return
    fi

    printf '\n%-4s %-22s %-34s %-8s %-11s %-16s %s\n' "编号" "类型 / 范围" "Token" "状态" "已用/上限" "过期时间" "格式"
    printf '%s\n' "──────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    local i=1 t scope tok st used maxu kind rec
    while IFS=$'\t' read -r t scope tok st used maxu kind; do
        [[ -n "$tok" ]] || continue
        rec=$(_share_api get --token "$tok" 2>/dev/null)
        local st_cn
        st_cn=$(_share_status "$rec")
        [[ "$st_cn" == "可用" ]] && st_cn="${GREEN}可用${RESET}" || st_cn="${YELLOW}${st_cn}${RESET}"
        printf '%-4s %-22s %-34s %-18b %-11s %-16s %s\n' \
            "$i" "$scope" "$tok" "$st_cn" \
            "$used/$([[ "$maxu" == "0" ]] && echo ∞ || echo "$maxu")" \
            "$(_share_expiry_str "$rec")" "${kind:-}"
        i=$((i+1))
    done <<< "$rows"
    printf '\n'
    # 「原生」是主记录的附带产物: 说清楚它是什么, 否则用户会以为那是第二条分享
    print_info "「原生」= 主记录的附带产物 (同内核同发行版才拉它); 撤销/停用成对生效"
    _share_legacy_hint
}


# 交互式选一条分享链接。
# 选中的完整路径写入全局 _SHARE_PICKED, **不往 stdout 打任何东西** ——
# 调用方一律用 _SHARE_PICKED 取值, 绝不要写 f=$(share_pick)。
# 成功返回 0, 取消/无效返回 1。

# 交互式选一条分享链接。
# 选中项的 **token** 写入 _SHARE_PICKED, 完整记录 JSON 写入 _SHARE_PICKED_REC;
# 不往 stdout 打任何东西 —— 调用方一律用这两个变量取值, 绝不要写 f=$(share_pick)。
# 成功返回 0, 取消/无效返回 1。
share_pick() {
    _SHARE_PICKED=""; _SHARE_PICKED_REC=""
    # 表格必须走 stderr —— 这个函数会被包在命令替换里, 表格混进 stdout 会把
    # 后面所有取值逻辑污染成"整张表格"(这个坑在旧实现里踩过, 注释保留在案)。
    share_list >&2
    printf '请输入编号 [回车取消]: ' >&2
    local n; read -r n
    [[ -n "$n" && "$n" =~ ^[0-9]+$ ]] || { print_info "已取消"; return 1; }
    local -a toks=()
    local line
    while IFS=$'\t' read -r _ _ tok _ _ _; do
        [[ -n "$tok" ]] && toks+=("$tok")
    done < <(_share_rows)
    (( n >= 1 && n <= ${#toks[@]} )) || { print_error "编号不存在"; return 1; }
    _SHARE_PICKED="${toks[$((n-1))]}"
    _SHARE_PICKED_REC=$(_share_api get --token "$_SHARE_PICKED" 2>/dev/null)
    [[ -n "$_SHARE_PICKED_REC" ]] || { print_error "读取记录失败"; _SHARE_PICKED=""; return 1; }
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

# 吊销**全部** M 分享 —— 清空全部节点时用。
#
# 与 share_revoke_by_tag 的区别: 那个按协议桶匹配, 这个不分范围一律禁用。
# 节点全没了, 任何链接拉回去都是一份空配置, 留着只会让客户端反复去拉。
share_revoke_all() {
    _SHARE_REVOKED_N=0
    local toks
    # ★ 原生记录也在这份清单里(它就是一条普通记录) —— 所以"全部禁用"天然成对。
    toks=$(_share_api_list | python3 -c '
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    if r.get("enabled", True):          # 已经禁用的不重复禁
        print(r.get("token", ""))
' 2>/dev/null)
    local tok
    for tok in $toks; do
        [[ -n "$tok" ]] || continue
        _share_api update --token "$tok" --enabled false >/dev/null 2>&1 \
            && _SHARE_REVOKED_N=$((_SHARE_REVOKED_N + 1))
    done
    return 0
}

share_revoke_by_tag() {
    local tag="${1:-}" mode="${2:-prefix}"
    _SHARE_REVOKED_N=0
    [[ -n "$tag" ]] || return 0

    # 匹配规则与旧实现一致:
    #   prefix (默认) —— tag 相同, 或以 "<tag>_" 开头
    #   exact        —— tag 完全相同
    # 默认必须是 prefix: 产物命名有两套 (单协议 `trojan` / 批量 `trojan_trojan`),
    # 只按 exact 匹配会让批量生成节点的吊销**静默失效** (实测过)。
    local toks
    toks=$(_share_api_list | python3 -c '
import sys, json
tag, mode = sys.argv[1], sys.argv[2]
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    if r.get("type") != "node": continue
    t = str((r.get("meta") or {}).get("tag", ""))
    ok = (t == tag) if mode == "exact" else (t == tag or t.startswith(tag + "_"))
    if ok: print(r.get("token", ""))
' "$tag" "$mode" 2>/dev/null)
    # 原生记录与主记录**同一个 tag**, 所以上面这份清单已经同时覆盖两条 ——
    # 这正是"吊销成对"能成立的原因(只动主记录会留下一条还活着的原生分享)。

    local tok
    for tok in $toks; do
        [[ -n "$tok" ]] || continue
        # 吊销 = 禁用 (不是删除): 链接立刻返回 410, 但记录还在 ——
        # 用户仍能看到"发给谁、什么时候、用过几次"。与旧实现的取舍一致。
        _share_api update --token "$tok" --enabled false >/dev/null 2>&1 \
            && _SHARE_REVOKED_N=$((_SHARE_REVOKED_N + 1))
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
    [[ -n "$tag" ]] || return 0
    share_refresh_all >/dev/null 2>&1   # 先把内容对齐, 免得按过期内容判断
    share_revoke_by_tag "$tag"
    if (( ${_SHARE_REVOKED_N:-0} > 0 )); then
        print_info "已吊销 ${label} 的分享链接 ${_SHARE_REVOKED_N} 条 (立即返回 410)"
        print_warn "分享粒度是协议桶不是单节点 —— 同协议其它节点的链接也一并失效了"
    fi
    local alln=0
    alln=$(_share_api_list | python3 -c '
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
print(sum(1 for r in recs if r.get("type")=="node" and str((r.get("meta") or {}).get("tag",""))=="all"))
' 2>/dev/null)
    (( ${alln:-0} > 0 )) && print_info "另有 ${alln} 条 tag=all 的链接仍可用 (它们还包含其它节点)"
    return 0
}



share_delete() {
    print_title "删除分享链接"
    share_pick || return
    # ★ 一条分享有两条记录(普通话主 + 原生附带): 只删主记录的话, 原生产物
    #   **还活着** —— 带声明的地址依然能拉到同一批节点, 而用户以为已经删了。
    local tok; tok=$(_share_primary_of "$_SHARE_PICKED")
    local -a pair=()
    while IFS= read -r _t; do [[ -n "$_t" ]] && pair+=("$_t"); done < <(_share_pair_of "$tok")
    local t
    for t in "${pair[@]}"; do
        if ! _share_api delete --token "$t" >/dev/null 2>&1; then
            print_error "删除失败 (公共服务拒绝或不可用)"
            return 1
        fi
        # 回读确认, 否则服务端静默失败时仍会报"已删除" (旧实现踩过同款假成功)
        if _share_api get --token "$t" >/dev/null 2>&1; then
            print_error "删除失败, 记录仍在: ${t:0:12}..."
            return 1
        fi
    done
    if (( ${#pair[@]} > 1 )); then
        print_ok "已删除分享链接 (主 ${tok:0:12}... + 原生附带记录, 共 ${#pair[@]} 条)"
    else
        print_ok "已删除分享链接 (token ${tok:0:12}...)"
    fi
}



share_toggle() {
    print_title "启用 / 禁用分享链接"
    share_pick || return
    # ★ 成对: 只禁用主记录的话, 原生产物**还活着** —— 带声明的地址依然能拉到
    #   同一批节点, 而面板上主记录显示"已禁用"。这个错误是静默的。
    local tok; tok=$(_share_primary_of "$_SHARE_PICKED")
    local cur want
    cur=$(printf '%s' "$_SHARE_PICKED_REC" | python3 -c 'import sys,json;print("true" if json.load(sys.stdin).get("enabled",True) else "false")' 2>/dev/null)
    [[ "$cur" == "true" ]] && want="false" || want="true"
    local -a pair=(); local t
    while IFS= read -r _t; do [[ -n "$_t" ]] && pair+=("$_t"); done < <(_share_pair_of "$tok")
    local bad=0
    for t in "${pair[@]}"; do
        local out now
        out=$(_share_api update --token "$t" --enabled "$want" 2>/dev/null)
        now=$(printf '%s' "$out" | python3 -c 'import sys,json;print("true" if json.load(sys.stdin).get("enabled",False) else "false")' 2>/dev/null)
        [[ "$now" == "$want" ]] || bad=1
    done
    if (( bad == 1 )); then
        print_error "切换失败 (公共服务未生效)"
        return 1
    fi
    if [[ "$want" == "true" ]]; then print_ok "已启用"; else print_ok "已禁用"; fi
    (( ${#pair[@]} > 1 )) && print_info "主记录与原生附带记录已一起切换 (共 ${#pair[@]} 条)"
}



share_regen() {
    print_title "重新生成 Token"
    share_pick || return
    local old="$_SHARE_PICKED" rec="$_SHARE_PICKED_REC"
    printf '重新生成后旧链接立即失效 (404)。确认? (y/N): '
    local c; read -r c
    [[ "$c" =~ ^[yY]$ ]] || { print_info "已取消"; return; }

    # 公共服务没有"改 token"这种操作 —— token 就是主键。
    # 语义上用「建新的 + 删旧的」等价实现: 旧链接立刻 404, 新链接可用。
    # 内容/范围/次数上限/有效期全部照搬, 使用次数也一并带过去 (与旧实现的
    # "改名保留计数" 行为一致)。
    local f; f=$(mktemp)
    printf '%s' "$rec" | python3 -c '
import sys, json
r = json.load(sys.stdin)
sys.stdout.write(r.get("content", ""))
' > "$f"
    local ttl=0 exp now
    exp=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("expires_at",0)))' 2>/dev/null)
    now=$(date +%s)
    (( exp > now )) && ttl=$((exp - now))
    local meta maxu used
    meta=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin).get("meta") or {},ensure_ascii=False))' 2>/dev/null)
    maxu=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("max_uses",0)))' 2>/dev/null)
    used=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("used_count",0)))' 2>/dev/null)

    local new
    new=$(_share_api create --type "$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("type","node"))' 2>/dev/null)" \
            --content-file "$f" --ttl "$ttl" --max-uses "$maxu" --meta "$meta" 2>/dev/null \
          | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    rm -f "$f"
    [[ -n "$new" ]] || { print_error "创建新 token 失败"; return 1; }
    # 把使用次数带过去 —— 与旧实现 (mv 保留计数) 行为一致
    (( used > 0 )) && _share_api update --token "$new" --used-count "$used" >/dev/null 2>&1

    # ★ 一条分享两条记录: 主记录换了 token, 原生产物必须一起重建 ——
    #   否则新地址上的声明会指向**旧的原生 token**(那个还活着, 但已经和这条
    #   新分享脱钩), 而旧的原生记录也没有被回收。
    local ntok oldnat newnat decl
    oldnat=$(_share_native_of "$old")
    if [[ -n "$oldnat" ]]; then
        local nrec
        nrec=$(_share_api get --token "$oldnat" 2>/dev/null)
        local nfile; nfile=$(mktemp)
        printf '%s' "$nrec" | python3 -c '
import sys, json
try: sys.stdout.write((json.load(sys.stdin) or {}).get("content", ""))
except Exception: pass' > "$nfile"
        newnat=$(_share_api create --type node --content-type "text/yaml; charset=utf-8" \
                    --content-file "$nfile" --ttl "$ttl" --max-uses "$maxu" \
                    --meta "$(printf '%s' "$nrec" | python3 -c '
import sys, json
try:
    m = (json.load(sys.stdin) or {}).get("meta") or {}
except Exception:
    m = {}
m.pop("parent", None)
print(json.dumps(m, ensure_ascii=False))' | python3 -c '
import sys, json
m = json.load(sys.stdin)
m["parent"] = sys.argv[1]
print(json.dumps(m, ensure_ascii=False))' "$new")" 2>/dev/null \
                  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
        rm -f "$nfile"
        _share_api delete --token "$oldnat" >/dev/null 2>&1
        if [[ -z "$newnat" ]]; then
            print_warn "原生产物没能重建 —— 新地址上的声明会退回只有普通话"
        fi
    fi

    _share_api delete --token "$old" >/dev/null 2>&1 || {
        print_warn "旧 token 删除失败, 新旧两条同时存在"; }

    local got
    got=$(_share_api get --token "$new" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    [[ "$got" == "$new" ]] || { print_error "新 token 未生效"; return 1; }

    # 主记录的 meta 里要写上新的原生 token 与声明口径
    local dist ver
    dist=$(python3 -c 'import sys,json
try: print((json.loads(sys.argv[1]) or {}).get("distribution",""))
except Exception: print("")' "$meta" 2>/dev/null)
    ver=$(python3 -c 'import sys,json
try: print((json.loads(sys.argv[1]) or {}).get("kernel_version",""))
except Exception: print("")' "$meta" 2>/dev/null)
    local addr
    addr=$(cat "$SRV_OUT/share_addr.txt" 2>/dev/null)
    [[ -n "$addr" ]] || addr=$(_share_addr)
    local nurl=""
    [[ -n "$newnat" ]] && nurl="http://$(_share_host "$addr"):$(_share_port)/share/$newnat"
    local newmeta
    newmeta=$(TAG="$(printf '%s' "$meta" | python3 -c 'import sys,json
try: print((json.loads(sys.stdin.read()) or {}).get("tag","all"))
except Exception: print("all")')" DIST="$dist" VER="$ver" NTOK="$newnat" python3 -c '
import json, os
fmts = ["uri"] + ([os.environ["DIST"]] if os.environ["NTOK"] else [])
print(json.dumps({"tag": os.environ["TAG"], "interop": 1, "role": "primary",
                  "kernel": "mihomo", "distribution": os.environ["DIST"],
                  "kernel_version": os.environ["VER"], "formats": fmts,
                  "native_token": os.environ["NTOK"]}, ensure_ascii=False))')
    _share_api update --token "$new" --meta "$newmeta" >/dev/null 2>&1
    decl=$(_share_declare_url "http://$(_share_host "$addr"):$(_share_port)/share/$new" \
             "$dist" "$nurl")
    [[ -n "$decl" ]] && printf '%s\n' "$decl" > "$SRV_OUT/share_tag-$(printf '%s' "$meta" | python3 -c 'import sys,json
try: print((json.loads(sys.stdin.read()) or {}).get("tag","all"))
except Exception: print("all")').txt" 2>/dev/null

    print_ok "已重新生成"
    printf '  旧: %s\n  新: %s\n' "$old" "$new"
    [[ -n "$newnat" ]] && printf '  原生附带记录也已重建 (%s)\n' "${newnat:0:12}..."
}



share_show_url() {
    print_title "查看分享链接"
    share_pick || return
    # 选中的可能是附带记录 (原生) —— 展示的永远是主记录 + 它的声明
    local tok; tok=$(_share_primary_of "$_SHARE_PICKED")
    local addr
    addr=$(_share_addr)
    printf '\n  自动探测地址: %s\n' "$addr"
    printf '若不对请输入正确地址, 回车使用上面: '
    local a2; read -r a2
    [[ -n "$a2" ]] && addr="$a2"
    # ★ 现算带**内核声明**的地址(不落盘读): 客户端靠声明决定拉原生还是普通话。
    #   复制裸地址的话客户端只能走普通话, 而且没有任何报错指向这一点。
    local dist ver ntok nurl decl
    dist=$(_share_meta_field "$tok" meta.distribution)
    ver=$(_share_meta_field "$tok" meta.kernel_version)
    ntok=$(_share_native_of "$tok")
    [[ -n "$ntok" ]] && nurl="http://$(_share_host "$addr"):$(_share_port)/share/$ntok"
    decl=$(_share_declare_url "http://$(_share_host "$addr"):$(_share_port)/share/$tok" \
             "$dist" "$nurl")
    [[ -n "$decl" ]] || decl="http://$(_share_host "$addr"):$(_share_port)/share/$tok"
    printf '\n  %s\n\n' "$decl"
    if [[ -n "$ntok" ]]; then
        printf '  格式: 普通话(URI 列表) + 原生(%s 的 YAML)\n' "${dist:-?}"
    else
        local f0 ver0
        f0=$(_share_self_facts); ver0=$(_share_fact "$f0" version)
        printf '  格式: 仅普通话(URI 列表); 地址上仍带内核声明\n'
        [[ -z "$dist" ]] && printf '        (内核发行版探测不到, 所以没有原生: %s)\n' "$(_share_fact "$f0" note)"
    fi
    printf '  客户端: 把这整行填进「添加节点 → 分享链接」即可\n\n'
}


# ---------- 服务 ----------
# ---------------------------------------------------------------- 内容生成
#
# 内容由 **M** 生成 —— 公共服务只负责保存和返回, 它不认识 Mihomo 的格式。

# 一条分享的**两条记录** + 带声明的地址。
#
# 打印(一行, TAB 分隔): <主token>\t<原生token或空>\t<带声明的地址>; 失败返回 1。
#
#   主记录   = 普通话 (URI 列表)  —— content_type text/plain
#   附带记录 = 原生   (mihomo YAML) —— content_type text/yaml
#
# 为什么**普通话是主记录**(而不是把 YAML 继续当主):
#   声明里 `uri` 的地址就是主 URL 本身(设计 §2: 不重复写), 而跨内核客户端
#   (xbd) 走普通话时拉的就是主 URL —— 主 URL 必须是普通话, 否则"跨内核 → 拉
#   URI"这条链在服务端就断了。原生则挂在自己的地址上 (url-<发行版>)。
#
# 两条记录的 TTL 与次数上限**同源**: 一条永久一条 24 小时会让用户以为原生
# "自己坏了"。
_share_create_records() { # <tag> <max_uses> <ttl_s> <addr>
    local tag="$1" mu="$2" ttl_s="$3" addr="$4"
    local uri_file nat_file
    uri_file=$(mktemp) || return 1
    if ! _share_make_uri_content "$tag" "$uri_file"; then
        rm -f "$uri_file" "$uri_file.loss"
        return 1
    fi
    # 普通话这一份的损失报告要给人看见(不静默降级)
    if [[ -s "$uri_file.loss" ]]; then
        sed 's/^/       /' "$uri_file.loss" >&2
    fi

    local facts dist ver
    facts=$(_share_self_facts)
    dist=$(_share_fact "$facts" distribution)
    ver=$(_share_fact "$facts" version)

    local pri_meta pri_tok nat_tok="" nat_meta rec
    pri_meta=$(TAG="$tag" DIST="$dist" VER="$ver" python3 -c '
import json, os
print(json.dumps({"tag": os.environ["TAG"], "interop": 1, "role": "primary",
                  "kernel": "mihomo", "distribution": os.environ["DIST"],
                  "kernel_version": os.environ["VER"]}, ensure_ascii=False))')
    rec=$(_share_api create --type node --content-type "text/plain; charset=utf-8" \
              --content-file "$uri_file" --ttl "$ttl_s" --max-uses "$mu" \
              --meta "$pri_meta" 2>/dev/null)
    rm -f "$uri_file" "$uri_file.loss"
    pri_tok=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    [[ -n "$pri_tok" ]] || return 1

    # ---- 原生产品 (只有 mihomo 内核读) ----
    if [[ -z "$dist" ]]; then
        print_warn "内核发行版探测不到 ($(_share_fact "$facts" note)) —— 不产出原生, 只发普通话" >&2
    else
        nat_file=$(mktemp) || nat_file=""
        if [[ -n "$nat_file" ]] && _share_make_content "$tag" "$nat_file"; then
            nat_meta=$(TAG="$tag" DIST="$dist" VER="$ver" PRI="$pri_tok" python3 -c '
import json, os
print(json.dumps({"tag": os.environ["TAG"], "interop": 1, "role": "native",
                  "kernel": "mihomo", "distribution": os.environ["DIST"],
                  "kernel_version": os.environ["VER"],
                  "parent": os.environ["PRI"]}, ensure_ascii=False))')
            rec=$(_share_api create --type node --content-type "text/yaml; charset=utf-8" \
                      --content-file "$nat_file" --ttl "$ttl_s" --max-uses "$mu" \
                      --meta "$nat_meta" 2>/dev/null)
            nat_tok=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
        fi
        [[ -n "$nat_file" ]] && rm -f "$nat_file"
        if [[ -z "$nat_tok" ]]; then
            # 原生产物没发出去也要**说清楚**: 地址上仍会声明"只有普通话",
            # 客户端据此走通用格式, 而不是先试原生再失败一次。
            print_warn "原生产品没生成/没建起来 —— 这条分享只发普通话(URI)" >&2
        fi
    fi

    # ---- 地址上的声明 ----
    local url nat_url declared
    url="http://$(_share_host "$addr"):$(_share_port)/share/$pri_tok"
    if [[ -n "$nat_tok" ]]; then
        nat_url="http://$(_share_host "$addr"):$(_share_port)/share/$nat_tok"
        declared=$(_share_declare_url "$url" "$dist" "$nat_url")
    else
        declared=$(_share_declare_url "$url" "")
    fi
    [[ -n "$declared" ]] || declared="$url"

    # 把"原生在哪 / 声明口径"记进主记录 meta —— 列表、刷新、吊销都靠它。
    # meta 是**整体替换**, 所以上面写过的字段必须一起带上。
    pri_meta=$(TAG="$tag" DIST="$dist" VER="$ver" NTOK="$nat_tok" python3 -c '
import json, os
fmts = ["uri"] + ([os.environ["DIST"]] if os.environ["NTOK"] else [])
print(json.dumps({"tag": os.environ["TAG"], "interop": 1, "role": "primary",
                  "kernel": "mihomo", "distribution": os.environ["DIST"],
                  "kernel_version": os.environ["VER"], "formats": fmts,
                  "native_token": os.environ["NTOK"]}, ensure_ascii=False))')
    _share_api update --token "$pri_tok" --meta "$pri_meta" >/dev/null 2>&1 \
        || print_warn "声明没写进 meta (分享本身可用, 但列表里看不到原生地址)" >&2

    printf '%s\t%s\t%s\n' "$pri_tok" "$nat_tok" "$declared"
    return 0
}

_share_make_content() { # <tag> <输出文件>
    local tag="$1" out="$2"
    if [[ -n "${SHARE_PROVIDERS_DIR:-}" && -d "${SHARE_PROVIDERS_DIR:-}" ]]; then
        python3 "$BUILD_SUB" --out-dir "$SRV_OUT" \
            --providers-dir "$SHARE_PROVIDERS_DIR" --tag "$tag" >"$out" 2>/dev/null
    else
        python3 "$BUILD_SUB" --out-dir "$SRV_OUT" \
            --conf-dir "$SRV_CONF" --tag "$tag" >"$out" 2>/dev/null
    fi
    grep -q "proxies:" "$out" 2>/dev/null
}

# ---------------------------------------------------------------- 内容保鲜
#
# ★ 分享链接的"活"语义靠这里维持: 节点变了就把内容刷新一遍。
#   token / URL / TTL / 使用次数**全部不变**, 只换内容 —— 客户端下次拉取
#   就能拿到最新节点。旧实现是"访问时实时生成", 现在改成"创建时写入 +
#   主动刷新", 这是公共化带来的唯一行为差异, 由本函数把它补回来。
#
#   **内容没变就不写** (比对 content_sha256), 避免无谓写盘。
share_refresh_all() {
    local recs; recs=$(_share_api_list 2>/dev/null)
    [[ -z "$recs" || "$recs" == "[]" ]] && return 0
    local n=0 tok tag want wanttype role cur_hash new_hash tmp
    while IFS=$'\t' read -r tok tag wanttype role; do
        [[ -n "$tok" ]] || continue
        [[ "$wanttype" == "node" ]] || continue      # 只刷新节点类; 配置类由调用方决定
        tmp=$(mktemp)
        # ★ 按**角色**分派产品: 普通话记录刷 URI 列表, 原生记录刷 YAML。
        #   不分派的话, 原生记录会被改写成一份 URI 列表 —— 而地址上仍然声明
        #   "原生在那边", 客户端拉过去解析出 0 个节点(或格式不符), 全程无报错。
        #   role 缺失 = 2026-10-10 之前的旧记录, 内容一直是 YAML → 按 YAML 刷。
        case "$role" in
            primary) _share_make_uri_content "$tag" "$tmp" || { rm -f "$tmp"; continue; } ;;
            native)  _share_make_content "$tag" "$tmp"     || { rm -f "$tmp"; continue; } ;;
            *)       _share_make_content "$tag" "$tmp"     || { rm -f "$tmp"; continue; } ;;
        esac
        new_hash=$(sha256sum "$tmp" | awk '{print $1}')
        cur_hash=$(_share_api get --token "$tok" 2>/dev/null \
                   | python3 -c 'import sys,json;print(json.load(sys.stdin).get("content_sha256",""))' 2>/dev/null)
        if [[ "$new_hash" != "$cur_hash" ]]; then
            _share_api update --token "$tok" --content-file "$tmp" >/dev/null 2>&1 && n=$((n+1))
        fi
        rm -f "$tmp"
    done < <(_share_api_list | python3 -c '
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    print("%s\t%s\t%s\t%s" % (r.get("token",""), (r.get("meta") or {}).get("tag","all"),
                              r.get("type",""), (r.get("meta") or {}).get("role","")))
' 2>/dev/null)
    (( n > 0 )) && print_info "已刷新 ${n} 条分享链接的内容 (token 与地址未变)"
    return 0
}

# ---------------------------------------------------------------- 旧数据
_share_legacy_files() {
    shopt -s nullglob
    local f=("${SHARES:-/nonexistent}"/*.json)
    shopt -u nullglob
    printf '%s\n' "${f[@]:-}" | grep -v '^$' || true
}

_share_legacy_hint() {
    local n; n=$(_share_legacy_files | wc -l)
    (( n > 0 )) && print_warn "另有 ${n} 条旧格式记录未迁移 (面板下次进入时会自动导入)"
    return 0
}

# 把旧格式记录 (share/shares/*.json, 只有 tag 没有 content) 导入公共服务。
# ★ **沿用原 token** —— 否则已经发出去的链接会全部失效。
#   导入后旧文件改名 .migrated (不删, 留回滚余地), 再次运行不会重复导入。
share_legacy_migrate() {
    local files; files=$(_share_legacy_files)
    [[ -n "$files" ]] || return 0
    local f n=0 fail=0
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        local tok tag exp maxu used enabled
        tok=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("share_token",""))' "$f" 2>/dev/null)
        tag=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("tag","all"))' "$f" 2>/dev/null)
        exp=$(python3 -c 'import sys,json;print(int(json.load(open(sys.argv[1])).get("expires_at",0)))' "$f" 2>/dev/null)
        maxu=$(python3 -c 'import sys,json;print(int(json.load(open(sys.argv[1])).get("max_uses",0)))' "$f" 2>/dev/null)
        used=$(python3 -c 'import sys,json;print(int(json.load(open(sys.argv[1])).get("used_count",0)))' "$f" 2>/dev/null)
        enabled=$(python3 -c 'import sys,json;print("true" if json.load(open(sys.argv[1])).get("enabled",True) else "false")' "$f" 2>/dev/null)
        [[ "$tok" =~ ^[0-9a-f]{32}$ ]] || { fail=$((fail+1)); continue; }

        # ★ 用**绝对到期时间**而不是 ttl。
        #   已过期的旧记录 exp < now, 按 ttl 算会得到 0, 而 0 = 永久 ——
        #   等于把过期分享复活成永久链接 (实测踩到: 一条"已过期"的记录迁移后
        #   返回 200)。expires_at 原样搬过去才是等价迁移。
        local tmp
        tmp=$(mktemp)
        _share_make_content "$tag" "$tmp" || { rm -f "$tmp"; fail=$((fail+1)); continue; }
        if _share_api create --type node --token "$tok" --content-file "$tmp" \
              --expires-at "$exp" --max-uses "$maxu" --meta "{\"tag\":\"$tag\"}" >/dev/null 2>&1; then
            (( used > 0 )) && _share_api update --token "$tok" --used-count "$used" >/dev/null 2>&1
            [[ "$enabled" == "false" ]] && _share_api update --token "$tok" --enabled false >/dev/null 2>&1
            mv -f "$f" "$f.migrated" 2>/dev/null
            n=$((n+1))
        else
            fail=$((fail+1))
        fi
        rm -f "$tmp"
    done <<< "$files"
    (( n > 0 )) && print_ok "已导入 ${n} 条旧分享记录 (原 token 保留, 已发出的链接继续可用)"
    (( fail > 0 )) && print_warn "有 ${fail} 条导入失败 (已保留原文件)"
    return 0
}


share_service_status() {
    local st p
    p=$(_share_port)
    if [[ -f "$SHARE_CLIENT" ]] && python3 "$SHARE_CLIENT" health >/dev/null 2>&1; then
        printf '  %s运行中%s  端口 %s  %s(公共基础服务, M/SB/X 共用)%s\n' \
            "$GREEN" "$RESET" "$p" "$DIM" "$RESET"
    else
        printf '  %s未运行%s  (分享链接暂时无法访问)\n' "$YELLOW" "$RESET"
        printf '  %s这是公共基础服务, 不是 M 的子服务 —— 选 7 可安装/检查%s\n' "$DIM" "$RESET"
    fi
}



share_service_install() {
    print_title "安装 / 检查公共分享服务"
    if [[ ! -f "$SHARE_CLIENT" ]]; then
        print_error "缺少适配层: $SHARE_CLIENT"; return 1
    fi
    local p
    if p=$(python3 "$SHARE_CLIENT" ensure 2>/dev/null) && [[ -n "$p" ]]; then
        print_ok "公共分享服务已就位 (端口 $p)"
        print_info "M / SB / X 共用它 —— 后装的内核会直接复用它, 不会重复安装"
        python3 "$SHARE_CLIENT" health 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print("  版本: %s   API 版本: %s" % (d.get("version"), d.get("api_version")))
provs = d.get("providers") or {}
if provs:
    print("  各内核分享: " + ", ".join("%s=%d" % (k, v.get("total", 0)) for k, v in provs.items()))
' 2>/dev/null
        return 0
    fi
    print_error "公共分享服务不可用 —— 安装失败或起不来"
    print_info "手动排查: bash /root/deepseek/Share-Service/install.sh --check"
    return 1
}



share_service_restart() {
    systemctl restart proxy-share-service && print_ok "已重启" || print_error "重启失败"
}



share_service_stop() {
    # ★ 这是**公共**服务: 停掉它会影响 SB/X 的分享链接。
    print_warn "proxy-share-service 是 M/SB/X 共用的公共基础服务"
    printf '  停止后所有内核的分享链接都会失效。确认? (y/N): '
    local c; read -r c
    [[ "$c" =~ ^[yY]$ ]] || { print_info "已取消"; return 0; }
    systemctl stop proxy-share-service && print_ok "已停止" || print_warn "停止失败"
}


# ---------- 菜单 ----------
share_menu() {
    # 进面板时顺手做三件**幂等**的事 (都不改变菜单与文案):
    #   1. 确保公共分享服务在位 (不存在则从独立项目装)
    #   2. 把旧格式的分享记录导入公共服务 (沿用原 token, 保住已发出的链接)
    #   3. 刷新 node 类分享的内容 —— 这是"活链接"语义的维持点
    share_service_ensure >/dev/null 2>&1
    share_legacy_migrate
    share_refresh_all
    # 旧的 mihomo-share.service 已被公共服务取代, 顺手清掉
    local _legacy=/etc/systemd/system/mihomo-share.service
    if [[ -f "$_legacy" ]] && [[ -f "$SHARE_CLIENT" ]] && python3 "$SHARE_CLIENT" health >/dev/null 2>&1; then
        systemctl stop mihomo-share >/dev/null 2>&1
        systemctl disable mihomo-share >/dev/null 2>&1
        rm -f "$_legacy"
        systemctl daemon-reload >/dev/null 2>&1
        print_info "已停用旧的 mihomo-share.service (由公共分享服务取代)"
    fi
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

    local addr; addr=$(_share_addr)

    # 确保公共服务在位 (不存在则从独立项目装), 否则刚生成的链接当场就是拉不动的
    local p
    p=$(python3 "$SHARE_CLIENT" ensure 2>/dev/null)
    if [[ -z "$p" ]]; then
        printf '\n  %s公共分享服务不可用, 本次没能生成分享链接%s\n' "$YELLOW" "$RESET"
        printf '  %s面板「分享链接管理 → 7」可查看原因%s\n' "$DIM" "$RESET"
        printf '0'; return 1
    fi

    # ★ 与面板「生成分享链接」走**同一条**创建路径 (两条记录 + 声明)。
    #   分开写的话, 这一条会只发普通话, 而用户看到的地址上仍然带着声明 ——
    #   同内核客户端反而拿不到原生(且没有任何报错)。
    local ttl_s recrec token ntok declared
    ttl_s=$((HOURS * 3600))
    if ! recrec=$(_share_create_records "$TAG" "$MU" "$ttl_s" "$addr"); then
        printf '0'; return 1
    fi
    token=$(printf '%s' "$recrec" | awk -F'\t' '{print $1}')
    ntok=$(printf '%s' "$recrec" | awk -F'\t' '{print $2}')
    declared=$(printf '%s' "$recrec" | awk -F'\t' '{print $3}')
    [[ -n "$token" ]] || { printf '0'; return 1; }

    printf '%s' "$addr" > "$SRV_OUT/share_addr.txt"
    printf '%s\n' "$declared" > "$SRV_OUT/share_tag-$TAG.txt"

    local link; link="$declared"
    printf '\n  %s一次性分享链接%s  %s用 %s 次 · %s 小时后过期%s\n' \
        "$GREEN" "$RESET" "$DIM" "$MU" "$([[ "$HOURS" -gt 0 ]] && echo "$HOURS" || echo "永久")" "$RESET"
    [[ -n "$ntok" ]] && printf '  %s(带内核声明: 同内核同发行版拉原生, 其余走普通话)%s\n' "$DIM" "$RESET"
    printf '  %s%s%s\n' "$BOLD" "$link" "$RESET"
    printf '  %s地址探测自本机; 若客户端拉不到, 面板「生成分享链接」里可改地址重发%s\n' "$DIM" "$RESET"
    return 0
}

