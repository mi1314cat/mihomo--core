#!/usr/bin/env bash
# =============================================================
# server_extra.sh — 服务端「出站 / 规则集 / 端口转发」
#
# 为什么放在一个文件里而不是三个:
#   三者的生命周期完全一致 —— 都由服务端面板菜单挂载, 都落在 conf/config.d/
#   下的独立片段里, 都走「合并 → 严格校验 → mihomo -t → 重载」同一条通道。
#   拆三个文件只是让 manifest 多三行, 不会让任何一处更清楚。
#
# 三者与已有功能的关系 (避免重复造轮子):
#   * 出站   —— 服务端自己的出站。客户端的 simple_proxy.sh 只做「接其它内核的
#              HTTP/SOCKS」, 那是**客户端**的事; 这里做的是服务端转发用的出站。
#   * 规则集 —— 服务端用 rule-provider 做分流。与客户端 rules_bind.sh 的
#              「域名 → 节点/组」不是一回事: 那改的是客户端 config.yaml,
#              这里改的是服务端 config.d/。
#   * 端口转发 —— direct listener, 把本机一个端口的数据直接送到目标地址。
#              mihomo 原生支持 (type: tunnel), 已用内核 -t 逐字段实测验证。
#
# 存储布局 (都放 config.d/, 由 merge.py 自动合并进主配置):
#   conf/config.d/outbound-NN.yaml   outbounds 段
#   conf/config.d/ruleset-NN.yaml    rule-providers + 自己的 rules 段
#   conf/config.d/pfwd-NN.yaml       端口转发 listener
#
# 片段顶部都写自己的 tag 注释, 删节点时按 tag 精确摘除, 不误伤别人。
# =============================================================

# =============================================================
# 一、通用: 片段读写
# =============================================================

# ⚠ 之前这里直接 `printf '%s' "$CONF_DIR"`, 而 **CONF_DIR 全项目只有
#   conf/all.sh 和各协议脚本会赋值** —— server.sh 从没设过它。
#   于是从服务端菜单调用时它为空串, 文件被写到**文件系统根目录**
#   (/outbound-01.yaml、/pfwd-01.yaml …), 节点自然一个都没多。
#   表现极具迷惑性: 面板一路显示"已生效"(因为 _extra_apply 只看校验和重载,
#   它根本没检查文件落地没有), 直到查 config.d 才发现空空如也。
#
# 改成**自己算**, 不依赖任何环境变量:
#   SRV_CONF (server.sh 一定有) 的目录 + /config.d
#   退路: CONF_DIR 若已被调用方设好就用它
# 不同调用方给的 SRV_CONF 含义并不统一 (server.sh 给的是**目录**
# $SRV_ROOT/conf, 而 share.sh 的 systemd 单元里给的是同一个变量的路径),
# 所以这里**逐个试, 用存在性判断**, 而不是靠约定:
#   1. $SRV_CONF 本身就是个 config.d      (调用方已经算好了)
#   2. $SRV_CONF/config.d 存在            (SRV_CONF 是 conf 目录)
#   3. $(dirname $SRV_CONF)/config.d 存在  (SRV_CONF 是 conf/config.yaml)
# 都不中才退回默认路径。
#
# ⚠ 曾试过纯字符串推导, 结果两种约定各错一半: 对着"SRV_CONF 是文件"算对了,
#   碰上真实的"SRV_CONF 是目录"就拼出 /conf/config.d 之外的东西。存在性
#   判断没有这种歧义。
_extra_dir() {
    local c
    # ★ SRV_CONFIGD 排第一: 它是 env.sh / server.sh 已经算好的**规范路径**
    #   ($SRV_CONF/config.d, SRV_CONF 本身就是 conf 目录)。
    #
    #   之前把 $SRV_CONF 本身也列为候选, 结果它**里面就有 config.yaml**,
    #   glob "$c/*.yaml" 命中 → 片段被写成 conf/socks-01.yaml, 少了一层
    #   config.d, 而合并器只读 conf/config.d/*。于是: 目录存在、校验通过、
    #   重载成功, 三步全绿, 而新节点一个都没多 —— 又一个假阳性。
    for c in "${SRV_CONFIGD:-}"              "${CONF_DIR:-}"              "${SRV_CONF:-}"              "${SRV_CONF:-}/config.d"              "${SRV_CONF:+$(dirname "$SRV_CONF")/config.d}"              "/root/catmi/mihomo/conf/config.d"; do
        [[ -n "$c" && -d "$c" ]] || continue
        # 必须真的是"片段目录": 里面若已有 yaml, 或名字以 config.d 结尾, 更可信
        if compgen -G "$c/*.yaml" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
        [[ "${c%/}" == */config.d ]] && { printf '%s' "$c"; return 0; }
    done
    printf '%s' "/root/catmi/mihomo/conf/config.d"
}

_extra_next_index() { # <前缀> -> 第一个空位 NN
    local pre="$1" i
    for (( i = 1; i < 100; i++ )); do
        [[ -f "$(_extra_dir)/$pre-$(printf '%02d' "$i").yaml" ]] || { printf '%02d' "$i"; return; }
    done
    printf '01'
}

