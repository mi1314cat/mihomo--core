#!/usr/bin/env python3
"""Phase 4D · CLI —— 不需要编程就能测节点兼容性。

    proxy-node-compat check   "<uri>" --kernel mihomo --version 1.19.32
    proxy-node-compat check-many nodes.txt --kernel singbox --version 1.14.2
    proxy-node-compat capabilities --kernel mihomo

目标信息不足时**明确说出缺什么**, 不默默补默认值。
"""

from __future__ import annotations

import argparse
import json
import sys

from .engine import Target, evaluate
from .model import NodeProfile
from .registry import Registry, default_registry_path
from .uri import parse_uri

_ICON = {"SUPPORTED": "✅", "SUPPORTED_WITH_WARNING": "🟡", "SUPPORTED_WITH_LOSS": "🟠",
         "UNSUPPORTED": "❌", "UNKNOWN": "❓"}


def _target_from_args(a: argparse.Namespace) -> Target:
    tags = a.build_tags.split(",") if a.build_tags else None
    runtime = {}
    for kv in (a.runtime or []):
        k, _, v = kv.partition("=")
        runtime[k] = v.lower() in ("1", "true", "yes", "on")
    return Target(kernel=a.kernel, distribution=a.distribution, version=a.version,
                  build_tags=tags, platform=a.platform, runtime_options=runtime,
                  evaluated_at=a.evaluated_at)


def _load(uri_or_file: str) -> NodeProfile:
    if uri_or_file.startswith(("vless://", "vmess://", "trojan://", "ss://", "hysteria2://",
                               "hy2://", "tuic://", "anytls://", "socks://", "http://",
                               "https://", "socks5://")):
        return parse_uri(uri_or_file)
    with open(uri_or_file, encoding="utf-8") as fh:
        text = fh.read().strip()
    if text.startswith("{"):
        return NodeProfile.from_dict(json.loads(text))
    return parse_uri(text)


