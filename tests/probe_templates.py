#!/usr/bin/env python3
"""probe_templates.py — 验证 all.sh 要生成的每个协议模板能否通过 mihomo -t

只做一件事: 把每个协议的完整 listener 模板丢给内核, 看认不认。
全绿之后再去写 all.sh, 避免写完再回来调。
"""
import subprocess, sys, tempfile, os, yaml

MIHOMO = sys.argv[1] if len(sys.argv) > 1 else "/root/catmi/mihomo/mihomo"
U = "00000000-0000-4000-8000-000000000000"   # RFC4122 示例值, 非真实凭据
PK = "aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleQ=="   # 仅用于占位, 非真实密钥

T = {
"reality": {"name": "reality-01", "type": "vless", "listen": "0.0.0.0", "port": 18443,
    "users": [{"uuid": U, "flow": "xtls-rprx-vision", "name": "u1"}],
    "reality-opts": {"public-key": PK, "short-id": "abcd1234"}},

"trojan-reality": {"name": "trojan-01", "type": "trojan", "listen": "0.0.0.0", "port": 18444,
    "password": "pw", "users": [{"name": "u1", "password": "pw"}],
    "reality-opts": {"public-key": PK, "short-id": "abcd1234"}},

"trojan-tls": {"name": "trojan-02", "type": "trojan", "listen": "0.0.0.0", "port": 18445,
    "password": "pw", "users": [{"name": "u1", "password": "pw"}],
    "certificate": "/tmp/x.crt", "private-key": "/tmp/x.key"},

"vless-ws": {"name": "vless-01", "type": "vless", "listen": "0.0.0.0", "port": 18446,
    "users": [{"uuid": U, "name": "u1"}], "ws-path": "/ws"},

"vless-ws-tls": {"name": "vless-02", "type": "vless", "listen": "0.0.0.0", "port": 18447,
    "users": [{"uuid": U, "name": "u1"}], "ws-path": "/ws",
    "certificate": "/tmp/x.crt", "private-key": "/tmp/x.key"},

"vmess-ws": {"name": "vmess-01", "type": "vmess", "listen": "0.0.0.0", "port": 18448,
    "users": [{"uuid": U, "name": "u1", "alterId": 0}], "ws-path": "/ws"},

"hysteria2": {"name": "hysteria2-01", "type": "hysteria2", "listen": "0.0.0.0",
    "port": 18449, "password": "pw", "users": {"u1": "pw"},
    "certificate": "/tmp/x.crt", "private-key": "/tmp/x.key"},

"tuicv5": {"name": "tuicv5-01", "type": "tuic", "listen": "0.0.0.0", "port": 18450,
    "users": {U: "pw"}, "congestion-controller": "bbr",
    "max-idle-time": 15000, "alpn": ["h3"],
    "certificate": "/tmp/x.crt", "private-key": "/tmp/x.key"},

"anytls": {"name": "anytls-01", "type": "anytls", "listen": "0.0.0.0", "port": 18451,
    "password": "pw", "users": {U: "pw"}},

"shadowsocks": {"name": "ss-01", "type": "shadowsocks", "listen": "0.0.0.0",
    "port": 18452, "cipher": "aes-128-gcm", "password": "pw", "udp": True},

"snell": {"name": "snell-01", "type": "snell", "listen": "0.0.0.0", "port": 18453,
    "psk": "pw", "version": "3"},

"_hysteria1_出站可用但不能做listener": {"name": "hysteria-01", "type": "hysteria", "listen": "0.0.0.0",
    "port": 18454, "auth-str": "pw", "protocol": "udp", "up": "10", "down": "50",
    "obfs": "plain"},
}


def probe(ln):
    cfg = {"mixed-port": 0, "mode": "rule", "listeners": [ln], "rules": ["MATCH,DIRECT"]}
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        yaml.safe_dump(cfg, fh)
        path = fh.name
    r = subprocess.run([MIHOMO, "-t", "-d", tempfile.mkdtemp(), "-f", path],
                       capture_output=True, text=True, timeout=30)
    os.unlink(path)
    return r.returncode, (r.stderr or "") + (r.stdout or "")


print(f"内核: {MIHOMO}")
print(f"{'模板':<16} {'结果':<6} 说明")
print("-" * 66)
ok, bad = [], []
for name, ln in T.items():
    rc, out = probe(ln)
    if rc == 0:
        ok.append(name); print(f"  {name:<16} {'✓':<6}")
    else:
        line = next((l for l in out.splitlines() if "error" in l.lower()), "")
        line = line.split("msg=")[-1][:58]
        bad.append(name); print(f"  {name:<16} {'✗':<6} {line}")
print(f"\n可用 {len(ok)}/{len(T)}: {', '.join(ok)}")
if bad: print(f"不可用: {', '.join(bad)}")
sys.exit(0 if not bad else 1)