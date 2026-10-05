#!/usr/bin/env python3
"""
envtool.py — install_info.env 的读写工具

设计要点:
  * 文件格式固定为 KEY="VALUE", 只接受 [A-Za-z_][A-Za-z0-9_]* 作为键
  * **从不 source / eval**, 因此不可能执行任意代码
  * 写入走 flock 串行化 + 临时文件原子替换, 保留原权限
  * 转义/反转义集中在这里, 避免 bash 的 ${v//...} 陷阱

子命令:
  set  <file> <key> <value>
  get  <file> <key>
  load <file>            # 输出 key<TAB>value, 供 bash 以 IFS=$'\t' 读取
"""
from __future__ import annotations

import os
import re
import sys
import tempfile

LINE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)="(.*)"$')
KEY_OK = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')


def esc(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")


def unesc(v: str) -> str:
    # 反转义必须与 esc 逆序
    out, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v) and v[i + 1] in ('\\', '"', "$"):
            out.append(v[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def read_lines(path: str) -> list[str]:
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def cmd_set(path: str, key: str, value: str) -> int:
    if not KEY_OK.match(key):
        print(f"[ERR] 非法键名: {key}", file=sys.stderr)
        return 1
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    if not os.path.exists(path):
        open(path, "a", encoding="utf-8").close()

    fd = os.open(path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX)
        lines = [l for l in read_lines(path) if not l.startswith(key + "=")]
        lines.append(f'{key}="{esc(value)}"')
        mode = os.stat(path).st_mode & 0o7777
        tfd, tmp = tempfile.mkstemp(dir=d, prefix=".env.")
        os.close(tfd)
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        os.close(fd)
    return 0


def cmd_get(path: str, key: str) -> int:
    for l in read_lines(path):
        m = LINE.match(l)
        if m and m.group(1) == key:
            sys.stdout.write(unesc(m.group(2)) + "\n")
            return 0
    return 1


def cmd_load(path: str) -> int:
    out = sys.stdout
    for l in read_lines(path):
        m = LINE.match(l)
        if not m:
            continue
        v = unesc(m.group(2)).replace("\t", " ").replace("\n", " ").replace("\r", " ")
        out.write(f"{m.group(1)}\t{v}\n")
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "set" and len(sys.argv) == 5:
        return cmd_set(path, sys.argv[3], sys.argv[4])
    if cmd == "get" and len(sys.argv) == 4:
        return cmd_get(path, sys.argv[3])
    if cmd == "load" and len(sys.argv) == 3:
        return cmd_load(path)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())