_extra_count() { # <前缀> -> 数量
    local pre="$1" i n=0 f
    for (( i = 1; i < 100; i++ )); do
        printf -v f '%s/%s-%02d.yaml' "$(_extra_dir)" "$pre" "$i"
        [[ -f "$f" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
}

_extra_list() { # <前缀> -> 逐条打印 "NN<TAB>摘要"
    local pre="$1" f i idx
    for (( i = 1; i < 100; i++ )); do
        printf -v f '%s/%s-%02d.yaml' "$(_extra_dir)" "$pre" "$i"
        [[ -f "$f" ]] || continue
        idx=$(printf '%02d' "$i")
        printf '%s\t%s\n' "$idx" "$(_extra_summary "$f")"
    done
}

# 从片段里抽一行人话摘要 (不是给机器解析的, 只为菜单显示)
_extra_summary() {
    local f="$1"
    python3 - "$f" <<'PY' 2>/dev/null || printf '(无法解析)'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("(无法解析)"); raise SystemExit
if not isinstance(d, dict):
    print("(无法解析)"); raise SystemExit
# 端口转发
for l in (d.get("listeners") or []):
    if isinstance(l, dict) and l.get("type") == "tunnel":
        net = l.get("network") or []
        if isinstance(net, list):
            net = "/".join(str(x) for x in net)
        print(f"{l.get('listen','0.0.0.0')}:{l.get('port')} ({net}) -> {l.get('target','?')}")
        raise SystemExit
# 出站
ob = d.get("outbounds") or []
if ob:
    print(", ".join(f"{o.get('name')} ({o.get('type')})" for o in ob
                    if isinstance(o, dict)))
    raise SystemExit
# 规则集
rp = d.get("rule-providers") or {}
if rp:
    print(", ".join(f"{k}({v.get('behavior','?')})" for k, v in rp.items()
                    if isinstance(v, dict)))
    raise SystemExit
print("(空)")
PY
}

_extra_del() { # <前缀> <NN>
    local pre="$1" idx="$2" f
    f=$(printf '%s/%s-%s.yaml' "$(_extra_dir)" "$pre" "$idx")
    [[ -f "$f" ]] || { print_error "没有 $pre-$idx"; return 1; }
    rm -f "$f" && print_ok "已删除 $pre-$idx"
}

# 三个功能共用的收尾: 合并 -> 校验 -> 重载
_extra_apply() {
    # ★ 先确认片段真的落到 config.d 了, 再去重载。
    #   之前这里直接 m_sync_reload —— 而重载的是**已经存在的** config.yaml,
    #   片段没落地时它照样成功, 于是面板一路显示"已生效", 而 config.d 里
    #   一个新文件都没有。这类"校验通过但功能没生效"的假阳性最难查:
    #   每一步都绿, 结果什么都没发生。
    local d; d=$(_extra_dir)
    if [[ ! -d "$d" ]]; then
        print_error "片段目录不存在: $d"
        return 1
    fi
    printf '\n  应用配置...\n'
    if m_sync_reload; then
        print_ok "已生效"
    else
        print_error "校验未通过, 已回滚"
        return 1
    fi
}

# =============================================================
# 二、出站管理
# =============================================================
#
# mihomo 的 outbounds 是服务端**主动连出去**时用的。场景:
#   * 节点监听器后面要指定走哪条链路 (走本地另有一个内核/落地机)
#   * 想把某些目标定向到 reject / direct 而不是默认规则
#
# 内核实测: outbounds 段写 type: direct / reject / socks5 / http 均通过 -t。
# 从 URL 导入出站 —— 和客户端「添加节点」保持同一套做法。
#
# 用户明确要求服务端出站能像客户端一样直接喂自己的订阅 URL。
# 与客户端 node_add 的区别只有落地位置: 客户端写 conf/providers/<名字>.yaml
# (proxy-provider, 由内核按需拉), 服务端这里写 config.d/outbound-<NN>.yaml
# (直接把节点展开成 outbounds)。因为服务端出站是被**规则**引用的实体,
# 不是给客户端挑的候选, 展开成静态 outbounds 更直白, 也少一层间接。
_extra_outbound_from_url() {
    print_title "从 URL 导入出站"
    printf '  订阅链接 (本机分享链接 / 通用订阅 / base64 订阅): ' >&2
    local url; read -r url || return 1
    url=$(clean_input "$url")
    [[ -n "$url" ]] || { print_error "链接不能为空"; return 1; }
    [[ "$url" == http://* || "$url" == https://* ]] \
        || { print_error "只支持 http/https 链接"; return 1; }

    printf '  导入后叫什么 (规则里用它引用): ' >&2
    local name; read -r name || return 1
    name=$(clean_input "$name")
    [[ -n "$name" ]] || { print_error "名称不能为空"; return 1; }
    if printf '%s' "$name" | grep -q '[/\\:*?"<>|[:space:]]'; then
        print_error "名称里不能含 / \\ : * ? \" < > | 或空格"; return 1
    fi

    local tmp; tmp=$(mktemp -d) || { print_error "临时目录创建失败"; return 1; }
    local body="$tmp/sub.yaml"; : > "$body"
    print_info "正在拉取..."
    # 不用 dl_curl_code: 它住在 dl_route.sh, 而 dl_route.sh 只在**客户端**
    # 被 source, 服务端这条路径上调用会直接 "command not found"。
    # 服务端本来也不需要下载通道那套代理决策, 直接 curl 就够。
    local code
    code=$(curl -sS -L -m 30 -o "$body" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
    if [[ "$code" != "200" ]]; then
        print_error "拉取失败 (HTTP ${code:-000})"
        rm -rf "$tmp"; return 1
    fi

    # 通用订阅常见的三种外层: 明文 YAML / base64 的一串分享链接 /
    # {"proxies":[...]}。三种都还原成 Mihomo 的 proxies 结构。
    python3 - "$body" "$tmp/norm.yaml" "$_m_libdir" <<'PYURL' 2>&1 | tail -3
import sys, yaml, base64, re
src, dst, lib = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, lib)
raw = open(src, encoding="utf-8", errors="replace").read().strip()
d = None
try:
    d = yaml.safe_load(raw)
except Exception:
    d = None
# 情况 2: 顶层不是 proxies, 但像 base64
if not (isinstance(d, dict) and isinstance(d.get("proxies"), list)):
    b = re.sub(r"\s+", "", raw)
    if len(b) > 20 and re.fullmatch(r"[A-Za-z0-9+/=_-]+", b):
        try:
            dec = base64.urlsafe_b64decode(b + "=" * (-len(b) % 4)).decode("utf-8", "replace")
            d2 = yaml.safe_load(dec)
            if isinstance(d2, dict) and isinstance(d2.get("proxies"), list):
                d = d2
        except Exception:
            pass
if not (isinstance(d, dict) and isinstance(d.get("proxies"), list) and d["proxies"]):
    print("[ERR] 链接里没找到 Mihomo 订阅 (需要顶层 proxies: 列表, 或 base64 编码的订阅)")
    sys.exit(1)
# 剔除内核不认识的类型 —— 否则节点会被**静默丢弃**, 表现是"订阅里有但连不上"
import validate as V
known = getattr(V, "PROXY_TYPES", None) or set()
out = [p for p in d["proxies"]
       if isinstance(p, dict) and (not known or p.get("type") in known)]
if not out:
    print("[ERR] 订阅里的节点全都不是 mihomo 支持的类型: %s"
          % sorted({str(p.get('type')) for p in d['proxies'] if isinstance(p, dict)}))
    sys.exit(1)
yaml.safe_dump({"proxies": out}, open(dst, "w", encoding="utf-8"), allow_unicode=True)
print("[OK] 可用节点 %d / 共 %d" % (len(out), len(d["proxies"])))
PYURL
    local rc=$?
    if [[ $rc -ne 0 || ! -s "$tmp/norm.yaml" ]]; then
        rm -rf "$tmp"; return 1
    fi

    local idx; idx=$(_extra_next_index outbound)
    local f; f=$(printf '%s/outbound-%s.yaml' "$(_extra_dir)" "$idx")
    # 名字冲突直接挡: 规则按名字引用, 覆盖等于悄悄改坏规则
    if python3 - "$(_extra_dir)" "$name" <<'PYDUP' 2>/dev/null
import sys, glob, yaml
for f in glob.glob(sys.argv[1] + "/outbound-*.yaml"):
    try: d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception: continue
    for o in (d.get("outbounds") or []) if isinstance(d, dict) else []:
        if isinstance(o, dict) and o.get("name") == sys.argv[2]: raise SystemExit(0)
raise SystemExit(1)
PYDUP
    then
        print_error "已存在同名出站 '$name' —— 请换个名字"
        rm -rf "$tmp"; return 1
    fi
    python3 - "$f" "$name" "$tmp/norm.yaml" <<'PYEXP'
import sys, yaml
path, name, sub = sys.argv[1:4]
proxies = yaml.safe_load(open(sub, encoding="utf-8"))["proxies"]
# 原先手工拼 YAML 字符串, 结果缩进错了 2 空格 —— `- name:` 之后的键要跟
# name 同列 (4 空格), 我写成了 6。校验器当场报 YAML 解析失败, 但更好的做法
# 是不手拼: 交给 yaml 序列化, 缩进/转义/嵌套全由它保证。
out = []
for i, p in enumerate(proxies, 1):
    o = {k: v for k, v in p.items() if k != "name"}
    # 名字加组名前缀, 否则两个 URL 里都叫"香港01"的节点会互相覆盖
    o = {"name": "%s/%02d %s" % (name, i, p.get("name", "?")), **o}
    out.append(o)
head = ("# 服务端出站组 · %s —— 由 URL 导入 (%d 个节点), 删除请用面板菜单\n"
        % (name, len(out)))
body = yaml.safe_dump({"outbounds": out}, allow_unicode=True, default_flow_style=False,
                      sort_keys=False, width=4096)
open(path, "w", encoding="utf-8").write(head + body)
PYEXP
    print_ok "已创建 outbound-$idx ($name)"
    _extra_apply
    rm -rf "$tmp"
}

_extra_ask_outbound_type() {
    # 之前只有 direct/reject/socks5/http 四项, 是**我们菜单窄**, 不是内核不支持。
    # mihomo 的 outbound/ 下实际实现了 16 种 (validate.py OUTBOUND_TYPES 与
    # 内核二进制 strings 双向核对过), 其中 ss/vmess/vless/trojan/hysteria2/
    # tuic/anytls/shadow-tls/wireguard 都能当出站用 —— 也就是**链路套娃**:
    # 这台服务器的流量经由另一台服务器的节点出去。
    #
    # 列出的是"能连到别的服务器"的那几种; pass/compatible/reject-drop 属于
    # 内核内部控制流, 开放给用户没意义, 不列。
    printf '\n  出站类型:\n' >&2
    printf '    1) direct  直连 (本机自己出去)\n' >&2
    printf '    2) reject  拒绝\n' >&2
    printf '    3) socks5  转发给另一个 SOCKS 代理\n' >&2
    printf '    4) http    转发给一个 HTTP 代理\n' >&2
    ui_rule
    printf '    --- 转发到另一台服务器的节点 (链路套娃) ---\n' >&2
    printf '    5) ss        Shadowsocks\n' >&2
    printf '    6) vmess     VMess\n' >&2
    printf '    7) vless     VLESS\n' >&2
    printf '    8) trojan    Trojan\n' >&2
    printf '    9) hysteria2 Hysteria2\n' >&2
    printf '   10) tuic      TUIC\n' >&2
    printf '   11) anytls    AnyTLS\n' >&2
    printf '   12) snell     Snell\n' >&2
    printf '   13) wireguard WireGuard\n' >&2
    ui_rule
    printf '   14) 从订阅 URL 导入 (和客户端添加节点一样)\n' >&2
    printf '  请选择 [1]: ' >&2
    local c; read -r c || return 1
    # ⚠ 这里的结果是用全局变量 OB_TYPE 传出去的, 不是 stdout。
    #   原先 `t=$(_extra_ask_outbound_type)` 跑在**命令替换子shell**里,
    #   于是第 14 项里调用的 _extra_outbound_from_url 也在子shell里执行 ——
    #   它写的文件还在, 但 t 拿到的仍是 direct, 于是主流程继续走手工分支,
    #   结果: 用户选了"从 URL 导入", 却拿到一个用 URL 拼出来的畸形名字,
    #   而且**全程无报错**。
    case "$c" in
        2) OB_TYPE=reject ;; 3) OB_TYPE=socks5 ;; 4) OB_TYPE=http ;;
        5) OB_TYPE=ss ;; 6) OB_TYPE=vmess ;; 7) OB_TYPE=vless ;;
        8) OB_TYPE=trojan ;; 9) OB_TYPE=hysteria2 ;; 10) OB_TYPE=tuic ;;
        11) OB_TYPE=anytls ;; 12) OB_TYPE=snell ;; 13) OB_TYPE=wireguard ;;
        14) OB_TYPE=__url__ ;;
        *) OB_TYPE=direct ;;
    esac
    printf '%s' "$OB_TYPE"
}

