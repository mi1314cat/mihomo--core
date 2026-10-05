#!/usr/bin/env bash
# =============================================================
# 一键生成全协议节点 (all.sh)
#
#   一次跑完所有能在当前 Mihomo 内核上做 **入站** 的协议,
#   最后统一走 merge → 严格校验 → mihomo -t → 重载。
#
# 与逐个菜单添加的区别:
#   * 不需要反复交互, 端口自动分配
#   * 全部节点共享同一套 UUID / Reality 密钥 / 证书
#   * 任何一个协议失败不影响其他, 末尾统一汇总
#   * 最终只重载一次, 中途不会把服务弄成半死状态
#
# 用法:
#   bash all.sh                    # 自动检测证书, 生成全部
#   bash all.sh --no-tls           # 跳过所有需要证书的协议
#   bash all.sh --only reality,trojan,hysteria2
#   bash all.sh --dry-run          # 只看会生成什么, 不落盘
# =============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SELF_DIR/../lib/env.sh" 2>/dev/null || {
    echo "找不到 src/lib/env.sh, 请从仓库内运行" >&2; exit 1; }

CONF_DIR="${CONF_DIR:-$SRV_ROOT/conf/config.d}"
OUT_DIR="${OUT_DIR:-$SRV_ROOT/out}"
CERTS_DIR="${CERTS_DIR:-$SRV_ROOT/conf/certs}"
MIHOMO_BIN="${MIHOMO_BIN:-$SRV_BIN}"

GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; CYAN="\033[36m"
MAGENTA="\033[35m"; BOLD="\033[1m"; RESET="\033[0m"
info()  { printf "${CYAN}·${RESET} %s\n" "$1" >&2; }
# env.sh 的 m_sync / m_sync_reload 会调用 print_*, 这里必须提供
print_info()  { info "$1"; }
print_ok()    { ok "$1"; }
print_warn()  { warn "$1"; }
print_error() { err "$1"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$1" >&2; }
warn()  { printf "${YELLOW}!${RESET} %s\n" "$1" >&2; }
err()   { printf "${RED}✗${RESET} %s\n" "$1" >&2; }

DRY_RUN=0
USE_TLS=1
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-tls)  USE_TLS=0 ;;
        --only)    shift; ONLY="$1" ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
    shift
done

# =============================================================
# 端口分配: 从 20000 起找一个没被占用的
# =============================================================
USED_PORTS_FILE=$(mktemp)
trap 'rm -f "$USED_PORTS_FILE"' EXIT
: > "$USED_PORTS_FILE"

collect_used_ports() {
    # 已存在的 config.d + 正在运行的监听
    python3 - "$CONF_DIR" >> "$USED_PORTS_FILE" <<'PY'
import glob, sys, yaml
for f in glob.glob(sys.argv[1] + "/*.yaml"):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8")) or {}
    except Exception:
        continue
    for l in (d.get("listeners") or []):
        if isinstance(l, dict) and l.get("port"):
            print(l["port"])
PY
    # 主配置里已有的
    python3 - "${SRV_CONF}/config.yaml" >> "$USED_PORTS_FILE" 2>/dev/null <<'PY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    raise SystemExit
for l in (d.get("listeners") or []):
    if isinstance(l, dict) and l.get("port"):
        print(l["port"])
PY
    ss -tln 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://' >> "$USED_PORTS_FILE"
}

next_port() {
    local p=$(( ${1:-20000} ))
    for _ in $(seq 1 4000); do
        if ! grep -qx "$p" "$USED_PORTS_FILE"; then
            echo "$p" >> "$USED_PORTS_FILE"
            printf '%s' "$p"; return 0
        fi
        p=$((p + 1))
    done
    return 1
}

next_index() {  # next_index <proto>
    local proto="$1" i=1
    shopt -s nullglob
    while (( i < 100 )); do
        local f; printf '%s\n' "$CONF_DIR/$proto-$(printf '%02d' $i).yaml" | grep -qxF "$CONF_DIR/$proto-$(printf '%02d' $i).yaml" || true
        f=$(printf '%s/%s-%02d.yaml' "$CONF_DIR" "$proto" "$i")
        [[ -f "$f" ]] || { printf '%02d' "$i"; return; }
        i=$((i + 1))
    done
    printf '01'
}

# =============================================================
# 前置: 环境变量 / Reality 密钥 / 证书
# =============================================================
ensure_env() {
    [[ -x "$MIHOMO_BIN" ]] || { err "未找到 mihomo 内核: $MIHOMO_BIN"; exit 1; }
    if [[ ! -f "$SRV_ENV" ]] || ! m_load_env "$SRV_ENV"; then
        info "首次运行, 生成环境变量..."
        bash "$SELF_DIR/XRevise.sh" >/dev/null 2>&1 || {
            err "环境变量生成失败"; exit 1; }
    fi
    m_load_env "$SRV_ENV"
    [[ -n "${UUID:-}" ]] || { err "缺少 UUID"; exit 1; }
}

