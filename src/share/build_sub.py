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
import json
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("[ERR] 需要 PyYAML: pip3 install pyyaml", file=sys.stderr)
    sys.exit(2)

# 节点名的旗帜规则只有一份实现 (src/lib/naming.py)。这里按路径引入它,
# 而不是另抄一个正则 —— 抄一份就是第二个真源, 迟早漂移。
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                os.pardir, "lib"))
try:
    import naming
except ImportError:                                              # pragma: no cover
    naming = None

# out/<proto>_client-<NN>.yaml  →  tag = <proto>
CLIENT_RE = re.compile(r"^(?P<proto>.+?)_client-(?P<num>\d+)\.yaml$")
SKIP_PROXY_NAMES = {"DIRECT", "REJECT", "PASS", "COMPATIBLE", "GLOBAL"}

# naming.py 找不到时的兜底 (独立复制出来的 build_sub.py)。规则必须与
# naming.py 的 FLAG_RE 逐字一致 —— check_all.sh 的分享产物闸门会同时跑
# 两条路径, 不一致就报红。
_FLAG_RE = re.compile("[\U0001F1E6-\U0001F1FF]{2}")


def node_key(name: str) -> str:
    """节点**身份键**: 去掉地区旗帜后比较。

    为什么不能直接比字符串 (2026-10-10 修, 分享订阅生成 100% 失败):
        旗帜是服务器的**显示属性**, 于是同一个节点有两个写法 ——
            conf/config.d/.managed.json : "mAnyTLS01-TLS"      (裸名, 台账)
            out/*_client-*.yaml         : "🇺🇸 mAnyTLS01-TLS"  (产物, 给人看)
        原来按等值比较, 交集 0/19 → 19 个**活节点**全被判成"陈旧产物"剔除,
        build_sub 报"没有任何可用节点", 面板"生成分享内容失败"。

    红线: **不许为了让匹配成功而把旗帜从名字里去掉** (旗帜是用户可见特性)。
    两侧都过一遍本函数即可, 显示名一个字节都不动。
    """
    if naming is not None:
        return naming.match_key(name)
    return " ".join(_FLAG_RE.sub("", str(name or "")).split())

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
            # ★ 内核一定用不了的产物在这里拒收 (原因逐条打出来, 不静默丢)。
            #   必须在**去重之前**: 否则坏产物会先把同名好产物覆盖掉。
            _why = bad_product_reason(item)
            if _why:
                print(f"[拒收] {os.path.basename(p)}: {item.get('name', '?')} —— {_why}",
                      file=sys.stderr)
                continue
            buckets.setdefault(proto, [])
            buckets[proto] = [x for x in buckets[proto]
                              if x.get("name") != item["name"]]
            buckets[proto].append(item)


# 「看着是产物、其实内核一定用不了」的条目 —— 必须**在收集这一层**挡掉。
#
# 真机来由 (2026-10-11, RN): 单协议面板的「重建客户端文件」对 all.sh 批量生成的
# 节点会**按字段位置**取值 (`grep -E "uuid:" … | awk '{print $2}'`), 遇上列表形态
# (`    - uuid: xxx`) 就错位 —— 产出 server/sni = **证书文件名** 的产物, 或
# reality-opts.public-key 为空的产物。要命的是这些产物**文件名排序在前**, 于是在
# "同名节点后者覆盖前者"的去重里**压过**了原来那份好的。实测 payload 里
# mVLESS01-REALITY 丢了 pbk、mTUIC01-TLS 的 sni 变成 `fullchain.pem`。
#
# 修法不是在 11 个协议脚本里逐个改解析 (那是另一件事), 而是让**收集端拒收**:
# 坏产物进不了两条产品 (build_sub / build_uri 共用 collect), 好产物自然赢;
# 每一条都**说出原因**(不静默丢), 而被拒的产物仍留在 out/ 里可查。
_CERT_FILE_RE = re.compile(r"\.(pem|crt|cer|key)$", re.IGNORECASE)


