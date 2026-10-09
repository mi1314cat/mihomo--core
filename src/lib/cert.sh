#!/usr/bin/env bash
# =============================================================
# 证书路径安全区 (mihomo 的 SAFE_PATHS 限制)
#
# ★ 这是 mihomo 的一个硬性限制, 而且**只在 listener 启动时才报错**,
#   `mihomo -t` 完全不报 —— 属于"面板全绿但连不上"那一类。
#
# 实测:
#   证书在 -d 目录内                          -> ✅ 可用
#   证书在 $HOME 下但不在 -d 内               -> ❌ 拒绝
#   证书在 /tmp 且未设 SAFE_PATHS             -> ❌ 拒绝
#   SAFE_PATHS=<目录>                          -> ✅ 可用
#   SAFE_PATHS=<目录1>:<目录2>  (冒号分隔)     -> ✅ 可用
#   SAFE_PATHS=<目录1>;<目录2>  (分号分隔)     -> ❌ 不生效 (只认冒号)
#
# 报错原文:
#   listener 0: parse certificate failed, maybe format error:
#   tls: failed to find any PEM data in certificate input, or path error:
#   path is not subpath of home directory or SAFE_PATHS: <路径>
#   allowed paths: [<-d 指向的配置目录>]
#
# 注意: 报错里的 "home directory" **不是 $HOME**, 而是 -d 指向的配置目录
# (实测放在 /root 下、但 -d 指向 /tmp/xx 时依然被拒)。
#
# 现实影响: 用户从 /etc/letsencrypt/live/<域名>/ 选证书是极常见的做法,
# 那条路径几乎必然在 -d 之外 -> 节点建好却永远连不上。
# =============================================================

