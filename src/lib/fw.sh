#!/usr/bin/env bash
# =============================================================
# mihomo--core · 防火墙管理 (fw.sh)
#
# 设计照搬 参考实现 的 fw_apply.sh 那套 —— 那是在真实机器上被烧出来的:
# 用户自己的 nftables.sh 会在开机时把链上所有 "dport N accept" 规则扫走、
# 去掉注释、存进它自己的文件。于是面板关掉的端口, 下次重启又被打开,
# 而那条规则已经没有任何标记, 从外面看不出它曾经属于哪个节点。
#
# ---- 三条铁律 (违反其中任何一条都可能把用户锁在门外) ----
#
# 1. 只认自己的登记表
#    放行端口时写进 .fw-ports, 这是唯一真实来源。关端口时如果端口不在表里,
#    说明本面板从没为它开过规则, 就不该由本面板去关。
#
# 2. 规则一律带标记
#    没有标记的规则和用户自己加的规则**完全无法区分**。<SERVER_ALIAS> 上实测有 382 条
#    带 --comment SB-Panel 的规则, 证明这台的 -m comment 可用。
#
# 3. SSH 端口永不自动关
#    且**不能写死 22** —— 实测 <SERVER_ALIAS> 上 sshd 监听的是 <SSH_PORT>, 写死 22 的保护在
#    这台机器上形同虚设。必须从 ss 实际监听反查。
#
# ---- 为什么关端口时要删该端口的**全部**规则, 而不只是带标记的 ----
# 用户那套脚本会把注释扫掉, 留下的副本在链上不带任何标记, 认不出归属。
# 只删带标记的那些, 那些副本会永远留着 —— 端口等于没关。
# ==========================================================================

FW_COMMENT="MIHOMO-Panel"          # 规则标记
FW_PORT_LIST=""                     # .fw-ports, 由调用方赋值 (放行的端口登记表)
FW_CLOSED_LIST=""                   # .fw-closed-ports, 本面板主动关过的端口

# 这些端口永远不由节点防火墙逻辑碰 —— 不在登记表里也照样跳过。
# 443/80 可能是 Web 服务, 22/2222 类可能是 SSH, 数据库端口误关等于事故。
FW_NEVER_TOUCH="22 2222 <SSH_PORT> 80 443 8443 3306 5432 6379 27017"

# ---------- 后端探测 ----------

# 依次判定 nft / ufw / firewalld / iptables。
# 注意 nft 判据是 "inet filter 表存在", 不是 "装了 nft 命令": 装了 nft
# 但实际用 iptables 管防火墙的机器很常见 (<SERVER_ALIAS> 就是), 判错了会往错的地方写规则。
fw_detect_backend() {
    if command -v nft >/dev/null 2>&1 \
       && nft list table inet filter >/dev/null 2>&1; then echo nft; return 0; fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"
        then echo ufw; return 0; fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running
        then echo firewalld; return 0; fi
    if command -v iptables >/dev/null 2>&1; then echo iptables; return 0; fi
    echo none
}

# -m comment 是否可用。缓存结果, 探测要建临时链。
fw_comment_ok() {
    if [[ -n "${_FW_CMT_OK:-}" ]]; then [[ "$_FW_CMT_OK" == "1" ]]; return; fi
    if iptables -N MIHOMO_PROBE 2>/dev/null; then
        if iptables -A MIHOMO_PROBE -p tcp -m comment --comment probe -j RETURN 2>/dev/null; then
            iptables -F MIHOMO_PROBE 2>/dev/null
            iptables -X MIHOMO_PROBE 2>/dev/null
            _FW_CMT_OK=1; return 0
        fi
        iptables -F MIHOMO_PROBE 2>/dev/null
        iptables -X MIHOMO_PROBE 2>/dev/null
    fi
    _FW_CMT_OK=0; return 1
}

# iptables 规则的 comment 参数数组; 模块不可用时留空。
# 返回 0=可用 1=不可用
fw_ipt_cmt_args() {
    if fw_comment_ok; then printf '%s\n' "-m" "comment" "--comment" "$FW_COMMENT"; fi
}

