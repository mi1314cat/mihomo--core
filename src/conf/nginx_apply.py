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

关于重载
--------
**配置过了 nginx -t 就直接 reload。** 改了不重载等于没改:

  插入方向 —— 片段写进文件了但 nginx 还跑着旧配置, 节点照样连不上,
              用户看到的是"配好了但用不了", 且没有任何报错;
  移除方向 —— 旧规则仍在生效, 等于没删。

nginx 的 reload 是平滑的 (不断开现有连接), 所以"会影响其它服务"这个
顾虑不成立。

这与 参考实现 的**实际代码**一致 —— cdn_menu.sh:254 (插入后) 和
:315 (移除后) 都调 cdn_nginx_reload, 它自己在 cdn_nginx.sh:53 起的注释
写的是 "插入成功但没重载 = 配置没生效, 节点照样连不上"。

⚠ 注意 SB 的帮助文本 cdn_menu.sh:348 写着 "✗ 不自动重载 nginx" ——
   与它自己第 254/315 行调用的代码直接矛盾。那是陈旧说法, 以代码为准。

用法:
    nginx_apply.py --domain <域名> --file <站点配置> [--block <片段文件>]
                   [--remove] [--nginx docker exec <容器> nginx|nginx|none]
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

# server{} 指令段用的是 `===` 而不是 `>>>`, 是**另一套标记**。
# ⚠ 早先这里让 existing_dirs_span 复用 TAG_RE, 而 TAG_RE 只认 >>>/<<<,
#   于是 kind 永远取不到 "===", 整段代码是死的 —— 后果是删掉全部节点后,
#   站点里那段 `client_max_body_size 100m` 之类的补入指令会永远留着。
DIRS_RE = re.compile(
    rf"#\s*===\s*{re.escape(MARK)}\s+(BEGIN|END)\s+(\S+?)\s*(?:\(server 指令\))?\s*===\s*$")

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


def list_sites(paths_only=False):
    if paths_only:
        # 机器可读: 每行一个站点配置**路径**, 没有表头、没有对齐列。
        #
        # ★ 为什么必须有这个开关:
        #   list_sites() 的表给人看, 格式是 "  {mode:8} {sn:30} {f}" —— **空格分隔**。
        #   而调用方 cdn_site_files_all() 用的是 `awk -F'|' '{...$2...}'`, 即按
        #   **竖线**分隔取第 2 列。输出里根本没有竖线, 所以它**永远返回空**,
        #   于是 cdn.sh 的"幽灵配置"自检循环一次都不执行, 恒打印
        #   "没有幽灵配置" —— 一个查不到东西就报成功的假绿灯。
        #   根因与 share_create 的 `awk 'NF==2'` 完全同类: 生产者和消费者
        #   对格式的理解不一致, 而没有任何机制保证它们一致。
        for mode, root, f in site_files():
            if not server_name_of(f):
                continue
            print(f)
        return 0
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


def existing_dirs_span(lines, domain):
    """找出本工具上次**自动补入的 server{} 指令段**, 没有则返回 None。"""
    start = None
    for i, ln in enumerate(lines):
        m = DIRS_RE.search(ln)
        if not m:
            continue
        kind, dom = m.group(1), m.group(2)
        if dom != domain:
            continue
        if kind == "BEGIN":
            start = i
        elif kind == "END" and start is not None:
            return start, i
    return None


def newline_style(raw):
    return "\r\n" if b"\r\n" in raw[:4096] else "\n"


# ★ CDN 回源必须在 server{} 层生效、而**不能**写在 location{} 里的三个指令。
#
#   client_max_body_size 0      默认 1m。xhttp/ws 上行远超 1m -> nginx 直接 413,
#                               客户端表现为「握手成功、一传数据就断」, 极易误判成
#                               节点坏了或证书有问题。
#   proxy_request_buffering off 默认 on。xhttp 是流式上行, 被 nginx 整个缓冲住
#                               不转发 -> 连接建立但永远不通 (xhttp 过 nginx 最经典的坑)。
#   proxy_buffering off         默认 on。响应侧同理, 长连接流式被攒批, 延迟飙升。
#
# 以前这三条只**打印警告**, 让用户自己手工加 —— 于是「面板显示 CDN 已配好、
# 节点就是不 통」成为最高频的反馈。location 里写它们无效, 只能进 server{}。
# 现在自动补进目标 server{}, 并同样包在标记里以便回收。
SERVER_DIRS = (
    ("client_max_body_size", "client_max_body_size 0;", "0"),
    ("proxy_request_buffering", "proxy_request_buffering off;", "off"),
    ("proxy_buffering", "proxy_buffering off;", "off"),
)


