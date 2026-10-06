#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nginx_apply.py — 把面板生成的 location 片段安全地插入已有 Nginx 站点。

为什么必须这么小心
------------------
用户的 Nginx 站点已经 listen 443、配好了 ssl_certificate，还兼着正常网站业务。
新建一个同 server_name 的 server 块会让 nginx 直接起不来
(Address already in use / duplicate server name), 所以只能往**已有的
server{} 块内部**插 location。

安全措施 (每一步都可回滚)
--------------------------
1. 只在"已存在且 server_name 匹配"的 server 块内插入; 找不到就拒绝, 不猜。
2. 用标记注释包起来, 重复执行是**替换**而非追加 —— 天然幂等, 也便于手工编辑。
3. 写入前备份 (.mihomo-bak), 保留原文件权限与行尾风格。
4. 写入后自动跑 nginx -t; 不通过立即回滚并报错。
5. 找不到 nginx 部署方式 / 站点文件 / 没权限 —— 一律拒绝并说明原因。

刻意不做的事
------------
**不 reload / 不 restart nginx。** reload 会影响这台机器上的其它所有站点,
不是本面板该替用户做的决定。插入完成后把命令打给用户, 由他自己执行。

这与 参考实现 的判断一致 (cdn_menu.sh 的 "面板做什么" 一节明写
"✗ 不自动重载 nginx —— 重载会影响你的其它服务, 留给你确认后自己执行")。

用法:
    nginx_apply.py --domain <域名> --file <站点配置> [--block <片段文件>]
                   [--remove] [--nginx docker:<容器名>|systemd|none]
                   [--dry-run] [--list]
    nginx_apply.py --list                      # 列出所有候选站点配置
    nginx_apply.py --probe                     # 只探测部署方式与配置根
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

MARK = "mihomo-core-cdn"
TAG_RE = re.compile(rf"#\s*(>>>|<<<)\s*{re.escape(MARK)}.*?(\S+)\s*(>>>|<<<)\s*$")

# 已知的配置根。顺序即优先级 —— 先命中先用。
HOST_ROOTS = [
    "/etc/nginx/conf.d",
    "/etc/nginx/sites-enabled",
    "/usr/local/nginx/conf",
    "/etc/nginx/sites-available",
]


# ---------- 探测 ----------

def probe_docker():
    """找一个正在跑且挂了配置目录的 nginx 容器。

    踩过的坑的坑: 这台机器的 nginx 跑在容器里,
    宿主 /etc/nginx/sites-enabled 里有个站点文件, 但它根本不是生效配置 ——
    真正生效的挂在容器内 /etc/nginx/conf.d, 由宿主 /home/web/conf.d 挂载进去。
    只看宿主路径会得出"找到了站点"的错误结论, 然后插到没人读的文件里。
    """
    try:
        out = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}\t{{.Image}}"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        name, image = parts[0].strip(), parts[1].strip()
        if "nginx" not in image.lower() and "nginx" not in name.lower():
            continue
        # 取容器内 /etc/nginx/conf.d 的真实宿主路径
        try:
            m = subprocess.run(
                ["docker", "inspect", name, "--format",
                 "{{range .Mounts}}{{.Destination}} {{.Source}}{{\"\\n\"}}{{end}}"],
                capture_output=True, text=True, timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        for ln in m.stdout.splitlines():
            dst, _, src = ln.strip().partition(" ")
            if dst.rstrip("/").endswith("/conf.d") and src:
                return name, src.rstrip("/")
        return name, None      # 容器化但没挂 conf.d
    return None


def config_roots():
    """返回 [(模式, 路径, 校验命令模板)]，按优先级排列。"""
    roots = []
    dk = probe_docker()
    if dk:
        name, src = dk
        if src and os.path.isdir(src):
            roots.append(("docker", src, ["docker", "exec", name, "nginx", "-t"]))
            roots.append(("docker", src, ["docker", "exec", name, "nginx", "-s", "reload"]))
        else:
            print(f"[提示] 检测到容器 {name}, 但没挂出 conf.d 目录, "
                  f"无法自动定位站点", file=sys.stderr)
    for d in HOST_ROOTS:
        if os.path.isdir(d):
            roots.append(("systemd", d, ["nginx", "-t"]))
            roots.append(("systemd", d, ["nginx", "-s", "reload"]))
    return roots


def site_files():
    seen, out = set(), []
    for mode, root, _ in config_roots():
        for f in sorted(glob.glob(os.path.join(root, "*.conf"))):
            real = os.path.realpath(f)
            if real in seen:
                continue
            seen.add(real)
            out.append((mode, root, f))
    return out


def server_name_of(path):
    """取出文件里第一个 server_name 的值。

    必须锚定行首 —— proxy_ssl_server_name 这类指令里也含 "server_name"
    字样, 不锚定会把它们当成站点。
    """
    try:
        txt = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    m = re.search(r"^[ \t]*server_name[ \t]+([^;]+);", txt, re.M)
    return m.group(1).strip() if m else None


def list_sites():
    print("候选站点配置:")
    found = 0
    for mode, root, f in site_files():
        sn = server_name_of(f)
        if not sn:
            continue
        found += 1
        print(f"  {mode:8} {sn:30} {f}")
    if not found:
        print("  (没找到带 server_name 的站点配置)")
    return 0


# ---------- 插入 ----------

def find_server_block(lines, domain):
    """返回该 server{} 块在 lines 中的 [start, end) 区间 (含头尾)。

    策略: 逐个 '}' 与 '{' 配对出块, 再看块内有没有 server_name 含 domain。
    nginx 的 server 块支持嵌套 (location 里也能有 {}), 所以用深度计数,
    不能简单按第一个 } 收尾。
    """
    depth = 0
    start = None
    in_server = False
    for i, ln in enumerate(lines):
        code = strip_comment(ln)
        if start is None and re.match(r"^[ \t]*server[ \t]*\{", code):
            start = i
            depth = code.count("{") - code.count("}")
            in_server = True
            continue
        if not in_server:
            continue
        depth += code.count("{") - code.count("}")
        if depth <= 0:
            block = "\n".join(lines[start:i + 1])
            if re.search(rf"^[ \t]*server_name[ \t]+[^;]*\b{re.escape(domain)}\b",
                         block, re.M):
                return start, i + 1
            start, in_server = None, False
    return None, None


def strip_comment(line):
    """去掉行尾注释 —— 只做粗略处理, 目的是不把注释里的 { } 当结构。"""
    out, q = [], None
    for ch in line:
        if q:
            out.append(ch)
            if ch == q:
                q = None
            continue
        if ch in "\"'":
            q = ch
            out.append(ch)
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out)


