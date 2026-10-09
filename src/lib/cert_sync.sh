#!/usr/bin/env bash
# =============================================================
# cert-sync.sh — 把 Let's Encrypt 续期后的新证书同步进 mihomo 的 conf/certs
#
# 为什么需要它:
#
#   mihomo 的 SAFE_PATHS 只允许读 -d 配置目录**之内**的证书, 所以本项目的
#   做法是"把证书复制进 conf/certs 再用"。复制本身没问题, 问题在复制之后
#   **没有任何人负责同步**, 而证书是会换的:
#
#     KPanel 的 /root/auto_cert_renewal.sh (第三方保活脚本) 续签成功后只做
#     两件事: cp 到 /home/web/certs/, reload nginx。它不碰 conf/certs。
#
#   于是 mihomo 拿着旧证书继续对外服务, 直到过期那天所有 TLS 节点一起断。
#   内核自己不检查有效期 —— 只有客户端握手时才拒。
#
#   测试机上原本有一个 mihomo-hy2-cert-sync.timer 干这件事, 但它指向的
#   /root/catmi/mihomo/sync-hy2-certs.sh 随清空重装一起消失, 从 2026-10-05
#   起每晚 203/EXEC 失败 (docs/E2E_VERIFY_REPORT.md:440 记为"未处理")。
#   本脚本就是那个缺口的替代实现, --install 会顺手把孤儿单元清掉。
#
# 与 xray--core/tools/cert-sync.sh 的区别 (那里踩过的坑, 这里不能再踩):
#
#   1. **目标不写死域名**。那边给 mihomo 的目标是 "fullchain.pem@__PRIMARY__",
#      主域名写死成一个具体的域名 —— 换到另一台主域名不同的机器,
#      它会静默什么都不做 (一个字的输出都没有)。
#      这里改成:**从 mihomo 自己的配置里反查**要维护哪些证书文件,
#      域名从证书本体的 SAN/CN 读。零硬编码, 哪台机器都对。
#
#   2. **不 restart**。那边注释写"续签后必须 restart 才能加载新证书 …… mihomo
#      同理"。实测是错的: mihomo 每次握手都重新读证书文件, 换文件立即生效
#      (TCP-TLS: openssl s_client 读到 serial 立刻变; QUIC/hysteria2: 客户端
#      校验开关一开, 换证书后握手立刻失败, SNI 跟着改又立刻成功)。
#      而且证书文件坏掉时 mihomo 会**继续发上一份有效证书**, 是 fail-safe 的。
#      所以同步只要落文件, 不需要动服务 —— 少一次重启 = 少一次全量断流。
#
#   3. mihomo 的配置里 private-key 与 certificate **成对出现**, 这里按配置
#      反查, 不靠文件名猜。
#
# 用法 (日常不需要人来敲 —— 见下面「谁在调它」):
#   bash src/lib/cert_sync.sh            # 同步 (只在内容真的不同时才写)
#   bash src/lib/cert_sync.sh --check    # 只报告, 不改任何东西 (有需要同步的返回 2)
#   bash src/lib/cert_sync.sh --ensure   # 幂等自愈: 需要才装定时器, 否则一声不吭
#   bash src/lib/cert_sync.sh --install  # 强制装 systemd timer (每天 03:30) 并清理孤儿单元
#   bash src/lib/cert_sync.sh --uninstall
#   bash src/lib/cert_sync.sh --run      # systemd 单元用的入口 (等同不带参数)
#
# 谁在调它 (全部是自动的, 用户无感):
#   1. systemd: mihomo-cert-sync.timer 每天 03:30 跑 --run
#   2. 面板启动时: server.sh → cert_sync_ensure_timer → --ensure
#   3. 面板里**选中一个 Let's Encrypt 证书时**: cert_ensure_safe_path → --ensure
#      —— 这一条是关键: 用户的心智是"我在面板里选个证书它就该自己动起来",
#         所以触发点就放在选证书那一刻, 而不是留一步"记得去装定时器"。
#
# 环境变量:
#   SRV_ROOT=/root/catmi/mihomo      mihomo 安装根目录
#   CERT_SYNC_SRC=/etc/letsencrypt/live   证书源
#   CERT_SYNC_URL=<raw GitHub 地址>   --install 时若脚本自身不是普通文件 (>_)
#                                    就用它重拉一份; 默认指向本项目的 main 分支
#
# 本文件放在 src/lib/ 而不是 tools/: install.sh 的更新只把 $tmp/src/. 拷到
# $root/src/, 面板「更新脚本」也以 src/ 为主 —— 放 tools/ 的话两条更新路径都
# 覆盖不到它, 定时器会一直跑一份再也不会被更新的旧脚本。
# =============================================================
set -uo pipefail

