#!/usr/bin/env bash
# 并发防双花测试: N 个并发请求抢 1 次额度, 必须恰好 1 个成功
set -uo pipefail
ROOT=/root/catmi/mihomo
SHARE=$ROOT/share
SHARES=$SHARE/shares
PORT=9443
BASE="http://127.0.0.1:$PORT"
N=${1:-8}
MAXU=${2:-1}
rm -rf "$SHARES"; mkdir -p "$SHARES"

export SHARE_DIR=$SHARE OUT_DIR=$ROOT/out SHARE_PORT=$PORT BUILD_SUB=$SHARE/build_sub.py
python3 "$SHARE/share_server.py" >/tmp/share_conc.log 2>&1 &
SPID=$!
sleep 3

TOK=$(openssl rand -hex 16)
python3 -c '
import json,sys
json.dump({"share_token":sys.argv[1],"tag":"all","created_at":0,"expires_at":0,
 "max_uses":int(sys.argv[2]),"used_count":0,"enabled":True,"last_used_at":0},
 open(sys.argv[3]+"/"+sys.argv[1]+".json","w"),indent=1)' "$TOK" "$MAXU" "$SHARES"

rm -f /tmp/conc.txt
for i in $(seq 1 "$N"); do
  ( curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 "$BASE/share/$TOK" ) &
done >> /tmp/conc.txt
wait

n200=$(grep -c '^200$' /tmp/conc.txt || true)
n410=$(grep -c '^410$' /tmp/conc.txt || true)
used=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["used_count"])' "$SHARES/$TOK.json")

echo "并发 $N 个请求抢 max_uses=$MAXU"
echo "  200 成功: $n200   410 用尽: $n410   used_count: $used"

kill $SPID 2>/dev/null
if [[ "$used" == "$MAXU" && "$n200" == "$MAXU" ]]; then
  echo "  ✓ 无超发: 成功次数与额度完全一致"
  exit 0
else
  echo "  ✗ 超发! 额度 $MAXU 但成功 $n200 次 / 计数 $used"
  exit 1
fi