# ---------- SSH 保护 ----------

# 这个端口是不是 sshd 的?
#
# ss 的一行形如:
#   LISTEN 0 128 0.0.0.0:<SSH_PORT> 0.0.0.0:* users:(("sshd",pid=860,fd=6))
# 进程名在端口**后面**, 所以不能写成 "sshd.*:PORT" —— 那样永远匹配不上,
# 安全网会形同虚设。必须同一行里既出现该监听端口, 又出现 sshd。
fw_port_is_ssh() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if command -v ss >/dev/null 2>&1; then
        ss -Hltnp 2>/dev/null </dev/null \
            | grep -E "[:.]${port}[[:space:]]" | grep -q "sshd" </dev/null && return 0
    fi
    # 兜底1: sshd 自己的配置 (端口还没起来时也能认)
    if [[ -r /etc/ssh/sshd_config ]]; then
        grep -qiE "^[[:space:]]*Port[[:space:]]+${port}([[:space:]]|$)" /etc/ssh/sshd_config </dev/null && return 0
    fi
    # 兜底2: 防火墙里被标成 SSH 的放行规则 (含原生 nft)
    if command -v nft >/dev/null 2>&1; then
        nft list ruleset 2>/dev/null </dev/null | grep -iE "dport ${port} accept" | grep -qi "ssh" </dev/null && return 0
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -S 2>/dev/null </dev/null | grep -E -- "--dport ${port} " | grep -qi "ssh" </dev/null && return 0
    fi
    return 1
}

fw_is_never_touch() {
    local p="$1"
    for w in $FW_NEVER_TOUCH; do [[ "$w" == "$p" ]] && return 0; done
    return 1
}

# ---------- 登记表 ----------

fw_list_file()      { printf '%s\n' "${FW_PORT_LIST:-${SRV_ROOT:-/root/catmi/mihomo}/.fw-ports}"; }
fw_closed_file()    { printf '%s\n' "${FW_CLOSED_LIST:-${SRV_ROOT:-/root/catmi/mihomo}/.fw-closed-ports}"; }

fw_register() {
    local p="$1" f; f=$(fw_list_file)
    [[ "$p" =~ ^[0-9]+$ ]] || return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null
    grep -qxF "$p" "$f" 2>/dev/null || printf '%s\n' "$p" >> "$f" 2>/dev/null
}

# 从登记表移除一个端口。
#
# 不能写成 `grep -vxF "$p" "$f" > tmp && mv tmp "$f"`:
# 登记表只有一行、且正好是被删的那个端口时, grep 一行都不输出, 退出码是 1,
# `&&` 于是不执行 —— 端口已经关掉了, 登记表却还留着, 于是它永远过不了
# "是否已登记"这一关, 下次同步会被当成新端口再放行一遍。
# 空结果要当成正常情况处理。
fw_unregister() {
    local p="$1" f; f=$(fw_list_file)
    [[ -f "$f" ]] || return 0
    local tmp; tmp="$f.tmp.$$"
    if grep -vxF "$p" "$f" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f" 2>/dev/null
    else
        # 一个都没剩下 = 登记表里只有这个端口, 直接清空
        : > "$f" 2>/dev/null
        rm -f "$tmp"
    fi
}

fw_is_registered() {
    local p="$1" f; f=$(fw_list_file)
    [[ -f "$f" ]] && grep -qxF "$p" "$f" 2>/dev/null
}

fw_mark_closed() {
    local p="$1" f; f=$(fw_closed_file)
    [[ "$p" =~ ^[0-9]+$ ]] || return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null
    grep -qxF "$p" "$f" 2>/dev/null || printf '%s\n' "$p" >> "$f" 2>/dev/null
}

# ---------- 放行 ----------

