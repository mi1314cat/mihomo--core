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
    [[ -f "$CLI_SETTINGS" ]] || save_settings
    local secret_file="$CLI_ROOT/.secret"
    [[ -f "$secret_file" ]] || gen_secret > "$secret_file"
    chmod 600 "$secret_file"
    # 注意: 传给 python 的必须是密钥**内容**, 不是文件路径
    local secret; secret=$(cat "$secret_file")

    # 把 provider 列表交给 python 处理; 每个 provider 附带它的刷新方式
    local spec=""
    local f name rec kind
    for f in $(node_files); do
        name=$(basename "$f" .yaml)
        kind="file"
        rec=$(subs_get "$name")
        if [[ -n "$rec" ]] && printf '%s' "$rec" | grep -q 'http-auto'; then
            kind="http-auto"
        fi
        spec+="$name:$kind"$'\n'
    done

    python3 - "$CLI_CONF/config.yaml" "$spec" "$PORT_MIXED" "$PORT_CTRL" \
             "$BIND_ADDR" "$CLI_CONF/ui" "$secret" "${GEO_AUTO_UPDATE:-0}" <<'PYGEN'
import sys, os, yaml

out, spec, p_mixed, p_ctrl, bind, ui, secret, AUTO_GEO_UPDATE = sys.argv[1:9]

providers, names = {}, []
for line in spec.splitlines():
    line = line.strip()
    if not line or ":" not in line:
        continue
    name, kind = line.rsplit(":", 1)
    names.append(name)
    entry = {"path": f"./providers/{name}.yaml"}
    if kind == "http-auto":
        entry = {"type": "http", "path": f"./providers/{name}.yaml",
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
        "listen": "0.0.0.0:1053",
        "ipv6": True,
        "enhanced-mode": "fake-ip",
        "fake-ip-range": "198.18.0.1/16",
        "fake-ip-filter": ["*.lan", "localhost", "*.local", "+.msftconnecttest.com"],
        "default-nameserver": ["223.5.5.5", "119.29.29.29"],
        "nameserver": ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"],
        "proxy-server-nameserver": ["https://dns.alidns.com/dns-query"],
        "fallback": ["https://1.0.0.1/dns-query", "tls://dns.google"],
        # geoip-code 在当前内核是字符串; 写成列表会硬报错
        "fallback-filter": {"geoip": True, "geoip-code": "CN"},
        "nameserver-policy": {"geosite:cn,private": ["https://dns.alidns.com/dns-query"]},
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
        subs_put "$(python3 -c '
import json,sys,datetime
print(json.dumps({"prefix":sys.argv[1],"url":sys.argv[2],"kind":"http-oneshot",
 "imported_at":datetime.datetime.now().isoformat(timespec="seconds")}))' "$name" "$src")"
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
    printf "  HTTP/SOCKS: %s:%s   控制面板: http://%s:%s/ui/\n" "$BIND_ADDR" "$PORT_MIXED" "$BIND_ADDR" "$PORT_CTRL"
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
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        printf "\n按回车继续..."; read -r || break
    done
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
        1) printf "新端口: "; read -r PORT_MIXED; save_settings; apply_change ;;
        2) printf "新端口: "; read -r PORT_CTRL; save_settings; apply_change ;;
        3) printf "新地址 (127.0.0.1 / 0.0.0.0): "; read -r BIND_ADDR; save_settings; apply_change ;;
        4) cat "$CLI_ROOT/.secret" ;;
        5) gen_secret > "$CLI_ROOT/.secret"; chmod 600 "$CLI_ROOT/.secret"
           print_ok "已重新生成"; apply_change ;;
        6) printf "开启 geo 自动更新? (1=开, 0=关): "; read -r GEO_AUTO_UPDATE
           save_settings; apply_change ;;
    esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && client_menu