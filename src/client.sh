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

: "${PORT_MIXED:=7890}"
: "${PORT_CTRL:=9090}"
: "${BIND_ADDR:=127.0.0.1}"
: "${HEALTH_URL:=http://www.gstatic.com/generate_204}"

GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; CYAN="\033[36m"
MAGENTA="\033[35m"; BOLD="\033[1m"; RESET="\033[0m"

print_info()  { printf "${CYAN}[信息]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[成功]${RESET} %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[警告]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[错误]${RESET} %s\n" "$1" >&2; }
print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

ensure_dirs() { mkdir -p "$CLI_CONF" "$CLI_PROVIDERS" "$CLI_NODES" "$CLI_UI"; }

# =============================================================
# 工具
# =============================================================
gen_secret() { openssl rand -hex 16; }

node_files() { ls "$CLI_PROVIDERS"/*.yaml 2>/dev/null | sort; }
node_count() { node_files | wc -l | tr -d ' '; }

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

# 写配置 → 严格校验 → 内核校验 → 才重启; 任一步失败则回滚
apply_change() {
    local bak; bak=$(mktemp)
    [[ -f "$CLI_CONF/config.yaml" ]] && cp -f "$CLI_CONF/config.yaml" "$bak"

    if ! gen_config; then rm -f "$bak"; return 1; fi
    if ! cfg_check_strict >/tmp/cfgstrict.log 2>&1; then
        cat /tmp/cfgstrict.log >&2
        print_error "严格字段校验未通过, 已回滚"
        [[ -f "$bak" ]] && cp -f "$bak" "$CLI_CONF/config.yaml"
        rm -f "$bak"; return 1
    fi
    if ! "$CLI_BIN" -t -d "$CLI_CONF" >/tmp/cfgcheck.log 2>&1; then
        tail -5 /tmp/cfgcheck.log >&2
        print_error "内核配置检查未通过, 已回滚"
        [[ -f "$bak" ]] && cp -f "$bak" "$CLI_CONF/config.yaml"
        rm -f "$bak"; return 1
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
    # (实测 2026-10-06 CC: 同机另一个项目的 mihomo 占着 7890/9090)。
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
            if printf '%s' "$rec" | grep -q 'http-auto'; then kind="http-auto"; fi
            url=$(printf '%s' "$rec" | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("url",""))
except Exception: print("")' 2>/dev/null)
        fi
        # URL 里含 : 和 /, 不能用 name:kind:url 三段切分 —— 改用 \x1f 分隔。
        spec+="$name"$'\x1f'"$kind"$'\x1f'"$url"$'\n'
    done

    python3 - "$CLI_CONF/config.yaml" "$spec" "$PORT_MIXED" "$PORT_CTRL" \
             "$BIND_ADDR" "$CLI_CONF/ui" "$secret" "${GEO_AUTO_UPDATE:-0}" <<'PYGEN'
import sys, os, yaml

out, spec, p_mixed, p_ctrl, bind, ui, secret, AUTO_GEO_UPDATE = sys.argv[1:9]

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

if not names:
    names = []
    groups = [{"name": "PROXY", "type": "select", "proxies": ["DIRECT"]}]
else:
    groups = [
        {"name": "PROXY", "type": "select", "use": names},
        {"name": "AUTO", "type": "url-test", "use": names,
         "url": "http://www.gstatic.com/generate_204", "interval": 300,
         "tolerance": 50, "max-failed-times": 3},
    ]
    for n in names:
        groups.append({"name": n, "type": "select", "use": [n]})

lan = bind != "127.0.0.1"

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

cfg = {
    "mixed-port": int(p_mixed),
    "allow-lan": lan,
    "bind-address": "*" if lan else bind,
    "mode": "rule",
    "log-level": "info",
    "ipv6": True,
    "unified-delay": True,
    "tcp-concurrent": True,
    "find-process-mode": "strict",
    "external-controller": f"{bind}:{p_ctrl}",
    "secret": secret,
    "external-ui": "ui",
    "profile": {"store-selected": True, "store-fake-ip": True},
    "dns": {
        "enable": True,
        # 跟随 BIND_ADDR, 不要硬编码 0.0.0.0。
        #
        # 实测问题: 同一进程里代理口听 127.0.0.1:17890,
        # DNS 口却听 0.0.0.0:1053 —— 与上面 allow-lan=false 自相矛盾。
        # 后果是本机成了一个开放解析器: 局域网任何人都能拿它查询,
        # 而这些查询**不经过代理**, 等于白送一份 DNS 反射面。
        "listen": f"{bind}:1053",
        # 关掉 AAAA 记录。
        #
        # 实测问题: 开着 ipv6 时内核会返回真实 IPv6 地址,
        # 而 <CLIENT_ALIAS> 有活的 2409:8a20::/64 和默认 v6 路由 —— 那些流量根本没进
        # mihomo, 直接走 IPv6 出去了。同机两个解析器两个答案:
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
        # 主解析: 全部加密, 且走代理 (respect-rules)。
        # 之前这里是 alidns/doh.pub 两个国内 DoH —— 意味着每个境外域名
        # 都被完整送到阿里和腾讯, 这是与运营商无关的第二条泄露链路。
        "nameserver": ["https://dns.alidns.com/dns-query#PROXY",
                       "https://doh.pub/dns-query#PROXY"],
        # 解析代理服务器自身域名: 必须直连, 否则死循环。
        "proxy-server-nameserver": ["https://dns.alidns.com/dns-query"],
        # fallback 与主解析二选一, 不是并行双发。
        #
        # 实测问题: 之前没设 fallback-lazy-query (默认 false),
        # fallback 被急切并发查询, 于是**每个境外域名同时**发给
        # alidns/doh.pub 和 fallback 两组。加上 nameserver 本身就是
        # 国内 DoH, 一个境外域名实际被发给了 4 家。
        # fallback-lazy-query=true 才是 mihomo 的正确语义:
        # 主解析返回的 IP 落在境外时才查 fallback, 国内域名根本不会走到。
        "fallback-lazy-query": True,
        "fallback": ["https://1.0.0.1/dns-query#PROXY", "tls://dns.google#PROXY"],
        # geoip-code 在当前内核是字符串; 写成列表会硬报错
        "fallback-filter": {"geoip": True, "geoip-code": "CN"},
        # respect-rules: DNS 连接本身受 rules 约束。
        #
        # 不设时默认为 false —— 这意味着 DNS 出站**不受路由规则影响**,
        # 写 rules: MATCH,PROXY 对 DNS 毫无作用, 加密 DNS 实际是直连出去的。
        "respect-rules": True,
        "nameserver-policy": {
            "geosite:cn,private": ["https://dns.alidns.com/dns-query"],
            # 广告在 DNS 层直接拒, 不让它离开本机。
            # 路由层也有一份, 双层消费 (与 SB 的做法一致)。
            "geosite:category-ads-all": ["rcode://success"],
        },
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
    python3 - "$src" "$CLI_PROVIDERS/$name.yaml" <<'PYIMP'
import sys, yaml, os, tempfile
src, dst = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(src, encoding="utf-8"))
if not isinstance(d, dict) or not isinstance(d.get("proxies"), list) or not d["proxies"]:
    print("[ERR] 不是合法的 Mihomo 订阅 (需要顶层 proxies: 列表)", file=sys.stderr)
    sys.exit(1)
bad = [p.get("name") for p in d["proxies"]
       if not isinstance(p, dict) or not p.get("name") or not p.get("type")
       or "server" not in p or "port" not in p]
if bad:
    print(f"[ERR] 以下节点缺少必要字段: {bad}", file=sys.stderr)
    sys.exit(1)
os.makedirs(os.path.dirname(dst), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst), prefix=".p.")
os.close(fd)
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(f"# 导入于 {__import__('datetime').datetime.now().isoformat(timespec='seconds')}\n")
    yaml.safe_dump({"proxies": d["proxies"]}, fh, sort_keys=False,
                   allow_unicode=True, default_flow_style=False)
os.replace(tmp, dst)
print(f"[OK] 已写入 {dst} ({len(d['proxies'])} 个节点)", file=sys.stderr)
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
        print_info "正在拉取..."
        local code
        code=$(curl -sSL --max-time 30 -o "$body" -w '%{http_code}' "$src" 2>/dev/null)
        case "$code" in
            200) ;;
            404) print_error "链接不存在"; rm -rf "$tmp"; return 1 ;;
            410) print_error "链接已失效 (用尽 / 过期 / 已禁用)"; rm -rf "$tmp"; return 1 ;;
            503) print_error "服务端暂时不可用 (未消耗次数)"; rm -rf "$tmp"; return 1 ;;
            *)   print_error "拉取失败 HTTP $code"; rm -rf "$tmp"; return 1 ;;
        esac
    elif [[ -f "$src" ]]; then
        cp -f "$src" "$body"
    else
        print_error "无法识别的来源"; rm -rf "$tmp"; return 1
    fi

    local name; name=$(printf '%s' "${src##*/}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
    [[ -z "$name" || "$name" == "share" ]] && name="sub$(date +%H%M%S)"
    local n=1 base="$name"
    while [[ -f "$CLI_PROVIDERS/$name.yaml" ]]; do name="${base}_$n"; n=$((n+1)); done

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
        printf "    1) 自动更新 (每 10 分钟, 推荐)\n"
        printf "    2) 手动更新 (只在选「更新配置」时拉取)\n"
        printf "请选择 [1]: "
        local a; read -r a
        [[ "$a" == "2" ]] || kind="http-auto"
        subs_put "$(python3 -c '
