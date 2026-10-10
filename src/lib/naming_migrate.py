#!/usr/bin/env python3
"""给**已有**节点的产物补上地区旗帜。

新生成的节点已经带旗帜了（见 src/lib/naming.py 与 env.sh 的 m_node_tag），
但在这之前生成的节点名已经写进产物文件，不会自己变。用户看到的就是
"面板上写着带旗帜，我客户端里还是没有"。

这里只重写**客户端产物**（out/*_client-*.yaml 的 name、out/*_share-*.txt 的
# 片段）—— 与服务端的 conf/config.d/ 无关: 那里是监听配置, 名字只是内部标签,
旗子是给人看的, 不该为了显示去动服务端配置（那要重载, 平白多一次风险）。

幂等: 已经有旗帜的名字原样保留。

用法:
    naming_migrate.py --out <out 目录> [--apply]
    不带 --apply 只报告要改什么（默认 dry-run）
    naming_migrate.py --selftest
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import naming
except ImportError:                                              # pragma: no cover
    naming = None

CLIENT_RE = re.compile(r"^(?P<pre>[ \t]*-[ \t]*name:[ \t]*)(?P<name>.+?)[ \t]*$")
# 分享链接里的显示名 = 最后一个 # 之后的部分（fragment，可能被 urlencode 过）
SHARE_RE = re.compile(r"^(?P<pre>.*#)(?P<name>[^#]*)$")


def _flag(name: str) -> str:
    if naming is None:
        return name
    return naming.ensure_flag(name)


def scan_client(path: str) -> list[tuple[int, str, str]]:
    """返回 [(行号, 旧名, 新名)]，只含需要改的。"""
    out = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for i, line in enumerate(lines, 1):
        m = CLIENT_RE.match(line)
        if not m:
            continue
        old = m.group("name").strip().strip('"').strip("'")
        new = _flag(old)
        if new != old:
            out.append((i, old, new))
    return out


def scan_share(path: str) -> list[tuple[int, str, str]]:
    out = []
    try:
        raw = open(path, encoding="utf-8").read()
    except OSError:
        return out
    for i, line in enumerate(raw.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue                      # 以 # 开头的是注释行, 不是链接
        m = SHARE_RE.match(line)
        if not m or not m.group("name"):
            continue
        old = m.group("name").strip()
        new = _flag(old)
        if new != old:
            out.append((i, old, new))
    return out


def _rewrite_line(line: str, old: str, new: str, kind: str) -> str:
    if kind == "client":
        m = CLIENT_RE.match(line)
        if not m:
            return line
        return m.group("pre") + new
    m = SHARE_RE.match(line)
    if not m:
        return line
    return m.group("pre") + new


def run(out_dir: str, apply: bool = False) -> int:
    files: list[tuple[str, str]] = []
    for f in sorted(glob.glob(os.path.join(out_dir, "*_client-*.yaml"))):
        files.append((f, "client"))
    for f in sorted(glob.glob(os.path.join(out_dir, "*_share-*.txt"))):
        files.append((f, "share"))

    total = 0
    for path, kind in files:
        changes = scan_client(path) if kind == "client" else scan_share(path)
        if not changes:
            continue
        total += len(changes)
        for _ln, old, new in changes:
            print("  %s: %s  ->  %s" % (os.path.basename(path), old, new))
        if not apply:
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for _ln, old, new in changes:
            for i, line in enumerate(lines):
                if kind == "client":
                    m = CLIENT_RE.match(line)
                    if m and m.group("name").strip().strip('"').strip("'") == old:
                        lines[i] = _rewrite_line(line, old, new, kind)
                        break
                else:
                    m = SHARE_RE.match(line)
                    if m and m.group("name").strip() == old:
                        lines[i] = _rewrite_line(line, old, new, kind)
                        break
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        os.replace(tmp, path)
    print(total)
    return 0


def selftest() -> int:
    import shutil
    import tempfile
    bad = 0

    def ck(cond, what):
        nonlocal bad
        print(("  [PASS] " if cond else "  [FAIL] ") + what)
        if not cond:
            bad += 1

    tmp = tempfile.mkdtemp(prefix="naming-migrate-")
    old_cache = naming.FLAG_CACHE if naming else None
    try:
        if naming is not None:
            naming.FLAG_CACHE = os.path.join(tmp, "flag")
            naming._write(naming.FLAG_CACHE, "\U0001F1FA\U0001F1F8")     # 🇺🇸
        cy = os.path.join(tmp, "anytls_client-01.yaml")
        sh = os.path.join(tmp, "anytls_share-01.txt")
        open(cy, "w", encoding="utf-8").write(
            "proxies:\n  - name: mAnyTLS01-TLS\n    type: anytls\n"
            "  - name: \U0001F1FA\U0001F1F8 mAnyTLS02-TLS\n    type: anytls\n")
        open(sh, "w", encoding="utf-8").write(
            "anytls://pw@1.2.3.4:443?sni=a.com#mAnyTLS01-TLS\n"
            "anytls://pw@1.2.3.4:443?sni=a.com#\U0001F1FA\U0001F1F8%20mAnyTLS02-TLS\n")
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = run(tmp, apply=True)
        txt = open(cy, encoding="utf-8").read()
        ck(rc == 0, "迁移返回 0")
        ck("- name: \U0001F1FA\U0001F1F8 mAnyTLS01-TLS" in txt, "客户端产物补上旗帜")
        ck(txt.count("mAnyTLS02-TLS") == 1 and "\U0001F1FA\U0001F1F8 mAnyTLS02-TLS" in txt,
           "已带旗帜的原样保留")
        shs = open(sh, encoding="utf-8").read()
        ck("#\U0001F1FA\U0001F1F8 mAnyTLS01-TLS" in shs, "分享链接 fragment 补上旗帜")
        # 幂等: 再跑一次不该有任何改动
        buf2 = io.StringIO()
        with contextlib.redirect_stdout(buf2):
            run(tmp, apply=True)
        ck(buf2.getvalue().strip() == "0", "第二次运行 0 处改动（幂等）")
    finally:
        if naming is not None and old_cache:
            naming.FLAG_CACHE = old_cache
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n迁移自检: {'PASS' if bad == 0 else str(bad) + ' 项失败'}")
    return 1 if bad else 0


def main(argv) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--out", default="", help="产物目录 (out/)")
    ap.add_argument("--apply", action="store_true", help="真的写回（默认只报告）")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv[1:])
    if a.selftest:
        return selftest()
    if not a.out:
        ap.print_help()
        return 2
    return run(a.out, apply=a.apply)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