SRV_ROOT="${SRV_ROOT:-/root/catmi/mihomo}"
SRC="${CERT_SYNC_SRC:-/etc/letsencrypt/live}"
# "bash <(curl ...)" 这种跑法下脚本复制不了自己, --install 会退回按这个地址重拉
CERT_SYNC_URL="${CERT_SYNC_URL:-https://raw.githubusercontent.com/mi1314cat/mihomo--core/main/src/lib/cert_sync.sh}"
CONF_DIR="$SRV_ROOT/conf"
CERT_DIR="$CONF_DIR/certs"

# 把自己取一份到指定路径 (先本地复制, 不行再按 URL 拉)
fetch_self() { # <目标路径>
    local dest="${1:-}"
    [[ -n "$dest" ]] || return 1
    if [[ -f "${BASH_SOURCE[0]}" ]] && cp -f "${BASH_SOURCE[0]}" "$dest" 2>/dev/null; then return 0; fi
    command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 30 "$CERT_SYNC_URL" -o "$dest" 2>/dev/null && return 0
    command -v wget >/dev/null 2>&1 && wget -qO "$dest" --timeout=30 "$CERT_SYNC_URL" 2>/dev/null && return 0
    return 1
}

# 历史上那个指向不存在脚本的孤儿单元 —— --install 时清掉
ORPHAN_UNITS=(mihomo-hy2-cert-sync.service mihomo-hy2-cert-sync.timer)
UNIT=/etc/systemd/system/mihomo-cert-sync.service
TIMER=/etc/systemd/system/mihomo-cert-sync.timer
# 本实现的稳定落位路径。定时器的 ExecStart 指向它 ——
# 它在 src/lib/ 下, 于是 **install.sh 与面板「更新脚本」两条路都会覆盖到它**,
# 定时器用的永远是当前版本。放在 tools/ 下就两条都覆盖不到 (install.sh 只拷
# $tmp/src/. → $root/src/), 定时器会一直跑一份再也不会被更新的旧脚本。
SELF_DEST="$SRV_ROOT/src/lib/cert_sync.sh"

CHECK_ONLY=0
MODE="sync"
case "${1:-}" in
    --check)     CHECK_ONLY=1 ;;
    --install)   MODE="install" ;;
    --ensure)    MODE="ensure" ;;
    --uninstall) MODE="uninstall" ;;
    -h|--help)   sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "--run"|"")  ;;
    *)           echo "未知参数: $1 (--run / --check / --ensure / --install / --uninstall)"; exit 2 ;;
esac

