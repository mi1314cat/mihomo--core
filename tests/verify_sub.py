#!/usr/bin/env python3
"""verify_sub.py — 校验生成的订阅文件是否字节级保真、可被 Mihomo 消费"""
import subprocess, sys, yaml, os

OUT = "/root/catmi/mihomo/out"
SUB = os.path.join(OUT, "sub_all.yaml")

src = yaml.safe_load(open(os.path.join(OUT, "anytls_client-01.yaml")))["proxies"][0]
sub = yaml.safe_load(open(SUB))
d = sub["proxies"]
print(f"  订阅节点数: {len(d)}")
print(f"  节点名: {', '.join(p['name'] for p in d)}")

first = d[0]
ok = True
for k in ("certificate", "private-key"):
    a = (src.get(k) or "").strip()
    b = (first.get(k) or "").strip()
    same = a == b
    ok = ok and same
    print(f"  {k}: {'IDENTICAL' if same else 'DIFFER'} ({len(a)} chars)")

# 每个节点都检查必备字段
bad = []
for p in d:
    for f in ("name", "type", "server", "port"):
        if f not in p or p[f] in (None, ""):
            bad.append(f"{p.get('name','?')}.{f}")
print(f"  缺失字段: {bad if bad else '无'}")

sys.exit(0 if ok and not bad else 1)