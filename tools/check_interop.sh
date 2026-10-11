#!/usr/bin/env bash
# =============================================================
# 三家互通闸门 —— **内核声明 + 决策 + 回退链** 的机械断言
#
# 为什么单独一道、为什么必须机械可重复
# ------------------------------------
# 三家互通的核心是"客户端读地址上的声明, 单方面决定拉原生还是普通话", 而它
# 失效的方式**全是静默的**:
#   · 服务端声明的字段名和客户端读的字段名不一致 → 永远走普通话, 不报错;
#   · 发行版标签与 compat 判能力用的标签不是一个字符串 → 声明匹配不上, 不报错;
#   · 原生取件失败没有回退 → 客户端直接"订阅里没有解析出节点";
#   · 回退时不说原因 → 用户以为服务端坏了。
# 已实测的原始故障: M 分享 (mihomo YAML) 喂给 Xray 的 xbd → 解析 19 个空壳,
# **导入 0/19**。修法不是让 xbd 学 YAML, 而是 M 也产出普通话 (URI 列表)。
#
# 本闸门在 /tmp 里搭真夹具, 跑**真代码**:
#   interop.py (服务端与客户端**同一份**) / build_uri.py / build_sub.py /
#   client.sh 的 node-sub 子命令 (与面板走同一条决策+回退路径)。
# 连 HTTP 都是真的 (本机 python http.server, 随机端口)。
#
# 用法: bash tools/check_interop.sh     退出码 0=通过 1=有问题
# =============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$(pwd)"

PASS=0; FAIL=0; SKIP=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31m❌\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
skip() { printf "  \033[33m⊘\033[0m %s\n" "$1"; SKIP=$((SKIP+1)); }
# 明示但不判红: 用于"真源自己的状态"这类不是副本缺陷、却必须让人看见的情况。
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
py()   { python3 - "$@"; }

TMP=$(mktemp -d /tmp/.m-interop-XXXXXX)
trap 'rm -rf "$TMP"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null' EXIT

FLAG="🇺🇸"
PINVAL="$(python3 -c 'print("b8" * 32)')"
INTEROP="$ROOT/src/lib/interop.py"
FACTDIR="$TMP/fakebin"; mkdir -p "$FACTDIR"
# 假内核: 与真 mihomo 的 -v 首行同形 (官方二进制自称 "Mihomo Meta …")
cat > "$FACTDIR/mihomo" <<'EOF'
#!/bin/sh
echo "Mihomo Meta v1.19.32 linux arm64 with go1.26.8 Wed Sep 30 16:55:22 UTC 2026"
echo "Use tags: with_gvisor"
EOF
chmod +x "$FACTDIR/mihomo"
export MIHOMO_BIN="$FACTDIR/mihomo"

# ---------------------------------------------------------------- 夹具
FIX="$TMP/fix"
mkdir -p "$FIX/out" "$FIX/conf/config.d"
python3 - "$FIX" "$FLAG" <<'PY'
import sys, os
d, flag = sys.argv[1], sys.argv[2]
rows = [("anytls_client-01.yaml",
         "    type: anytls\n    server: 203.0.113.10\n    port: 25684\n"
         "    password: pw-anytls\n    sni: example.com\n    skip-cert-verify: true\n"),
        ("hysteria2_client-01.yaml",
         "    type: hysteria2\n    server: 203.0.113.10\n    port: 25682\n"
         "    password: pw-hy2\n    sni: example.com\n    up: \"60\"\n    down: \"200\"\n"
         "    skip-cert-verify: true\n")]
names = ["mAnyTLS01-TLS", "mHysteria201-TLS"]
for (fn, body), nm in zip(rows, names):
    with open(os.path.join(d, "out", fn), "w", encoding="utf-8") as fh:
        fh.write("proxies:\n  - name: %s %s\n%s" % (flag, nm, body))
# 幽灵产物 (节点已删) —— 两条产品都必须把它剔掉, 否则"两条产品节点集合一致"
# 这条断言会因为两边都错得一样而假通过
with open(os.path.join(d, "out", "trojan_client-09.yaml"), "w", encoding="utf-8") as fh:
    fh.write("proxies:\n  - name: %s mTrojan09-GHOST\n    type: trojan\n"
             "    server: 203.0.113.10\n    port: 12345\n    password: x\n" % flag)
PY
printf '["mAnyTLS01-TLS", "mHysteria201-TLS"]\n' > "$FIX/conf/config.d/.managed.json"

echo "== ① 两个产品: 普通话(URI 列表) 与 原生(mihomo YAML) 节点集合必须一致 =="
URI_LIST="$TMP/uri.txt"; NATIVE="$TMP/native.yaml"
if python3 "$ROOT/src/share/build_uri.py" --out-dir "$FIX/out" --conf-dir "$FIX/conf" \
        --tag all -o "$URI_LIST" >"$TMP/uri.log" 2>&1; then
    ok "build_uri 生成成功 (普通话产品)"
else
    bad "build_uri 生成失败"; sed 's/^/      /' "$TMP/uri.log" | tail -3
fi
python3 "$ROOT/src/share/build_sub.py" --out-dir "$FIX/out" --conf-dir "$FIX/conf" \
    --tag all -o "$NATIVE" >/dev/null 2>&1

NAMES_URI=$(python3 - "$URI_LIST" <<'PY'
import sys, urllib.parse
out = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "://" not in line:
        continue
    frag = urllib.parse.urlsplit(line).fragment
    out.append(urllib.parse.unquote(frag))
print("\n".join(out))
PY
)
NAMES_YAML=$(python3 - "$NATIVE" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print("\n".join(str(p.get("name")) for p in (d.get("proxies") or [])))
PY
)
if [[ "$NAMES_URI" == "$NAMES_YAML" && -n "$NAMES_URI" ]]; then
    ok "两条产品的节点集合逐字一致 ($(printf '%s' "$NAMES_URI" | grep -c .) 个)"
else
    bad "两条产品发布的节点集合不一致: URI=[$(printf '%s' "$NAMES_URI" | tr '\n' ',')] YAML=[$(printf '%s' "$NAMES_YAML" | tr '\n' ',')]"
fi
grep -q "GHOST" "$URI_LIST" && bad "陈旧产物 GHOST 混进了普通话产品" \
                              || ok "普通话产品也剔除了陈旧产物 (与原生同一道过滤)"
grep -q "例com" "$URI_LIST" && bad "URI 里出现了非法编码" || true
# URI 必须能被**本项目自己的解析器**读回成同一个节点 (server/port/凭据/sni)
python3 - "$URI_LIST" "$ROOT/src/lib" <<'PY' && ok "生成的 URI 能被 compat 解析回同一个节点 (端口/凭据/sni 逐项相等)" \
    || bad "生成的 URI 解析回来对不上 (字段丢失或写错)"
