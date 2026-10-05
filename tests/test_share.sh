#!/usr/bin/env bash
# 分享服务验收测试: token / TTL / max_uses / 并发 / 注入防护
set -uo pipefail
PASS=0; FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

ROOT=/root/catmi/mihomo
SHARE=$ROOT/share
SHARES=$SHARE/shares
PORT=9443
BASE="http://127.0.0.1:$PORT"
rm -rf "$SHARES"; mkdir -p "$SHARES"

mk() { # mk <tag> <max_uses> <expires_at>
  local tok; tok=$(openssl rand -hex 16)
  python3 -c '
import json,sys
json.dump({"share_token":sys.argv[1],"tag":sys.argv[2],"created_at":0,
 "expires_at":int(sys.argv[4]),"max_uses":int(sys.argv[3]),"used_count":0,
 "enabled":True,"last_used_at":0},
 open(sys.argv[5]+"/"+sys.argv[1]+".json","w"),indent=1)' "$tok" "$1" "$2" "$3" "$SHARES"
  printf '%s' "$tok"
}

used() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["used_count"])' "$SHARES/$1.json"; }
cnt()  { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["used_count"])' "$SHARES/$1.json"; }

echo "== 启动分享服务 =="
export SHARE_DIR=$SHARE OUT_DIR=$ROOT/out SHARE_PORT=$PORT BUILD_SUB=$SHARE/build_sub.py
python3 "$SHARE/share_server.py" >/tmp/share.log 2>&1 &
SPID=$!
sleep 3
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/status")
[[ "$code" == "200" ]] && ok "/status 健康检查 200" || bad "/status 返回 $code"

echo
echo "== 一次性令牌 (max_uses=1) =="
T1=$(mk all 1 0)
c1=$(curl -s -o /tmp/s1.yaml -w '%{http_code}' --max-time 15 "$BASE/share/$T1")
[[ "$c1" == "200" ]] && ok "第 1 次拉取 200" || bad "第 1 次拉取返回 $c1"
grep -q "^proxies:" /tmp/s1.yaml && ok "响应体是合法的 proxies: YAML" || bad "响应体格式不对"
echo "    节点数: $(grep -c '^- name:\|^  - name:' /tmp/s1.yaml)"
c2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/share/$T1")
[[ "$c2" == "410" ]] && ok "第 2 次拉取 410 (额度用尽)" || bad "第 2 次拉取返回 $c2 (应为 410)"
[[ "$(cnt "$T1")" == "1" ]] && ok "used_count 恰好为 1 (先扣后发, 不多扣)" || bad "used_count=$(cnt "$T1")"

echo
echo "== 不限次数 (max_uses=0) =="
T2=$(mk all 0 0)
a=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/share/$T2")
b=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/share/$T2")
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/share/$T2")
[[ "$a$c$b" == "200200200" ]] && ok "连续 3 次均 200" || bad "结果 $a $c $b"
[[ "$(cnt "$T2")" == "3" ]] && ok "used_count=3" || bad "used_count=$(cnt "$T2")"

echo
echo "== TTL 过期 =="
NOW=$(date +%s)
T3=$(mk all 1 $((NOW - 10)))
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/share/$T3")
[[ "$c" == "410" ]] && ok "已过期令牌 410" || bad "过期令牌返回 $c"
[[ "$(cnt "$T3")" == "0" ]] && ok "过期不消耗额度" || bad "过期却扣了额度"

echo
echo "== 禁用 =="
T4=$(mk all 1 0)
python3 -c 'import json,sys;p=sys.argv[1];m=json.load(open(p));m["enabled"]=False;json.dump(m,open(p,"w"))' "$SHARES/$T4.json"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/share/$T4")
[[ "$c" == "410" ]] && ok "已禁用令牌 410" || bad "禁用令牌返回 $c"

echo
echo "== HEAD 预检不消耗额度 =="
T5=$(mk all 1 0)
c=$(curl -s -I -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/share/$T5")
[[ "$c" == "200" ]] && ok "HEAD 返回 200" || bad "HEAD 返回 $c"
[[ "$(cnt "$T5")" == "0" ]] && ok "HEAD 未消耗额度" || bad "HEAD 消耗了额度"
curl -s -o /dev/null --max-time 15 "$BASE/share/$T5"
[[ "$(cnt "$T5")" == "1" ]] && ok "随后 GET 正常扣 1 次" || bad "GET 未扣额度"

echo
echo "== 未知令牌 / 路径穿越 =="
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/share/deadbeefdeadbeef")
[[ "$c" == "404" ]] && ok "未知令牌 404" || bad "未知令牌返回 $c"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/share/..%2f..%2fetc%2fpasswd")
[[ "$c" == "404" ]] && ok "路径穿越被拒 404" || bad "路径穿越返回 $c (危险!)"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/etc/passwd")
[[ "$c" == "404" ]] && ok "任意路径 404" || bad "任意路径返回 $c"

echo
echo "== 并发双花最后一次额度 =="
T6=$(mk all 1 0)
for i in $(seq 1 8); do
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 "$BASE/share/$T6" &
done > /tmp/conc.txt
wait
n200=$(grep -c 200 /tmp/conc.txt)
n410=$(grep -c 410 /tmp/conc.txt)
if [[ "$n200" == "1" && "$n410" == "7" ]]; then
  ok "8 并发抢 1 次额度: 恰好 1 个 200 / 7 个 410"
else
  bad "8 并发抢 1 次额度: $n200 个 200 / $n410 个 410 (应各为 1/7)"
fi

kill $SPID 2>/dev/null
echo
printf "结果: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$PASS" "$FAIL"
exit $((FAIL>0))