import json,sys,datetime
print(json.dumps({"prefix":sys.argv[1],"url":sys.argv[2],"kind":sys.argv[3],
 "imported_at":datetime.datetime.now().isoformat(timespec="seconds")}))' "$name" "$src" "$kind")"
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
d=yaml.safe_load(open(sys.argv[1])) or {}
print(len(d.get('proxies') or []))" "$f" 2>/dev/null || echo "?")
        local src=""; [[ -f "$CLI_NODES/$name.txt" ]] && src=$(head -1 "$CLI_NODES/$name.txt")
        printf '  \033[1m%-20s\033[0m %s 个节点   来源: %s\n' "$name" "$cnt" "${src:-本地文件}"
        found=1
    done
    [[ $found -eq 0 ]] && print_info "还没有任何节点, 请先「添加节点」"
}

node_delete() {
    ensure_dirs
    node_list
    printf '\n请输入要删除的节点名 [回车取消]: '
    local n; read -r n
    [[ -n "$n" ]] || { print_info "已取消"; return; }
    [[ -f "$CLI_PROVIDERS/$n.yaml" ]] || { print_error "节点不存在: $n"; return 1; }
    rm -f "$CLI_PROVIDERS/$n.yaml" "$CLI_NODES/$n.txt"
    subs_del "$n"
    print_ok "已删除 $n"
    apply_change
}

