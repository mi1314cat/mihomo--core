#!/usr/bin/env python3
"""
dns_edit.py — 结构化读写 config.yaml 的 `dns` 段

为什么必须单独写一个脚本:
  config.yaml 由 merge.py 生成, 除 listeners 外的键 (dns / rules / ...) 原样保留。
  要改 dns 就得做**结构化**的 YAML 编辑 —— 用 sed/grep 动 YAML 迟早把缩进或
  引号弄坏, 而 DNS 配错的后果是**全机解析中断**, 不是单个节点失效。

  另外 mihomo 只接受它认识的 dns 键, 写错了内核静默忽略 —— 所以改完必须让
  调用方走 m_sync 的三道关 (merge → validate.py → mihomo -t)。

接口:
  dns_edit.py --conf <配置目录> --get               把 dns 段打成 JSON 输出
  dns_edit.py --conf <配置目录> --set-json '<json>'  整段替换 dns
  dns_edit.py --conf <配置目录> --del                删除 dns 段

写入是原子的 (临时文件 + rename), 并在同目录留 .dns-bak 备份。
有 ruamel 时用它以保留注释; 没有则退回 PyYAML (注释会丢, 结构不变)。
"""
from __future__ import annotations

import argparse
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

try:
    import yaml as _PyYAML  # type: ignore
except Exception:  # noqa: BLE001
    _PyYAML = None


def _load(path: str):
    with open(path, "r", encoding="utf-8") as fh:
        if _HAVE_RUAMEL:
            y = _RuamelYAML()
            y.preserve_quotes = True
            return y, y.load(fh)
        if _PyYAML is None:
            raise RuntimeError("既没有 ruamel.yaml 也没有 PyYAML, 无法编辑 YAML")
        return None, _PyYAML.safe_load(fh)


def _dump(y, data, path: str) -> None:
    """原子写入: 先写同目录临时文件, 再 rename 覆盖。

    直接 open(path,'w') 写一半崩掉会留下半个文件, 而 config.yaml 是内核的
    唯一输入 —— 半个文件 = 服务起不来。
    """
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".dns-", suffix=".yaml")
    os.close(fd)
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            if y is not None:
                y.dump(data, fh)
            else:
                _PyYAML.safe_dump(data, fh, allow_unicode=True, sort_keys=False)
        shutil.copymode(path, tmp) if os.path.exists(path) else None
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf", required=True, help="配置目录 (含 config.yaml)")
    ap.add_argument("--get", action="store_true")
    ap.add_argument("--set-json")
    ap.add_argument("--del", dest="delete", action="store_true")
    args = ap.parse_args()

    path = os.path.join(args.conf, "config.yaml")
    if not os.path.isfile(path):
        print(f"找不到 {path}", file=sys.stderr)
        return 1

    try:
        y, data = _load(path)
    except Exception as e:  # noqa: BLE001
        print(f"解析 config.yaml 失败: {e}", file=sys.stderr)
        return 1
    if data is None:
        data = {}

    if args.get:
        json.dump(data.get("dns") or {}, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0

    if not args.set_json and not args.delete:
        print("需要 --get / --set-json / --del 之一", file=sys.stderr)
        return 2

    # 备份: 与 merge.py 的 .bak 区分开, 便于出问题时分辨是谁写的
    bak = path + ".dns-bak"
    shutil.copy2(path, bak)

    if args.delete:
        data.pop("dns", None)
    else:
        try:
            new = json.loads(args.set_json)
        except json.JSONDecodeError as e:
            print(f"--set-json 不是合法 JSON: {e}", file=sys.stderr)
            return 2
        if not isinstance(new, dict):
            print("dns 段必须是对象 (map)", file=sys.stderr)
            return 2
        data["dns"] = new

    _dump(y, data, path)
    print(f"已写入 {path} (备份: {bak})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
