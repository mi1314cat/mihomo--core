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


echo
echo "== ② 链接 vs 实际监听/当前产物 (发布前一致性闸门) =="
# 判据的现场依据 (RN 真机 2026-10-10): 12 条链接里 9 条是死的 ——
#   * 8 条指向无人监听的端口 (50877/21168/23512/22737/42099/56676/38899/23451;
#     `ss -tulnH` 全表都没有), 真实监听是 25669-25684/28725/22812
#   * 1 条端口在听 (443) 但**凭据早没了** (节点删掉重建换了 uuid) —— 认证过不去
# 这两类都"发出去显示成功、客户端永远连不上"。夹具造出同形态, 断言**拒发**。
L2="$TMP/fix2"
mkdir -p "$L2/out" "$L2/conf/config.d"
cat > "$L2/conf/config.d/anytls-01.yaml" <<'EOF'
listeners:
  - name: mAnyTLS01-TLS
    type: anytls
    listen: "0.0.0.0"
    port: 25684
    users:
      someone: anytlspw
EOF
cat > "$L2/conf/config.d/trojan-04.yaml" <<'EOF'
listeners:
  - name: mTrojan04-CDN-WS
    type: trojan
    listen: "0.0.0.0"
    port: 25680
    users:
      - username: someone
        password: trojanpw
EOF
# cdn_bindings.tsv 与 conf/ 平级 (生产: $SRV_ROOT/cdn_bindings.tsv, conf 在 $SRV_ROOT/conf)
printf 'trojan-04\texample.com\t/home/web/x.conf\tws\t/cdnws-1\t25680\n' > "$L2/cdn_bindings.tsv"
# 当前客户端产物 = "节点现在长什么样"的权威副本
cat > "$L2/out/anytls_client-01.yaml" <<'EOF'
proxies:
  - name: mAnyTLS01-TLS
    type: anytls
    server: 203.0.113.10
    port: 25684
    password: anytlspw
EOF
cat > "$L2/out/trojan_cdn-t-ws_client-04.yaml" <<'EOF'
proxies:
  - name: mTrojan04-CDN-WS
    type: trojan
    server: example.com
    port: 443
    password: trojanpw
EOF
printf 'anytls://anytlspw@203.0.113.10:25684?sni=a.com#good\n'   > "$L2/out/anytls_share-01.txt"
printf 'anytls://deadcred@203.0.113.10:25684?sni=a.com#old-node\n' > "$L2/out/anytls_share-02.txt"
printf 'tuic://anytlspw:pw@203.0.113.10:25684#wrong-type\n'       > "$L2/out/tuicv5_share-01.txt"
printf 'trojan://trojanpw@example.com:443?sni=example.com#cdn\n'  > "$L2/out/trojan_share-04.txt"
printf 'trojan://trojanpw@example.com:8443?sni=example.com#cdn-port-wrong\n' > "$L2/out/trojan_share-05.txt"
printf 'anytls://anytlspw@203.0.113.10:9999?sni=a.com#port-changed\n' > "$L2/out/anytls_share-09.txt"

if python3 "$ROOT/src/share/link_check.py" --out-dir "$L2/out" --conf-dir "$L2/conf" \
        >"$TMP/lc.out" 2>"$TMP/lc.err"; then
    bad "死链没有被挡下 —— 发布闸门失效"
else
    ok "死链被拒发 (退出码 1)"
fi
grep -q "凭据已不在任何当前节点里" "$TMP/lc.err" \
    && ok "凭据已失效也能识别 (端口在听但节点被重建过)" || bad "没识别出凭据失效"
grep -q "不是 tuic" "$TMP/lc.err" && ok "端口被别的协议占了也能识别 (25684 是 anytls)" \
                                  || bad "没识别出协议族对不上"
grep -q "同凭据的 trojan 节点是 example.com:443" "$TMP/lc.err" \
    && ok "链接目标与当前产物不一致能识别 (CDN 端口写错)" || bad "没识别出产物端口不一致"
! grep -q "anytls_share-01.txt" "$TMP/lc.err" \
    && ok "自洽的直连链接放行" || bad "把自洽的链接也拦了 (误报)"
! grep -q "trojan_share-04.txt" "$TMP/lc.err" \
    && ok "自洽的 CDN 链接放行 (域名 + 443 + 回源端口在听)" || bad "CDN 正例被误拦"

STALE_N=$(python3 "$ROOT/src/share/link_check.py" --out-dir "$L2/out" --conf-dir "$L2/conf" \
            --count-only 2>/dev/null)
[[ "$STALE_N" == "4" ]] && ok "陈旧条数 = 4 (凭据死/协议不符/CDN 端口错/产物端口变)" \
                        || bad "陈旧条数应为 4, 实际 $STALE_N"
LIST=$(python3 "$ROOT/src/share/link_check.py" --out-dir "$L2/out" --conf-dir "$L2/conf" \
        --list-stale 2>/dev/null | sort | tr '\n' ' ')
[[ "$LIST" == "anytls_share-02.txt anytls_share-09.txt trojan_share-05.txt tuicv5_share-01.txt " ]] \
    && ok "--list-stale 机器可读清单正确" || bad "--list-stale 清单不对: $LIST"

