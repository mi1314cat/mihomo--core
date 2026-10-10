"""Phase 4B · Compatibility Evaluation（分层判定）。

四条纪律:
  1. 未知一律 UNKNOWN, 禁止向证据区间外推断
  2. 未知只影响**它实际影响的层级**, 不把无关层级一起标成未知
  3. 静默类失败（silent_ignore / silent_drop）必须升级为 SUPPORTED_WITH_LOSS
  4. 判定只发生一次: 本模块是唯一检查点, 客户端只消费结果
"""

from __future__ import annotations

from dataclasses import dataclass, field as dc_field
from typing import Any

from .model import NodeProfile, Presence
from .registry import Registry, Rule, Segment, parse_version, version_in_range

LEVELS = ("parse", "config", "uri", "runtime", "semantic")
# 内核侧层级（uri 是独立第三张表, 不受内核能力/版本/发行版缺失的影响）
KERNEL_LEVELS = ("parse", "config", "runtime", "semantic")

_STATUS_ORDER = {
    "SUPPORTED": 0,
    "SUPPORTED_WITH_WARNING": 1,
    "SUPPORTED_WITH_LOSS": 2,
    "UNKNOWN": 3,
    "UNSUPPORTED": 4,
}
_WORSE = max


def _worst(a: str | None, b: str | None) -> str | None:
    if a is None:
        return b
    if b is None:
        return a
    return a if _STATUS_ORDER[a] >= _STATUS_ORDER[b] else b


# 节点自身**显式**给出的字段可以直接满足某些运行期条件（P7: DEFAULTED/INFERRED 一律不算）。
# 证据: mihomo common/convert/v.go:28-33 —— URI 的 fp → client-fingerprint
#       （trojan 路径 converter.go:212-216），所以"链接里有 fp"确实能补上这个条件。
_PROFILE_RUNTIME_FACTS = {"client_fingerprint_present": ("fingerprint", "fp")}


def _profile_runtime_facts(profile: NodeProfile) -> tuple[dict[str, Any], dict[str, str]]:
    """profile → 可确定的运行期条件。返回 (facts, why)。

    facts 只是**缺省来源**: 目标端自报的 runtime_options 永远优先（客户端说没有就是没有）。
    """
    facts: dict[str, Any] = {}
    why: dict[str, str] = {}
    feats = ([profile.protocol] if profile.protocol else []) + list(profile.features)
    for key, param_names in _PROFILE_RUNTIME_FACTS.items():
        for feat in feats:
            for pk, pf in feat.params.items():
                if pk in param_names and pf.presence is Presence.EXPLICIT and pf.v:
                    facts[key] = True
                    why[key] = (f"{feat.id}.{pk}={pf.v}"
                                f"（provenance={pf.provenance.value if pf.provenance else '?'}）")
    return facts, why


@dataclass
class Target:
    """判定输入（四维）。缺省即 UNKNOWN, 不即"默认支持"。"""

    kernel: str
    distribution: str | None = None
    version: str | None = None
    build_tags: list[str] | None = None      # None = 未知（不是"空"）
    platform: str | None = None
    runtime_options: dict[str, Any] = dc_field(default_factory=dict)
    evaluated_at: str | None = None

    def to_dict(self) -> dict:
        return {"kernel": self.kernel, "distribution": self.distribution,
                "version": self.version, "build_tags": self.build_tags,
                "platform": self.platform, "runtime_options": self.runtime_options,
                "evaluated_at": self.evaluated_at}


@dataclass
class EvaluationResult:
    status: str
    levels: dict[str, str]
    reason_codes: list[str] = dc_field(default_factory=list)
    message: str = ""
    failure_mode: str | None = None
    losses: list[dict] = dc_field(default_factory=list)
    warnings: list[dict] = dc_field(default_factory=list)
    unknowns: list[dict] = dc_field(default_factory=list)
    detected_features: list[dict] = dc_field(default_factory=list)
    evidence: list[dict] = dc_field(default_factory=list)
    raw_uri: str | None = None
    rules_applied: list[str] = dc_field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "status": self.status, "levels": self.levels,
            "reason_codes": self.reason_codes, "message": self.message,
            "failure_mode": self.failure_mode, "losses": self.losses,
            "warnings": self.warnings, "unknowns": self.unknowns,
            "detected_features": self.detected_features,
            "evidence": self.evidence, "raw_uri": self.raw_uri,
            "rules_applied": self.rules_applied,
        }


