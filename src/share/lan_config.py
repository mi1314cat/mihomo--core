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

# PyYAML 只在"改写组"这一步用得到 (项目里 build_sub.py / verify_sub.py 本来就
# 依赖它)。缺了也不让整个分发挂掉: 那一步会退化成原样返回。
try:
    import yaml
except ImportError:                                              # pragma: no cover
    yaml = None

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
    # proxy-providers: 每一项都是 `type: file` + `path: ./providers/<hash>.yaml`
    # —— 那是**发送端**的相对路径, 接收设备上根本不存在。实测 (真机, 把分发
    # 出来的配置直接喂给 mihomo):
    #     level=error msg="initial proxy provider <hash> error:
    #         fswatch: watch /tmp/lantest/providers no such file or directory"
    # 于是所有 `use: [<hash>]` 的组都是空的 —— 配置里明明有 17 个节点,
    # 组里一个都没有, 用户看到的是"导入成功, 但没有可用节点"。
    # 只删它还不够: 组的 `use:` 必须同时改写成具体节点名, 见 rewrite_group_use()。
    "proxy-providers",
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


def collect_fragments(confdir: str) -> tuple[str, dict]:
    """返回 (片段文本, {provider 名: [节点名…]})。

    provider 名取文件名去掉 .yaml —— 与 proxy-providers 里的键、以及
    `providers/<hash>.yaml` 的文件名三者一致 (实测: 键 = 文件名 = 组里 use 的值)。
    这份映射用来把 `use: [<provider>]` 改写成具体节点名。
    """
    merged = ""
    provider_nodes: dict[str, list] = {}
    for pat in FRAGMENT_GLOBS:
        for f in sorted(glob.glob(os.path.join(confdir, pat))):
            try:
                with open(f, encoding="utf-8") as fh:
                    body = fh.read()
            except OSError as e:
                sys.stderr.write(f"跳过 {f}: {e}\n")
                continue
            merged += body + "\n"
            if os.path.basename(os.path.dirname(f)) != "providers":
                continue
            stem = os.path.basename(f)[:-5]
            try:
                doc = yaml.safe_load(body) or {}
                names = [p.get("name") for p in (doc.get("proxies") or [])
                         if isinstance(p, dict) and p.get("name")]
            except yaml.YAMLError:
                names = []
            if names:
                provider_nodes[stem] = names
    return merged, provider_nodes