# 回收: --prune 只删**整体陈旧**的文件, 好的一个都不许动
PR="$TMP/prune"; mkdir -p "$PR/out" "$PR/conf/config.d"
cp "$L2"/conf/config.d/*.yaml "$PR/conf/config.d/"; cp "$L2/cdn_bindings.tsv" "$PR/"
cp "$L2"/out/*.yaml "$L2"/out/*.txt "$PR/out/"
NDEL=$(python3 "$ROOT/src/share/link_check.py" --out-dir "$PR/out" --conf-dir "$PR/conf" \
        --prune --quiet 2>/dev/null | tail -1)
[[ "$NDEL" == "4" ]] && ok "--prune 删掉 4 个陈旧链接" || bad "--prune 删除数应为 4, 实际 $NDEL"
[[ -f "$PR/out/anytls_share-01.txt" && -f "$PR/out/trojan_share-04.txt" ]] \
    && ok "自洽的链接没被误删" || bad "误删了自洽的链接"
[[ ! -f "$PR/out/anytls_share-02.txt" ]] && ok "死链文件已回收" || bad "死链没删掉"
[[ -f "$PR/out/anytls_client-01.yaml" ]] && ok "客户端产物不受清理影响" \
                                        || bad "清理误删了客户端产物"

# 全自洽夹具必须放行 (闸门不能变成"永远红")
L3="$TMP/fix3"; mkdir -p "$L3/out" "$L3/conf/config.d"
cp "$L2"/conf/config.d/*.yaml "$L3/conf/config.d/"; cp "$L2/cdn_bindings.tsv" "$L3/"
cp "$L2"/out/*.yaml "$L3/out/"
printf 'anytls://anytlspw@203.0.113.10:25684?sni=a.com#good\n'   > "$L3/out/anytls_share-01.txt"
printf 'trojan://trojanpw@example.com:443?sni=example.com#cdn\n' > "$L3/out/trojan_share-04.txt"
python3 "$ROOT/src/share/link_check.py" --out-dir "$L3/out" --conf-dir "$L3/conf" \
    >/dev/null 2>&1 && ok "全部自洽时放行 (退出码 0)" || bad "全部自洽却仍报红"

echo
echo "== ③ 链接里不许有会让整条订阅归零的参数 (obfs=none) =="
# 现场依据 (RN 真机): out/hysteria2_share-01/02/10/11.txt 四条都写着
# `&obfs=none` → mihomo 报 `proxy 0 error: missing obfs password` →
# **provider 0 节点**。最狠的是"一票否决": 1 条坏 hy2 + 8 条好链接放同一份
# 订阅 → 整条 0 节点, 8 个好节点一起消失 (实测)。
#
# 断言方式: 从 hysteria2.sh 里**抽出真实的 hy2_link 函数**跑一遍 —— 不能直接
# source 那个脚本 (它加载即进交互菜单), 所以用 sed/python 取函数体, 依赖全部
# 打桩, 只验"生成出来的链接长什么样"。
extract_fn() { # <函数名> <文件>
    python3 - "$1" "$2" <<'PYX'
import re, sys
name, path = sys.argv[1], sys.argv[2]
out, depth, started = [], 0, False
for ln in open(path, encoding="utf-8").read().splitlines():
    if not started:
        if re.match(r"^%s\(\)\s*\{" % re.escape(name), ln):
            started = True
        else:
            continue
    out.append(ln)
    depth += ln.count("{") - ln.count("}")
    if depth <= 0:
        break
print("\n".join(out))
PYX
}
PROBE="$TMP/hy2probe.sh"
{
    echo 'set -u'
    echo 'calc_pin() { :; }'
    echo '_uri_h() { printf "%s" "$1"; }'
    echo 'CERT_FILE=""; CERT_TRUSTED="true"; CERT_DOMAIN="example.com"; CERT_PIN=""'
    echo 'HY_OBFS=""; HY_OBFS_PASSWORD=""'
    echo 'm_hy2_up() { echo 60; }'
    echo 'm_hy2_down() { echo 200; }'
    extract_fn hy2_link "$ROOT/src/conf/hysteria2.sh"
    echo 'echo "NOOBFS=$(hy2_link pw 203.0.113.10 25682 01)"'
    echo 'HY_OBFS="salamander"; HY_OBFS_PASSWORD="pw2"'
    echo 'echo "OBFS=$(hy2_link pw 203.0.113.10 25682 01)"'
} > "$PROBE"
if bash "$PROBE" > "$TMP/hy2probe.out" 2>"$TMP/hy2probe.err"; then
    NOOBFS=$(grep '^NOOBFS=' "$TMP/hy2probe.out" | cut -d= -f2-)
    OBFS=$(grep '^OBFS=' "$TMP/hy2probe.out" | cut -d= -f2-)
    [[ -n "$NOOBFS" ]] || bad "抽不出 hy2_link 的输出 (断言本身失效)"
    grep -q 'obfs=' <<<"$NOOBFS" && bad "无混淆时链接里写了 obfs= ($NOOBFS)" \
                                   || ok "无混淆时链接里不写 obfs (一票否决的根因)"
    ! grep -q 'obfs=none' <<<"$NOOBFS" && ok "链接里没有 obfs=none" \
                                        || bad "链接里还有 obfs=none"
    grep -q 'obfs=salamander&obfs-password=pw2' <<<"$OBFS" \
        && ok "真开了混淆时照写 obfs/obfs-password" || bad "开了混淆反而不写: $OBFS"
else
    bad "hy2_link 探针跑不起来 (见 $TMP/hy2probe.err)"
fi
# 静态兜底: 源码里再出现这个写法就直接红 (防回归)
# ⚠ 必须**去掉注释**再判断 —— 注释里正是在解释为什么删掉它, 直接 grep
#   会把说明文字当成实现 (本项目在"预置不越权"那道闸门里踩过同一个坑)。
_hy2_code=$(sed 's/#.*//' "$ROOT/src/conf/hysteria2.sh" 2>/dev/null)
if grep -q 'obfs=none' <<<"$_hy2_code"; then
    bad "hysteria2.sh 里又有 obfs=none 了"