outbound_add() {
    print_title "添加服务端出站"
    local OB_TYPE="" t
    t=$(_extra_ask_outbound_type) || return 1
    # __url__ 必须在主流程里分派 (见 _extra_ask_outbound_type 里的说明)
    [[ "$t" == "__url__" ]] && { _extra_outbound_from_url; return $?; }

    local name default_port
    case "$t" in
        socks5|reject) default_port="" ;;
        http) default_port="" ;;
        *) default_port="" ;;
    esac

    printf '\n  出站名称 (规则里用它引用, 建议用英文/短横线):\n  名称: ' >&2
    local name; read -r name || return 1
    name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9_-')
    [[ -n "$name" ]] || { print_error "名称不能为空 (只能用字母/数字/下划线/短横线)"; return 1; }

    # 名字撞了不静默覆盖 —— 规则里引用的是名字, 改了名字等于悄悄改坏规则
    if python3 - "$CONF_DIR" "$name" <<'PY' 2>/dev/null
import sys, glob, yaml
want = sys.argv[2]
for f in glob.glob(sys.argv[1] + "/outbound-*.yaml"):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception:
        continue
    for o in (d.get("outbounds") or []) if isinstance(d, dict) else []:
        if isinstance(o, dict) and o.get("name") == want:
            raise SystemExit(0)