# open_port <端口> —— 建节点时调
#
# 登记表 + 标记规则, 两个都要成功才算成功。
# 登记表写不进去 (只读目录/磁盘满) 就直接失败, 不能留一条"放行了但
# 关闭时认不出归属"的规则 —— 那种规则日后只能靠人工清理。
fw_open_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || { print_warn "非法端口 $port, 跳过防火墙"; return 1; }
    command -v iptables >/dev/null 2>&1 || { ui_hint "本机无 iptables, 跳过防火墙"; return 0; }

    fw_register "$port" || { print_error "端口登记表写入失败 ($port), 未改动防火墙"; return 1; }

    local -a cmt=()
    mapfile -t cmt < <(fw_ipt_cmt_args)
    local proto
    for proto in tcp udp; do
        if (( ${#cmt[@]} )); then
            iptables -C INPUT -p "$proto" --dport "$port" "${cmt[@]}" -j ACCEPT 2>/dev/null \
                || iptables -I INPUT -p "$proto" --dport "$port" "${cmt[@]}" -j ACCEPT 2>/dev/null
        else
            iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
        fi
    done
    if (( ${#cmt[@]} )); then
        print_ok "防火墙已放行 $port (tcp+udp, 带标记)"
    else
        print_warn "防火墙已放行 $port (tcp+udp)"
        print_warn "  本机 iptables 无 -m comment, 规则未打标记 —— 删除节点时可能无法精确识别"
    fi
}

# ---------- 关闭 ----------

# close_node_port <端口> [节点tag] —— 删节点时调
#
# 三道闸门, 任何一道不过就**不动防火墙**:
#   1. 在登记表里吗? 不在 = 不是本面板开的, 不归本面板管
#   2. 是 sshd 的吗?    是 = 跳过 (防失联)
#   3. 是系统常用端口吗? 是 = 跳过
#
# 过闸之后删该端口的**全部** INPUT 规则, 不只带标记的 ——
# 用户那套脚本会把注释扫掉, 留下的副本不带标记认不出归属, 只删带标记的
# 等于没关。
fw_close_port() {
    local port="$1" tag="${2:-}" acted=0 proto
    [[ "$port" =~ ^[0-9]+$ ]] || return 0

    if ! fw_is_registered "$port"; then
        fw_mark_closed "$port"
        ui_hint "端口 $port 不在本面板登记表内, 未改动防火墙"
        return 0
    fi
    if fw_port_is_ssh "$port"; then
        print_warn "端口 $port 正被 sshd 使用, 跳过关闭 (防失联)"
        return 0
    fi
    if fw_is_never_touch "$port"; then
        print_warn "端口 $port 属于系统常用端口, 跳过关闭"
        return 0
    fi

    _fw_delete_rules "$port" && acted=1

    fw_unregister "$port"
    fw_mark_closed "$port"
    if (( acted )); then
        print_ok "防火墙已关闭 $port${tag:+ (节点 $tag)}"
    else
        ui_hint "端口 $port 在防火墙里没有规则, 已从登记表移除"
    fi
}

# 真正动 iptables 的那一步。三道闸门都过了才调它。
_fw_delete_rules() {
    local port="$1" proto line
    for proto in tcp udp; do
        while :; do
            line=$(iptables -S INPUT 2>/dev/null </dev/null \
                   | grep -E -- "^-A INPUT .*-p ${proto} .*--dport ${port} " | head -1)
            [[ -n "$line" ]] || break
            # iptables -S 输出的是 "-A INPUT ..."; 删规则要把 -A 换成 -D,
            # 其余参数原样保留 (必须一模一样, 否则匹配不上)。
            line="${line/-A INPUT /-D INPUT }"
            iptables $line 2>/dev/null || break
        done
    done
}

# 孤儿清理专用的强制关闭。
#
# 不能直接调 fw_close_port: 它的第一道闸门是"不在登记表就不动", 而孤儿规则
# 按定义就不在登记表 —— 两边逻辑对撞, 结果是**一条都没删, 却报"已清理 N 条"**。
# 这个假成功比没有这个功能更糟: 用户以为防火墙干净了, 实际规则还在。
#
# 这里跳过登记表闸门 (调用方已经独立验证过"不在登记表"), 但 SSH 与系统端口
# 两道闸门仍然生效 —— 孤儿清理也绝不能碰 sshd。
fw_force_close() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if fw_port_is_ssh "$port"; then
        print_warn "端口 $port 正被 sshd 使用, 跳过 (防失联)"
        return 1
    fi
    if fw_is_never_touch "$port"; then
        print_warn "端口 $port 属于系统常用端口, 跳过"
        return 1
    fi
    _fw_delete_rules "$port"
    fw_mark_closed "$port"
    return 0
}

# ---------- 孤儿清理 ----------

# 找出并清掉"本面板留下的、但已经不该存在"的规则。
#
# 判定: 带本面板标记, 且 ①端口不在登记表 ②端口没有程序在监听。
# 两条同时满足才动手 —— 只满足一条可能是正常状态 (比如节点配置还在但服务没起)。
fw_purge_orphans() {
    command -v iptables >/dev/null 2>&1 || { print_info "本机无 iptables, 跳过"; return 0; }
    fw_comment_ok || { print_warn "本机 iptables 无 -m comment, 无法可靠识别归属, 不做清理"; return 1; }

    local listening p orphan=0 kept=0
    listening=$( { ss -tln 2>/dev/null; ss -uln 2>/dev/null; } </dev/null \
                | awk '{print $5}' | grep -oE '[0-9]+$' )

    echo >&2
    local ports
    ports=$(iptables -S INPUT 2>/dev/null </dev/null \
            | grep -- "$FW_COMMENT" | grep -oE -- "--dport [0-9]+" | awk '{print $2}' | sort -un)

    for p in $ports; do
        if fw_is_registered "$p"; then kept=$((kept + 1)); continue; fi
        if fw_port_is_ssh "$p"; then kept=$((kept + 1)); continue; fi
        if fw_is_never_touch "$p"; then kept=$((kept + 1)); continue; fi
        if printf '%s\n' "$listening" | grep -qxF "$p"; then kept=$((kept + 1)); continue; fi
        # 只有真的删掉了才计数 —— 之前无条件 +1, 闸门把它挡下来时仍然报
        # "已清理", 是个假成功。
        printf "  %s: " "$p" >&2
        if fw_force_close "$p" >/dev/null 2>&1; then
            orphan=$((orphan + 1))
            printf "已清理\n" >&2
        else
            printf "跳过\n" >&2
        fi
    done

    if (( orphan == 0 )); then
        print_ok "没有孤儿规则 (保留 $kept 条正常规则)"
    else
        print_ok "已清理 $orphan 条孤儿规则, 保留 $kept 条"
    fi
}

# ---------- 页面 ----------

fw_status_page() {
    local be; be=$(fw_detect_backend)
    print_title "防火墙"
    ui_kv_ascii "后端" "$be"
    ui_kv_ascii "规则标记" "$(fw_comment_ok && echo "$FW_COMMENT (可用)" || echo "不可用 (无法精确识别归属)")"
    ui_kv_ascii "已登记端口" "$(fw_is_registered 0 || wc -l < "$(fw_list_file)" 2>/dev/null || echo 0) 个"
    ui_kv_ascii "SSH 端口" "$(ss -Hltn 2>/dev/null </dev/null | grep sshd \
                          | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ' || echo '未检出')"
    echo >&2

    case "$be" in
        nft)        print_warn "原生 nft: 本面板规则写在链上, 由 fw_apply.sh 开机同步" ;;
        ufw)        print_warn "ufw: 关闭端口需要 ufw delete, 归属判断较弱" ;;
        firewalld)  print_warn "firewalld: 关闭端口需要 --remove-port" ;;
        iptables)   ui_hint "iptables: 规则带 $FW_COMMENT 标记, 关闭时按登记表精确删除" ;;
        none)       print_warn "未检测到任何防火墙后端, 节点端口需要自行放行" ;;
    esac

    local p listening
    listening=$( { ss -tln 2>/dev/null; ss -uln 2>/dev/null; } </dev/null \
                | awk '{print $5}' | grep -oE '[0-9]+$' )
    echo >&2; ui_title "登记表里的端口"
    local n=0
    for p in $(cat "$(fw_list_file)" 2>/dev/null); do
        if printf '%s\n' "$listening" | grep -qxF "$p"; then
            ui_kv_ascii "$p" "${GREEN}监听中${RESET}"
        else
            ui_kv_ascii "$p" "${YELLOW}未监听 (节点可能没跑)${RESET}"
        fi
        n=$((n + 1))
    done
    (( n == 0 )) && { echo >&2; print_info "登记表为空"; return 0; }
}

