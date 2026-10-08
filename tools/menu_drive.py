#!/usr/bin/env python3
"""按提示语驱动交互菜单 —— 等提示真的出现再应答, 不靠 sleep 猜时序。

用法: menu_drive.py <日志文件> <<'RULES'
<等待出现的文字> <应答>
...
RULES

每行规则是"看到什么"与"回什么"。应答里 \n 表示回车, \t 表示制表符。
没匹配到任何规则的提示会原样记进日志, 方便事后核对到底问了什么。
"""
import os
import re
import select
import subprocess
import sys
import time

RULES = []
for line in sys.stdin.read().splitlines():
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    parts = line.split("\t", 1)
    if len(parts) == 2:
        pat, ans = parts
    else:
        pat, ans = parts[0], ""
    RULES.append((pat, ans.replace("\\n", "\n").replace("\\t", "\t")))

log_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/menu_drive.log"
raw = open(log_path, "wb")

# setsid + PTY: 菜单靠 isatty 决定彩色与清屏, 管道会走另一条分支
master, slave = os.openpty()
proc = subprocess.Popen(
    ["bash", "src/server.sh"],
    stdin=slave, stdout=slave, stderr=slave,
    preexec_fn=os.setsid, cwd="/root/catmi/mihomo",
    env={**os.environ, "TERM": "xterm-256color"},
)
os.close(slave)

buf = ""
used = [False] * len(RULES)
deadline = time.time() + 900
raw.write(b"=== menu_drive start ===\n")
raw.flush()

while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 1.0)
    if r:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        raw.write(chunk)
        raw.flush()
        buf += chunk.decode("utf-8", "replace")
        buf = buf[-20000:]

    # 逐条检查未命中的规则; 取**最后**命中的一条, 这样同一段文字里
    # 后面的提示优先 (菜单常把上一个问题的答案回显在同一屏里)
    plain = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", buf)
    plain = plain.replace("\r", "")
    hit = -1
    for i, (pat, _) in enumerate(RULES):
        if used[i]:
            continue
        if pat in plain:
            hit = i
    if hit >= 0:
        used[hit] = True
        ans = RULES[hit][1]
        os.write(master, (ans + "\n").encode())
        time.sleep(0.6)
        buf = ""

    if all(used) and not RULES:
        break

time.sleep(1)
try:
    os.killpg(os.getpgid(proc.pid), 15)
except OSError:
    pass
raw.write(b"\n=== menu_drive end ===\n")
raw.close()
print("DRIVER DONE")
