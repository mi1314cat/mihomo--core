#!/usr/bin/env python3
"""
lan_config.py — 局域网分发配置的**唯一**生成实现

为什么单独抽出来:
    这份"合并 conf/ 下所有片段 + 剥掉本机专属段"的逻辑，原先在项目里有
    **两份独立实现**:
        lan_dispatch.sh 的 lan_gen_config()   —— 预览 (菜单 4) / 节点计数
        share_server.py 的 build_lan_config() —— 实际分发
    而两份的剥除清单**已经漂移**: build_lan_config 多剥了一个 `profile`,
    lan_gen_config 没剥。实测差异:
        实际分发版本 profile 出现 0 处
        预览版本     profile 出现 1 处
    也就是"用户在面板里预览到的，不是别的设备实际拿到的东西"。
    属于本项目反复出现的那类 bug —— 两处必须一致但无机制保证。

收敛方向 (重要):
    统一到**实际分发**那一份的行为 (剥 `profile`)。这样接收设备拿到的
    内容**一个字节都不变**，只是预览从此变准。反过来收敛会让所有接收
    设备突然多收到一个 `profile:` 段，那是行为变更，不该在这次做。

用法:
    python3 lan_config.py --root <客户端根目录> [--out <文件>]
        stdout 打印合并后的配置；--out 则写到文件
        最后一行打印节点数 (供 shell 取用)

    python3 lan_config.py --root <根目录> --count
        只打印节点数
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys

# 分发前必须剥掉的段 —— 换台机器全都对不上:
#   mixed-port / port / socks-port / redir-port / tproxy-port
#       端口是接收设备自己的事, 带过去要么冲突要么把本机代理暴露出去
#   allow-lan / bind-address
#       监听范围同理
#   external-controller / external-ui
#       本机绝对路径与端口, 那边不存在
#   secret
#       本机密钥, 传过去等于没设
#   log-level / mode
#       纯本机偏好
#   profile
#       store-selected / store-fake-ip 会把选择与缓存写进**本机配置目录**,
#       对接收设备是另一份状态 —— 原先只有实际分发剥了它, 预览没剥 (已统一)
#
# 注意: 不带尾部冒号 —— 比较的是 line.split(":", 1)[0],
#       带了就永远匹配不上, 剥除会**静默失效** (踩过的坑)。
DROP_SECTIONS = (
    "mixed-port", "port", "socks-port", "redir-port", "tproxy-port",
    "allow-lan", "bind-address", "external-controller", "external-ui",
    "secret", "log-level", "mode", "profile",
)

# 段内还要剥掉的键 —— 段本身有用 (要留着), 但这一行换台设备就是错的。
#
# ★ 为什么要有这一张表: DROP_SECTIONS 只看**顶层键**（`line[0]` 不是空格）。
#   `dns.listen` 是缩进的, 于是原样发给了别的设备 —— 实测在客户端上拉一次
#   分发地址, 拿到的就是 `listen: 0.0.0.0:1053`。后果分两种, 都不轻:
#     · 接收设备导入后, mihomo 会在**它的所有网卡**上开一个 DNS 服务。
#       这正是本项目早就在本机修掉的那个"开放解析器"问题 (见 client.sh 的
#       注释: "局域网任何人都能拿它查询, 而这些查询不经过代理") ——
#       本机修好了, 却在"分发给别人"这一环又原样送了出去;
#     · 那台设备上 1053 若已被占 (自己还跑着别的 mihomo / sing-box),
#       内核启动直接失败, 用户看到的是"导入你的配置后起不来"。
#
#   dns 段其余内容 (fake-ip / fake-ip-filter / nameserver / 策略) 都是
#   设备无关的, 必须保留 —— 所以只剥这一个键, 不是整段丢掉。
DROP_KEYS_IN_SECTION = {"dns": ("listen",)}

# 片段来源, 按这个顺序拼接 (Mihomo 的 -d 目录语义就是合并所有 yaml)
FRAGMENT_GLOBS = ("config.d/*.yaml", "providers/*.yaml")

NODE_RE = re.compile(r"^\s*-\s*name:", re.M)


def collect_fragments(confdir: str) -> str:
    merged = ""
    for pat in FRAGMENT_GLOBS:
        for f in sorted(glob.glob(os.path.join(confdir, pat))):
            try:
                with open(f, encoding="utf-8") as fh:
                    merged += fh.read() + "\n"
            except OSError as e:
                sys.stderr.write(f"跳过 {f}: {e}\n")
    return merged


def strip_local_sections(main_text: str, nested=None) -> str:
    """按行剥掉本机专属配置, 保留注释与格式。

    两种粒度:
      · 顶层段   —— 整段丢掉 (DROP_SECTIONS)
      · 段内单键 —— 只丢那一行 (DROP_KEYS_IN_SECTION, 默认就是它)

    行式而不是 YAML round-trip: 这份配置带着大量解释性注释, 而且节点片段
    是直接拼在结果后面的; 走 PyYAML 会把这些全丢掉, 还会重排键。
    """
    nested = DROP_KEYS_IN_SECTION if nested is None else nested
    kept, skip = [], False
    section = None
    child_indent = None      # 当前段直接子键的缩进 (遇到第一行子键时才确定,
                             # 所以 2 空格与 4 空格两种写法都认)
    for line in main_text.splitlines():
        head = line.split(":", 1)[0].strip() if ":" in line else ""
        # 只在本行是**顶层键**时重新判断 (缩进行属于上一个段)
        if line and not line[0].isspace() and ":" in line:
            section = head
            skip = head in DROP_SECTIONS
            child_indent = None
            if not skip:
                kept.append(line)
            continue
        if skip:
            continue                       # 整段丢掉, 连同段内空行
        want = nested.get(section or ())
        if want and line.strip() and not line.lstrip().startswith("-"):
            indent = len(line) - len(line.lstrip())
            if child_indent is None:
                child_indent = indent
            if indent == child_indent and head in want:
                continue                   # 只丢本机专属的那一行
        kept.append(line)
    return "\n".join(kept).rstrip()


def build(root: str) -> tuple[str, int]:
    """返回 (合并后的配置文本, 节点数)。"""
    confdir = os.path.join(root, "conf")
    main_path = os.path.join(confdir, "config.yaml")
    main_text = ""
    if os.path.exists(main_path):
        try:
            with open(main_path, encoding="utf-8") as fh:
                main_text = fh.read()
        except OSError as e:
            raise RuntimeError(f"读不到主配置 {main_path}: {e}") from e

    merged = collect_fragments(confdir)
    # 节点片段拼在主配置之后 —— 规则仍以主配置为准 (Mihomo 先匹配先赢)
    result = strip_local_sections(main_text) + "\n" + merged
    return result, len(NODE_RE.findall(merged))


def selftest() -> int:
    """脱敏规则自检 —— 纯字符串, 不读文件、不联网。

    为什么做成常驻自检而不是只写在测试脚本里: 这张"剥除清单"是**安全属性**
    (漏一个就是把本机的监听地址/密钥发给别人), 而它靠的是"人记得加"。
    有了它, 每次跑 tools/check_all.sh 都会重新验证一遍。
    """
    sample = """mixed-port: 7890