def _render(profile: NodeProfile, target: Target, res, as_json: bool,
            verbose: bool) -> str:
    if as_json:
        return json.dumps({"target": target.to_dict(), "result": res.to_dict()},
                          ensure_ascii=False, indent=2)
    name = (profile.metadata.get("name").v if profile.metadata.get("name") else "?")
    out = [f"{_ICON.get(res.status, '?')} {res.status}  [{name}]",
           f"   目标: {target.kernel}"
           + (f" {target.distribution}" if target.distribution else "")
           + (f" {target.version}" if target.version else " (版本未知)")
           + (f" tags={target.build_tags}" if target.build_tags else "")
           + (f" platform={target.platform}" if target.platform else "")]
    out.append("   分层: " + "  ".join(f"{lv}={res.levels[lv]}" for lv in
                                       ("parse", "config", "uri", "runtime", "semantic")))
    if res.reason_codes:
        out.append("   原因码: " + ", ".join(res.reason_codes))
    if res.failure_mode:
        out.append(f"   失败模式: {res.failure_mode}")
    if res.message:
        out.append(f"   说明: {res.message}")
    for ls in res.losses:
        out.append(f"   🟠 损失: {ls.get('feature')} —— {ls.get('what')} "
                   f"[{ls.get('impact')}] ({ls.get('rule')})")
    for wn in res.warnings:
        out.append(f"   🟡 注意: {wn.get('code')} —— {wn.get('detail')}")
    for un in res.unknowns:
        out.append(f"   ❓ 未知: {un.get('what')} —— {un.get('why')}")
    if verbose and res.evidence:
        out.append("   证据:")
        for ev in res.evidence:
            out.append(f"     - [{ev.get('type')}/{ev.get('confidence')}] {ev.get('claim')}"
                       f"  ↳ {ev.get('where')}  (局限: {ev.get('limits')})")
    # 缺信息提示（不默默补默认值）
    missing = []
    if not target.version:
        missing.append("--version")
    if not target.build_tags:
        missing.append("--build-tags（内核 build 标签, 影响可选能力）")
    if missing and not verbose:
        out.append("   ⓘ 缺少信息: " + "; ".join(missing)
                   + " —— 受影响的判断已标 UNKNOWN, 未用默认值替代")
    if res.raw_uri:
        out.append(f"   原始链接已保留: {res.raw_uri[:80]}{'…' if len(res.raw_uri) > 80 else ''}")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="proxy-node-compat",
                                 description="跨内核节点兼容性判断（本地、离线）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--kernel", required=True,
                       help="目标内核: xray | mihomo | singbox（可扩展）")
        p.add_argument("--distribution", default=None,
                       help="发行版/fork；缺省视为 upstream；未知 fork 一律 UNKNOWN")
        p.add_argument("--version", default=None, help="内核版本，如 1.19.32；缺省则版本相关判断为 UNKNOWN")
        p.add_argument("--build-tags", default=None, help="构建标签，逗号分隔，如 with_utls,with_quic")
        p.add_argument("--platform", default=None, help="平台，如 linux/amd64")
        p.add_argument("--runtime", action="append", help="运行期选项 k=v，可重复")
        p.add_argument("--evaluated-at", default=None, help="评估时刻（时间闸门用）")
        p.add_argument("--registry", default=default_registry_path())
        p.add_argument("--json", action="store_true")
        p.add_argument("-v", "--verbose", action="store_true", help="显示证据与局限")

    p1 = sub.add_parser("check", help="检查单个节点")
    p1.add_argument("node", help="分享链接，或 profile JSON 文件")
    common(p1)

    p2 = sub.add_parser("check-many", help="批量检查（每行一个链接）")
    p2.add_argument("file")
    common(p2)

    p3 = sub.add_parser("capabilities", help="列出注册表里覆盖的能力规则")
    p3.add_argument("--kernel", default=None)
    p3.add_argument("--registry", default=default_registry_path())
    p3.add_argument("--json", action="store_true")

    args = ap.parse_args(argv)
    reg = Registry.load(args.registry)

    if args.cmd == "capabilities":
        rows = [r for r in reg.rules if not args.kernel or r.target.get("kernel") == args.kernel]
        if args.json:
            print(json.dumps([{"rule_id": r.rule_id, "target": r.target,
                               "selector": r.selector, "transition": r.transition,
                               "evidence_only": r.evidence_only,
                               "version_independent": r.version_independent}
                              for r in rows], ensure_ascii=False, indent=2))
        else:
            print(f"注册表覆盖 {len(rows)} 条规则（证据 {len(reg.evidence)} 条）:")
            for r in rows:
                flags = []
                if r.version_independent:
                    flags.append("版本无关")
                if r.transition == "UNKNOWN":
                    flags.append("含未知区间")
                if r.evidence_only:
                    flags.append("无版本证据")
                print(f"  - {r.rule_id:44s} {r.target.get('kernel'):8s} "
                      f"{'/'.join(flags) or '版本有界'}")
        return 0

    target = _target_from_args(args)
    if args.cmd == "check":
        profile = _load(args.node)
        res = evaluate(profile, target, reg)
        print(_render(profile, target, res, args.json, args.verbose))
        return 0

    # check-many
    ok = 0
    agg: dict[str, int] = {}
    lines = [ln.strip() for ln in open(args.file, encoding="utf-8") if ln.strip()
             and not ln.strip().startswith("#")]
    results = []
    for ln in lines:
        try:
            profile = parse_uri(ln)
        except Exception as exc:  # 单行失败不拖垮整批
            print(f"⚠️  跳过无法解析的一行: {ln[:60]}… ({exc})")
            continue
        res = evaluate(profile, target, reg)
        agg[res.status] = agg.get(res.status, 0) + 1
        ok += 1
        results.append({"uri": ln, "status": res.status,
                        "reason_codes": res.reason_codes, "levels": res.levels})
        if not args.json:
            print(_render(profile, target, res, False, False) + "\n")
    if args.json:
        print(json.dumps({"target": target.to_dict(), "total": ok,
                          "summary": agg, "items": results},
                         ensure_ascii=False, indent=2))
    else:
        print("─" * 60)
        print(f"共 {ok} 个节点: " + "  ".join(f"{k}={v}" for k, v in sorted(agg.items())))
        print("提示: UNKNOWN 表示证据不足（不是不支持）; UNSUPPORTED 才是明确不支持。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
