#!/usr/bin/env bash
# =============================================================
# cc-verify-m.sh — 真机验收台: M 客户端 × proxy-node-compat
#
# 验什么（三列对照, 缺一列都不算验过）:
#     旧判定  vs  compat 判定  vs  **真实连通性**
#
# 真实连通性是本机实测出来的, 不是引用别人的结论:
#     经代理 curl generate_204 → 记 HTTP 码 / 耗时 / 出口 IP
#
# 纪律（与项目既有约定一致）:
#   * 全部在 /tmp 内完成, 不写任何生产路径, 不碰 /root/catmi/*
#   * **不重启任何生产服务**; 被测内核是独立实例（独立 -d 目录 + 独立端口）
#   * 端口**动态选**, 并显式挡住"撞上生产客户端端口"的情况 ——
#     撞了之后 curl 打到的是生产实例, 结论全错却看起来很正常
#   * 订阅来自 RN 的真实产物, 由仓库当前版本的 build_sub.py 生成
#   * 收尾清理: kill 全部临时进程 + rm -rf 临时目录 + 关掉 RN 侧临时服务
#
# 用法（在 CC 上）:
#     SRC=/tmp/mvm/src bash /tmp/cc-verify-m.sh
# 变量:
#     SRC         仓库 src/ 的落地位置（默认 /tmp/mvm/src）
#     MIHOMO      内核二进制（默认取在跑的那个客户端的内核, **只读**使用）
#     RN          RN 的 ssh 别名（默认 rn）
#     TUNNEL_PORT 订阅隧道端口（默认 18899; 只在回环上, 不对公网开新端口）
#     KEEP=1      跑完保留 /tmp/mvm（排查用）
# 退出码: 0 全过 / 1 有失败
# =============================================================
set -uo pipefail

SRC=${SRC:-/tmp/mvm/src}
MIHOMO=${MIHOMO:-/root/catmi/mihomo-client/mihomo}
RN=${RN:-rn}
TUNNEL_PORT=${TUNNEL_PORT:-18899}
WORK=/tmp/mvm
ROOT="$WORK/cli"
PASS=0; FAIL=0; FIND=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
hdr()  { printf "\n\033[1m%s\033[0m\n" "$1"; }
note() { printf "    %s\n" "$1"; }
# 「发现」与「失败」分开: 发现 = 这次验收**顺带查出来的既有缺陷**（不在本次改动
# 范围内, 但它是个真问题, 必须看得见）；失败 = 本次接入自己的断言没过。
# 把两者混在一起会让"接入是否安全"这个结论被无关缺陷污染。
find_() { printf "  \033[33m⚠ 发现\033[0m %s\n" "$1"; FIND=$((FIND+1)); }
dump() { if [[ -f "$1" ]]; then sed 's/^/    /' "$1" | awk 'NR<=20'; fi; return 0; }

# 让内核自己 bind 0 号端口, 拿一个真正空闲的
pick_port() {
    python3 <<'PYP'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PYP
}