raise SystemExit(1)
PY
    then
        print_error "已存在同名出站 '$name' —— 请换个名字 (规则按名字引用, 覆盖会改坏已有规则)"
        return 1
    fi

    local extra=""
    # 除 direct/reject 外都要问连接参数。按协议各自的必填项来问, 不做
    # "一律问地址端口再靠猜" —— 那会让 trojan 少个密码也能生成, 到运行时
    # 才报连不上。
    if [[ "$t" != "direct" && "$t" != "reject" ]]; then
        printf '  上游服务器地址 (域名或 IP): ' >&2
        local up; read -r up || return 1
        up=$(clean_input "$up")
        [[ -n "$up" ]] || { print_error "地址不能为空"; return 1; }
        printf '  上游端口: ' >&2
        local up_port; read -r up_port || return 1
        up_port=$(clean_input "$up_port")
        if [[ ! "$up_port" =~ ^[0-9]{1,5}$ ]] || (( up_port < 1 || up_port > 65535 )); then
            print_error "端口必须是 1-65535"; return 1
        fi
        extra="$up:$up_port"
        local cred
        case "$t" in
            ss)
                printf '  加密方式 (aes-256-gcm / aes-128-gcm / chacha20-ietf-poly1305): ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred"); cred="${cred:-aes-256-gcm}"
                extra="$extra|$cred"
                printf '  密码: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] || { print_error "密码不能为空"; return 1; }
                extra="$extra|$cred" ;;
            vmess|vless)
                printf '  UUID: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] || { print_error "UUID 不能为空"; return 1; }
                extra="$extra|$cred"
                printf '  传输方式 ws / grpc / h2 / tcp [ws]: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred"); cred="${cred:-ws}"
                extra="$extra|$cred" ;;
            trojan)
                printf '  密码: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] || { print_error "密码不能为空"; return 1; }
                extra="$extra|$cred" ;;
            hysteria2)
                printf '  密码: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] || { print_error "密码不能为空"; return 1; }
                extra="$extra|$cred" ;;
            tuic)
                printf '  UUID: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] || { print_error "UUID 不能为空"; return 1; }
                extra="$extra|$cred"
                printf '  密码: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] || { print_error "密码不能为空"; return 1; }
                extra="$extra|$cred" ;;
            anytls)
                printf '  密码: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] || { print_error "密码不能为空"; return 1; }
                extra="$extra|$cred" ;;
            snell)
                printf '  密钥 (psk): ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] || { print_error "密钥不能为空"; return 1; }
                extra="$extra|$cred"
                printf '  版本 (1-5) [3]: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred"); cred="${cred:-3}"
                extra="$extra|$cred" ;;
            socks5|http)
                printf '  用户名 (可留空): ' >&2
                read -r cred || return 1; extra="$extra|$(clean_input "$cred")"
                printf '  密码 (可留空): ' >&2
                read -r cred || return 1; extra="$extra|$(clean_input "$cred")" ;;
            wireguard)
                printf '  公钥 (peer public key): ' >&2
                read -r cred || return 1; extra="$extra|$(clean_input "$cred")"
                printf '  本机私钥 (可留空, 留空则内核自动生成): ' >&2
                read -r cred || return 1; extra="$extra|$(clean_input "$cred")"
                printf '  本机地址 如 10.0.0.2/32 [回车自动]: ' >&2
                read -r cred || return 1; cred=$(clean_input "$cred")
                [[ -n "$cred" ]] && extra="$extra|$cred" ;;
        esac
    fi

    local idx
    idx=$(_extra_next_index outbound)
    local f
    f=$(printf '%s/outbound-%s.yaml' "$(_extra_dir)" "$idx")

    python3 - "$f" "$name" "$t" "$extra" <<'PY'