else
    ok "hysteria2.sh 源码里没有 obfs=none"
fi

echo
echo "== ④ hysteria2 带宽默认值 (上行 60 / 下行 150~200) =="
# 用户偏好就是这一组数。两条红线:
#   · 默认必须落在区间内 (上行 60 / 下行 200)
#   · **不许硬编码覆盖用户自己的设置** —— 用户设过就读 .hy2-bandwidth
#   · 参数名不许写错: mihomo 的 hy2 解析器只认 `up=`/`down=`, upmbps/downmbps
#     是已废弃 hysteria v1 的名字 (写了会被**静默忽略** —— 实测踩过)
BW="$TMP/bw"; mkdir -p "$BW"
{
    echo 'set -u'
    echo 'calc_pin() { :; }'
    echo '_uri_h() { printf "%s" "$1"; }'
    echo 'CERT_FILE=""; CERT_TRUSTED="true"; CERT_DOMAIN="example.com"; CERT_PIN=""'
    echo 'HY_OBFS=""; HY_OBFS_PASSWORD=""'
    echo "SRV_ROOT=$BW"
    # 真实实现 (不许用桩): 设置读取是"用户设了就以用户为准"的唯一实现
    extract_fn m_hy2_bw_state_file "$ROOT/src/lib/env.sh"
    extract_fn m_hy2_bw_get "$ROOT/src/lib/env.sh"
    extract_fn m_hy2_up "$ROOT/src/lib/env.sh"
    extract_fn m_hy2_down "$ROOT/src/lib/env.sh"
    echo 'M_HY2_UP_DEFAULT=60; M_HY2_DOWN_DEFAULT=200'
    echo 'M_HY2_UP_RANGE="30 100"; M_HY2_DOWN_RANGE="150 200"'
    extract_fn hy2_link "$ROOT/src/conf/hysteria2.sh"
    echo 'echo "DEFAULT=$(hy2_link pw 203.0.113.10 25682 01)"'
    echo 'printf "45 170\n" > "$SRV_ROOT/.hy2-bandwidth"'
    echo 'echo "USERSET=$(hy2_link pw 203.0.113.10 25682 01)"'
} > "$BW/probe.sh"
if bash "$BW/probe.sh" > "$BW/out" 2>"$BW/err"; then
    DEF=$(grep '^DEFAULT=' "$BW/out" | cut -d= -f2-)
    USR=$(grep '^USERSET=' "$BW/out" | cut -d= -f2-)
    grep -q 'up=60&down=200' <<<"$DEF" && ok "默认链接带宽 = 上行 60 / 下行 200" \
                                        || bad "默认带宽不对: $DEF"
    grep -q 'upmbps=60&downmbps=200' <<<"$DEF" \
        && ok "同时写了两家内核认识的参数名 (up/down + upmbps/downmbps)" \
        || bad "缺 upmbps/downmbps (sing-box 系客户端会丢带宽)"
    grep -q 'upmbps=50\|downmbps=50' <<<"$DEF" && bad "还在写旧的 50" || ok "旧的 50/200 已不再出现"
    grep -q 'up=45&down=170' <<<"$USR" \
        && ok "用户设过就用用户的 (45/170), 没有被默认值覆盖" \
        || bad "用户设置被硬编码覆盖了: $USR"
else
    bad "带宽探针跑不起来 (见 $BW/err)"
fi
grep -q 'm_hy2_up' "$ROOT/src/conf/all.sh" \
    && ok "批量生成 (all.sh) 也走同一组带宽值" || bad "all.sh 里还是写死的带宽"
_hy2bw=$(grep -c 'm_hy2_up' "$ROOT/src/conf/hysteria2.sh" || true)
(( _hy2bw >= 2 )) && ok "客户端 YAML 与分享链接都读同一处设置" \
                  || bad "hysteria2.sh 里只有 $_hy2bw 处引用设置"

printf "\n分享产物闸门: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$PASS" "$FAIL"
exit $((FAIL > 0))
