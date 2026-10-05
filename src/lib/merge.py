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

优先使用 ruamel.yaml 以保留 config.yaml 里的注释；没有则退回 PyYAML。
"""
from __future__ import annotations

import argparse
import glob
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf", required=True, help="conf 目录 (含 config.yaml 与 config.d/)")
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

    # 保留主配置里已经存在、但 config.d 里没有的 listener（手工加的不被抹掉）
    old_listeners = {}
    for it in cfg.get("listeners") or []:
        if isinstance(it, dict) and it.get("name"):
            old_listeners[it["name"]] = it

    merged = collect_listeners(conf_dir)
    final = dict(old_listeners)
    final.update(merged)  # config.d 覆盖

    cfg["listeners"] = [final[k] for k in sorted(final)]

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

    print(
        f"[OK] 合并完成 → {main_file} "
        f"(config.d {len(merged)} 个 / 合计 {len(cfg['listeners'])} 个 listener)"
        + ("" if _HAVE_RUAMEL else "  [提示: 安装 python3-ruamel 可保留注释]"),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())