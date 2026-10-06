#!/usr/bin/env bash
# =============================================================
# preset.sh — 每个协议的「推荐配置」预置方案
#
# 设计照搬 SB (参考实现) 的 SB_PRESETS / sb_ask_preset,
# 但**内容按 M 内核实测结论重写**。三处必须不同:
#
#   ① REALITY 预置里**绝不排 ws**
#      实测 (本项目与 SB 各自独立复现): mihomo 用 WebSocket 承载
#      REALITY 稳定失败 —— 裸TCP/grpc/h2 都 3/3~5/5, ws 是 0/3~0/5。
#      对照组 (vless+TCP+REALITY) 通过, 所以不是环境问题。
#      详见 docs/private/M-KERNEL-ISSUES.md K-1。
#
#   ② AnyTLS **不提供 REALITY 预置**
#      SB 的表里注明「mihomo 不支持 AnyTLS+Reality」; 本项目实测 0/5 证实。
#      对照 vless+TCP+REALITY 5/5。见 K-5。
#
#   ③ 增加 **xhttp** 预置 (M 内核独有, SB 内核没有这个传输)
#
# 沿用 SB 的两条设计原则:
#   * 优先级: 隐蔽性 > 兼容性。默认项**绝不能**是 CDN/ECH 相关。
#   * 方案标识写进**节点名** —— 用户在客户端列表里只能看到名字,
#     这是唯一能区分"这个节点是哪个方案"的地方。
#
# 表字段顺序固定:
#   协议|id|显示名|传输|mux档位|flow|证书|说明|标签|额外
#     - 传输 写 tcp 表示裸TCP; 写 无 表示该协议没有传输层
#     - mux档位 off=不跑多路复用; 其余用英文 id (web/video/download)
#     - flow 只有 vless 有
#     - 证书 reality / selfsign(自签) / 真证书
#     - 额外 ech / pad / cdn, 空表示都不开
#
# ★ 取值一律用 cut 逐列取, **不能**用 read 拆 —— 表里空字段是 "||"
#   这种连续分隔符, 而 read 按 IFS 折叠连续空白, 空列会被吞掉、后面所有
#   字段左移一位。(SB 就因此让 vmess/trojan 把 reality 读成 flow。)
# =============================================================

