#!/usr/bin/env python3
"""probe_listeners.py — 探测当前 mihomo 内核支持哪些入站 (listener) 类型"""
import subprocess, sys, tempfile, os, yaml

MIHOMO = sys.argv[1] if len(sys.argv) > 1 else "/root/catmi/mihomo/mihomo"

CAND = {
    "mixed":     {"name": "mixed", "type": "mixed", "listen": "127.0.0.1", "port": 17701},
    "http":      {"name": "http", "type": "http", "listen": "127.0.0.1", "port": 17702},
    "socks":     {"name": "socks", "type": "socks", "listen": "127.0.0.1", "port": 17703},
    "redir":     {"name": "redir", "type": "redir", "listen": "127.0.0.1", "port": 17704},
    "tproxy":    {"name": "tproxy", "type": "tproxy", "listen": "127.0.0.1", "port": 17705},
    "tun":       {"name": "tun", "type": "tun", "listen": "127.0.0.1", "port": 17706,
                  "stack": "gvisor"},
    "shadowtls": {"name": "shadowtls", "type": "shadowtls", "listen": "127.0.0.1",
                  "port": 17707},
    "ssh":       {"name": "ssh-in", "type": "ssh", "listen": "127.0.0.1", "port": 17708},
    "vless":     {"name": "vless-in", "type": "vless", "listen": "127.0.0.1",
                  "port": 17709, "allow-insecure": True},
    "vmess":     {"name": "vmess-in", "type": "vmess", "listen": "127.0.0.1",
                  "port": 17710, "users": [{"name": "u", "uuid": "00000000-0000-4000-8000-000000000000"}]},
    "trojan":    {"name": "trojan-in", "type": "trojan", "listen": "127.0.0.1",
                  "port": 17711, "password": "pw"},
    "hysteria2": {"name": "hy2-in", "type": "hysteria2", "listen": "127.0.0.1",
                  "port": 17712, "password": "pw"},
    "tuic":      {"name": "tuic-in", "type": "tuic", "listen": "127.0.0.1",
                  "port": 17713, "users": {"u": {"uuid": "00000000-0000-4000-8000-000000000000", "password": "pw"}}},
    "anytls":    {"name": "anytls-in", "type": "anytls", "listen": "127.0.0.1",
                  "port": 17714, "password": "pw"},
    "snell":     {"name": "snell-in", "type": "snell", "listen": "127.0.0.1",
                  "port": 17715, "psk": "pw", "version": "3"},
    "naive":     {"name": "naive-in", "type": "naive", "listen": "127.0.0.1", "port": 17716},
    "mieru":     {"name": "mieru-in", "type": "mieru", "listen": "127.0.0.1",
                  "port": 17717, "password": "pw", "transport": "tcp",
                  "username": "u"},
    "wireguard": {"name": "wg-in", "type": "wireguard", "listen": "127.0.0.1",
                  "port": 17718, "private-key": "aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleQ=="},
    "shadowtls3": {"name": "st3-in", "type": "shadowtls", "listen": "127.0.0.1",
                   "port": 17719, "version": 3,
                   "password": "pw",
                   "handshake": {"server": "example.com", "server-port": 443}},
}


def probe(ln):
    cfg = {"mixed-port": 0, "mode": "rule", "listeners": [ln],
           "rules": ["MATCH,DIRECT"]}
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        yaml.safe_dump(cfg, fh)
        path = fh.name
    r = subprocess.run([MIHOMO, "-t", "-d", tempfile.mkdtemp(), "-f", path],
                       capture_output=True, text=True, timeout=30)
    os.unlink(path)
    return r.returncode, (r.stderr or "") + (r.stdout or "")


print(f"内核: {MIHOMO}")
print(f"{'入站类型':<14} {'可用':<6} 说明")
print("-" * 64)
ok, bad = [], []
for name, ln in CAND.items():
    rc, out = probe(ln)
    if rc == 0:
        ok.append(name)
        print(f"  {name:<14} {'✓':<6}")
    else:
        line = next((l for l in out.splitlines() if "error" in l.lower()), "")
        line = line.split("msg=")[-1][:56]
        bad.append(name)
        print(f"  {name:<14} {'✗':<6} {line}")
print(f"\n可用 {len(ok)}: {', '.join(ok)}")
if bad:
    print(f"不可用 {len(bad)}: {', '.join(bad)}")