node_update() {
    print_title "更新订阅节点"
    ensure_dirs
    subs_file_init
    local rec pre url
    while read -r pre url; do
        [[ -z "$pre" ]] && continue
        print_info "更新 $pre ..."
        # 先备份, 拉取成功才替换 —— 一次性链接失败时不能把现有节点弄丢
        local tmp; tmp=$(mktemp -d)
        local code
        code=$(curl -sSL --max-time 30 -o "$tmp/sub.yaml" -w '%{http_code}' "$url" 2>/dev/null)
        if [[ "$code" != "200" ]]; then
            print_warn "  跳过 $pre (HTTP $code), 保留原有节点"
            rm -rf "$tmp"; continue
        fi
        local bak=""; [[ -f "$CLI_PROVIDERS/$pre.yaml" ]] && bak=$(mktemp) && cp -f "$CLI_PROVIDERS/$pre.yaml" "$bak"
        if _add_from_file "$tmp/sub.yaml" "$pre"; then
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
    local svc="未运行" ver="-" n; n=$(node_count)
    svc_active && svc="${GREEN}运行中${RESET}"
    if [[ -x "$CLI_BIN" ]]; then ver=$("$CLI_BIN" -v 2>/dev/null | head -1); fi
    printf "  服务: %-14s 节点: %-4s 内核: %s\n" "$svc" "$n" "$ver"
    # 端口要显示**内核实际在用的**, 不能只显示 settings.env 里的值。
    # 实测: 全新安装写的是 mixed-port: 0, 面板却显示 7890 ——
    # 而 7890 恰好是本机另一个 mihomo 的端口, 等于显示"别人的端口"。
    # 该端口在本进程名下真有 socket 才算一致, 否则去内核实际监听里找。
    local eff_mixed="$PORT_MIXED" nm real
    nm=$(basename "$CLI_BIN")
    if ! ss -lntpH 2>/dev/null | grep -E ":${PORT_MIXED}[[:space:]]" | grep -q "(\"$nm\","; then
        real=$(ss -lntpH 2>/dev/null | grep "(\"$nm\"," \
               | awk '{print $4}' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -1)
        [[ -n "$real" ]] && eff_mixed="$real"
    fi
    printf "  HTTP/SOCKS: %s:%s   控制面板: http://%s:%s/ui/\n" \
        "$BIND_ADDR" "$eff_mixed" "$BIND_ADDR" "$PORT_CTRL"
    if [[ "$eff_mixed" != "$PORT_MIXED" ]]; then
        print_info "面板设置端口 $PORT_MIXED, 但内核实际在用 $eff_mixed"
        print_info "改端口后需「6) 服务管理 → 3) 重启」才会生效"
    fi
}