ensure_reality() {
    if [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]]; then
        info "复用已有 Reality 密钥"; return 0
    fi
    info "生成 Reality 密钥对..."
    local out priv pub sid
    out=$("$MIHOMO_BIN" generate reality-keypair 2>/dev/null) || { err "密钥生成失败"; return 1; }
    priv=$(grep -i "private" <<<"$out" | head -1 | tr -d ' \r' | cut -d: -f2)
    pub=$(grep -i "public"  <<<"$out" | head -1 | tr -d ' \r' | cut -d: -f2)
    sid=$(grep -i "short"   <<<"$out" | head -1 | tr -d ' \r' | cut -d: -f2)
    [[ -n "$priv" && -n "$pub" ]] || { err "无法解析密钥"; return 1; }
    [[ -n "$sid" ]] || sid=$(openssl rand -hex 4)
    m_set_env "$SRV_ENV" PRIVATE_KEY "$priv"
    m_set_env "$SRV_ENV" PUBLIC_KEY  "$pub"
    m_set_env "$SRV_ENV" SHORT_ID    "$sid"
    PRIVATE_KEY="$priv"; PUBLIC_KEY="$pub"; SHORT_ID="$sid"
    ok "Reality 密钥已生成并保存"
}

# 证书目录里的命名相当杂:
#   cert-bing.com.crt            + cert-bing.com.key
#   cert-01-cert-x.com.crt       + cert-01-key-x.com.key
#   x.com_cert.pem               + x.com_key.pem
# 最坑的是 *_cert.pem 既是证书, 又因为带 .pem 很容易被当成 key 选进去,
# 结果内核报 "failed to find any PEM data in certificate input"。
# 所以这里**按文件内容**判断, 不靠文件名。
find_cert() {
    python3 - "$CERTS_DIR" <<'PYCERT' 2>/dev/null
import glob, os, re, sys

d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, "*.crt")) +
               glob.glob(os.path.join(d, "*.pem")) +
               glob.glob(os.path.join(d, "*.key")))

def head(p, n=400):
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read(n)
    except OSError:
        return ""

certs  = [f for f in files if "BEGIN CERTIFICATE" in head(f)]
keys   = [f for f in files if "PRIVATE KEY" in head(f)]
others = [f for f in files if f not in certs and f not in keys]

def domain_of(p):
    b = os.path.basename(p)
    b = re.sub(r"^cert-\d+-cert-", "", b)
    b = re.sub(r"^cert-", "", b)
    b = re.sub(r"_cert\.pem$", "", b)
    b = re.sub(r"_key\.pem$", "", b)
    b = re.sub(r"\.(crt|pem|key)$", "", b)
    return b.lower()

# 按域名精确配对
by_dom = {}
for k in keys:
    by_dom.setdefault(domain_of(k), k)
for c in certs:
    dom = domain_of(c)
    if dom in by_dom:
        print(f"{c}\t{by_dom[dom]}\t{dom}")
        raise SystemExit

# 配不上就退回: 第一张证书 + 第一把私钥 (内核会校验是否匹配)
if certs and keys:
    print(f"{certs[0]}\t{keys[0]}\t{domain_of(certs[0])}")
else:
    sys.stderr.write(f"cert={len(certs)} key={len(keys)} other={len(others)}\n")
PYCERT
}

# =============================================================
# 生成器
# =============================================================
RESULTS=()

record() {  # record <协议> <端口> <状态> <说明>
    RESULTS+=("$1|$2|$3|$4")
}

want() {  # 是否选中该协议
    [[ -z "$ONLY" ]] && return 0
    [[ ",$ONLY," == *",$1,"* ]]
}

# gen <proto> <标签> <需要reality> <需要tls>
gen() {
    local proto="$1" label="$2" need_reality="$3" need_tls="$4"
    shift 4
    local body="$*"          # 实际生成 listener 的函数名 + 参数

    if ! want "$proto"; then return; fi
    if [[ "$need_tls" == "1" && "$USE_TLS" == "0" ]]; then
        record "$label" "-" "跳过" "需要证书 (--no-tls)"; return
    fi
    if [[ "$need_tls" == "1" && -z "$CRT" ]]; then
        record "$label" "-" "跳过" "无可用证书"; return
    fi
    if [[ "$need_reality" == "1" && -z "${PUBLIC_KEY:-}" ]]; then
        record "$label" "-" "跳过" "无 Reality 密钥"; return
    fi

    local idx port
    idx=$(next_index "$proto")
    port=$(next_port "$PORT_BASE") || { record "$label" "-" "失败" "无可用端口"; return; }

    local in_file out_file
    in_file=$(printf '%s/%s-%s.yaml' "$CONF_DIR" "$proto" "$idx")
    out_file=$(printf '%s/%s_client-%s.yaml' "$OUT_DIR" "$proto" "$idx")

    if [[ "$DRY_RUN" == "1" ]]; then
        record "$label" "$port" "预览" "将写入 $(basename "$in_file")"
        return
    fi

    if "$body" "$idx" "$port" "$in_file" "$out_file"; then
        record "$label" "$port" "成功" ""
    else
        record "$label" "$port" "失败" "生成器返回非 0"
    fi
}