import sys, re
path, name, t, extra = sys.argv[1:5]
Q = lambda v: '"%s"' % str(v).replace("\\", "\\\\").replace('"', '\\"')
L = [f"# 服务端出站 · {name} ({t}) —— 由面板生成, 删除请用面板菜单"]
if t in ("direct", "reject"):
    L += ["outbounds:", f"  - name: {name}", f"    type: {t}"]
else:
    parts = extra.split("|")
    host, _, port = parts[0].rpartition(":")
    host = host or parts[0]
    L += ["outbounds:", f"  - name: {name}", f"    type: {t}",
          f"    server: {Q(host)}", f"    port: {int(port)}"]
    cred = parts[1:]
    if t == "ss":
        L += [f"    cipher: {Q(cred[0])}", f"    password: {Q(cred[1])}"]
    elif t in ("vmess", "vless"):
        L += [f"    uuid: {Q(cred[0])}"]
        net = cred[1] if len(cred) > 1 else "ws"
        L += [f"    network: {net}"]
        if net in ("ws", "grpc"):
            L += [f"    {net}-opts:", f"      path: /{name}"]
        L += ["    tls: true", "    udp: true"]
    elif t in ("trojan", "hysteria2", "anytls"):
        L += [f"    password: {Q(cred[0])}", "    tls: true", "    udp: true"]
    elif t == "tuic":
        L += [f"    uuid: {Q(cred[0])}", f"    password: {Q(cred[1])}",
              "    congestion-controller: bbr", "    tls: true", "    udp: true"]
    elif t == "snell":
        L += [f"    psk: {Q(cred[0])}", f"    version: {int(cred[1]) if len(cred) > 1 else 3}"]
    elif t in ("socks5", "http"):
        if cred and cred[0]:
            L += ["    username: " + Q(cred[0])]
        if len(cred) > 1 and cred[1]:
            L += ["    password: " + Q(cred[1])]
    elif t == "wireguard":
        L += ["    private-key: " + Q(cred[1] if len(cred) > 1 and cred[1] else ""),
              "    peer-public-key: " + Q(cred[0] if cred else ""),
              "    ip: " + Q("172.16.0.2/32"),
              "    reserved: [1, 2, 3]"]
        if len(cred) > 2 and cred[2]:
            L[-1] = f"    ip: {Q(cred[2])}"
open(path, "w", encoding="utf-8").write("\n".join(L) + "\n")
PY

    print_ok "已创建 outbound-$idx ($name)"
    _extra_apply
}

outbound_list() {
    print_title "服务端出站"
    local n; n=$(_extra_count outbound)
    if [[ "$n" == "0" ]]; then
        printf '\n  (还没有出站)\n\n' >&2
        return 0
    fi
    printf '\n  %-6s %s\n' "编号" "出站" >&2
    printf '  %s\n' "--------------------------------" >&2
    _extra_list outbound | while IFS=$'\t' read -r idx sum; do
        printf '  %-6s %s\n' "$idx" "$sum" >&2
    done
    printf '\n' >&2
}

outbound_del() {
    print_title "删除服务端出站"
    outbound_list
    printf '  要删除的编号 (回车取消): ' >&2
    local idx; read -r idx || return 1
    [[ -n "$idx" ]] || return 0
    _extra_del outbound "$idx"
    _extra_apply
}

outbound_menu() {
    while true; do
        print_title "出站管理"
        ui_menu 1 "添加出站"
        ui_menu 2 "列出出站"
        ui_menu 3 "删除出站"
        ui_rule
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        local c; c=$(clean_input "$(read -r)") || break
        case "$c" in
            1) outbound_add; pause ;;
            2) outbound_list; pause ;;
            3) outbound_del; pause ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}

# =============================================================
# 三、规则集管理
# =============================================================
#
# mihomo rule-provider 的 type (vehicle) 只有三种, 已用 mihomo -t 实测:
#   * inline —— 规则直接写在配置的 payload 里 (本面板用它, 不依赖外部文件/网络)
#   * file   —— 本地文件
#   * http   —— 远程规则集
#
# ⚠ **不是 "payload"**。凭直觉写 type: payload 内核不认, 报的是
#   "unsupported vehicle type: payload" —— 错误名里没有 rule-provider,
#   很容易误以为是别的段坏了, 而 listeners/proxies 都与它无关。
#
# 这里做 payload 型: 用户在菜单里一行一行加域名/关键词, 生成
# rule-providers + 对应的 RULE-SET 规则。行为 domain / ipcidr / classical。
# 内核实测三种 behavior 均通过 -t。
_extra_ask_ruleset_behavior() {
    printf '\n  规则类型:\n' >&2
    printf '    1) domain   域名 (含子域)\n' >&2
    printf '    2) ip-cidr  IP 段\n' >&2
    printf '    3) classical 经典规则 (DOMAIN-SUFFIX / GEOIP 等)\n' >&2
    printf '  请选择 [1]: ' >&2
    local c; read -r c || return 1
    case "$c" in 2) printf 'ipcidr' ;; 3) printf 'classical' ;; *) printf 'domain' ;; esac
}