M_PRESETS=(
  # ---------- VLESS (M 内核变体最多) ----------
  "vless|tcp-vision|① 隐匿优先 · REALITY|tcp|off|xtls-rprx-vision|reality|裸TCP + XTLS Vision; 抗 DPI 最强; 不用证书|REALITY|"
  "vless|grpc-video|② gRPC 伪装 · REALITY|grpc|video||reality|gRPC 套一层正常 HTTP/2; 观感最像普通应用|REALITY|"
  "vless|grpc-dl|③ gRPC 高并发 · REALITY|grpc|download||reality|多路复用扛并发; 适合大量小请求|REALITY|"
  "vless|h2-video|④ HTTP/2 伪装 · REALITY|h2|video||reality|HTTP/2 传输; 形状对 CDN 最友好|REALITY|"
  "vless|xhttp-reality|⑤ xHTTP · REALITY (M 独有)|xhttp|video||reality|xHTTP 伪装成普通 HTTP 接口调用; 仅 M 内核支持|REALITY+xHTTP|"
  "vless|xhttp-tls|⑥ xHTTP · 真证书 (M 独有)|xhttp|video||真证书|xHTTP 走 TLS; 可直连也可过 CDN|真证书+xHTTP|"
  "vless|ws-cdn|⑦ CDN 网页党 · 真证书|ws|web||真证书|走 Cloudflare 回源; 网页浏览档, 最省资源|CDN|cdn"
  "vless|grpc-cdn|⑧ CDN · gRPC 档|grpc|video||真证书|Cloudflare 回源; gRPC 走 HTTP/2|CDN+gRPC|cdn"
  "vless|xhttp-cdn|⑨ CDN · xHTTP 档 (M 独有)|xhttp|video||真证书|xHTTP 过 Cloudflare; 需把该 path 排除缓存|CDN+xHTTP|cdn"
  "vless|ws-cdn-ech|⑩ CDN + ECH · 网页党|ws|web||真证书|ECH 加密真实 SNI, CDN 回源; 域名探测也挡得住|CDN+ECH|cdn,ech"

  # ---------- VMess ----------
  "vmess|tcp-video|① 隐匿优先 · REALITY|tcp|video||reality|裸TCP, 不带任何 Web 特征|REALITY|"
  "vmess|grpc-video|② gRPC 伪装 · REALITY|grpc|video||reality|gRPC 套一层正常 HTTP/2|REALITY|"
  "vmess|grpc-dl|③ gRPC 高并发 · REALITY|grpc|download||reality|多路复用扛并发|REALITY|"
  "vmess|h2-video|④ HTTP/2 伪装 · REALITY|h2|video||reality|HTTP/2 传输|REALITY|"
  "vmess|ws-cdn|⑤ CDN 网页党 · 真证书|ws|web||真证书|走 Cloudflare 回源; 网页浏览档|CDN|cdn"
  "vmess|grpc-cdn|⑥ CDN · gRPC 档|grpc|video||真证书|Cloudflare 回源; gRPC 走 HTTP/2|CDN+gRPC|cdn"

  # ---------- Trojan ----------
  "trojan|tcp-video|① 隐匿优先 · REALITY|tcp|video||reality|裸TCP, 不带任何 Web 特征|REALITY|"
  "trojan|grpc-video|② gRPC 伪装 · REALITY|grpc|video||reality|gRPC 套一层正常 HTTP/2|REALITY|"
  "trojan|grpc-dl|③ gRPC 高并发 · REALITY|grpc|download||reality|多路复用扛并发|REALITY|"
  "trojan|h2-video|④ HTTP/2 伪装 · REALITY|h2|video||reality|HTTP/2 传输|REALITY|"
  "trojan|tls|⑤ 原生 TLS (推荐)|tcp|video||真证书|不用 REALITY, 兼容面最广; 真证书正常校验|真证书|"
  "trojan|ws-cdn|⑥ CDN 网页党 · 真证书|ws|web||真证书|走 Cloudflare 回源|CDN|cdn"
  "trojan|grpc-cdn|⑦ CDN · gRPC 档|grpc|video||真证书|Cloudflare 回源; gRPC 走 HTTP/2|CDN+gRPC|cdn"

  # ---------- AnyTLS ----------
  # ★ 无 REALITY 预置: 实测 mihomo 的 AnyTLS+REALITY 是 0/5 (见 K-5)。
  #   SB 的表里也注明"仅 sing-box 客户端", 本项目直接不提供。
  "anytls|tls-self|① 自签 (pin) · 通用|无|无||selfsign|自签证书 + 钉扎; 一路回车就能建, 无需先备 crt/key|自签|"
  "anytls|tls-real|② 真证书|无|无||真证书|CA 可信证书, 客户端无需 insecure/钉扎; 需先备好 crt/key|真证书|"
  "anytls|tls-pad|③ 真证书 + padding|无|无|pad|真证书|在真证书基础上开 padding 填充, 改变流量形状|真证书+pad|pad"

  # ---------- Shadowsocks (无传输层, 按 mux 档位分) ----------
  "ss|ss-web|① 网页党 (省资源)|无|web||无|网页浏览; 单连接流数压到 1, 内存占用最低|网页|"
  "ss|ss-video|② 视频党 (均衡)|无|video||无|默认档; 看视频 + 日常网页都够用|视频|"
  "ss|ss-dl|③ 下载党 (高吞吐)|无|download||无|大文件/长连接; 单连接多流并行|下载|"

  # ---------- Snell ----------
  "snell|snell-video|① 均衡默认|无|video||无|Snell v4 (mihomo 独有协议)|默认|"

  # ---------- Hysteria2 ----------
  "hysteria2|h2-default|① 推荐默认|无|无||真证书|参数已是最优默认 (BBR + Salamander)|默认|"
  "hysteria2|h2-self|② 自签 (pin)|无|无||selfsign|无域名也能建; 客户端走证书钉扎|自签|"

  # ---------- TUIC v5 ----------
  "tuic|tuic-default|① 推荐默认|无|无||真证书|参数已是最优默认 (BBR + Salamander)|默认|"
  "tuic|tuic-self|② 自签 (pin)|无|无||selfsign|无域名也能建; 客户端走证书钉扎|自签|"
)

# =============================================================
# 查询
# =============================================================
preset_count() { # <协议>
    local p="${1:-}" n=0 row
    for row in "${M_PRESETS[@]}"; do [[ "${row%%|*}" == "$p" ]] && n=$((n+1)); done
    printf '%s' "$n"
}

# 返回去掉「协议|id|」之后的部分, 使列从「显示名」开始。
#
# ★ 这里必须正好剥 **2** 列 (协议, id)。剥 3 列会让后面每一列都左移一位
#   —— 显示名被当成传输、cert 被当成说明, 结果就是"选了 REALITY 却当成
#   自签"这类静默错误 (SB 也在这张表上栽过, 见 preset.sh 头部注释)。
preset_row() { # <协议> <第几行, 1 起> -> stdout: 显示名|传输|mux|flow|证书|说明|标签|额外
    local want="$1" idx="$2" i=1 row cols
    for row in "${M_PRESETS[@]}"; do
        [[ "${row%%|*}" == "$want" ]] || continue
        if (( i == idx )); then
            cols="${row#*|}"; cols="${cols#*|}"
            printf '%s' "$cols"; return 0
        fi
        i=$((i+1))
    done
    return 1
}

# 取某协议某行的 id 字段
preset_id() { # <协议> <第几行>
    local want="$1" idx="$2" i=1 row
    for row in "${M_PRESETS[@]}"; do
        [[ "${row%%|*}" == "$want" ]] || continue
        if (( i == idx )); then
            local rest="${row#*|}"; printf '%s' "${rest%%|*}"; return 0
        fi
        i=$((i+1))
    done
    return 1
}

