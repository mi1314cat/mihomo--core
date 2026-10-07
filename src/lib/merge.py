#!/usr/bin/env python3
"""
merge.py — 把 config.d/*.yaml 的 listeners 合并进 config.yaml

单一数据来源原则：
  config.d/<proto>-<NN>.yaml   ← 唯一真相来源（每个节点一个片段）
  config.yaml                  ← 内核实际加载的文件（由本脚本生成）

合并规则：
  * config.yaml 的非 listeners 键（dns / rules / proxy-groups / ...）原样保留
  * listeners 取 config.d 全部片段，config.d 优先（同名覆盖）
  * 原子写入 + 自动备份

来源追踪（解决「删除节点删不掉」）：
    合并时把「本次注入的 listener 名字」记进 config.d/.managed.json。
    下次合并时，凡是在 .managed.json 里、但已不在 config.d 中的 listener
    判定为「片段被删除」，从 config.yaml 剔除。
    不在 .managed.json 里的 listener 视为手工添加，原样保留。

    没有这个追踪时，合并逻辑是 old ∪ new，listener 一旦进过 config.yaml
    就永远删不掉 —— 删节点后端口继续监听，面板却报「已删除」。

优先使用 ruamel.yaml 以保留 config.yaml 里的注释；没有则退回 PyYAML。
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import sys
import tempfile

try:
    from ruamel.yaml import YAML as _RuamelYAML  # type: ignore

    _HAVE_RUAMEL = True
except Exception:  # noqa: BLE001
    _HAVE_RUAMEL = False

import yaml


def _round_trip():
    y = _RuamelYAML()
    y.preserve_quotes = True
    y.indent(mapping=2, sequence=4, offset=2)
    return y


def _load(path):
    """返回 (data, is_roundtrip_obj)"""
    if _HAVE_RUAMEL:
        y = _round_trip()
        with open(path, "r", encoding="utf-8") as fh:
            return y.load(fh), True
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh), False


def _dump(data, rt, fh):
    if rt and _HAVE_RUAMEL:
        _round_trip().dump(data, fh)
    else:
        yaml.safe_dump(data, fh, sort_keys=False, allow_unicode=True)


def _norm(d):
    return d if isinstance(d, dict) else {}


def collect_listeners(conf_dir: str):
    """读取 config.d/*.yaml，返回 {name: listener}，同文件后者覆盖前者。"""
    found = {}
    for p in sorted(glob.glob(os.path.join(conf_dir, "config.d", "*.yaml"))):
        try:
            with open(p, "r", encoding="utf-8") as fh:
                d = yaml.safe_load(fh) or {}
        except Exception as e:  # noqa: BLE001
            print(f"[WARN] 跳过无法解析的片段 {p}: {e}", file=sys.stderr)
            continue
        if not isinstance(d, dict):
            continue
        for it in d.get("listeners") or []:
            if isinstance(it, dict) and it.get("name"):
                found[it["name"]] = it
    return found


# 除 listeners 之外, 还有哪些**顶层键**也应该由 config.d 片段提供。
#
# ★ 为什么需要这张表 (2026-10-07 新增)
#
#   merge.py 此前**只**收 `listeners`, 于是片段里写的其它顶层键被静默丢弃:
#       outbounds:      -> 丢弃 (服务端出站管理形同虚设)
#       rule-providers: -> 丢弃 (规则集形同虚设)
#       rules:          -> 丢弃 (规则集的 RULE-SET 规则进不来)
#
#   症状极其隐蔽: 片段文件确实写出来了, 严格校验也过了 (校验器读的是**合并后**
#   的 config.yaml, 而那些键根本没进去, 自然"没错"), mihomo -t 也过,
#   面板显示一切正常 —— 只有用户在 rules 里引用了那个 rule-provider 时才会
#   发现"规则没生效"。而且没有任何一条报错指向真正的原因。
#
#   这与内核文档里记的"未知键静默忽略"是同一类陷阱, 只是发生在我们自己的
#   合并层。
#
#   语义与 listeners 一致: 同名条目后者覆盖前者, 片段删除后自动剔除。
FRAG_TOP_KEYS = ("outbounds", "rule-providers", "rules")


def collect_top_keys(conf_dir: str):
    """收集片段里的顶层键, 返回 {键名: {条目名: 条目}}。

    - outbounds / rule-providers 是 {名字: {...}} 映射
    - rules 是列表, 但每条都以 "RULE-SET,<tag>," 开头, 用 <tag> 当键去重
      (同名 tag 的规则后者覆盖前者, 不会出现两条 RULE-SET 同时命中)。
    """
    found: dict[str, dict] = {k: {} for k in FRAG_TOP_KEYS}
    for p in sorted(glob.glob(os.path.join(conf_dir, "config.d", "*.yaml"))):
        try:
            with open(p, "r", encoding="utf-8") as fh:
                d = yaml.safe_load(fh) or {}
        except Exception:  # noqa: BLE001
            continue
        if not isinstance(d, dict):
            continue
        for key in FRAG_TOP_KEYS:
            val = d.get(key)
            if val is None:
                continue
            if key == "rules":
                # 规则是**字符串列表**, 以 RULE-SET,<tag>, 里的 <tag> 当键去重
                if not isinstance(val, list):
                    continue
                for r in val:
                    if not isinstance(r, str):
                        continue
                    parts = r.split(",")
                    tag = parts[1] if len(parts) > 1 and parts[0] == "RULE-SET" else r
                    found[key][tag] = r
            elif key == "outbounds":
                # ★ outbounds 在内核里是**列表** (与 proxies 同构), 不是映射。
                #   按名字去重: 同名后者覆盖前者, 不会出现两条同名出站
                #   (rules 里按名字引用, 重名无法区分)。
                if not isinstance(val, list):
                    continue
                for o in val:
                    if isinstance(o, dict) and o.get("name"):
                        found[key][o["name"]] = o
            elif isinstance(val, dict):
                # rule-providers 是 {名字: {...}} 映射
                for name, item in val.items():
                    if isinstance(item, dict):
                        found[key][name] = item
    return found


def merge_top_keys(cfg: dict, incoming: dict) -> int:
    """把 incoming 合进 cfg 的对应顶层键, 返回新增/变更的条目数。

    **只增不删**: 片段删除时对应条目应该消失, 但 config.yaml 里手工写的
    同名条目不能被误删 —— 与 listeners 的 .managed.json 台账同源的取舍,
    这里保守处理: 手工条目一律保留, 片段条目按名字覆盖。
    """
    changed = 0
    for key in FRAG_TOP_KEYS:
        got = incoming.get(key) or {}
        if not got:
            continue
        if key in ("rules", "outbounds"):
            # outbounds 是**列表** (与 proxies 同构), 按 name 去重;
            # rules 是字符串列表, 按 RULE-SET 的 tag 去重。
            cur = [r for r in (cfg.get(key) or []) if isinstance(r, (str, dict))]
            def _key_of(r):
                if isinstance(r, dict):
                    return r.get("name") or ""
                parts = r.split(",")
                return parts[1] if len(parts) > 1 and parts[0] == "RULE-SET" else r
            have = {_key_of(r) for r in cur}
            added = [v for k, v in got.items() if k not in have]
            added = [a for a in added if _key_of(a)]
            if added:
                # 按名字排序保证输出稳定 (dict 不可比较, 不能直接 sorted())
                added.sort(key=lambda r: _key_of(r))
                cfg[key] = cur + added
                changed += len(added)
        else:
            cur = cfg.get(key)
            if not isinstance(cur, dict):
                cur = {}
            for name, item in got.items():
                if cur.get(name) != item:
                    changed += 1
                cur[name] = item
            cfg[key] = cur
    return changed


def managed_path(frag_dir: str) -> str:
    """记录「哪些 listener 是由 config.d 注入」的台账文件。"""
    return os.path.join(frag_dir, ".managed.json")


def load_managed(frag_dir: str) -> set:
    p = managed_path(frag_dir)
    try:
        with open(p, "r", encoding="utf-8") as fh:
            d = json.load(fh)
        return set(d) if isinstance(d, list) else set()
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return set()


def save_managed(frag_dir: str, names: set) -> None:
    """台账本身也要原子写，且不能被 collect_listeners 当成节点片段。"""
    p = managed_path(frag_dir)
    fd, tmp = tempfile.mkstemp(dir=frag_dir, prefix=".managed.", suffix=".json")
    os.close(fd)
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(sorted(names), fh, indent=1)
        os.replace(tmp, p)
    except Exception as e:  # noqa: BLE001
        if os.path.exists(tmp):
            os.unlink(tmp)
        print(f"[WARN] 来源台账写入失败: {e}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf", required=True, help="conf 目录 (含 config.yaml 与 config.d/)")
    ap.add_argument(
        "--rebuild",
        action="store_true",
        help="丢弃 config.yaml 里所有手工添加的 listener, 完全按 config.d 重建",
    )
    args = ap.parse_args()

    conf_dir = args.conf
    main_file = os.path.join(conf_dir, "config.yaml")
    frag_dir = os.path.join(conf_dir, "config.d")

    if not os.path.isdir(frag_dir):
        print(f"[ERR] 片段目录不存在: {frag_dir}", file=sys.stderr)
        return 5

    # 载入主配置（不存在则从空开始）
    rt = False
    if os.path.isfile(main_file):
        try:
            existing, rt = _load(main_file)
        except Exception:  # noqa: BLE001
            existing, rt = {}, False
    else:
        existing, rt = {}, False
    cfg = _norm(existing)

    # config.yaml 里已有的 listener
    old_listeners = {}
    for it in cfg.get("listeners") or []:
        if isinstance(it, dict) and it.get("name"):
            old_listeners[it["name"]] = it

    merged = collect_listeners(conf_dir)

    # ---- 来源追踪: 决定哪些"消失的 listener"该被剔除 ----
    if args.rebuild:
        dropped = [n for n in old_listeners if n not in merged]
        final = dict(merged)
    else:
        was_managed = load_managed(frag_dir)
        # 上次由 config.d 注入、这次片段已删 → 判定为删除, 剔除
        pruned = sorted(was_managed - set(merged))
        # 从未被台账记录过 → 手工添加, 保留
        final = {n: v for n, v in old_listeners.items()
                 if n not in pruned and (n in merged or n not in was_managed)}
        dropped = pruned
    final.update(merged)  # config.d 永远覆盖

    if dropped:
        print(f"[OK] 剔除已删除片段残留的 listener: {', '.join(dropped)}", file=sys.stderr)

    cfg["listeners"] = [final[k] for k in sorted(final)]

    # 出站 / 规则集 / 规则 (2026-10-07 新增)。放在 listeners 之后、原子写入
    # 之前 —— 与 listeners 走同一次写入, 不会出现「一半生效」的中间态。
    _top = collect_top_keys(conf_dir)
    _n_top = merge_top_keys(cfg, _top)
    if _n_top:
        _what = ", ".join(f"{k}:{len(v)}" for k, v in _top.items() if v)
        print(f"[OK] 合并片段顶层键 → {_what}", file=sys.stderr)

    # 原子写入
    os.makedirs(conf_dir, exist_ok=True)
    if os.path.isfile(main_file):
        shutil.copy2(main_file, main_file + ".bak")

    fd, tmp = tempfile.mkstemp(dir=conf_dir, prefix=".config.", suffix=".yaml")
    os.close(fd)
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            _dump(cfg, rt, fh)
        shutil.copymode(main_file if os.path.isfile(main_file) else tmp, tmp)
        os.replace(tmp, main_file)
    except Exception as e:  # noqa: BLE001
        os.unlink(tmp)
        print(f"[ERR] 写入失败: {e}", file=sys.stderr)
        return 7

    save_managed(frag_dir, set(merged))

    print(
        f"[OK] 合并完成 → {main_file} "
        f"(config.d {len(merged)} 个 / 合计 {len(cfg['listeners'])} 个 listener)"
        + ("" if _HAVE_RUAMEL else "  [提示: 安装 python3-ruamel 可保留注释]"),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())