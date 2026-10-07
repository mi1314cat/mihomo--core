#!/usr/bin/env python3
"""
validate.py — 严格字段白名单校验

为什么需要它：
    Mihomo 的配置解码器 **静默忽略未知键**。实测写 `totally-bogus-key: zzz`
    后 `mihomo -t` 依然输出 "test is successful"。
    也就是说 `-t` 只能证明"能解析"，不能证明"字段生效"。
    一个拼错的键 = 服务正常启动 + 功能静默失效。

本脚本做三件事：
    1. 拦截 **已删除 / 已废弃** 字段（ERROR，附版本号与替代方案）
    2. 拦截 **拼写错误 / 不存在的键**（WARN，指向最接近的合法键）
    3. 校验结构陷阱（类型错误、必填缺失、users 形态等）

用法:
    python3 validate.py --conf /root/catmi/mihomo/conf [--bin /path/to/mihomo]
退出码: 0 通过 / 1 有 ERROR / 2 用法错误
"""
from __future__ import annotations

import argparse
import glob
import os
import sys

try:
    import yaml
except ImportError:
    print("[ERR] 需要 PyYAML: pip3 install pyyaml", file=sys.stderr)
    sys.exit(2)

# =============================================================
# 已删除 / 已废弃 —— 内核不会报错，只会忽略或打一条 ERROR
# key: (版本, 说明, 替代方案)
# =============================================================
REMOVED = {
    "global-client-fingerprint": ("v1.19.27", "顶层全局指纹已删除", "在每个 proxy 上写 client-fingerprint"),
    "override-tuple": ("-", "sniffer.override-tuple 已删除", "使用 sniff.<协议>.override-destination"),
    "ca": ("v1.19.14", "证书校验用的 ca 已删除", "使用 fingerprint"),
    "ca-str": ("v1.19.14", "证书校验用的 ca-str 已删除", "使用 fingerprint"),
    "script": ("-", "顶层 script 不被支持", "-"),
    "ecn": ("-", "顶层 ecn 不被支持", "experimental.quic-go-disable-ecn"),
    "quic": ("-", "顶层 quic 不被支持", "experimental.quic-go-disable-gso"),
    "geoip": ("-", "顶层 geoip 不被支持", "规则里用 GEOIP, 或 geox-url"),
    "geosite": ("-", "顶层 geosite 不被支持", "规则里用 GEOSITE, 或 geox-url"),
    "sniffing": ("已废弃", "请改用 sniff", "sniff: {HTTP/TLS/QUIC}"),
    "port-whitelist": ("已废弃", "请改用 sniff", "sniff: {HTTP/TLS/QUIC}"),
}

REMOVED_IN_GROUP = {
    "routing-mark": ("v1.19.6→11", "分组上的 routing-mark 已删除", "-"),
    "interface-name": ("v1.19.6→11", "分组上的 interface-name 已删除", "-"),
    "dialer-proxy": ("-", "分组上不允许 dialer-proxy", "-"),
}

REMOVED_GROUP_TYPES = {
    "relay": "relay 分组已于 v1.19.17 移除，请使用 dialer-proxy",
    "ssid": "ssid 分组不受支持",
}

# listener 上用错位置的键（放 proxy 才有效）
LISTENER_FORBIDDEN = {
    "ws-opts": "listener 端请用平铺的 ws-path（proxy 端才用 ws-opts）",
    "smux": "smux 仅支持 proxy 端，listener 端请用 mux-option",
    "packet-encoding": "packet-encoding 仅支持 proxy 端",
    "packet-addr": "仅支持 proxy 端",
    "xudp": "仅支持 proxy 端",
}

# =============================================================
# 合法键集合（按内核 v1.19.32 struct tag 整理）
# =============================================================
TOP = {
    "port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "mixed",
    "allow-lan", "bind-address", "lan-allowed-ips", "lan-disallowed-ips",
    "authentication", "skip-auth-prefixes", "mode", "log-level", "ipv6",
    "external-controller", "external-controller-tls", "secret",
    "external-controller-cors", "external-controller-unix", "external-controller-pipe",
    "external-controller-routing-mark", "external-doh-server",
    "external-ui", "external-ui-url", "external-ui-name",
    "unified-delay", "tcp-concurrent", "find-process-mode",
    "keep-alive-interval", "keep-alive-idle", "disable-keep-alive",
    "profile", "geodata-mode", "geo-auto-update", "geo-update-interval",
    "geodata-loader", "geosite-matcher", "geox-url",
    "sniffer", "tun", "dns", "hosts", "rule-providers", "rules", "sub-rules",
    "listeners", "proxies", "proxy-groups", "proxy-providers", "tunnels",
    # 出站: 服务端主动连出去时用的链路。与 proxies (入站节点) 独立。
    # 内核 config/config.go 有这个顶层键 (已用 mihomo -t 实测 v1.19.32 通过)。
    "outbounds",
    "ntp", "iptables", "tls", "experimental", "global-ua", "etag-support",
    # 内核 config/config.go:434-435 确有这两个顶层键, 之前漏了会被误报
    "interface-name", "routing-mark",
    "clash-for-android", "ss-config", "vmess-config", "tuic-server",
    "inbound-tfo", "inbound-mptcp", "sniffer",
}

