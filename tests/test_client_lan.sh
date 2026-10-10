#!/usr/bin/env bash
# 客户端真机验收 (客户端 / arm64): 导入 服务端 拉来的订阅 → 校验 → 真实出网
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$HERE/../src}"
[[ -d "$SRC" ]] || SRC=/root/catmi/mihomo-client/src
PASS=0; FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
hdr() { printf "\n\033[1m%s\033[0m\n" "$1"; }

export CLI_ROOT=/root/catmi/mihomo-client
export CLI_BIN=$CLI_ROOT/mihomo
export PORT_MIXED=17890 PORT_CTRL=19099 BIND_ADDR=127.0.0.1
export CLI_SERVICE=mihomo-client

hdr "0. 环境"
printf "  架构: %s\n" "$(uname -m)"
printf "  内核: %s\n" "$("$CLI_BIN" -v | awk 'NR==1')"

cd "$CLI_ROOT"
# source client.sh (末尾会进菜单, 这里截断)
sed '/^\[\[ "\${BASH_SOURCE\[0\]}" == "\${0}" \]\] && client_menu$/d' "$SRC/client.sh" > /tmp/client_lib.sh
export CLI_LIB="$SRC/lib"
source /tmp/client_lib.sh

hdr "1. 导入服务端分享来的订阅"
if [[ ! -f /tmp/sub_from_rn.yaml ]]; then
    bad "缺少 /tmp/sub_from_rn.yaml (先从服务端拉取)"
else
    printf '/tmp/sub_from_rn.yaml\n' | node_add >/tmp/na.log 2>&1
    n=$(node_count)
    [[ "$n" -ge 1 ]] && ok "已导入 $n 个 provider" || { bad "导入失败"; tail -8 /tmp/na.log; }
    python3 - "$CLI_PROVIDERS" <<'PY'
import sys, glob, yaml
fs = glob.glob(sys.argv[1] + "/*.yaml")
for f in fs:
    d = yaml.safe_load(open(f)) or {}
    print("  provider 文件:", f.split("/")[-1], "节点数:", len(d.get("proxies") or []))
PY
fi

hdr "2. 配置严格校验 (arm64 内核)"
if python3 "$SRC/lib/validate.py" --conf "$CLI_CONF" >/tmp/v.log 2>&1; then
    ok "严格字段校验通过"
else
    bad "严格校验失败"; cat /tmp/v.log
fi

hdr "3. 内核校验"
"$CLI_BIN" -t -d "$CLI_CONF" 2>&1 | tail -1 | sed 's/^/    /'

hdr "4. 真实启动并出网 (经服务端上的节点)"
systemctl stop mihomo-client 2>/dev/null
"$CLI_BIN" -d "$CLI_CONF" >/tmp/cc_run.log 2>&1 &
CPID=$!
sleep 12
if kill -0 "$CPID" 2>/dev/null; then ok "客户端进程运行中"; else bad "启动失败"; tail -10 /tmp/cc_run.log; fi

S=$(cat "$CLI_ROOT/.secret" 2>/dev/null)
mem=$(curl -s -m 8 -H "Authorization: Bearer $S" "http://127.0.0.1:$PORT_CTRL/proxies/PROXY")
if printf '%s' "$mem" | grep '"all"' >/dev/null; then
    ok "PROXY 组已建立"
    printf '%s' "$mem" | python3 -c "
import sys,json
d=json.load(sys.stdin)['all']
print('  可选节点:', len(d))
for x in d: print('   -', x)
" 2>/dev/null
else
    bad "PROXY 组未建立"; tail -5 /tmp/cc_run.log
fi

hdr "5. 实际流量"
ip=$(curl -s -m 30 -x "http://127.0.0.1:$PORT_MIXED" http://api.ipify.org 2>/dev/null)
[[ -n "$ip" ]] && ok "HTTP 代理出网 → $ip" || bad "HTTP 代理无法出网"
ip2=$(curl -s -m 30 --socks5-hostname "127.0.0.1:$PORT_MIXED" http://api.ipify.org 2>/dev/null)
[[ -n "$ip2" ]] && ok "SOCKS5 代理出网 → $ip2" || bad "SOCKS5 无法出网"

hdr "6. 实际用了哪个节点"
grep -oE "using [A-Za-z]+\[[^]]+\]" /tmp/cc_run.log 2>/dev/null | sort | uniq -c | awk 'NR<=5' | sed 's/^/    /'

errs=$(grep -ci "level=fatal" /tmp/cc_run.log 2>/dev/null); errs=${errs:-0}
[[ "$errs" == "0" ]] && ok "无 fatal 日志" || { bad "有 $errs 条 fatal"; grep -i fatal /tmp/cc_run.log | awk 'NR<=3'; }

kill $CPID 2>/dev/null
hdr "结果"
printf "  \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$PASS" "$FAIL"
exit $((FAIL>0))