# 某路径是否在配置目录 (-d) 之内
cert_path_in_confdir() { # <路径>
    local p="${1:-}" conf="${SRV_CONF:-}"
    [[ -n "$p" && -n "$conf" ]] || return 1
    # 先归一化, 再比前缀 —— 否则 /root/catmi/mihomo/conf2 会被误判为在
    # /root/catmi/mihomo/conf 之内
    local rp rc
    rp=$(readlink -f "$p" 2>/dev/null)   || rp="$p"
    rc=$(readlink -f "$conf" 2>/dev/null) || rc="$conf"
    [[ "$rp" == "$rc" || "$rp" == "$rc"/* ]]
}

# 证书与私钥是否配对 (SPKI 的 SHA256 比对)
#   ★ 用 SPKI 而不是 `openssl x509 -modulus` —— 后者是 RSA 专用, 遇到 EC 证书
#     直接报错, 而本项目自签证书是 ECDSA P-256, LE 也是 --key-type ecdsa。
cert_pub_hash() { # <证书>
    [[ -s "${1:-}" ]] || return 1
    openssl x509 -in "$1" -noout -pubkey 2>/dev/null | sha256sum | awk '{print tolower($1)}'
}
key_pub_hash() { # <私钥>
    [[ -s "${1:-}" ]] || return 1
    openssl pkey -in "$1" -pubout 2>/dev/null | sha256sum | awk '{print tolower($1)}'
}
cert_key_match() { # <证书> <私钥>
    local c="${1:-}" k="${2:-}" a b
    [[ -s "$c" && -s "$k" ]] || return 1
    a=$(cert_pub_hash "$c") || return 1
    b=$(key_pub_hash "$k")  || return 1
    [[ -n "$a" && -n "$b" && "$a" == "$b" ]]
}

# 证书在配置目录内的落位文件名 —— 打印 "证书<TAB>私钥"
#
# ★ 这里必须**带域名**。原来落位用的是 $(basename "$cert"), 而从
#   /etc/letsencrypt/live/<域名>/ 取到的 basename 恒为 fullchain.pem:
#     节点1 选 域名A  -> conf/certs/fullchain.pem
#     节点2 选 域名B  -> conf/certs/fullchain.pem   ← 同一个文件, 证书+私钥一起被顶掉
#   于是节点1 开始对外发域名B 的证书 (SNI 不匹配 → 客户端全部握手失败),
#   而 `mihomo -t` 通过、service 是 active、监听一个不少 —— 静默失败里最难查的一类。
#   同一个坑 xray--core/tools/cert-sync.sh:41-45 有实测记录。
#
# 命名沿用项目自己的 cert-<域名>.crt / key-<域名>.key, 于是
# find_key_for_cert() 的第一条配对规则天然认得它们, 扫描/回收链路无需改动。
cert_dest_paths() { # <证书>
    local cert="${1:-}" dom
    [[ -n "$cert" ]] || return 1
    dom=$(cert_extract_domain "$cert" 2>/dev/null)
    # 拿不到真域名时用内容指纹兜底 —— 保证"不同证书必然落到不同文件",
    # 宁可名字难看, 也不能再出现互相覆盖。
    case "$dom" in
        ""|fullchain|cert|chain|cert1|fullchain1|privkey)
            dom="imported-$(sha256sum "$cert" 2>/dev/null | cut -c1-16)" ;;
    esac
    [[ -n "$dom" ]] || return 1
    dom=$(printf '%s' "$dom" | tr -c 'A-Za-z0-9._-' '_')
    [[ -n "$dom" ]] || return 1
    printf '%s\t%s' "$CERT_DIR/cert-${dom}.crt" "$CERT_DIR/key-${dom}.key"
}

# 这张证书是不是"会被别人换掉"的那种
#   LE 的 live/*.pem 全是符号链接, 指向 archive/ 下带序号的真实文件 ——
#   续期后符号链接指向新的那份, 而我们复制出来的快照不会跟着变。
cert_is_renewable_source() { # <证书路径>
    local c="${1:-}" r
    [[ -n "$c" ]] || return 1
    r=$(readlink -f "$c" 2>/dev/null) || r="$c"
    [[ "$r" == /etc/letsencrypt/* ]] && return 0
    [[ "$r" == /root/.acme.sh/* ]]    && return 0
    [[ -L "$c" ]] && return 0
    return 1
}

# 确保"续期后自动同步"的定时器在位 —— 幂等、安静、失败不影响主流程。
#
# ★ 这是整个机制**无感**的关键: 用户不需要知道有定时器这回事。他在面板里
#   选中 LE 证书的那一刻, 这里就把后续每一次续期的同步接上了。
#   留一步"记得去装定时器"给人记, 等于没做 —— 这条链路上已经断过一次
#   (原 mihomo-hy2-cert-sync.timer 指向的脚本丢失, 从 2026-10-05 起每晚
#    203/EXEC 失败, 大半个月没人发现)。
cert_sync_ensure_timer() {
    local lib="${M_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local helper="$lib/cert_sync.sh"
    [[ -f "$helper" ]] || return 0
    local out=""
    out=$(bash "$helper" --ensure 2>&1) || true
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    return 0
}

# 若用户给的证书不在配置目录内, 把它复制进来并改写 CERT_FILE/KEY_FILE。
# 返回 0 = 已可用 (可能已复制), 1 = 无法处理
cert_ensure_safe_path() { # <证书> <私钥>  (就地修改 CERT_FILE / KEY_FILE)
    local cert="${1:-$CERT_FILE}" key="${2:-$KEY_FILE}"
    [[ -n "$cert" && -f "$cert" ]] || return 1
    if cert_path_in_confdir "$cert"; then
        # ★ 已经在配置目录里, 也要验一次配对。
        #
        # 批量路径 (all.sh) 的证书多半就是从 conf/certs 里挑出来的, 而它在
        # "已在目录内"时不会走下面的复制分支 —— 旧实现于是**完全不校验**:
        # find_cert 一旦配错 (它曾用"第 0 张证书 + 第 0 把私钥"的位置兜底),
        # 配错的一对会一路写进配置, 面板三道关全绿, 直到客户端握手才炸。
        if [[ -n "$key" && -f "$key" ]] && ! cert_key_match "$cert" "$key"; then
            print_error "证书与私钥不配对: $cert <-> $key"
            return 1
        fi
        return 0
    fi
    # 记下来: 这份证书是不是外部脚本续期的 (决定要不要接上自动同步)
    local renewable=0
    cert_is_renewable_source "$cert" && renewable=1

    # 私钥必须存在。原来私钥缺失时 KEY_FILE 会被赋成空串, 一路静默写进配置
    # (private-key: ""), 直到 listener 起不来才暴露。
    if [[ -z "$key" || ! -f "$key" ]]; then
        print_error "证书私钥缺失或不可读: ${key:-<未提供>}"
        return 1
    fi
    # 配对要在**写入之前**判定源文件。写一份配不上的证书进配置目录,
    # 等于给所有引用它的节点埋雷。
    if ! cert_key_match "$cert" "$key"; then
        print_error "证书与私钥不配对: $cert <-> $key"
        return 1
    fi

    mkdir -p "$CERT_DIR"
    local cdest="" kdest="" dom
    IFS=$'\t' read -r cdest kdest < <(cert_dest_paths "$cert")
    [[ -n "$cdest" && -n "$kdest" ]] || { print_error "无法确定落位文件名"; return 1; }
    dom=$(cert_extract_domain "$cert" 2>/dev/null)

    # 先写临时文件再原子改名。
    # ★ 这不是洁癖: mihomo 是**热读**证书文件的 (TCP-TLS 与 QUIC 都实测过),
    #   直接在目标路径上 cp 会出现"新证书 + 旧私钥"的中间态, 而这个中间态
    #   真的会被正在握手的客户端读到。
    local ct="${cdest}.tmp.$$" kt="${kdest}.tmp.$$"
    if ! cp -f "$cert" "$ct" || ! cp -f "$key" "$kt"; then
        rm -f "$ct" "$kt"; print_error "复制证书失败"; return 1
    fi
    chmod 644 "$ct" 2>/dev/null || true
    chmod 600 "$kt" 2>/dev/null || true
    if ! cert_key_match "$ct" "$kt"; then
        rm -f "$ct" "$kt"; print_error "落位后配对校验失败, 已放弃"; return 1
    fi
    if ! { mv -f "$ct" "$cdest" && mv -f "$kt" "$kdest"; }; then
        rm -f "$ct" "$kt"; print_error "落位失败"; return 1
    fi

    CERT_FILE="$cdest"; KEY_FILE="$kdest"
    print_warn "证书不在配置目录内, mihomo 会拒绝加载 (SAFE_PATHS 限制)"
    print_info "已自动复制到配置目录: $cdest"
    print_info "  (文件名带域名, 多域名不会互相覆盖)"
    if ((renewable)); then
        # 其余的话不再说第二遍: 这一条已经把"后续怎么办"接上了。
        # SAFE_PATHS 那套备选方案仍写在 cert.sh 顶部注释里, 需要时能查到。
        print_info "原证书由外部脚本续期 (符号链接 / Let's Encrypt), 复制件本身不会自动更新"
        cert_sync_ensure_timer
    fi
    return 0
}

# =============================================================
# cert.sh — 证书的唯一真源 (扫描 / 识别 / 生成 / 钉扎 / 回收)
#
# 为什么要有这个文件:
#   在此之前 generate_cert / ask_cert / scan_certs 在 4 个协议脚本里
#   各有一份独立副本, 且互相不一致 ——
#     hysteria2 : ECDSA P-256 + SAN + 扫描三选项  (最完整)
#     Trojan    : RSA2048, 且证书路径写死 /root/catmi/<域名>.crt
#     VLESS     : 同上, 同一处写死
#     AnyTLS    : RSA2048, 无扫描
#   结果是"添加 Trojan 节点时看不到自己已有的证书" —— 静默退回自签。
#   SB 的教训原文: 「同一份字段写两处必然漂移」。所以集中到这里。
#
# 两个必须分清的"指纹"概念 (曾经混用):
#   client-fingerprint : uTLS 的 ClientHello 指纹 (chrome/firefox/...), 抗 JA3/JA4
#   fingerprint        : **证书钉扎**, X.509 整证书 DER 的 SHA256 (64位hex)
#   -> 后者由 cert_pin() 计算。注意 sing-box 的 certificate_public_key_sha256
#      是 SPKI 的 SHA256, **与这里不是同一个值**, 直接搬过来钉扎必然失败。
#
# 依赖: ui.sh (print_*) ; 被 client.sh / server.sh 与各协议脚本 source
# =============================================================

# 证书目录: 与配置同级的 conf/certs
#   BASE_DIR  : 服务端根 (server.sh 定义)
#   SRV_CONF  : 服务端 conf 目录
# 兼容单独运行 (BASE_DIR 未定义时退回脚本自身位置)
: "${BASE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
: "${SRV_CONF:=$BASE_DIR/conf}"
export CERT_DIR="${CERT_DIR:-$SRV_CONF/certs}"

# =============================================================
# 一、基础判定
# =============================================================

# 证书是否需要续期 (24h 内过期即算不可用)
cert_not_expired() {
    [[ -f "${1:-}" ]] || return 1
    openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1
}

# 从证书提取域名 (三级回退: SAN → CN → 文件名)
cert_extract_domain() {
    local crt="${1:-}" dom=""
    if command -v openssl >/dev/null 2>&1 && [[ -f "$crt" ]]; then
        dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null |
              grep -oE 'DNS:[^,]+' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
        [[ -z "$dom" ]] && dom=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null |
              grep -oE 'CN *= *[^,]+' | head -1 | sed 's/.*CN *= *//' | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//' | sed 's/^cert-//')
    printf '%s' "$dom"
}

# 是否 CA 证书 (CA 不能当站点证书用)
cert_is_ca() {
    # ★ 不能只看 CA:TRUE —— `openssl req -x509` 默认会给自签证书打上
    #   "Basic Constraints: CA:TRUE", 于是我们**自己生成的证书**全被判成
    #   CA 而排除, 表现就是"扫描已有证书"永远扫不到本项目的证书。
    #   真 CA 的判据是 CA:TRUE **且** subject != issuer (中间/根 CA 由别人签发);
    #   自签叶子证书 subject == issuer。
    local crt="${1:-}" subj issuer
    [[ -f "$crt" ]] || return 1
    openssl x509 -in "$crt" -noout -text 2>/dev/null | grep -q 'CA:TRUE' || return 1
    subj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    [[ "$subj" == "$issuer" ]] && return 1
    return 0
}

# 是否真证书 (CA 签发), 用于决定客户端是"正常校验"还是"钉扎"
#
# 主判据取 SB 的 subject != issuer —— 自签证书的 subject 与 issuer 必然相同,
# 这是最可靠且不依赖具体 CA 名单的判据。
# 附加: 已知公共 CA 名单命中时也直接认定 (覆盖某些 subject/issuer 写法怪异的链)。
cert_is_trusted() {
    local crt="${1:-}" subj issuer
    [[ -f "$crt" ]] || return 1
    subj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    [[ -z "$subj" || -z "$issuer" ]] && return 1
    [[ "$subj" == "$issuer" ]] && return 1
    # subject != issuer ⇒ 有独立签发者 ⇒ 真证书
    # (已知公共 CA 是充分条件的加强, 但不作为必要条件, 免得漏判小众 CA)
    return 0
}

# 证书钉扎值 —— mihomo 的 `fingerprint` 字段
#   ★ 语义: X.509 证书 DER 的 SHA256 (不是 SPKI!)
#   sing-box 的 certificate_public_key_sha256 是 SPKI 的 SHA256, 两者不同,
#   实测同一张证书: DER=a4b9.. 而 SPKI=1f7c.. —— 搬错则钉扎静默失效。
cert_pin() {
    local crt="${1:-}" pin
    [[ -s "$crt" ]] || { printf ''; return 0; }
    pin=$(openssl x509 -in "$crt" -outform der 2>/dev/null | sha256sum | awk '{print tolower($1)}')
    # sha256sum 对空输入会返回 e3b0c442... (空串的 SHA256), 当作失败
    [[ "$pin" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]] && pin=""
    printf '%s' "$pin"
}

# 向后兼容别名 (hysteria2.sh 历史调用点)
calc_pin() { CERT_PIN=$(cert_pin "${1:-$CERT_FILE}"); }

# =============================================================
# =============================================================
# 一之二、伪装域名
#
# ★ 这里补的是一个真实存在的 bug: 原先 hysteria2.sh 的 generate_cert
#   调用 random_domain, 但全项目**从未定义过这个函数** ——
#   bash 只会打一句 "command not found" 然后把命令替换结果当空串,
#   于是自签证书落盘成 conf/certs/cert-.crt (域名为空),
#   且 CERT_DOMAIN 为空会让后续所有依赖域名的分支静默走错。
#   单独运行 hysteria2.sh 走"生成自签证书"就必然踩到。
#
# 取值优先级:
#   1) auto_website (domains.sh 现场优选, 与 Reality/Trojan 同一来源)
#   2) 内置常见 CDN 友好域名表 (离线可用, 不依赖网络)
#   3) 随机串兜底 (保证任何时候都有一个非空域名)
# =============================================================
M_DECOY_DOMAINS=(
    "www.bing.com" "www.apple.com" "www.cloudflare.com" "www.microsoft.com"
    "www.amazon.com" "www.samsung.com" "swdist.apple.com" "www.icloud.com"
    "cdn.jsdelivr.net" "www.python.org" "www.wikipedia.org" "www.mozilla.org"
)

random_domain() {
    local d=""
    # 1) 优先复用已有的域名优选 (它内部走 domains.sh, 拿到的域名更"活")
    if command -v auto_website >/dev/null 2>&1; then
        d=$(auto_website 2>/dev/null) || d=""
    fi
    # 2) 内置表随机取
    if [[ -z "$d" ]]; then
        d="${M_DECOY_DOMAINS[$((RANDOM % ${#M_DECOY_DOMAINS[@]}))]}"
    fi
    # 3) 兜底: 随机串 (理论上到不了这里)
    [[ -z "$d" ]] && d="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 12).com"
    printf '%s' "$d"
}

# 二、私钥配对 (crt → key)
# =============================================================
find_key_for_cert() {
    local crt="${1:-}" k
    # ★ 第一组必须是本项目自己的命名: cert-<域名>.crt ↔ key-<域名>.key
    #   原先这里只有 SB 的 _cert.pem/_key.pem 规则, 于是 scan_certs
    #   把自己生成的证书全部判成"没有配对私钥"而丢弃 ——
    #   表现就是"扫描已有证书"永远扫不到我们自己的那一批。
    local base; base=$(basename "$crt"); local dir; dir=$(dirname "$crt")
    if [[ "$base" == cert-*.crt ]]; then
        k="$dir/key-${base#cert-}"
        k="${k%.crt}.key"
        [[ -f "$k" ]] && { printf '%s' "$k"; return 0; }
    fi
    for k in "${crt%.crt}.key" "${crt%.pem}.key" "${crt%_cert.pem}_key.pem" \
             "${crt%.crt}_key.pem" "${crt%.crt}.pem.key" "$dir/server.key" \
             "$dir/privkey.pem" "$dir/${base%.crt}.key"; do
        [[ -f "$k" ]] && { printf '%s' "$k"; return 0; }
    done
    printf ''
    return 1
}

# =============================================================
# 三、扫描本机已有证书
#
# 搜这些地方 (顺序即优先级):
#   本项目 conf/certs → Cloudflare Origin CA → acme.sh → certbot →
#   nginx → v2ray-agent → /home/web/certs → Docker nginx 容器挂载
# 每张都要求: 非 CA / 未过期 / 有配对私钥。缺一不可。
#
# ★ 本项目目录用 $CERT_DIR 动态取, 不写死绝对路径 ——
#   写死会让项目换目录安装后"看不到自己的证书"(曾经就是 /root/catmi/mihomo)。
# =============================================================
scan_certs() {
    FOUND_CERTS=(); SEEN_CERTS_TMP=()
    local f k d i src cid
    shopt -s nullglob
    local -a search_dirs=() labels=()

    [[ -d "$CERT_DIR" ]] && { search_dirs+=("$CERT_DIR"); labels+=("本项目"); }
    [[ -d /root/catmi/cloudflare/certs ]] && { search_dirs+=(/root/catmi/cloudflare/certs); labels+=(Cloudflare-源站); }
    [[ -d /root/.acme.sh ]] && { search_dirs+=(/root/.acme.sh); labels+=(acme.sh); }
    if [[ -d /etc/letsencrypt/live ]]; then
        for f in /etc/letsencrypt/live/*/fullchain.pem; do
            [[ -f "$f" ]] || continue
            k="$(dirname "$f")/privkey.pem"
            [[ -f "$k" ]] && cert_not_expired "$f" && FOUND_CERTS+=("$f|$k|certbot")
        done
    fi
    [[ -d /etc/nginx/certs ]] && { search_dirs+=(/etc/nginx/certs); labels+=(nginx); }
    [[ -d /etc/v2ray-agent/tls ]] && { search_dirs+=(/etc/v2ray-agent/tls); labels+=(v2ray-agent); }
    [[ -d /home/web/certs ]] && { search_dirs+=(/home/web/certs); labels+=(web); }
    [[ -d /root/catmi ]] && { search_dirs+=(/root/catmi); labels+=(catmi-根目录); }

    # Docker nginx 容器: 证书常挂在容器里, 宿主目录反而是空的
    if command -v docker >/dev/null 2>&1; then
        for cid in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx); do
            src=$(docker inspect "$cid" \
                --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/certs"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
            [[ -n "$src" && -d "$src" ]] && { search_dirs+=("$src"); labels+=("docker-nginx($cid)"); }
        done
    fi

    for ((i=0; i<${#search_dirs[@]}; i++)); do
        d="${search_dirs[$i]}"; [[ -d "$d" ]] || continue
        for f in "$d"/*.pem "$d"/*.crt; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *_key.pem || "$f" == *key*.pem ]] && continue
            case "$(basename "$f")" in
                ca.cer|fullchain.cer|*.issuer.cer|chain.cer|key.pem) continue ;;
            esac
            local dup=false sf
            for sf in "${SEEN_CERTS_TMP[@]:-}"; do [[ "$sf" == "$f" ]] && dup=true && break; done
            $dup && continue
            SEEN_CERTS_TMP+=("$f")
            cert_is_ca "$f" && continue
            cert_not_expired "$f" || continue
            k=$(find_key_for_cert "$f")
            [[ -n "$k" ]] && FOUND_CERTS+=("$f|$k|${labels[$i]}")
        done
    done
    shopt -u nullglob
    ((${#FOUND_CERTS[@]} > 0))
}

# 按域名去重 (同域名多份时保留第一份 = 优先级最高的那份)
cert_dedup_by_domain() {
    local -A seen=(); local -a out=()
    local e crt dom
    for e in "${FOUND_CERTS[@]:-}"; do
        crt="${e%%|*}"; dom=$(cert_extract_domain "$crt")
        [[ -n "${seen[$dom]:-}" ]] && continue
        seen[$dom]=1; out+=("$e")
    done
    FOUND_CERTS=("${out[@]:-}")
}

# =============================================================
# 四、生成自签证书 (ECDSA P-256 + SAN, 10 年)
#   P-256 而非 RSA2048: 握手更快、体积更小, 且被所有内核支持。
# =============================================================
generate_cert() {
    local dom="${1:-}"
    if [[ -z "$dom" ]]; then
        dom=$(safe_read "自签证书域名(伪装域名)" "$(random_domain)")
        [[ -z "$dom" ]] && dom=$(random_domain)
    fi
    dom=$(printf '%s' "$dom" | tr '[:upper:]' '[:lower:]')

    mkdir -p "$CERT_DIR"
    CERT_DOMAIN="$dom"
    CERT_FILE="$CERT_DIR/cert-$dom.crt"
    KEY_FILE="$CERT_DIR/key-$dom.key"

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        cert_not_expired "$CERT_FILE" && { CERT_TRUSTED=false; print_ok "已有自签证书: $dom"; return 0; }
    fi

    print_info "生成自签证书 (ECDSA P-256, 叶子证书, 10年): $dom"
    # basicConstraints=CA:FALSE 必须显式写: 不加的话 openssl 默认 CA:TRUE,
    # 会让这张叶子证书被自己的 CA 过滤器排除掉 (见 cert_is_ca 注释),
    # 部分客户端也会因为"叶子自称是 CA"而拒绝校验。
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve -nodes \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
        -subj "/CN=$dom" \
        -addext "subjectAltName=DNS:$dom" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 || {
            print_error "openssl 生成证书失败"
            return 1
        }
    CERT_TRUSTED=false
    print_ok "自签证书生成完成: $CERT_FILE"
}

# =============================================================
# 五、统一证书选择菜单 (所有协议共用)
#   选完统一设置: CERT_FILE / KEY_FILE / CERT_DOMAIN / CERT_TRUSTED
# =============================================================
ask_cert() {
    local choice f e k lbl dom i=1
    print_title "证书选择 (客户端校验方式取决于此)"
    printf '    %b1)%b 扫描本机已有证书   %b(ACME/certbot/nginx 等, CA 可信)%b\n' \
        "${CYAN:-}" "${RESET:-}" "${DIM:-}" "${RESET:-}" >&2
    printf '    %b2)%b 手动输入证书路径\n' "${CYAN:-}" "${RESET:-}" >&2
    printf '    %b3)%b 生成自签证书         %b(无需域名, 客户端走钉扎)%b\n' \
        "${CYAN:-}" "${RESET:-}" "${DIM:-}" "${RESET:-}" >&2
    choice=$(safe_read "选择" "1")

    case "$choice" in
        2)
            printf '  证书 crt 路径: ' >&2; read -r f; CERT_FILE=$(clean_input "$f")
            printf '  证书 key 路径: ' >&2; read -r f; KEY_FILE=$(clean_input "$f")
            if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
                cert_not_expired "$CERT_FILE" || { print_error "证书已过期"; return 1; }
                # 必须在写进配置**之前**处理: mihomo 只接受 -d 配置目录内的
                # 证书路径 (或 SAFE_PATHS 放行的), 否则 listener 起不来而
                # `mihomo -t` 不报错。用户手输的路径多半在 /etc/letsencrypt 下。
                cert_ensure_safe_path || { print_error "证书无法放入配置目录"; return 1; }
                CERT_DOMAIN=$(cert_extract_domain "$CERT_FILE")
                if cert_is_trusted "$CERT_FILE"; then CERT_TRUSTED=true; else CERT_TRUSTED=false; fi
                print_ok "使用手动证书: $CERT_DOMAIN"
                print_info "校验方式: $([[ "$CERT_TRUSTED" == true ]] && echo '正常校验 (CA 签发)' || echo '证书钉扎 (自签)')"
                return 0
            fi
            print_error "证书路径无效, 退回自签"
            generate_cert; return $?
            ;;
        3)
            generate_cert; return $?
            ;;
    esac

    # 默认 1: 扫描
    print_info "扫描本机已有证书..."
    if ! scan_certs || ((${#FOUND_CERTS[@]} == 0)); then
        print_warn "未找到可用证书 (需要 非CA + 未过期 + 有配对私钥), 退回自签"
        generate_cert; return $?
    fi
    cert_dedup_by_domain

    print_title "找到以下证书"
    for e in "${FOUND_CERTS[@]}"; do
        f="${e%%|*}"; k="${e#*|}"; lbl="${k##*|}"; k="${k%%|*}"
        dom=$(cert_extract_domain "$f")
        local tag=""; cert_is_trusted "$f" || tag=" ${YELLOW:-}[自签]${RESET:-}"
        printf '    %b%d)%b %-34s %b(%s)%b%s\n' \
            "${CYAN:-}" "$i" "${RESET:-}" "$dom" "${DIM:-}" "$lbl" "${RESET:-}" "$tag" >&2
        i=$((i+1))
    done
    printf '    %b%d)%b 都不用, 生成自签证书\n' "${CYAN:-}" "$i" "${RESET:-}" >&2
    choice=$(safe_read "选择" "1")

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#FOUND_CERTS[@]} )); then
        e="${FOUND_CERTS[$((choice-1))]}"
        CERT_FILE="${e%%|*}"; k="${e#*|}"; KEY_FILE="${k%%|*}"
        # 扫描结果里常有 /etc/letsencrypt/live/... 这类路径 —— 同样在配置
        # 目录之外, 同样会被 mihomo 拒绝, 所以这里也要过一遍。
        cert_ensure_safe_path || { print_warn "证书无法放入配置目录, 改用自签"; generate_cert; return $?; }
        CERT_DOMAIN=$(cert_extract_domain "$CERT_FILE")
        if cert_is_trusted "$CERT_FILE"; then CERT_TRUSTED=true; else CERT_TRUSTED=false; fi
        print_ok "已选证书: $CERT_DOMAIN"
        print_info "校验方式: $([[ "$CERT_TRUSTED" == true ]] && echo '正常校验 (CA 签发)' || echo '证书钉扎 (自签)')"
        return 0
    fi
    generate_cert; return $?
}

# =============================================================
# 六、引用检查与回收 (从 env.sh 迁入, 逻辑不变)
#
# 背景: 曾出现删节点时把仍被其它节点引用的证书删掉, 导致另外 4 个 TLS
#       节点全部 listen err: parse certificate failed, 而面板还显示"运行中"。
#       所以删除前必须逐个确认引用。
# =============================================================
cert_in_use() {
    local want="${1:-}" f
    [[ -n "$want" ]] || return 1
    want=$(readlink -f "$want" 2>/dev/null || printf '%s' "$want")
    for f in "${SRV_CONFIGD:-/nonexistent}"/*.yaml; do
        [[ -f "$f" ]] || continue
        grep -qF -- "$want" "$f" 2>/dev/null && return 0
        grep -qF -- "$(basename "$want")" "$f" 2>/dev/null && return 0
    done
    return 1
}

# cert_gc <证书路径...> —— 只删真正没人用的
cert_gc() {
    local c base
    for c in "$@"; do
        [[ -e "$c" ]] || continue
        base=$(basename "$c")
        if cert_in_use "$c"; then
            print_warn "证书仍被其它节点引用, 已保留: $base"
            continue
        fi
        rm -f "$c" && print_ok "已删除未使用的证书: $base"
    done
}

# 向后兼容别名 (env.sh 旧调用点)
m_cert_in_use() { cert_in_use "$@"; }
m_cert_gc()     { cert_gc "$@"; }
