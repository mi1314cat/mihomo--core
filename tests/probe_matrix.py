#!/usr/bin/env python3
"""probe_matrix.py - 实测 Mihomo 的「协议 x 传输层」搭配矩阵

每个组合同时生成 listener(服务端) 与 proxy(客户端) 两份配置, 两边都要过
mihomo -t。只测单边没意义: 有的组合 listener 认而 proxy 不认。

用法: probe_matrix.py <mihomo 内核路径>
"""
import itertools
import os
import subprocess
import sys
import tempfile

import yaml

BIN = sys.argv[1] if len(sys.argv) > 1 else "/root/catmi/mihomo/mihomo"
U = "00000000-0000-4000-8000-000000000000"
PW = "pw"


def tr_raw():
    return {}, {}, "tcp"


def tr_ws():
    return {"ws-path": "/p"}, {"ws-opts": {"path": "/p"}}, "ws"


def tr_grpc():
    return ({"grpc-service-name": "svc"},
            {"grpc-opts": {"grpc-service-name": "svc"}}, "grpc")


def tr_h2():
    return ({"http-path": "/p"},
            {"h2-opts": {"host": ["h"], "path": "/p"}}, "http")


def tr_hu():
    return ({"ws-path": "/p", "ws-opts": {"v2ray-http-upgrade": True}},
            {"ws-opts": {"v2ray-http-upgrade": True, "path": "/p"}}, "ws")


def tr_xhttp():
    return ({"xhttp-opts": {"path": "/p", "mode": "auto"}},
            {"network": "xhttp", "xhttp-opts": {"path": "/p"}}, "xhttp")


def tr_ssh():
    return {"ssh-opts": {"username": "u"}}, \
           {"ssh-opts": {"username": "u"}}, "ssh"


def tr_kcp():
    return {"kcp-opts": {"seed": "s"}}, {"kcp-opts": {"seed": "s"}}, "kcp"


ORDER = ["raw", "ws", "grpc", "http2", "httpupgrade", "xhttp", "ssh", "kcp"]
TR = {"raw": tr_raw, "ws": tr_ws, "grpc": tr_grpc, "http2": tr_h2,
      "httpupgrade": tr_hu, "xhttp": tr_xhttp, "ssh": tr_ssh, "kcp": tr_kcp}


def pair(port, pn):
    n = "p%d" % port
    s = "1.2.3.4"
    if pn == "vless":
        return ({"name": n, "type": "vless", "port": port, "listen": "0.0.0.0",
                 "users": [{"uuid": U}]},
                {"name": n, "type": "vless", "server": s, "port": port,
                 "uuid": U, "udp": True})
    if pn == "vmess":
        return ({"name": n, "type": "vmess", "port": port, "listen": "0.0.0.0",
                 "users": [{"uuid": U, "alterId": 0}]},
                {"name": n, "type": "vmess", "server": s, "port": port,
                 "uuid": U, "alterId": 0, "cipher": "auto", "udp": True})
    if pn == "trojan":
        return ({"name": n, "type": "trojan", "port": port,
                 "listen": "0.0.0.0",
                 "users": [{"username": "u", "password": PW}]},
                {"name": n, "type": "trojan", "server": s, "port": port,
                 "password": PW, "udp": True})
    if pn == "ss":
        return ({"name": n, "type": "shadowsocks", "port": port,
                 "listen": "0.0.0.0", "cipher": "aes-128-gcm",
                 "password": PW},
                {"name": n, "type": "ss", "server": s, "port": port,
                 "cipher": "aes-128-gcm", "password": PW})
    if pn == "snell":
        return ({"name": n, "type": "snell", "port": port,
                 "listen": "0.0.0.0", "psk": PW, "version": "3"},
                {"name": n, "type": "snell", "server": s, "port": port,
                 "psk": PW, "version": "3"})
    if pn == "anytls":
        return ({"name": n, "type": "anytls", "port": port,
                 "listen": "0.0.0.0", "users": {U: PW}},
                {"name": n, "type": "anytls", "server": s, "port": port,
                 "password": PW})
    raise KeyError(pn)


PNAMES = ["vless", "vmess", "trojan", "ss", "snell", "anytls"]


def run(cfg):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        yaml.safe_dump(cfg, fh)
        path = fh.name
    r = subprocess.run([BIN, "-t", "-d", tempfile.mkdtemp(), "-f", path],
                       capture_output=True, text=True, timeout=30)
    os.unlink(path)
    return r.returncode, (r.stderr or "") + (r.stdout or "")


def why(out):
    for line in out.splitlines():
        low = line.lower()
        if "error" in low or "unsupport" in low or "unset" in low:
            return line.split("msg=")[-1].strip()[:56]
    ls = [x for x in out.strip().splitlines() if x.strip()]
    return ls[-1][:56] if ls else "?"


port = 19100
rows = []
for pn, tn in itertools.product(PNAMES, ORDER):
    port += 1
    el, ep, net = TR[tn]()
    lb, pb = pair(port, pn)
    lb.update(el)
    pb.update(ep)
    if net != "tcp":
        pb["network"] = net
    if tn == "httpupgrade":
        lb.setdefault("allow-insecure", True)
        pb["skip-cert-verify"] = True
    lrc, lout = run({"mixed-port": 0, "mode": "rule", "listeners": [lb],
                     "rules": ["MATCH,DIRECT"]})
    prc, pout = run({"mixed-port": 0, "mode": "rule", "proxies": [pb],
                     "proxy-groups": [{"name": "P", "type": "select",
                                       "proxies": [pb["name"]]}],
                     "rules": ["MATCH,P"]})
    rows.append((pn, tn, lrc, lout, prc, pout))

print("内核: %s" % BIN)
print()
print("  %-9s" % "协议\\传输" + "".join("%-13s" % t for t in ORDER))
print("  " + "-" * (9 + 13 * len(ORDER)))
print("  ⚠️ 以下矩阵仅表示「内核接受了这份配置」, 不代表该组合能连通")
both, only_l, only_p, neither = [], [], [], []
for pn in PNAMES:
    line = "  %-9s" % pn
    for tn in ORDER:
        r = next(x for x in rows if x[0] == pn and x[1] == tn)
        lok, pok = r[2] == 0, r[4] == 0
        if lok and pok:
            line += "%-13s" % "OK"
            both.append((pn, tn))
        elif lok:
            line += "%-13s" % "仅服务端"
            only_l.append((pn, tn, why(r[3])))
        elif pok:
            line += "%-13s" % "仅客户端"
            only_p.append((pn, tn, why(r[5])))
        else:
            line += "%-13s" % "-"
            neither.append((pn, tn, why(r[3]), why(r[5])))
    print(line)

print()
print("OK = 收发两端都支持, 才是真正可用的组合")
print()
print("【语法可接受(不代表能连通)】共 %d 种" % len(both))
for pn in PNAMES:
    ts = [t for p, t in both if p == pn]
    if ts:
        print("   %-8s %s" % (pn, "  ".join(ts)))
print()
print("【仅服务端支持】%d 种" % len(only_l))
for p, t, w in only_l:
    print("   %-8s %-12s %s" % (p, t, w))
print()
print("【仅客户端支持】%d 种" % len(only_p))
for p, t, w in only_p:
    print("   %-8s %-12s %s" % (p, t, w))
print()
print("【两端都不支持】%d 种" % len(neither))
for p, t, a, b in neither:
    print("   %-8s %-12s L:%s" % (p, t, a[:50]))