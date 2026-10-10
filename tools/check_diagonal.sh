#!/usr/bin/env bash
# =============================================================
# 对角线闸门 —— **M 分享 → M 客户端** 这条链不许再断
#
# 为什么单独一道、而且必须机械可重复
# ----------------------------------
# 用户的红线原话: "我怕修着修着之后, 它自己这个就不认得啦 … 这个是最可怕的,
# 因为我那些都是印证过的。"
#
# 这不是假想 —— **已经真实发生过一次**: M 的"自己分享给自己客户端"本来是好的
# (用户验证过 19 个节点), 后来加地区旗帜命名时, build_sub.py 拿裸名台账
# (mAnyTLS01-TLS) 去等值匹配带旗帜的产物名 (🇺🇸 mAnyTLS01-TLS) → 交集 **0/19**
# → 分享订阅生成 100% 失败, 已发出的分享永远刷不动。没有任何报错指向真正原因,
# 面板只报"没有可分享的节点"。
#
# 所以本闸门把这条链**整条**跑一遍, 而且故意用"带旗帜名"和"裸名"两种输入:
#   ① 生成分享内容 (build_sub.py --conf-dir 那道过滤)  —— 踩过雷的那一步
#   ② 经 HTTP 取回 (模拟公共分享服务: 存在 + 原样返回, 字节一致)
#   ③ M 自己的客户端把它导入成 provider (client.sh 里那段真实代码)
#   ④ 真内核解析出**正确节点数** (mihomo: proxy-provider 的节点数)
#   ⑤ 至少一条**真连** (HTTP 码 + 出口 IP ≠ 本机自身 IP)
#
# ④⑤ 需要真内核与真节点, 所以是**可选层**: 设 MIHOMO_BIN 才有 ④; 再设
# M_DIAG_REAL_LINK=<含真实分享链接的文件> 才有 ⑤。本机没有内核时这两层明确
# 报"跳过"(不算失败) —— 但闸门本身在任何机器上都必须能跑, 不许因为缺内核而
# 变成"永远红"或"静默假绿"。
#
# 用法:
#   bash tools/check_diagonal.sh
#   MIHOMO_BIN=/root/catmi/mihomo-client/mihomo \
#   M_DIAG_REAL_LINK=/tmp/real_links.txt bash tools/check_diagonal.sh
# =============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$(pwd)"

PASS=0; FAIL=0; SKIP=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31m❌\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
skip() { printf "  \033[33m⊘\033[0m %s\n" "$1"; SKIP=$((SKIP+1)); }

TMP=$(mktemp -d /tmp/.m-diag-XXXXXX)
trap 'rm -rf "$TMP"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null' EXIT

FLAG="🇺🇸"
N=3

# ---- 夹具: 三种命名组合 (flag=产物带旗帜, bare=裸名) ----
mk_case() { # <目录> <台账命名: flag|bare> <产物命名: flag|bare>
    local d="$1" mgn="$2" art="$3"
    mkdir -p "$d/out" "$d/conf/config.d"
    python3 - "$d" "$mgn" "$art" "$FLAG" <<'PY'
import json, os, sys
d, mgn, art, flag = sys.argv[1:5]
names = ["mAnyTLS01-TLS", "mAnyTLS02-TLS", "mHysteria201-TLS"]
json.dump([(flag + " " + n) if mgn == "flag" else n for n in names],
          open(os.path.join(d, "conf/config.d/.managed.json"), "w"))
# ⚠ 夹具必须带**内核真正需要的字段** (缺 password 的节点内核会整条丢掉,
#   那样闸门会误报"内核解析出 0 个节点" —— 夹具自己先得上得了牌桌)
rows = [("anytls_client-01.yaml", "anytls", names[0], 25684,
         "    password: pw-anytls-1\n    sni: example.com\n    skip-cert-verify: true\n"),
        ("anytls_client-02.yaml", "anytls", names[1], 28725,
         "    password: pw-anytls-2\n    sni: example.com\n    skip-cert-verify: true\n"),
        ("hysteria2_client-01.yaml", "hysteria2", names[2], 25682,
         "    password: pw-hy2\n    sni: example.com\n    skip-cert-verify: true\n"
         "    up: \"60\"\n    down: \"200\"\n")]
for fn, t, nm, port, extra in rows:
    disp = (flag + " " + nm) if art == "flag" else nm
    open(os.path.join(d, "out", fn), "w", encoding="utf-8").write(
        "proxies:\n  - name: %s\n    type: %s\n    server: 203.0.113.10\n    port: %d\n%s"
        % (disp, t, port, extra))
PY
}

