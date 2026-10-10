#!/usr/bin/env bash
# 客户端端到端验收: 生成配置 → 拉分享链接 → 严格校验 → 真实出网
# 用法: CLI_ROOT=/tmp/clitest bash test_client.sh
set -uo pipefail

SRC=${SRC:-/root/catmi/mihomo-core/src}      # 仓库内 src/ 位置
SRV_OUT=${SRV_OUT:-/root/catmi/mihomo/out}
export CLI_ROOT=${CLI_ROOT:-/tmp/clitest}
export PORT_MIXED=17890 PORT_CTRL=19090
SHARE_TMP=$(mktemp -d)
SHARE_PORT=9455

PASS=0; FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
hdr() { printf "\n\033[1m%s\033[0m\n" "$1"; }

trap 'kill ${SPID:-0} 2>/dev/null; rm -rf "$SHARE_TMP"' EXIT

command -v mihomo >/dev/null 2>&1 && MIHOMO=$(command -v mihomo) || MIHOMO=/root/catmi/mihomo/mihomo
export CLI_BIN="$MIHOMO"

hdr "0. 环境"
printf "  mihomo : %s\n" "$($MIHOMO -v 2>/dev/null | awk 'NR==1')"
printf "  root   : %s\n" "$CLI_ROOT"
rm -rf "$CLI_ROOT"; mkdir -p "$CLI_ROOT"

# ---- 启动一个独立的分享服务 ----
hdr "1. 启动分享服务"
cp "$SRC/share/share_server.py" "$SRC/share/build_sub.py" "$SHARE_TMP/" 2>/dev/null
export SHARE_DIR="$SHARE_TMP" OUT_DIR="$SRV_OUT" SHARE_PORT=$SHARE_PORT
export BUILD_SUB="$SHARE_TMP/build_sub.py" MIHOMO_SERVICE=mihomo
python3 "$SHARE_TMP/share_server.py" >/tmp/clitest_share.log 2>&1 &
SPID=$!
sleep 3
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SHARE_PORT/status")
[[ "$c" == 200 ]] && ok "分享服务 200" || { bad "分享服务未启动 (HTTP $c)"; head -5 /tmp/clitest_share.log; exit 1; }

# 建一个 max_uses=1 的一次性分享
TOK=$(openssl rand -hex 16)
python3 -c '
import json,sys,os
os.makedirs(sys.argv[1], exist_ok=True)
json.dump({"share_token":sys.argv[2],"tag":"all","created_at":0,"expires_at":0,
 "max_uses":1,"used_count":0,"enabled":True,"last_used_at":0},
 open(os.path.join(sys.argv[1], sys.argv[2]+".json"),"w"), indent=1)' \
 "$SHARE_TMP/shares" "$TOK"
URL="http://127.0.0.1:$SHARE_PORT/share/$TOK"
ok "一次性分享已创建 (max_uses=1)"

# ---- 客户端 ----
hdr "2. 载入客户端"
source "$SRC/client.sh"
CLI_CONF="$CLI_ROOT/conf"; CLI_PROVIDERS="$CLI_CONF/providers"
CLI_NODES="$CLI_ROOT/nodes"; CLI_BIN="$MIHOMO"; CLI_UI="$CLI_ROOT/ui"
CLI_SUBS="$CLI_ROOT/subscriptions.json"; CLI_SERVICE=clitest-nothing
BIND_ADDR=127.0.0.1
ok "client.sh 已载入"

hdr "3. 空配置也必须可用"
gen_config >/dev/null 2>&1 && ok "gen_config 成功" || bad "gen_config 失败"
cfg_check >/dev/null 2>&1 && ok "mihomo -t 通过 (无节点时回落到 DIRECT)" || bad "空配置无法通过内核校验"
python3 "$SRC/lib/validate.py" --conf "$CLI_CONF" >/tmp/v1.log 2>&1 \
    && ok "严格字段校验通过" || { bad "严格校验失败"; cat /tmp/v1.log; }

hdr "4. 从分享链接导入节点"
node_add <<< "$URL" >/tmp/nodeadd.log 2>&1
n=$(node_count)
[[ "$n" -ge 1 ]] && ok "已导入 provider: $n 个" || { bad "导入失败"; cat /tmp/nodeadd.log; }
python3 - "$CLI_PROVIDERS" <<'PY'
import sys, glob, yaml
f = glob.glob(sys.argv[1] + "/*.yaml")
d = yaml.safe_load(open(f[0]))
print(f"  导入节点数: {len(d['proxies'])}")
PY

hdr "5. 一次性令牌已被消耗 (不能再拉)"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL")
[[ "$c" == 410 ]] && ok "再次拉取 410 (额度已用)" || bad "再次拉取返回 $c (应为 410)"

hdr "6. 重新生成配置后的校验"
gen_config >/dev/null 2>&1
python3 "$SRC/lib/validate.py" --conf "$CLI_CONF" >/tmp/v2.log 2>&1 \
    && ok "严格字段校验通过" || { bad "严格校验失败"; cat /tmp/v2.log; }
cfg_check >/dev/null 2>&1 && ok "mihomo -t 通过" || { bad "内核校验失败"; }

hdr "7. 真实启动并出网"
"$MIHOMO" -d "$CLI_CONF" >/tmp/clitest_run.log 2>&1 &
CPID=$!
sleep 10
if kill -0 "$CPID" 2>/dev/null; then
    ok "客户端进程运行中"
else
    bad "客户端启动失败"; tail -10 /tmp/clitest_run.log
fi

mem=$(curl -s -m 8 "http://127.0.0.1:$PORT_CTRL/proxies/PROXY" -H "Authorization: Bearer $(cat "$CLI_ROOT/.secret" 2>/dev/null)")
if printf '%s' "$mem" | grep '"all"' >/dev/null; then
    ok "PROXY 组已建立"
    printf '%s' "$mem" | python3 -c "
import sys,json
d=json.load(sys.stdin)['all']
print('  可选节点:', len(d))
for x in d[:15]: print('   -', x)
" 2>/dev/null
else
    bad "PROXY 组未建立"; tail -5 /tmp/clitest_run.log
fi

ip=$(curl -s -m 25 -x "http://127.0.0.1:$PORT_MIXED" http://api.ipify.org 2>/dev/null)
if [[ -n "$ip" ]]; then
    ok "HTTP 代理真实出网 → $ip"
else
    bad "HTTP 代理无法出网"
fi

ip2=$(curl -s -m 25 --socks5-hostname "127.0.0.1:$PORT_MIXED" http://api.ipify.org 2>/dev/null)
[[ -n "$ip2" ]] && ok "SOCKS5 代理真实出网 → $ip2" || bad "SOCKS5 无法出网"

errs=$(grep -ci "level=error\|level=fatal" /tmp/clitest_run.log 2>/dev/null)
errs=${errs:-0}
[[ "$errs" == "0" ]] && ok "无 error/fatal 日志" || bad "日志中有 $errs 条 error/fatal"
grep -i "level=error\|level=fatal" /tmp/clitest_run.log 2>/dev/null | awk 'NR<=5'

kill $CPID 2>/dev/null
hdr "结果"
printf "  \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$PASS" "$FAIL"
exit $((FAIL>0))