ruleset_add() {
    print_title "添加规则集"
    printf '\n  规则集名称 (小写字母/数字/短横线):\n  名称: ' >&2
    local name; read -r name || return 1
    name=$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')
    [[ -n "$name" ]] || { print_error "名称不合法"; return 1; }
    [[ "$name" != *-* ]] || { print_error "名称里不要用短横线 (YAML 键名会难读, 用下划线)"; return 1; }

    if python3 - "$CONF_DIR" "$name" <<'PY' 2>/dev/null
import sys, glob, yaml
want = sys.argv[2]
for f in glob.glob(sys.argv[1] + "/ruleset-*.yaml"):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception:
        continue
    if isinstance(d, dict) and want in (d.get("rule-providers") or {}):
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
        print_error "已存在同名规则集 '$name'"; return 1
    fi

    local beh; beh=$(_extra_ask_ruleset_behavior) || return 1

    printf '\n  逐条输入规则 (留空结束):\n' >&2
    local -a items=()
    while true; do
        printf '    规则 (如 example.com): ' >&2
        local it; read -r it || break
        [[ -n "$it" ]] || break
        items+=("$it")
    done
    (( ${#items[@]} > 0 )) || { print_error "至少要一条规则"; return 1; }

    # 命中的目标: 内置的 DIRECT / REJECT, 外加**用户自己建的出站**
    # (比如 socks5 / http 上游)。原先只有 DIRECT/REJECT 两项, 等于
    # "把某个域名指定到某个出口" 这件事根本做不了。
    printf '\n  命中后走哪里:\n' >&2
    printf '    1) DIRECT 直连\n' >&2
    printf '    2) REJECT 拒绝 (断掉, 不回源)\n' >&2
    local -a ob_names=(); local of
    for of in "$(_extra_dir)"/outbound-*.yaml; do
        [[ -f "$of" ]] || continue
        local on; on=$(awk '/^[[:space:]]*- name:/{gsub(/"/,"",$3);print $3;exit}' "$of")
        local ot; ot=$(awk '/^[[:space:]]*type:/{print $2;exit}' "$of")
        [[ -n "$on" ]] && ob_names+=("$on|${ot:-?}")
    done
    if (( ${#ob_names[@]} > 0 )); then
        local i=3
        for of in "${ob_names[@]}"; do
            printf '    %d) 自定义出站 %s (%s)\n' "$i" "${of%%|*}" "${of##*|}" >&2
            i=$(( i + 1 ))
        done
    fi
    local oc; printf '  请选择 [1]: ' >&2
    read -r oc || oc=1
    oc=$(clean_input "$oc"); oc="${oc:-1}"
    local target="DIRECT"
    if [[ "$oc" == "2" ]]; then
        target="REJECT"
    elif (( oc >= 3 )) && [[ -n "${ob_names[$(( oc - 3 ))]:-}" ]]; then
        target="${ob_names[$(( oc - 3 ))]%%|*}"
    elif [[ "$oc" != "1" ]]; then
        print_warn "无效选项, 按 DIRECT 处理"
    fi

    local idx; idx=$(_extra_next_index ruleset)
    local f; f=$(printf '%s/ruleset-%s.yaml' "$(_extra_dir)" "$idx")

    python3 - "$f" "$name" "$beh" "$target" "${items[@]}" <<'PY'
import sys
path, name, beh, target = sys.argv[1:5]
items = sys.argv[5:]
L = [f"# 规则集 · {name} ({beh}) —— 由面板生成, 删除请用面板菜单",
     "rule-providers:", f"  {name}:", f"    type: inline",
     f"    behavior: {beh}", "    payload:"]
L += [f"      - {it!r}" for it in items]
L += ["", "rules:", f"  - RULE-SET,{name},{target}"]
open(path, "w", encoding="utf-8").write("\n".join(L) + "\n")
PY

    print_ok "已创建 ruleset-$idx ($name, ${#items[@]} 条)"
    _extra_apply
}

ruleset_list() {
    print_title "规则集"
    local n; n=$(_extra_count ruleset)
    if [[ "$n" == "0" ]]; then
        printf '\n  (还没有规则集)\n\n' >&2
        return 0
    fi
    printf '\n  %-6s %s\n' "编号" "规则集" >&2
    printf '  %s\n' "--------------------------------" >&2
    _extra_list ruleset | while IFS=$'\t' read -r idx sum; do
        printf '  %-6s %s\n' "$idx" "$sum" >&2
    done
    printf '\n' >&2
}

ruleset_del() {
    print_title "删除规则集"
    ruleset_list
    printf '  要删除的编号 (回车取消): ' >&2
    local idx; read -r idx || return 1
    [[ -n "$idx" ]] || return 0
    _extra_del ruleset "$idx"
    _extra_apply
}

ruleset_menu() {
    while true; do
        print_title "规则集管理"
        ui_menu 1 "添加规则集"
        ui_menu 2 "列出规则集"
        ui_menu 3 "删除规则集"
        ui_rule
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        local c; c=$(clean_input "$(read -r)") || break
        case "$c" in
            1) ruleset_add; pause ;;
            2) ruleset_list; pause ;;
            3) ruleset_del; pause ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}

# =============================================================
# 四、端口转发
# =============================================================
#
# 内核实测字段 (mihomo -t v1.19.32 逐字段验证):
#   listeners:
#     - name: pf-01
#       type: tunnel            # ★ 不是 direct —— 内核没有 direct 这个 listener
#       listen: 0.0.0.0
#       port: <本机监听端口>
#       network:                # ★ 必须是列表, 写标量报 "'network' is not a slice"
#         - tcp                 #   可选 tcp / udp
#       target: <目标 host:port> # 无 ,omitempty => 缺了报 "has unset fields"
#       override-destination: false
#
# override-destination 是关键: 不开它 target 是唯一出口 (更安全, 默认档);
# 开了之后客户端可以在请求里指定别的目标, 相当于一个不改内容的转发代理。
pfwd_add() {
    print_title "添加端口转发"
    printf '\n  本机监听地址 [0.0.0.0]: ' >&2
    local laddr; read -r laddr || return 1
    laddr="${laddr:-0.0.0.0}"
    # IPv6 的 [::1] 写法先剥掉方括号再校验 ——
    # 正则里不能写 [\[\]]: bash 的 ERE 把括号类内的 \[ \] 当成一个**区间**,
    # 结果 0.0.0.0 这种最正常的地址反而匹配不上 (实测踩过)。
    local lchk="${laddr#[}"; lchk="${lchk%]}"
    [[ "$lchk" =~ ^[0-9A-Za-z._:-]+$ ]] || { print_error "监听地址不合法: $laddr"; return 1; }

    printf '  本机监听端口 (如 23389): ' >&2
    local lport; read -r lport || return 1
    [[ "$lport" =~ ^[0-9]{1,5}$ ]] && (( lport >= 1 && lport <= 65535 )) \
        || { print_error "端口必须是 1-65535 的数字"; return 1; }

    # 端口占用预检 —— 否则 mihomo 启动时 bind 失败, 整个服务端起不来
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$lport\$"; then
        print_error "端口 $lport 已被占用, 换一个"
        return 1
    fi

    printf '  目标地址 (如 127.0.0.1:3000 或 example.com:443): ' >&2
    local target; read -r target || return 1
    # 同样避开括号类里的 [] —— IPv6 目标 [::1]:22 先剥方括号
    local tchk="${target#[}"; tchk="${tchk%]}"
    [[ "$tchk" =~ ^[0-9A-Za-z._:-]+:[0-9]+$ ]] || { print_error "目标格式应为 host:port"; return 1; }

    printf '\n  转发哪些协议?\n' >&2
    printf '    1) tcp\n' >&2
    printf '    2) tcp + udp\n' >&2
    printf '  请选择 [1]: ' >&2
    local nc; read -r nc || nc=1
    local netblock="      - tcp"
    [[ "$nc" == "2" ]] && netblock="      - tcp\n      - udp"

    local od="false"
    printf '\n  是否允许客户端指定真实目标 (override-destination)?\n' >&2
    printf '    1) 否 —— 所有流量都送到上面那个目标 (推荐, 更安全)\n' >&2
    printf '    2) 是 —— 客户端可以在请求里指定别的目标\n' >&2
    printf '  请选择 [1]: ' >&2
    local oc; read -r oc || oc=1
    [[ "$oc" == "2" ]] && od="true"

    local idx; idx=$(_extra_next_index pfwd)
    local f; f=$(printf '%s/pfwd-%s.yaml' "$(_extra_dir)" "$idx")

    # ★ type 必须是 tunnel, 不是 direct —— 内核没有 direct 这个 listener 类型,
    #   写成 direct 会让 mihomo -t 报 "unsupport proxy type: direct", 而这会
    #   因为 listeners 是共享数组而**整批配置**校验不过 (节点也一起起不来)。
    #   network 必须是**列表**, 写成标量报 "'network' is not a slice"。
    printf '# 端口转发 · %s:%s -> %s —— 由面板生成, 删除请用面板菜单\n' \
        "$laddr" "$lport" "$target" > "$f"
    printf 'listeners:\n' >> "$f"
    printf '  - name: pf-%s\n' "$idx" >> "$f"
    printf '    type: tunnel\n' >> "$f"
    printf '    listen: "%s"\n' "$laddr" >> "$f"
    printf '    port: %s\n' "$lport" >> "$f"
    printf '    network:\n%s\n' "$netblock" >> "$f"
    printf '    target: "%s"\n' "$target" >> "$f"
    printf '    override-destination: %s\n' "$od" >> "$f"

    print_ok "已创建 pfwd-$idx ($laddr:$lport -> $target)"
    _extra_apply
}

pfwd_list() {
    print_title "端口转发"
    local n; n=$(_extra_count pfwd)
    if [[ "$n" == "0" ]]; then
        printf '\n  (还没有端口转发)\n\n' >&2
        return 0
    fi
    printf '\n  %-6s %s\n' "编号" "监听 -> 目标" >&2
    printf '  %s\n' "--------------------------------" >&2
    _extra_list pfwd | while IFS=$'\t' read -r idx sum; do
        printf '  %-6s %s\n' "$idx" "$sum" >&2
    done
    printf '\n' >&2
}

pfwd_del() {
    print_title "删除端口转发"
    pfwd_list
    printf '  要删除的编号 (回车取消): ' >&2
    local idx; read -r idx || return 1
    [[ -n "$idx" ]] || return 0
    _extra_del pfwd "$idx"
    _extra_apply
}

pfwd_menu() {
    while true; do
        print_title "端口转发"
        ui_menu 1 "添加转发"
        ui_menu 2 "列出转发"
        ui_menu 3 "删除转发"
        ui_rule
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        local c; c=$(clean_input "$(read -r)") || break
        case "$c" in
            1) pfwd_add; pause ;;
            2) pfwd_list; pause ;;
            3) pfwd_del; pause ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
    done
}

