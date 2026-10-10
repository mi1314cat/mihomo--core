#!/usr/bin/env bash
# 产物地址族改写测试: m_artifacts_apply_addr + _ca_pick_family 的旧地址取法
#
# 覆盖的都是实际踩过的坑 (前三个是静默失败, 现场看不出来):
#   1. 切回 IPv4 时旧地址取成了 IPv4 本身 -> 整块判断被跳过:
#      状态文件改了、产物一个字节没动, 而且一句话都不说
#   2. 旧地址是 IPv6 时, 链接里写的是 @[addr]:port —— 按裸地址匹配永远不中:
#      YAML 改得到, 链接一处不改, 两者对不上
#   3. 订阅 URL (share_tag-*.txt) 不在扫描范围内, 主机停在旧地址族
#   4. 回归: CDN 节点的域名、他机 IP 必须原样保留 —— 只改**等于旧地址**的那些
#
# 全程在临时目录里跑, 不碰任何真实产物; 本机地址被打桩, 不依赖跑测机器的网卡。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

pass=0; fails=0
ok()  { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
bad() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf "        实际: %s\n" "$2"; fails=$((fails + 1)); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "期望[$3] 得到[$2]"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export SRV_ROOT="$T/root" SRV_OUT="$T/out" M_LIB="$REPO/src/lib"
mkdir -p "$SRV_ROOT" "$SRV_OUT"
# shellcheck source=/dev/null
source "$REPO/src/lib/env.sh"

# 本机地址打桩 —— 测试不能依赖跑测机器的真实网卡
OUR4="203.0.113.10"; OUR6="2001:db8::1"; OTHER4="198.51.100.77"; CDNDOM="cdn.example.com"
m_addr4_real() { printf '%s' "$OUR4"; }
m_addr6_real() { printf '%s' "$OUR6"; }
# 订阅重生成与分享内容刷新在真机上要联网/写盘, 这里打桩
_ca_regen_sub() { :; }
share_refresh_all() { :; }

# _ca_pick_family 定义在 server.sh 里, 而 server.sh 末尾会直接进主菜单 —— 不能整个
# source。只取这一个函数体, 它依赖的动作已在上面打桩。
eval "$(sed -n '/^_ca_pick_family() {/,/^}/p' "$REPO/src/server.sh")"
declare -F _ca_pick_family >/dev/null || { bad "取不到 _ca_pick_family (server.sh 结构变了?)"; exit 1; }

srv() { grep -m1 -oE 'server: .*' "$1" 2>/dev/null; }

mkfix() {
    cat > "$SRV_OUT/VLESS_client-01.yaml" <<EOF
proxies:
  - name: VLESS-01
    type: vless
    server: $OUR4
    port: 443
    servername: $CDNDOM
EOF
    # CDN 节点: server 是证书域名 (走 Cloudflare), 换地址族不该动
    cat > "$SRV_OUT/VLESS_cdn_client-02.yaml" <<EOF
proxies:
  - name: VLESS-cdn-02
    type: vless
    server: $CDNDOM
    port: 443
EOF
    # 他机/中转节点: 不是本机地址, 更不该动
    cat > "$SRV_OUT/Trojan_client-03.yaml" <<EOF
proxies:
  - name: Trojan-03
    type: trojan
    server: $OTHER4
    port: 443
EOF
    echo "vless://uuid-1@$OUR4:443?security=tls&sni=$CDNDOM#VLESS-01"      > "$SRV_OUT/VLESS_share-01.txt"
    echo "vless://uuid-2@$CDNDOM:443?security=tls&sni=$CDNDOM#VLESS-cdn-02" > "$SRV_OUT/VLESS_cdn_share-02.txt"
    echo "trojan://pw@$OTHER4:443?sni=relay.example.net#Trojan-03"          > "$SRV_OUT/Trojan_share-03.txt"
    echo "http://$OUR4:9443/share/tokall"                                   > "$SRV_OUT/share_tag-all.txt"
}

echo "== 菜单: IPv4 -> IPv6 =="
mkfix
printf '2\ny\n' | _ca_pick_family >/dev/null 2>&1
eq "直连 YAML 切到 IPv6"          "$(srv "$SRV_OUT/VLESS_client-01.yaml")" "server: $OUR6"
eq "CDN YAML 保留域名"            "$(srv "$SRV_OUT/VLESS_cdn_client-02.yaml")" "server: $CDNDOM"
eq "他机 IP 原样"                 "$(srv "$SRV_OUT/Trojan_client-03.yaml")" "server: $OTHER4"
eq "直连链接切到 [IPv6]:port"     "$(cat "$SRV_OUT/VLESS_share-01.txt")" \
   "vless://uuid-1@[$OUR6]:443?security=tls&sni=$CDNDOM#VLESS-01"
eq "CDN 链接原样 (域名)"          "$(cat "$SRV_OUT/VLESS_cdn_share-02.txt")" \
   "vless://uuid-2@$CDNDOM:443?security=tls&sni=$CDNDOM#VLESS-cdn-02"
eq "他机链接原样"                 "$(cat "$SRV_OUT/Trojan_share-03.txt")" \
   "trojan://pw@$OTHER4:443?sni=relay.example.net#Trojan-03"
eq "订阅 URL 跟着切"              "$(cat "$SRV_OUT/share_tag-all.txt")" "http://[$OUR6]:9443/share/tokall"
eq "状态文件 = v6"                "$(cat "$SRV_ROOT/.addr-family")" "v6"

echo "== 菜单: IPv6 -> IPv4 (原来整段静默跳过) =="
printf '1\ny\n' | _ca_pick_family >/dev/null 2>&1
eq "状态文件 = v4"                "$(cat "$SRV_ROOT/.addr-family")" "v4"
eq "直连 YAML 切回 IPv4"          "$(srv "$SRV_OUT/VLESS_client-01.yaml")" "server: $OUR4"
eq "直连链接切回 IPv4"            "$(cat "$SRV_OUT/VLESS_share-01.txt")" \
   "vless://uuid-1@$OUR4:443?security=tls&sni=$CDNDOM#VLESS-01"
eq "订阅 URL 切回 IPv4"           "$(cat "$SRV_OUT/share_tag-all.txt")" "http://$OUR4:9443/share/tokall"
eq "CDN 域名始终没被碰过"         "$(srv "$SRV_OUT/VLESS_cdn_client-02.yaml")" "server: $CDNDOM"

echo "== 直调 m_artifacts_apply_addr: 旧地址是 IPv6 (带方括号的链接) =="
printf 'proxies:\n  - name: X\n    server: %s\n    port: 443\n' "$OUR6" > "$SRV_OUT/VLESS_client-09.yaml"
echo "vless://uuid-9@[$OUR6]:443?sni=x#VLESS-09" > "$SRV_OUT/VLESS_share-09.txt"
echo "http://[$OUR6]:9443/share/tok9"            > "$SRV_OUT/share_tag-09.txt"
N=$(m_artifacts_apply_addr "$OUR4" "$OUR6")
eq "YAML 匹配裸 IPv6 并替换"      "$(srv "$SRV_OUT/VLESS_client-09.yaml")" "server: $OUR4"
eq "带方括号的链接也匹配到"       "$(cat "$SRV_OUT/VLESS_share-09.txt")" "vless://uuid-9@$OUR4:443?sni=x#VLESS-09"
eq "订阅 URL 也改了"              "$(cat "$SRV_OUT/share_tag-09.txt")" "http://$OUR4:9443/share/tok9"
eq "改动处数 = 3 (YAML+链接+订阅URL)" "$N" "3"

echo "== 幂等与空目录 =="
eq "重复执行报告 0 处"            "$(m_artifacts_apply_addr "$OUR4" "$OUR6")" "0"
eq "订阅 URL 未被二次改写"        "$(cat "$SRV_OUT/share_tag-09.txt")" "http://$OUR4:9443/share/tok9"
EMPTY="$T/empty"; mkdir -p "$EMPTY"
eq "空目录报告 0 处"              "$(SRV_OUT="$EMPTY" m_artifacts_apply_addr "$OUR4" "$OUR6")" "0"

echo
if (( fails == 0 )); then
    printf "  \033[32m全部通过\033[0m (%d 项)\n" "$pass"
else
    printf "  \033[31m有失败\033[0m (%d 通过 / %d 失败)\n" "$pass" "$fails"
fi
exit $(( fails > 0 ))