DNS = {
    "enable", "prefer-h3", "ipv6", "ipv6-timeout", "use-hosts", "use-system-hosts",
    "respect-rules", "nameserver", "fallback", "fallback-filter", "fallback-lazy-query",
    "listen", "listen-routing-mark", "enhanced-mode", "fake-ip-range", "fake-ip-range6",
    "fake-ip-filter", "fake-ip-filter-mode", "fake-ip-ttl", "default-nameserver",
    "cache-algorithm", "cache-max-size", "nameserver-policy", "proxy-server-nameserver",
    "proxy-server-nameserver-policy", "direct-nameserver", "direct-nameserver-follow-policy",
}

SNIFF = {
    "enable", "override-destination", "force-dns-mapping", "parse-pure-ip",
    "force-domain", "skip-src-address", "skip-dst-address", "skip-domain", "sniff",
}
SNIFF_PROTO = {"override-destination", "ports"}

TUN = {
    "enable", "device", "stack", "dns-hijack", "auto-route", "auto-redirect",
    "auto-detect-interface", "mtu", "gso", "gso-max-size", "inet6-address",
    "iproute2-table-index", "iproute2-rule-index", "auto-redirect-input-mark",
    "auto-redirect-output-mark", "auto-redirect-iproute2-fallback-rule-index",
    "loopback-address", "route-address", "route-exclude-address",
    "route-address-set", "route-exclude-address-set",
    "include-interface", "exclude-interface",
    "include-uid", "include-uid-range", "exclude-uid", "exclude-uid-range",
    "exclude-src-port", "exclude-src-port-range", "exclude-dst-port", "exclude-dst-port-range",
    "include-android-user", "include-package", "exclude-package",
    "include-mac-address", "exclude-mac-address",
    "endpoint-independent-nat", "udp-timeout", "icmp-timeout", "disable-icmp-forwarding",
    "congestion-controller", "file-descriptor", "recvmsgx", "sendmsgx",
    "inet4-route-address", "inet6-route-address",
    "inet4-route-exclude-address", "inet6-route-exclude-address",
    "inet4-address",  # 仅 tun listener
}
TUN_STACKS = {"gvisor", "system", "mixed", "mips"}