def existing_span(lines, domain):
    """找出本工具上次插入的区间, 没有则返回 None。"""
    start = None
    for i, ln in enumerate(lines):
        m = TAG_RE.search(ln)
        if not m:
            continue
        kind, dom = m.group(1), m.group(2)
        if dom != domain:
            continue
        if kind == ">>>":
            start = i
        elif kind == "<<<" and start is not None:
            return start, i
    return None


def newline_style(raw):
    return "\r\n" if b"\r\n" in raw[:4096] else "\n"


def do_apply(args):
    path = args.file
    if not os.path.isfile(path):
        print(f"[错误] 站点文件不存在: {path}", file=sys.stderr)
        return 2

    domain = args.domain
    raw = open(path, "rb").read()
    nl = newline_style(raw)
    had_bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig" if had_bom else "utf-8", errors="replace")
    lines = text.splitlines()

    # 1) 先摘掉上次插入的整段 (幂等的基础)
    span = existing_span(lines, domain)
    if span:
        del lines[span[0]:span[1] + 1]
        # 摘完可能留下连续空行, 收一收
        while span[0] < len(lines) and not lines[span[0]].strip():
            del lines[span[0]]
        print(f"[信息] 已移除上次插入的 {domain} 片段 ({span[1]-span[0]+1} 行)")

    # 2) --remove 到此为止
    if args.remove:
        return commit(args, path, lines, nl, had_bom, remove_only=True)

    if not args.block:
        print("[错误] 需要 --block <片段文件>, 或用 --remove", file=sys.stderr)
        return 2
    if not os.path.isfile(args.block):
        print(f"[错误] 片段文件不存在: {args.block}", file=sys.stderr)
        return 2

    # 3) 定位目标 server 块
    start, end = find_server_block(lines, domain)
    if start is None:
        print(f"[错误] 在 {path} 里找不到 server_name 含 {domain} 的 server 块",
              file=sys.stderr)
        print("       拒绝新建 server 块 —— 你的站点已 listen 443, "
              "新建同名块会导致 nginx 起不来。", file=sys.stderr)
        print("       请确认域名拼写, 或手工把片段贴进对应的 server{} 内。",
              file=sys.stderr)
        return 3

    block = "\n".join(lines[start:end])
    if not re.search(r"^[ \t]*listen[ \t]+[^;]*\b(443|\*:\s*443)\b", block, re.M):
        print(f"[提示] server_name {domain} 的块里没看到 listen 443 —— "
              f"CDN 回源需要它, 请确认这个就是回源站点", file=sys.stderr)

    body = open(args.block, encoding="utf-8").read().rstrip().splitlines()
    # 片段本身缩进可能已经很深 (为手工粘贴准备的), 这里统一左移到 4 空格
    pad = " " * 4
    out = [
        f"{pad}# >>> {MARK} BEGIN {domain} >>>",
        f"{pad}# 由 mihomo--core 面板自动插入 (CDN 回源)。",
        f"{pad}# 删除本段请用面板, 或直接删掉这两行标记之间的内容。",
    ]
    out += [pad + b.strip() if b.strip() else "" for b in body]
    out.append(f"{pad}# <<< {MARK} END {domain} <<<")

    # 插在块的收尾 } **之前**。
    #
    # end 是开区间下标 —— lines[end-1] 才是那行收尾的 '}'。
    # 写成 lines[end:end] = out 会把片段插到 '}' 之后 (块外), 实测报:
    #   nginx: [emerg] "location" directive is not allowed here
    # 靠的正是插入后 nginx -t + 回滚把它兜住的, 但不该靠这个。
    lines[end - 1:end - 1] = out
    return commit(args, path, lines, nl, had_bom, remove_only=False)