# ---------- 各协议模板 ----------
g_reality() {
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: reality-$1
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
        flow: xtls-rprx-vision
    # ★ listener 端是 reality-config + 私钥; reality-opts/public-key 是**客户端**用的
    reality-config:
      dest: ${dest_server}:443
      private-key: $PRIVATE_KEY
      short-id:
        - $SHORT_ID
      server-names:
        - $dest_server
EOF
    cat > "$4" <<EOF
proxies:
  - name: Reality-$1
    type: vless
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: chrome
EOF
}

g_trojan_reality() {
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: trojan-$1
    type: trojan
    listen: "0.0.0.0"
    port: $2
    users:
      - username: $UUID
        password: $UUID
    reality-config:
      dest: ${dest_server}:443
      private-key: $PRIVATE_KEY
      short-id:
        - $SHORT_ID
      server-names:
        - $dest_server
EOF
    cat > "$4" <<EOF
proxies:
  - name: Trojan-Reality-$1
    type: trojan
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    udp: true
    sni: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: chrome
EOF
}

g_trojan_tls() {
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: trojan-tls-$1
    type: trojan
    listen: "0.0.0.0"
    port: $2
    users:
      - username: $UUID
        password: $UUID
    certificate: $CRT
    private-key: $KEY
EOF
    cat > "$4" <<EOF
proxies:
  - name: Trojan-TLS-$1
    type: trojan
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    udp: true
    sni: $SNI
    skip-cert-verify: true
EOF
}

g_vless_ws() {
    local path="/ws$1"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: vless-ws-$1
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
    ws-path: $path
    # v1.19.x 起, 明文 VLESS 入站必须显式 allow-insecure,
    # 否则内核直接拒绝: "disallow using Vless without any certificates/..."
    allow-insecure: true
EOF
    cat > "$4" <<EOF
proxies:
  - name: VLESS-WS-$1
    type: vless
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    network: ws
    tls: false
    udp: true
    ws-opts:
      path: $path
EOF
}

g_vless_ws_tls() {
    local path="/wss$1"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: vless-wss-$1
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
    ws-path: $path
    certificate: $CRT
    private-key: $KEY
EOF
    cat > "$4" <<EOF
proxies:
  - name: VLESS-WSS-$1
    type: vless
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    network: ws
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $SNI
    ws-opts:
      path: $path
EOF
}

g_vmess_ws() {
    local path="/vm$1"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: vmess-$1
    type: vmess
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
        alterId: 0
    ws-path: $path
EOF
    cat > "$4" <<EOF
proxies:
  - name: VMess-WS-$1
    type: vmess
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    alterId: 0
    cipher: auto
    network: ws
    tls: false
    udp: true
    ws-opts:
      path: $path
EOF
}

g_hysteria2() {
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: hysteria2-$1
    type: hysteria2
    listen: "0.0.0.0"
    port: $2
    users:
      user1: $UUID
    certificate: $CRT
    private-key: $KEY
    masquerade: https://www.bing.com
EOF
    cat > "$4" <<EOF
proxies:
  - name: Hysteria2-$1
    type: hysteria2
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    sni: $SNI
    skip-cert-verify: true
    up: "30"
    down: "200"
EOF
}

g_tuicv5() {
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: tuicv5-$1
    type: tuic
    listen: "0.0.0.0"
    port: $2
    users:
      $UUID: $UUID
    certificate: $CRT
    private-key: $KEY
    congestion-controller: bbr
    max-idle-time: 15000
    alpn:
      - h3
EOF
    cat > "$4" <<EOF
proxies:
  - name: TUICv5-$1
    type: tuic
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    password: $UUID
    sni: $SNI
    skip-cert-verify: true
    alpn:
      - h3
    congestion-controller: bbr
EOF
}

g_anytls() {
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: anytls-$1
    type: anytls
    listen: "0.0.0.0"
    port: $2
    users:
      $UUID: $UUID
    certificate: $CRT
    private-key: $KEY
EOF
    cat > "$4" <<EOF
proxies:
  - name: AnyTLS-$1
    type: anytls
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    sni: $SNI
    skip-cert-verify: true
    udp: true
    client-fingerprint: chrome
EOF
}