BASE_LISTENER = {"name", "type", "listen", "port", "rule", "proxy", "routing-mark"}
LISTENER = {
    "vless": BASE_LISTENER | {
        "users", "decryption", "ws-path", "xhttp-config", "grpc-service-name",
        "certificate", "private-key", "client-auth-type", "client-auth-cert",
        "ech-key", "allow-insecure", "shadow-tls", "res-tls", "jls-config",
        "reality-config", "mux-option"},
    "vmess": BASE_LISTENER | {
        "users", "ws-path", "grpc-service-name", "certificate", "private-key",
        "client-auth-type", "client-auth-cert", "ech-key", "shadow-tls", "res-tls",
        "jls-config", "reality-config", "tlsmirror-config", "mekya-config",
        "mkcp-config", "mux-option"},
    "trojan": BASE_LISTENER | {
        "users", "ws-path", "grpc-service-name", "certificate", "private-key",
        "client-auth-type", "client-auth-cert", "ech-key", "allow-insecure",
        "shadow-tls", "res-tls", "jls-config", "reality-config", "mux-option",
        "ss-option"},
    "hysteria2": BASE_LISTENER | {
        "users", "obfs", "obfs-password", "obfs-min-packet-size", "obfs-max-packet-size",
        "certificate", "private-key", "client-auth-type", "client-auth-cert", "ech-key",
        "max-idle-time", "alpn", "up", "down", "ignore-client-bandwidth",
        "masquerade", "cwnd", "bbr-profile", "udp-mtu", "mux-option",
        "initial-stream-receive-window", "max-stream-receive-window",
        "initial-connection-receive-window", "max-connection-receive-window"},
    "tuic": BASE_LISTENER | {
        "token", "users", "certificate", "private-key", "client-auth-type",
        "client-auth-cert", "ech-key", "congestion-controller", "max-idle-time",
        "authentication-timeout", "alpn", "max-udp-relay-packet-size", "cwnd",
        "bbr-profile", "mux-option"},
    "anytls": BASE_LISTENER | {
        "users", "certificate", "private-key", "client-auth-type", "client-auth-cert",
        "ech-key", "shadow-tls", "res-tls", "jls-config", "allow-insecure",
        "padding-scheme"},
    "shadowsocks": BASE_LISTENER | {
        "password", "cipher", "udp", "mux-option", "shadow-tls", "res-tls",
        "jls-config", "kcp-tun", "simple-obfs"},
    "snell": BASE_LISTENER | {
        "psk", "version", "udp", "obfs-opts", "shadow-tls", "res-tls", "jls-config"},
    "socks": BASE_LISTENER | {"users", "udp", "certificate", "private-key",
                               "client-auth-type", "client-auth-cert", "ech-key",
                               "reality-config"},
    "mixed": BASE_LISTENER | {"users", "udp", "certificate", "private-key",
                              "client-auth-type", "client-auth-cert", "ech-key",
                              "reality-config"},
    "http": BASE_LISTENER | {"users", "certificate", "private-key",
                             "client-auth-type", "client-auth-cert", "ech-key",
                             "reality-config"},
    "tproxy": BASE_LISTENER | {"udp"},
    "redir": BASE_LISTENER,
    # tunnel listener —— 端口转发 (TCP/UDP 转发) 用。
    #
    # ★ 踩过的坑, 别再改回 direct:
    #   直觉上端口转发应该写 `type: direct`, 但内核**没有**这个 listener 类型,
    #   mihomo -t 会直接报 `listener N: unsupport proxy type: direct`。
    #   而且这个报错**不会**在面板上体现为"端口转发坏了", 只表现为
    #   "整批配置校验不过" —— 因为它和节点共用同一个 listeners 数组。
    #
    #   正确写法 (已用 mihomo -t v1.19.32 逐字段实测):
    #       type: tunnel
    #       network: [tcp]        # 必须**列表**, 写成标量报 'network' is not a slice
    #       target: host:port     # 无 ,omitempty => 缺了报 "has unset fields"
    #       override-destination: bool
    "tunnel": BASE_LISTENER | {"network", "target", "override-destination"},
}
LISTENER_TYPES = set(LISTENER) | {"tun", "tunnel"}

# 出站 (outbounds 段) 的字段白名单。
#   common/direct/reject/reject-drop 无额外字段;
#   socks5/http 需要 server+port;
#   其余走 dialer-proxy 的协议与 PROXY 同构 —— 这里不重复列全, 只在
#   check_outbounds 里按类型挑对应的白名单。
OUTBOUND_BASE = {"name", "type", "udp", "interface-name", "routing-mark",
                 "ip-version", "dialer-proxy", "tfo", "mptcp"}
OUTBOUND_UPSTREAM = OUTBOUND_BASE | {"server", "port", "username", "password",
                                     "tls", "skip-cert-verify", "sni",
                                     "client-fingerprint", "fingerprint"}
# 可接受的出站类型 (内核 outbound/ 下实际实现的)
OUTBOUND_TYPES = {"direct", "reject", "reject-drop", "pass", "compatible",
                  "socks5", "http", "ss", "snell", "vmess", "vless", "trojan",
                  "hysteria2", "tuic", "anytls", "shadow-tls", "wireguard"}

BASE_PROXY = {"name", "server", "port", "type", "udp", "tfo", "mptcp",
              "interface-name", "routing-mark", "ip-version", "dialer-proxy", "smux"}
TLS_PROXY = {"tls", "alpn", "skip-cert-verify", "name-cert-verify", "fingerprint",
             "certificate", "private-key", "ech-opts"}