echo "== ① 生成分享内容 (踩过雷的那一步: 台账名 vs 产物名) =="
declare -A CASES=( [flag-flag]="flag flag" [bare-flag]="bare flag" [bare-bare]="bare bare" )
for key in flag-flag bare-flag bare-bare; do
    read -r mgn art <<<"${CASES[$key]}"
    d="$TMP/$key"; mk_case "$d" "$mgn" "$art"
    if python3 "$ROOT/src/share/build_sub.py" --out-dir "$d/out" --conf-dir "$d/conf" \
            --tag all -o "$d/sub.yaml" >"$d/gen.log" 2>&1; then
        got=$(python3 - "$d/sub.yaml" <<'PY' 2>/dev/null || echo 0
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print(len(d.get("proxies") or []))
PY
)
        [[ "$got" == "$N" ]] && ok "台账=$mgn 产物=$art → $got/$N 个节点" \
                             || bad "台账=$mgn 产物=$art → 只有 $got 个节点 (对角线断了)"
    else
        bad "台账=$mgn 产物=$art → 分享内容生成失败 (对角线断了)"
        sed 's/^/      /' "$d/gen.log" | tail -3
        got=0
    fi
    # 显示名不许被"为了匹配"而改动 (旗帜是用户可见特性)
    if [[ "$art" == "flag" ]]; then
        grep -q "$FLAG mAnyTLS01-TLS" "$d/sub.yaml" 2>/dev/null \
            && ok "  显示名仍带旗帜 (没为了匹配抹掉)" \
            || bad "  显示名里的旗帜被抹掉了"
    else
        grep -q -- "- name: mAnyTLS01-TLS" "$d/sub.yaml" 2>/dev/null \
            && ok "  裸名输入保持裸名 (没有被硬塞旗帜)" \
            || bad "  裸名输入被改了"
    fi
done