def bad_product_reason(item: dict) -> str:
    """内核一定用不了的产物 → 返回原因; 没问题返回空串。"""
    for field in ("server", "sni", "servername"):
        v = str(item.get(field) or "").strip()
        if v and "/" not in v and _CERT_FILE_RE.search(v):
            return f"{field} 是证书文件名 ({v}) —— 字段位置解析错位的典型症状"
    if "reality-opts" in item:
        ro = item.get("reality-opts")
        if not isinstance(ro, dict) or not str(ro.get("public-key") or "").strip():
            return "reality 节点缺 public-key —— 只按裸 TLS 拨号, 必然连不通"
    return ""


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
            # ★ 内核一定用不了的产物在这里拒收 (原因逐条打出来, 不静默丢)。
            #   必须在**去重之前**: 否则坏产物会先把同名好产物覆盖掉。
            _why = bad_product_reason(item)
            if _why:
                print(f"[拒收] {os.path.basename(p)}: {item.get('name', '?')} —— {_why}",
                      file=sys.stderr)
                continue
            buckets.setdefault(proto, [])
            buckets[proto] = [x for x in buckets[proto]
                              if x.get("name") != item["name"]]
            buckets[proto].append(item)
    return buckets


def live_node_names(frag_dir: str) -> set[str] | None:
    """读 conf/config.d/.managed.json —— 当前**真实在跑**的 listener 名单。

    .managed.json 由 merge.py 维护, 是「哪些节点还活着」的唯一真源: 节点被
    删掉时它的名字会从这份名单里消失, 而 out/ 里的客户端产物**不会**跟着删。
    """
    p = os.path.join(frag_dir, ".managed.json")
    try:
        with open(p, "r", encoding="utf-8") as fh:
            names = json.load(fh)
        if isinstance(names, list):
            return {str(x) for x in names if isinstance(x, (str, int))}
    except (OSError, ValueError):
        return None
    return None


def build_buckets(out_dir: str, conf_dir: str = "", import_dir: str = "",
                  providers_dir: str = "") -> dict[str, list[dict]]:
    """收集 + **过滤陈旧产物** → {proto: [proxy,...]}。

    ★ 这段逻辑从 main() 里提出来, 是因为它现在有**两个**消费者:
        build_sub.py   → mihomo YAML 产品 (原生)
        build_uri.py   → URI 列表产品     (普通话)
      两条产品必须发布**同一个节点集合**(设计: proxy-node-compat/docs/
      three-way-interop.md §5 —— "两条产品给不同的人, 发布的节点却不一样,
      是最难查的一类错")。各写一份收集/过滤逻辑 = 必然漂移, 所以只有一处。
    """
    buckets = collect(out_dir)

    # ★ 过滤陈旧产物 (2026-10-07 新增)
    #
    # out/ 是**累积目录**: --force 重建 / 删节点时旧的 *_client-*.yaml 不会
    # 被删 (它们可能已被用户复制走)。而 collect() 是 glob out/*_client-*.yaml
    # —— 于是已删除的节点会以陈旧产物的形式**继续出现在订阅里发给用户**,
    # 客户端表现为「订阅里有这个节点但怎么都连不上」。
    #
    # 实测: 造一个 GHOST 节点后重建订阅, 它确实混进了 20 个 proxies 里。
    #
    # 判据: conf/config.d/.managed.json 是 merge.py 维护的「当前在跑的
    # listener」名单, 与节点是否存活一一对应; 名单里没有的就是陈旧的。
    #
    # ★ 比较必须**去旗帜**(node_key): 台账里是裸名, 产物里是带旗帜名
    #   —— 直接比字符串会得到空交集, 把全部活节点判成陈旧 (实测 19/19)。
    #
    # 没传 --conf-dir / 名单读不到时**不过滤** —— 宁可多发也不能把整份订阅
    # 变空 (那是更严重的故障)。
    if conf_dir:
        alive = live_node_names(os.path.join(conf_dir, "config.d"))
        if alive:
            alive_keys = {node_key(x) for x in alive}
            dropped = 0
            for proto, items in list(buckets.items()):
                keep = [it for it in items
                        if node_key(it.get("name")) in alive_keys]
                dropped += len(items) - len(keep)
                if keep:
                    buckets[proto] = keep
                else:
                    del buckets[proto]
            if dropped:
                print(f"[清理] 剔除了 {dropped} 个陈旧产物 (节点已删除, "
                      f"但 out/ 里旧文件还在)", file=sys.stderr)
            total = sum(len(v) for v in buckets.values())
            if total == 0:
                # 一个都不剩 = 要么真的全删光了, 要么名单与产物对不上。
                # 后者是**静默故障**, 必须把两边的写法打出来给人看。
                print(f"[ERR] 存活名单 {len(alive)} 个名字与 out/ 产物一个都"
                      f"对不上 —— 订阅会是空的 (不是'没有节点')", file=sys.stderr)
                print(f"      名单示例: {sorted(alive)[:3]}", file=sys.stderr)

    if import_dir and os.path.isdir(import_dir):
        collect_dir(import_dir, "imported", buckets)
    if providers_dir and os.path.isdir(providers_dir):
        # 客户端没有 out/*_client-*.yaml, 节点都在 conf/providers/*.yaml 里。
        # 每个 provider 文件单开一个 tag, 这样可以只分享其中一份订阅。
        for pf in sorted(glob.glob(os.path.join(providers_dir, "*.yaml"))):
            collect_dir(os.path.dirname(pf), os.path.splitext(os.path.basename(pf))[0], buckets)
    return buckets


