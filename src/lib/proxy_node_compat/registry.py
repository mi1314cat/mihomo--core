"""Phase 4B · Capability Registry（证据决定精度）。

核心不是"每个版本一条记录", 而是 **Capability Rule**:
  * 有证据给出边界 → segments 里写确切范围
  * 只知道两端     → 两端各一段 + transition: UNKNOWN + unknown_range（禁止补中间版本号）
  * 完全没有版本信息 → evidence_only: true → 任何版本都是 UNKNOWN
  * 版本无关的事实 → version_independent: true（如"某内核全树从未出现该字段"）

缺版本时不抹掉无关结论: version_independent 的规则照常判定（用户第 4B 节明确要求）。
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field as dc_field
from typing import Any


# --------------------------------------------------------------------- 版本
def parse_version(text: Any) -> tuple[int, ...] | None:
    """'1.19.32' / 'v26.3.27' → (1,19,32)。解析不了就 None（不是 0）。"""
    if isinstance(text, (tuple, list)):
        return tuple(int(x) for x in text)
    if text is None:
        return None
    s = str(text).strip().lstrip("vV")
    if not s:
        return None
    parts = s.split(".")
    out: list[int] = []
    for p in parts:
        num = ""
        for ch in p:
            if ch.isdigit():
                num += ch
            else:
                break
        if num == "":
            break
        out.append(int(num))
    return tuple(out) if out else None


def _cmp(a: tuple[int, ...], b: tuple[int, ...]) -> int:
    n = max(len(a), len(b))
    a2 = a + (0,) * (n - len(a))
    b2 = b + (0,) * (n - len(b))
    return (a2 > b2) - (a2 < b2)


def version_in_range(version: tuple[int, ...] | None, spec: str) -> bool:
    """支持 '<1.2' '< 1.2' '<=1.2' '>1.2' '>=1.2' '=1.2' '*'
    以及逗号组合 '>1.18.0, <1.19.32'。version=None 时**恒为 False**（不猜）。"""
    if version is None:
        return False
    spec = (spec or "").strip()
    if spec in ("", "*"):
        return True
    for part in [p.strip() for p in spec.split(",") if p.strip()]:
        op = "="
        for cand in ("<=", ">=", "<", ">", "==", "="):
            if part.startswith(cand):
                op = "=" if cand == "==" else cand
                part = part[len(cand):].strip()
                break
        bound = parse_version(part)
        if bound is None:
            return False
        c = _cmp(version, bound)
        ok = {"<": c < 0, "<=": c <= 0, ">": c > 0, ">=": c >= 0, "=": c == 0}[op]
        if not ok:
            return False
    return True


# --------------------------------------------------------------------- 规则
CTX_KEYS = ("version", "build_tags", "platform", "runtime_options")


@dataclass
class Segment:
    range: str = "*"
    verdict: dict[str, str] = dc_field(default_factory=dict)   # level -> status
    failure_mode: str | None = None
    reason_code: str | None = None
    losses: list[dict] = dc_field(default_factory=list)
    warnings: list[dict] = dc_field(default_factory=list)
    requires_build_tags: list[str] = dc_field(default_factory=list)
    runtime_condition: dict[str, Any] | None = None
    condition: dict[str, Any] | None = None
    note: str | None = None

    @staticmethod
    def from_dict(d: dict) -> "Segment":
        return Segment(**{k: v for k, v in d.items() if k in Segment.__dataclass_fields__})


@dataclass
class Rule:
    rule_id: str
    target: dict[str, Any] = dc_field(default_factory=dict)
    selector: dict[str, Any] = dc_field(default_factory=dict)
    segments: list[Segment] = dc_field(default_factory=list)
    transition: str | None = None            # KNOWN | UNKNOWN
    unknown_range: list[dict] = dc_field(default_factory=list)
    evidence_only: bool = False              # 完全没有版本信息
    version_independent: bool = False        # 与版本无关的事实
    evidence: list[str] = dc_field(default_factory=list)
    unknown_distribution_policy: str = "UNKNOWN"
    constraint: dict[str, Any] | None = None
    mismatch: str | None = None
    reason_code: str | None = None
    message: str | None = None

    def applies_to(self, kernel: str, distribution: str | None) -> bool:
        return self.target.get("kernel") == kernel

    def distribution_ok(self, distribution: str | None) -> bool:
        want = self.target.get("distribution")
        if want in (None, "*"):
            return True
        return want == (distribution or "upstream")

    def selector_matches(self, feature_ids: set[str], protocol_id: str | None) -> bool:
        sel = self.selector or {}
        if "feature" in sel and sel["feature"] not in feature_ids:
            return False
        if "protocol" in sel and sel["protocol"] != protocol_id:
            return False
        allof = sel.get("all_of_features") or []
        if allof and not set(allof).issubset(feature_ids):
            return False
        if not any(k in sel for k in ("feature", "protocol", "all_of_features")):
            return False
        return True

    @staticmethod
    def from_dict(d: dict) -> "Rule":
        segs = [Segment.from_dict(s) for s in (d.get("segments") or [])]
        return Rule(
            rule_id=d["rule_id"], target=d.get("target") or {},
            selector=d.get("selector") or {}, segments=segs,
            transition=d.get("transition"), unknown_range=d.get("unknown_range") or [],
            evidence_only=bool(d.get("evidence_only")),
            version_independent=bool(d.get("version_independent")),
            evidence=d.get("evidence") or [],
            unknown_distribution_policy=d.get("unknown_distribution_policy", "UNKNOWN"),
            constraint=d.get("constraint"), mismatch=d.get("mismatch"),
            reason_code=d.get("reason_code"), message=d.get("message"))


@dataclass
class Evidence:
    id: str
    type: str
    confidence: str
    date: str = ""
    claim: str = ""
    how: str = ""
    where: str = ""
    limits: str = ""

    @staticmethod
    def from_dict(d: dict) -> "Evidence":
        return Evidence(**{k: v for k, v in d.items() if k in Evidence.__dataclass_fields__})


# ---------------------------------------------------------------- URI 规则字段
#
# 这张表是**必需**的，不是为了整洁：`rules.json` 是公开数据文件，谁都能往里加字段，
# 而"加了字段但没有任何代码读它"是**最难发现的一类失真** —— 数据看起来记录了
# 一个事实（例如"这个参数是哪版进规范的"），判定却完全不用它，读者会以为这层
# 的精度比实际高。所以：
#
#   · 读得出的字段 → 必须在 `URI_RULE_KEYS` 里；
#   · 读得出但这个版本**不参与判定**的字段 → 列进 `URI_RULE_INFORMATIONAL`，
#     由引擎原样带进结果、由 CLI 打出来（**显式告诉用户"它不影响结论"**），
#     而不是悄悄躺在 JSON 里；
#   · 认不出的字段 → `Registry.load` 直接**报错**，不许静默忽略。
#
# 已知的"读得出但不参与判定"的三个（都由 URI 规则携带、经 result.informational 透出）：
#   carrier        这条参数靠哪种链接形态承载（用于解释"为什么换个格式就丢了"）
#   spec_added_at  该参数是哪个版本的链接规范引入的（**规范事实**，不是内核能力边界；
#                  本实现不做基于它的判定，"版本边界未知就不许补"这条同样适用于它）
#   workaround     有损时的可用绕行（例如"改用原生 YAML/JSON 格式"）
URI_RULE_KEYS = {
    "uri_rule_id", "scheme", "feature", "target_kernel", "representation",
    "loss", "note", "evidence",
    "carrier", "spec_added_at", "workaround",
}
URI_RULE_INFORMATIONAL = ("carrier", "spec_added_at", "workaround")


class Registry:
    def __init__(self, rules: list[Rule], uri_rules: list[dict],
                 evidence: dict[str, Evidence]):
        self.rules = rules
        self.uri_rules = uri_rules
        self.evidence = evidence

    @staticmethod
    def load(path: str) -> "Registry":
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        ev = {e["id"]: Evidence.from_dict(e) for e in (data.get("evidence") or [])}
        for rule in (data.get("rules") or []):
            for eid in rule.get("evidence") or []:
                if eid not in ev:
                    raise ValueError(f"{rule['rule_id']} 引用了不存在的证据: {eid}")
        # URI 规则：认不出的键必须报错 —— 静默忽略等于"数据里写了、判定里没有"
        for ur in (data.get("uri_rules") or []):
            unknown = sorted(set(ur) - URI_RULE_KEYS)
            if unknown:
                raise ValueError(
                    "%s 里有认不出的字段 %s —— 要么它应该被引擎读（那就一起改引擎与 "
                    "URI_RULE_KEYS），要么它只是给人看的（那就列进 URI_RULE_INFORMATIONAL "
                    "并由 result.informational 透出）。不许静默躺在数据里。"
                    % (ur.get("uri_rule_id", "?"), unknown))
        return Registry(
            rules=[Rule.from_dict(r) for r in (data.get("rules") or [])],
            uri_rules=data.get("uri_rules") or [],
            evidence=ev)

    # ------------------------------------------------------------------ 查询
    def rules_for(self, kernel: str, distribution: str | None,
                  feature_ids: set[str], protocol_id: str | None) -> list[Rule]:
        out = []
        for r in self.rules:
            if not r.applies_to(kernel, distribution):
                continue
            if not r.distribution_ok(distribution):
                continue
            if r.selector_matches(feature_ids, protocol_id):
                out.append(r)
        return out

    def kernel_has_distribution_rule(self, kernel: str, distribution: str | None) -> bool:
        if distribution in (None, "upstream"):
            return True
        return any(r.target.get("kernel") == kernel
                   and r.target.get("distribution") == distribution for r in self.rules)

    def uri_rule(self, scheme: str, feature: str,
                 kernel: str | None = None) -> dict | None:
        """取 (scheme × feature) 的 URI 表达力规则。

        `target_kernel` 存在的意义: "URI 表达力"分两层 ——
          (1) 链接格式本身装不装得下这个参数(全局, 不带 target_kernel)
          (2) 某个内核的链接解析**实现**读不读它(带 target_kernel, 只对该内核生效)
        例: mihomo 的 trojan 分支不读 pbk/sid, 而同一条 trojan:// 链接
        Xray/sing-box 都能用 —— 那一行绝不能外溢。
        未给 kernel 时忽略所有带 target_kernel 的行(不猜, 不拿别家的结论顶替)。
        """
        fallback = None
        for u in self.uri_rules:
            if u.get("scheme") != scheme or u.get("feature") != feature:
                continue
            if u.get("target_kernel"):
                if kernel is not None and u["target_kernel"] == kernel:
                    return u
                continue
            if fallback is None:
                fallback = u
        return fallback

    def uri_rules_for_scheme(self, scheme: str) -> list[dict]:
        return [u for u in self.uri_rules if u.get("scheme") == scheme]

    def evidence_of(self, ids: list[str]) -> list[dict]:
        return [self.evidence[i].__dict__ for i in ids if i in self.evidence]


def default_registry_path() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "rules.json")
