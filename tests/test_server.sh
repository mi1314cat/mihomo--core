#!/usr/bin/env bash
# 服务端面板冒烟测试 (非交互)
set -uo pipefail
# 从仓库内跑就用旁边的 src/, 被拷到别处时退回各机器的安装位置
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$HERE/../src}"
[[ -f "$SRC/server.sh" ]] || SRC=/root/catmi/mihomo/src
PASS=0; FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
hdr() { printf "\n\033[1m%s\033[0m\n" "$1"; }

SRV=/root/catmi/mihomo
BACKUP=/tmp/server_backup
mkdir -p "$BACKUP"
cp -f "$SRV/conf/config.yaml" "$BACKUP/config.yaml" 2>/dev/null
cp -f "$SRV/install_info.env" "$BACKUP/install_info.env" 2>/dev/null
echo "  已备份生产配置到 $BACKUP"

cd "$SRV"
HERE="$SRC" SRV_ROOT="$SRV" bash -c '
source /dev/stdin <<EOF
EOF
' 2>/dev/null

# 直接加载面板源码 (跳过交互菜单)
export SRV_ROOT="$SRV"
load_server() {
  # server.sh 末尾会进主菜单, 这里截断到 main_menu 调用之前。
  # server.sh 内部用 HERE 推导 M_LIB, 截断后位置会变成 /tmp, 所以要把
  # M_LIB / HERE 改回真实路径, 否则找不到 lib/ 下的脚本。
  sed -e '/^main_menu "\$@"$/,$d' \
      -e "s#^HERE=.*#HERE=\"$SRC\"#" \
      "$SRC/server.sh" > /tmp/server_lib.sh
  source /tmp/server_lib.sh
}
load_server

hdr "1. 状态与节点清单"
status_block >/tmp/st.txt 2>&1 && ok "status_block 正常" || bad "status_block 报错"
cat /tmp/st.txt | sed 's/^/    /'
list_nodes >/tmp/ln.txt 2>&1 && ok "list_nodes 正常" || bad "list_nodes 报错"
printf "    已列节点: %s\n" "$(grep -c '^  ' /tmp/ln.txt)"

hdr "2. 已知漂移: config.d 里有但 config.yaml 没有的节点"
python3 - <<'PY'
import glob, os, yaml
cd = "/root/catmi/mihomo/conf/config.d"
main = yaml.safe_load(open("/root/catmi/mihomo/conf/config.yaml")) or {}
have = {l.get("name") for l in (main.get("listeners") or []) if isinstance(l, dict)}
miss = []
for f in sorted(glob.glob(cd + "/*.yaml")):
    d = yaml.safe_load(open(f)) or {}
    for l in (d.get("listeners") or [d]):
        if isinstance(l, dict) and l.get("name") not in have:
            miss.append((os.path.basename(f), l.get("name")))
print("  config.d 里有, config.yaml 缺失的监听:", miss if miss else "无")
PY

hdr "3. 更新配置 (合并 → 严格校验 → mihomo -t → 重载)"
if update_config >/tmp/uc.txt 2>&1; then
    ok "update_config 成功"
    sed 's/^/    /' /tmp/uc.txt | tail -6
else
    bad "update_config 失败"; sed 's/^/    /' /tmp/uc.txt | tail -12
fi

hdr "4. 漂移是否已修复"
python3 - <<'PY'
import glob, os, yaml
cd = "/root/catmi/mihomo/conf/config.d"
main = yaml.safe_load(open("/root/catmi/mihomo/conf/config.yaml")) or {}
have = {l.get("name") for l in (main.get("listeners") or []) if isinstance(l, dict)}
miss = []
for f in sorted(glob.glob(cd + "/*.yaml")):
    d = yaml.safe_load(open(f)) or {}
    for l in (d.get("listeners") or [d]):
        if isinstance(l, dict) and l.get("name") not in have:
            miss.append(l.get("name"))
print("  仍缺失:", miss if miss else "无 (漂移已修复)")
PY

hdr "5. 服务仍在运行且端口还在"
systemctl is-active --quiet mihomo && ok "mihomo 服务 active" || bad "mihomo 服务异常"
n=$(ss -tlnp 2>/dev/null | grep "mihomo" | wc -l)
[[ "$n" -ge 6 ]] && ok "监听端口数 $n" || bad "监听端口数只有 $n"
err=$(grep -ci "level=fatal" "$SRV/mihomo.log" 2>/dev/null); err=${err:-0}
[[ "$err" == "0" ]] && ok "无 fatal 日志" || bad "有 $err 条 fatal"

hdr "6. 分享服务"
bash -c 'source '"$SRC"'/share/share.sh; share_service_status' >/tmp/sh.txt 2>&1
sed 's/^/    /' /tmp/sh.txt

hdr "7. 拉取节点 (导入一份公开测试订阅)"
printf 'https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/clash.yml\n' > /tmp/pn.in
pull_node < /tmp/pn.in > /tmp/pn.txt 2>&1
if grep -q "已导入" /tmp/pn.txt; then
    ok "$(grep '已导入' /tmp/pn.txt | tr -d '\n')"
else
    bad "拉取节点失败"; tail -5 /tmp/pn.txt | sed 's/^/    /'
fi

hdr "结果"
printf "  \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$PASS" "$FAIL"
echo "  (生产配置备份在 $BACKUP)"
exit $((FAIL>0))