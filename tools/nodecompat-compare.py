#!/usr/bin/env python3
"""nodecompat-compare.py — 旧判定 vs compat 判定 双跑对比台（切换前必须全绿）。

做三件事，每一件都是机械的、可重复的:
  1. 逐条跑两套引擎，比出 **relaxed**（旧说不能用、新说能用 —— 最危险的一类）
  2. 比出 tightened / fallback / same，并给出"为什么收紧"
  3. 断言结果里 losses / unknowns / extensions / raw_uri 一个都没丢

用法:
    python3 tools/nodecompat-compare.py                 # 用内置语料
    python3 tools/nodecompat-compare.py a.json b.yaml   # 追加外部语料
    MIHOMO_BIN=/path/to/mihomo python3 tools/nodecompat-compare.py
退出码: 0 = 无 relaxed、无 downgrade、字段完整; 1 = 有问题
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src", "lib"))

import nodecompat  # noqa: E402

CORPUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "compat-corpus.json")
RANK = nodecompat.STATUS_RANK


def load_corpus(extra):
    items = []
    with open(CORPUS, encoding="utf-8") as fh:
        data = json.load(fh)
    for case in data.get("cases", []):
        items.append(case)
    for path in extra:
        text = open(path, encoding="utf-8").read()
        if path.endswith(".json"):
            d = json.loads(text)
        else:
            import yaml
            d = yaml.safe_load(text)
        nodes = d if isinstance(d, list) else (
            d.get("proxies") or d.get("nodes") or [d] if isinstance(d, dict) else [d])
        for n in nodes:
            items.append({"id": n.get("name") or "?", "node": n})
    return items


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("extra", nargs="*", help="额外的节点文件 (YAML/JSON)")
    ap.add_argument("--json", action="store_true", help="输出机器可读的完整结果")
    args = ap.parse_args()

    cases = load_corpus(args.extra)
    tgt = nodecompat.kernel_target()
    print("目标内核: %s" % json.dumps(tgt.to_dict(), ensure_ascii=False))
    if not tgt.version:
        print("  ⚠ 没探测到内核版本 —— compat 会对所有版本相关规则判 UNKNOWN "
              "并整体回退旧判定（设计行为, 不是错误）")
    print("语料: %d 条\n" % len(cases))

    relaxed, tightened, fallback, same, bad_fields, downgraded, wider = \
        [], [], [], [], [], [], []
    results = []
    for case in cases:
        # 两种输入形状: "uri" = 分享链接（走 compat 的 parse_uri, 旧判定不逐条
        # 表态 —— 客户端把整个列表原样交给内核的内置转换器）; "node" = YAML 条目。
        node = case.get("uri") or case["node"]
        res = nodecompat.judge(node, target=tgt)
        legacy = res["legacy"]["status"]
        comp = (res["compat"] or {}).get("status")
        rec = {"id": case.get("id") or "?", "why": case.get("why", ""),
               "legacy": legacy, "compat": comp, "merged": res["verdict"],
               "source": res["verdict_source"], "drop": res["drop"],
               "kind": res["kind"], "wider": res["wider"],
               "downgrades": res["downgrades"],
               "losses": len((res["compat"] or {}).get("losses") or []),
               "unknowns": len((res["compat"] or {}).get("unknowns") or []),
               "extensions": len((res["compat"] or {}).get("extensions") or []),
               "raw_uri": (res["compat"] or {}).get("raw_uri"),
               "describe": nodecompat.describe(res, limit=3)}
        results.append(rec)
        if res["downgrades"]:
            downgraded.append(rec)
        if res["wider"]:
            wider.append(rec)
        # 放宽: 旧判定明确不能用, 合并后却能用
        if legacy == "UNSUPPORTED" and res["verdict"] != "UNSUPPORTED":
            relaxed.append(rec)
        elif res["kind"] == "tightened":
            tightened.append(rec)
        elif res["kind"] == "fallback":
            fallback.append(rec)
        else:
            same.append(rec)
        # 字段完整性: 只要 compat 参与了, 四样必须在结果里出现
        if res["compat"] is not None:
            for k in ("losses", "unknowns", "extensions", "raw_uri"):
                if k not in res["compat"]:
                    bad_fields.append((rec["id"], k))

    def show(title, rows):
        if not rows:
            return
        print("── %s (%d) ──" % (title, len(rows)))
        for r in rows:
            print("   %-30s 旧=%-20s compat=%-20s 合并=%-20s %s"
                  % (str(r["id"])[:30], r["legacy"], r["compat"], r["merged"], r["describe"]))
        print()

    show("旧说能用 → 新判定更严 (tightened)", tightened)
    show("回退旧判定 (compat 无确定结论)", fallback)
    show("⛔ 旧判定要剔除、合并后却能用 (relaxed —— 必须为 0)", relaxed)
    show("保险丝在起作用: compat 想放宽、被挡回旧判定 (fuse_fired)", downgraded)
    if wider:
        print("── 信息: compat 比旧判定宽 %d 条 ──" % len(wider))
        print("   两个引擎量的不是同一件事: 旧判定有一维 compat 按设计不管 ——")
        print("   字段名的对错 (trojan 写 servername 会被内核静默忽略)。")
        print("   这类差异不参与判定, 只由\"取更差者\"保留旧判定的保守结论。")
        print()
    if bad_fields:
        print("⛔ 结果缺字段: %s" % bad_fields[:5])

    # 保险丝只在一种情况下**应该**触发: 旧判定要剔除, compat 却说能用。
    # 多触发一次、少触发一次都说明合并层坏了 —— 所以这里比的是等式, 不是"越小越好"。
    should_fuse = sum(1 for r in results
                      if r["legacy"] == "UNSUPPORTED" and r["compat"] not in (None, "UNKNOWN",
                                                                             "UNSUPPORTED"))
    fuse_ok = len(downgraded) == should_fuse
    print("═══ 结论 ═══")
    print("  语料 %d 条: 收紧 %d | 回退旧判定 %d | 一致 %d"
          % (len(cases), len(tightened), len(fallback), len(same)))
    print("  relaxed    : %d   <- 旧判定要剔除、合并后却能用: 必须 0" % len(relaxed))
    print("  fuse_fired : %d   期望 %d  %s"
          % (len(downgraded), should_fuse, "✅" if fuse_ok else "❌ 合并层坏了"))
    print("  字段完整   : %s" % ("✅" if not bad_fields else "❌"))
    print("  判定引擎  : %s%s" % (nodecompat.engine(),
                               "" if not nodecompat.reason_disabled()
                               else " (退回旧判定: %s)" % nodecompat.reason_disabled()))
    if args.json:
        print(json.dumps({"target": tgt.to_dict(), "results": results},
                         ensure_ascii=False, indent=1))
    return 1 if (relaxed or bad_fields or not fuse_ok) else 0


if __name__ == "__main__":
    raise SystemExit(main())