PROXY = {
    "vless": BASE_PROXY | TLS_PROXY | {
        "uuid", "flow", "packet-addr", "xudp", "packet-encoding", "encryption",
        "network", "shadow-tls-opts", "restls-opts", "jls-opts", "reality-opts",
        "http-opts", "h2-opts", "grpc-opts", "ws-opts", "xhttp-opts",
        "servername", "client-fingerprint"},
    "vmess": BASE_PROXY | TLS_PROXY | {
        "uuid", "alterId", "cipher", "network", "shadow-tls-opts", "restls-opts",
        "jls-opts", "reality-opts", "tlsmirror-opts", "mekya-opts", "mkcp-opts",
        "http-opts", "h2-opts", "grpc-opts", "ws-opts", "packet-addr", "xudp",
        "packet-encoding", "global-padding", "authenticated-length",
        "servername", "client-fingerprint"},
    "trojan": BASE_PROXY | TLS_PROXY | {
        "password", "sni", "network", "shadow-tls-opts", "restls-opts", "jls-opts",
        "reality-opts", "grpc-opts", "ws-opts", "ss-opts", "client-fingerprint"},
    "ss": BASE_PROXY | {"password", "cipher", "plugin", "plugin-opts",
                        "udp-over-tcp", "udp-over-tcp-version", "client-fingerprint"},
    "hysteria2": BASE_PROXY | TLS_PROXY | {
        "ports", "hop-interval", "up", "down", "password", "obfs", "obfs-password",
        "obfs-min-packet-size", "obfs-max-packet-size", "sni", "cwnd", "bbr-profile",
        "udp-mtu", "handshake-timeout", "realm-opts", "initial-stream-receive-window",
        "max-stream-receive-window", "initial-connection-receive-window",
        "max-connection-receive-window", "client-fingerprint"},
    "tuic": BASE_PROXY | {
        "token", "uuid", "password", "ip", "heartbeat-interval", "alpn", "reduce-rtt",
        "request-timeout", "udp-relay-mode", "congestion-controller", "disable-sni",
        "max-udp-relay-packet-size", "fast-open", "max-open-streams", "cwnd",
        "bbr-profile", "skip-cert-verify", "name-cert-verify", "fingerprint",
        "certificate", "private-key", "recv-window-conn", "recv-window",
        "disable-mtu-discovery", "max-datagram-frame-size", "sni", "ech-opts",
        "udp-over-stream", "udp-over-stream-version", "client-fingerprint"},
    "anytls": BASE_PROXY | TLS_PROXY | {
        "password", "sni", "shadow-tls-opts", "restls-opts", "jls-opts",
        "client-metadata", "idle-session-check-interval", "idle-session-timeout",
        "min-idle-session", "disable-reuse", "client-fingerprint"},
    "snell": BASE_PROXY | {"psk", "version", "reuse", "obfs-opts", "client-fingerprint"},
    "socks5": BASE_PROXY | TLS_PROXY | {"username", "password"},
    "http": BASE_PROXY | TLS_PROXY | {"username", "password", "sni", "headers"},
    "wireguard": BASE_PROXY,
    "ssh": BASE_PROXY,
    "mieru": BASE_PROXY | {"users", "transport", "traffic-pattern"},
    "direct": BASE_PROXY, "reject": BASE_PROXY, "pass": BASE_PROXY,
    "dns": BASE_PROXY, "compatible": BASE_PROXY,
}
# 补充协议 —— 字段名逐个对照 adapter/outbound/<proto>.go
PROXY["openvpn"] = {
    "server", "port", "proto", "dev", "cipher", "data-ciphers",
    "data-ciphers-fallback", "auth", "comp-lzo", "ca", "cert", "key",
    "tls-auth", "key-direction", "tls-crypt", "tls-crypt-v2", "username",
    "password", "peer-info", "ping", "ping-restart", "tran-window",
    "handshake-timeout", "mtu", "udp", "ip-stack", "remote-dns-resolve", "dns",
}
PROXY["tailscale"] = {
    "hostname", "auth-key", "control-url", "state-dir", "ephemeral", "udp",
    "accept-routes", "exit-node", "exit-node-allow-lan-access",
}
PROXY["hysteria"] = {
    "port", "ports", "protocol", "obfs-protocol", "up", "up-speed", "down",
    "down-speed", "auth", "auth-str", "obfs", "sni", "ech-opts",
    "skip-cert-verify", "name-cert-verify", "fingerprint", "certificate",
    "private-key", "alpn", "recv-window-conn", "recv-window",
    "disable-mtu-discovery", "fast-open", "hop-interval",
} | TLS_PROXY | BASE_PROXY

# 死字段: 内核保留了 yaml tag, 但代码里从不读取 —— 写了不报错也不生效。
# vless.ws-headers 就是典型 (真正生效的是 ws-opts.headers)。
DEAD_FIELDS = {
    ("vless", "ws-headers"),
    ("vmess", "ws-headers"),
}

PROXY_TYPES = set(PROXY)

