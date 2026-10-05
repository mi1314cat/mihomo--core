#!/usr/bin/env python3
"""check_ports.py — 准确核对 all.sh 生成的每个端口是否真的在监听"""
import subprocess, sys, json, re

PORTS = sys.argv[1:] or ["31023","31024","31025","31026","31027","31028",
                         "31029","31030","31031","31032","31033"]
want = set(PORTS)

def snap():
    out = {}
    for proto, flag in (("tcp", "tln"), ("udp", "uln")):
        r = subprocess.run(["ss", f"-{flag}"], capture_output=True, text=True)
        for line in r.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 4:
                continue
            local = parts[3]   # ss -tln/-uln 的第 4 列都是本地地址
            m = re.search(r":(\d+)$", local)
            if not m:
                continue
            p = m.group(1)
            if p in want:
                out.setdefault(p, []).append((proto, parts[-1][:60] if len(parts) > 5 else ""))
    return out

print(f"{'端口':<8} {'协议':<6} 状态 / 持有进程")
print("-" * 70)
missing = []
for p in PORTS:
    s = snap()
    if p in s:
        for proto, who in s[p]:
            print(f"  {p:<6} {proto:<6} LISTEN  {who}")
    else:
        print(f"  {p:<6} {'-':<6} \033[31mMISSING\033[0m")
        missing.append(p)
print(f"\n监听 {len(PORTS)-len(missing)}/{len(PORTS)}")
if missing:
    print("缺失:", ", ".join(missing))