#!/usr/bin/env python3
"""
build_sub.py — 由 out/*_client-*.yaml 生成可被 Mihomo 直接消费的订阅

为什么需要它:
    各协议脚本写出的 out/<proto>_client-NN.yaml 各自带一个 `proxies:` 顶层键。
    原 export_subscription() 用 shell 拼接, 产生了:
        proxies:
            proxies:      <- 嵌套, 非法
              - ...
          vless://...      <- 裸文本混进 YAML
    该文件既不是合法 YAML, 也不是 Mihomo 能加载的订阅。

本脚本用 YAML 解析器合并, 产出一个干净的 `proxies:` 列表 —— 这正是
Mihomo 的 proxy-provider (type: http/file) 能够直接消费的格式。

用法:
    build_sub.py --out-dir /root/catmi/mihomo/out --tag all  -o sub_all.yaml
    build_sub.py --out-dir ... --tag reality -o sub_reality.yaml
    build_sub.py --out-dir ... --list
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("[ERR] 需要 PyYAML: pip3 install pyyaml", file=sys.stderr)
    sys.exit(2)

# out/<proto>_client-<NN>.yaml  →  tag = <proto>
CLIENT_RE = re.compile(r"^(?P<proto>.+?)_client-(?P<num>\d+)\.yaml$")
SKIP_PROXY_NAMES = {"DIRECT", "REJECT", "PASS", "COMPATIBLE", "GLOBAL"}

# 内嵌 PEM (mTLS 客户端证书/私钥) 必须用字面量块标量输出。
# 否则 PyYAML 会用单引号折行, 把 PEM 拆成 "空行 + 缩进" 的形式,
# 虽然合规解析器能还原, 但极易被其他工具改写坏掉 —— 私钥坏了节点就废了。
class _Dumper(yaml.SafeDumper):
    pass


def _str_representer(dumper, data):
    if isinstance(data, str) and "-----BEGIN " in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


_Dumper.add_representer(str, _str_representer)


def dump_doc(doc) -> str:
    return yaml.dump(doc, Dumper=_Dumper, sort_keys=False, allow_unicode=True,
                     default_flow_style=False, width=4096)


def collect_dir(pattern_dir: str, proto: str,
                buckets: dict[str, list[dict]]) -> None:
    """把一个目录下所有 *.yaml 里的 proxies 并入 buckets[proto]。"""
    for p in sorted(glob.glob(os.path.join(pattern_dir, "*.yaml"))):
        try:
            with open(p, "r", encoding="utf-8") as fh:
                d = yaml.safe_load(fh) or {}
        except Exception as e:  # noqa: BLE001
            print(f"[WARN] 跳过 {os.path.basename(p)}: {e}", file=sys.stderr)
            continue
        if not isinstance(d, dict) or not isinstance(d.get("proxies"), list):
            continue
        for item in d["proxies"]:
            if not isinstance(item, dict):
                continue
            if item.get("name") in SKIP_PROXY_NAMES:
                continue
            if not item.get("name") or not item.get("type"):
                continue
            if "server" not in item or "port" not in item:
                continue
            buckets.setdefault(proto, [])
            buckets[proto] = [x for x in buckets[proto]
                              if x.get("name") != item["name"]]
            buckets[proto].append(item)


def collect(out_dir: str) -> dict[str, list[dict]]:
    """返回 {proto: [proxy,...]}，同名节点后者覆盖前者。"""
    buckets: dict[str, list[dict]] = {}
    for p in sorted(glob.glob(os.path.join(out_dir, "*_client-*.yaml"))):
        base = os.path.basename(p)
        m = CLIENT_RE.match(base)
        if not m:
            continue
        proto = m.group("proto")
        try:
            with open(p, "r", encoding="utf-8") as fh:
                d = yaml.safe_load(fh) or {}
        except Exception as e:  # noqa: BLE001
            print(f"[WARN] 跳过 {base}: {e}", file=sys.stderr)
            continue
        if not isinstance(d, dict):
            continue
        lst = d.get("proxies")
        if not isinstance(lst, list):
            continue
        for item in lst:
            if not isinstance(item, dict):
                continue
            if item.get("name") in SKIP_PROXY_NAMES:
                continue
            # 缺少必要字段的半成品直接丢, 不让坏节点进订阅
            if not item.get("name") or not item.get("type"):
                continue
            if "server" not in item or "port" not in item:
                continue
            buckets.setdefault(proto, [])
            buckets[proto] = [x for x in buckets[proto]
                              if x.get("name") != item["name"]]
            buckets[proto].append(item)
    return buckets


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--import-dir", default="", help="外部拉取的订阅目录 (合并为 imported)")
    ap.add_argument("--tag", default="all", help="all 或某个协议前缀 (reality/trojan/...)")
    ap.add_argument("-o", "--output", default="")
    ap.add_argument("--list", action="store_true", help="只列出可用 tag")
    args = ap.parse_args()

    buckets = collect(args.out_dir)
    if args.import_dir and os.path.isdir(args.import_dir):
        collect_dir(args.import_dir, "imported", buckets)

    if args.list:
        if not buckets:
            print("(尚无任何节点)")
            return 0
        total = 0
        for proto in sorted(buckets):
            n = len(buckets[proto])
            total += n
            print(f"  {proto:<12} {n} 个")
        print(f"  {'合计':<12} {total} 个")
        return 0

    if args.tag == "all":
        proxies = [x for proto in sorted(buckets) for x in buckets[proto]]
    else:
        proxies = buckets.get(args.tag, [])
        if not proxies:
            print(f"[ERR] 没有 tag=`{args.tag}` 的节点", file=sys.stderr)
            return 1

    if not proxies:
        print("[ERR] 没有任何可用节点 (out/*_client-*.yaml 为空?)", file=sys.stderr)
        return 1

    doc = {"proxies": proxies}

    if not args.output:
        sys.stdout.write(dump_doc(doc))
        return 0

    tmp = args.output + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(f"# mihomo--core 自动生成的订阅 ({args.tag})\n")
        fh.write(f"# 共 {len(proxies)} 个节点, 可直接作为 proxy-provider 使用\n")
        fh.write(dump_doc(doc))
    os.replace(tmp, args.output)
    print(f"[OK] 已生成 {args.output} ({len(proxies)} 个节点)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())