TRANSPORT_OPTS = {
    "ws-opts": {"path", "headers", "max-early-data", "early-data-header-name",
                "v2ray-http-upgrade", "v2ray-http-upgrade-fast-open"},
    "grpc-opts": {"grpc-service-name", "grpc-user-agent", "ping-interval",
                  "max-connections", "min-streams", "max-streams"},
    "http-opts": {"method", "path", "headers"},
    "h2-opts": {"host", "path"},
    "reality-opts": {"public-key", "short-id", "support-x25519mlkem768"},
    # proxy 侧 xhttp-opts —— 键名逐个对照 adapter/outbound/vless.go:XHTTPOptions。
    # 只列 8 个键会把合法的 xhttp 配置判成未知字段, 校验一旦覆盖客户端就会满屏误报。
    "xhttp-opts": {
        "path", "host", "mode", "headers", "no-grpc-header",
        "uplink-http-method",
        "x-padding-bytes", "x-padding-obfs-mode", "x-padding-key",
        "x-padding-header", "x-padding-placement", "x-padding-method",
        "session-placement", "session-key", "session-table", "session-length",
        "seq-placement", "seq-key",
        "uplink-data-placement", "uplink-data-key", "uplink-chunk-size",
        "sc-max-each-post-bytes", "sc-min-posts-interval-ms",
        "reuse-settings", "download-settings",
    },
}
# XHTTP 嵌套子结构 (adapter/outbound/vless.go:XHTTPReuseSettings)
XHTTP_REUSE_OPTS = {"max-concurrency", "max-connections", "c-max-reuse-times",
                    "h-max-request-times", "h-max-reusable-secs", "h-keep-alive-period"}

TRANSPORT_OPTS["xhttp-config"] = TRANSPORT_OPTS["xhttp-opts"] | {
    "no-sse-header", "x-padding-bytes", "x-padding-obfs-mode", "x-padding-key",
    "x-padding-header", "x-padding-placement", "x-padding-method",
    "session-placement", "session-key", "seq-placement", "seq-key",
    "uplink-data-placement", "uplink-data-key", "uplink-chunk-size",
    "sc-stream-up-server-secs", "sc-max-buffered-posts", "sc-max-each-post-bytes"}

GROUP_TYPES = {"select", "url-test", "fallback", "load-balance"}
GROUP = {
    "name", "type", "proxies", "use", "url", "interval", "timeout",
    "max-failed-times", "empty-fallback", "lazy", "disable-udp", "filter",
    "exclude-filter", "exclude-type", "expected-status", "include-all",
    "include-all-proxies", "include-all-providers", "hidden", "icon",
    "default-selected", "tolerance", "strategy", "hash-key",
}

PROVIDER = {
    "type", "path", "url", "proxy", "interval", "filter", "exclude-filter",
    "exclude-type", "dialer-proxy", "size-limit", "header", "age-secret-key",
    "payload", "health-check",
}
HEALTH_CHECK = {"enable", "url", "interval", "timeout", "lazy", "expected-status"}

RULE_PROVIDER = {
    "type", "behavior", "format", "path", "url", "proxy", "interval",
    "size-limit", "header", "payload", "path-in-bundle",
}
# rule-provider 的 type (vehicle) 只有这三种。**写别的内核不认**, 而且报的错
# 是 "unsupported vehicle type: xxx" —— 与本文件无关的错误名, 很难联想到
# 是 rule-providers 段的问题。
# 已用 mihomo -t v1.19.32 逐个实测:
#   inline —— payload 直接写在配置里 (面板生成的规则集用这个, 不依赖外部文件)
#   file   —— 本地文件
#   http   —— 远程规则集
# ⚠ 注意 **不是 "payload"**。凭直觉写 type: payload 会整批配置校验失败。
RULE_PROVIDER_TYPES = {"inline", "file", "http"}


def _norm_key(k: str) -> str:
    return k.lower().replace("_", "-")


def _closest(key: str, pool) -> str | None:
    import difflib
    c = difflib.get_close_matches(key.lower(), sorted(pool), n=1, cutoff=0.7)
    return c[0] if c else None


class Report:
    def __init__(self):
        self.errors: list[str] = []
        self.warns: list[str] = []

    def err(self, where, msg):
        self.errors.append(f"{where}: {msg}")

    def warn(self, where, msg):
        self.warns.append(f"{where}: {msg}")


# `ca` 在 TLS 型代理上确实已删, 但 openvpn 的 ca 是真实在用的 CA 路径,
# 不能按同一张废弃表一刀切, 否则合法配置被误杀。
REMOVED_EXEMPT = {("openvpn", "ca")}


