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
PASS=0; FAIL=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
hdr()  { printf "\n\033[1m%s\033[0m\n" "$1"; }
note() { printf "    %s\n" "$1"; }
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
echo "uri_count=$(wc -l < /tmp/mrnsub/uris.txt)"
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
    python3 - "$_side" "http://127.0.0.1:$CTRL" "$SECRET" "$MIXED" \
        >"$WORK/matrix$_mi.tsv" 2>"$WORK/matrix$_mi.err" <<'PYC'
import json, subprocess, sys, time, urllib.parse, urllib.request

side, api, secret, mixed = sys.argv[1:5]
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


def pick(node):
    """PROXY → 组 → 节点 这条链一路选中; 选不动不算错（组可能不存在）。"""
    for g in groups + ["PROXY"]:
        try:
            put("/proxies/" + urllib.parse.quote(g), {"name": node})
        except Exception:
            pass


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


print("legacy\tcompat\tmerged\tsource\treal_http\treal_time\texit_ip\tlosses\tname")
for r in recs:
    pick(r["name"])
    time.sleep(0.3)
    code, t = curl_proxy(TEST)
    ip = exit_ip() if code[:1] == "2" else ""
    print("\t".join([str(r["legacy"]), str(r["compat_status"]), str(r["verdict"]),
                     str(r["verdict_source"]), code, t, ip or "-",
                     str(len(r["losses"])), r["name"]]))
PYC
    if [[ -s "$WORK/matrix$_mi.err" ]]; then
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
    print("    %-28s %-20s %-19s %-9s %-6s %s"
          % ("节点", "旧判定", "compat", "合并", "真实", "出口 IP"))
    for r in rows:
        real = r["real_http"][:3]
        flag = "✅" if real in ("200", "204") else ("·" if real == "000" else "✗")
        print("    %-28s %-20s %-19s %-9s %s %-4s %s"
              % (r["name"][:28], r["legacy"], r["compat"], r["merged"], flag, real, r["exit_ip"]))
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
sys.exit(1 if (fake_uns or relaxed) else 0)
PYD
    [[ $? -eq 0 ]] && ok "无假 UNSUPPORTED、无静默放宽" || bad "存在假 UNSUPPORTED 或静默放宽"
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
printf "  \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$PASS" "$FAIL"
exit $((FAIL > 0))
