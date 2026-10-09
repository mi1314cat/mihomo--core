#!/usr/bin/env bash
# =============================================================
# mihomo--core 客户端面板
#
#   拉取分享链接 → 自动导入为 proxy-provider → 选组出网
#
# 设计要点(与 sing-box 客户端的关键差异):
#   * 不用任何格式转换器 —— 服务端发的是 Mihomo 原生的 `proxies:` YAML,
#     客户端直接存成 type: file 的 proxy-provider, Mihomo 自己认。
#   * 分组用 use: 引用 provider, 新增节点不需要改配置。
#   * 单次令牌(max_uses=1)只拉一次存本地文件; 永久订阅用 type: http + interval。
#     否则 interval 会把一次性链接的额度反复消耗掉。
#   * 拉取失败一律不动现有节点(先备份, 成功才替换)。
# =============================================================
set -uo pipefail

: "${CLI_ROOT:=/root/catmi/mihomo-client}"

# 先读上次保存的设置, 再套默认值 —— 否则改过的端口下次打开面板就丢了,
# gen_config 会被悄悄改回 7890/9090。
CLI_SETTINGS="$CLI_ROOT/settings.env"
if [[ -f "$CLI_SETTINGS" ]]; then
    # 只接受 KEY="VALUE", 不 source 执行代码
    while IFS=$'\t' read -r _k _v; do
        [[ -n "$_k" ]] || continue
        printf -v "$_k" '%s' "$_v"
    done < <(python3 - "$CLI_SETTINGS" <<'PYSET'
import re, sys
pat = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)="(.*)"$')
try:
    for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
        m = pat.match(raw.rstrip("\n").rstrip("\r"))
        if m:
            sys.stdout.write(f"{m.group(1)}\t{m.group(2)}\n")
except FileNotFoundError:
    pass
PYSET
    )
fi

: "${CLI_CONF:=$CLI_ROOT/conf}"          # ★ -d 工作目录 (SAFE_PATHS 以此为根)
: "${CLI_PROVIDERS:=$CLI_CONF/providers}"
: "${CLI_NODES:=$CLI_ROOT/nodes}"
: "${CLI_BIN:=$CLI_ROOT/mihomo}"
: "${CLI_SERVICE:=mihomo-client}"
: "${CLI_UI:=$CLI_ROOT/ui}"
: "${CLI_SUBS:=$CLI_ROOT/subscriptions.json}"
# 共享库目录 —— 用变量固定下来, 不要在函数里每次从 BASH_SOURCE 推导,
# 否则脚本被复制/截断到别处时就找不到 validate.py 了。
CLI_LIB="${CLI_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib}"

# ---------- 共享库 ----------
# 客户端**也要**走 env.sh。
#
# 之前的注释写的是"客户端不经过 env.sh, 这里自己兜一道", 于是只单独 source
# 了 ui.sh。那个决定本身没错 (env.sh 会在 /root/catmi/mihomo 下建服务端
# 目录树), 但它漏掉了一件事: m_resolve_ports / m_free_port / m_port_in_use
# 这些端口 helper **只定义在 env.sh 里**, 客户端一个都拿不到。
#
# 后果是首次生成配置必炸 (实测, 全新安装后从面板拉第一个订阅):
#     src/client.sh: line 185: m_resolve_ports: command not found
#     src/client.sh: line 186: M_PORT_MIXED: unbound variable
# gen_config 里那段"写配置前先把端口定死"的逻辑因此从来没生效过, 而
# set -u 会让它直接中断 —— 新用户第一次拉订阅就卡在这。
#
# env.sh 现在已经把"建服务端目录"那步用 M_NO_SRV_DIRS 关掉了, 所以这里
# 可以放心 source。加载顺序: env.sh 自己会带入 ui.sh / core_mgmt.sh /
# fw.sh / cert.sh / preset.sh / cdn.sh (都依赖 ui.sh, 顺序已在 env.sh 里
# 排好), 下面的循环只补它没带的那些。
M_NO_SRV_DIRS=1
# shellcheck source=/dev/null
[[ -f "$CLI_LIB/env.sh" ]] && source "$CLI_LIB/env.sh"
unset M_NO_SRV_DIRS

# 端口与出网探测的默认值。放在 env.sh 之后: 这几个是**客户端独有**的,
# env.sh 里没有, 但 save_settings / gen_config 要读。
: "${PORT_MIXED:=7890}"
: "${PORT_CTRL:=9090}"
# 监听地址默认 **0.0.0.0 (局域网可达)**, 不是 127.0.0.1。
#
# 面板是给局域网内其他机器访问的 —— 绑回环等于只有本机能打开。
#
# SB 的默认值本来就是局域网 (install.sh: BIND_LAN="${BIND_LAN:-0.0.0.0}",
# CLASH_LISTEN="${CLASH_LISTEN:-0.0.0.0}") —— 所以这不是"Mihomo 内核不同所以必须
# 不同", 而是**我还没把 SB 里已经验证过的产品默认值迁移过来**。
#
# 存 0.0.0.0 而不是具体那个 LAN IP, 是刻意的: DHCP 换地址后具体 IP 会绑不上,
# 内核直接起不来; 0.0.0.0 不受影响。**显示时**再解析成真实 LAN IP (见 host_addr)。
: "${BIND_ADDR:=0.0.0.0}"
: "${HEALTH_URL:=http://www.gstatic.com/generate_204}"

# ---------- 监听地址 / 显示地址 ----------
#
# 这是两个不同的概念, 混在一起就会出错:
#   * 监听地址 (BIND_ADDR) —— 写进配置, 决定内核 bind 在哪。可以是 0.0.0.0。
#   * 显示地址             —— 给用户看/复制进浏览器的。**0.0.0.0 不是可访问地址**,
#                            拿它当 URL 只会得到一个连不上的链接。
#
# SB 的做法 (client.sh: lan_ip / host_addr) 是这个思路, 但**它的实现有兜底缺陷,
# 我们补上**:
#   SB 只靠 `ip route get 1.1.1.1`, 没有默认路由时返回空 —— 而"没有默认路由"正是
#   纯局域网/离线机器 (也就是最需要走本机代理的那类机器) 的常见状态。空了之后
#   URL 会拼成 "http://:9090/ui/", 一个点不开的坏链接。
# 所以这里加两级兜底: 路由探测 -> 本机第一个非回环 IPv4 -> 127.0.0.1。
lan_ip() {
    local v
    # ① 默认路由上的源地址 (最准: 就是这台机器对外用的那个地址)
    v=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    # ② 没有默认路由 (纯局域网/离线) -> 拿第一个非回环 IPv4
    v=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | grep -vE '^127\.' | head -1)
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    # ③ 连网卡地址都拿不到 -> 退回回环, 至少不是空字符串
    printf '127.0.0.1'
}

# 把监听地址解析成"真的能连上"的地址
host_addr() {
    case "${1:-}" in
        ""|0.0.0.0|"::"|"[::]"|"*") lan_ip ;;
        *) printf '%s' "$1" ;;
    esac
}

# UI 原语 (颜色/消息分级/标题/菜单) 统一来自 src/lib/ui.sh。
# 客户端不经过 env.sh 的老路已经改掉, 这里保留兜底: env.sh 缺失时面板
# 至少还能显示出中文而不是一堆 command not found。
_MUI="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/lib" && pwd)/ui.sh"
# shellcheck source=/dev/null
[[ -f "$_MUI" ]] && source "$_MUI"

# Web UI 管理与内核/版本管理。两者依赖上面的 ui.sh, 必须在它之后加载。
for _mx in webui portcheck rules_bind dl_route simple_proxy lan_dispatch; do
    _MEXTRA="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/lib" && pwd)/$_mx.sh"
    [[ -f "$_MEXTRA" ]] && source "$_MEXTRA"
done
unset _MEXTRA

# 客户端防火墙走自己的登记表 —— 客户端不监听对外端口, 它的登记项是
# 拉订阅/开面板时顺手放行的端口, 与服务端分开, 卸载时只回收自己的。
declare -F fw_close_port >/dev/null 2>&1 && FW_PORT_LIST="$CLI_ROOT/.fw-ports"

ensure_dirs() { mkdir -p "$CLI_CONF" "$CLI_PROVIDERS" "$CLI_NODES" "$CLI_UI"; }

# =============================================================
# 工具
# =============================================================
gen_secret() { openssl rand -hex 16; }