def check_keys(d, allowed, where, r: Report, ctx="", owner=""):
    if not isinstance(d, dict):
        return
    for k, v in d.items():
        nk = _norm_key(k)
        if nk in REMOVED and (owner, nk) not in REMOVED_EXEMPT:
            ver, note, alt = REMOVED[nk]
            r.err(where, f"字段 `{k}` 已废弃/删除 ({ver}) — {note}"
                         + (f"；请改用 `{alt}`" if alt and alt != "-" else ""))
            continue
        if nk in REMOVED_IN_GROUP and ctx == "group":
            ver, note, alt = REMOVED_IN_GROUP[nk]
            r.err(where, f"分组上的 `{k}` 不可用 ({ver}) — {note}")
            continue
        if nk in allowed:
            continue
        near = _closest(k, allowed)
        r.warn(where, f"未知键 `{k}`（内核会静默忽略）"
                      + (f"；是否想写 `{near}`？" if near else ""))


def check_outbounds(cfg, r: Report):
    """校验 outbounds 段 (服务端出站管理用)。"""
    seen = set()
    for i, o in enumerate(cfg.get("outbounds") or []):
        if not isinstance(o, dict):
            continue
        w = f"outbounds[{i}]({o.get('name','?')})"
        t = o.get("type")
        if t not in OUTBOUND_TYPES:
            r.err(w, f"不支持的 outbound 类型 `{t}`；"
                     f"可用: {', '.join(sorted(OUTBOUND_TYPES))}")
            continue
        # 需要上游地址的类型
        if t in ("socks5", "http"):
            check_keys(o, OUTBOUND_UPSTREAM, w, r, owner=t)
            if "server" not in o:
                r.err(w, f"{t} 出站缺少 server")
            if "port" not in o:
                r.err(w, f"{t} 出站缺少 port")
        elif t in PROXY_TYPES:
            # 与入站 proxy 同构的协议, 复用 PROXY 白名单
            check_keys(o, PROXY[t] | OUTBOUND_BASE, w, r, owner=t)
        else:
            check_keys(o, OUTBOUND_BASE, w, r, owner=t)
        n = o.get("name")
        if n:
            if n in seen:
                r.err(w, f"出站名称 `{n}` 重复 —— rules 里按名字引用, 重名无法区分")
            seen.add(n)


def check_listeners(cfg, r: Report):
    for i, it in enumerate(cfg.get("listeners") or []):
        if not isinstance(it, dict):
            continue
        w = f"listeners[{i}]({it.get('name','?')})"
        t = it.get("type")
        if t not in LISTENER_TYPES:
            r.err(w, f"不支持的 listener 类型 `{t}`；"
                     f"可用: {', '.join(sorted(LISTENER_TYPES))}")
            continue
        check_keys(it, LISTENER.get(t, BASE_LISTENER), w, r)
        for bad, hint in LISTENER_FORBIDDEN.items():
            if _norm_key(bad) in {_norm_key(x) for x in it}:
                r.err(w, f"`{bad}` 在 listener 上无效 — {hint}")
        if t == "tun":
            st = it.get("stack")
            if st and st.lower() not in TUN_STACKS:
                r.err(w, f"tun.stack=`{st}` 无效；可用: {', '.join(sorted(TUN_STACKS))}"
                         f"（注意 lwip 已更名为 mips）")
        if t in ("hysteria2", "tuic"):
            if not it.get("certificate") or not it.get("private-key"):
                r.err(w, f"{t} listener 缺少 certificate/private-key（内核会硬失败）")
            us = it.get("users")
            if us is not None and not isinstance(us, dict):
                r.err(w, f"{t} 的 users 必须是 map（名称: 密码），写成 list 会硬报错")
        if t in ("vless", "vmess", "trojan"):
            us = it.get("users")
            if us is not None and not isinstance(us, list):
                r.err(w, f"{t} 的 users 必须是 list（{{username: ...}}），"
                         f"写成 map 会硬报错")
        for opt in ("ws-opts", "grpc-opts", "http-opts", "h2-opts",
                    "reality-opts", "xhttp-config", "xhttp-opts"):
            if isinstance(it.get(opt), dict):
                check_keys(it[opt], TRANSPORT_OPTS.get(opt, set()),
                           f"{w}.{opt}", r)