# =============================================================
# 五、卸载时要一并清掉的片段
#
# 与 _uninstall_all 的清单放在一起 (见 server.sh)。这里只提供名字列表,
# 免得那处再手写一遍前缀。
_extra_fragment_prefixes() { printf 'outbound ruleset pfwd'; }

# =============================================================
# SOCKS 入站
#
# 为什么单独做: 协议档位都是**给外面用的**节点, 需要证书/REALITY/抗封锁;
# 而 SOCKS 入站是给**自己或内网**用的 —— 比如在内部跑脚本、让同网段的
# 机器借道出网。它不需要任何抗封锁能力, 越简单越好维护, 所以只问三件事:
# 监听地址 / 端口 / 用户名密码。
#
# 监听地址的四个常用写法 (这是最容易配错的一项, 所以做成选项而不是自由输入):
#   127.0.0.1  只有本机能连       ← 默认, 最安全
#   0.0.0.0    本机所有 IPv4 网卡  ← 允许局域网访问
#   ::         本机所有 IPv6 网卡  ← 允许 IPv6 网络访问
#   ::1       只有本机的 IPv6 回环
# =============================================================

_socks_addr_choices() {
    printf '    1) 127.0.0.1  —— 只有本机能连 (默认, 最安全)\n'
    printf '    2) 0.0.0.0    —— 本机所有 IPv4 网卡 (允许局域网访问)\n'
    printf '    3) ::         —— 本机所有 IPv6 网卡 (允许 IPv6 网络访问)\n'
    printf '    4) ::1        —— 只有本机的 IPv6 回环\n'
    printf '    5) 手输一个地址\n'
}