def rewrite_group_use(main_text: str, provider_nodes: dict) -> str:
    """把 `use: [<provider>]` 改写成具体节点名, 让接收设备真的有节点可用。

    为什么必须做: `proxy-providers` 被剥掉之后 (它的 path 是发送端的相对路径),
    组里的 `use:` 指向一个不存在的 provider —— 组是空的。而节点其实就在配置
    末尾的 `proxies:` 里, 只是没有任何组引用它们。

    做法: 用 PyYAML 解析主配置 → 只改 proxy-groups → 把这一段**重新 dump**
    后贴回原文 (其余部分仍是原始文本, 注释与顺序不动)。
    解析不了就原样返回, 并在 stderr 说明 —— 分发一份"组是空的"配置,
    也好过因为一个格式问题整个分发不可用。
    """
    if not provider_nodes:
        return main_text
    try:
        doc = yaml.safe_load(main_text) or {}
    except yaml.YAMLError as e:
        sys.stderr.write(f"主配置解析失败, 跳过组改写: {e}\n")
        return main_text
    groups = doc.get("proxy-groups")
    if not isinstance(groups, list) or not groups:
        return main_text

    changed = False
    for g in groups:
        if not isinstance(g, dict):
            continue
        used = g.pop("use", None)
        if not used:
            continue
        used = used if isinstance(used, list) else [used]
        names: list = []
        for prov in used:
            got = provider_nodes.get(str(prov))
            if not got:
                sys.stderr.write(f"组 {g.get('name')} 引用的 provider 没有节点: {prov}\n")
                continue
            for n in got:
                if n not in names:
                    names.append(n)
        if names:
            # 保持原有的 proxies 在前, 追加 provider 里的节点 (去重)
            rest = [x for x in (g.get("proxies") or []) if x not in names]
            g["proxies"] = rest + names
            changed = True
    if not changed:
        return main_text

    lines = main_text.splitlines()
    start = end = None
    for i, line in enumerate(lines):
        if line.startswith("proxy-groups:"):
            start = i
            continue
        # 段结束 = 下一个顶层键。**列表项不算** —— `- name: ds` 也是顶格且带
        # 冒号, 第一版按这个条件找, 于是只替换掉了 `proxy-groups:` 那一行,
        # 原来的列表留在原地, 结果组出现两次 (mihomo 直接报
        # "ProxyGroup ds: duplicate group name")。
        if start is not None and i > start and line and not line[0].isspace() \
                and ":" in line and not line.lstrip().startswith("-"):
            end = i
            break
    if start is None:
        return main_text
    if end is None:
        end = len(lines)
    dumped = yaml.safe_dump(groups, allow_unicode=True, sort_keys=False,
                            default_flow_style=False, width=4096).rstrip()
    note = ("# proxy-groups: `use: [provider]` 已展开成具体节点名 ——\n"
            "# proxy-providers 的 path 是发送端本机路径, 接收设备上没有那个文件。\n")
    # ★ dump 出来的是**列表本身**, 不带顶层键 —— 而这里替换掉的整段包含
    #   `proxy-groups:` 那一行, 所以必须把键补回来, 否则组没有键头,
    #   整段变成上一段的缩进内容 (第一次写就漏了, 输出里组直接消失)。
    block = note + "proxy-groups:\n" + dumped
    return "\n".join(lines[:start] + block.splitlines() + lines[end:])


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

    merged, provider_nodes = collect_fragments(confdir)
    kept = strip_local_sections(main_text)
    # 剥掉 proxy-providers 之后, 组里的 use 必须展开成节点名, 否则组是空的
    kept = rewrite_group_use(kept, provider_nodes)
    # 节点片段拼在主配置之后 —— 规则仍以主配置为准 (Mihomo 先匹配先赢)
    result = kept + "\n" + merged
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

    # ---- 组改写: use: [provider] → 具体节点名 ----
    # 剥掉 proxy-providers 之后, 组里 use 指向的 provider 在接收设备上不存在
    # (path 是发送端的相对路径), 实测 mihomo 直接报
    #   "initial proxy provider <hash> error: fswatch: watch .../providers no such file"
    # 于是组是空的 —— 配置里有 17 个节点, 组里一个都没有。
    if yaml is None:
        ck(False, "需要 PyYAML 才能验证组改写")
    else:
        main = ("proxy-providers:\n"
                "  prov-a:\n    type: file\n    path: ./providers/prov-a.yaml\n"
                "proxy-groups:\n"
                "- name: ds\n  type: select\n  use:\n  - prov-a\n"
                "- name: AUTO\n  type: url-test\n  use:\n  - prov-a\n"
                "rules:\n- MATCH,PROXY\n")
        kept2 = strip_local_sections(main)
        ck("proxy-providers" not in kept2, "proxy-providers 整段剥掉（path 是发送端的）")
        out = rewrite_group_use(kept2, {"prov-a": ["n1", "n2"]})
        doc = yaml.safe_load(out)
        names = [g.get("name") for g in doc["proxy-groups"]
                 if isinstance(g, dict)]
        ck(names == ["ds", "AUTO"], f"组没有重复/丢失 ({names})")
        ck(all(g.get("proxies") == ["n1", "n2"] for g in doc["proxy-groups"]),
           "use 已展开成具体节点名")
        ck(all("use" not in g for g in doc["proxy-groups"]), "use 字段已移除")
        ck(doc.get("rules") == ["MATCH,PROXY"] and "proxy-groups:" in out,
           "段尾判定正确（后面的 rules 没被吞掉, 键头还在）")
        ck(rewrite_group_use(kept2, {}) == kept2, "没有 provider 时原样返回")
        ck(rewrite_group_use("proxy-groups:\n- name: a\n  type: select\n", {"p": ["n"]})
           == "proxy-groups:\n- name: a\n  type: select\n", "没有 use 时不改动")

        # ★ 端到端（build 级）: 光验函数不够 —— 函数对但**没接上**是这里的
        #   典型 bug（本项目已经栽过好几次）。所以真造一份 conf/ 跑 build()。
        import tempfile
        tmp = tempfile.mkdtemp(prefix="lan-cfg-check-")
        try:
            os.makedirs(os.path.join(tmp, "conf", "providers"), exist_ok=True)
            with open(os.path.join(tmp, "conf", "config.yaml"), "w",
                      encoding="utf-8") as fh:
                fh.write("mixed-port: 7890\ndns:\n  enable: true\n"
                         "  listen: 0.0.0.0:1053\n"
                         "proxy-providers:\n  prov-a:\n    type: file\n"
                         "    path: ./providers/prov-a.yaml\n"
                         "proxy-groups:\n- name: ds\n  type: select\n"
                         "  use:\n  - prov-a\n"
                         "rules:\n- MATCH,PROXY\n")
            with open(os.path.join(tmp, "conf", "providers", "prov-a.yaml"), "w",
                      encoding="utf-8") as fh:
                fh.write("proxies:\n- name: n1\n  type: vless\n"
                         "- name: n2\n  type: vless\n")
            text, n = build(tmp)
            doc2 = yaml.safe_load(text)
            if not isinstance(doc2, dict):
                doc2 = {}
            ck(n == 2, f"build() 数出节点数 ({n})")
            ck("listen" not in text, "build() 输出里没有 dns.listen")
            # 断言用解析后的文档, 不用子串 —— 输出里的说明注释本身也写着
            # "proxy-providers" 这个词, 子串检查会把自己的注释当成泄漏。
            ck("proxy-providers" not in doc2,
               "build() 输出里没有 proxy-providers 段")
            groups2 = [g for g in (doc2.get("proxy-groups") or [])
                       if isinstance(g, dict)]
            ck([g.get("proxies") for g in groups2] == [["n1", "n2"]],
               "build() 真的接上了组改写（不是只有函数对）")
            ck([p.get("name") for p in (doc2.get("proxies") or [])] == ["n1", "n2"],
               "节点片段仍拼在配置里")
        finally:
            import shutil
            shutil.rmtree(tmp, ignore_errors=True)

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