g_shadowsocks() {
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: ss-$1
    type: shadowsocks
    listen: "0.0.0.0"
    port: $2
    cipher: aes-128-gcm
    password: $UUID
    udp: true
EOF
    cat > "$4" <<EOF
proxies:
  - name: Shadowsocks-$1
    type: ss
    server: $PUBLIC_IP
    port: $2
    cipher: aes-128-gcm
    password: $UUID
    udp: true
EOF
}

g_snell() {
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: snell-$1
    type: snell
    listen: "0.0.0.0"
    port: $2
    psk: $UUID
    version: "3"
EOF
    cat > "$4" <<EOF
proxies:
  - name: Snell-$1
    type: snell
    server: $PUBLIC_IP
    port: $2
    psk: $UUID
    version: "3"
EOF
}

# =============================================================
# 主流程
# =============================================================
PORT_BASE="${ALL_PORT_BASE:-20000}"

printf "${MAGENTA}${BOLD}╔══════════════════════════════════════════════╗\n"
printf "║  一键生成全协议节点                              ║\n"
printf "╚══════════════════════════════════════════════╝${RESET}\n"

ensure_env
ensure_reality
m_pick_dest "${dest_server:-}" >/dev/null 2>&1 || true
[[ -n "${dest_server:-}" ]] || dest_server="www.bing.com"

CRT=""; KEY=""; SNI=""
if [[ "$USE_TLS" == "1" ]]; then
    local pair; pair=$(find_cert)
    if [[ -n "$pair" ]]; then
        IFS=$'\t' read -r CRT KEY SNI <<<"$pair"
    fi
    [[ -n "$CRT" && -f "$CRT" && -n "$KEY" && -f "$KEY" ]] || { CRT=""; KEY=""; SNI=""; }
    if [[ -n "$CRT" ]]; then ok "使用证书: $(basename "$CRT")  (sni=$SNI)"
    else warn "未找到证书, 将跳过需要 TLS 的协议"; fi
fi

PUBLIC_IP=$(m_server_ip)
[[ -z "$PUBLIC_IP" ]] && { err "拿不到对外地址, 请先在 install_info.env 里设置 PUBLIC_IP"; exit 1; }
info "对外地址: $PUBLIC_IP"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERTS_DIR"
collect_used_ports

printf '\n'
gen reality        "VLESS+Reality"  1 0 g_reality
gen trojan         "Trojan+Reality" 1 0 g_trojan_reality
gen trojan-tls     "Trojan+TLS"     0 1 g_trojan_tls
gen vless          "VLESS+WS"       0 0 g_vless_ws
gen vless-ws       "VLESS+WS+TLS"   0 1 g_vless_ws_tls
gen vmess          "VMess+WS"       0 0 g_vmess_ws
gen hysteria2      "Hysteria2"      0 1 g_hysteria2
gen tuicv5         "TUIC v5"        0 1 g_tuicv5
gen anytls         "AnyTLS"         0 1 g_anytls
gen ss             "Shadowsocks"    0 0 g_shadowsocks
gen snell          "Snell"          0 0 g_snell

# ---------- 汇总 ----------
printf "\n${BOLD}生成结果${RESET}\n"
printf "  %-18s %-8s %-8s %s\n" "协议" "端口" "状态" "备注"
printf "  %s\n" "────────────────────────────────────────────────────"
local_fail=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r p port st note <<<"$r"
    case "$st" in
        成功) stc="${GREEN}${st}${RESET}" ;;
        预览) stc="${CYAN}${st}${RESET}" ;;
        失败) stc="${RED}${st}${RESET}"; local_fail=$((local_fail+1)) ;;
        *)    stc="${YELLOW}${st}${RESET}" ;;
    esac
    printf "  %-18s %-8s %-18b %s\n" "$p" "$port" "$stc" "$note"
done

if [[ "$DRY_RUN" == "1" ]]; then
    printf "\n${YELLOW}预览模式, 未写入任何文件${RESET}\n"
    exit 0
fi

# ---------- 统一校验 + 重载 ----------
printf '\n${BOLD}校验并应用${RESET}\n'
if m_sync_reload; then
    n_ok=$(grep -c "成功" /dev/null 2>/dev/null || echo 0)
    printf "\n${GREEN}${BOLD}全协议节点已生成并生效${RESET}\n"
    printf "  配置目录: %s\n" "$CONF_DIR"
    printf "  分享内容: %s\n" "$OUT_DIR"
    printf "\n  下一步: 服务端面板 → 生成分享链接, 或直接\n"
    printf "          python3 %s --out-dir %s --list\n\n" \
        "$SELF_DIR/../share/build_sub.py" "$OUT_DIR"
    exit $(( local_fail > 0 ? 1 : 0 ))
else
    printf "\n${RED}${BOLD}校验未通过, 配置已回滚${RESET}\n"
    exit 1
fi
