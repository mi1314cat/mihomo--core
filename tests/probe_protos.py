#!/usr/bin/env python3
"""probe_protos.py — 探测当前 mihomo 内核到底认哪些协议类型

方法: 为每种协议生成一个最小可用的 proxy, 跑 mihomo -t。
mihomo -t 对**未知 type** 会直接报错, 所以这个结果是权威的
(不像未知字段那样会被静默忽略)。
"""
import subprocess, sys, tempfile, os, yaml

MIHOMO = sys.argv[1] if len(sys.argv) > 1 else "/root/catmi/mihomo/mihomo"
S = "1.2.3.4"

CANDIDATES = {
    "ss":         {"type": "ss", "server": S, "port": 8388, "cipher": "aes-128-gcm",
                   "password": "pw"},
    "ssr":        {"type": "ssr", "server": S, "port": 8388, "cipher": "aes-128-cfb",
                   "password": "pw", "obfs": "plain", "protocol": "origin"},
    "vmess":      {"type": "vmess", "server": S, "port": 443, "uuid": "00000000-0000-4000-8000-000000000000",
                   "alterId": 0, "cipher": "auto"},
    "vless":      {"type": "vless", "server": S, "port": 443, "uuid": "00000000-0000-4000-8000-000000000000"},
    "trojan":     {"type": "trojan", "server": S, "port": 443, "password": "pw"},
    "snell":      {"type": "snell", "server": S, "port": 443, "psk": "pw", "version": "3"},
    "hysteria":   {"type": "hysteria", "server": S, "port": 443,
                   "auth-str": "pw", "protocol": "udp", "up": "10", "down": "50"},
    "hysteria2":  {"type": "hysteria2", "server": S, "port": 443, "password": "pw"},
    "tuic":       {"type": "tuic", "server": S, "port": 443, "uuid": "00000000-0000-4000-8000-000000000000",
                   "password": "pw"},
    "anytls":     {"type": "anytls", "server": S, "port": 443, "password": "pw"},
    "ssh":        {"type": "ssh", "server": S, "port": 22, "username": "u", "password": "pw"},
    "mieru":      {"type": "mieru", "server": S, "port": 443, "password": "pw",
                   "plugin": "obfs-local", "plugin-opts": {"mode": "tls"}},
    "wireguard":  {"type": "wireguard", "server": S, "port": 51820, "ip": "10.0.0.2/32",
                   "private-key": "aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleQ==",
                   "public-key": "aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleQ=="},
    "http":       {"type": "http", "server": S, "port": 8080},
    "socks5":     {"type": "socks5", "server": S, "port": 1080},
    "direct":     {"type": "direct"},
    "reject":     {"type": "reject"},
    "pass":       {"type": "pass"},
    "compatible": {"type": "compatible"},
}

# 只探出站 (proxy)。入站 (listener) 另外单独探。
def probe(proxy):
    cfg = {"mixed-port": 0, "mode": "rule",
           "proxies": [proxy], "proxy-groups": [{"name": "P", "type": "select",
                                                  "proxies": [proxy["name"]]}],
           "rules": ["MATCH,P"]}
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        yaml.safe_dump(cfg, fh)
        path = fh.name
    r = subprocess.run([MIHOMO, "-t", "-d", tempfile.mkdtemp(), "-f", path],
                       capture_output=True, text=True, timeout=30)
    os.unlink(path)
    return r.returncode, (r.stderr or "") + (r.stdout or "")

print(f"内核: {MIHOMO}")
print(f"{'协议':<12} {'可用':<6} 说明")
print("-" * 62)
ok_list, bad_list = [], []
for name, p in CANDIDATES.items():
    p["name"] = f"t-{name}"
    rc, out = probe(p)
    if rc == 0:
        ok_list.append(name)
        print(f"  {name:<12} {'✓':<6}")
    else:
        line = next((l for l in out.splitlines() if "error" in l.lower()), out.strip()[:44])
        line = line.split("msg=")[-1][:60]
        bad_list.append(name)
        print(f"  {name:<12} {'✗':<6} {line}")

print(f"\n可用 {len(ok_list)}: {', '.join(ok_list)}")
if bad_list:
    print(f"不可用 {len(bad_list)}: {', '.join(bad_list)}")