cleanup() {
    kill "${SVPID:-0}" "${TUNPID:-0}" 2>/dev/null
    # RN 侧按 pidfile 杀。★ 不能用 `pkill -f <名字>` —— 那条远程命令的**自身
    # 命令行**里就含那个名字, pkill 会先把自己杀掉, 后面的 rm 永远不执行,
    # 临时服务就残留在生产机上（本项目实测踩过）。
    # 双保险: 先按 pidfile 杀; 再按**端口**兜一次（pidfile 有可能没写成 ——
    # 比如订阅构建那步先失败了）。仍然不用 pkill -f, 理由同上。
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$RN" \
        "kill \$(cat /tmp/mrnsub/server.pid 2>/dev/null) 2>/dev/null; sleep 1; \
         P=\$(ss -lntp 2>/dev/null | awk '/:$TUNNEL_PORT/{print}' | grep -oE 'pid=[0-9]+' | cut -d= -f2); \
         [ -n \"\$P\" ] && kill \$P 2>/dev/null; \
         sleep 1; rm -rf /tmp/mrnsub /tmp/mrnsub-build /tmp/mrnsub.log" \
        >/dev/null 2>&1
    [[ "${KEEP:-0}" == "1" ]] || rm -rf "$WORK"
}
trap cleanup EXIT

printf "\n\033[1m═══ M 客户端 × proxy-node-compat · 真机验收 ═══\033[0m\n"
printf "  src    : %s\n" "$SRC"
printf "  kernel : %s\n" "$MIHOMO"
printf "  工作区 : %s  (收尾会删; KEEP=1 保留)\n" "$WORK"

# ---------------------------------------------------------------- 0
hdr "0. 环境与真探测"
rm -rf "$WORK"; mkdir -p "$ROOT"
"$MIHOMO" -v 2>/dev/null | awk 'NR==1' | sed 's/^/  /'
export MIHOMO_BIN="$MIHOMO"
KV=$(python3 "$SRC/lib/nodecompat.py" kernel 2>&1)
printf '%s\n' "$KV" | sed 's/^/  /'
VER=$(printf '%s' "$KV" | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["version"] or "")' 2>/dev/null)
[[ -n "$VER" ]] && ok "内核版本真探测 = $VER（不是写死的）" || bad "版本探测失败"

MIXED="${MIXED:-$(pick_port)}"; CTRL="${CTRL:-$(pick_port)}"
PROD_SETTINGS=/root/catmi/mihomo-client/settings.env
if [[ -f "$PROD_SETTINGS" ]]; then
    PROD_MIXED=$(sed -n 's/^PORT_MIXED="\(.*\)"$/\1/p' "$PROD_SETTINGS")
    PROD_CTRL=$(sed -n 's/^PORT_CTRL="\(.*\)"$/\1/p' "$PROD_SETTINGS")
    for pair in "MIXED:$MIXED:$PROD_MIXED" "CTRL:$CTRL:$PROD_CTRL"; do
        IFS=: read -r _n _a _b <<<"$pair"
        if [[ -n "$_b" && "$_a" == "$_b" ]]; then
            printf "\033[31m临时端口 %s=%s 与生产客户端冲突, 拒绝继续（会拿生产实例当被测对象）\033[0m\n" "$_n" "$_a"
            exit 2
        fi
    done
    note "已确认临时端口 $MIXED/$CTRL 不撞生产端口 $PROD_MIXED/$PROD_CTRL"
fi
for p in $MIXED $CTRL; do
    if ss -lnt 2>/dev/null | awk -v pat=":$p " 'index($0,pat){found=1} END{exit !found}'; then
        bad "端口 $p 被占用"
    else
        ok "端口 $p 空闲"
    fi
done

# ---------------------------------------------------------------- 1
hdr "1. RN 侧: 用仓库当前的构建器生成真实订阅（只写 /tmp）"
# ⚠ 用**仓库当前**的 build_sub.py, 不是 RN 上部署的那一份: 部署版是旧版,
#   它的"存活名单 vs 产物"按裸名/旗帜名直接比字符串, 交集恒为空 → 把全部
#   活节点判成陈旧产物, 订阅直接变空（正是仓库刚修掉的 P-M1）。
#   本脚本只把文件拷到 /tmp 跑, 不碰 RN 的生产目录、不重启任何服务。
ssh -o BatchMode=yes -o ConnectTimeout=10 "$RN" \
    'mkdir -p /tmp/mrnsub-build/share /tmp/mrnsub-build/lib' >/dev/null 2>&1
scp -q "$SRC/share/build_sub.py" "$RN:/tmp/mrnsub-build/share/build_sub.py"
scp -q "$SRC/lib/naming.py" "$RN:/tmp/mrnsub-build/lib/naming.py" 2>/dev/null || true

# 下面这个 heredoc **不加引号**: $TUNNEL_PORT 需要在本地展开。
# 因此里面的 shell 变量一律要转义 —— 连注释里的也一样, 注释同样会被展开
# （踩过: 注释里写了一个本地不存在的变量, 整条 ssh 直接失败且不留日志）。
ssh -o BatchMode=yes -o ConnectTimeout=10 "$RN" bash -s <<RNSUB >"$WORK/rn-build.log" 2>&1
set -e
rm -rf /tmp/mrnsub; mkdir -p /tmp/mrnsub
python3 /tmp/mrnsub-build/share/build_sub.py \
    --out-dir /root/catmi/mihomo/out \
    --conf-dir /root/catmi/mihomo/conf \
    --tag all -o /tmp/mrnsub/sub_all.yaml
if ! grep -q '^- name' /tmp/mrnsub/sub_all.yaml 2>/dev/null; then
    echo "[fallback] 存活名单对不上, 改为不过滤重建"
    python3 /tmp/mrnsub-build/share/build_sub.py \
        --out-dir /root/catmi/mihomo/out --tag all -o /tmp/mrnsub/sub_all.yaml
fi
# 真实单节点分享链接也一起导出: 客户端现在能吃这一路 (URI 列表),
# 而这一路在 compat 里是**保真最高**的入口 (parse_uri, 值一字节不改)。
cat /root/catmi/mihomo/out/*_share-*.txt 2>/dev/null | grep -v '^[[:space:]]*$' > /tmp/mrnsub/uris.txt || true
# 再存一份**只去掉 `&obfs=none`** 的同一批链接。为什么需要它:
#   mihomo 的 file-provider 转换器遇到 `obfs=none` 会认为缺 obfs-password,
#   于是**整批**失败（12 条只加载 0 条, 而 -t 仍报 successful）。原样那份留着
#   复现这个问题, 修正那份用来真正测出 URI 通路的逐节点连通性。
sed 's/&obfs=none//g' /tmp/mrnsub/uris.txt > /tmp/mrnsub/uris-fixed.txt || true
echo "uri_count=$(wc -l < /tmp/mrnsub/uris.txt) fixed_count=$(wc -l < /tmp/mrnsub/uris-fixed.txt)"
cd /tmp/mrnsub
nohup python3 -m http.server $TUNNEL_PORT --bind 127.0.0.1 >/tmp/mrnsub.log 2>&1 &
echo \$! > /tmp/mrnsub/server.pid
echo "server_pid=\$(cat /tmp/mrnsub/server.pid)"
RNSUB
dump "$WORK/rn-build.log"
RNN=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$RN" \
      'python3 -c "import yaml,collections;d=yaml.safe_load(open(\"/tmp/mrnsub/sub_all.yaml\"));p=d.get(\"proxies\") or [];print(len(p));print(dict(collections.Counter(x.get(\"type\") for x in p)))"' 2>/dev/null)
note "RN 订阅: $RNN"
[[ -n "$RNN" ]] && ok "RN 真实订阅已生成（内容不进仓库）" || bad "RN 订阅生成失败"

# 只用**回环**隧道把 RN 的 127.0.0.1 端口映射到 CC 的 127.0.0.1 ——
# 不在 RN 上开任何公网可达的新端口。
ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -N \
    -L "127.0.0.1:$TUNNEL_PORT:127.0.0.1:$TUNNEL_PORT" "$RN" \
    </dev/null >"$WORK/tunnel.log" 2>&1 &
TUNPID=$!
SUBURL="http://127.0.0.1:$TUNNEL_PORT/sub_all.yaml"
c=000
for _i in $(seq 1 20); do
    c=$(curl -s -o "$WORK/sub_pull.yaml" -w '%{http_code}' --max-time 8 "$SUBURL")
    [[ "$c" == 200 ]] && break
    sleep 1
done
if [[ "$c" == 200 ]]; then
    ok "经回环隧道从 RN 拉到订阅 (HTTP 200, $(wc -c <"$WORK/sub_pull.yaml") 字节)"
else
    bad "拉取 RN 订阅失败 HTTP $c"; dump "$WORK/tunnel.log"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$RN" \
        "ss -lnt 2>/dev/null | awk '/$TUNNEL_PORT/{print}'" | sed 's/^/    RN: /'
    exit 1
fi

# ---------------------------------------------------------------- 2
hdr "2. CC 侧: 用 M 客户端导入这份真实订阅"
# 用**独立脚本**而不是嵌套引号的 bash -c: 后者出现过"少一个引号 → 整段静默
# 失败", 而报错只指向 bash 本身, 看不出是哪一步。
cat > "$WORK/import.sh" <<'IMP'
set -uo pipefail
source "$SRC/client.sh"
CLI_CONF="$CLI_ROOT/conf"; CLI_PROVIDERS="$CLI_CONF/providers"
CLI_NODES="$CLI_ROOT/nodes"; CLI_UI="$CLI_ROOT/ui"
CLI_SUBS="$CLI_ROOT/subscriptions.json"; CLI_SERVICE=mvm-nothing
mkdir -p "$CLI_PROVIDERS" "$CLI_NODES"
_add_from_file "$1" "$2"
IMP

# 拉取走客户端自己的 HTTP 通路（dl_route / http_code 分支都真跑一遍）
SRC="$SRC" CLI_ROOT="$ROOT" PORT_MIXED="$MIXED" PORT_CTRL="$CTRL" BIND_ADDR=127.0.0.1 \
CLI_BIN="$MIHOMO" CLI_SERVICE=mvm-nothing bash -c '
    source "$SRC/client.sh"
    CLI_CONF="$CLI_ROOT/conf"; CLI_PROVIDERS="$CLI_CONF/providers"
    CLI_NODES="$CLI_ROOT/nodes"; CLI_UI="$CLI_ROOT/ui"
    CLI_SUBS="$CLI_ROOT/subscriptions.json"; CLI_SERVICE=mvm-nothing
    node_add
' <<< "$(printf '%s\n\n\n' "$SUBURL")" >"$WORK/import.log" 2>&1
sed 's/^/    /' "$WORK/import.log" | awk 'NR<=30'
grep -q "\[OK\] 已写入" "$WORK/import.log" && ok "客户端导入成功（走的是 node_add 的 HTTP 通路）" || bad "客户端导入失败"
SIDE=$(ls "$ROOT"/nodes/*.compat.json 2>/dev/null | awk 'NR==1')
[[ -n "$SIDE" ]] && ok "判定报告已落盘: $(basename "$SIDE")" || bad "判定报告缺失"
python3 - "$SIDE" <<'PYS' | sed 's/^/    /'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("engine=%s target=%s counts=%s" % (d["engine"], (d["target"] or {}).get("version"), d["counts"]))
PYS

# ---------------------------------------------------------------- 2b
hdr "2b. 分享链接 (URI) 列表通路: 走 compat 的 parse_uri（保真最高）"
URIURL="http://127.0.0.1:$TUNNEL_PORT/uris.txt"
uc=$(curl -s -o "$WORK/uris.txt" -w '%{http_code}' --max-time 10 "$URIURL")
if [[ "$uc" == 200 && -s "$WORK/uris.txt" ]]; then
    ok "从 RN 拉到真实分享链接列表 ($(wc -l <"$WORK/uris.txt") 条 URI)"
    SRC="$SRC" CLI_ROOT="$ROOT" PORT_MIXED="$MIXED" PORT_CTRL="$CTRL" BIND_ADDR=127.0.0.1 \
    CLI_BIN="$MIHOMO" CLI_SERVICE=mvm-nothing bash -c '
        source "$SRC/client.sh"
        CLI_CONF="$CLI_ROOT/conf"; CLI_PROVIDERS="$CLI_CONF/providers"
        CLI_NODES="$CLI_ROOT/nodes"; CLI_UI="$CLI_ROOT/ui"
        CLI_SUBS="$CLI_ROOT/subscriptions.json"; CLI_SERVICE=mvm-nothing
        node_add
    ' <<< "$(printf '%s\n\n\n' "$URIURL")" >"$WORK/import-uri.log" 2>&1
    sed 's/^/    /' "$WORK/import-uri.log" | awk 'NR>=1 && NR<=20'
    grep -q "\[OK\] 已写入" "$WORK/import-uri.log" && ok "URI 列表导入成功" || bad "URI 列表导入失败"
    URISIDE=$(ls "$ROOT"/nodes/*.compat.json 2>/dev/null | grep -v "$(basename "$SIDE")" | awk 'NR==1')
    if [[ -n "$URISIDE" ]]; then
        ok "URI 通路的判定报告: $(basename "$URISIDE")"
        # I1: 原始字符串必须一字节不改 —— 与 RN 上那份逐行比对
        python3 - "$URISIDE" "$WORK/uris.txt" <<'PYU'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
src = set(l.strip() for l in open(sys.argv[2], encoding="utf-8") if l.strip())
got = set((n.get("raw_uri") or "").strip() for n in d["nodes"])
miss = [n["name"] for n in d["nodes"] if not n.get("raw_uri")]
print("    source_kind=%s counts=%s" % (d["source_kind"], d["counts"]))
print("    raw_uri 缺失 %d 条 | 与 RN 原文不一致 %d 条"
      % (len(miss), len(got - src)))
for n in d["nodes"]:
    print("      · %-26s 旧=%s compat=%s 合并=%s" % (n["name"][:26], n["legacy"],
                                                    n["compat_status"], n["verdict"]))
sys.exit(1 if (miss or (got - src)) else 0)
PYU
        [[ $? -eq 0 ]] && ok "I1 成立: 每条 raw_uri 与 RN 原文逐字节一致" \
                       || bad "raw_uri 与原文不一致（违反不变式 I1）"
    else
        bad "URI 通路没有产出判定报告"
    fi
else
    bad "拉取 RN 分享链接列表失败 HTTP $uc"
fi

hdr "2c. 分享链接通路（修正版: 去掉 &obfs=none）—— 用于真正测出逐节点连通性"
FIXURL="http://127.0.0.1:$TUNNEL_PORT/uris-fixed.txt"
fc=$(curl -s -o "$WORK/uris-fixed.txt" -w '%{http_code}' --max-time 10 "$FIXURL")
if [[ "$fc" == 200 && -s "$WORK/uris-fixed.txt" ]]; then
    ok "拉到修正版链接列表 ($(wc -l <"$WORK/uris-fixed.txt") 条)"
    SRC="$SRC" CLI_ROOT="$ROOT" PORT_MIXED="$MIXED" PORT_CTRL="$CTRL" BIND_ADDR=127.0.0.1 \
    CLI_BIN="$MIHOMO" CLI_SERVICE=mvm-nothing bash -c '
        source "$SRC/client.sh"
        CLI_CONF="$CLI_ROOT/conf"; CLI_PROVIDERS="$CLI_CONF/providers"
        CLI_NODES="$CLI_ROOT/nodes"; CLI_UI="$CLI_ROOT/ui"
        CLI_SUBS="$CLI_ROOT/subscriptions.json"; CLI_SERVICE=mvm-nothing
        node_add
    ' <<< "$(printf '%s\n\n\n' "$FIXURL")" >"$WORK/import-uri2.log" 2>&1
    grep -q "\[OK\] 已写入" "$WORK/import-uri2.log" && ok "修正版导入成功" || bad "修正版导入失败"
else
    bad "拉取修正版链接列表失败 HTTP $fc"
fi

# ---------------------------------------------------------------- 3
hdr "3. 逐节点三列对照: 旧判定 vs compat vs 真实连通性"
SRC="$SRC" CLI_ROOT="$ROOT" PORT_MIXED="$MIXED" PORT_CTRL="$CTRL" BIND_ADDR=127.0.0.1 \
CLI_BIN="$MIHOMO" CLI_SERVICE=mvm-nothing bash -c '
    source "$SRC/client.sh"
    gen_config && cfg_check
' >"$WORK/gen.log" 2>&1
grep -q "test is successful" "$WORK/gen.log" && ok "gen_config + 内核 -t 全通过" || { bad "配置生成/校验失败"; dump "$WORK/gen.log"; }
# 端口以**内核真正写进配置的那两个**为准: gen_config 发现占用会顺延并落盘,
# 拿命令行那个值去 curl 就会打到别人身上（本项目踩过这个坑）。
if [[ -f "$ROOT/settings.env" ]]; then
    MIXED=$(sed -n 's/^PORT_MIXED="\(.*\)"$/\1/p' "$ROOT/settings.env")
    CTRL=$(sed -n 's/^PORT_CTRL="\(.*\)"$/\1/p' "$ROOT/settings.env")
fi
note "协商后的端口: mixed=$MIXED ctrl=$CTRL"

"$MIHOMO" -d "$ROOT/conf" >"$WORK/run.log" 2>&1 &
SVPID=$!
sleep 6
if kill -0 "$SVPID" 2>/dev/null; then
    OURD=$(tr '\0' ' ' <"/proc/$SVPID/cmdline" 2>/dev/null)
    case "$OURD" in
        *"$ROOT/conf"*) ok "独立内核实例已起 (pid=$SVPID, -d $ROOT/conf)" ;;
        *) bad "pid $SVPID 不是我们的实例: $OURD" ;;
    esac
else
    bad "内核启动失败"; dump "$WORK/run.log"
fi
SECRET=$(cat "$ROOT/.secret" 2>/dev/null)
# provider 是**异步**加载的: 内核刚起来时分组里的 all 还是空的, 这时去选节点
# 一律失败（而且是静默的）。等分组里真的出现节点再开始。
_prev=-1; _stable=0; _n=0
for _i in $(seq 1 40); do
    _n=$(curl -s -m 5 -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$CTRL/proxies" \
         | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["proxies"]
except Exception:
    print(0); raise SystemExit
print(sum(len(v.get("all") or []) for k,v in d.items()
          if v.get("type")=="Selector" and k!="GLOBAL"))' 2>/dev/null)
    if [[ -n "$_n" && "$_n" == "$_prev" && "$_n" -gt 0 ]]; then
        _stable=$((_stable + 1))
        [[ "$_stable" -ge 3 ]] && break
    else
        _stable=0
    fi
    _prev="$_n"
    sleep 1
done
note "分组里可见节点数: ${_n:-0}（连续 3 次不再变化才继续 —— provider 是异步加载的）"
ac=$(curl -s -o /dev/null -w '%{http_code}' -m 8 -H "Authorization: Bearer $SECRET" \
     "http://127.0.0.1:$CTRL/version")
[[ "$ac" == 200 ]] && ok "控制 API 认我们的 secret (HTTP 200 @ $CTRL)" \
                   || bad "控制 API 不认我们的 secret (HTTP $ac @ $CTRL) —— 可能连到了别的实例"

# 两条通路各一份 sidecar, 各自跑一遍矩阵 —— 合起来才覆盖"能拿到的全部协议"。
rm -f "$WORK"/matrix*.tsv "$WORK"/matrix*.err
_mi=0
for _side in "$ROOT"/nodes/*.compat.json; do
    [[ -f "$_side" ]] || continue
    _mi=$((_mi + 1))
    _prov="$ROOT/conf/providers/$(basename "$_side" .compat.json).yaml"
    python3 - "$_side" "http://127.0.0.1:$CTRL" "$SECRET" "$MIXED" "$_prov" \
        "$ROOT/conf/config.yaml" \
        >"$WORK/matrix$_mi.tsv" 2>"$WORK/matrix$_mi.err" <<'PYC'
import json, os, re, subprocess, sys, time, urllib.parse, urllib.request
import yaml

side, api, secret, mixed, prov_file, conf_file = sys.argv[1:7]
recs = json.load(open(side, encoding="utf-8"))["nodes"]
H = {"Authorization": "Bearer " + secret}
TEST = "http://www.gstatic.com/generate_204"


def get(path, timeout=15):
    with urllib.request.urlopen(
            urllib.request.Request(api + path, headers=H), timeout=timeout) as r:
        return json.load(r)


def put(path, obj, timeout=15):
    req = urllib.request.Request(api + path, data=json.dumps(obj).encode(),
                                 headers=dict(H, **{"Content-Type": "application/json"}),
                                 method="PUT")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status


allp = get("/proxies").get("proxies") or {}
groups = [n for n, v in allp.items() if v.get("type") == "Selector" and n != "GLOBAL"]


FLAG = re.compile("[\U0001F1E6-\U0001F1FF]{2}")


def _body(name):
    """去掉地区旗帜, 得到节点的"身份"部分。"""
    s = (name or "").strip()
    m = FLAG.match(s)
    return s[m.end():].lstrip() if m else s


# ---- provider → 组名 / 组内真实节点名: 从**产物本身**读出来, 不猜 ----
#
# 判定报告里记的是**导入那一刻**的节点名; 之后 node_add 会给组内节点加
# `<订阅名>-` 前缀（同名服务器要分得开）。而"哪个组对应哪个 provider"更是
# 生成配置时才算出来的。这两件事都能从产物里**精确**读出来:
#   * 组名     ← conf/config.yaml 的 proxy-groups 里 use: [<provider>] 那一条
#   * 节点名   ← providers/<provider>.yaml 本体（YAML 型读 proxies[].name,
#               URI 型读 `#` 片段 —— 前缀就是加在片段里的）
# 早先版本靠"按名字全局猜", 结果是同一个名字存在于两个 provider 时选错组,
# 矩阵把别的节点的连通性当成本节点的结果（静默假通过）。
PROV = os.path.basename(prov_file)[:-5] if prov_file.endswith(".yaml") else prov_file

GROUP = None
try:
    _cfg = yaml.safe_load(open(conf_file, encoding="utf-8")) or {}
    for _g in _cfg.get("proxy-groups") or []:
        if PROV in (_g.get("use") or []):
            GROUP = _g.get("name")
            break
except Exception as _e:
    print("group-lookup failed: %r" % (_e,), file=sys.stderr)

ALL_OF_GROUP = []
NAMES = []
try:
    _raw = open(prov_file, encoding="utf-8").read()
    try:
        _d = yaml.safe_load(_raw)
    except Exception:
        _d = None
    if isinstance(_d, dict) and isinstance(_d.get("proxies"), list):
        NAMES = [n.get("name") for n in _d["proxies"] if isinstance(n, dict)]
    else:
        for _l in _raw.splitlines():
            _s = _l.strip()
            if _s and not _s.startswith("#") and "#" in _s:
                NAMES.append(urllib.parse.unquote(_s.split("#", 1)[1]))
except Exception as _e:
    print("names-lookup failed: %r" % (_e,), file=sys.stderr)
print("provider=%r group=%r names=%d" % (PROV, GROUP, len(NAMES)), file=sys.stderr)
# 诊断: provider 文件里有 N 个名字, 组里实际可见 M 个 —— 差集就是内核自己没接住的
try:
    _alls = get("/proxies/" + urllib.parse.quote(GROUP)).get("all") or [] if GROUP else []
    _missing = [n for n in NAMES if n not in _alls]
    ALL_OF_GROUP = _alls
    print("group_all=%d / provider_names=%d; 组里没有的: %r"
          % (len(_alls), len(NAMES), _missing[:8]), file=sys.stderr)
except Exception as _e:
    print("group-dump failed: %r" % (_e,), file=sys.stderr)


def _body(name):
    """去掉地区旗帜, 得到节点的"身份"部分。"""
    s = (name or "").strip()
    m = FLAG.match(s)
    return s[m.end():].lstrip() if m else s


def resolve(node):
    """判定报告里的名字 → provider 里真实存在的节点名（先精确, 再去前缀）。"""
    if node in NAMES:
        return node
    want = _body(node)
    hit = [c for c in NAMES if _body(c) == want]
    if not hit:
        hit = [c for c in NAMES if _body(c).endswith(want)]
    return sorted(hit, key=len)[0] if hit else node


def pick(node):
    """把出网路径真正切到目标节点上, 并**读回校验整条链**。

    ★ 出网链是 PROXY → <该 provider 的组> → 节点。只把叶子组设成目标节点
      **不算数**: PROXY 默认停在 AUTO（一个跨全部节点的 url-test 组）, 流量
      根本不经过叶子组 —— 矩阵会打印"每个节点都 204", 而实际走的一直是同一个
      节点。这是本项目最怕的静默假通过, 所以两段都要设、都要读回。
    """
    target = resolve(node)
    if not GROUP:
        print("PICKFAIL %r: 找不到 provider %r 对应的组" % (node, PROV), file=sys.stderr)
        return "UNSELECTED", target
    why = []
    # 1) 叶子组 → 目标节点
    try:
        put("/proxies/" + urllib.parse.quote(GROUP), {"name": target})
    except Exception as e:
        why.append("leaf-put=%s" % (str(e)[:26],))
    # 2) PROXY → 该叶子组（这才是"流量真的走这条链"的一步）
    try:
        put("/proxies/PROXY", {"name": GROUP})
    except Exception as e:
        why.append("proxy-put=%s" % (str(e)[:26],))
    # 3) 两段都读回
    try:
        leaf = get("/proxies/" + urllib.parse.quote(GROUP))
        if leaf.get("now") != target:
            why.append("leaf.now=%r" % (str(leaf.get("now"))[:20],))
    except Exception as e:
        why.append("leaf-get=%s" % (str(e)[:26],))
    try:
        top = get("/proxies/PROXY")
        if top.get("now") != GROUP:
            why.append("PROXY.now=%r" % (str(top.get("now"))[:20],))
    except Exception as e:
        why.append("proxy-get=%s" % (str(e)[:26],))
    if not why:
        return "ok", target
    print("PICKFAIL %r -> %r (组 %r) :: %s"
          % (node, target, GROUP, " | ".join(why)), file=sys.stderr)
    return "UNSELECTED", target


def curl_proxy(url, timeout=15):
    p = subprocess.run(["curl", "-s", "-o", "/dev/null",
                        "-w", "%{http_code} %{time_total}",
                        "-x", "http://127.0.0.1:" + mixed,
                        "--max-time", str(timeout), url],
                       capture_output=True, text=True)
    parts = (p.stdout or "").split()
    # 连不上时 curl 会打 "000 0.000000"; 极端情况下是空串 —— 都兜底成两位
    return (parts[0], parts[1]) if len(parts) >= 2 else ("000", "0")


def exit_ip(timeout=15):
    p = subprocess.run(["curl", "-s", "-x", "http://127.0.0.1:" + mixed,
                        "--max-time", str(timeout), "http://api.ipify.org"],
                       capture_output=True, text=True)
    return (p.stdout or "").strip()


# "组里有节点"还不够: provider 加载失败时组里会剩一个 COMPATIBLE 占位项。
# 真正要看的是"provider 文件里的名字有没有出现在组里"。
_loaded = [n for n in NAMES if n in ALL_OF_GROUP]
if not _loaded:
    # 内核一个节点都没加载出来 —— 这是**发现**, 不是"矩阵跑失败"。
    # 绝不能产出"看起来正常"的行（那正是静默假通过）。
    print("GROUP_EMPTY provider=%r group=%r names=%d 组内可见=%r"
          % (PROV, GROUP, len(NAMES), ALL_OF_GROUP[:3]), file=sys.stderr)
    raise SystemExit(0)
print("legacy\tcompat\tmerged\tsource\treal_http\treal_time\texit_ip\tlosses"
      "\tselected\tname\tconfig_name")
for r in recs:
    sel, actual = pick(r["name"])
    if sel != "ok":
        time.sleep(1.0)
        sel, actual = pick(r["name"])
    time.sleep(0.3)
    code, tt = curl_proxy(TEST)
    ip = exit_ip() if code[:1] == "2" else ""
    print("\t".join([str(r["legacy"]), str(r["compat_status"]), str(r["verdict"]),
                     str(r["verdict_source"]), code, tt, ip or "-",
                     str(len(r["losses"])), sel, r["name"], actual]))
PYC
    if grep -q GROUP_EMPTY "$WORK/matrix$_mi.err" 2>/dev/null; then
        find_ "provider `$(basename "$_side" .compat.json)` 内核**一个节点都没加载出来**（客户端却打印了"已写入 N 个节点"）"
        grep -E "GROUP_EMPTY|group_all=" "$WORK/matrix$_mi.err" | sed 's/^/      /'
        grep -oE "initial proxy provider [^\"]*" "$WORK/run.log" 2>/dev/null | sort -u | awk 'NR<=3' | sed 's/^/      内核: /'
    elif [[ -s "$WORK/matrix$_mi.err" ]]; then
        note "$(basename "$_side") 的矩阵脚本 stderr:"; dump "$WORK/matrix$_mi.err"
    fi
done
if ls "$WORK"/matrix*.tsv >/dev/null 2>&1 && \
   [[ $(cat "$WORK"/matrix*.tsv 2>/dev/null | wc -l) -gt 2 ]]; then
    python3 - "$WORK" <<'PYT'
import csv, glob, os, sys
work = sys.argv[1]
total = 0
for f in sorted(glob.glob(os.path.join(work, "matrix*.tsv"))):
    rows = list(csv.DictReader(open(f, encoding="utf-8"), delimiter="\t"))
    if not rows:
        continue
    print("    ── %s（%d 个节点）──" % (os.path.basename(f), len(rows)))
    print("    %-28s %-20s %-19s %-9s %-6s %-11s %s"
          % ("节点", "旧判定", "compat", "合并", "真实", "选择", "出口 IP"))
    for r in rows:
        real = r["real_http"][:3]
        flag = "✅" if real in ("200", "204") else ("·" if real == "000" else "✗")
        sel = r.get("selected", "?")
        mark = "OK" if sel == "ok" else "⚠" + sel
        ren = "" if r.get("config_name") in (None, "", r["name"]) else "  (配置名: %s)" % r["config_name"]
        print("    %-28s %-20s %-19s %-9s %s %-4s %-11s %s%s"
              % (r["name"][:28], r["legacy"], r["compat"], r["merged"], flag, real,
                 mark, r["exit_ip"], ren))
    total += len(rows)
print("    " + "-" * 104)
print("    合计 %d 个节点（两条通路）" % total)
PYT
    ok "逐节点真实连通性已实测（$(cat "$WORK"/matrix*.tsv | wc -l) 行数据）"
else
    bad "连通性矩阵为空 —— 下面的结论无从谈起"
fi

# ---------------------------------------------------------------- 4
hdr "4. 假 UNSUPPORTED / 退步 / 多判出 判定"
if ls "$WORK"/matrix*.tsv >/dev/null 2>&1 && \
   [[ $(cat "$WORK"/matrix*.tsv 2>/dev/null | wc -l) -gt 2 ]]; then
python3 - "$WORK" <<'PYD'
import csv, glob, os, sys
rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "matrix*.tsv"))):
    rows += list(csv.DictReader(open(f, encoding="utf-8"), delimiter="\t"))
unsel = [r for r in rows if r.get("selected") not in (None, "", "ok")]
if unsel:
    print("    ⛔ %d 个节点的选择没生效 —— 它们的真实连通性数字不作数: %s"
          % (len(unsel), [r["name"][:22] for r in unsel]))
fake_uns, relaxed, tighten, wins, hidden_fail = [], [], [], [], []
for r in rows:
    real = r["real_http"][:3]
    conn = real in ("200", "204")
    if r["merged"] == "UNSUPPORTED" and conn:
        fake_uns.append(r)                     # 判死但真能连 = 假 UNSUPPORTED
    if r["legacy"] == "UNSUPPORTED" and r["merged"] != "UNSUPPORTED":
        relaxed.append(r)                      # 静默放宽（保险丝失效）
    if r["legacy"] in ("SUPPORTED", "SUPPORTED_WITH_LOSS") and r["merged"] != "SUPPORTED":
        tighten.append(r)
        if not conn:
            wins.append(r)                     # compat 收紧 且 真连不通 = 判对了
    if r["merged"] in ("SUPPORTED", "SUPPORTED_WITH_LOSS") and not conn:
        hidden_fail.append(r)                  # 两边都说能用但连不通 = 既有问题, 非本次引入
print("    收紧 %d | 其中真实连不通(compat 判对) %d | 假 UNSUPPORTED %d | 静默放宽 %d"
      % (len(tighten), len(wins), len(fake_uns), len(relaxed)))
for r in tighten:
    print("      · %s: %s → %s（真实 HTTP %s）"
          % (r["name"][:30], r["legacy"], r["merged"], r["real_http"][:3]))
for r in fake_uns:
    print("      ⛔ 假 UNSUPPORTED: %s（真实 HTTP %s）" % (r["name"], r["real_http"][:3]))
for r in relaxed:
    print("      ⛔ 静默放宽: %s" % r["name"])
if hidden_fail:
    print("    ⚠ 两边都判可用但实测连不通 %d 个（既有问题, 与本次接入无关, 逐个列出）:"
          % len(hidden_fail))
    for r in hidden_fail:
        print("      - %s（HTTP %s）" % (r["name"][:34], r["real_http"][:3]))
sys.exit(1 if (fake_uns or relaxed or unsel) else 0)
PYD
    [[ $? -eq 0 ]] && ok "无假 UNSUPPORTED、无静默放宽、无选择失效" \
                   || bad "存在假 UNSUPPORTED / 静默放宽 / 选不中的节点"
else
    bad "矩阵为空, 本节不成立"
fi

# ---------------------------------------------------------------- 5
hdr "5. compat 的具体主张: 逐条真机验证（只改一个变量）"
# 主张 1: mihomo 不校验 network, 未知值静默按 tcp → 用 kcp/乱写值打同一个服务端
# 主张 2: ws 分支的 TLSConfig 不含 Reality → ws+reality 里 reality 静默不启用
# 主张 3: 有 reality-opts 但缺 client-fingerprint → 配置层过、拨号才失败
rm -rf "$WORK/exp"; mkdir -p "$WORK/exp"
python3 - "$ROOT/conf/providers" "$WORK/exp" <<'PYE'
import glob, json, os, sys, yaml
prov, out = sys.argv[1], sys.argv[2]
nodes = []
for f in glob.glob(prov + "/*.yaml"):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception:
        continue
    # ⚠ provider 目录下可能混着**分享链接列表**（纯文本, safe_load 会返回 str）
    #   —— 那是另一条通路, 不是 dict。直接 .get() 会 AttributeError。
    if isinstance(d, dict):
        nodes += d.get("proxies") or []
real = next((n for n in nodes
             if n.get("reality-opts") and n.get("network") in (None, "tcp")), None)
if real is None:
    print("NO_REALITY_NODE"); sys.exit(0)
base = json.dumps(real, ensure_ascii=False, sort_keys=True)


def emit(name, mutate):
    n = json.loads(base); n["name"] = "exp-" + name
    mutate(n)
    yaml.safe_dump({"proxies": [n]}, open(os.path.join(out, name + ".yaml"), "w"),
                   sort_keys=False, allow_unicode=True)


emit("ctrl-baseline", lambda n: None)
def _kcp(n):
    n["network"] = "kcp"
    n["mkcp-opts"] = {"header": {"type": "none"}, "seed": "experiment-seed"}
emit("net-kcp", _kcp)
emit("net-bogus", lambda n: n.update({"network": "totally-bogus-net"}))
def _wsr(n):
    n["network"] = "ws"; n["ws-opts"] = {"path": "/ws"}
emit("ws-plus-reality", _wsr)
emit("reality-no-fingerprint", lambda n: n.pop("client-fingerprint", None))
print("OK")
PYE
if [[ -f "$WORK/exp/reality-no-fingerprint.yaml" ]]; then
    ok "实验节点已从真实节点派生（基线 + 4 个只改一个变量的变体）"
else
    note "本批真实订阅里没有 tcp+reality 节点"
    bad "实验节点没能派生出来 —— 这三条主张就没被验证（不算通过）"
fi

cat > "$WORK/exp_one.py" <<'PYX'
import json, os, shutil, subprocess, sys, time, yaml
nodefile, name, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = "/tmp/mvm/exp/" + name
shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
node = (yaml.safe_load(open(nodefile, encoding="utf-8")) or {}).get("proxies")[0]
yaml.safe_dump({"mixed-port": port, "external-controller": "127.0.0.1:0",
                "log-level": "warning", "proxies": [node],
                "proxy-groups": [{"name": "P", "type": "select", "proxies": [node["name"]]}],
                "rules": ["MATCH,P"]},
               open(os.path.join(d, "config.yaml"), "w"), sort_keys=False, allow_unicode=True)
b = os.environ["MIHOMO_BIN"]
t = subprocess.run([b, "-t", "-d", d], capture_output=True, text=True)
cfg_ok = "successful" in (t.stdout + t.stderr).lower()
p = subprocess.Popen([b, "-d", d], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(5)
r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                    "-x", "http://127.0.0.1:%d" % port, "--max-time", "20",
                    "http://www.gstatic.com/generate_204"], capture_output=True, text=True)
p.terminate()
try:
    p.wait(timeout=5)
except Exception:
    p.kill()
print(json.dumps({"case": name, "config_ok": cfg_ok,
                  "real_http": (r.stdout or "000").strip()}, ensure_ascii=False))
PYX
EXP_PORT=$(pick_port)
for case in ctrl-baseline net-kcp net-bogus ws-plus-reality reality-no-fingerprint; do
    [[ -f "$WORK/exp/$case.yaml" ]] || continue
    MIHOMO_BIN="$MIHOMO" python3 "$WORK/exp_one.py" "$WORK/exp/$case.yaml" "$case" "$EXP_PORT" \
        2>&1 | sed 's/^/    /'
done

# ---------------------------------------------------------------- 5b
hdr "5b. 真机对照: 同一个 trojan+REALITY 节点, 链接形态 vs YAML 形态"
# compat 有一条**只对 mihomo 生效**的 URI 表达力规则:
#   uri.trojan.reality@mihomo —— mihomo 的 trojan 链接解析器不读 pbk/sid,
#   于是"经过链接导入"和"经过 YAML 导入"是**两个结果**。
# 这条正好落在 M 客户端新增的分享链接通路上, 所以必须真机对照, 不能只信规则。
mkdir -p "$WORK/tr"
URI_LINE=$(grep -m1 '^trojan://' "$WORK/uris.txt" 2>/dev/null || true)
if [[ -n "$URI_LINE" ]]; then
    printf '%s\n' "$URI_LINE" > "$WORK/tr/raw-uri.txt"
    # RN 的 out/*_share-*.txt 与 out/*_client-*.yaml 可能是**不同批次**的产物
    # （实测端口就不一样）。所以不按 server:port 配对, 按**节点名**配对, 再把
    # 链接的 host:port 改写成 YAML 对端的 —— 这样唯一的变量就只剩"导入形态"。
    python3 - "$WORK/tr/raw-uri.txt" "$ROOT/conf/providers" "$WORK/tr" <<'PYR'
import glob, os, sys, urllib.parse, yaml
uri = open(sys.argv[1], encoding="utf-8").read().strip()
frag = urllib.parse.unquote(uri.split("#", 1)[1]) if "#" in uri else ""
body = frag.strip()
for c in ("\U0001F1E6",):
    pass
import re
FLAG = re.compile("[\U0001F1E6-\U0001F1FF]{2}")
m = FLAG.match(body)
if m:
    body = body[m.end():].lstrip()
peer = None
for f in glob.glob(sys.argv[2] + "/*.yaml"):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    for n in d.get("proxies") or []:
        nm = n.get("name") or ""
        mm = FLAG.match(nm)
        b = nm[mm.end():].lstrip() if mm else nm
        # 对端名也可能带客户端加的 <tag>- 前缀（生成配置时才加的），两种都认
        if (n.get("type") == "trojan" and n.get("reality-opts")
                and (b == body or b.endswith(body))):
            peer = n
if peer is None:
    print("    NO_YAML_PEER (同名的 YAML trojan+reality 节点没找到)")
    sys.exit(0)
# 把链接指到同一个活着的 server:port 上
u = urllib.parse.urlsplit(uri)
host = peer["server"] if ":" not in str(peer["server"]) else "[%s]" % peer["server"]
fixed = urllib.parse.urlunsplit(
    (u.scheme, u.username and (u.username + (":" + u.password if u.password else "") +
                               "@" + host + ":" + str(peer["port"])) or u.netloc,
     u.path, u.query, u.fragment))
open(os.path.join(sys.argv[3], "one-uri.txt"), "w", encoding="utf-8").write(fixed + "\n")
yaml.safe_dump({"proxies": [dict(peer, name="exp-trojan-yaml")]},
               open(os.path.join(sys.argv[3], "one-yaml.yaml"), "w"),
               sort_keys=False, allow_unicode=True)
print("    配对: 链接原文 %s:%s  ←→  YAML %r %s:%s (reality-opts=%s)"
      % (u.hostname, u.port, peer["name"], peer["server"], peer["port"],
         bool(peer.get("reality-opts"))))
if str(u.port) != str(peer["port"]):
    print("    ⚠ 两者端口不同 —— RN 的 out/*_share-*.txt 与 out/*_client-*.yaml 不是同一批次"
          "（P-M3 那类产物过期）; 下面把链接改写到对端的活端口, 让变量只剩\"导入形态\"")
PYR
    if [[ -f "$WORK/tr/one-uri.txt" && -f "$WORK/tr/one-yaml.yaml" ]]; then
        for _case in uri yaml; do
            _f="$WORK/tr/one-$_case.txt"; [[ "$_case" == "yaml" ]] && _f="$WORK/tr/one-yaml.yaml"
            _p=$(pick_port)
            MIHOMO_BIN="$MIHOMO" python3 - "$_f" "$_case" "$_p" <<'PYX' 2>&1 | sed 's/^/    /'
import os, shutil, subprocess, sys, time, yaml
src, kind, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = "/tmp/mvm/tr/" + kind
shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
txt = open(src, encoding="utf-8").read()
cfg = {"mixed-port": port, "external-controller": "127.0.0.1:0", "log-level": "info",
       "rules": ["MATCH,P"]}
if kind == "yaml":
    node = dict((yaml.safe_load(txt) or {}).get("proxies")[0]); node["name"] = "N"
    cfg["proxies"] = [node]
    cfg["proxy-groups"] = [{"name": "P", "type": "select", "proxies": ["N"]}]
else:
    # 走 URI 形态: 与客户端给内核的输入**逐字节相同**（provider 文件）
    pdir = os.path.join(d, "prov"); os.makedirs(pdir)
    with open(os.path.join(pdir, "u.txt"), "w", encoding="utf-8") as fh:
        fh.write(txt if txt.endswith("\n") else txt + "\n")
    cfg["proxy-providers"] = {"u": {"type": "file", "path": pdir + "/u.txt",
                                    "health-check": {"enable": False}}}
    cfg["proxy-groups"] = [{"name": "P", "type": "select", "use": ["u"]}]
with open(os.path.join(d, "config.yaml"), "w") as fh:
    yaml.safe_dump(cfg, fh, sort_keys=False, allow_unicode=True)
b = os.environ["MIHOMO_BIN"]
t = subprocess.run([b, "-t", "-d", d], capture_output=True, text=True)
cfg_ok = "successful" in (t.stdout + t.stderr).lower()
lg = open(os.path.join(d, "run.log"), "w")
pr = subprocess.Popen([b, "-d", d], stdout=lg, stderr=subprocess.STDOUT)
time.sleep(6)
r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                    "-x", "http://127.0.0.1:%d" % port, "--max-time", "20",
                    "http://www.gstatic.com/generate_204"], capture_output=True, text=True)
pr.terminate()
try:
    pr.wait(timeout=5)
except Exception:
    pr.kill()
lg.close()
log = open(os.path.join(d, "run.log"), encoding="utf-8", errors="replace").read()
print("形态=%-4s config_ok=%-5s 真实HTTP=%-4s 日志出现 REALITY 行=%d"
      % (kind, cfg_ok, (r.stdout or "000").strip(),
         sum(1 for line in log.splitlines() if "REALITY" in line.upper())))
PYX
        done
        ok "trojan+REALITY 的两种导入形态已真机对照（结论见报告）"
    else
        note "配对失败, 对照跳过"
        bad "trojan+REALITY 对照没做成（这条规则正落在分享链接通路上, 必须验）"
    fi
else
    note "本批分享链接里没有 trojan://, 对照跳过"
fi

# ---------------------------------------------------------------- 6
hdr "6. 一键回滚开关"
RB_MIXED=$(pick_port); RB_CTRL=$(pick_port)
SRC="$SRC" CLI_ROOT="$WORK/cli-rb" PORT_MIXED="$RB_MIXED" PORT_CTRL="$RB_CTRL" \
BIND_ADDR=127.0.0.1 CLI_BIN="$MIHOMO" CLI_SERVICE=mvm-nothing \
MH_COMPAT_ENGINE=legacy bash "$WORK/import.sh" "$WORK/sub_pull.yaml" rollback \
    >"$WORK/rollback.log" 2>&1
if grep -q "引擎: legacy" "$WORK/rollback.log"; then
    ok "MH_COMPAT_ENGINE=legacy 生效（判定引擎=legacy, compat 完全不参与）"
else
    bad "回滚开关未生效"; dump "$WORK/rollback.log"
fi
if [[ -f "$WORK/cli-rb/nodes/rollback.compat.json" ]]; then
    python3 - "$WORK/cli-rb/nodes/rollback.compat.json" <<'PYR'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
bad = [n for n in d["nodes"] if n["verdict"] != n["legacy"] or n["compat_status"]]
print("    回滚后: %d 个节点, 判定与旧判定不一致的 %d 个" % (len(d["nodes"]), len(bad)))
sys.exit(1 if bad else 0)
PYR
    [[ $? -eq 0 ]] && ok "回滚后判定与接入前逐条一致" || bad "回滚后仍有 compat 参与"
else
    bad "回滚用例没有产出判定报告"
fi

# ---------------------------------------------------------------- 7
hdr "7. 客户端原有功能未受影响"
SRC="$SRC" CLI_ROOT="$ROOT" PORT_MIXED="$MIXED" PORT_CTRL="$CTRL" BIND_ADDR=127.0.0.1 \
CLI_BIN="$MIHOMO" CLI_SERVICE=mvm-nothing bash -c '
    source "$SRC/client.sh"
    python3 "$CLI_LIB/validate.py" --conf "$CLI_CONF" >/dev/null 2>&1 && echo STRICT_OK || echo STRICT_FAIL
    node_list
    node_test
' >"$WORK/list.log" 2>&1
grep -q STRICT_OK "$WORK/list.log" && ok "严格字段校验通过" || bad "严格字段校验失败"
sed -n '/已导入的节点/,$p' "$WORK/list.log" | sed 's/^/    /' | awk 'NR<=14'
errs=$(grep -ci "level=error\|level=fatal" "$WORK/run.log" 2>/dev/null || echo 0)
[[ "$errs" == "0" ]] && ok "内核实例无 error/fatal 日志" || note "内核日志有 $errs 条 error/fatal"

printf "\n\033[1m结果\033[0m\n"
printf "  \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m / \033[33m%d 项既有缺陷发现\033[0m\n" \
       "$PASS" "$FAIL" "$FIND"
exit $((FAIL > 0))