class _Acc:
    """累加器: 按层收集结论, 并记录损失/未知/证据。"""

    def __init__(self) -> None:
        self.levels: dict[str, str | None] = {lv: None for lv in LEVELS}
        self.explicit: set[str] = set()      # 被显式判定的层级（兜底不算）
        self.reasons: list[str] = []
        self.losses: list[dict] = []
        self.warnings: list[dict] = []
        self.unknowns: list[dict] = []
        self.evidence: list[str] = []
        self.failure_mode: str | None = None
        self.rules: list[str] = []
        self.messages: list[str] = []

    def set_level(self, level: str, status: str) -> None:
        if level not in self.levels:
            return
        self.levels[level] = _worst(self.levels[level], status)
        self.explicit.add(level)

    def set_levels(self, status: str, levels) -> None:
        """只影响指定层级 —— 缺信息不该污染无关层级（用户 4B 节要求）。"""
        for lv in levels:
            self.set_level(lv, status)

    def reason(self, code: str | None) -> None:
        if code and code not in self.reasons:
            self.reasons.append(code)

    def note_unknown(self, what: str, why: str) -> None:
        self.unknowns.append({"what": what, "why": why})


def _segment_for(rule: Rule, version: tuple[int, ...] | None,
                 acc: _Acc, target: Target) -> Segment | None:
    """挑出适用段。挑不到就是 UNKNOWN —— 绝不外推。"""
    if rule.evidence_only:
        acc.note_unknown(f"{rule.rule_id}: 版本行为",
                         "该规则没有任何版本证据（evidence_only）")
        return None
    if rule.version_independent:
        for seg in rule.segments:
            return seg
        acc.note_unknown(f"{rule.rule_id}: 规则无段落定义", "数据缺失")
        return None
    if version is None:
        acc.note_unknown(f"{rule.rule_id}: 目标版本未知",
                         "未提供 version —— 版本相关的规则无法判定（不影响版本无关的规则）")
        return None
    for seg in rule.segments:
        if version_in_range(version, seg.range):
            return seg
    for gap in rule.unknown_range:
        if version_in_range(version, gap.get("range", "")):
            acc.note_unknown(f"{rule.rule_id}: {gap.get('range')}",
                             gap.get("why", "证据空缺"))
            return None
    acc.note_unknown(f"{rule.rule_id}: 版本 {target.version} 未覆盖",
                     "没有任何段落覆盖该版本, 且未标注为已知区间")
    return None


def _apply_segment(rule: Rule, seg: Segment, acc: _Acc, target: Target,
                   facts: dict[str, Any], why: dict[str, str]) -> None:
    # ---- 构建标签: 已知缺失 → BUILD_NOT_ENABLED；未知 → UNKNOWN（不猜）
    if seg.requires_build_tags:
        if target.build_tags is None:
            acc.note_unknown(f"{rule.rule_id}: build tags",
                             "未提供 build_tags, 无法判断可选依赖是否编入")
        elif not set(seg.requires_build_tags).issubset(set(target.build_tags)):
            acc.set_levels("UNSUPPORTED", KERNEL_LEVELS)
            acc.reason("BUILD_NOT_ENABLED")
            acc.messages.append(
                f"{rule.rule_id}: 该构建缺少 {seg.requires_build_tags}")
            return

    # ---- 运行期条件
    if seg.runtime_condition:
        need = seg.runtime_condition
        # 目标端自报的运行期状态优先; 缺省由节点自身的显式字段补足（见 _profile_runtime_facts）
        effective = dict(facts)
        effective.update(target.runtime_options)
        ok = all(effective.get(k) == v for k, v in need.items())
        if not ok:
            acc.reason("RUNTIME_CONDITION_NOT_MET")
            for lv, st in (seg.verdict or {}).items():
                acc.set_level(lv, "SUPPORTED_WITH_LOSS" if st == "SUPPORTED" else st)
            acc.losses.append({
                "feature": rule.selector.get("feature") or rule.rule_id,
                "what": seg.note or f"需要运行期条件 {need}",
                "impact": "CONNECTIVITY",
                "rule": rule.rule_id})
        else:
            # 条件是"节点自己带来的" → 必须留痕（不能悄悄当成客户端已满足）
            for k, v in need.items():
                if not v or k in target.runtime_options or facts.get(k) != v:
                    continue
                detail = (f"运行期条件 {k} 由节点自身显式字段满足: {why.get(k, '')}"
                          " —— 客户端导入时必须写进配置, 否则仍会运行期失败")
                if not any(w.get("code") == "RUNTIME_CONDITION_FROM_PROFILE"
                           and w.get("detail") == detail for w in acc.warnings):
                    acc.warnings.append({"code": "RUNTIME_CONDITION_FROM_PROFILE",
                                         "detail": detail, "rule": rule.rule_id})

    # ---- 段落结论（没有 verdict 时用规则级 reason/message 兜底）
    for lv, st in (seg.verdict or {}).items():
        acc.set_level(lv, st)
    if seg.failure_mode:
        acc.failure_mode = seg.failure_mode
        if seg.failure_mode.startswith("silent_"):
            # 静默类失败绝不允许显示成 SUPPORTED（纪律 3）
            for lv in ("runtime", "semantic"):
                if acc.levels[lv] == "SUPPORTED":
                    acc.levels[lv] = "SUPPORTED_WITH_LOSS"
    # 只有"确实出了非成功结果"时才记原因码 —— 否则条件满足也会挂一个
    # "为什么不能用"的原因码出来（会误导客户端）。
    has_failure = (seg.failure_mode is not None) or any(
        st in ("UNSUPPORTED", "SUPPORTED_WITH_LOSS")
        for st in (seg.verdict or {}).values())
    if seg.reason_code and has_failure:
        acc.reason(seg.reason_code)
    for ls in seg.losses:
        acc.losses.append({**ls, "rule": rule.rule_id})
    for wn in seg.warnings:
        acc.warnings.append({**wn, "rule": rule.rule_id})
    if rule.mismatch:
        acc.warnings.append({"code": "SEMANTIC_MISMATCH",
                             "detail": rule.message or rule.mismatch,
                             "rule": rule.rule_id})

    # ---- 组合约束（单点支持 ≠ 组合支持）
    if rule.constraint:
        allowed = rule.constraint.get("allowed_transports") or []
        have = {f for f in _profile_feature_ids(rule, acc)}
        if allowed and not (set(allowed) & have):
            acc.set_levels("UNSUPPORTED", KERNEL_LEVELS)
            acc.reason(rule.reason_code or "SEMANTIC_MISMATCH")
            acc.messages.append(rule.message or
                                f"{rule.rule_id}: 组合不受支持（需要 {allowed} 之一）")
    acc.evidence.extend(rule.evidence)
    acc.rules.append(rule.rule_id)