node_files() { ls "$CLI_PROVIDERS"/*.yaml 2>/dev/null | sort; }

# 面板状态里那个"节点: N"。
#
# 原来数的是 conf/providers/ 下的**文件个数** (= 订阅个数), 于是导入一个
# 含 19 个节点的订阅之后, 面板依旧显示 "节点: 1" —— 用户完全看不出自己
# 到底有多少个节点可用, 与"查看节点"里显示的 19 个也对不上账。
# 这里改为数 provider 里真实的 proxies 条目。
node_count() {
    local f c n=0
    for f in $(node_files); do
        c=$(python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    p = d.get("proxies") if isinstance(d, dict) else None
    print(len([x for x in (p or []) if isinstance(x, dict) and x.get("name")]))
except Exception:
    print(0)' "$f" 2>/dev/null || echo 0)
        [[ "$c" =~ ^[0-9]+$ ]] || c=0
        n=$((n + c))
    done
    printf '%s' "$n"
}

subs_file_init() { [[ -f "$CLI_SUBS" ]] || echo '{"subscriptions":[]}' > "$CLI_SUBS"; }

subs_get() {   # 输出该前缀的订阅记录 (json)
    python3 - "$CLI_SUBS" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit
for s in d.get("subscriptions", []):
    if s.get("prefix") == sys.argv[2]:
        print(json.dumps(s)); break
PY
}

# 覆盖订阅显示名。只改 name 字段, prefix/url/kind 一律不动 ——
# 这三样任何一个变了都会指向另一个 provider, 节点就凭空消失了。
subs_set_name() {   # 覆盖某条订阅的显示名, 其余字段一律不动
    python3 - "$CLI_SUBS" "$1" "$2" <<'PY'
import json, sys
path, prefix, label = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(1)
hit = False
for s in d.get("subscriptions", []):
    if s.get("prefix") == prefix:
        s["name"] = label
        hit = True
        break
if not hit:
    sys.exit(1)
json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
}

# 给某条订阅下的所有节点名加来源前缀。
#
# 为什么需要: 同一个客户端常常同时拉好几台服务器的订阅, 而它们是同一套脚本
# 生成的, 节点名**完全撞车** —— 两台都叫 mVLESS01-REALITY / mTrojan03-TLS。
# 面板里两个组长得一模一样, 连测速都分不清测的是哪台, 用户只能一个个点开
# 看端口猜来源。组名虽然能分开, 节点名不分开就等于没分开。
#
# 前缀取组名, 所以用户给组起名的那一刻就顺手解决了 —— 不再单独问一次前缀。
#
# 只改 provider 文件里的 proxies[].name:
#   客户端的 config.yaml 里所有组都是 `use: <provider>` 引用 provider,
#   **没有一处按节点名引用**, 所以改名不会产生悬空引用。
#   如果哪天有人在 config.yaml 里硬写了某个节点名, 这里会把它改坏 ——
#   所以下面保留了旧名到新名的映射, 供后续需要时使用。
#
# 已经带过前缀的不重复加 —— 更新订阅会重新下载原始文件, 所以每次下载后
# 都要重新应用一遍, 必须幂等。
node_prefix_names() {   # <provider 文件> <前缀>
    local f="$1" tag="$2"
    [[ -f "$f" && -n "$tag" ]] || return 0
    python3 - "$f" "$tag" <<'PY'
import sys, yaml
path, tag = sys.argv[1], sys.argv[2]
try:
    d = yaml.safe_load(open(path, encoding="utf-8")) or {}
except Exception:
    sys.exit(0)
ps = d.get("proxies")
if not isinstance(ps, list):
    sys.exit(0)
changed = 0
for p in ps:
    if not isinstance(p, dict):
        continue
    n = p.get("name")
    if not isinstance(n, str) or not n or n.startswith(tag + "-"):
        continue
    p["name"] = "%s-%s" % (tag, n)
    changed += 1
if changed:
    yaml.safe_dump(d, open(path, "w", encoding="utf-8"),
                   allow_unicode=True, sort_keys=False)
print(changed)
PY
}

# 从组名推出一个短前缀: 取第一段 (空格/下划线/连字符前), 最多 6 个字符。
# "<SERVER_ALIAS> 自建节点" -> <SERVER_ALIAS>,  "香港01" -> 香港01,  "两字母-中文" -> 两字母
node_tag_from_name() {
    local n; n=$(printf '%s' "${1:-}" | tr -d '[:space:]')
    n="${n%%[-_ ]*}"
    n="${n:0:6}"
    # 只保留字母数字和中文; 其余会让 YAML 的 name 字段出问题
    printf '%s' "$n" | tr -cd '[:alnum:]' | head -c 6
}

subs_put() {   # upsert
    python3 - "$CLI_SUBS" "$1" <<'PY'
import json, os, sys, tempfile
path, rec = sys.argv[1], json.loads(sys.argv[2])
d = {"subscriptions": []}
try:
    d = json.load(open(path))
except Exception:
    pass
lst = d.setdefault("subscriptions", [])
for i, s in enumerate(lst):
    if s.get("prefix") == rec["prefix"]:
        lst[i] = rec; break
else:
    lst.append(rec)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".subs.")
os.close(fd)
json.dump(d, open(tmp, "w"), indent=1, ensure_ascii=False)
os.replace(tmp, path)
PY
}

subs_del() {
    python3 - "$CLI_SUBS" "$1" <<'PY'
import json, os, sys, tempfile
path, pre = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["subscriptions"] = [s for s in d.get("subscriptions", []) if s.get("prefix") != pre]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".subs.")
os.close(fd)
json.dump(d, open(tmp, "w"), indent=1, ensure_ascii=False)
os.replace(tmp, path)
PY
}

svc_active() { systemctl is-active --quiet "$CLI_SERVICE" 2>/dev/null; }

cfg_check() {
    [[ -x "$CLI_BIN" ]] || { print_error "内核未安装"; return 1; }
    "$CLI_BIN" -t -d "$CLI_CONF" 2>&1 | tail -3
}

cfg_check_strict() {
    python3 "$CLI_LIB/validate.py" --conf "$CLI_CONF"
}

# 配置回滚。
#
# 这里原本两处都写 `[[ -f "$bak" ]] && cp -f "$bak" ...`, 而 $bak 是
# mktemp 建的 —— **它一定存在**。所以"原配置不存在"时, 回滚会把那个
# 0 字节的空文件覆盖上去, 比回滚前更糟:
#   * 下次生成前若有分支判 `-f config.yaml`, 会误以为"已经有配置了"
#   * 内核直接报 configuration file ... is empty
# 实测就是这么来的: 全新客户端第一次生成 -> 内核校验失败 -> 回滚 ->
# config.yaml 变成空文件, 之后每次 -t 都失败。
#
# 正确做法是记住"到底备份没备份过", 没备份过就**删掉**这次写坏的配置。
_cfg_rollback() {   # <备份文件> <是否有备份: 0/1>
    local bak="${1:-}" had="${2:-0}"
    if [[ "$had" -eq 1 && -n "$bak" && -f "$bak" ]]; then
        cp -f "$bak" "$CLI_CONF/config.yaml"
        print_info "已恢复到上一个可用配置"
    else
        rm -f "$CLI_CONF/config.yaml"
        print_warn "本次生成前没有可用配置, 已清除这次写坏的 config.yaml"
    fi
    [[ -n "$bak" ]] && rm -f "$bak"
    return 0
}

# 写配置 → 严格校验 → 内核校验 → 才重启; 任一步失败则回滚
apply_change() {
    # 只有真的存在旧配置时才建备份文件 —— 否则 mktemp 会留下一个空文件,
    # 让回滚误以为"有东西可恢复"。
    local bak="" had_bak=0
    if [[ -f "$CLI_CONF/config.yaml" ]]; then
        bak=$(mktemp) && cp -f "$CLI_CONF/config.yaml" "$bak" && had_bak=1
    fi

    if ! gen_config; then _cfg_rollback "$bak" "$had_bak"; return 1; fi
    if ! cfg_check_strict >/tmp/cfgstrict.log 2>&1; then
        cat /tmp/cfgstrict.log >&2
        print_error "严格字段校验未通过, 已回滚"
        _cfg_rollback "$bak" "$had_bak"; return 1
    fi
    if ! "$CLI_BIN" -t -d "$CLI_CONF" >/tmp/cfgcheck.log 2>&1; then
        tail -5 /tmp/cfgcheck.log >&2
        print_error "内核配置检查未通过, 已回滚"
        _cfg_rollback "$bak" "$had_bak"; return 1
    fi

    if svc_active; then
        systemctl restart "$CLI_SERVICE" && print_ok "已应用并重启" || print_warn "重启失败(配置已通过校验)"
    else
        print_ok "配置已生成并通过全部校验 (服务未运行, 启动后生效)"
    fi
    rm -f "$bak"
}

# =============================================================
# 主配置生成 —— 全量重建, 保证「providers 目录 = 配置里的 provider」
# =============================================================
gen_config() {
    ensure_dirs
    # 首次生成配置前先把端口定死。
    #
    # 之前只在 save_settings 里写默认值 7890/9090, 而"值是不是可用"
    # 从来没人查过 —— 撞了就是内核起不来, 面板却显示"运行中"
    # (实测: 同机另一个项目的 mihomo 占着 7890/9090)。
    # 这里在写配置前探一次, 冲突就顺延并写进 settings.env。
    if [[ ! -f "$CLI_SETTINGS" ]]; then
        m_resolve_ports "$PORT_MIXED" "$PORT_CTRL" "" >/dev/null
        PORT_MIXED="$M_PORT_MIXED"
        PORT_CTRL="$M_PORT_CTRL"
        save_settings
    fi
    local secret_file="$CLI_ROOT/.secret"
    [[ -f "$secret_file" ]] || gen_secret > "$secret_file"
    chmod 600 "$secret_file"
    # 注意: 传给 python 的必须是密钥**内容**, 不是文件路径
    local secret; secret=$(cat "$secret_file")

    # 把 provider 列表交给 python 处理; 每个 provider 附带它的刷新方式
    local spec=""
    local f name rec kind url
    for f in $(node_files); do
        name=$(basename "$f" .yaml)
        kind="file"; url=""
        rec=$(subs_get "$name")
        if [[ -n "$rec" ]]; then
            # rec 已在变量里, 直接模式匹配 —— 不为了一个子串匹配去开管道。
            if [[ "$rec" == *http-auto* ]]; then kind="http-auto"; fi
            url=$(printf '%s' "$rec" | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("url",""))
except Exception: print("")' 2>/dev/null)
        fi
        # URL 里含 : 和 /, 不能用 name:kind:url 三段切分 —— 改用 \x1f 分隔。
        spec+="$name"$'\x1f'"$kind"$'\x1f'"$url"$'\n'
    done

    python3 - "$CLI_CONF/config.yaml" "$spec" "$PORT_MIXED" "$PORT_CTRL" \
             "$BIND_ADDR" "$CLI_CONF/ui" "$secret" "${GEO_AUTO_UPDATE:-0}" \
             "$CLI_SUBS" <<'PYGEN'
import sys, os, yaml

out, spec, p_mixed, p_ctrl, bind, ui, secret, AUTO_GEO_UPDATE, SUBS_FILE = sys.argv[1:10]

SEP = "\x1f"
providers, names = {}, []
for line in spec.splitlines():
    line = line.rstrip("\n")
    if not line.strip():
        continue
    parts = (line.split(SEP) + ["", "", ""])[:3]
    name, kind, url = parts[0], parts[1], parts[2]
    if not name:
        continue
    names.append(name)
    if kind == "http-auto" and url:
        # type: http 必须带 url —— path 只是本地缓存位置, 没有 url 内核无从拉取。
        # 这个分支之前从没被走到 (写入侧写的是 http-oneshot), 所以 url 缺失
        # 一直没暴露。现在读侧认 http-auto 了, 必须补上。
        entry = {"type": "http", "url": url, "path": f"./providers/{name}.yaml",
                 "interval": 600}
    else:
        # type 必须显式给出: 缺字段时 mihomo -t 不报错, 但运行期直接 fatal
        entry = {"type": "file", "path": f"./providers/{name}.yaml"}
    entry["health-check"] = {"enable": True, "url": "http://www.gstatic.com/generate_204",
                             "interval": 300, "timeout": 5000}
    providers[name] = entry

# ---- 策略组结构 ----
#
# 一条订阅一个组, 最外层的 PROXY (面板里的"手动选择") **只放组**, 组里才是节点。
#
# 原来 PROXY 写的是 `use: names`, 内核会把每个 provider 的节点全部摊平进
# PROXY —— 30 个节点就得点 30 层才找得到自己要的那个, 而且和"自动选择"
# 混在一起。SB 的做法是 PROXY 只放组 (client.sh: "PROXY 只放组, 组里才是那条
# 订阅的节点"), 嵌套 selector 内核 check 通过。
#
# 一条订阅都没登记时 (节点全是手动加的简易 HTTP/SOCKS) 保持平铺 —— 这时本来
# 就没有"订阅"这个概念可分组, 硬套一层反而多绕。
def _sub_names():
    # 读 subscriptions.json 拿可读组名。不能用 subs_get —— 那是 shell 函数,
    # 在这段 python 里根本不存在, 异常被吞掉后组名会静默回退成哈希前缀
    # (面板里显示成一串 45fe6c20..., 看不出是哪条订阅)。
    if not SUBS_FILE or not os.path.exists(SUBS_FILE):
        return {}
    try:
        d = json.load(open(SUBS_FILE, encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(d, dict):
        return {}
    return {s.get("prefix"): (s.get("name") or "").strip()
            for s in (d.get("subscriptions") or []) if isinstance(s, dict)}

def _grp_name(prefix, used):
    # 组名要可读且唯一: 同名会让内核拒绝启动 (组名撞节点名同理)
    label = _sub_names().get(prefix, "")
    if not label:
        label = prefix
    base = label
    i = 2
    while label in used:
        label = "%s-%d" % (base, i); i += 1
    used.add(label)
    return label

if not names:
    names = []
    groups = [{"name": "PROXY", "type": "select", "proxies": ["DIRECT"]}]
else:
    import os, json
    used = set()
    node_groups = []
    for n in names:
        g = _grp_name(n, used)
        node_groups.append({"name": g, "type": "select", "use": [n]})
    # 顶层只放组名 (不是 use:), 于是 PROXY 里看到的是几个组而不是几十个节点
    top = [g["name"] for g in node_groups]
    groups = node_groups + [
        {"name": "AUTO", "type": "url-test", "use": names,
         "url": "http://www.gstatic.com/generate_204", "interval": 300,
         "tolerance": 50, "max-failed-times": 3},
        {"name": "PROXY", "type": "select", "proxies": ["AUTO"] + top},
    ]

# 回环判定要认全: 127.0.0.1 / ::1 / localhost 都是"只有本机"
lan = bind not in ("127.0.0.1", "::1", "localhost")


def hp(host, port):
    """拼 host:port。IPv6 字面量必须加方括号, 否则 ':::9090' 无法解析。"""
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"

# geodata 必须按实际拥有的文件来定:
#   * geodata-mode: true  → 需要 GeoIP.dat / GeoSite.dat
#   * 默认 (metadb)      → 需要 geoip.metadb / geosite.metadb
# 机器上不一定有这些文件, 也可能没有 GitHub 访问权限去下载。
# 缺了就退化成不依赖 geo 库的规则, 保证配置永远能加载。
confdir = os.path.dirname(os.path.abspath(out))
def has(*names):
    return any(os.path.isfile(os.path.join(confdir, n)) for n in names)

geoip_ok  = has("geoip.metadb", "GeoIP.dat")
geosite_ok = has("geosite.metadb", "GeoSite.dat")
# geodata-mode 一旦开启, GeoIP.dat 和 GeoSite.dat **两份都要**,
# 只有其中一份会让内核去找另一份并触发下载 —— 在访问不了 GitHub 的机器上
# 直接卡住启动。这里必须两个都存在才开。
use_geodata = has("GeoIP.dat") and has("GeoSite.dat")

# 内网直连: 不依赖任何 geo 库, 任何机器都能用
rules = ["IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
         "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
         "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
         "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
         "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve"]
# 有哪份库就用哪份规则 —— 只有 geoip.metadb 时照样能用 GEOIP 规则
if geosite_ok:
    rules += ["GEOSITE,private,DIRECT", "GEOSITE,cn,DIRECT"]
else:
    print("[WARN] 缺少 geosite 数据, 已跳过 GEOSITE 规则", file=sys.stderr)
if geoip_ok:
    rules += ["GEOIP,private,DIRECT,no-resolve", "GEOIP,CN,DIRECT,no-resolve"]
else:
    print("[WARN] 缺少 geoip 数据, 已跳过 GEOIP 规则", file=sys.stderr)
rules.append("MATCH,PROXY")

# DNS 策略也必须按"手上有没有 geosite"来定 —— 这里原先写死了
#     geosite:cn,private / geosite:category-ads-all
#
# 上面 rules 那边很小心的判了 geosite_ok 并跳过 GEOSITE 规则, 注释还写着
# "保证配置永远能加载"; 但**真正会触发下载 GeoSite.dat 的恰恰是这里**:
# nameserver-policy 的 geosite: 键会让内核去加载 geosite 数据。
#
# 实测 (全新客户端, 机器访问不了 GitHub):
#     [WARN] 缺少 geosite 数据, 已跳过 GEOSITE 规则      <- rules 判对了
#     level=error msg="Can't find GeoSite.dat, start download"
#     level=error msg="can't download GeoSite.dat: context deadline exceeded"
#     configuration file .../config.yaml test failed      <- 配置还是加载不了
# 然后触发回滚, 首次安装直接失败。
#
# 没有 geosite 时用域名后缀兜底: +.cn 覆盖国内域名, 不依赖任何 geo 库。
ns_policy = {}
if geosite_ok:
    ns_policy["geosite:cn,private"] = ["https://dns.alidns.com/dns-query"]
    # 广告在 DNS 层直接拒, 不让它离开本机。
    # 路由层也有一份, 双层消费 (与 SB 的做法一致)。
    ns_policy["geosite:category-ads-all"] = ["rcode://success"]
else:
    ns_policy["+.cn"] = ["https://dns.alidns.com/dns-query"]

cfg = {
    "mixed-port": int(p_mixed),
    "allow-lan": lan,
    # 通配才写 "*"; **具体 IP 必须原样写下去**。
    #
    # 原来是 `"*" if lan else bind` —— 而 lan 只判了"不等于 127.0.0.1", 于是
    # 用户填 192.168.1.5 会被悄悄扩成 "*", 变成监听所有网卡。用户以为收窄了,
    # 实际放宽了 —— 安全语义反了, 而且界面上完全看不出来。
    "bind-address": "*" if bind in ("0.0.0.0", "::", "*") else bind,
    "mode": "rule",
    "log-level": "info",
    "ipv6": True,
    "unified-delay": True,
    "tcp-concurrent": True,
    "find-process-mode": "strict",
    "external-controller": hp(bind, p_ctrl),
    "secret": secret,
    "external-ui": "ui",
    "profile": {"store-selected": True, "store-fake-ip": True},
    "dns": {
        "enable": True,
        # 跟随 BIND_ADDR, 不要硬编码 0.0.0.0。
        #
        # 实测问题: 同一进程里代理口听 127.0.0.1:<协商端口>,
        # DNS 口却听 0.0.0.0:1053 —— 与上面 allow-lan=false 自相矛盾。
        # 后果是本机成了一个开放解析器: 局域网任何人都能拿它查询,
        # 而这些查询**不经过代理**, 等于白送一份 DNS 反射面。
        "listen": hp(bind, 1053),
        # 关掉 AAAA 记录。
        #
        # 实测问题: 开着 ipv6 时内核会返回真实 IPv6 地址,
        # 而客户端有活的 2409:8a20::/64 (运营商段) 和默认 v6 路由 —— 那些流量
        # 根本没进 mihomo, 直接走 IPv6 出去了。同机两个解析器两个答案:
        #   getent ahosts example.com  → 2606:4700:... (真实 v6, 走了运营商)
        #   dig @127.0.0.1 -p 1053     → 198.18.0.4      (fake-ip)
        # 客户端面板不跑 TUN 也没有 IPv6 路由表, 给不出可用出口, 索性不给 AAAA。
        # 需要 IPv6 的场景应显式开启 TUN 模式并确认回源链路。
        "ipv6": False,
        "enhanced-mode": "fake-ip",
        "fake-ip-range": "198.18.0.1/16",
        # 这些域名拿到 fake-ip 会坏掉, 必须走真实解析。
        # 缺了它们的表现很隐蔽: QUIC/STUN 打洞失败、NTP 校时卡住、
        # iCloud 中继连不上 —— 用户往往先去关 fake-ip, 反而引入真泄露。
        "fake-ip-filter": [
            "*.lan", "localhost", "*.local", "+.msftconnecttest.com",
            "+.stun.*", "+.stun.*.*", "time.*", "+.pool.ntp.org",
            "+.apple.com", "+.icloud.com", "+.icloud-content.com",
            "+.market.xiaomi.com",
        ],
        # 服务器 IP 域名要用明文 DNS 解出来 —— 这一步必须在代理之外,
        # 否则第一次启动时还没有可用的代理链路。
        "default-nameserver": ["223.5.5.5", "119.29.29.29"],
        # 主解析: 全部加密, **直连**, 不带 #PROXY。
        #
        # ★ 之前这里加了 #PROXY (走代理解析), 结果 ECH 全军覆没。
        #   加 #PROXY 之后, 解析一个域名要先连上代理 —— 而代理节点的地址
        #   本身是域名, 又要解析, 于是形成循环依赖。mihomo 遇到这个死锁
        #   不会报错, 只是把这条查询静默丢掉。
        #   后果是 **HTTPS/SVCB 记录(type 65)一条都问不到**, 而 ECH 的
        #   ECHConfig 就装在这条记录里 —— 于是 ECH 静默失效: 面板照常
        #   显示节点, 只是连不上。
        #
        #   实测: 客户端 DNS 查 type 65 返回 0 字节, 换成不带 #PROXY 的
        #   DoH 之后 ECH 立刻恢复 (mTrojan04-CDN-WS 1258ms,
        #   mVLESS04-CDN-WS 967ms)。
        #
        # 泄露面并没有变大: 这两个是国内 DoH, 本来就直接可达; 走不走代理
        # 都是发给他们, 只是多绕一跳自己的代理。
        "nameserver": ["https://dns.alidns.com/dns-query",
                       "https://doh.pub/dns-query"],
        # 解析代理服务器自身域名: 必须直连, 否则死循环。
        "proxy-server-nameserver": ["https://dns.alidns.com/dns-query"],
        # ★ 不设 fallback / fallback-filter, 因为它会让 ECH 整体失效。
        #
        # 实测 (同一批带 ech-opts 的 CDN 节点, 同一台客户端, 只差这一段):
        #     无 fallback-filter   7 / 7 可用
        #     有 fallback-filter   0 / 7 可用, 且日志里**一次 HTTPS 查询都没发**
        #
        # 机制: 走 CDN 的域名解析出来是 Cloudflare 的境外 IP, geoip 判定为
        # 非 CN, 于是这条域名的查询改走 fallback 组 (1.0.0.1 / dns.google)。
        # 这两个在国内不可达, 查询超时被丢弃 —— 丢的不只是 A 记录,
        # **HTTPS/SVCB 记录 (type 65) 一条也没要到**, 而 Cloudflare 的
        # ECHConfig 正装在那条记录里。ECH 于是静默失效: 面板照常显示节点,
        # 只是连不上, 没有任何报错指向 DNS。
        #
        # 换成国内 DoH 也没用 —— 只要 fallback-filter 开着就会重路由,
        # 所以这是有/无的区别, 不是解析器选谁的区别。
        #
        # 代价: 少了 fallback 分流, 全部交给国内 DoH。对国内使用没有实际
        # 损失 (国内域名本来就该走国内 DNS), 而且省掉了"一个域名发 4 家"。
        # 要恢复 fallback 分流, 前提是接受 ECH 失效, 或换成能回答 type 65
        # 的境外解析器。
        # respect-rules: DNS 连接本身受 rules 约束。
        #
        # 不设时默认为 false —— 这意味着 DNS 出站**不受路由规则影响**,
        # 写 rules: MATCH,PROXY 对 DNS 毫无作用, 加密 DNS 实际是直连出去的。
        #
        # ⚠ 但它和 ECH 是一对矛盾: 域名解析走代理, 而代理节点的地址本身
        #   也是域名 → 解析要先连代理、连代理又要解析。mihomo 遇到这个
        #   循环不报错, 只是把查询静默丢掉, 于是 type 65 又问不到了。
        #   所以这里设为 False —— 国内 DoH 本来就直接可达, 走不走代理都是
        #   发给他们, 少绕一跳自己的代理反而更快。
        "respect-rules": False,
        "nameserver-policy": ns_policy,
    },
    "sniffer": {
        "enable": True, "override-destination": True,
        "force-dns-mapping": True, "parse-pure-ip": True,
        "sniff": {"HTTP": {"ports": [80, "8080-8880"]}, "TLS": {"ports": [443, 8443]}},
    },
    "proxy-providers": providers,
    "proxy-groups": groups,
    "rules": rules,
}

# geodata-mode 只在 .dat 齐全时开启; geo-auto-update 需要能访问 GitHub,
# 默认关闭, 用户可在设置里开。
if use_geodata:
    cfg["geodata-mode"] = True
if AUTO_GEO_UPDATE == "1":
    cfg["geo-auto-update"] = True
    cfg["geo-update-interval"] = 24
with open(out, "w", encoding="utf-8") as fh:
    fh.write("# 由 client.sh 自动生成, 请勿手工编辑\n")
    fh.write("# 节点来自 conf/providers/, 每个文件一个 provider\n\n")
    yaml.safe_dump(cfg, fh, sort_keys=False, allow_unicode=True, default_flow_style=False)
print(f"[OK] 生成 {out} ({len(names)} 个 provider)", file=sys.stderr)
PYGEN
}

# =============================================================
# 节点导入
# =============================================================
_add_from_file() {  # <文件> <名字>  —— 校验后落盘
    local src="$1" name="$2"
    # 第 3 个参数传 validate.py 的目录: 这段 python 是从 **stdin** 读的,
    # __file__ 不存在, 只能由调用方给路径。
    python3 - "$src" "$CLI_PROVIDERS/$name.yaml" "$CLI_LIB" <<'PYIMP'
import sys, yaml, os, tempfile
src, dst = sys.argv[1], sys.argv[2]
_mlib = sys.argv[3] if len(sys.argv) > 3 else ""
d = yaml.safe_load(open(src, encoding="utf-8"))
if not isinstance(d, dict) or not isinstance(d.get("proxies"), list) or not d["proxies"]:
    print("[ERR] 不是合法的 Mihomo 订阅 (需要顶层 proxies: 列表)", file=sys.stderr)
    sys.exit(1)

# ---- 剔除 mihomo 核心不认识的节点 (2026-10-07 新增) ----
#
# 为什么不直接照单全收:
#   之前的校验只要求每个节点有 name/type/server/port, 于是**任何** type 都能
#   被写进 provider。mihomo 核心遇到不认识的协议类型不会报错, 只是把这个
#   节点**静默丢弃** —— 用户看到的是"订阅里有这个节点, 但怎么都连不上",
#   没有任何一条错误指向真正的原因。
#
#   典型来源: 从 sing-box 内核那边导出的订阅。sing-box 的 outbound 类型
#   (naive / remote / fakeip / mixed / block …) 与 mihomo 的 proxy 类型
#   不是一套命名, 直接导入会带进来一堆死节点。
#
# 判据从哪来: **validate.py 自己的 PROXY 表**, 不另抄一份清单 ——
#   抄一份就等于两份真源, 以后加了新协议这里必然忘记同步, 于是过滤会
#   把**合法的**节点也剔掉, 比不过滤还糟。
sys.path.insert(0, _mlib)
_mihomo_types = None
try:
    import validate as _v
    _mihomo_types = set(_v.PROXY_TYPES)
except Exception as _e:
    print(f"[WARN] 读不到内核协议表 ({_e}), 跳过协议过滤", file=sys.stderr)

# ★ 原来这里是**硬失败**: 只要有任一节点缺 server/port 就整体退出。
#   问题是外部订阅里混几个"根本不是代理"的东西太正常了 —— sing-box 的
#   block/dns/selector 这类 outbound 本来就没有 server/port, 它们是配置
#   结构的一部分, 不是节点。结果一份 90% 能用的订阅会因为 4 个附带条目
#   整个导不进来。现在两类问题都只是**剔除**, 只有"一个都不剩"才报错。
kept, dropped, malformed = [], [], []
for p in d["proxies"]:
    if (not isinstance(p, dict) or not p.get("name") or not p.get("type")
            or "server" not in p or "port" not in p):
        malformed.append(p.get("name", "(无名)") if isinstance(p, dict) else "(格式错误)")
        continue
    t = str(p.get("type", "")).lower()
    if _mihomo_types and t not in _mihomo_types:
        dropped.append((p.get("name", "?"), t))
    else:
        kept.append(p)

if malformed:
    show = ", ".join(malformed[:5]) + (f" 等 {len(malformed)} 个" if len(malformed) > 5 else "")
    print(f"[过滤] 不是合法代理条目 (缺 name/type/server/port), 已剔除 {len(malformed)} 个 —— {show}",
          file=sys.stderr)
if dropped:
    # 按类型汇总, 避免 30 个节点刷 30 行
    by_t = {}
    for nm, t in dropped:
        by_t.setdefault(t, []).append(nm)
    for t, names in sorted(by_t.items()):
        show = ", ".join(names[:3]) + (f" 等 {len(names)} 个" if len(names) > 3 else "")
        print(f"[过滤] {t}: mihomo 核心不支持该协议, 已剔除 {len(names)} 个 —— {show}",
              file=sys.stderr)
if not kept:
    print("[ERR] 剔除后一个可用节点都不剩 —— 这份订阅与 mihomo 不兼容", file=sys.stderr)
    sys.exit(1)
d["proxies"] = kept
os.makedirs(os.path.dirname(dst), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst), prefix=".p.")
os.close(fd)
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(f"# 导入于 {__import__('datetime').datetime.now().isoformat(timespec='seconds')}\n")
    # 按 type 剔除内核不认的字段 (见 validate.strip_unknown 的说明)。
    # 内核对不认识的键是**静默忽略**, 所以这一步不是洁癖: 少了它,
    # username 这类只对 socks5/http 合法、却几乎在每份订阅里都带的字段
    # 会一路写进 provider, 用户看到的是"配了没反应"且无任何报错指向它。
    _dropped = 0
    _ps = []
    for _p in d["proxies"]:
        _p2, _dd = _v.strip_unknown(_p)
        _dropped += len(_dd)
        _ps.append(_p2)
    if _dropped:
        print("[Info] 已剔除 %d 个内核不认的字段" % _dropped)
    yaml.safe_dump({"proxies": _ps}, fh, sort_keys=False,
                   allow_unicode=True, default_flow_style=False)
os.replace(tmp, dst)
print(f"[OK] 已写入 {dst} ({len(d['proxies'])} 个节点"
      + (f", 已剔除 {len(dropped) + len(malformed)} 个不兼容" if (dropped or malformed) else "")
      + ")", file=sys.stderr)
PYIMP
}

node_add() {
    print_title "添加节点"
    ensure_dirs
    printf '\n输入分享链接或订阅地址 (http://...), 或本地文件路径:\n请输入: '
    local src; read -r src
    [[ -n "$src" ]] || { print_info "已取消"; return; }

    local tmp; tmp=$(mktemp -d)
    local body="$tmp/sub.yaml"

    if [[ "$src" == http://* || "$src" == https://* ]]; then
        # 走下载通道的 sub 作用域 —— 这正是"到服务器拉配置"那条路。
        #
        # 之前是裸 curl, 完全不走代理 —— 而「下载通道」菜单里明明有这个开关,
        # 设了却没人读 (见 dl_route.sh 头部说明)。
        local _px; _px=$(dl_route_resolve sub "$(dl_mixed_port)")
        print_info "正在拉取...${_px:+ (经 $_px)}"
        local code
        code=$(dl_curl_code "$src" "$body" sub)
        case "$code" in
            200) ;;
            404) print_error "链接不存在"; rm -rf "$tmp"; return 1 ;;
            410) print_error "链接已失效 (用尽 / 过期 / 已禁用)"; rm -rf "$tmp"; return 1 ;;
            503) print_error "服务端暂时不可用 (未消耗次数)"; rm -rf "$tmp"; return 1 ;;
            000|"")
                print_error "连不上订阅服务器${_px:+ (经 $_px)}"
                print_info "去「13) 下载通道 → 3) 订阅拉取单独设置」换直连试试"
                rm -rf "$tmp"; return 1 ;;
            *)   print_error "拉取失败 HTTP $code"; rm -rf "$tmp"; return 1 ;;
        esac
    elif [[ -f "$src" ]]; then
        cp -f "$src" "$body"
    else
        print_error "无法识别的来源"; rm -rf "$tmp"; return 1
    fi

    local name; name=$(printf '%s' "${src##*/}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
    [[ -z "$name" || "$name" == "share" ]] && name="sub$(date +%H%M%S)"

    # ⚠ 重名处理原先是**自动加 _1 / _2**, 用户根本不知道 sub_mixed_yaml 和
    #   sub_mixed_yaml_1 分别是哪两台服务器 —— 这是在掩盖问题, 不是在解决问题
    #   同理, 对标实现的注释里也是这个结论。两台服务器同名是**常态**, 不是异常。
    # 现在让用户自己起名, 并把已有的组列出来当提示; 一路回车才退回自动名。
    if [[ -f "$CLI_PROVIDERS/$name.yaml" ]]; then
        print_warn "已经有同名的组: $name"
        printf '  现有组:\n' >&2
        local _pf
        for _pf in "$CLI_PROVIDERS"/*.yaml; do
            [[ -f "$_pf" ]] || continue
            printf '    - %s\n' "$(basename "$_pf" .yaml)" >&2
        done
        printf '  新组叫什么? (两台服务器同名时建议用地区/线路区分, 如 美国RN / 香港备用): ' >&2
        local _nn; read -r _nn || _nn=""
        _nn=${_nn// /}
        if [[ -n "$_nn" ]] && ! printf '%s' "$_nn" | grep -q '[/\\:*?"<>|[:space:]]'; then
            if [[ -f "$CLI_PROVIDERS/$_nn.yaml" ]]; then
                print_error "已经有这个组了: $_nn"; rm -rf "$tmp"; return 1
            fi
            name="$_nn"
        else
            local _n=1 _base="$name"
            # ★ 这里原来是 `name="${_base}_$n"` —— 变量名写错了一个下划线:
            #   local 声明的是 _n, 引用的却是 $n。set -u 下直接
            #   "n: unbound variable" 中断, 于是**重复导入同一个订阅**会失败,
            #   而这段代码的本意正是"同名时自动改叫 xxx_1"。
            while [[ -f "$CLI_PROVIDERS/$name.yaml" ]]; do name="${_base}_$_n"; _n=$((_n+1)); done
        fi
        print_ok "新组名: $name"
    fi

    if ! _add_from_file "$body" "$name"; then rm -rf "$tmp"; return 1; fi
    printf '%s\n' "$src" > "$CLI_NODES/$name.txt"
    if [[ "$src" == http://* || "$src" == https://* ]]; then
        # 自动刷新必须在这里问清楚。
        #
        # 之前写死 kind="http-oneshot", 而配置生成侧 (client.sh:189) 只认
        # "http-auto" —— 两边对不上, 结果是: 通过面板导入的订阅**永远不会**
        # 走 type: http + interval 分支, 只能靠「更新配置」手动拉。
        # 读侧的分支代码一直存在, 看上去像支持了, 实际永远到不了。
        #
        # 对照 SB: 它也是纯手动更新 (client.sh 的 update_node 遍历来源 URL
        # 重拉), 没有 interval 自动刷新。所以自动刷新是 Mihomo 侧多出来的
        # 能力, 得真正能用。
        local kind="http-oneshot"
        printf '\n是否让内核自动定时更新这个订阅?\n'
        printf "    1) 自动更新 (每 10 分钟)\n"
        printf "    2) 手动更新 (只在选「更新配置」时拉取, 推荐)\n"
        printf "请选择 [2]: "
        local a; read -r a
        # 默认手动。自动更新每 10 分钟就发一次请求, 对一次性令牌是**直接把它
        # 拉废** —— 额度用掉之后订阅里就再也拿不到新节点了, 而界面只显示一个
        # 空的 provider, 没有任何地方提示是额度耗尽。
        [[ "$a" == "1" ]] && kind="http-auto"

        # 组名: 自动取的名字多半是 IP 或哈希, 订阅一多就分不清谁是谁
        # (面板里显示成哈希前缀或一串地址就是这么来的)。先问一句, 回车才用
        # 自动名 —— 多一次输入换一个长期能认出来的名字, 划算。
        printf '\n这条订阅在面板里叫什么?\n'
        printf '    (回车 = 按地址自动命名)\n'
        printf '请输入: '
        local want; read -r want
        want=$(clean_input "${want:-}")
        # 组名会直接进 YAML 的 name 字段, 冒号等字符会让 mihomo -t 失败;
        # 引号和换行同样会让配置写坏。
        want="${want//$'"'\n'"'/ }"
        [[ "$want" == *:* ]] && want="${want//:/-}"
        want="${want//\"/}"
        want="${want//$'"'\\'"'/}"

        # 组名取来源标识: 分享链接的 host、本地文件名, 或按序号兜底。
        # 原来只存哈希前缀, 面板里那个组就显示成一串 45fe6c20..., 完全看不出
        # 是哪条订阅 —— 分组再漂亮, 名字是乱码也没法用。
        subs_put "$(python3 -c '
import json,sys,datetime,urllib.parse,os
prefix,url,kind=sys.argv[1],sys.argv[2],sys.argv[3]
label=""
if kind=="local" and url:
    label=os.path.basename(url)
else:
    h=urllib.parse.urlparse(url).hostname
    if h: label=h
if not label or label==prefix: label="订阅-"+prefix[:6]
print(json.dumps({"prefix":prefix,"url":url,"kind":kind,"name":label,
 "imported_at":datetime.datetime.now().isoformat(timespec="seconds")},
 ensure_ascii=False))' "$name" "$src" "$kind")"
        # 用户起的名字优先于自动名
        if [[ -n "$want" ]]; then
            subs_set_name "$name" "$want"
        fi
        # 组名同步到组内节点名 —— 多台服务器的订阅拉进同一个客户端时,
        # 否则两边节点名完全撞车, 面板和测速都分不清来源
        local _t; _t=$(node_tag_from_name "${want:-$name}")
        if [[ -n "$_t" ]]; then
            local _c; _c=$(node_prefix_names "$CLI_PROVIDERS/$name.yaml" "$_t")
            [[ "${_c:-0}" -gt 0 ]] && print_ok "已给 $_c 个节点加上前缀 [$_t-]"
        fi
        if [[ "$kind" == "http-auto" ]]; then
            print_ok "已设为自动更新, 需重新生成配置后生效"
        fi
    fi
    rm -rf "$tmp"
    apply_change
}

node_list() {
    print_title "已导入的节点"
    local f found=0
    for f in $(node_files); do
        local name; name=$(basename "$f" .yaml)
        local cnt; cnt=$(python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
if not isinstance(d, dict): d = {}
print(len(d.get('proxies') or []))" "$f" 2>/dev/null || echo "?")
        local src=""; [[ -f "$CLI_NODES/$name.txt" ]] && src=$(head -1 "$CLI_NODES/$name.txt")
        printf '  \033[1m%-20s\033[0m %s 个节点   来源: %s\n' "$name" "$cnt" "${src:-本地文件}"
        found=1
    done
    [[ $found -eq 0 ]] && print_info "还没有任何节点, 请先「添加节点」"
}

# 终端里中文占 2 列, 但 bash 的 %-Ns 按**字节**算 —— printf "%-40s" "美国RN"
# 实际只补了 36 个空格, 表会歪。宽度差 = (字节数 - 列数) / 2。
_disp_pad() { # <文本> <目标列宽>
    local t="$1" w="$2" bytes cols
    bytes=${#t}
    cols=$(printf '%s' "$t" | wc -m)
    local pad=$(( w - cols ))
    (( pad < 1 )) && pad=1
    printf '%s%*s' "$t" "$pad" ''
}

# 列出所有"订阅/组" (一个 provider 文件 = 一组节点)
_sub_groups() {
    local f
    for f in "$CLI_PROVIDERS"/*.yaml; do
        [[ -f "$f" ]] || continue
        local n c
        n=$(basename "$f" .yaml)
        c=$(python3 -c '
import yaml,sys
try: print(len(yaml.safe_load(open(sys.argv[1])).get("proxies") or []))
except Exception: print(0)' "$f" 2>/dev/null)
        printf '%s|%s\n' "$n" "${c:-0}"
    done
}

# 整组删除 / 重命名 —— 编号选择, 不用手打名字。
# 原先 node_delete 让用户手输组名, 而组名多半是订阅 token 或 URL 末段
# (f8eb3715… / sub_mixed_yaml), 谁记得住? 输错一个字就是"节点不存在"。
node_delete() {
    ensure_dirs
    print_title "删除节点 / 整组"
    local -a gn=() gc=()
    local line
    while IFS='|' read -r a b; do gn+=("$a"); gc+=("$b"); done < <(_sub_groups)
    if (( ${#gn[@]} == 0 )); then print_info "还没有任何节点组"; return 0; fi
    print_title "选择要删除的组 (整个组一起删)"
    local i
    for (( i=0; i<${#gn[@]}; i++ )); do
        printf '    %b%2d)%b %s %b(%s 个节点)%b\n' \
            "${CYAN:-}" "$((i+1))" "${RESET:-}" "$(_disp_pad "${gn[$i]}" 38)" \
            "${DIM:-}" "${gc[$i]}" "${RESET:-}" >&2
    done
    printf '  %b%s%b\n' "${DIM:-}" "(删一个组 = 删掉它带进来的全部节点)" "${RESET:-}" >&2
    local c; printf '  请选择 [回车取消]: ' >&2
    read -r c || return 0
    c=$(clean_input "$c")
    [[ -n "$c" ]] || { print_info "已取消"; return 0; }
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#gn[@]} )) \
        || { print_error "请输入 1-${#gn[@]} 之间的编号"; return 1; }
    local n="${gn[$((c-1))]}"
    # 二次确认: 这是**不可撤销**的整组删除, 而且会连带删掉订阅登记,
    # 下次更新订阅得重新填一遍 URL。
    printf '  确认删除 %b%s%b 及它的 %s 个节点? 输入 yes 确认: ' \
        "${YELLOW:-}" "$n" "${RESET:-}" "${gc[$((c-1))]}" >&2
    local ok; read -r ok || return 0
    [[ "$ok" == "yes" ]] || { print_info "已取消"; return 0; }
    rm -f "$CLI_PROVIDERS/$n.yaml" "$CLI_NODES/$n.txt"
    subs_del "$n"
    print_ok "已删除整组 $n"
    apply_change
}

node_rename() {
    ensure_dirs
    print_title "重命名节点组"
    local -a gn=()
    local line
    while IFS='|' read -r a b; do gn+=("$a"); done < <(_sub_groups)
    if (( ${#gn[@]} == 0 )); then print_info "还没有任何节点组"; return 0; fi
    local i
    for (( i=0; i<${#gn[@]}; i++ )); do
        printf '    %b%2d)%b %s\n' "${CYAN:-}" "$((i+1))" "${RESET:-}" "$(_disp_pad "${gn[$i]}" 38)" >&2
    done
    local c; printf '  选择要改名的组: ' >&2
    read -r c || return 0
    c=$(clean_input "$c")
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#gn[@]} )) \
        || { print_error "请输入有效编号"; return 1; }
    local old="${gn[$((c-1))]}"
    printf '  新名字 (会同时作为组名, 字母数字短横线): ' >&2
    local nn; read -r nn || return 0
    nn=$(clean_input "$nn")
    # 必须校验: 这个名字会变成 mihomo 的 proxy-group 名, 也是文件名
    # 拦的是**文件系统危险字符**, 不是非 ASCII。
    # 这个名字会当文件名用 ($CLI_PROVIDERS/$nn.yaml), 所以 / \ : * ? " < > |
    # 和空格必须挡住; 但中文是这台机器上最自然的命名方式 ("香港" / "备用线路"),
    # 一律拒绝等于把功能废掉一半。
    # ⚠ 不要用 [[ =~ ^[...一-龥...]$ ]] 来校验中文: 方括号里的多字节范围
    #   依赖 UTF-8 locale, 在没设 UTF-8 locale 的机器上整个字符类直接
    #   失效 —— 结果连纯 ASCII 的 "RN-US" 都被拒, 报错还写着"不能含空格",
    #   与实际原因毫无关系。改成用 grep 挑危险字符, 按字节处理, 与 locale 无关。
    if printf '%s' "$nn" | grep -q '[/\\:*?"<>|[:space:]]'; then
        print_error "名字里不能含 / \\ : * ? \" < > | 或空格"
        return 1
    fi
    [[ "$nn" == "." || "$nn" == ".." ]] \
        && { print_error "名字不能是 . 或 .."; return 1; }
    [[ "$nn" == "$old" ]] && { print_info "名字没变"; return 0; }
    [[ -f "$CLI_PROVIDERS/$nn.yaml" ]] && { print_error "已经有同名组了: $nn"; return 1; }
    mv "$CLI_PROVIDERS/$old.yaml" "$CLI_PROVIDERS/$nn.yaml"
    [[ -f "$CLI_NODES/$old.txt" ]] && mv "$CLI_NODES/$old.txt" "$CLI_NODES/$nn.txt"
    # 订阅登记表里记着来源 URL, 改组名不能让这条记录丢掉 ——
    # 否则下次「更新订阅」就找不到它, 等于把这条订阅弄丢了
    # ⚠ 只有当旧名字**确实**在订阅登记表里才改它。
    #   本地文件 / 分享链接导入的组没有登记记录, subs_get 返回空串;
    #   原先不判空直接 json.loads("") 就把 Python traceback 打在面板上 ——
    #   而重命名其实已经成功了, 用户看到的是"报错 + 成功"混在一起。
    local rec; rec=$(subs_get "$old")
    if [[ -n "$rec" ]]; then
        subs_put "$(python3 -c '
import json,sys,datetime
rec=json.loads(sys.argv[1])
rec["prefix"]=sys.argv[2]
rec["imported_at"]=datetime.datetime.now().isoformat(timespec="seconds")
print(json.dumps(rec,ensure_ascii=False))' "$rec" "$nn")"
        subs_del "$old"
    fi
    print_ok "已把 $old 改名为 $nn"
    apply_change
}

node_update() {
    print_title "更新订阅节点"
    ensure_dirs
    subs_file_init
    local rec pre url
    # 一次性把通道解析出来, 循环里复用 (resolve 每次都要读文件)
    local _px; _px=$(dl_route_resolve sub "$(dl_mixed_port)")
    while read -r pre url; do
        [[ -z "$pre" ]] && continue
        print_info "更新 $pre ...${_px:+ (经 $_px)}"
        # 先备份, 拉取成功才替换 —— 一次性链接失败时不能把现有节点弄丢
        local tmp; tmp=$(mktemp -d)
        local code
        code=$(dl_curl_code "$url" "$tmp/sub.yaml" sub)
        if [[ "$code" != "200" ]]; then
            if [[ "$code" == "000" || -z "$code" ]]; then
                print_warn "  跳过 $pre (连不上订阅服务器${_px:+ 经 $_px}), 保留原有节点"
            else
                print_warn "  跳过 $pre (HTTP $code), 保留原有节点"
            fi
            rm -rf "$tmp"; continue
        fi
        local bak=""; [[ -f "$CLI_PROVIDERS/$pre.yaml" ]] && bak=$(mktemp) && cp -f "$CLI_PROVIDERS/$pre.yaml" "$bak"
        if _add_from_file "$tmp/sub.yaml" "$pre"; then
            # 重新下载会覆盖掉之前加的前缀, 所以每次更新后都要重新应用。
            # 不补的话, 更新一次订阅就会让这组的节点名退回和别台机器撞车的状态
            # —— 而用户刚更新完, 不会再去怀疑名字又变了。
            local _t; _t=$(node_tag_from_name "$(subs_get "$pre" | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("name",""))
except Exception: print("")' 2>/dev/null)")
            [[ -n "$_t" ]] && node_prefix_names "$CLI_PROVIDERS/$pre.yaml" "$_t" >/dev/null
            print_ok "  $pre 已更新"
            [[ -n "$bak" ]] && rm -f "$bak"
        else
            print_warn "  $pre 更新失败, 已还原"
            [[ -n "$bak" ]] && cp -f "$bak" "$CLI_PROVIDERS/$pre.yaml" && rm -f "$bak"
        fi
        rm -rf "$tmp"
    done < <(python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit
for s in d.get('subscriptions',[]):
    print(s.get('prefix',''), s.get('url',''))" "$CLI_SUBS")
    apply_change
}

# =============================================================
# 状态 / 测试
# =============================================================
status_block() {
    local svc ver pid n
    pid=$(systemctl show -p MainPID --value "$CLI_SERVICE" 2>/dev/null) || pid=""
    [[ "$pid" == "0" ]] && pid=""
    n=$(node_count)
    ver="未安装"
    [[ -x "$CLI_BIN" ]] && ver=$("$CLI_BIN" -v 2>/dev/null | head -1 | awk '{print $3}')
    [[ -n "$ver" ]] || ver="未知"

    if svc_active; then
        svc="${GREEN}● 运行中${RESET}${pid:+ (PID $pid)}"
    else
        svc="${YELLOW}○ 未运行${RESET}"
    fi
    ui_kv "服务状态" "$svc"
    ui_kv "节点数量" "$n"
    ui_kv "内核版本" "$ver"

    # ---------- 本地代理 ----------
    echo >&2
    printf "  ${CYAN}本地代理${RESET}\n" >&2

    local eff_mixed eff_bind eff_ctrl
    eff_mixed=$(eff_cfg mixed-port)
    eff_bind=$(eff_cfg bind-address)
    eff_ctrl=$(eff_cfg external-controller)
    local from_conf=1
    [[ "$eff_mixed" =~ ^[0-9]+$ ]] || { eff_mixed="$PORT_MIXED"; from_conf=0; }
    [[ -n "$eff_bind" ]] || eff_bind="$BIND_ADDR"

    local ctrl_host="${eff_ctrl%:*}" ctrl_port="${eff_ctrl##*:}"
    [[ -n "$ctrl_host" ]] || ctrl_host="$eff_bind"
    [[ "$ctrl_port" =~ ^[0-9]+$ ]] || ctrl_port="$PORT_CTRL"

    # 0.0.0.0 / * 不是能连上的地址, 显示前解析成真实 LAN IP
    local show_bind; show_bind=$(host_addr "$eff_bind")

    if [[ "$eff_mixed" == "0" ]]; then
        # mixed-port: 0 = 内核**不监听**代理端口 (全新安装未生成配置的正常状态)
        ui_kv_i "代理端口" "${YELLOW}未启用${RESET} (先「1) 初始化基础配置」)"
    else
        # 标清这是 mixed-port: HTTP 与 SOCKS5 **共用这一个端口**, 不是两个端口。
        ui_kv_i "代理端口" "${show_bind}:${eff_mixed}  ${DIM}(HTTP + SOCKS5 共用)${RESET}"
    fi
    ui_kv_i "控制面板" "http://$(host_addr "$ctrl_host"):${ctrl_port}/ui/"

    # 面板密钥: 控制面板没密钥就等于局域网里任何设备都能改配置、换节点。
    # 显示在面板上是刻意的 —— 这台机器只自己在局域网内用。真正的防护是
    # bind-address 不对公网开放, 而不是把字符串藏起来。
    local sec; sec=$(cat "$CLI_ROOT/.secret" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$sec" ]]; then
        ui_kv_i "面板密钥" "$sec"
    else
        ui_kv_i "面板密钥" "${RED}未设置 — 局域网内任何设备都能改配置${RESET}"
    fi

    if (( from_conf )) && [[ "$eff_mixed" != "0" && "$eff_mixed" != "$PORT_MIXED" ]]; then
        print_info "面板设置端口 $PORT_MIXED, 但配置里写的是 $eff_mixed (改端口需重启)"
    elif (( ! from_conf )); then
        print_info "还没生成配置文件, 端口按面板设置显示 (先「1) 初始化基础配置」)"
    fi
}

# 读**实际生成的配置**里的一个顶层字段。config.yaml 是唯一事实来源。
# 读不到 (文件不存在 / 字段缺失 / 解析失败) 返回空, 由调用方决定怎么退。
eff_cfg() {
    [[ -s "$CLI_CONF/config.yaml" ]] || return 0
    python3 - "$CLI_CONF/config.yaml" "$1" <<'PYEFF' 2>/dev/null
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
v = d.get(sys.argv[2])
if v is None:
    sys.exit(0)
# bool 要还原成小写, 否则 Python 会打成 True/False
if isinstance(v, bool):
    print("true" if v else "false")
else:
    print(v)
PYEFF
}

api() { curl -s -m 8 -H "Authorization: Bearer $(cat "$CLI_ROOT/.secret" 2>/dev/null)" "http://$BIND_ADDR:$PORT_CTRL$1"; }

node_test() {
    print_title "节点测速"
    svc_active || { print_warn "服务未运行, 请先启动"; return 1; }
    # 连通性预检; 真正的取数在下面的 python 里 (要打 /proxies、
    # /providers/proxies、/group/<组>/delay 三个接口)。
    api /proxies > /tmp/proxies.json 2>/dev/null
    [[ -s /tmp/proxies.json ]] || { print_error "无法连接控制 API"; return 1; }
    python3 - "$CLI_ROOT/.secret" "$BIND_ADDR" "$PORT_CTRL" <<'PYTEST'
import json, sys, urllib.request, urllib.parse
secret = open(sys.argv[1]).read().strip()
base = f"http://{sys.argv[2]}:{sys.argv[3]}"
H = {"Authorization": "Bearer " + secret}
TEST = "http://www.gstatic.com/generate_204"


def get(path, timeout=15):
    return json.load(urllib.request.urlopen(
        urllib.request.Request(base + path, headers=H), timeout=timeout))


try:
    allp = get("/proxies").get("proxies") or {}
except Exception:
    print("[错误] 控制 API 返回异常"); sys.exit(1)

# 真实节点来自 provider —— /proxies 只含代理组与内置项 (DIRECT/REJECT/PASS...)
# 内置 provider 的名字固定是 "default", 里面装的是 DIRECT/REJECT/PROXY/AUTO
# 这些**不是节点**的东西; 组类型同理。两者都要排掉 —— 否则分母里混进 6 个
# 非节点项 (显示"可用 18/24"), 看起来像有一堆节点坏了。
BUILTIN = {"Direct", "Reject", "Selector", "URLTest", "Fallback",
           "LoadBalance", "Relay", "Compatible", "Pass", "PassRule",
           "RejectDrop"}
nodes = {}
try:
    prov = (get("/providers/proxies").get("providers") or {})
except Exception:
    prov = {}
for _pn, _pv in prov.items():
    if _pn == "default":
        continue
    for _x in (_pv.get("proxies") or []):
        if _x.get("name") and _x.get("type") not in BUILTIN:
            nodes[_x["name"]] = _x.get("type", "?")

GROUP_TYPES = ("Selector", "URLTest", "Fallback", "LoadBalance", "Relay")
groups = [n for n, v in allp.items()
          if v.get("type") in GROUP_TYPES and n != "GLOBAL"]

# ★ 单个 provider 节点的延迟**不能**用 /proxies/<name>/delay 测 —— 实测返回
#   404 {"message":"Resource not found"}; mihomo 也没有
#   /providers/proxies/<provider>/<node>/delay 这条路由 (404 page not found)。
#   一次能拿到全组每个节点延迟的是 /group/<组名>/delay, 它返回
#   {"节点名": 延迟, ...} 的映射, 而且是**当场实测**。
#   用错接口的表现就是: 每个节点都显示"失败", 但实际全都通。
delays = {}
for g in groups:
    try:
        r = get(f"/group/{urllib.parse.quote(g)}/delay"
                f"?timeout=8000&url={urllib.parse.quote(TEST)}", timeout=20)
        if isinstance(r, dict):
            for k, v in r.items():
                if isinstance(v, int) and v > 0:
                    delays[k] = v
    except Exception:
        pass

# 组没覆盖到 (或压根没有组) -> 退回 provider 的健康检查历史
if not delays:
    for _pn, _pv in prov.items():
        for _x in (_pv.get("proxies") or []):
            h = _x.get("history") or []
            if h and h[-1].get("delay"):
                delays[_x["name"]] = h[-1]["delay"]

rows = []
for name, t in nodes.items():
    if name in delays:
        rows.append((delays[name], name, t, True))
    else:
        rows.append((99999, name, t, False))

if not rows:
    print("\n  (没有可测速的节点 —— 先用「2) 添加节点」导入订阅)\n")
    sys.exit(0)

rows.sort(key=lambda r: (not r[3], r[0]))
print()
print(f"  {'延迟':>8}  {'类型':<14} 名称")
print("  " + "-" * 60)
for r in rows:
    dly = f"{r[0]}ms" if r[3] else "失败"
    print(f"  {dly:>8}  {r[2]:<14} {r[1]}")
ok = sum(1 for r in rows if r[3])
print(f"\n  可用 {ok}/{len(rows)}\n")
PYTEST
}

# =============================================================
# 菜单
# =============================================================
# =============================================================
# 客户端 DNS 管理
#
# 为什么要单独包一层, 而不是直接调 dns_menu:
#   dns.sh 里的读写走 $SRV_CONF / m_sync_reload / $SRV_SERVICE, 都是服务端的
#   名字。客户端的配置在 $CLI_CONF、服务叫 mihomo-client。这里把变量名对齐
#   再交给 dns_menu, 复用同一套菜单/预设/回滚逻辑, 不复制第二份。
#
# DNS_MODE=client 让 dns_menu 选客户端安全默认 (fake-ip + fake-ip-filter),
# 而不是服务端那套 normal 模式。
# =============================================================
client_dns_menu() {
    local _r="$SRV_ROOT" _c="$SRV_CONF" _s="$SRV_SERVICE"
    export SRV_ROOT="$CLI_ROOT" SRV_CONF="$CLI_CONF" SRV_SERVICE="$CLI_SERVICE"
    export DNS_MODE=client
    dns_menu
    unset DNS_MODE
    export SRV_ROOT="$_r" SRV_CONF="$_c" SRV_SERVICE="$_s"
}

client_menu() {
    local c
    while true; do
        ui_rule
        printf "  ${CYAN}${BOLD}Mihomo 客户端${RESET}\n" >&2
        ui_rule
        status_block
        echo >&2
        ui_sec "节点"
        ui_menu 1  "初始化基础配置"
        ui_menu 2  "添加节点 (分享链接 / 订阅 / 本地文件)"
        ui_menu 3  "添加简易 HTTP/SOCKS 节点 (接其它内核)"
        ui_menu 4  "查看节点"
        ui_menu 5  "更新订阅节点"
        ui_menu 6  "删除节点 / 整组"
        ui_menu 7  "重命名节点组"
        ui_menu 8  "节点测速"
        ui_menu 9  "域名分流 (域名 -> 节点/组)"
        echo >&2
        ui_sec "服务"
        ui_menu 10 "启动 / 停止 / 重启服务"
        ui_menu 11 "配置检查"
        ui_menu 12 "局域网配置分发 (URL 拉取)"
        ui_menu 13 "下载通道 (订阅/内核/UI 走不走代理)"
        echo >&2
        ui_sec "配置"
        ui_menu 14 "客户端设置 (端口 / 绑定 / Web UI / 面板密钥)"
        ui_menu 15 "Web UI / 仪表盘"
        ui_menu 16 "DNS 管理 (fake-ip / 防泄露 / 解析策略)"
        ui_menu 17 "安装 / 内核管理 (版本/更新/脚本)"
        ui_menu 18 "卸载客户端"
        ui_menu 19 "切换到服务端面板 (装/进另一端)"
        ui_menu 0  "退出"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || { printf '\n' >&2; print_info "非交互环境 (stdin 已关闭), 已退出"; break; }
        c=$(clean_input "$c")
        case "$c" in
            1)  apply_change ;;
            2)  node_add ;;
            3)  simple_add_menu ;;
            4)  node_list ;;
            5)  node_update ;;
            6)  node_delete ;;
            7)  node_rename ;;
            8)  node_test ;;
            9)  rules_menu ;;
            10) svc_menu ;;
            11) check_menu ;;
            12) lan_dispatch_menu ;;
            13) dl_route_menu ;;
            14) settings_menu ;;
            15) webui_menu ;;
            16) client_dns_menu ;;
            17) core_menu "$CLI_ROOT" "$CLI_SERVICE" ;;
            18|d|D) cli_uninstall ;;
            19) switch_side "$CLI_ROOT" ;;
            0|q|Q) exit 0 ;;
            *)  ui_invalid "$c" ;;
        esac
        pause
    done
}

# =============================================================
# 卸载客户端
#
# 服务端本来就有卸载, 客户端一直没有 —— 只能手动 rm -rf, 而安装路径
# 因人而定, 很多人根本不知道删哪。两种粒度:
#   1) 仅卸载服务  保留配置与节点
#   2) 彻底删除    本脚本在本机创建的全部内容
# 与服务端对齐, 并额外回收自己登记的防火墙端口 (见 .fw-ports)。
# =============================================================
cli_uninstall() {
    print_title "卸载 Mihomo 客户端"
    # 分享服务名与 install 时注册的保持一致, 不能各处各写一份
    local svc="$CLI_SERVICE" shsvc="mihomo-client-share"
    # 作用域校验: 安装目录被改到别处时 (CLI_ROOT 可被环境变量覆盖),
    # 这两个服务名可能属于**别的** mihomo 实例, 删 unit 就是误删。
    # 单元文件里记了安装路径, 对不上就只提示不动手。
    _cli_unit_owned_by_me "$svc" || { svc=""; print_warn "$svc 的 unit 不属于 $CLI_ROOT, 不会删除"; }
    _cli_unit_owned_by_me "$shsvc" || { shsvc=""; print_warn "$shsvc 的 unit 不属于 $CLI_ROOT, 不会删除"; }
    cat <<EOF
  1) 仅卸载服务     停服务+删 unit, 保留配置/节点
  2) 彻底删除       本脚本在本机创建的全部内容, 见下方清单

  当前安装目录: $CLI_ROOT
  服务: ${svc:-无} (本机)  分享服务: ${shsvc:-无} (本机)
EOF
    printf '\n请选择 [1-2, 回车取消]: '
    local mode; read -r mode
    case "$mode" in
        1) [[ -n "$svc" ]]   && _cli_uninstall_unit "$svc"
           [[ -n "$shsvc" ]] && _cli_uninstall_unit "$shsvc"
           print_info "配置与节点已保留在 $CLI_ROOT" ;;
        2) _cli_uninstall_all "$svc" "$shsvc" ;;
        "") print_info "已取消" ;;
        *)  ui_invalid "$c" ;;
    esac
}

# 该 systemd unit 是不是本安装目录的?
# unit 文件里写着 ExecStart=<CLI_ROOT>/mihomo, 对不上就不能碰 ——
# 否则 CLI_ROOT 被改过时, 卸载会删掉另一个 mihomo 实例的服务。
_cli_unit_owned_by_me() {
    local s="${1:-}" f
    # set -u 下 "$1" 未传会直接报错中断整个面板 —— 这类"内部工具函数"
    # 必须容错, 传空就当"不归我管"
    [[ -n "$s" ]] || return 1
    f="/etc/systemd/system/$s.service"
    [[ -f "$f" ]] || return 1
    grep -qF -- "$CLI_ROOT" "$f" 2>/dev/null || return 1
    return 0
}

_cli_uninstall_unit() {
    local s="$1"
    systemctl stop "$s" 2>/dev/null
    systemctl disable "$s" 2>/dev/null
    rm -f "/etc/systemd/system/$s.service"
    systemctl daemon-reload 2>/dev/null
    print_ok "服务已移除: $s"
}

_cli_uninstall_all() {
    local svc="$1" shsvc="$2"
    cat <<EOF

  即将【永久删除】以下内容 (不可恢复, 建议先备份):

    服务      : ${svc:-无}${svc:+, }${shsvc:-无} 的 systemd unit
    目录      : $CLI_ROOT
                ├─ mihomo            内核
                ├─ src/              面板脚本
                ├─ conf/             配置、providers、节点、密钥
                ├─ share/            分享服务与分享记录
                ├─ settings.env      端口等设置
                └─ .secret           面板密钥
    防火墙    : 只回收本程序登记在 .fw-ports 里的端口, 不动其它规则

  注意: 本机若还有别的 mihomo 实例 (例如另一个项目), 不要删它们的目录。

  确认彻底删除? 输入 DELETE 继续 (其它任何输入都取消):
EOF
    local a; read -r a
    [[ "$a" == "DELETE" ]] || { print_info "已取消, 未删除任何内容"; return; }

    # 传空串就跳过 —— cli_uninstall 已按 unit 归属做过校验
    [[ -n "$svc" ]]   && _cli_uninstall_unit "$svc"
    [[ -n "$shsvc" ]] && _cli_uninstall_unit "$shsvc"

    # 端口回收: 只按自己的登记表逐个走 fw_close_port。
    #
    # 原来这里是内联实现, 只认 ufw/firewalld/iptables 三家, 且**没有 SSH 保护** ——
    # 登记表里万一混进了 sshd 端口, 这段会直接把 SSH 规则删掉, 然后人就再也连不上了。
    # fw_close_port 三道闸门: 登记表 / sshd 实测监听 / 系统常用端口, 任何一道不过就不动防火墙。
    declare -F fw_close_port >/dev/null 2>&1 && {
        local _p _n=0 _fw="$CLI_ROOT/.fw-ports"
        if [[ -f "$_fw" ]]; then
            while IFS= read -r _p; do
                [[ "$_p" =~ ^[0-9]+$ ]] || continue
                fw_close_port "$_p" "卸载" && _n=$((_n + 1))
            done < "$_fw"
        fi
        print_ok "已回收登记的防火墙端口: $_n 个"
    }

    rm -rf "$CLI_ROOT"
    if [[ -e "$CLI_ROOT" ]]; then
        print_error "删除失败, 目录仍在: $CLI_ROOT"
        print_error "请检查权限 (是否有进程占用), 或手动执行: rm -rf $CLI_ROOT"
        return 1
    fi
    print_ok "已彻底删除: $CLI_ROOT"

    # 确认代理口确实释放
    # 先整体捕获再匹配 —— 管道式会因 grep -q 提前退出让 ss 收到 SIGPIPE (141),
    # 在 `set -euo pipefail` 下把"命中"误判为"失败", 于是这句警告永远不显示。
    if grep -qE ":${PORT_MIXED}[[:space:]]" <<<"$(ss -lntH 2>/dev/null || true)"; then
        print_warn "端口 $PORT_MIXED 仍在监听 —— 本机可能还有别的 mihomo 实例在使用它"
    fi
    return 0
}

svc_menu() {
    print_title "服务管理"
    # 与服务端的 svc_menu 保持同一套编号与项目 —— 两边不一致会让人换端后按错。
    # 手动上传内核放在这里 (而不是只藏在"配置检查"里), 是因为下载不通时用户
    # 第一个去的地方就是服务/内核相关菜单。
    ui_menu 1 "启动"
    ui_menu 2 "停止"
    ui_menu 3 "重启"
    ui_menu 4 "查看状态"
    ui_menu 5 "开机自启"
    ui_menu 6 "手动上传内核 (下载不通时用)"
    echo >&2
    printf "  ${CYAN}请选择${RESET}: "; local c; read -r c
    c=$(clean_input "$c")
    case "$c" in
        1) systemctl start "$CLI_SERVICE" && print_ok "已启动" ;;
        2) systemctl stop "$CLI_SERVICE" && print_ok "已停止" ;;
        3) systemctl restart "$CLI_SERVICE" && print_ok "已重启" ;;
        4) systemctl status "$CLI_SERVICE" --no-pager | head -12 ;;
        5) systemctl enable "$CLI_SERVICE" && print_ok "已设置开机自启" ;;
        6) kernel_upload_menu ;;
    esac
}

check_menu() {
    local c
    while true; do
        print_title "配置检查"
        # 这里原来是 `print_info "1) …"; cfg_check` —— 检查被写成了**打印菜单
        # 的一部分**, 于是"进入配置检查"这个动作本身就会立刻把内核检查和严格
        # 校验各跑一遍, 用户还没选就已经跑完了; 选完第 1 项再跑第二遍。
        # 表现为"菜单一显示, 检查就已经跑了两遍", 且第一遍的输出挤在菜单中间。
        # 菜单只负责列出选项, 检查必须在 case 分支里 —— 选哪项跑哪项。
        ui_menu 1 "内核检查 (mihomo -t)"
        ui_hint "只验语法与结构, 不检测端口冲突/占用 —— 那要看服务状态"
        ui_menu 2 "严格字段校验 (本项目 validate.py, 比内核更严)"
        ui_menu 3 "服务状态"
        ui_menu 4 "手动上传内核 (下载不通时用)"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || { printf '\n' >&2; print_info "非交互环境, 已退出"; return 0; }
        c=$(clean_input "$c")
        case "$c" in
            1) cfg_check ;;
            2) cfg_check_strict ;;
            3) systemctl status "$CLI_SERVICE" --no-pager | head -8 ;;
            4) kernel_upload_menu ;;
            0) return 0 ;;
            *) ui_invalid "$c"; continue ;;
        esac
        echo >&2
        printf "  ${DIM}按回车继续...${RESET}" >&2
        read -r _ || true
    done
}

# ---------- 手动上传内核 ----------
#
# 内核下载是整个安装/升级流程里唯一依赖外网的一步。实测
# GitHub 主站不通、5 个镜像只有 ghproxy.net 勉强能通但只有 11KB/s,
# 20.8MB 要 31 分钟。此时"自己下个包传上来"比继续折腾网络可靠得多。
#
# 认架构不靠猜文件名: 直接读 ELF 头的 e_machine 字段, 再真跑一次看它能否
# 自报版本。两个判据都过才算可用 —— 只看文件名的话, 一个 amd64 的包传到
# arm64 机器上会一路装完, 直到 systemctl start 才炸。
kernel_upload_menu() {
    print_title "手动上传内核"
    local kdir="${MIHOMO_KERNEL_DIR:-${CLI_ROOT%/*}/mihomo-kernels}"
    local want; want=$(kernel_want_arch)
    # printf 而非 cat <<EOF: heredoc 不解释 \033, 会把转义码当字面量打印出来
    printf "\n  把 mihomo 内核压缩包传到这台机器的:\n\n"
    printf "    \033[36m%s\033[0m\n" "$kdir"
    printf "\n  支持三种格式 (脚本都能认):\n"
    printf "    - .gz          mihomo-linux-%s-vX.Y.Z.gz   (GitHub 官方就是这种)\n" "$want"
    printf "    - .zip         里面套一层目录也没关系\n"
    printf "    - 裸二进制     直接就是 mihomo 这个文件\n"
    printf "\n  下载地址: https://github.com/MetaCubeX/mihomo/releases/latest\n"
    printf "\n  传完后选择操作:\n"
    printf "    1) 校验已上传的内核 (不动现有内核)\n"
    printf "    2) 用上传的内核重装并重启\n"
    printf "    0) 返回\n"
    printf "请选择: "; local c; read -r c
    case "$c" in
        1) kernel_verify "$kdir" ;;
        2) kernel_install "$kdir" ;;
    esac
}

# 本机需要的架构标识 (与 core_install.sh 保持一致)
kernel_want_arch() {
    [[ "$(uname -m)" == "x86_64" ]] && echo amd64 || echo arm64
}

# 从 ELF 头的 e_machine (第 18-19 字节) 读架构。
#   0x3e = x86-64   0xb7 = AArch64
kernel_arch_of() {
    local f="$1" m
    [[ -f "$f" ]] || { echo "?"; return; }
    m=$(od -An -tx1 -j18 -N2 "$f" 2>/dev/null | tr -d ' \n')
    case "$m" in
        3e00) echo amd64 ;;
        b700) echo arm64 ;;
        *)    echo "未知($m)" ;;
    esac
}

# 把上传的文件解出可执行内核, 并真的跑一下取版本号
kernel_probe() {   # $1=文件  $2=解包目标
    local f="$1" out="$2" inner
    case "${f,,}" in
        *.gz)
            gunzip -c "$f" > "$out" 2>/dev/null || return 1 ;;
        *.zip)
            command -v unzip >/dev/null || return 1
            inner=$(unzip -Z1 "$f" 2>/dev/null | grep -E '(^|/)mihomo$' | head -1)
            [[ -n "$inner" ]] || return 1
            unzip -p "$f" "$inner" > "$out" 2>/dev/null || return 1 ;;
        *)
            cp -f "$f" "$out" || return 1 ;;
    esac
    chmod +x "$out" 2>/dev/null
    [[ -s "$out" ]] || return 1
    # 真跑 —— 这是唯一可靠的判据。
    #
    # 必须**先整体捕获再匹配**, 不能写成 "$out" -v 2>/dev/null | grep -qi mihomo:
    # grep -q 一命中就退出, 上游 mihomo 写管道时收到 SIGPIPE (141), 而本脚本
    # 开头是 `set -euo pipefail`, 管道因此被判为失败。
    #
    # 致命的是这是竞态 —— 取决于内核把版本行写完的快慢, 同一台机器时灵时不灵。
    # 实测 上连跑 12 次, 管道式挂了 7 次 (全是 141), 捕获式 12/12。
    # 用户传了好端端的内核却被判成"不可用", 再传一次又"可用" —— 比一直坏更难查。
    _v="$("$out" -v 2>/dev/null)" || return 1
    [[ "$_v" =~ [Mm][Ii][Hh][Oo][Mm][Oo] ]] || return 1
    return 0
}

# 只校验, 不动现有内核
kernel_verify() {
    local kdir="$1"
    if [[ ! -d "$kdir" ]]; then
        print_error "目录不存在: $kdir"
        print_info "先执行: mkdir -p $kdir, 再把内核文件传进来"
        return 1
    fi
    # 直接输出, 不包 $(...)。同服务端的原因: print_* 走 stderr,
    # 用 $(...) 捕获 stdout 会让成功/失败提示与文件内容交错, 对不上号。
    local probe found="" any=0 base ver arch f
    shopt -s nullglob
    local files=("$kdir"/*)
    shopt -u nullglob

    if (( ${#files[@]} == 0 )); then
        print_error "目录里没有任何文件: $kdir"
        print_info "先 mkdir -p $kdir, 再把内核文件传进来"
        return 1
    fi

    probe=$(mktemp)
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.part ]] && continue
        any=1
        base=$(basename "$f")
        if ! kernel_probe "$f" "$probe"; then
            print_error "$base"
            printf "    不是可用的 mihomo 内核 (无法解压或无法执行)\n\n" >&2
            continue
        fi
        ver=$("$probe" -v 2>/dev/null | head -1)
        arch=$(kernel_arch_of "$probe")
        print_ok "$base"
        printf "    版本: %s\n" "$ver" >&2
        printf "    架构: %s\n" "$arch" >&2
        if [[ "$arch" == "$(kernel_want_arch)" ]]; then
            printf "    \033[32m✓ 与本机架构匹配\033[0m (%s)\n\n" "$(uname -m)" >&2
            found=1
        else
            printf "    \033[33m✗ 架构不匹配\033[0m 本机是 %s, 这个是 %s\n\n" \
                "$(uname -m)" "$arch" >&2
        fi
    done
    rm -f "$probe"

    (( any )) || { print_error "目录里没有可用的文件: $kdir"; return 1; }
    if [[ -z "$found" ]]; then
        print_error "没有找到与本机架构匹配的可执行内核"
        print_info "本机需要: linux-$(kernel_want_arch)"
        print_info "下载地址: https://github.com/MetaCubeX/mihomo/releases/latest"
        return 1
    fi
    print_ok "有可用内核, 可选择「2) 用上传的内核重装并重启」"
    return 0
}

# 用上传的内核重装并重启
kernel_install() {
    local kdir="$1"
    kernel_verify "$kdir" || return 1
    printf "确认用上传的内核重装? [y/N]: "; local a; read -r a
    [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; return; }

    [[ -f "$CLI_ROOT/src/core_install.sh" ]] || {
        print_error "缺少 src/core_install.sh, 无法重装"
        return 1
    }
    local backup="$CLI_ROOT/mihomo.bak.$(date +%Y%m%d-%H%M%S)"
    cp -f "$CLI_ROOT/mihomo" "$backup" 2>/dev/null \
        && print_ok "已备份当前内核: $(basename "$backup")"

    if bash "$CLI_ROOT/src/core_install.sh" \
           INSTALL_DIR="$CLI_ROOT" SERVICE_NAME="$CLI_SERVICE" \
           MIHOMO_KERNEL_DIR="$kdir" < /dev/null; then
        systemctl restart "$CLI_SERVICE" 2>/dev/null
        print_ok "内核已更新并重启"
        return 0
    fi
    print_error "重装失败, 正在回滚"
    if [[ -f "$backup" ]]; then
        cp -f "$backup" "$CLI_ROOT/mihomo"
        systemctl restart "$CLI_SERVICE" 2>/dev/null
        print_ok "已回滚到原内核"
    fi
    return 1
}

# 端口提问。$1=变量名  $2=显示名
# 必须自己校验: 原来 read 完直接 save_settings, 而 save_settings 里的
# python 会 int(p_mixed) —— 直接回车得到空串, 抛
#   ValueError: invalid literal for int() with base 10: ''
# 面板带着 traceback 退出去, 设置没生效但用户以为已经改了。
ask_port() {
    local __var="$1" __label="$2" __cur="${!1}" __in
    printf "新端口 (回车保持 %s): " "$__cur"
    read -r __in
    __in=$(printf '%s' "$__in" | tr -d '[:space:]')
    if [[ -z "$__in" ]]; then
        print_info "未修改, 保持 $__cur"
        return 1
    fi
    if ! [[ "$__in" =~ ^[0-9]+$ ]] || (( __in < 1024 || __in > 65535 )); then
        print_error "端口必须是 1024-65535 之间的数字 (1-1023 会顶掉系统服务)"
        return 1
    fi
    # 已被占用要拦, 否则内核起不来, 而面板还会显示旧端口
    # 先整体捕获再匹配 —— 管道式会因 grep -q 提前退出触发 SIGPIPE (141), 在
    # `set -euo pipefail` 下把"已占用"误判成"未占用", 于是放行了一个起不来的端口。
    if grep -qE ":${__in}$" <<<"$(ss -lntH 2>/dev/null | awk '{print $4}' || true)"; then
        print_error "端口 $__in 已被占用, 换一个"
        return 1
    fi
    printf -v "$__var" '%s' "$__in"
    print_ok "$__label 端口: $__cur → $__in"
    return 0
}

save_settings() {
    python3 - "$CLI_SETTINGS" "$PORT_MIXED" "$PORT_CTRL" "$BIND_ADDR" "${GEO_AUTO_UPDATE:-0}" <<'PYSAVE'
import os, sys, tempfile
path, mixed, ctrl, bind, geo = sys.argv[1:6]
vals = {"PORT_MIXED": mixed, "PORT_CTRL": ctrl, "BIND_ADDR": bind,
        "GEO_AUTO_UPDATE": geo}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".set.")
os.close(fd)
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("# client.sh 设置 (由面板自动写入)\n")
    for k, v in vals.items():
        fh.write(f'{k}="{v}"\n')
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PYSAVE
}

settings_menu() {
    print_title "客户端设置"
    ui_menu 1 "HTTP/SOCKS 端口    当前: $PORT_MIXED"
    ui_menu 2 "控制面板端口       当前: $PORT_CTRL"
    ui_menu 3 "监听地址           当前: $BIND_ADDR  →  $(_show_bind_hint)"
    ui_menu 4 "显示面板密钥"
    ui_menu 5 "重新生成面板密钥"
    ui_menu 6 "geo 自动更新       当前: ${GEO_AUTO_UPDATE:-0}"
    ui_menu 7 "端口占用检测"
    echo >&2
    printf "  ${CYAN}请选择${RESET}: "; local c; read -r c
    c=$(clean_input "$c")
    case "$c" in
        1) ask_port PORT_MIXED "HTTP/SOCKS" && { save_settings; apply_change; } ;;
        2) ask_port PORT_CTRL "控制面板" && { save_settings; apply_change; } ;;
        3) set_bind ;;
        4) cat "$CLI_ROOT/.secret" ;;
        5) gen_secret > "$CLI_ROOT/.secret"; chmod 600 "$CLI_ROOT/.secret"
           print_ok "已重新生成"; apply_change ;;
        6) printf "开启 geo 自动更新? (1=开, 0=关): "; read -r GEO_AUTO_UPDATE
           save_settings; apply_change ;;
        7) port_check_show "$(basename "$CLI_ROOT/mihomo")" ;;
    esac
}

# 菜单上那行"当前: X → Y"的提示
_show_bind_hint() {
    local h; h=$(host_addr "$BIND_ADDR")
    if [[ "$BIND_ADDR" == "$h" ]]; then
        printf '仅 %s' "$h"
    else
        printf '局域网可达, 用 %s 连' "$h"
    fi
}

# 改监听地址。
#
# 对齐 SB 的 set_bind: 讲清两个选项的差别、改完**必须重启**(监听地址是启动期
# 参数, 已在运行时 systemctl start 是空操作), 校验失败要回滚。
set_bind() {
    print_title "监听地址"
    printf "  当前: %s  →  %s\n\n" "$BIND_ADDR" "$(_show_bind_hint)" >&2
    printf "  ${YELLOW}0.0.0.0${RESET}    = 局域网其他设备也能用 (默认)\n" >&2
    printf "  ${YELLOW}127.0.0.1${RESET}  = 只有本机能用 (更安全)\n" >&2
    printf "  也可以直接填本机某个 IP, 例如 192.168.1.10 —— 那样只在该网卡上监听\n\n" >&2
    printf "  ${DIM}控制面板在非回环地址上监听时, 密钥是必需的 (已自动生成)${RESET}\n" >&2
    printf "  新地址 [回车取消]: " >&2
    local nb; read -r nb || return 0
    nb=$(clean_input "$nb")
    [[ -z "$nb" ]] && { print_warn "已取消"; return 0; }

    # 只接受: 0.0.0.0 / :: / 127.0.0.1 / ::1 / localhost / 一个合法 IPv4
    case "$nb" in
        0.0.0.0|"::"|127.0.0.1|"::1"|localhost) ;;
        *)
            if [[ "$nb" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
                local o
                for o in "${BASH_REMATCH[@]:1}"; do
                    (( o <= 255 )) || { print_error "不是合法 IPv4: $nb"; return 1; }
                done
            else
                print_error "认不出来: $nb (可填 0.0.0.0 / 127.0.0.1 / 本机某个 IPv4)"
                return 1
            fi
            # 填了具体 IP 就提醒一句: 换网/DHCP 变了这个地址会绑不上, 内核起不来
            if [[ "$nb" != "$(lan_ip)" ]]; then
                print_warn "注意: 填具体 IP 后, 本机地址一旦变化内核会绑不上而启动失败"
                print_warn "要跟随地址变化, 用 0.0.0.0 更稳"
            fi
            ;;
    esac

    local old="$BIND_ADDR"
    BIND_ADDR="$nb"
    if ! { save_settings && apply_change; }; then
        BIND_ADDR="$old"; save_settings >/dev/null 2>&1 || true
        print_error "配置检查失败, 已回滚为 $old"
        return 1
    fi
    print_ok "监听地址已改为 $nb"
    # 监听地址属于启动期参数: 已在运行时 start 是空操作, 必须重启才会重新 bind
    if svc_active; then
        systemctl restart "$CLI_SERVICE" && print_ok "服务已重启, 新监听地址已生效" \
            || print_warn "重启失败, 请手动「8) 启动/停止/重启服务」"
    else
        print_warn "服务未运行, 启动后生效"
    fi
}

# =============================================================
# 入口 / 子命令
#
# 与服务端同理: core_menu (src/lib/core_mgmt.sh) 一直用
#     bash "$root/src/client.sh" init
#     bash "$root/src/client.sh" uninstall
# 这两个子命令调过来, 而这里以前只无条件进 client_menu, 从不读 $1 ——
# 于是会递归打开一个看不见的面板并抢走 stdin。
# 这里按调用处的本意补齐 (保留原有的"被 source 时不执行"守卫)。
# =============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        init)
            ensure_dirs || exit 1
            # 有 settings 就顺手应用一次, 让基础配置真正落盘;
            # 失败不算错 (还没配过端口是正常状态)。
            apply_change >/dev/null 2>&1 || true
            exit 0 ;;
        uninstall)
            cli_uninstall ;;
        *)
            client_menu ;;
    esac
fi