fw_menu() {
    local c
    while true; do
        fw_status_page
        echo >&2
        ui_menu 1 "清理孤儿规则 (本面板留下但已无用的)"
        ui_menu 2 "手动关闭一个端口"
        ui_menu 3 "查看 SSH 端口 (关端口前务必确认)"
        ui_menu 0 "返回"
        echo >&2
        printf "  ${CYAN}请选择${RESET}: " >&2
        read -r c || return 0
        c=$(clean_input "$c")
        case "$c" in
            1)
                print_warn "将删除: 带标记、不在登记表、且没有程序监听的端口规则"
                printf "  ${CYAN}确认清理? (y/N)${RESET}: " >&2
                local a; read -r a
                [[ "$a" =~ ^[yY]$ ]] && fw_purge_orphans || print_info "已取消"
                ;;
            2)
                printf "  ${CYAN}输入端口号${RESET}: " >&2
                local p; read -r p; p=$(clean_input "$p")
                if [[ "$p" =~ ^[0-9]+$ ]]; then fw_close_port "$p" "手动"
                else ui_invalid "$p"; fi
                ;;
            3)
                echo >&2
                local sp
                sp=$(ss -Hltn 2>/dev/null </dev/null | grep -oE '[0-9]+$' | sort -un)
                echo >&2; print_warn "以下端口由 sshd 监听, 任何情况下都不会被本面板关闭:"
                for p in $sp; do
                    fw_port_is_ssh "$p" && ui_kv_ascii "$p" "sshd"
                done
                ;;
            0|q|Q) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        pause
    done
}
# ---------- 节点生命周期接入 ----------