def _profile_feature_ids(rule: Rule, acc: _Acc) -> list[str]:
    return list(getattr(acc, "_feature_ids", []))


def evaluate(profile: NodeProfile, target: Target,
             registry: Registry) -> EvaluationResult:
    acc = _Acc()
    feat_ids = set(profile.feature_ids())
    setattr(acc, "_feature_ids", sorted(feat_ids))
    protocol_id = profile.protocol.id if profile.protocol else None
    scheme = _scheme_of(profile)

    # ---------------- 1. 发行版/fork: 没数据就是 UNKNOWN, 不继承上游
    dist = target.distribution or "upstream"
    if not registry.kernel_has_distribution_rule(target.kernel, dist):
        acc.set_levels("UNKNOWN", KERNEL_LEVELS)      # 只影响内核侧层级
        acc.reason("UNKNOWN_CAPABILITY")
        acc.note_unknown(
            f"distribution={dist}",
            "该发行版/fork 没有任何能力规则；fork 不得默认继承上游")

    # ---------------- 2. 能力规则
    matched = registry.rules_for(target.kernel, dist, feat_ids, protocol_id)
    if not matched:
        acc.set_levels("UNKNOWN", KERNEL_LEVELS)
        acc.reason("UNKNOWN_CAPABILITY")
        acc.note_unknown(f"{target.kernel} × {sorted(feat_ids)}",
                         "注册表里没有覆盖该组合的规则")
    version = parse_version(target.version)
    # 节点自身显式带来的运行期条件（缺省来源; 目标端自报的优先）
    facts, facts_why = _profile_runtime_facts(profile)
    for rule in matched:
        seg = _segment_for(rule, version, acc, target)
        if seg is None:
            for lv in ("config", "runtime", "semantic"):
                acc.set_level(lv, "UNKNOWN")
            acc.reason("UNKNOWN_CAPABILITY")
            continue
        _apply_segment(rule, seg, acc, target, facts, facts_why)

    # ---------------- 3. URI 表达力（独立第三张表）
    _apply_uri_rules(profile, scheme, acc, registry)

    # ---------------- 3.4 未知命名空间的 feature: 必须 UNKNOWN
    covered = set()
    for r in matched:
        sel = r.selector or {}
        for key in ("feature", "protocol"):
            if sel.get(key):
                covered.add(sel[key])
        covered.update(sel.get("all_of_features") or [])
    for fid in sorted(feat_ids):
        ns = fid.split(":", 1)[0]
        if ns in ("standard",) or fid in covered:
            continue
        acc.set_levels("UNKNOWN", KERNEL_LEVELS)
        acc.reason("UNKNOWN_CAPABILITY")
        acc.note_unknown(f"feature {fid}",
                         "该扩展 feature 没有任何能力规则（未知 ≠ 不支持）")

    # ---------------- 3.5 R1: 推断证据不得单独支撑 SUPPORTED
    for rid in acc.rules:
        rule = next((r for r in registry.rules if r.rule_id == rid), None)
        if rule is None or not rule.evidence:
            continue
        evs = [registry.evidence.get(e) for e in rule.evidence]
        evs = [e for e in evs if e is not None]
        if evs and all(e.type == "INFERENCE" for e in evs):
            for lv in LEVELS:
                if acc.levels[lv] == "SUPPORTED":
                    acc.levels[lv] = "SUPPORTED_WITH_WARNING"
            acc.warnings.append({
                "code": "INFERENCE_ONLY_EVIDENCE",
                "detail": f"{rid} 仅有 INFERENCE 证据 —— 按 R1 不得判为无警告的 SUPPORTED",
                "rule": rid})

    # ---------------- 4. 汇总
    levels = {lv: (acc.levels[lv] or "UNKNOWN") for lv in LEVELS}
    for lv in LEVELS:
        if lv not in acc.explicit:
            acc.note_unknown(f"层级 {lv}", "没有任何证据覆盖该层级")
    # 总状态只看"显式判定过"的层级 —— 未覆盖的层级报 UNKNOWN, 但不该拖累
    # 已独立验证的结论（用户 4B 节: 缺信息只影响它真正影响的判断）。
    kernel_statuses = [acc.levels[lv] for lv in KERNEL_LEVELS if lv in acc.explicit]
    status = "UNKNOWN" if not kernel_statuses else kernel_statuses[0]
    for st in kernel_statuses[1:]:
        status = _worst(status, st) or status
    # URI 层: 表达力损失要并入; 但"没有 URI 规则"只是未知 → 降为 warning,
    # 不能把已独立验证的内核侧结论一起吞掉。
    if "uri" in acc.explicit:
        ustat = acc.levels["uri"]
        if ustat == "UNKNOWN":
            # 只作为 UNKNOWN 记录（levels.uri + unknowns），不降级总状态：
            # "我们没有这条 URI 规则" 与 "URI 表达不了" 是两件事。
            pass
        else:
            status = _worst(status, ustat) or status
    if acc.failure_mode in ("silent_ignore", "silent_drop") and status == "SUPPORTED":
        status = "SUPPORTED_WITH_LOSS"
    if status == "SUPPORTED" and acc.warnings:
        status = "SUPPORTED_WITH_WARNING"
    return EvaluationResult(
        status=status, levels=levels,
        reason_codes=sorted(set(acc.reasons)), message="; ".join(acc.messages),
        failure_mode=acc.failure_mode, losses=acc.losses, warnings=acc.warnings,
        unknowns=acc.unknowns,
        detected_features=[{"id": f.id, "presence": f.presence.value}
                           for f in profile.features]
        + ([{"id": profile.protocol.id, "presence": profile.protocol.presence.value}]
           if profile.protocol else []),
        evidence=registry.evidence_of(acc.evidence),
        raw_uri=profile.raw_uri, rules_applied=acc.rules)


