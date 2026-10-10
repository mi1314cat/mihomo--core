#!/usr/bin/env bash
# =============================================================
# 节点命名闸门 —— 旗帜必须真的出现在节点名里
#
# 为什么单独一个闸门:
#   "旗帜是服务器的属性"这件事有三处会经过名字（服务端 m_node_tag /
#   客户端加订阅前缀 / 面板显示），每一处都能把它抹掉；改个短名字就
#   没了旗帜这种事发生过。光验函数不够 —— 还要验**真的接上了**。
#
# 全部离线: 旗帜从临时缓存读, 不联网。
# =============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
PASS=0; FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

# ---- 1. 命名实现自检（ISO→emoji / 幂等 / 自带旗帜 / 关旗帜）----
if python3 src/lib/naming.py --selftest >/tmp/.m-naming.log 2>&1; then
    ok "naming.py 自检通过"
else
    bad "naming.py 自检失败"; sed 's/^/      /' /tmp/.m-naming.log | tail -5
fi

# ---- 2. m_node_tag 真的带旗帜（用临时缓存, 不联网）----
TMPD=$(mktemp -d /tmp/.m-naming-XXXXXX)
mkdir -p "$TMPD/share-state"
# ★ 旗帜写死成这个值, 断言也用它 —— 不能直接断言 "🇺🇸":
#   第一版就是这么写的, 于是在本机 (🇺🇸) 全绿、在另一台机器 (🇨🇳) 全红,
#   而代码是同一份。闸门的结果不许取决于跑在哪台机器上。
FLAG="🇺🇸"
printf '%s' "$FLAG" > "$TMPD/share-state/flag"
run_tag() { # <M_TAG_PREFIX> <参数…>
    local pfx="$1"; shift
    M_ROOT="$TMPD" M_TAG_PREFIX="$pfx" SELF_DIR="$PWD/src" \
        bash -c 'source src/lib/env.sh 2>/dev/null; m_node_tag "$@"' _ "$@" 2>/dev/null
}
GOT=$(run_tag m AnyTLS 01 tls)
[[ "$GOT" == "$FLAG mAnyTLS01-TLS" ]] && ok "m_node_tag 带旗帜 ($GOT)" \
    || bad "m_node_tag 带旗帜 (得到 '$GOT')"
GOT=$(run_tag m VLESS 12 reality XHTTP CDN)
[[ "$GOT" == "$FLAG mVLESS12-REALITY-XHTTP-CDN" ]] && ok "带后缀的形态也正确 ($GOT)" \
    || bad "带后缀的形态 ($GOT)"
# 幂等: 同一个名字过两遍不许叠成两个旗帜
TWICE=$(M_ROOT="$TMPD" bash -c 'source src/lib/env.sh 2>/dev/null; a=$(m_node_tag AnyTLS 01 tls); m_with_flag "$a"' 2>/dev/null)
[[ "$(printf '%s' "$TWICE" | grep -o '🇺' | wc -l)" == "1" ]] && ok "重复调用不会叠两层旗帜" \
    || bad "幂等 (得到 '$TWICE')"
# 关掉旗帜时名字照旧（不是变空）
GOT=$(M_ROOT="$TMPD" M_SKIP_FLAG=1 bash -c 'source src/lib/env.sh 2>/dev/null; m_node_tag AnyTLS 01 tls' 2>/dev/null)
[[ "$GOT" == "mAnyTLS01-TLS" ]] && ok "M_SKIP_FLAG=1 时名字照旧 ($GOT)" \
    || bad "M_SKIP_FLAG=1 (得到 '$GOT')"
# 前缀可改（M_TAG_PREFIX）
GOT=$(run_tag "hk-" AnyTLS 01 tls)
[[ "$GOT" == "$FLAG hk-AnyTLS01-TLS" ]] && ok "前缀可自定义 ($GOT)" \
    || bad "前缀可自定义 (得到 '$GOT')"

# ---- 3. 客户端加订阅前缀时, 旗帜必须留在最前面 ----
python3 - "$TMPD" <<'PY'
import re, shutil, sys, textwrap, os
tmp = sys.argv[1]
# 把 client.sh 里的 node_prefix_names 抠出来跑 —— 不 source 整个脚本
# （它会进菜单）。
src = open("src/client.sh", encoding="utf-8").read()
m = re.search(r"node_prefix_names\(\) \{(.*?)\n\}\n", src, re.S)
if not m:
    print("    找不到 node_prefix_names"); sys.exit(3)
body = m.group(1)
# 外层正则把 `}\n` 也吃掉了, 所以 body 以 PY 结尾（没有尾换行）——
# 这里必须用 PY\s*$ 而不是 PY\n, 否则永远匹配不上（第一版就是这么静的）。
py = re.search(r"<<'PY'\n(.*?)\nPY\s*$", body, re.S)
if not py:
    print("    找不到内嵌 python"); sys.exit(3)
code = py.group(1)
p = os.path.join(tmp, "prov.yaml")
open(p, "w", encoding="utf-8").write(
    "proxies:\n"
    "- name: \U0001F1FA\U0001F1F8 mAnyTLS01-TLS\n"
    "- name: mAnyTLS02-TLS\n"
    "- name: \U0001F1ED\U0001F1F0 ds-mVLESS01-REALITY\n")
sys.argv = ["x", p, "ds"]
# 函数本身会 print(changed)（调用方要读它）—— 闸门里把它吞掉,
# 否则那个数字混进闸门输出, 看起来像"多了一行没头没尾的东西"。
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    exec(compile(code, "node_prefix_names", "exec"), {"__name__": "__main__"})
import yaml
got = [x["name"] for x in yaml.safe_load(open(p, encoding="utf-8"))["proxies"]]
want = ["\U0001F1FA\U0001F1F8 ds-mAnyTLS01-TLS",       # 前缀落在旗帜之后
        "ds-mAnyTLS02-TLS",                             # 无旗帜的照老规矩
        "\U0001F1ED\U0001F1F0 ds-mVLESS01-REALITY"]     # 幂等: 不重复加
if got == want:
    print("OK")
else:
    print("BAD 得到 %r" % (got,))
PY
CLI_RC=$?
if [[ $CLI_RC -eq 0 ]]; then ok "客户端加前缀时旗帜留在最前面（幂等）"
else bad "客户端加前缀（见上）"; fi
rm -rf "$TMPD"

# ---- 4. 已有节点的迁移（给旧产物补旗帜）----
if python3 src/lib/naming_migrate.py --selftest >/tmp/.m-migrate.log 2>&1; then
    ok "产物迁移自检通过（含幂等）"
else
    bad "产物迁移自检失败"; sed 's/^/      /' /tmp/.m-migrate.log | tail -5
fi
# shell 包装必须真的指向那份实现（"函数对但没接上"是这里的常客）
if grep -q 'naming_migrate.py' src/lib/env.sh && grep -q 'm_artifacts_apply_flag' src/server.sh; then
    ok "面板入口已接到迁移实现"
else
    bad "面板入口没接到迁移实现"
fi

printf '\n节点命名: %d 通过, %d 失败\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