allow-lan: true
bind-address: '*'
external-controller: 0.0.0.0:9090
secret: deadbeef
profile:
  store-selected: true
dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-filter:
  - '*.lan'
  nameserver:
  - https://dns.alidns.com/dns-query
sniffer:
  enable: true
rules:
- MATCH,PROXY
"""
    kept = strip_local_sections(sample)
    bad = 0

    def ck(cond, what):
        nonlocal bad
        print(("  [PASS] " if cond else "  [FAIL] ") + what)
        if not cond:
            bad += 1

    ck("mixed-port" not in kept, "顶层本机键 mixed-port 被剥掉")
    ck("allow-lan" not in kept, "顶层本机键 allow-lan 被剥掉")
    ck("bind-address" not in kept, "顶层本机键 bind-address 被剥掉")
    ck("external-controller" not in kept and "secret" not in kept,
       "external-controller / secret 被剥掉")
    ck("store-selected" not in kept, "整段丢弃时连带段内内容一起丢 (profile)")
    ck("listen" not in kept, "dns.listen 被剥掉（本机监听地址, 不该发给别人）")
    ck("enable: true" in kept and "fake-ip" in kept,
       "dns 段本身保留（fake-ip 等是设备无关的）")
    ck("https://dns.alidns.com/dns-query" in kept, "dns.nameserver 保留")
    ck("*.lan" in kept, "fake-ip-filter 的列表项保留（不被误当成键）")
    ck("sniffer" in kept and "MATCH,PROXY" in kept, "其它段与规则原样保留")
    alt = "dns:\n    enable: true\n    listen: 127.0.0.1:1053\n    ipv6: false\n"
    ck("listen" not in strip_local_sections(alt),
       "4 空格缩进同样剥得掉（子键缩进按文件实际取）")
    deep = "dns:\n  nameserver-policy:\n    listen: 1.2.3.4\n  listen: 1.1.1.1\n"
    ck("listen: 1.1.1.1" not in strip_local_sections(deep)
       and "listen: 1.2.3.4" in strip_local_sections(deep),
       "只剥 dns 的直接子键, 不误伤更深层的同名键")
    print(f"\n脱敏自检: {'PASS' if bad == 0 else str(bad) + ' 项失败'}")
    return 1 if bad else 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", required=True, help="客户端根目录 (含 conf/)")
    ap.add_argument("--out", default="", help="写到文件; 不传则输出到 stdout")
    ap.add_argument("--count", action="store_true", help="只打印节点数")
    args = ap.parse_args()

    try:
        text, n = build(args.root)
    except RuntimeError as e:
        sys.stderr.write(f"{e}\n")
        return 1

    if args.count:
        print(n)
        return 0

    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(n)
    else:
        sys.stdout.write(text)
        if not text.endswith("\n"):
            sys.stdout.write("\n")
        # 契约: 输出到 stdout 时, **最后一行是节点数**。
        # 调用方 (lan_dispatch.sh) 一直用 `| tail -1` 取它、用 `head -60` 预览,
        # 这个形状必须保持 —— 换成两个子命令会让所有调用点都要改。
        print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