echo
echo "== ② 经 HTTP 取回 (模拟分享服务: 存进去 + 原样取回) =="
D1="$TMP/bare-flag"
PORT=$(( 18000 + RANDOM % 2000 ))
( cd "$D1" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!
sleep 2
URL="http://127.0.0.1:$PORT/sub.yaml"
if curl -s --max-time 8 -o "$TMP/fetched.yaml" -w '%{http_code}' "$URL" >"$TMP/code" 2>/dev/null \
   && [[ "$(cat "$TMP/code")" == "200" ]]; then
    ok "订阅 URL 取回 200 ($URL)"
    if cmp -s "$D1/sub.yaml" "$TMP/fetched.yaml"; then
        ok "取回内容与生成内容字节一致 (分享层不解析、不改写)"
    else
        bad "取回内容与生成内容不一致"
    fi
else
    bad "订阅 URL 取不回来 (HTTP $(cat "$TMP/code" 2>/dev/null))"
fi
kill "$HTTP_PID" 2>/dev/null; HTTP_PID=""

echo
echo "== ③ M 客户端导入 (client.sh 里的真实代码路径) =="
IMP="$TMP/import.py"
python3 - "$ROOT/src/client.sh" "$IMP" <<'PYX'
import sys
txt = open(sys.argv[1], encoding="utf-8").read()
i = txt.index("<<'PYIMP'\n") + len("<<'PYIMP'\n")
j = txt.index("\nPYIMP", i)
open(sys.argv[2], "w", encoding="utf-8").write(txt[i:j] + "\n")
PYX
CLI="$TMP/cli"; mkdir -p "$CLI/providers" "$CLI/lib" "$CLI/nodes"
cp "$ROOT/src/lib/validate.py" "$CLI/lib/" 2>/dev/null || true
if python3 "$IMP" "$TMP/fetched.yaml" "$CLI/providers/rn.yaml" "$CLI/lib" "" >"$CLI/imp.log" 2>&1; then
    # `| head -1` 会让上游 grep 吃 SIGPIPE(141), 而本脚本开头是 set -euo pipefail
    # → 随机猝死。改成会读完输入的 awk（不是重构, 只换读取器）。
    ok "客户端导入成功: $(grep -o '([0-9]* 个节点[^)]*)' "$CLI/imp.log" | awk 'NR==1')"
else
    bad "客户端导入失败: $(tail -2 "$CLI/imp.log" | tr '\n' ' ')"
fi
CNT=$(python3 - "$CLI/providers/rn.yaml" <<'PY' 2>/dev/null || echo 0
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print(len(d.get("proxies") or []))
PY
)
[[ "$CNT" == "$N" ]] && ok "provider 里有 $CNT 个节点 (不是 0)" \
                     || bad "provider 里只有 $CNT 个节点 (对角线断了)"

echo
echo "== ④ 真内核解析出正确节点数 =="
if [[ -z "${MIHOMO_BIN:-}" || ! -x "${MIHOMO_BIN:-}" ]]; then
    skip "没有内核可跑 (设 MIHOMO_BIN=<mihomo 路径> 可启用这层)"
else
    KD="$TMP/kernel"; mkdir -p "$KD"
    cp "$CLI/providers/rn.yaml" "$KD/provider.yaml"
    KPORT=$(( 20000 + RANDOM % 2000 ))
    cat > "$KD/config.yaml" <<EOF
mixed-port: $((KPORT + 1))
external-controller: 127.0.0.1:$KPORT
secret: diagsecret
log-level: warning
proxy-providers:
  t: {type: file, path: $KD/provider.yaml}
proxy-groups:
  - {name: g, type: select, use: [t]}
rules:
  - MATCH,g
EOF
    if "$MIHOMO_BIN" -t -d "$KD" >"$KD/test.log" 2>&1; then
        ok "内核配置校验通过 (mihomo -t)"
    else
        bad "内核配置校验失败: $(tail -2 "$KD/test.log" | tr '\n' ' ')"
    fi
    nohup "$MIHOMO_BIN" -d "$KD" >"$KD/run.log" 2>&1 &
    KPID=$!
    sleep 6
    KN=$(curl -s --max-time 6 -H "Authorization: Bearer diagsecret" \
            "http://127.0.0.1:$KPORT/providers/proxies/t" 2>/dev/null \
         | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("proxies") or []))' 2>/dev/null)
    [[ "${KN:-0}" == "$N" ]] && ok "真内核解析出 $KN 个节点 (provider 不是空的)" \
                             || bad "真内核只解析出 ${KN:-0} 个节点 (期望 $N)"
    kill "$KPID" 2>/dev/null; wait "$KPID" 2>/dev/null

    echo
    echo "== ⑤ 至少一条真连 (HTTP 码 + 出口 IP) =="
    if [[ -z "${M_DIAG_REAL_LINK:-}" || ! -f "${M_DIAG_REAL_LINK:-}" ]]; then
        skip "没有真实分享链接 (设 M_DIAG_REAL_LINK=<文件> 可启用这层)"
    else
        RD="$TMP/real"; mkdir -p "$RD"
        cp "$M_DIAG_REAL_LINK" "$RD/provider.yaml"
        RPORT=$(( 22000 + RANDOM % 2000 ))
        cat > "$RD/config.yaml" <<EOF
mixed-port: $((RPORT + 1))
external-controller: 127.0.0.1:$RPORT
secret: diagsecret
log-level: warning
proxy-providers:
  t: {type: file, path: $RD/provider.yaml}
proxy-groups:
  - {name: g, type: select, use: [t]}
rules:
  - MATCH,g