_color(){ [[ -t 1 ]] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
ok(){   _color 32 "$1"; }
warn(){ _color 33 "$1"; }
bad(){  _color 31 "$1"; }
dim(){  _color 90 "$1"; }

need_changes=0
changed=0
REPORT=()

# ---------------------------------------------------------------- 证书工具
cert_domain() { # 从证书本体读域名 (SAN → CN), 真域名是唯一可信来源
    local f="${1:-}" d=""
    [[ -s "$f" ]] || return 1
    d=$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null |
        grep -oE 'DNS:[^,]+' | head -1 | cut -d: -f2)
    [[ -z "$d" ]] && d=$(openssl x509 -in "$f" -noout -subject 2>/dev/null |
        sed -n 's/.*CN *= *//p' | tr -d '"' | head -1)
    [[ -n "$d" ]] || return 1
    printf '%s' "$d" | tr '[:upper:]' '[:lower:]'
}
cert_pub() { openssl x509 -in "$1" -noout -pubkey 2>/dev/null | sha256sum | awk '{print $1}'; }
key_pub()  { openssl pkey -in "$1" -pubout         2>/dev/null | sha256sum | awk '{print $1}'; }
cert_key_match() { # <证书> <私钥>  —— 用 SPKI, RSA/EC 通用
    local c="${1:-}" k="${2:-}" a b
    [[ -s "$c" && -s "$k" ]] || return 1
    a=$(cert_pub "$c"); b=$(key_pub "$k")
    [[ -n "$a" && "$a" == "$b" ]]
}