def _check_xhttp_nested(d: dict, w: str, r: Report) -> None:
    """xhttp-opts 里的嵌套子结构。download-settings 是一整份 proxy 定义,
    字段集与 xhttp-opts 完全不同, 不能按同一份白名单套。"""
    if isinstance(d.get("reuse-settings"), dict):
        check_keys(d["reuse-settings"], XHTTP_REUSE_OPTS, f"{w}.reuse-settings", r)
    if isinstance(d.get("download-settings"), dict):
        ds = d["download-settings"]
        # download-settings = 一整份 vless proxy 定义 + xhttp 自己的 path/host/headers
        allowed = set(PROXY.get("vless", BASE_PROXY)) | {"path", "host", "headers",
                                                         "reuse-settings"}
        for k in ds:
            if k not in allowed:
                r.err(f"{w}.download-settings", f"未知字段 `{k}`")
        if "mode" in ds:
            r.err(f"{w}.download-settings", "`mode` 只能写在 xhttp-opts 外层")
        if "port" not in ds:
            r.warn(f"{w}.download-settings", "未指定 port，可能下载不下来")


def check_proxies(cfg, r: Report):
    for i, p in enumerate(cfg.get("proxies") or []):
        if not isinstance(p, dict):
            continue
        w = f"proxies[{i}]({p.get('name','?')})"
        t = p.get("type")
        if t not in PROXY_TYPES:
            r.err(w, f"不支持的 proxy 类型 `{t}`")
            continue
        check_keys(p, PROXY.get(t, BASE_PROXY), w, r, owner=t)
        if t in ("vmess",) and "alterId" not in p:
            r.err(w, "vmess 缺少 alterId（必填）")
        if t in ("vmess",) and "cipher" not in p:
            r.err(w, "vmess 缺少 cipher（必填，如 auto）")
        if t == "trojan":
            for bad in ("h2-opts", "http-opts", "xhttp-opts"):
                if bad in p:
                    r.err(w, f"trojan 不支持 `{bad}`（仅支持 grpc / ws）")
        if t in ("socks5",) and ("sni" in p or "servername" in p):
            r.err(w, "socks5 没有 sni/servername 字段（请用 name-cert-verify）")
        if t == "hysteria2" and "masquerade" in p:
            r.err(w, "masquerade 仅 listener 端支持")
        if t == "vmess" and "ws-headers" in p:
            r.err(w, "vmess 不支持 ws-headers（用 ws-opts.headers）")
        # 死字段: 内核保留 yaml tag 但代码从不读取, 写了对错都没提示, 功能静默失效
        for k in p:
            if (t, k) in DEAD_FIELDS:
                r.err(w, f"`{k}` 是死字段：内核不读取该键（vless 用的是 ws-opts.headers）")
        for opt in ("ws-opts", "grpc-opts", "http-opts", "h2-opts",
                    "reality-opts", "xhttp-opts"):
            if isinstance(p.get(opt), dict):
                check_keys(p[opt], TRANSPORT_OPTS.get(opt, set()), f"{w}.{opt}", r)
        # xhttp 嵌套结构单独校验
        if isinstance(p.get("xhttp-opts"), dict):
            _check_xhttp_nested(p["xhttp-opts"], f"{w}.xhttp-opts", r)


def check_groups(cfg, r: Report):
    for g in cfg.get("proxy-groups") or []:
        if not isinstance(g, dict):
            continue
        w = f"proxy-groups[{g.get('name','?')}]"
        t = g.get("type")
        if t in REMOVED_GROUP_TYPES:
            r.err(w, REMOVED_GROUP_TYPES[t])
            continue
        if t not in GROUP_TYPES:
            r.err(w, f"不支持的分组类型 `{t}`；可用: {', '.join(sorted(GROUP_TYPES))}")
            continue
        check_keys(g, GROUP, w, r, ctx="group")
        if not g.get("proxies") and not g.get("use"):
            r.err(w, "proxies 与 use 至少要有一个")
        ef = g.get("empty-fallback")
        if ef and ef not in {p.get("name") for p in (cfg.get("proxies") or [])
                             if isinstance(p, dict)}:
            r.warn(w, f"empty-fallback=`{ef}` 必须是一个具体节点名，不能是分组名")


def check_providers(cfg, r: Report):
    for name, p in (cfg.get("proxy-providers") or {}).items():
        w = f"proxy-providers[{name}]"
        check_keys(p, PROVIDER, w, r)
        if not isinstance(p.get("type"), (str, type(None))) or not p.get("type"):
            r.err(w, "缺少 type (http / file / inline)")
        if p.get("type") == "http" and not p.get("url") and not p.get("payload"):
            r.err(w, "type: http 需要 url")
        hc = p.get("health-check")
        if isinstance(hc, dict):
            check_keys(hc, HEALTH_CHECK, f"{w}.health-check", r)