EOF
        nohup "$MIHOMO_BIN" -d "$RD" >"$RD/run.log" 2>&1 &
        RPID=$!
        sleep 6
        RN_N=$(curl -s --max-time 6 -H "Authorization: Bearer diagsecret" \
                 "http://127.0.0.1:$RPORT/providers/proxies/t" 2>/dev/null \
               | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("proxies") or []))' 2>/dev/null)
        ok "真实分享链接被内核解析出 ${RN_N:-0} 个节点"
        # 本机自身出口 IP: 多源回退 (单源在有些网络里直接不通, 拿不到就会把
        # 正确的节点误判成"没走节点")
        SELFIP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '\r\n')
        [[ -n "$SELFIP" ]] || SELFIP=$(curl -s --max-time 8 https://ifconfig.me 2>/dev/null | tr -d '\r\n')
        [[ -n "$SELFIP" ]] || SELFIP=$(curl -s --max-time 8 "http://ip-api.com/line/?fields=query" 2>/dev/null | tr -d '\r\n')
        LOCALIPS=$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
        printf '      本机自身出口 IP=%s (网卡: %s)\n' "${SELFIP:-<取不到>}" "${LOCALIPS:-<无>}"
        # 逐个试前 3 个节点: 至少**一条**真连 (HTTP 204) 且出口 IP ≠ 本机自身。
        # 只试第一个是不够的 —— 列表里可能第一个恰好是 CDN 节点 (需要客户端那套
        # DNS/ECH 配置), 那不代表对角线断了。
        ALL=$(curl -s --max-time 6 -H "Authorization: Bearer diagsecret" \
                "http://127.0.0.1:$RPORT/proxies/g" 2>/dev/null \
              | python3 -c 'import sys,json;print("\n".join((json.load(sys.stdin).get("all") or [])[:3]))' 2>/dev/null)
        PROVEN=0
        while IFS= read -r NODE1; do
            [[ -n "$NODE1" ]] || continue
            curl -s --max-time 6 -H "Authorization: Bearer diagsecret" -X PUT \
                 "http://127.0.0.1:$RPORT/proxies/g" \
                 -d "$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1]}))' "$NODE1")" >/dev/null
            RES=$(curl -s -o /dev/null -w '%{http_code}|%{time_total}' --max-time 12 \
                     -x "http://127.0.0.1:$((RPORT + 1))" https://www.gstatic.com/generate_204)
            CODE=${RES%%|*}
            COST=${RES##*|}
            EXITIP=$(curl -s --max-time 10 -x "http://127.0.0.1:$((RPORT + 1))" https://api.ipify.org 2>/dev/null | tr -d '\r\n')
            [[ -n "$EXITIP" ]] || EXITIP=$(curl -s --max-time 10 -x "http://127.0.0.1:$((RPORT + 1))" \
                     "http://ip-api.com/line/?fields=query" 2>/dev/null | tr -d '\r\n')
            printf '      %-34s http=%-4s %ss exit_ip=%s\n' "$NODE1" "$CODE" "$COST" "${EXITIP:-<none>}"
            # 判据: 204 + 出口 IP 非空 + **不等于**本机任一地址 (自身出口 IP 拿不到
            # 时用网卡地址兜底 —— 节点出口绝不可能等于本机网卡地址)
            IS_LOCAL=0
            for _ip in $LOCALIPS; do [[ "$EXITIP" == "$_ip" ]] && IS_LOCAL=1; done
            if [[ "$CODE" == "204" && -n "$EXITIP" && "$EXITIP" != "$SELFIP" && "$IS_LOCAL" == "0" ]]; then
                ok "真连: '$NODE1' http=204 耗时 ${COST}s 出口 IP=$EXITIP (本机 $SELFIP)"
                PROVEN=1
                break
            fi
        done <<<"$ALL"
        (( PROVEN == 1 )) || bad "前 3 个节点里没有一条能证明"真的走了节点" (204 且出口 IP 不同)"
        kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null
    fi
fi

printf "\n对角线闸门 (M 分享 → M 客户端): \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m / \033[33m%d 跳过\033[0m\n" \
    "$PASS" "$FAIL" "$SKIP"
if (( SKIP > 0 )); then
    printf "  \033[33m注意\033[0m: 跳过的层不算通过 —— 它们在有内核的机器上必须真跑 (见脚本头部)\n"
fi
exit $((FAIL > 0))