# ------------------------------------------------- 从 mihomo 配置反查证书用途
#
# 输出 "证书路径<TAB>私钥路径"。只取**配置目录内**的路径:
#   certificate: 也可能是内联 PEM (值不是路径) → 跳过
#   reality-config 里的 private-key 是 REALITY 密钥, 不是证书私钥 → 值不以 / 开头, 跳过
collect_refs() {
    local f
    for f in "$CONF_DIR"/config.yaml "$CONF_DIR"/*.yaml "$CONF_DIR"/config.d/*.yaml; do
        [[ -f "$f" ]] || continue
        awk -v dir="$CERT_DIR" '
            /^[[:space:]]*certificate:[[:space:]]*/ {
                v=$0; sub(/^[[:space:]]*certificate:[[:space:]]*/, "", v)
                gsub(/^["'"'"']|["'"'"'][[:space:]]*$/, "", v); gsub(/[[:space:]]+$/, "", v)
                pend = (v ~ /^\// && index(v, dir"/") == 1) ? v : ""
                next
            }
            /^[[:space:]]*private-key:[[:space:]]*/ {
                v=$0; sub(/^[[:space:]]*private-key:[[:space:]]*/, "", v)
                gsub(/^["'"'"']|["'"'"'][[:space:]]*$/, "", v); gsub(/[[:space:]]+$/, "", v)
                if (v ~ /^\// && pend != "") { print pend "\t" v; pend="" }
                next
            }
        ' "$f"
    done | sort -u
}

# 在证书目录里按**公钥内容**找配对私钥 —— 不猜文件名。
#   目录里的命名五花八门 (fullchain.pem+privkey.pem / cert-01-fullchain.pem+
#   cert-01-privkey.pem / x_cert.pem+x_key.pem), 按名字猜必然漏, 按内容比对
#   是唯一可靠的做法。
find_key_in_dir() { # <证书>
    local c="${1:-}" k h
    h=$(cert_pub "$c") || return 1
    [[ -n "$h" ]] || return 1
    for k in "$CERT_DIR"/*.key "$CERT_DIR"/*.pem; do
        [[ -f "$k" ]] || continue
        grep -q "PRIVATE KEY" "$k" 2>/dev/null || continue
        [[ "$(key_pub "$k")" == "$h" ]] && { printf '%s' "$k"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------- 主流程
main() {
    if [[ ! -d "$CONF_DIR" ]]; then
        bad "✗ 找不到 mihomo 配置目录: $CONF_DIR"; echo "  用 SRV_ROOT=<安装根目录> 覆盖"; return 1
    fi

    # ------- 目标清单 = 配置引用的 + 目录里"有 LE 出处"的其它副本 -------
    #
    # ★ 为什么连"没被任何节点引用"的副本也要管:
    #   conf/certs 里常有历史遗留的副本 (cert-01-fullchain.pem 之类)。它们同样
    #   躺在 mihomo 的证书目录里, 同样会被外部续期甩下 —— 而批量路径的
    #   find_cert 是按文件名顺序挑的, 很可能**优先挑中它们**。
    #   只维护"被引用的"会让这些副本静默变陈旧, 然后在某次生成时被选中,
    #   节点就挂到一份过期证书上。所以判据不是"有没有被引用"，
    #   而是"它是不是这个目录里的、有 LE 出处的证书副本"。
    local refs=() targets=()
    mapfile -t refs < <(collect_refs)
    local -A have=()
    local i cert key f dom k
    for i in "${!refs[@]}"; do
        IFS=$'\t' read -r cert key <<< "${refs[$i]}"
        have["$cert"]=1
        targets+=("${refs[$i]}")
    done
    for f in "$CERT_DIR"/*.crt "$CERT_DIR"/*.pem; do
        [[ -f "$f" ]] || continue
        [[ -n "${have[$f]:-}" ]] && continue
        dom=$(cert_domain "$f" 2>/dev/null) || continue
        [[ -n "$dom" && -s "$SRC/$dom/fullchain.pem" ]] || continue
        k=$(find_key_in_dir "$f") || { dim "  · $(basename "$f") 有 LE 出处但找不到配对私钥, 跳过"; continue; }
        have["$f"]=1
        targets+=("$f"$'\t'"$k")
    done

    if ((${#targets[@]} == 0)); then
        warn "⚠ mihomo 配置与证书目录里都没有需要同步的 LE 证书 —— 无需同步"
        echo "  需要证书的协议 (Hysteria2 / TUIC / AnyTLS / Trojan+TLS / VLESS+WS+TLS) 都还没生成?"
        return 0
    fi
    refs=("${targets[@]}")

    echo "════════════════════════════════════════════"
    echo " mihomo 证书同步   (源: $SRC)"
    echo "════════════════════════════════════════════"

    # 源的 lineage 列表 (拿来做"只有一个源"时的兜底)
    local lineages=() d
    if [[ -d "$SRC" ]]; then
        for d in "$SRC"/*/; do
            [[ -f "$d/fullchain.pem" && -f "$d/privkey.pem" ]] && lineages+=("$(basename "$d")")
        done
    fi

    local src_cert src_key
    for i in "${!refs[@]}"; do
        IFS=$'\t' read -r cert key <<< "${refs[$i]}"

        # 域名解析顺序 (从最可信往下退):
        #   1) 现有副本证书本体的 SAN/CN —— 唯一可信来源
        #   2) cert-<域名>.crt 文件名 —— 本项目的命名约定
        #   3) 用**私钥**去反查: 拿私钥的公钥跟每个 lineage 的证书公钥比。
        #      这比"猜一个域名"可靠得多, 覆盖"证书文件被删但私钥还在"。
        #   4) 只有一个 lineage 时直接用它
        #   5) 都无法确定 → 拒绝动手并报错 (宁可不动, 也不能写错域名)
        dom=""
        [[ -s "$cert" ]] && dom=$(cert_domain "$cert" 2>/dev/null)
        if [[ -z "$dom" ]]; then
            dom=$(basename "$cert" | sed -n 's/^cert-\(.*\)\.crt$/\1/p')
        fi
        if [[ -z "$dom" && -s "$key" ]]; then
            local kp ld
            kp=$(key_pub "$key")
            for ld in "${lineages[@]:-}"; do
                [[ -n "$ld" && -s "$SRC/$ld/fullchain.pem" ]] || continue
                if [[ -n "$kp" && "$kp" == "$(cert_pub "$SRC/$ld/fullchain.pem")" ]]; then
                    dom="$ld"; dim "  · $(basename "$cert") 证书缺失, 按私钥反查确定为 $dom"; break
                fi
            done
        fi
        if [[ -z "$dom" && ${#lineages[@]} -eq 1 ]]; then
            dom="${lineages[0]}"
            dim "  · $(basename "$cert") 内容不可读, 按唯一证书源推断为 $dom"
        fi
        if [[ -z "$dom" ]]; then
            bad "  ✗ $(basename "$cert") 无法确定对应域名, 已跳过"
            echo "      (文件不存在或损坏, 且无法从私钥/证书源反查)"
            echo "      处理: 在面板里重新导入该证书, 或把它恢复成 cert-<域名>.crt 的命名"
            REPORT+=("skip|$cert"); continue
        fi

        src_cert="$SRC/$dom/fullchain.pem"
        src_key="$SRC/$dom/privkey.pem"
        if [[ ! -s "$src_cert" || ! -s "$src_key" ]]; then
            dim "  · $dom  无对应 Let's Encrypt lineage — 自签证书, 不归本脚本管"
            REPORT+=("self|$cert"); continue
        fi

        # 源本身就快过期了 → 提示第三方保活脚本可能失败了
        if ! openssl x509 -in "$src_cert" -noout -checkend $((7*86400)) >/dev/null 2>&1; then
            warn "  ⚠ $dom 源证书 7 天内到期: $(openssl x509 -in "$src_cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
            warn "     第三方保活脚本 (/root/auto_cert_renewal.sh) 可能又失败了"
        fi

        # 内容比对: 证书与私钥**都**要一致才算最新
        if [[ -s "$cert" && -s "$key" ]] && cmp -s "$src_cert" "$cert" && cmp -s "$src_key" "$key"; then
            ok "  ✓ $(basename "$cert") 已是最新 ($dom)"
            REPORT+=("ok|$cert"); continue
        fi

        if ((CHECK_ONLY)); then
            warn "  ! $(basename "$cert") 需要刷新 ← $dom"
            REPORT+=("todo|$cert"); need_changes=1; continue
        fi

        # 原子写入: 先写临时文件, 校验配对后再改名。
        # mihomo 热读证书文件, 直接覆盖会出现"新证书 + 旧私钥"的中间态。
        local ct="${cert}.tmp.$$" kt="${key}.tmp.$$"
        if ! cp -f "$src_cert" "$ct" 2>/dev/null || ! cp -f "$src_key" "$kt" 2>/dev/null; then
            bad "  ✗ $(basename "$cert") 复制失败"; rm -f "$ct" "$kt"; REPORT+=("fail|$cert"); continue
        fi
        chmod 644 "$ct" 2>/dev/null || true
        chmod 600 "$kt" 2>/dev/null || true
        if ! cert_key_match "$ct" "$kt"; then
            bad "  ✗ $(basename "$cert") 源证书与私钥不配对, 已放弃 (保留原文件)"
            rm -f "$ct" "$kt"; REPORT+=("fail|$cert"); continue
        fi
        if ! { mv -f "$ct" "$cert" && mv -f "$kt" "$key"; }; then
            bad "  ✗ $(basename "$cert") 落位失败"; rm -f "$ct" "$kt"; REPORT+=("fail|$cert"); continue
        fi
        ok "  ✓ $(basename "$cert") 已刷新 ($dom, 证书+私钥一起)"
        REPORT+=("done|$cert"); changed=1
    done

    # ------------------------------------------------------------ 汇总
    #
    # "自签跳过"是正常情况 (项目自己生成的证书本来就没有 LE lineage),
    # "无法确定"才是要人管的 —— 两者必须分开计数, 否则前者会把后者淹没,
    # 最后打出一句"全部已是最新"把真问题盖掉。
    echo "────────────────────────────────────────────"
    local n_ok=0 n_self=0 n_todo=0 n_fail=0 n_done=0 n_skip=0 r st
    for r in "${REPORT[@]:-}"; do
        [[ -n "$r" ]] || continue
        st="${r%%|*}"
        case "$st" in
            ok)   n_ok=$((n_ok+1)) ;;
            self) n_self=$((n_self+1)) ;;
            todo) n_todo=$((n_todo+1)) ;;
            fail) n_fail=$((n_fail+1)) ;;
            done) n_done=$((n_done+1)) ;;
            skip) n_skip=$((n_skip+1)) ;;
        esac
    done

    if ((CHECK_ONLY)); then
        printf '  最新 %d · 自签跳过 %d · 待刷新 %d · 失败 %d · 无法处理 %d\n' \
            "$n_ok" "$n_self" "$n_todo" "$n_fail" "$n_skip"
        if ((n_todo > 0)); then
            warn "  → 有证书需要同步。执行不带 --check 的本脚本即可。"
            return 2
        fi
        if ((n_fail > 0 || n_skip > 0)); then
            bad "  → 有 %d 项需要人工处理, 见上。" $((n_fail + n_skip))
            return 1
        fi
        ok "  → 全部已是最新, 无需操作。"
        return 0
    fi

    printf '  已刷新 %d · 本来就新 %d · 自签跳过 %d · 失败 %d · 无法处理 %d\n' \
        "$n_done" "$n_ok" "$n_self" "$n_fail" "$n_skip"
    if ((changed)); then
        ok "  → 同步完成。mihomo 每次握手都会重读证书文件, **不需要重启**。"
    elif ((n_fail == 0 && n_skip == 0)); then
        ok "  → 全部已是最新, 无需操作。"
    fi
    ((n_fail > 0 || n_skip > 0)) && return 1
    return 0
}