api() { curl -s -m 8 -H "Authorization: Bearer $(cat "$CLI_ROOT/.secret" 2>/dev/null)" "http://$BIND_ADDR:$PORT_CTRL$1"; }

node_test() {
    print_title "节点测速"
    svc_active || { print_warn "服务未运行, 请先启动"; return 1; }
    curl -s -m 8 -H "Authorization: Bearer $(cat "$CLI_ROOT/.secret" 2>/dev/null)" \
        "http://$BIND_ADDR:$PORT_CTRL/proxies" > /tmp/proxies.json 2>/dev/null
    [[ -s /tmp/proxies.json ]] || { print_error "无法连接控制 API"; return 1; }
    python3 - "$CLI_ROOT/.secret" "$BIND_ADDR" "$PORT_CTRL" <<'PYTEST'
import json, sys, urllib.request, urllib.parse
secret = open(sys.argv[1]).read().strip()
base = f"http://{sys.argv[2]}:{sys.argv[3]}"
H = {"Authorization": "Bearer " + secret}
try:
    d = json.load(open("/tmp/proxies.json"))["proxies"]
except Exception:
    print("[错误] 控制 API 返回异常"); sys.exit(1)
SKIP = {"Direct", "Reject", "Pass", "Compatible", "REJECT", "PASS", "COMPATIBLE",
        "GLOBAL", "REJECT-DROP"}
TEST = "http://www.gstatic.com/generate_204"
rows = []
for name, v in d.items():
    if v.get("type") in SKIP:
        continue
    url = (f"{base}/proxies/{urllib.parse.quote(name)}/delay"
           f"?timeout=8000&url={urllib.parse.quote(TEST)}")
    try:
        r = json.load(urllib.request.urlopen(
            urllib.request.Request(url, headers=H), timeout=12))
        rows.append((r.get("delay", "?"), name, v.get("type", "?"), True))
    except Exception as e:
        msg = ""
        if hasattr(e, "read"):
            try:
                msg = json.loads(e.read()).get("message", "")
            except Exception:
                pass
        rows.append((99999, name, v.get("type", "?"), False, msg))
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
client_menu() {
    while true; do
        print_title "Mihomo 客户端面板"
        status_block
        printf '\n'
        echo "1) 初始化基础配置"
        echo "2) 添加节点 (分享链接 / 订阅 / 本地文件)"
        echo "3) 查看节点"
        echo "4) 更新订阅节点"
        echo "5) 删除节点"
        echo "6) 启动 / 停止 / 重启服务"
        echo "7) 配置检查"
        echo "8) 节点测速"
        echo "9) 客户端设置 (端口 / 绑定 / 面板密钥)"
        echo "10) 分享订阅 (把我的节点发给别人)"
        echo "d) 卸载客户端"
        echo "0) 退出"
        printf "\n请选择: "
        local c; read -r c || { printf "\n[信息] 非交互环境 (stdin 已关闭), 已退出\n" >&2; break; }
        case "$c" in
            1) apply_change ;;
            2) node_add ;;
            3) node_list ;;
            4) node_update ;;
            5) node_delete ;;
            6) svc_menu ;;
            7) check_menu ;;
            8) node_test ;;
            9) settings_menu ;;
            10) cli_share_menu ;;
            d|D) cli_uninstall ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        printf "\n按回车继续..."; read -r || break
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
    # 分享服务名与 cli_share_menu 里 export 的保持一致, 不能各处各写一份
    # (之前这里硬编码, 改另一处就会漏)
    local svc="$CLI_SERVICE" shsvc="mihomo-client-share"
    # 作用域校验: 安装目录被改到别处时 (CLI_ROOT 可被环境变量覆盖),
    # 这两个服务名可能属于**别的** mihomo 实例, 删 unit 就是误删。
    # 单元文件里记了安装路径, 对不上就只提示不动手。
    _unit_owned_by_me "$svc" || { svc=""; print_warn "$svc 的 unit 不属于 $CLI_ROOT, 不会删除"; }
    _unit_owned_by_me "$shsvc" || { shsvc=""; print_warn "$shsvc 的 unit 不属于 $CLI_ROOT, 不会删除"; }
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
        *)  print_error "无效选项" ;;
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

    # 端口回收: 只按自己的台账删, 不扫防火墙全表
    local fw="$CLI_ROOT/.fw-ports" p
    if [[ -f "$fw" ]]; then
        while IFS= read -r p; do
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
                ufw delete allow "$p/tcp" >/dev/null 2>&1
                ufw delete allow "$p/udp" >/dev/null 2>&1
            elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
                firewall-cmd --zone=public --remove-port="$p/tcp" --permanent >/dev/null 2>&1
                firewall-cmd --zone=public --remove-port="$p/udp" --permanent >/dev/null 2>&1
            elif command -v iptables >/dev/null; then
                iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
                iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
            fi
        done < "$fw"
        print_ok "已回收登记的防火墙端口: $(wc -l < "$fw") 个"
    fi

    rm -rf "$CLI_ROOT"
    if [[ -e "$CLI_ROOT" ]]; then
        print_error "删除失败, 目录仍在: $CLI_ROOT"
        print_error "请检查权限 (是否有进程占用), 或手动执行: rm -rf $CLI_ROOT"
        return 1
    fi
    print_ok "已彻底删除: $CLI_ROOT"

    # 确认代理口确实释放
    if ss -lntH 2>/dev/null | grep -qE ":${PORT_MIXED}[[:space:]]"; then
        print_warn "端口 $PORT_MIXED 仍在监听 —— 本机可能还有别的 mihomo 实例在使用它"
    fi
    return 0
}

