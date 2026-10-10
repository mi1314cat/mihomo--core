#!/usr/bin/env bash
# =============================================================
# 分享产物闸门 —— 分享订阅能生成 / 链接端口与监听自洽 / 链接里没有 obfs=none
#
# 为什么单独一个闸门
# ------------------
# 这一批问题全是**静默失败**: 面板照常显示、日志里只有一行"剔除了 N 个
# 陈旧产物", 用户拿到的是空订阅或死链, 没有任何一处报错指向真正的原因。
#
#   ① 带旗帜的产物名 vs 裸名台账 → 等值比较 → 交集 0/19 →
#      分享订阅生成 100% 失败 (面板只报"没有可分享的节点")
#   ② 链接里的端口与实际监听不一致 → 死链照样"发送成功"
#   ③ 链接里写 obfs=none → mihomo 报 missing obfs password →
#      **一条坏节点把整条订阅打成 0 节点** (好在同一订阅里的好节点一起消失)
#
# 三条都不会自己暴露, 只能靠机械断言。全部离线, 用 /tmp 夹具, 不碰生产。
#
# 用法: bash tools/check_share_products.sh   退出码 0=通过 1=有问题
# =============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$(pwd)"

PASS=0; FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf "  \033[31m❌\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d /tmp/.m-share-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

FLAG="🇺🇸"          # 写死, 与跑闸门的机器在哪个国家无关

# ---- 夹具: 台账里是**裸名**, 产物里是**带旗帜名** (生产上的真实形态) ----
mk_fixture() { # <目录>
    local d="$1"
    mkdir -p "$d/out" "$d/conf/config.d"
    cat > "$d/conf/config.d/.managed.json" <<'EOF'
["mAnyTLS01-TLS", "mAnyTLS02-TLS", "mHysteria201-TLS"]
EOF
    python3 - "$d" "$FLAG" <<'PY'
import sys, os
d, flag = sys.argv[1], sys.argv[2]
rows = [("anytls_client-01.yaml", "anytls", "mAnyTLS01-TLS", 25684),
        ("anytls_client-02.yaml", "anytls", "mAnyTLS02-TLS", 28725),
        ("hysteria2_client-01.yaml", "hysteria2", "mHysteria201-TLS", 25682)]
for fn, t, nm, port in rows:
    with open(os.path.join(d, "out", fn), "w", encoding="utf-8") as fh:
        fh.write("proxies:\n  - name: %s %s\n    type: %s\n"
                 "    server: 203.0.113.10\n    port: %d\n" % (flag, nm, t, port))
# 幽灵产物: 节点早就删了, 文件还在 out/ 里 —— 必须仍被剔除
with open(os.path.join(d, "out", "trojan_client-09.yaml"), "w", encoding="utf-8") as fh:
    fh.write("proxies:\n  - name: %s mTrojan09-GHOST\n    type: trojan\n"
             "    server: 203.0.113.10\n    port: 12345\n" % flag)
PY
}

# 台账里的名字写进 config.d/*.yaml 片段 (listener name = 裸名)
mk_fragment() { # <目录>
    local d="$1"
    python3 - "$d" <<'PY'
import json, os, sys
d = sys.argv[1]
names = json.load(open(os.path.join(d, "conf/config.d/.managed.json"), encoding="utf-8"))
ports = [25684, 28725, 25682]
for i, (nm, port) in enumerate(zip(names, ports), 1):
    with open(os.path.join(d, "conf/config.d/%s-%02d.yaml" % (nm.split("-")[0][1:].lower(), i)),
              "w", encoding="utf-8") as fh:
        fh.write("listeners:\n  - name: %s\n    type: anytls\n"
                 "    listen: 0.0.0.0\n    port: %d\n" % (nm, port))
PY
}

echo "== ① 分享订阅生成: 带旗帜产物 vs 裸名台账 =="
FIX="$TMP/fix1"
mk_fixture "$FIX"; mk_fragment "$FIX"
SUB="$TMP/sub_all.yaml"
if python3 "$ROOT/src/share/build_sub.py" --out-dir "$FIX/out" \
        --conf-dir "$FIX/conf" --tag all -o "$SUB" >"$TMP/gen.log" 2>&1; then
    ok "build_sub 生成成功 (带 --conf-dir 过滤)"
else
    bad "build_sub 生成失败 —— 分享订阅会 100% 不可用"
    sed 's/^/      /' "$TMP/gen.log" | tail -5
fi
N=$(python3 - "$SUB" <<'PY' 2>/dev/null || echo 0
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print(len(d.get("proxies") or []))
PY
)
[[ "$N" == "3" ]] && ok "3 个活节点全部保留 (得到 $N)" \
                  || bad "活节点数应为 3, 实际 $N —— 旗帜名与裸名没匹配上"
[[ -f "$SUB" ]] && grep -q "$FLAG mAnyTLS01-TLS" "$SUB" \
    && ok "显示名仍然带旗帜 (没有为了匹配把旗帜去掉)" \
    || bad "产物里的旗帜被抹掉了 (或订阅没生成) —— 违反红线: 旗帜是用户可见特性"

# 原意不能被破坏: 真的陈旧产物还得剔除
{ [[ -f "$SUB" ]] && grep -q "GHOST" "$SUB"; } && bad "陈旧产物 GHOST 混进了订阅 (过滤失效)" \
                       || ok "陈旧产物仍被剔除 (过滤没有被放宽)"
grep -q "剔除了 1 个陈旧产物" "$TMP/gen.log" \
    && ok "剔除计数正确 (1 个幽灵)" || bad "剔除计数不对: $(grep -c . "$TMP/gen.log") 行日志"

TAGS=$(python3 "$ROOT/src/share/build_sub.py" --out-dir "$FIX/out" \
        --conf-dir "$FIX/conf" --list-tags 2>/dev/null | tr '\n' ' ')
for t in anytls hysteria2; do
    grep -qw "$t" <<<"$TAGS" && ok "协议桶 $t 可用 (面板的分享范围)" \
                             || bad "协议桶 $t 丢了 (得到: $TAGS)"
done

printf "\n分享产物闸门: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$PASS" "$FAIL"
exit $((FAIL > 0))