def check_rule_providers(cfg, r: Report):
    for name, p in (cfg.get("rule-providers") or {}).items():
        w = f"rule-providers[{name}]"
        check_keys(p, RULE_PROVIDER, w, r)
        t = p.get("type")
        if t and t not in RULE_PROVIDER_TYPES:
            r.err(w, f"不支持的 rule-provider 类型 `{t}`；"
                     f"可用: {', '.join(sorted(RULE_PROVIDER_TYPES))}")
        # inline 型必须有 payload, 否则是空规则集 (规则写了也不匹配任何东西)
        if t == "inline" and not p.get("payload"):
            r.err(w, "type: inline 但没有 payload —— 空规则集不会匹配任何流量")
        if t == "http" and not p.get("url"):
            r.err(w, "type: http 但没有 url")
        if p.get("behavior") not in (None, "domain", "ipcidr", "classical"):
            r.err(w, f"behavior=`{p.get('behavior')}` 无效")


def check_dns(cfg, r: Report):
    d = cfg.get("dns")
    if not isinstance(d, dict):
        return
    check_keys(d, DNS, "dns", r)
    ff = d.get("fallback-filter")
    if isinstance(ff, dict):
        # 已实测: geoip-code 在 v1.19.32 是字符串, 写成列表会硬报错
        if isinstance(ff.get("geoip-code"), list):
            r.err("dns.fallback-filter", "geoip-code 必须是字符串（如 CN），"
                                          "写成列表会导致 YAML 硬报错")
        if "geosite" in ff:
            r.warn("dns.fallback-filter", "geosite 已废弃，建议改用 nameserver-policy")
    em = d.get("enhanced-mode")
    if em and em not in ("fake-ip", "redir-host", "normal"):
        r.err("dns", f"enhanced-mode=`{em}` 无效")
    ca = d.get("cache-algorithm")
    if ca and ca not in ("lru", "arc"):
        r.err("dns", f"cache-algorithm=`{ca}` 无效（lru / arc）")


def check_sniffer(cfg, r: Report):
    s = cfg.get("sniffer")
    if not isinstance(s, dict):
        return
    check_keys(s, SNIFF, "sniffer", r)
    sn = s.get("sniff")
    if isinstance(sn, dict):
        for proto, v in sn.items():
            if str(proto).upper() not in ("HTTP", "TLS", "QUIC"):
                r.err("sniffer.sniff", f"`{proto}` 无效（只能 HTTP / TLS / QUIC）")
            elif isinstance(v, dict):
                check_keys(v, SNIFF_PROTO, f"sniffer.sniff.{proto}", r)


def check_tun(cfg, r: Report):
    t = cfg.get("tun")
    if not isinstance(t, dict):
        return
    check_keys(t, TUN, "tun", r)
    st = t.get("stack")
    if st and str(st).lower() not in TUN_STACKS:
        r.err("tun", f"stack=`{st}` 无效；可用: {', '.join(sorted(TUN_STACKS))}"
                     f"（lwip 已更名为 mips）")


def validate_one(cfg, r: Report, src: str):
    if not isinstance(cfg, dict):
        r.err(src, "顶层不是 map")
        return
    check_keys(cfg, TOP, src, r)
    check_listeners(cfg, r)
    check_proxies(cfg, r)
    check_outbounds(cfg, r)
    check_groups(cfg, r)
    check_providers(cfg, r)
    check_rule_providers(cfg, r)
    check_dns(cfg, r)
    check_sniffer(cfg, r)
    check_tun(cfg, r)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf", required=True)
    ap.add_argument("--bin", default="")
    args = ap.parse_args()

    r = Report()
    files = []
    main_f = os.path.join(args.conf, "config.yaml")
    if os.path.isfile(main_f):
        files.append(main_f)
    files += sorted(glob.glob(os.path.join(args.conf, "config.d", "*.yaml")))

    if not files:
        print("[WARN] 没有找到任何配置文件", file=sys.stderr)
        return 0

    for f in files:
        try:
            with open(f, "r", encoding="utf-8") as fh:
                cfg = yaml.safe_load(fh)
        except Exception as e:  # noqa: BLE001
            r.err(os.path.relpath(f), f"YAML 解析失败: {e}")
            continue
        validate_one(cfg, r, os.path.relpath(f))

    for e in r.errors:
        print(f"[ERROR] {e}", file=sys.stderr)
    for w in r.warns:
        print(f"[WARN ] {w}", file=sys.stderr)

    if r.errors:
        print(f"\n严格校验失败: {len(r.errors)} 个错误, {len(r.warns)} 个警告", file=sys.stderr)
        return 1

    if r.warns:
        print(f"\n严格校验通过（{len(r.warns)} 个警告，字段可能被内核静默忽略）",
              file=sys.stderr)
    else:
        print("\n严格校验通过", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())