def _scheme_of(profile: NodeProfile) -> str | None:
    if profile.source_format == "URI" and profile.raw_uri:
        return profile.raw_uri.split("://", 1)[0].lower()
    fmt = (profile.source_format or "").lower()
    return {"xray_json": "xray-json", "mihomo_yaml": "mihomo-yaml",
            "singbox_json": "singbox-json"}.get(fmt)


def _apply_uri_rules(profile: NodeProfile, scheme: str | None,
                     acc: _Acc, registry: Registry) -> None:
    """URI 层独立判定: 内核支持 ≠ URI 能表达。"""
    if scheme is None:
        acc.set_level("uri", "UNKNOWN")
        acc.note_unknown("层级 uri", "不知道原始格式, 无法判断表达力")
        return
    known = False
    for feat in profile.features:
        rule = registry.uri_rule(scheme, feat.id)
        if rule is None:
            continue
        known = True
        rep = rule.get("representation")
        if rep == "FULL":
            acc.set_level("uri", "SUPPORTED")
        else:
            acc.set_level("uri", "SUPPORTED_WITH_LOSS")
            for loss in rule.get("loss") or []:
                acc.losses.append({"feature": loss.get("field", feat.id),
                                   "what": loss.get("what", "URI 无法表达"),
                                   "impact": "CONNECTIVITY",
                                   "rule": rule.get("uri_rule_id", scheme)})
        acc.evidence.extend(rule.get("evidence") or [])
    if not known:
        acc.set_level("uri", "UNKNOWN")
        acc.note_unknown(f"层级 uri（scheme={scheme}）",
                         "没有覆盖该 scheme × feature 的 URI 表达力规则")