def server_missing_dirs(lines, start, end):
    """目标 server{} 块内缺哪几个必需指令 (返回指令正文列表)。"""
    blk = "\n".join(lines[start:end])
    miss = []
    for _, stmt, val in SERVER_DIRS:
        name = stmt.split()[0]
        # 块内已出现同名指令 (不管值是什么) 就算有 —— 不能覆盖用户的显式设置
        if re.search(rf"^[ \t]*{re.escape(name)}[ \t]+[^;]+;", blk, re.M):
            continue
        miss.append(stmt)
    return miss


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

    # 0) 先看本次要删的是不是「上次插入的 location 段」或「上次插入的指令段」。
    #    --remove 时两段都要摘, 否则补进去的 server{} 指令会变成孤儿留在站点里。
    old_span = existing_span(lines, domain)
    old_dirs = existing_dirs_span(lines, domain)

    # 1) 先摘掉上次插入的整段 (幂等的基础)
    span = old_span
    if span:
        del lines[span[0]:span[1] + 1]
        # 摘完可能留下连续空行, 收一收
        while span[0] < len(lines) and not lines[span[0]].strip():
            del lines[span[0]]
        print(f"[信息] 已移除上次插入的 {domain} 片段 ({span[1]-span[0]+1} 行)")

    if old_dirs:
        s2, e2 = old_dirs
        del lines[s2:e2 + 1]
        while s2 < len(lines) and not lines[s2].strip():
            del lines[s2]
        print(f"[信息] 已移除上次自动补入的 server 级指令 ({e2-s2+1} 行)")
        old_dirs = None

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
        print(f"       请确认域名拼写, 或手工把片段贴进对应的 server{{}} 内。", file=sys.stderr)
        print(f"       提示: 先看本机已有站点 —— {args.file} 所在目录里, "
              f"哪些文件的 server_name 是你的域名。", file=sys.stderr)
        for cand, _, _ in config_roots():
            try:
                names = [server_name_of(f) for f in sorted(glob.glob(os.path.join(cand, "*.conf")))]
            except OSError:
                continue
            hit = [n for n in names if n and n != "_"]
            if hit:
                print(f"       本机 {cand} 下有: {', '.join(hit)}", file=sys.stderr)
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
    # 保留片段内部的相对缩进: 先按最小缩进统一左移, 再整体加 pad。
    # 原先写的是 pad + b.strip(), 会把所有层级压平到同一缩进 ——
    # nginx 不敏感所以不影响功能, 但读起来是错的 (location 的
    # proxy_pass 与 location 本身同缩进), 排查时容易看错层级。
    _ne = [b for b in body if b.strip()]
    _base = min((len(b) - len(b.lstrip()) for b in _ne), default=0)
    out += [(pad + b[_base:]) if b.strip() else "" for b in body]
    out.append(f"{pad}# <<< {MARK} END {domain} <<<")

    # 插在块的收尾 } **之前**。
    #
    # end 是开区间下标 —— lines[end-1] 才是那行收尾的 '}'。
    # 写成 lines[end:end] = out 会把片段插到 '}' 之后 (块外), 实测报:
    #   nginx: [emerg] "location" directive is not allowed here
    # 靠的正是插入后 nginx -t + 回滚把它兜住的, 但不该靠这个。
    lines[end - 1:end - 1] = out

    # ---- ② 自动补 server{} 层的三个必需指令 (2026-10-07 新增) ----
    #
    # 补在 location 段**之前**, 同样用标记包起来; --remove / 下次重渲染时
    # 会连同 location 段一起摘掉, 不留孤儿。位置在 server{} 块的开头,
    # 便于人工一眼看到「这几行是面板加的」。
    #
    # 不覆盖已有同名指令: 用户自己写了 client_max_body_size 100m 就尊重它,
    # 绝不擅自改 —— 面板只负责补「完全没有」的。
    miss = server_missing_dirs(lines, start, end + len(out) - 1)
    if miss:
        dpad = "    "
        dout = [
            f"{dpad}# === {MARK} BEGIN {domain} (server 指令) ===",
            f"{dpad}# 由 mihomo--core 面板自动补入 —— CDN 回源必需, 删除会让 xhttp 413/不通",
            f"{dpad}# 位置必须是 server{{}} 或 http{{}} 层, 写在 location 里无效",
        ]
        dout += [f"{dpad}{s}" for s in miss]
        dout.append(f"{dpad}# === {MARK} END {domain} (server 指令) ===")
        # 插到 server 块开头的 '{' 之后 (start+1)
        lines[start + 1:start + 1] = dout
        print(f"[信息] 已自动补入 {len(miss)} 条 server 级指令: "
              f"{', '.join(s.split()[0] for s in miss)}")

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
        # 没检测到可用的 nginx (面板/容器/宿主都没找着), 写完只能靠用户自己
        # reload。这里不做校验也不做重载 —— 硬跑一条必然失败的命令没意义。
        verb = "移除" if remove_only else "插入"
        print(f"[成功] 已{verb} (未检测到可用的 nginx, 跳过校验与重载)")
        print("[提示] 配置已写入文件, 需你自己重载才生效:")
        print("[提示]   docker exec <容器> nginx -s reload   (Docker 部署)")
        print("[提示]   systemctl reload nginx                (宿主部署)")
        print(f"[信息] 备份: {bak}")
        return 0

    argv = cmd.split() + ["-t"]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        # 连校验都跑不了 —— 绝不能在这时候盲重载
        print(f"[提示] 无法执行校验 ({' '.join(argv)}: {e})", file=sys.stderr)
        print("[提示] 配置已写入但**未校验**, 请自己确认后再重载:", file=sys.stderr)
        print(f"[提示]   {' '.join(argv[:-1] + ['-s', 'reload'])}", file=sys.stderr)
        print(f"[提示] 备份: {bak}", file=sys.stderr)
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
    return do_reload(cmd, bak)