def select_proxies(buckets: dict[str, list[dict]], tag: str) -> list[dict]:
    """按 tag 取节点 (与 build_sub 的 --tag 语义完全一致)。取不到返回 []。

    `all` 时按 name 去重并保留首个 —— 客户端常见情况是同一个订阅被导入成多个
    provider (rn_all / 哈希名 / sub_*), 直接按桶拼接会得到成倍的同名重复节点。
    """
    if tag == "all":
        proxies, seen = [], set()
        for proto in sorted(buckets):
            for x in buckets[proto]:
                nm = x.get("name")
                if nm in seen:
                    continue
                seen.add(nm)
                proxies.append(x)
        return proxies
    return list(buckets.get(tag, []))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--import-dir", default="", help="外部拉取的订阅目录 (合并为 imported)")
    ap.add_argument("--providers-dir", default="",
                    help="客户端 proxy-providers 目录 (每个 *.yaml 单独成一个 tag)")
    ap.add_argument("--conf-dir", default="",
                    help="服务端 conf 目录 (含 config.d/.managed.json)。"
                         "给了就按当前在跑的 listener 名单过滤掉陈旧产物")
    ap.add_argument("--tag", default="all", help="all 或某个协议前缀 (reality/trojan/...)")
    ap.add_argument("-o", "--output", default="")
    ap.add_argument("--list", action="store_true", help="只列出可用 tag (给人看的表格)")
    ap.add_argument("--list-tags", action="store_true",
                    help="只列出可用 tag, 每行一个 (给脚本用, 无表头无计数)")
    args = ap.parse_args()

    buckets = build_buckets(args.out_dir, args.conf_dir, args.import_dir,
                            args.providers_dir)

    if args.list_tags:
        # 机器可读: 每行一个 tag, 没有表头、没有计数、没有单位字。
        #
        # ★ 为什么必须有这个开关 (而不是让调用方去 awk 那张表格):
        #   --list 的表格是给人看的, 格式随时可能加列 (例如曾经加上 " 个"),
        #   调用方一旦按字段数过滤 (awk 'NF==2'), 格式一变就**静默变空** ——
        #   面板上表现为"分享哪些节点"只剩 "全部" 一个选项, 且没有任何报错。
        #   这类"两处必须一致但无机制保证"是本项目的头号 bug 类, 所以这里
        #   直接提供稳定的接口, 让调用方不再依赖表格长什么样。
        for proto in sorted(buckets):
            print(proto)
        return 0

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
        proxies = select_proxies(buckets, "all")
    else:
        proxies = select_proxies(buckets, args.tag)
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