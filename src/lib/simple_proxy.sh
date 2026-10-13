#!/usr/bin/env bash
# =============================================================
# mihomo--core · 简易 HTTP/SOCKS 节点 (客户端)
#
# 用途: 把「本机或局域网里另一个内核」当成一个节点接进来。
# 典型场景:
#   - 这台机器上已经跑着别的内核 (clash / sing-box / v2rayN 等),
#     不想再拉一份节点配置, 直接把它的 7890 当节点用;
#   - 局域网另一台设备开着代理, 手机/平板上的 mihomo 想借它;
#   - 公司/学校只给了个 socks5 出口。
#
# 对齐 SB 的「添加简易 HTTP/SOCKS 节点 (接本机或局域网的其它内核)」。
# 在 Mihomo 里就是一个 type: http / socks5 的 proxy 条目。
#
# 两条容易踩的点:
#   1. **地址不能填 0.0.0.0**。那是"监听所有网卡", 不是"连到那里"。
#      用户从面板上看到监听地址是 0.0.0.0, 直接抄进来就连不上 ——
#      这里显式拦下来并提示填 127.0.0.1 或实际 LAN IP。
#   2. **本机节点不能填 mixed-port 自己**。那会变成"自己代理自己",
#      轻则死循环, 重则连不上任何外网。
# =============================================================

# 探测一个地址上是否有 SOCKS / HTTP 代理在听。
# $1=host $2=port
simple_proxy_probe() {
    local h="$1" p="$2"
    timeout 4 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null
    return 0
}

# 列出本机/局域网常见的代理端口, 帮用户少打字
simple_scan_common() {
    local h="$1"
    printf '%s\n' "$h:7890" "$h:7891" "$h:7897" "$h:1080" "$h:10808" "$h:10809" "$h:8080"
}

simple_add_menu() {
    local host port type user pass ans
    print_title "添加简易 HTTP/SOCKS 节点"

    echo >&2; ui_title "节点地址"
    printf "  ${CYAN}主机${RESET} (127.0.0.1=本机, 192.168.x.x=局域网其它设备): " >&2
    read -r host; host=$(clean_input "$host")
    [[ -n "$host" ]] || { print_error "未输入主机"; return 1; }

    # 0.0.0.0 是"监听所有网卡", 不是可连接的目标 —— 用户常犯
    if [[ "$host" == "0.0.0.0" || "$host" == "::" ]]; then
        print_warn "$host 是监听地址, 不能用来连接"
        print_info "本机请填 127.0.0.1; 局域网设备请填它自己的 IP"
        host=""
    fi

    printf "  ${CYAN}端口${RESET}: " >&2
    read -r port; port=$(clean_input "$port")
    [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )) \
        || { print_error "端口不对"; return 1; }

    # 自己代理自己
    if [[ "$host" == "127.0.0.1" || "$host" == "localhost" ]]; then
        local mine; mine=$(dl_mixed_port 2>/dev/null || printf '7890')
        if [[ "$port" == "$mine" ]]; then
            print_error "那就是本机自己的 mixed-port, 自己代理自己会成死循环"
            return 1
        fi
    fi


    # 常见端口扫一遍, 省得用户不知道填哪个
    if ! simple_proxy_probe "$host" "$port"; then
        print_warn "$host:$port 探测不到代理在监听"
        echo >&2; ui_hint "常见端口:"
        printf '%s\n' "$(simple_scan_common "$host")" | sed 's/^/    /' >&2
        printf "  ${CYAN}仍要继续? (y/N)${RESET}: " >&2
        local a; read -r a
        [[ "$a" =~ ^[yY]$ ]] || return 1
    else
        print_ok "$host:$port 有东西在监听"
    fi

    echo >&2; ui_title "类型"
    ui_menu 1 "socks5 (推荐, 多数内核都支持)"
    ui_menu 2 "http (部分内核只支持 HTTP 代理)"
    echo >&2
    printf "  ${CYAN}请选择${RESET}: " >&2
    local t; read -r t; t=$(clean_input "$t")
    type="socks5"; [[ "$t" == "2" ]] && type="http"

    printf "  ${CYAN}用户名${RESET} (留空=无认证): " >&2
    read -r user; user=$(clean_input "$user")
    printf "  ${CYAN}密码${RESET} (留空=无认证): " >&2
    read -r pass; pass=$(clean_input "$pass")

    # 自定义节点统一进「其他」组。
    #
    # 一个 provider 文件 = 一个组 (组名取文件名), 所以把手工填的 HTTP/SOCKS
    # 全都追加进 providers/其他.yaml, 面板/Web UI 里就是一个叫「其他」的组。
    # 之前是每个节点单独一个 lan-<port>.yaml —— 加几个就多几个组, 而这些节点
    # 本来是一类东西 (自己手工填的出口), 堆在菜单里越来越长。
    #
    # 注意落地位置: 客户端只认 conf/providers/*.yaml (gen_config 扫这个目录),
    # conf/config.d/ 是**服务端**的结构 (由 merge.py 合并), 客户端从来不读 ——
    # 早先版本写在那里, 于是面板报"[OK] 节点已添加"而内核/Web UI 里什么都没有。
    local prov="$CLI_PROVIDERS/其他.yaml"
    local added
    added=$(python3 - "$prov" "$type" "$host" "$port" "${user:-}" "${pass:-}" <<'PYADD'
import os, sys, yaml

path, ptype, server, port, user, password = sys.argv[1:7]
name = "LAN-%s-%s" % (server, port)

data = {"proxies": []}
if os.path.isfile(path):
    try:
        d = yaml.safe_load(open(path, encoding="utf-8")) or {}
    except Exception as exc:                       # noqa: BLE001
        print("读不了 %s (%s)" % (path, exc), file=sys.stderr)
        raise SystemExit(1)
    if not (isinstance(d, dict) and isinstance(d.get("proxies"), list)):
        print("%s 里没有 proxies: 列表, 不敢动它" % path, file=sys.stderr)
        raise SystemExit(1)
    data = d

ps = [x for x in data["proxies"] if isinstance(x, dict)]
base, i = name, 2
while any(x.get("name") == name for x in ps):      # 同名不覆盖, 顺延
    name = "%s-%d" % (base, i); i += 1

entry = {"name": name, "type": ptype, "server": server, "port": int(port)}
if user:
    entry["username"] = user
    entry["password"] = password
data["proxies"] = ps + [entry]

tmp = path + ".tmp"                                # 临时文件 + 原子改名
with open(tmp, "w", encoding="utf-8") as fh:
    yaml.safe_dump(data, fh, allow_unicode=True, sort_keys=False,
                   default_flow_style=False)
os.replace(tmp, path)
print(name)
PYADD
    ) || { print_error "写入 providers/其他.yaml 失败 (见上方报错)"; return 1; }

    print_ok "节点已添加: $added ($type $host:$port) → 组「其他」"
    ui_tip "自定义节点都放在「其他」组里; 组名可用「7) 重命名节点组」改"
    ui_tip "在「域名分流」里可以把这个节点设为分流目标"

    # 校验 + 重启 + 失败回滚, 统一交给 apply_change (不再自己调 _rules_reload)
    apply_change
    return 0
}