# 打开一个节点文件里的**所有**监听端口。
# 一个 yaml 可能起多个 listener (all.sh 生成 VLESS 时就是 plain-WS + reality 两个),
# 只放行其中一个的话另一个照样连不上 —— 而现象是"部分节点不通", 极难定位。
fw_open_node_file() {
    local f="$1" p n=0
    [[ -f "$f" ]] || return 0
    while read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        fw_open_port "$p" && n=$((n + 1))
    done < <(fw_ports_in_file "$f")
    (( n > 0 )) && ui_hint "已为 $n 个监听端口放行防火墙"
    return 0
}

# 关闭一个节点文件里的所有端口 (删节点前调, 趁文件还在)
fw_close_node_file() {
    local f="$1" tag="${2:-}" p n=0
    [[ -f "$f" ]] || return 0
    while read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        fw_close_port "$p" "$tag" && n=$((n + 1))
    done < <(fw_ports_in_file "$f")
    return 0
}

# 从节点 yaml 里读出所有监听端口。
# 只认 listeners 段下的 port:, 不碰别的字段 —— 节点配置里还有 users.uuid、
# ws path 等, 误当端口会把防火墙搞乱。
fw_ports_in_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    awk '
        /^listeners:/ { inl = 1; next }
        /^[a-zA-Z]/  { inl = 0 }          # 出了顶层就退出 listeners 段
        inl && /^[[:space:]]*-?[[:space:]]*port:[[:space:]]*[0-9]+/ {
            if (match($0, /[0-9]+/)) print substr($0, RSTART, RLENGTH)
        }
    ' "$f"
}

# 扫描整个配置目录, 为所有节点端口放行 —— 供"一键补齐"用。
# 面板升级前建的老节点没有登记, 不会自动出现在 .fw-ports 里。
fw_sync_all_nodes() {
    local f p n=0
    for f in "${SRV_CONFIGD:-$SRV_ROOT/conf/config.d}"/*.yaml; do
        [[ -f "$f" ]] || continue
        while read -r p; do
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            fw_is_registered "$p" && continue
            fw_open_port "$p" && n=$((n + 1))
        done < <(fw_ports_in_file "$f")
    done
    if (( n > 0 )); then
        print_ok "已补放行 $n 个端口"
    else
        print_ok "所有节点端口均已在登记表中"
    fi
}