def do_reload(cmd, bak):
    """配置过了 nginx -t 就重载 —— 改了不重载等于没改。

    插入方向: 片段写进文件了但 nginx 还跑着旧配置, 节点照样连不上,
              用户看到的是"配好了但用不了", 且没有任何报错。
    移除方向: 旧规则仍在生效, 等于没删。

    reload 本身是平滑的 (不断开现有连接), 所以这里的顾虑不成立。
    这与 参考实现 的实际代码一致 —— cdn_menu.sh:254 (插入后) 和
    :315 (移除后) 都调 cdn_nginx_reload, 它自己 cdn_nginx.sh:53 起的
    注释写的是 "插入成功但没重载 = 配置没生效, 节点照样连不上"。

    ⚠ cdn_menu.sh 的帮助文本里 "✗ 不自动重载 nginx" 与它自己调用的代码
    是矛盾的 —— 那段是陈旧说法, 以代码为准 (SB 内部注释与实现不一致)。

    reload 失败不回滚文件: 配置已经通过 nginx -t, 留着比撤掉有用。
    只提示手工命令。
    """
    # 重载命令 = 校验命令去掉末尾的 -t, 换成 -s reload。
    # 别图省事切前两个词: cmd 是 "docker exec nginx nginx" 时,
    # 切前两个会拼出 "docker exec -s reload" (踩过的坑)。
    argv = cmd.split()
    if argv and argv[-1] == "-t":
        argv.pop()
    reload_argv = argv + ["-s", "reload"]
    pretty = " ".join(reload_argv)

    try:
        p = subprocess.run(reload_argv, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"[提示] 无法执行重载 ({e})", file=sys.stderr)
        print(f"[提示] 配置已写入且通过校验, 请自己执行: {pretty}", file=sys.stderr)
        print(f"[提示] 备份: {bak}", file=sys.stderr)
        return 0

    if p.returncode == 0:
        print(f"[成功] 已重载 nginx: {pretty}")
        return 0

    msg = (p.stderr or p.stdout or "").strip()
    print(f"[提示] 重载未成功, 但配置已写入且通过了 nginx -t。", file=sys.stderr)
    if msg:
        for ln in msg.splitlines()[-3:]:
            print("       " + ln, file=sys.stderr)
    print(f"[提示] 请手工执行: {pretty}", file=sys.stderr)
    print(f"[提示] 备份: {bak}", file=sys.stderr)
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
    ap.add_argument("--list-paths", action="store_true",
                    help="只列出站点配置路径, 每行一个 (给脚本用)")
    ap.add_argument("--probe", action="store_true")
    args = ap.parse_args()

    if args.list:
        return list_sites()
    if args.list_paths:
        return list_sites(paths_only=True)
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