socks_add() {
    print_title "添加 SOCKS 入站"
    ui_hint "给自己或内网用的出站口。不需要证书, 也不做抗封锁 —— 只问监听地址、端口和账号密码。"

    printf '\n  监听地址 (决定谁能连):\n' >&2
    _socks_addr_choices
    printf '  请选择 [1]: ' >&2
    local c; read -r c || return 1
    c=$(clean_input "$c"); c="${c:-1}"
    local laddr
    case "$c" in
        2) laddr="0.0.0.0" ;;
        3) laddr="::" ;;
        4) laddr="::1" ;;
        5)
            printf '  请输入监听地址: ' >&2
            read -r laddr || return 1
            laddr="${laddr:-127.0.0.1}"
            local chk="${laddr#[}"; chk="${chk%]}"
            [[ "$chk" =~ ^[0-9A-Za-z._:-]+$ ]] \
                || { print_error "监听地址不合法: $laddr"; return 1; }
            ;;
        *) laddr="127.0.0.1" ;;
    esac

    printf '\n  监听端口 (1-65535, 建议 1080 或 10808): ' >&2
    local lport; read -r lport || return 1
    lport=$(clean_input "$lport"); lport="${lport:-1080}"
    [[ "$lport" =~ ^[0-9]{1,5}$ ]] && (( lport >= 1 && lport <= 65535 )) \
        || { print_error "端口必须是 1-65535 的数字"; return 1; }
    # 占用预检: mihomo bind 失败会导致**整个服务端起不来**, 不是这个
    # 入站不能用, 是全部节点一起挂 —— 所以宁可在这里挡住。
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$lport\$"; then
        print_error "端口 $lport 已被占用, 换一个"
        return 1
    fi

    printf '\n  用户名: ' >&2
    local user; read -r user || return 1
    user=$(clean_input "$user")
    [[ -n "$user" ]] || { print_error "用户名不能为空"; return 1; }

    printf '  密码 (留空则自动生成): ' >&2
    local pass; read -r pass || return 1
    pass=$(clean_input "$pass")
    if [[ -z "$pass" ]]; then
        pass=$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | cut -c1-16)
        [[ -n "$pass" ]] || pass=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16)
        print_info "已自动生成密码: $pass"
    fi
    # 用户名密码里的引号/反斜杠会破坏 YAML, 双引号包裹 + 转义
    user=${user//\\/\\\\}; user=${user//\"/\\\"}
    pass=${pass//\\/\\\\}; pass=${pass//\"/\\\"}

    printf '\n  允许 UDP 转发? (SOCKS5 的 UDP ASSOCIATE)\n' >&2
    printf '    1) 是\n' >&2
    printf '    2) 否 (只要 TCP, 更省心)\n' >&2
    printf '  请选择 [1]: ' >&2
    local uc; read -r uc || return 1
    uc=$(clean_input "$uc"); uc="${uc:-1}"
    local udp="udp: false"
    [[ "$uc" == "1" ]] && udp="udp: true"

    local idx; idx=$(_extra_next_index socks)
    local tag="socks-$(printf '%02d' "$idx")"
    local f="$(_extra_dir)/$tag.yaml"

    cat > "$f" <<EOF
# 由 server.sh SOCKS 入站生成 · $laddr:$lport
listeners:
  - name: mSOCKS-$idx
    type: socks
    listen: "$laddr"
    port: $lport
    users:
      - username: "$user"
        password: "$pass"
    $udp
EOF

    if ! _extra_apply; then
        print_error "配置校验未通过, 已自动回滚"
        rm -f "$f"
        return 1
    fi
    print_ok "已添加并生效: $laddr:$lport"
    print_info "用户名 $user / 密码 $pass"
    return 0
}

socks_list() {
    local f found=0
    for f in "$(_extra_dir)"/socks-*.yaml; do
        [[ -f "$f" ]] || continue
        found=1
        local a p u
        a=$(awk '/^[[:space:]]*listen:/{gsub(/"/,"",$2);print $2;exit}' "$f")
        p=$(awk '/^[[:space:]]*port:/{print $2;exit}' "$f")
        u=$(awk '/^[[:space:]]*username:/{gsub(/"/,"",$2);print $2;exit}' "$f")
        printf '  %-10s %-24s %-14s 用户: %s\n' "$(basename "$f" .yaml)" "${a:-?}:${p:-?}" \
            "$(grep -q 'udp: true' "$f" && echo 'UDP+TCP' || echo '仅 TCP')" "${u:-?}"
    done
    (( found )) || print_info "还没有 SOCKS 入站"
}

socks_del() {
    socks_list
    printf '\n  要删哪个? (填编号对应的文件名, 如 socks-01): ' >&2
    local tag; read -r tag || return 1
    tag=$(clean_input "$tag")
    [[ -n "$tag" ]] || return 1
    local f="$(_extra_dir)/$tag.yaml"
    [[ -f "$f" ]] || { print_error "没有这个条目: $tag"; return 1; }
    rm -f "$f"
    if _extra_apply; then
        print_ok "已删除并生效"
    else
        print_error "删除后校验失败, 请手工确认"
    fi
}

socks_menu() {
    local c
    while true; do
        print_title "SOCKS 入站 (自己 / 内网用)"
        ui_hint "不需要证书, 也不做抗封锁。只决定: 谁能连 (监听地址) + 端口 + 账号密码。"
        ui_menu 1 "添加"
        ui_menu 2 "查看"
        ui_menu 3 "删除"
        ui_rule
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || { printf '\n' >&2; print_info "非交互环境, 已退出"; return 0; }
        c=$(clean_input "$c")
        case "$c" in
            1) socks_add ;;
            2) socks_list ;;
            3) socks_del ;;
            0) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        echo >&2
        printf "  ${DIM}按回车继续...${RESET}" >&2
        read -r _ || true
    done
}
