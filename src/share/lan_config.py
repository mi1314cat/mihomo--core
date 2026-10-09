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


def strip_local_sections(main_text: str) -> str:
    kept, skip = [], False
    for line in main_text.splitlines():
        # 只在本行是**顶层键**时重新判断 (缩进行属于上一个段)
        if line and not line[0].isspace() and ":" in line:
            skip = line.split(":", 1)[0].strip() in DROP_SECTIONS
        if not skip:
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


def main() -> int:
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