# =============================================================
# 分享订阅
#
# 把本机已经导入的节点 (proxy-providers) 生成带 token 的分享链接,
# 发给别人后对方可直接作为 proxy-provider 消费。
#
# 与服务端 share 的差别:
#   服务端节点来自 out/*_client-*.yaml
#   客户端节点来自 conf/providers/*.yaml  —— 所以要传 SHARE_PROVIDERS_DIR
#
# 注意 SRV_ROOT 必须显式指向 CLI_ROOT。share.sh 的默认值是 /root/catmi/mihomo,
# 而客户端机器上那个路径可能存在但是**别的项目**的目录, 不指过去会发布错配置。
# =============================================================
cli_share_menu() {
    print_title "分享订阅"

    if [[ ! -d "$CLI_PROVIDERS" ]]; then
        print_error "没有 provider 目录: $CLI_PROVIDERS"
        print_info "请先通过「添加节点」导入订阅或分享链接"
        return 1
    fi

    local n
    n=$(ls -1 "$CLI_PROVIDERS"/*.yaml 2>/dev/null | wc -l)
    if [[ "$n" -eq 0 ]]; then
        print_error "provider 目录为空, 没有可分享的节点"
        return 1
    fi
    print_info "本机有 $n 份 provider, 可分别生成分享链接"

    export SRV_ROOT="$CLI_ROOT"
    export SRV_OUT="$CLI_ROOT/out"
    export SRV_CONF="$CLI_CONF"
    export SRV_SERVICE="$CLI_SERVICE"
    export SRV_ENV="$CLI_ROOT/install_info.env"
    export SHARE_DIR="$CLI_ROOT/share"
    # 客户端用独立的服务名和端口, 避免与服务器端混淆或撞端口
    export SHARE_SERVICE="mihomo-client-share"
    export SHARE_PORT="${CLI_SHARE_PORT:-9444}"
    export SHARE_PROVIDERS_DIR="$CLI_PROVIDERS"

    # share 模块按需加载。
    # 注意: 这里必须用带命名空间的名字 (cli_share_menu) 调本函数。
    # share.sh 自己就定义了 share_menu, 若同名, declare -F 会因为"本函数已存在"
    # 而恒为真 → source 永远不执行 → 末尾裸调用 share_menu 调到自己 → 无限递归。
    if ! declare -F share_menu >/dev/null 2>&1; then
        local _here share_sh
        _here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
        share_sh="$_here/share/share.sh"
        if [[ ! -f "$share_sh" ]]; then
            print_error "缺少 share 模块: $share_sh"
            print_info "请重新运行安装脚本补齐文件"
            return 1
        fi
        # shellcheck source=/dev/null
        source "$share_sh" || { print_error "share 模块加载失败"; return 1; }
    fi
    share_menu
}

svc_menu() {
    print_title "服务管理"
    echo "1) 启动   2) 停止   3) 重启   4) 查看状态"
    printf "请选择: "; local c; read -r c
    case "$c" in
        1) systemctl start "$CLI_SERVICE" && print_ok "已启动" ;;
        2) systemctl stop "$CLI_SERVICE" && print_ok "已停止" ;;
        3) systemctl restart "$CLI_SERVICE" && print_ok "已重启" ;;
        4) systemctl status "$CLI_SERVICE" --no-pager | head -12 ;;
    esac
}

check_menu() {
    print_title "配置检查"
    print_info "1) 内核检查 (mihomo -t)"; cfg_check
    print_info "2) 严格字段校验"; cfg_check_strict
    print_info "3) 服务状态"; systemctl status "$CLI_SERVICE" --no-pager | head -8
    print_info "4) 手动上传内核 (下载不通时用)"
    printf "请选择: "; local c; read -r c
    case "$c" in
        1) cfg_check ;;
        2) cfg_check_strict ;;
        3) systemctl status "$CLI_SERVICE" --no-pager | head -8 ;;
        4) kernel_upload_menu ;;
    esac
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
    # 真跑 —— 这是唯一可靠的判据
    # 真跑 —— 这是唯一可靠的判据。
    #
    # 必须**先整体捕获再匹配**, 不能写成 "$out" -v 2>/dev/null | grep -qi mihomo:
    # grep -q 一命中就退出, 上游 mihomo 写管道时收到 SIGPIPE (141), 而本脚本
    # 开头是 `set -euo pipefail`, 管道因此被判为失败。
    #
    # 致命的是这是竞态 —— 取决于内核把版本行写完的快慢, 同一台机器时灵时不灵。
    # 实测 2026-10-06 <SERVER_ALIAS> 上连跑 12 次, 管道式挂了 7 次 (全是 141), 捕获式 12/12。
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
    if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE ":${__in}$"; then
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
    echo "1) HTTP/SOCKS 端口      当前: $PORT_MIXED"
    echo "2) 控制面板端口         当前: $PORT_CTRL"
    echo "3) 监听地址             当前: $BIND_ADDR  (127.0.0.1=仅本机, 0.0.0.0=局域网)"
    echo "4) 显示面板密钥"
    echo "5) 重新生成面板密钥"
    echo "6) geo 自动更新                当前: ${GEO_AUTO_UPDATE:-0}"
    printf "请选择: "; local c; read -r c
    case "$c" in
        1) ask_port PORT_MIXED "HTTP/SOCKS" && { save_settings; apply_change; } ;;
        2) ask_port PORT_CTRL "控制面板" && { save_settings; apply_change; } ;;
        3) printf "新地址 (127.0.0.1 / 0.0.0.0): "; read -r BIND_ADDR
           [[ -n "$BIND_ADDR" ]] && { save_settings; apply_change; } ;;
        4) cat "$CLI_ROOT/.secret" ;;
        5) gen_secret > "$CLI_ROOT/.secret"; chmod 600 "$CLI_ROOT/.secret"
           print_ok "已重新生成"; apply_change ;;
        6) printf "开启 geo 自动更新? (1=开, 0=关): "; read -r GEO_AUTO_UPDATE
           save_settings; apply_change ;;
    esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && client_menu