def commit(args, path, lines, nl, had_bom, remove_only):
    payload = nl.join(lines) + nl
    data = payload.encode("utf-8")
    if had_bom:
        data = b"\xef\xbb\xbf" + data

    if args.dry_run:
        print("---- 预演, 未写入 ----")
        sys.stdout.write(payload[:4000])
        print("\n----------------")
        return 0

    # 备份 (保留权限)
    bak = path + f".{MARK}-bak"
    shutil.copy2(path, bak)

    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                                   prefix=f".{MARK}.")
        os.close(fd)
        with open(tmp, "wb") as f:
            f.write(data)
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
        tmp = None
    except OSError as e:
        print(f"[错误] 写入失败: {e}", file=sys.stderr)
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
        return 2

    # nginx -t; 不通过立刻回滚
    cmd = args.nginx
    if cmd == "none" or not cmd:
        print(f"[成功] 已{'移除' if remove_only else '插入'} (未做语法校验, --nginx none)")
        return 0

    argv = cmd.split() + ["-t"]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"[提示] 无法执行 {' '.join(argv)}: {e}", file=sys.stderr)
        print(f"[提示] 请自行确认配置无误再 reload。备份: {bak}", file=sys.stderr)
        return 0

    if p.returncode != 0:
        print("[错误] nginx -t 不通过, 已回滚:", file=sys.stderr)
        msg = (p.stderr or p.stdout or "").strip()
        for ln in msg.splitlines()[-6:]:
            print("       " + ln, file=sys.stderr)
        shutil.copy2(bak, path)
        print(f"[信息] 已还原到修改前: {path}", file=sys.stderr)
        return 4

    verb = "移除" if remove_only else "插入"
    print(f"[成功] 已{verb}到 {path}")
    print(f"[信息] 备份: {bak}")
    # 重载命令 = 校验命令去掉末尾的 -t, 换成 -s reload。
    # 别图省事切前两个词: cmd 是 "docker exec nginx nginx" 时,
    # 切前两个会拼出 "docker exec -s reload" (踩过的坑)。
    reload_argv = cmd.split()
    if reload_argv and reload_argv[-1] == "-t":
        reload_argv.pop()
    print("[提示] 现在可以自己重载 (本工具刻意不自动 reload —— "
          "reload 会影响这台机器上的其它站点):")
    print(f"       {' '.join(reload_argv + ['-s', 'reload'])}")
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--domain")
    ap.add_argument("--file")
    ap.add_argument("--block")
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--nginx", default="", help="校验命令前缀, 如 'docker exec nginx' / 'nginx' / 'none'")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--probe", action="store_true")
    args = ap.parse_args()

    if args.list:
        return list_sites()
    if args.probe:
        dk = probe_docker()
        print(f"容器化 nginx: {dk[0] if dk else '否'}"
              + (f"  conf.d 宿主路径: {dk[1]}" if dk and dk[1] else ""))
        print("配置根:")
        seen = set()
        for mode, root, chk in config_roots():
            if mode == "docker" and "reload" in chk:
                continue
            if root in seen:
                continue
            seen.add(root)
            print(f"  {mode:8} {root}   校验: {' '.join(chk)}")
        return 0
    if not args.domain or not args.file:
        ap.print_usage()
        return 2
    return do_apply(args)


if __name__ == "__main__":
    sys.exit(main())