# 本机是否有"LE 出处"的证书在用 —— 决定要不要装定时器
#
# 只有真正在用 Let's Encrypt 证书时才需要同步 (那种证书会被第三方脚本换掉)。
# 全自签的机器不该被塞一个每天空跑一遍的定时器, 所以这里判得很死。
has_le_cert() {
    local refs=() i cert key dom
    mapfile -t refs < <(collect_refs)
    ((${#refs[@]})) || return 1
    for i in "${!refs[@]}"; do
        IFS=$'\t' read -r cert key <<< "${refs[$i]}"
        dom=""
        [[ -s "$cert" ]] && dom=$(cert_domain "$cert" 2>/dev/null)
        [[ -z "$dom" ]] && dom=$(basename "$cert" | sed -n 's/^cert-\(.*\)\.crt$/\1/p')
        [[ -n "$dom" && -s "$SRC/$dom/fullchain.pem" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------- 无感自愈
#
# 面板每次启动、以及每次导入证书后都会调这个。它必须是**安静且幂等**的:
#
#   * 已经装好且指向正确 → 一个字的输出都没有
#   * 本机没有 LE 证书   → 什么都不做
#   * 需要装             → 装好, 并说明一句为什么
#
# 为什么要有它: 定时器以前只能靠手工敲一条命令装。用户的心智模型是
# "我在面板里选个证书, 它自己就该动起来" —— 那就必须由面板自己保证,
# 而不是留一步"记得去装定时器"给人记。
ensure_quiet() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    [[ -d /run/systemd/system ]] || return 0      # 容器里没有 systemd, 不硬装

    # 已就位且 ExecStart 指向当前实现的稳定路径 → 静默通过。
    # 这里比的是路径而不是"服务存在": 实现从 tools/ 挪到 src/lib/ 之后,
    # 老单元仍然存在但指向一个不会再被更新路径覆盖的位置, 必须自动升级。
    if systemctl is-enabled --quiet mihomo-cert-sync.timer 2>/dev/null &&
       [[ -f "$UNIT" ]] && grep -qF "ExecStart=$SELF_DEST" "$UNIT" 2>/dev/null; then
        return 0
    fi

    has_le_cert || return 0

    echo "  检测到证书来自 Let's Encrypt —— 自动启用每日同步 (每天 03:30)"
    install_timer
}

# ---------------------------------------------------------------- 安装 timer
install_timer() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        bad "✗ 需要 root 才能装 systemd 单元"; return 1
    fi
    local self dest_dir dest
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '')
    dest_dir="$SRV_ROOT/src/lib"
    dest="$SELF_DEST"
    mkdir -p "$dest_dir" || { bad "✗ 无法创建 $dest_dir"; return 1; }

    # 单元里的 ExecStart 必须指向一个**稳定位置**, 所以要把自己复制过去。
    #
    # ★ 从 GitHub 远程执行时有两种姿势, 一种复制不了:
    #     curl -o /tmp/x.sh && bash /tmp/x.sh --install   ← 可以
    #     bash <(curl -fsSL ...) --install                ← BASH_SOURCE 是 /dev/fd/NN
    #   后者 $self 不是普通文件, cp 必然失败。这时退回按 URL 重新拉一份。
    if [[ ! -f "$self" || "$self" == "$dest" ]]; then
        if [[ "$self" == "$dest" ]]; then
            chmod 755 "$dest" 2>/dev/null || true
        elif ! fetch_self "$dest"; then
            bad "✗ 无法把自己安装到 $dest"
            echo "     当前脚本不是普通文件 (${self:-<空>}), 常见于 'bash <(curl ...)' 这种跑法。"
            echo "     请改成先落盘再跑:"
            echo "       curl -fsSL $CERT_SYNC_URL -o /tmp/cert_sync.sh && bash /tmp/cert_sync.sh --install"
            return 1
        else
            echo "  ✓ 脚本已安装到 $dest"
        fi
    elif ! cp -f "$self" "$dest"; then
        bad "✗ 无法安装到 $dest"; return 1
    else
        chmod 755 "$dest" 2>/dev/null || true
        echo "  ✓ 脚本已安装到 $dest"
    fi

    # 清理历史孤儿单元: 它们指向不存在的 /root/catmi/mihomo/sync-hy2-certs.sh,
    # 从 2026-10-05 起每晚 203/EXEC 失败, 是 E2E_VERIFY_REPORT.md:440 的那一条。
    local u found=0
    for u in "${ORPHAN_UNITS[@]}"; do
        if [[ -e "/etc/systemd/system/$u" ]]; then
            found=1
            systemctl disable --now "$u" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$u"
            echo "  ✓ 已清理孤儿单元 $u"
        fi
    done
    ((found)) || dim "  · 无孤儿单元需要清理"

    cat > "$UNIT" <<UNITEOF
# 由 src/lib/cert_sync.sh --install 生成
[Unit]
Description=Sync Let's Encrypt certs into mihomo conf (SAFE_PATHS)
After=network.target

[Service]
Type=oneshot
ExecStart=$dest
UNITEOF

    cat > "$TIMER" <<TIMEREOF
# 由 src/lib/cert_sync.sh --install 生成
[Unit]
Description=Daily cert sync for mihomo

[Timer]
OnCalendar=*-*-* 03:30:00
# 关机时错过了就开机补跑 —— 证书不会因为机器关着就不过期
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
TIMEREOF

    systemctl daemon-reload
    systemctl enable --now mihomo-cert-sync.timer >/dev/null 2>&1 || {
        bad "✗ 启用 timer 失败"; return 1; }
    ok "  ✓ 已安装 mihomo-cert-sync.timer (每天 03:30)"
    systemctl list-timers mihomo-cert-sync.timer --no-pager 2>/dev/null | head -2 | sed 's/^/    /'
    echo
    dim "  立即跑一次验证: systemctl start mihomo-cert-sync.service && journalctl -u mihomo-cert-sync -n 30"
    return 0
}

uninstall_timer() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || { bad "✗ 需要 root"; return 1; }
    systemctl disable --now mihomo-cert-sync.timer >/dev/null 2>&1 || true
    rm -f "$UNIT" "$TIMER"
    systemctl daemon-reload
    ok "  ✓ 已卸载 mihomo-cert-sync.timer (脚本文件保留在 $SELF_DEST)"
    return 0
}

case "$MODE" in
    install)   install_timer ;;
    ensure)    ensure_quiet ;;
    uninstall) uninstall_timer ;;
    *)         main ;;
esac
