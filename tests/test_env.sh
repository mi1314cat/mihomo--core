#!/usr/bin/env bash
# env.sh 单元测试: 环境变量读写 + 注入防护
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../src/lib/env.sh"

fail=0
ok()   { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=1; }

T=$(mktemp -d)/install_info.env

echo "== 写入 =="
m_set_env "$T" dest_server "www.bing.com"
m_set_env "$T" UUID "abc-123"
m_set_env "$T" WEIRD 'has "q" and $dollar and \back'
[[ -f "$T" ]] && ok "文件已创建" || bad "文件未创建"

echo "== 读回 =="
m_load_env "$T"
[[ "$dest_server" == "www.bing.com" ]] && ok "dest_server" || bad "dest_server=[$dest_server]"
[[ "$UUID" == "abc-123" ]] && ok "UUID" || bad "UUID=[$UUID]"
[[ "$WEIRD" == 'has "q" and $dollar and \back' ]] && ok "特殊字符往返" || bad "WEIRD=[$WEIRD]"

echo "== 更新已有键 =="
m_set_env "$T" UUID "new-value"
m_load_env "$T"
[[ "$UUID" == "new-value" ]] && ok "更新 UUID" || bad "UUID=[$UUID]"
[[ $(grep -c '^UUID=' "$T") -eq 1 ]] && ok "无重复键" || bad "UUID 出现多次"

echo "== 注入防护 =="
E=$(mktemp)
printf 'EVIL=$(touch /tmp/pwned_marker)\nGOOD="1"\n' > "$E"
rm -f /tmp/pwned_marker
m_load_env "$E"
[[ -z "${EVIL:-}" ]] && ok "恶意内容未被执行" || bad "EVIL=[$EVIL]"
[[ ! -f /tmp/pwned_marker ]] && ok "未创建注入标记文件" || bad "发生了命令注入!"
[[ "$GOOD" == "1" ]] && ok "正常键仍可读取" || bad "GOOD=[$GOOD]"

echo "== 非法键名拒绝 =="
m_set_env "$T" "bad;key" "x" && bad "非法键被接受" || ok "非法键被拒绝"

rm -rf "$(dirname "$T")" "$E" /tmp/pwned_marker
[[ $fail -eq 0 ]] && echo "== 全部通过 ==" || echo "== 存在失败项 =="
exit $fail