# =============================================================
# 应用: 把某一行的选择写进 M_PRESET_* 变量
#
# 每次调用都先清空 —— 否则批量或连续添加时会把上一个节点的选择带过来
# (SB 明确踩过这个坑)。
# =============================================================
preset_reset() {
    M_PRESET_TR=""; M_PRESET_MUX=""; M_PRESET_FLOW=""; M_PRESET_CERT=""
    M_PRESET_TAG=""; M_PRESET_ECH=0; M_PRESET_PAD=0; M_PRESET_CDN=0
    M_PRESET_NAME=""; M_PRESET_ID=""; M_PRESET_DESC=""
    M_PRESET_APPLIED=0
}

preset_apply() { # <协议> <第几行>
    local proto="$1" idx="$2" row c
    preset_reset
    row=$(preset_row "$proto" "$idx") || return 1
    c() { printf '%s' "$row" | cut -d'|' -f"$1"; }

    M_PRESET_NAME=$(c 1)
    M_PRESET_TR=$(c 2)
    M_PRESET_MUX=$(c 3)
    M_PRESET_FLOW=$(c 4)
    M_PRESET_CERT=$(c 5)
    M_PRESET_DESC=$(c 6)
    M_PRESET_TAG=$(c 7)
    local extra; extra=$(c 8)

    # "无" 是占位符, 表示该协议没有这个维度
    [[ "$M_PRESET_TR"   == "无" ]] && M_PRESET_TR=""
    [[ "$M_PRESET_FLOW" == "无" ]] && M_PRESET_FLOW=""
    [[ "$M_PRESET_CERT" == "无" ]] && M_PRESET_CERT=""
    [[ "$M_PRESET_MUX"  == "无" ]] && M_PRESET_MUX=""

    # 裸 TCP 保留成显式的 "tcp" 而不是清空 —— 清空后与"用户没选预设"
    # 无法区分, 传输菜单就会回落到默认值, 预置的定位就丢了。(SB 的教训)
    M_PRESET_ID=$(preset_id "$proto" "$idx")

    [[ "$extra" == *ech* ]] && M_PRESET_ECH=1
    [[ "$extra" == *pad* ]] && M_PRESET_PAD=1
    [[ "$extra" == *cdn* ]] && M_PRESET_CDN=1
    M_PRESET_APPLIED=1
    return 0
}

# =============================================================
# 交互菜单 (单个节点创建时用; all.sh 批量走 preset_apply 不交互)
# =============================================================
preset_ask() { # <协议> [标题]
    local proto="$1" title="${2:-推荐配置}" n i=1 row name desc
    preset_reset
    # 批量模式下不提问 (all.sh 用 --preset 显式指定)
    [[ -n "${M_BATCH:-}" ]] && return 0

    n=$(preset_count "$proto")
    (( n == 0 )) && return 0

    print_title "$title (不想选就一路回车, 逐项自己配)"
    while read -r row; do
        [[ -n "$row" ]] || continue
        name=$(printf '%s' "$row" | cut -d'|' -f3)
        desc=$(printf '%s' "$row" | cut -d'|' -f8)
        printf '    %b%2d)%b %-34s %b%s%b\n' \
            "${CYAN:-}" "$i" "${RESET:-}" "$name" "${DIM:-}" "$desc" "${RESET:-}" >&2
        i=$((i+1))
    done < <(for r in "${M_PRESETS[@]}"; do [[ "${r%%|*}" == "$proto" ]] && printf '%s\n' "$r"; done)
    printf '    %b%2d)%b %s\n' "${CYAN:-}" "$i" "${RESET:-}" "不用预设, 我自己逐项配" >&2

    local c; c=$(safe_read "选择" "1")
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n )); then
        preset_apply "$proto" "$c" || return 1
        print_ok "已套用预置: $M_PRESET_NAME"
        print_info "节点名后缀: $M_PRESET_TAG"
        return 0
    fi
    return 0
}

# 列出某协议的全部预置 (给菜单/文档用)
preset_show() { # <协议>
    local proto="${1:-}" i=0 row
    for row in "${M_PRESETS[@]}"; do
        [[ "${row%%|*}" == "$proto" ]] || continue
        i=$((i+1))
        printf '  %2d) %-34s %s\n' "$i" "$(printf '%s' "$row" | cut -d'|' -f3)" \
               "$(printf '%s' "$row" | cut -d'|' -f8)"
    done
    (( i == 0 )) && { printf '  (无预置)\n'; return 1; }
    return 0
}

preset_protocols() {
    local row p seen=""
    for row in "${M_PRESETS[@]}"; do
        p="${row%%|*}"
        [[ " $seen " == *" $p "* ]] && continue
        seen="$seen $p"; printf '%s\n' "$p"
    done
}