import sys
sys.path.insert(0, sys.argv[2])
from proxy_node_compat import parse_uri
want = {"anytls": ("203.0.113.10", 25684, "pw-anytls", "example.com"),
        "hysteria2": ("203.0.113.10", 25682, "pw-hy2", "example.com")}
seen = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    prof = parse_uri(line)
    proto = (prof.protocol.id if prof.protocol else "").split(":")[-1]
    if proto not in want:
        raise SystemExit("协议不认识: %r" % proto)
    host, port, pw, sni = want[proto]
    got_host = str(prof.endpoint["host"].v)
    got_port = int(prof.endpoint["port"].v)
    got_pw = ""
    for k in ("password", "uuid"):
        f = prof.auth.get(k)
        if f is not None and str(f.v):
            got_pw = str(f.v)
            break
    if (got_host, got_port, got_pw) != (host, port, pw):
        raise SystemExit("对不上: %s %s %s != %s" % (got_host, got_port, got_pw, (host, port, pw)))
    seen += 1
if seen != 2:
    raise SystemExit("解析出的节点数 %d != 2" % seen)
PY

# 自签 hy2 的证书 pin: **两个键都要写** —— mihomo 只认 pinSHA256, Xray 系(xbd)
# 只认 pin。只写一个的后果实测过: xbd 解析出的 pinned_cert_sha256 为空 → 自签
# 节点按"校验证书"走 → 真连 http=000 (同一批里其余 14 个全 204)。
PINFIX="$TMP/pinfix"; mkdir -p "$PINFIX/out" "$PINFIX/conf/config.d"
python3 - "$PINFIX" "$FLAG" <<'PYEOF'
import sys, os
d, flag = sys.argv[1], sys.argv[2]
with open(os.path.join(d, "out", "hysteria2_client-07.yaml"), "w", encoding="utf-8") as fh:
    fh.write("proxies:\n  - name: %s mHysteria207-TLS\n    type: hysteria2\n"
             "    server: 203.0.113.10\n    port: 20309\n    password: pw\n"
             "    sni: example.com\n    up: \"50\"\n    down: \"200\"\n"
             "    fingerprint: %s\n" % (flag, "b8" * 32))
PYEOF
printf '["mHysteria207-TLS"]\n' > "$PINFIX/conf/config.d/.managed.json"
python3 "$ROOT/src/share/build_uri.py" --out-dir "$PINFIX/out" --conf-dir "$PINFIX/conf" \
    --tag all -o "$TMP/pin_uri.txt" >/dev/null 2>&1 || true
if grep -q "pinSHA256=$PINVAL" "$TMP/pin_uri.txt" && grep -q "&pin=$PINVAL" "$TMP/pin_uri.txt"; then
    ok "自签证书 pin 写了两个键 (pinSHA256=mihomo / pin=Xray 系)"
else
    bad "证书 pin 的键写少了 —— 某一家客户端会拿不到 pin: $(cat "$TMP/pin_uri.txt")"
fi

echo
echo "== ② URI 表达不了的东西必须报出来 (不静默降级) =="
LOSSFIX="$TMP/lossfix"; mkdir -p "$LOSSFIX/out" "$LOSSFIX/conf/config.d"
python3 - "$LOSSFIX" "$FLAG" <<'PY'
import sys, os
d, flag = sys.argv[1], sys.argv[2]
with open(os.path.join(d, "out", "vless_client-01.yaml"), "w", encoding="utf-8") as fh:
    fh.write("proxies:\n  - name: %s mV-01\n    type: vless\n    server: 203.0.113.10\n"
             "    port: 443\n    uuid: 11111111-2222-3333-4444-555555555555\n"
             "    network: xhttp\n    tls: true\n    servername: example.com\n"
             "    xhttp-opts:\n      path: /x\n      mode: auto\n"
             "      x-padding-bytes: \"100-1000\"\n" % flag)
    fh.write("  - name: %s mSnell01\n    type: snell\n    server: 203.0.113.10\n"
             "    port: 9999\n    psk: x\n" % flag)
PY
printf '["mV-01", "mSnell01"]\n' > "$LOSSFIX/conf/config.d/.managed.json"
python3 "$ROOT/src/share/build_uri.py" --out-dir "$LOSSFIX/out" --conf-dir "$LOSSFIX/conf" \
    --tag all -o "$TMP/loss_uri.txt" >"$TMP/loss.out" 2>"$TMP/loss.err" || true
grep -q "x-padding-bytes" "$TMP/loss.err" \
    && ok "xhttp 的 x-padding-bytes 报成损失 (URI 装不下, 原生 YAML 有)" \
    || bad "x-padding-bytes 被静默丢掉 (URI 里没有、日志里也没有)"
grep -q "未覆盖" "$TMP/loss.err" \
    && ok "做不出链接的协议(snell)被报成未覆盖" \
    || bad "snell 节点被静默丢掉"
[[ "$(grep -c '://' "$TMP/loss_uri.txt" 2>/dev/null)" == "1" ]] \
    && ok "可表达的节点照常产出 (1 条)" || bad "可表达节点的链接没产出"

echo
echo "== ③ 声明: 往返 / 保留别人的参数 / 片段不算声明 / 取件地址可被地址族切换改写 =="
python3 - "$INTEROP" <<'PY' && ok "declare→parse 往返: 内核/发行版/版本/格式/取件地址全部还原" \
    || bad "声明往返丢字段"
import sys, importlib.util, urllib.parse
spec = importlib.util.spec_from_file_location("interop", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
decl = m.build_declaration("mihomo", "upstream", "1.19.32", formats=("uri",),
                           urls={"upstream": "http://1.2.3.4:9443/share/nat"})
url = m.declare_url("http://1.2.3.4:9443/share/pri?panel=abc", decl)
d = m.parse_declaration(url)
assert d and d["kernel"] == "mihomo" and d["distribution"] == "upstream"
assert d["version"] == "1.19.32" and d["formats"] == ["uri", "upstream"]
assert d["urls"]["upstream"] == "http://1.2.3.4:9443/share/nat", d["urls"]
assert d["raw"].get("panel") == "abc", "别人的参数被吃掉了"
# ★ 取件地址必须**保持 `://` 原样**: 地址族切换靠 sed 替换 `//<host>[:/]`,
#   %3A%2F%2F 会让它匹配不到 → 订阅地址切了族、原生地址还停在旧族 (死链)。
assert "url-upstream=http://" in url, "取件地址被编码成 %3A%2F%2F —— 地址族切换会漏改: %s" % url
# 片段里的同名字段不算声明 (片段是别的客户端的显示名载体)
frag = "http://1.2.3.4:9443/share/x#interop=1&kernel=mihomo&distribution=upstream&formats=uri,upstream"
assert m.parse_declaration(frag) is None, "把片段当成了声明"
PY
# ★ 「M 产出的声明, M 自己读得回」—— 这条是跨实现一致性台抓到的真缺陷:
#   url-* 的值**保留 `://` 原样**(见上一条断言的用意), 于是**裸查询串里也有
#   `://`**; parse_declaration 若拿 `"://" not in s` 当"这是裸查询串"的判据,
#   就会把自家声明判成"没有查询串" → decide 落到 no-declaration →
#   **静默走普通话**, 不报错。修前的反向证据: 这条断言必红。
python3 - "$INTEROP" <<'PY' && ok "裸查询串/裸地址/完整地址三种形态的声明都能读回, 且决策一致" \
    || bad "M 产出的声明 M 自己读不回来 (裸查询串形态 → 静默走普通话)"
import sys, importlib.util
spec = importlib.util.spec_from_file_location("interop", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
decl = m.build_declaration("mihomo", "upstream", "1.19.32", formats=("uri", "upstream"),
                           urls={"upstream": "http://198.51.100.77:9443/share/nat"})
qs = m.declaration_query(decl)                       # 自己产出的裸查询串
assert "url-upstream=http://" in qs, "夹具前提不成立: url-* 值应保留 :// 原样"
bare = m.parse_declaration(qs)
assert bare is not None, "裸查询串读不回声明 (declaration_query 的输出)"
assert bare["recognized"], "裸查询串形态的声明被判成不认识"
assert bare["urls"].get("upstream") == "http://198.51.100.77:9443/share/nat", bare["urls"]
bareq = m.parse_declaration("?" + qs)                # 带 ? 前缀的裸查询串
assert bareq is not None and bareq["recognized"], "带 ? 的裸查询串读不回声明"
full = m.parse_declaration(m.declare_url("http://h:1/share/pri", decl))
assert full is not None and full["recognized"], "完整地址读不回声明"
d_bare = m.decide(bare,  "mihomo", "upstream")
d_bareq = m.decide(bareq, "mihomo", "upstream")
d_full = m.decide(full,  "mihomo", "upstream")
assert d_bare == d_bareq == d_full, (d_bare, d_bareq, d_full)
assert d_bare[0] == "native" and d_bare[1] == "native-listed", d_bare
PY
# ★ 地址收束 (2026-10-11): 不再产出 version; 同源写相对路径; 解析侧拼回绝对地址。
#   三条都要在**纯函数**这一层钉住, 再加 §⑧ 在真 share.sh 产出上钉一遍。
python3 - "$INTEROP" <<'PY' && ok "收束后: 声明无 version / 相对引用解析成绝对 / 旧格式仍判 native / 畸形不猜" \
    || bad "地址收束的三条契约有破口"
import sys, importlib.util
spec = importlib.util.spec_from_file_location("interop", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
MAIN = "http://h:1/share/pri"
REL = "/share/nat"
# ① 不再产出 version
decl = m.build_declaration("mihomo", "upstream",
                           formats=("uri", "upstream"), urls={"upstream": REL})
qs = m.declaration_query(decl)
assert "version=" not in qs, qs
assert "url-upstream=/share/nat" in qs, qs
# ② 同源相对引用 → parse 拼回绝对 → decide 给 native 且 URL 是拼好的绝对地址
url = m.declare_url(MAIN, decl)
d = m.parse_declaration(url)
assert d and d["urls"]["upstream"] == "http://h:1/share/nat", d and d["urls"]
c, r, u, _ = m.decide(d, "mihomo", "upstream")
assert (c, r) == ("native", "native-listed") and u == "http://h:1/share/nat", (c, r, u)
# ③ 向后兼容: **旧格式**向量 (绝对 URL + 带 version) 必须照样判 native
old = (MAIN + "?interop=1&kernel=mihomo&distribution=upstream&version=1.19.32"
       "&formats=uri%2Cupstream&url-upstream=http://h:1/share/nat")
do = m.parse_declaration(old)
assert do and do["urls"]["upstream"] == "http://h:1/share/nat", do and do["urls"]
assert do["version"] == "1.19.32", do          # version 仍被**接受**, 只是不参与决策
assert m.decide(do, "mihomo", "upstream")[:2] == ("native", "native-listed")
# ④ 畸形相对路径必须**不猜** (decide 落到 bad-native-url, 不是 native)
for badref in ("/share/", "//other.host/x", "/x", "../x", "/share/a/"):
    u2 = m.declare_url(MAIN, m.build_declaration("mihomo", "upstream",
                                                 urls={"upstream": badref},
                                                 formats=("uri", "upstream")))
    d2 = m.parse_declaration(u2)
    got = m.decide(d2, "mihomo", "upstream")[:2]
    assert got == ("uri", "bad-native-url"), (badref, got)
    # 解析不出就**原样保留**, 不许猜
    assert d2["urls"]["upstream"] == badref, (badref, d2["urls"])
# ⑤ 裸查询串形态没有"源"可比 → 相对引用原样保留 (不猜)
bare = m.parse_declaration("interop=1&kernel=mihomo&distribution=upstream"
                           "&formats=uri%2Cupstream&url-upstream=/share/nat")
assert bare["urls"]["upstream"] == "/share/nat", bare["urls"]
assert m.decide(bare, "mihomo", "upstream")[:2] == ("uri", "bad-native-url"), \
    m.decide(bare, "mihomo", "upstream")[:2]
PY
python3 - "$INTEROP" <<'PY' && ok "服务端声明地址含声明, 且裸地址不含 (客户端据前者决策)" \
    || bad "声明没写进地址"
import sys, importlib.util
spec = importlib.util.spec_from_file_location("interop", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
decl = m.build_declaration("mihomo", "upstream", "1.19.32",
                           urls={"upstream": "http://h:1/share/nat"})
u = m.declare_url("http://h:1/share/pri", decl)
assert "interop=1" in u and "url-upstream=" in u
assert m.parse_declaration("http://h:1/share/pri") is None
PY

echo
echo "== ④ 决策规则逐条 (9 条, 与设计文档 §3 一一对应) =="
DECL_URL=$(python3 "$INTEROP" declare --kernel mihomo --distribution upstream \
    --version 1.19.32 --url "http://127.0.0.1:1/share/pri" \
    --url-upstream "http://127.0.0.1:1/share/nat" 2>/dev/null)
decide() { python3 "$INTEROP" decide "$1" ${2:+--kernel "$2"} ${3:+--distribution "$3"} 2>/dev/null; }
field() { python3 -c 'import sys,json
try: print((json.loads(sys.stdin.read()) or {}).get(sys.argv[1],""))
except Exception: print("")' "$1"; }
case_rule() { # <说明> <地址> <期望 choice> <期望 reason> [kernel] [distribution]
    local desc="$1" url="$2" wantc="$3" wantr="$4" k="${5:-mihomo}" dist="${6:-upstream}"
    local out c r
    out=$(decide "$url" "$k" "$dist")
    c=$(printf '%s' "$out" | field choice); r=$(printf '%s' "$out" | field reason)
    if [[ "$c" == "$wantc" && "$r" == "$wantr" ]]; then ok "$desc → $c/$r"
    else bad "$desc: 期望 $wantc/$wantr, 实际 $c/$r"; fi
}
case_rule "同内核同发行版"      "$DECL_URL" native native-listed
case_rule "跨内核(xray 客户端)"  "$DECL_URL" uri    cross-kernel  xray xray
case_rule "声明缺失"            "http://127.0.0.1:1/share/pri" uri no-declaration
case_rule "规范版本不认识"      "${DECL_URL/interop=1/interop=9}" uri unknown-schema
case_rule "内核名不在词表"      "${DECL_URL/kernel=mihomo/kernel=neoxray}" uri unknown-kernel
case_rule "发行版不在清单"      "$DECL_URL" uri distribution-not-listed mihomo mihomo-lx
# "本机发行版探测不出来" 不能用 CLI 造 (CLI 探不到时会回落到真探测的结果),
# 直接调纯函数 —— 决策规则是纯函数, 验的就是它。
python3 - "$INTEROP" <<'PYEOF' && ok "本机发行版探测不出来 → uri/self-unknown (不猜自己是官方版)" \
    || bad "本机发行版探测不出来时的决策不对"
import sys, importlib.util
spec = importlib.util.spec_from_file_location("interop", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
decl = m.build_declaration("mihomo", "upstream", "1.19.32",
                           urls={"upstream": "http://h:1/share/nat"})
parsed = m.parse_declaration(m.declare_url("http://h:1/share/pri", decl))
c, r, u, _ = m.decide(parsed, "mihomo", "")
assert (c, r) == ("uri", "self-unknown"), (c, r)
c, r, u, _ = m.decide(None, "mihomo", "")
assert (c, r) == ("uri", "no-declaration"), (c, r)
PYEOF
NOURL=$(python3 "$INTEROP" declare --kernel mihomo --distribution upstream \
    --version 1.19.32 --url "http://127.0.0.1:1/share/pri" 2>/dev/null)
case_rule "声明了格式却没给地址" "$NOURL" uri distribution-not-listed
BADURL=$(python3 "$INTEROP" declare --kernel mihomo --distribution upstream \
    --version 1.19.32 --url "http://127.0.0.1:1/share/pri" \
    --url-upstream "ftp://h/nat" 2>/dev/null)
case_rule "取件地址不是 http(s)" "$BADURL" uri bad-native-url

echo
echo "== ⑤ 发行版标签与 compat 判能力用的标签**同源** (真二进制比对) =="
python3 - "$INTEROP" "$ROOT/src/lib" <<'PY' && ok "interop.self_facts() 与 nodecompat.probe_kernel() 的 distribution 逐字相同" \
    || bad "两处对同一个二进制给出了不同的发行版标签 —— 声明永远匹配不上"
import sys, importlib.util
spec = importlib.util.spec_from_file_location("interop", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.path.insert(0, sys.argv[2])
import nodecompat
a = m.self_facts()
b = nodecompat.probe_kernel()
assert a["distribution"] == b["distribution"], (a, b)
assert a["version"] == b["version"], (a, b)
assert a["ok"] and a["distribution"] == "upstream", a
PY

echo
echo "== ⑥ 客户端决策 + 回退链 (client.sh 的 node-sub, 与面板同一条路径) =="
PUB="$TMP/pub"; mkdir -p "$PUB/share"
cp "$URI_LIST" "$PUB/share/pri"
cp "$NATIVE" "$PUB/share/nat"
PORT=$(( 19000 + RANDOM % 2000 ))
( cd "$PUB" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!
sleep 2
BASE="http://127.0.0.1:$PORT/share"
DECL_OK=$(python3 "$INTEROP" declare --kernel mihomo --distribution upstream \
    --version 1.19.32 --url "$BASE/pri" --url-upstream "$BASE/nat" 2>/dev/null)
DECL_404=$(python3 "$INTEROP" declare --kernel mihomo --distribution upstream \
    --version 1.19.32 --url "$BASE/pri" --url-upstream "$BASE/nat404" 2>/dev/null)
DECL_X=$(python3 "$INTEROP" declare --kernel xray --distribution xray \
    --version 26.3.27 --url "$BASE/pri" --url-xray "$BASE/nat" 2>/dev/null)

CLIROOT="$TMP/cli"; mkdir -p "$CLIROOT"
cli_sub() { # <地址> <组名>
    CLI_ROOT="$CLIROOT" MIHOMO_BIN="$FACTDIR/mihomo" \
        bash "$ROOT/src/client.sh" node-sub "$1" "$2" 2>&1
}
# provider 里的节点数 —— **两种形态都要算对** (与 client.sh:m_provider_count 同一口径):
#   * proxies: YAML      (原生路径)
#   * 一行行分享链接      (普通话路径; 内核自己解析)
# 只认 YAML 的话, 普通话路径会被算成 0, 闸门就会把"正确回退"误报成失败。
count_prov() { python3 - "$CLIROOT/conf/providers/$1.yaml" <<'PYEOF' 2>/dev/null || echo 0
import sys, yaml
try:
    txt = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    print(0); raise SystemExit
d = None
try:
    d = yaml.safe_load(txt)
except Exception:
    d = None
if isinstance(d, dict) and isinstance(d.get("proxies"), list):
    print(len(d["proxies"]))
else:
    print(sum(1 for l in txt.splitlines()
              if l.strip() and not l.strip().startswith("#") and "://" in l))
PYEOF
}
lines_of() { python3 -c 'import sys
print(sum(1 for l in open(sys.argv[1], encoding="utf-8")
          if l.strip() and not l.strip().startswith("#")))' "$1"; }

OUT=$(cli_sub "$DECL_OK" ok1)
if grep -q "本次拉取: 原生" <<<"$OUT" && grep -q "同内核同发行版" <<<"$OUT"; then
    ok "同内核同发行版 → 原生: $(grep -o '本次拉取: 原生[^—]*' <<<"$OUT" | sed -n 1p | sed 's/ *$//')"
else
    bad "同内核同发行版没有走原生"; sed 's/^/      /' <<<"$OUT" | tail -4
fi
N=$(count_prov ok1)
[[ "$N" == "2" ]] && ok "原生路径 provider 里 2 个节点 (YAML 逐字落盘)" \
                  || bad "原生路径 provider 里只有 $N 个节点"

OUT=$(cli_sub "$DECL_404" fb1)
grep -q "本次拉取: 普通话" <<<"$OUT" && ok "原生 404 → 回退普通话" \
                                     || { bad "原生 404 没有回退"; sed 's/^/      /' <<<"$OUT" | tail -4; }
grep -q "原生取件失败" <<<"$OUT" && grep -q "回退" <<<"$OUT" \
    && ok "回退把原因打出来了 (不静默降级)" || bad "回退没有说明原因"
N=$(count_prov fb1)
[[ "$N" == "2" ]] && ok "回退后的 provider 有 2 个节点 (URI 列表)" \
                  || bad "回退后 provider 里只有 $N 个节点"

OUT=$(cli_sub "${BASE}/pri" nd1)
grep -q "地址上没有内核声明" <<<"$OUT" && ok "声明缺失 → 普通话, 且不报错 (原因=地址上没有内核声明)" \
                                      || { bad "声明缺失时的行为不对"; sed 's/^/      /' <<<"$OUT" | tail -4; }
N=$(count_prov nd1)
[[ "$N" == "2" ]] && ok "声明缺失时 provider 仍有 2 个节点" || bad "声明缺失时只有 $N 个节点"

OUT=$(cli_sub "$DECL_X" ck1)
grep -q "跨内核\|服务端内核 xray" <<<"$OUT" && ok "跨内核 → 普通话 (不试原生)" \
                                           || { bad "跨内核时行为不对"; sed 's/^/      /' <<<"$OUT" | tail -4; }
N=$(count_prov ck1)
[[ "$N" == "2" ]] && ok "跨内核时 provider 有 2 个节点 (URI 列表)" || bad "跨内核时只有 $N 个节点"
# 跨内核时**不许**去拉 url-xray (那时拉的是别人内核的原生格式, 解析不出节点)
grep -q "原生取件失败" <<<"$OUT" && bad "跨内核时竟然去试了原生" \
                                || ok "跨内核时连原生取件都没发生 (决策在取件之前)"

echo
echo "== ⑦ 同一份实现: 服务端与客户端读的是同一个 interop.py =="
N_INTEROP=$(find "$ROOT/src" -name 'interop.py' | wc -l)
[[ "$N_INTEROP" == "1" ]] && ok "仓库里只有一份 interop.py ($(find "$ROOT/src" -name interop.py))" \
                          || bad "interop.py 有 $N_INTEROP 份 —— 抄一份就是一处漂移源"
grep -q '_interop_py' "$ROOT/src/client.sh" && grep -q 'INTEROP_PY' "$ROOT/src/share/share.sh" \
    && ok "服务端(share.sh)与客户端(client.sh)都引用了它" \
    || bad "有一侧没有引用 interop.py"

echo
echo "== ⑧ 服务端: 两条记录 + 成对生命周期 (真 share.sh, 假公共服务只做存储) =="
# 为什么用假服务: 真公共服务不在开发机上, 而这一段全是**静默失败**型
# (只停用主记录 → 原生记录还活着; 刷新不分派 → 原生记录被写成 URI 列表)。
# 假实现只做存储语义, 被驱动的是 share.sh 里**真的**那些函数。
STORE="$TMP/store"
cat > "$TMP/fake_share_api.py" <<'FAKEPYEOF'
#!/usr/bin/env python3
"""闸门用的**假公共服务** —— 只实现 share.sh 用到的那几个子命令。

为什么要有: 服务端那条"两条记录 + 成对生命周期"的逻辑全是**静默失败**型
(只停用主记录 → 原生记录还活着; 刷新不分派 → 原生记录被写成 URI 列表)。
真公共服务不在开发机上, 而这段逻辑必须能机械复现 —— 所以用一个只有
存储语义的假实现去驱动**真的 share.sh 函数**。
"""
import json
import os
import sys
import time

STORE = os.environ["FAKE_SHARE_STORE"]
os.makedirs(STORE, exist_ok=True)


def path(tok):
    return os.path.join(STORE, tok + ".json")


def load(tok):
    try:
        with open(path(tok), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def save(rec):
    with open(path(rec["token"]), "w", encoding="utf-8") as fh:
        json.dump(rec, fh, ensure_ascii=False)


def out(obj):
    print(json.dumps(obj, ensure_ascii=False))


def main(argv):
    if not argv:
        return 2
    cmd = argv[0]
    opt = {}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            k = a[2:]
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                opt[k] = argv[i + 1]
                i += 2
            else:
                opt[k] = "true"
                i += 1
        else:
            i += 1
    if cmd == "port":
        print("9443")
        return 0
    if cmd == "health":
        return 0
    if cmd == "ensure":
        print("9443")
        return 0
    if cmd == "list":
        recs = []
        for f in sorted(os.listdir(STORE)):
            if f.endswith(".json"):
                r = load(f[:-5])
                if r:
                    recs.append(r)
        out(recs)
        return 0
    if cmd == "get":
        r = load(opt.get("token", ""))
        if not r:
            return 1
        out(r)
        return 0
    if cmd == "create":
        content = opt.get("content", "")
        if opt.get("content-file"):
            content = open(opt["content-file"], encoding="utf-8").read()
        tok = opt.get("token") or os.urandom(8).hex()
        rec = {
            "token": tok, "provider": "mihomo", "type": opt.get("type", "node"),
            "content": content,
            "content_type": opt.get("content-type", "text/yaml; charset=utf-8"),
            "content_sha256": __import__("hashlib").sha256(
                content.encode()).hexdigest(),
            "content_bytes": len(content.encode()),
            "meta": json.loads(opt["meta"]) if opt.get("meta") else {},
            "created_at": int(time.time()), "expires_at": 0,
            "max_uses": int(opt.get("max-uses", 0) or 0), "used_count": 0,
            "enabled": True, "state": "active", "last_used_at": 0,
        }
        save(rec)
        out(rec)
        return 0
    if cmd == "update":
        r = load(opt.get("token", ""))
        if not r:
            return 1
        if "content" in opt:
            r["content"] = opt["content"]
        if opt.get("content-file"):
            r["content"] = open(opt["content-file"], encoding="utf-8").read()
        if "content" in opt or opt.get("content-file"):
            r["content_sha256"] = __import__("hashlib").sha256(
                r["content"].encode()).hexdigest()
        if "meta" in opt:
            r["meta"] = json.loads(opt["meta"])
        if "enabled" in opt:
            r["enabled"] = opt["enabled"] == "true"
            r["state"] = "active" if r["enabled"] else "disabled"
        if "used-count" in opt:
            r["used_count"] = int(opt["used-count"])
        save(r)
        out(r)
        return 0
    if cmd == "delete":
        try:
            os.unlink(path(opt.get("token", "")))
        except OSError:
            return 1
        out({"deleted": True})
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
FAKEPYEOF
export FAKE_SHARE_STORE="$STORE"
export TMP_FAKE="$TMP/fake_share_api.py"
mkdir -p "$STORE"
SRV_OUT="$FIX/out" SRV_CONF="$FIX/conf" SHARE_DIR="$TMP/sharedir" \
SRV_ROOT="$TMP/srv" SHARE_PORT=9443 bash -c '
set -uo pipefail
m_uri_host() { printf '%s' "${1:-}"; }   # env.sh 的宿主函数 (单独 source share.sh 时缺)
source "$1/src/share/share.sh" >/dev/null 2>&1
_share_api() { FAKE_SHARE_STORE="$FAKE_SHARE_STORE" python3 "$TMP_FAKE" "$@"; }
export -f _share_api 2>/dev/null || true
# 面板的交互入口在这里被替换成"选这一条", 其余全是真代码
share_pick() { _SHARE_PICKED="$PICK_TOK"; _SHARE_PICKED_REC=$(_share_api get --token "$PICK_TOK"); return 0; }
recs=$(_share_api list)
echo "STORE_EMPTY=$(printf %s "$recs" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")"
recrec=$(_share_create_records all 0 86400 "127.0.0.1")
echo "RECREC=$recrec"
' _ "$ROOT" 2>"$TMP/srv.err" >"$TMP/srv.out" || true
sed 's/^/      /' "$TMP/srv.err" | tail -5

PRIMARY=$(grep '^RECREC=' "$TMP/srv.out" | cut -d= -f2- | cut -f1)
NATIVE=$(grep '^RECREC=' "$TMP/srv.out" | cut -d= -f2- | cut -f2)
DECLARED=$(grep '^RECREC=' "$TMP/srv.out" | cut -d= -f2- | cut -f3)
if [[ -n "$PRIMARY" && -n "$NATIVE" && "$PRIMARY" != "$NATIVE" ]]; then
    ok "建分享 = 两条记录 (普通话 $PRIMARY / 原生 $NATIVE)"
else
    bad "建分享没有产出两条记录 (primary=$PRIMARY native=$NATIVE)"
fi
grep -q 'interop=1' <<<"$DECLARED" && grep -q 'kernel=mihomo' <<<"$DECLARED" \
    && grep -q 'url-upstream=' <<<"$DECLARED" \
    && ok "地址上带声明: $(sed 's/.*\(interop=1.*\)/\1/' <<<"$DECLARED" | cut -c1-70)…" \
    || bad "地址上没有声明: $DECLARED"
# ★ 收束 (2026-10-11): 声明里**不再有 `version`**, 且原生产品**同源时写相对路径**。
#   两条都在**真 share.sh 产出的地址**上验, 不是只验 interop.py 的纯函数 ——
#   生产者那一侧漏掉任何一条, 地址就又会变长(而功能完全正常, 没人会发现)。
grep -q 'version=' <<<"$DECLARED" \
    && bad "声明里还在产出 version: $DECLARED" \
    || ok "声明里不再有 version (版本仍留在原生 record 的 meta 里)"
grep -q 'url-upstream=/share/' <<<"$DECLARED" \
    && ok "同源时原生产品地址写成相对路径 (url-upstream=/share/…)" \
    || { bad "同源却没有写相对路径: $DECLARED"; }
[[ "${#DECLARED}" -lt 220 ]] \
    && ok "地址长度 ${#DECLARED} 字符 (收束前同形态是 231)" \
    || bad "地址仍然过长: ${#DECLARED} 字符"
python3 - "$STORE" "$PRIMARY" "$NATIVE" <<'PYEOF' && ok "主记录=URI 列表且声明原生地址; 原生记录=YAML 且挂回主记录" \
    || bad "两条记录的角色/内容/指向不对"
import json, sys
store, pri, nat = sys.argv[1], sys.argv[2], sys.argv[3]
def load(t):
    return json.load(open("%s/%s.json" % (store, t), encoding="utf-8"))
p, n = load(pri), load(nat)
assert p["meta"]["role"] == "primary", p["meta"]
assert n["meta"]["role"] == "native" and n["meta"]["parent"] == pri, n["meta"]
assert p["meta"]["native_token"] == nat, p["meta"]
assert p["meta"]["formats"] == ["uri", "upstream"], p["meta"]
assert any(l.strip() and not l.strip().startswith("#") and "://" in l
           for l in p["content"].splitlines()), p["content"][:80]
assert "proxies:" in n["content"], n["content"][:80]
assert "application/json" not in p["content_type"]
PYEOF

# ---- 刷新按角色分派 ----
python3 - "$STORE" "$PRIMARY" "$NATIVE" <<'PYEOF'
import json, sys
store, pri, nat = sys.argv[1], sys.argv[2], sys.argv[3]
for t in (pri, nat):
    p = "%s/%s.json" % (store, t)
    r = json.load(open(p, encoding="utf-8"))
    r["content"] = "# 被人手改坏了\n"      # 制造"内容不一致"以逼出刷新
    r["content_sha256"] = "deadbeef"
    json.dump(r, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
SRV_OUT="$FIX/out" SRV_CONF="$FIX/conf" SHARE_DIR="$TMP/sharedir" \
SRV_ROOT="$TMP/srv" SHARE_PORT=9443 bash -c '
set -uo pipefail
m_uri_host() { printf '%s' "${1:-}"; }   # env.sh 的宿主函数 (单独 source share.sh 时缺)
source "$1/src/share/share.sh" >/dev/null 2>&1
_share_api() { FAKE_SHARE_STORE="$FAKE_SHARE_STORE" python3 "$TMP_FAKE" "$@"; }
share_refresh_all >/dev/null 2>&1 || true
' _ "$ROOT" >/dev/null 2>"$TMP/refresh.err" || true
python3 - "$STORE" "$PRIMARY" "$NATIVE" <<'PYEOF' && ok "刷新按角色分派: 主记录刷成 URI 列表, 原生记录刷成 YAML (不串味)" \
    || bad "刷新把两条记录的内容搞混了 (地址上声明原生, 拉到的却是别的格式)"
import json, sys
store, pri, nat = sys.argv[1], sys.argv[2], sys.argv[3]
def load(t):
    return json.load(open("%s/%s.json" % (store, t), encoding="utf-8"))
p, n = load(pri), load(nat)
assert "proxies:" not in p["content"], p["content"][:80]
assert any(l.strip() and "://" in l for l in p["content"].splitlines()), p["content"][:80]
assert "proxies:" in n["content"], n["content"][:80]
PYEOF

# ---- 成对: 停用 / 撤销 / 删除 ----
SRV_OUT="$FIX/out" SRV_CONF="$FIX/conf" SHARE_DIR="$TMP/sharedir" \
SRV_ROOT="$TMP/srv" SHARE_PORT=9443 PICK_TOK="$PRIMARY" bash -c '
set -uo pipefail
m_uri_host() { printf '%s' "${1:-}"; }   # env.sh 的宿主函数 (单独 source share.sh 时缺)
source "$1/src/share/share.sh" >/dev/null 2>&1
_share_api() { FAKE_SHARE_STORE="$FAKE_SHARE_STORE" python3 "$TMP_FAKE" "$@"; }
share_pick() { _SHARE_PICKED="$PICK_TOK"; _SHARE_PICKED_REC=$(_share_api get --token "$PICK_TOK"); return 0; }
share_toggle >/dev/null 2>&1          # 主记录当前 enabled=true → 关
share_toggle >/dev/null 2>&1          # 再开回来
share_revoke_by_tag all >/dev/null 2>&1
' _ "$ROOT" >/dev/null 2>&1 || true
python3 - "$STORE" "$PRIMARY" "$NATIVE" <<'PYEOF' && ok "停用/启用/按 tag 撤销: 主记录与原生记录状态成对 (只动一条 = 静默漏网)" \
    || bad "两条记录的状态不同步 (用户以为停了, 原生记录还活着)"
import json, sys
store, pri, nat = sys.argv[1], sys.argv[2], sys.argv[3]
def load(t):
    return json.load(open("%s/%s.json" % (store, t), encoding="utf-8"))
p, n = load(pri), load(nat)
assert p["enabled"] == n["enabled"] == False, (p["enabled"], n["enabled"])
PYEOF
SRV_OUT="$FIX/out" SRV_CONF="$FIX/conf" SHARE_DIR="$TMP/sharedir" \
SRV_ROOT="$TMP/srv" SHARE_PORT=9443 PICK_TOK="$PRIMARY" bash -c '
set -uo pipefail
m_uri_host() { printf '%s' "${1:-}"; }   # env.sh 的宿主函数 (单独 source share.sh 时缺)
source "$1/src/share/share.sh" >/dev/null 2>&1
_share_api() { FAKE_SHARE_STORE="$FAKE_SHARE_STORE" python3 "$TMP_FAKE" "$@"; }
share_pick() { _SHARE_PICKED="$PICK_TOK"; _SHARE_PICKED_REC=$(_share_api get --token "$PICK_TOK"); return 0; }
share_delete >/dev/null 2>&1
' _ "$ROOT" >/dev/null 2>&1 || true
LEFT=$(ls "$STORE" 2>/dev/null | wc -l)
[[ "$LEFT" == "0" ]] && ok "删除分享: 两条记录一起删干净 (留一条 = 还能拉到同一批节点)" \
                     || bad "删除后还剩下 $LEFT 条记录"

# ---- 旧记录 (2026-10-10 之前的, 没有 role) 刷新闻行为不变 ----
LEGACY=$(FAKE_SHARE_STORE="$STORE" python3 "$TMP/fake_share_api.py" create --type node \
    --content "proxies: [{name: L, type: anytls, server: 203.0.113.9, port: 1}]" \
    --meta '{"tag":"all"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FAKE_SHARE_STORE="$STORE" python3 - "$STORE" "$LEGACY" <<'PYEOF'
import json, sys
r = json.load(open("%s/%s.json" % (sys.argv[1], sys.argv[2]), encoding="utf-8"))
r["content"] = "# 改坏\n"; r["content_sha256"] = "x"
json.dump(r, open("%s/%s.json" % (sys.argv[1], sys.argv[2]), "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
SRV_OUT="$FIX/out" SRV_CONF="$FIX/conf" SHARE_DIR="$TMP/sharedir" \
SRV_ROOT="$TMP/srv" SHARE_PORT=9443 bash -c '
set -uo pipefail
m_uri_host() { printf '%s' "${1:-}"; }   # env.sh 的宿主函数 (单独 source share.sh 时缺)
source "$1/src/share/share.sh" >/dev/null 2>&1
_share_api() { FAKE_SHARE_STORE="$FAKE_SHARE_STORE" python3 "$TMP_FAKE" "$@"; }
share_refresh_all >/dev/null 2>&1 || true
' _ "$ROOT" >/dev/null 2>&1 || true
python3 - "$STORE" "$LEGACY" <<'PYEOF' && ok "旧记录(无 role)刷新后仍是 YAML —— 已发出的分享不因这次改造改变格式" \
    || bad "旧记录被改成了别的格式 (已发出的订阅会被踢下线)"
import json, sys
r = json.load(open("%s/%s.json" % (sys.argv[1], sys.argv[2]), encoding="utf-8"))
assert "proxies:" in r["content"], r["content"][:80]
PYEOF

echo
echo "== ⑨ vendored 兼容层与 canonical 逐字节一致 (例外机制就是漂移的入口) =="
# 为什么要有这一条: `src/lib/proxy_node_compat/` 是 **vendored 副本**, 真源在
# proxy-node-compat 仓库的 `proxy_node_compat/`。副本一旦落后, 表现是
# "判定按旧规则走" —— 不报错, 只是结论悄悄变了。这类漂移已经真实发生过
# (X 的副本落后多处, 靠逐字节比对才发现)。
#
# 判定口径: **逐字节**。不给任何例外 —— 一旦开口子("除某一处之外都相同"),
# 下一次的漂移就藏在那"一处"里, 而比对脚本照样绿。为此本副本曾把证据里的
# 一个真实出口 IP 脱敏成 `<CDN_IP>`, 与 canonical 差一个字符串; 现已改回
# canonical 原文 (取舍写在 research/known-issues/compat-canonical-sync.md,
# 报告里也记了一句)。`__pycache__` 是构建产物, 不参与比对。
#
# canonical 找不到时**不许静默通过**: 打出明确理由并计入"跳过", 摘要行会显示。
#
# ★ 比对基线是 canonical 的**已提交真源** (HEAD blob), 不是它的工作区:
#   canonical 仓库里常有"正在改、还没提交"的文件 —— 那是真源自己的 WIP, 不是
#   副本落后; 把它当漂移会让闸门在真源写一半时**假红**, 而假红的下场是被人
#   习惯性忽略。真源有未提交改动时本闸门会**明确打出来**(不是静默):
#     · 该文件在 canonical HEAD 里 → 比 HEAD; 工作区 != HEAD → 打 WIP 警告
#     · 该文件不在 HEAD 里 (新加的, 如 data/rules.json) → 只能比工作区
#   真源提交新内容却没重新 vendor → 下一跑立刻红。
VEND="$ROOT/src/lib/proxy_node_compat"
CANON="${PNC_CANONICAL:-$ROOT/../proxy-node-compat/proxy_node_compat}"
if [[ ! -d "$CANON" ]]; then
    skip "canonical 检出不存在 —— 本项**未比对**, 不算通过: $CANON"
    printf '       %s\n' "指定方式: PNC_CANONICAL=<proxy-node-compat/proxy_node_compat> bash tools/check_interop.sh" >&2
else
    VENDOR_OUT=$(python3 - "$VEND" "$CANON" <<'PY'
import hashlib, os, subprocess, sys
vend, canon = sys.argv[1], sys.argv[2]
repo = os.path.dirname(canon.rstrip("/"))          # canonical 的仓库根
is_git = os.path.isdir(os.path.join(repo, ".git"))
# canonical 目录在仓库里的相对路径 (HEAD:<这个前缀>/<rel>) —— 少了前缀,
# `cat-file blob HEAD:cli.py` 会失败, 于是每个文件都被当成"不在 HEAD 里",
# 基线悄悄退化成工作区, 闸门反过来指错方向。
prefix = os.path.relpath(os.path.abspath(canon), os.path.abspath(repo)) if is_git else ""

def walk(root):
    out = {}
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d != "__pycache__"]     # 构建产物不比对
        for fn in fns:
            p = os.path.join(dp, fn)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = fh.read()
    return out

def head_blob(rel):
    """canonical 的已提交内容; 不在 HEAD 里返回 None。"""
    if not is_git:
        return None
    hp = rel if prefix in ("", ".") else prefix + "/" + rel
    r = subprocess.run(["git", "-C", repo, "cat-file", "blob", "HEAD:" + hp],
                       capture_output=True)
    return r.stdout if r.returncode == 0 else None

cv, vv = walk(canon), walk(vend)
missing, extra, drift, wip = [], [], [], []
for rel, cbytes in sorted(cv.items()):
    hb = head_blob(rel)
    base = hb if hb is not None else cbytes           # 基线 = 已提交真源
    if rel not in vv:
        missing.append(rel)
        continue
    if vv[rel] != base:
        drift.append(rel)
    elif hb is not None and cbytes != hb:
        wip.append(rel)                               # 真源改了但还没提交
for rel in sorted(set(vv) - set(cv)):
    extra.append(rel)

prob = []
if missing: prob.append("副本缺 %d: %s" % (len(missing), ", ".join(missing)))
if extra: prob.append("副本多 %d: %s" % (len(extra), ", ".join(extra)))
if drift: prob.append("与已提交真源漂移 %d: %s" % (len(drift), ", ".join(drift)))
if prob:
    print("DRIFT\t" + "; ".join(prob))
elif wip:
    print("WIP\t" + ", ".join(wip))
else:
    print("OK\t%d" % len(cv))
PY
)
    case "$VENDOR_OUT" in
        OK*)   ok "vendored 副本与 canonical 已提交真源逐字节相同 (${VENDOR_OUT#OK	} 个文件)" ;;
        WIP*)  warn "vendored 副本与 canonical 已提交真源一致; 但 canonical 工作区有**未提交**改动 —— 未纳入比对: ${VENDOR_OUT#WIP	}"
               printf '       %s\n' "真源提交后请重新 vendor (M 不会去 vendor 未评审的 WIP)" >&2
               skip "canonical 有未提交 WIP (见上, 已明示) —— 本次只比到 HEAD" ;;
        *)     bad "vendored 副本与 canonical 真源漂移: ${VENDOR_OUT#DRIFT	}" ;;
    esac
fi

echo
echo "== ⑩ 客户端: 「文件里有 N 行」不等于「内核认 N 个节点」=="
# 为什么单独一组: 内核拒绝**一条**坏条目时会整批拒绝 provider (实测
# `hy2&obfs=none` → `missing obfs password` → 组里 0 个节点), 而客户端原先
# 只数文件行数, 于是照打 `[OK] 已写入 N 个节点` + `[OK] 解析出 N 个节点` ——
# 用户看到"导入成功"和一个空组。判据必须是**内核真加载数**; 而内核 -t 不加载
# provider (实测同一份坏 provider 上 `-t` 报 test is successful, 退出码 0)。
LOCALURIS="$TMP/local_uris.txt"
cp "$URI_LIST" "$LOCALURIS"
cli_probe() { # <probe 命令> <组名>
    CLI_ROOT="$TMP/cli-$2" MIHOMO_BIN="$FACTDIR/mihomo" \
        M_PROVIDER_LOAD_PROBE="$1" bash "$ROOT/src/client.sh" node-sub "$LOCALURIS" "$2" 2>&1
}
OUT=$(cli_probe 'echo 2' p2)
if grep -q "解析出 2 个节点" <<<"$OUT" && ! grep -q "unbound variable" <<<"$OUT"; then
    ok "本地文件形态导入正常收场 (修前: src/client.sh: line 1156: detail: unbound variable)"
else
    bad "本地文件形态导入仍然异常"; sed 's/^/      /' <<<"$OUT" | tail -6
fi
OUT=$(cli_probe 'echo 0' p0)
grep -q "内核只加载到 0/2 个节点" <<<"$OUT" \
    && ok "内核整批拒绝时客户端把真话打出来 (0/2)" \
    || { bad "内核只加载到 0 个, 客户端没说"; sed 's/^/      /' <<<"$OUT" | tail -6; }
grep -q "订阅里没有解析出节点" <<<"$OUT" \
    && ok "此时按失败收场, 不再宣称「解析出 2 个节点」" \
    || bad "内核加载 0 个却仍报成功 —— 静默假成功"
OUT=$(cli_probe 'echo -1' pu)
grep -q "解析出 2 个节点" <<<"$OUT" && ! grep -q "内核只加载到" <<<"$OUT" \
    && ok "拿不到内核(-1)时不误报: 不拦也不假装验过" \
    || bad "拿不到内核时的行为不对"

printf "\n三家互通闸门 (声明/决策/回退): \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m / \033[33m%d 跳过\033[0m\n" \
    "$PASS" "$FAIL" "$SKIP"
exit $((FAIL > 0))