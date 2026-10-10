"""Phase 4A · Universal Node Profile（内核无关）。

三条不可弱化的约束（见 docs/universal-node-profile.md）:
  I1  raw_uri 与 raw_fields 在整条流水线上字节不变
  I2  任何被读取但未建模的键, 必须出现在 extensions[] 或 raw_fields 中
  I7  本模块产出的 profile **不含任何内核版本字段**
"""

from __future__ import annotations

from dataclasses import dataclass, field as dc_field
from enum import Enum
from typing import Any


class Presence(str, Enum):
    """字段状态。null 无法区分这五种, 所以必须显式。"""

    ABSENT = "ABSENT"        # 输入里根本没有
    EXPLICIT = "EXPLICIT"    # 输入里明确写了（含空串/false/0）
    DEFAULTED = "DEFAULTED"  # 没写, 但协议/规范给了默认值
    INFERRED = "INFERRED"    # 由其它信息推断
    UNKNOWN = "UNKNOWN"      # 上游已把 presence 抹平, 无法确定


class Provenance(str, Enum):
    URI = "URI"
    XRAY_JSON = "XRAY_JSON"
    MIHOMO_YAML = "MIHOMO_YAML"
    SINGBOX_JSON = "SINGBOX_JSON"
    SUBSCRIPTION = "SUBSCRIPTION"
    INFERRED = "INFERRED"
    USER_DEFINED = "USER_DEFINED"
    EXTENSION = "EXTENSION"


# provenance 冲突时的优先级（高 → 低）
PROVENANCE_RANK = [
    Provenance.USER_DEFINED, Provenance.URI, Provenance.SUBSCRIPTION,
    Provenance.XRAY_JSON, Provenance.MIHOMO_YAML, Provenance.SINGBOX_JSON,
    Provenance.EXTENSION, Provenance.INFERRED,
]

# 允许的 feature 命名空间前缀写法: standard / <vendor> / custom / unknown
_ALLOWED_ROOTS = ("standard", "custom", "unknown")


def valid_feature_id(fid: str) -> bool:
    if not isinstance(fid, str) or ":" not in fid:
        return False
    ns, _, name = fid.partition(":")
    if not ns or not name:
        return False
    # standard / custom / unknown / <vendor>（vendor 名允许字母数字与 - _）
    return ns in _ALLOWED_ROOTS or all(c.isalnum() or c in "-_" for c in ns)


@dataclass
class Field:
    """带 presence + provenance 的字段。presence=ABSENT 时 v 必须为 None。"""

    presence: Presence
    v: Any = None
    provenance: Provenance | None = None
    raw_key: str | None = None
    basis: str | None = None          # presence=INFERRED 时必填

    def __post_init__(self) -> None:
        if self.presence is Presence.ABSENT and self.v is not None:
            raise ValueError("presence=ABSENT 时不允许有值")
        if self.presence is Presence.INFERRED and not self.basis:
            raise ValueError("presence=INFERRED 必须给 basis（推断依据）")

    @staticmethod
    def absent() -> "Field":
        return Field(Presence.ABSENT)

    @staticmethod
    def explicit(v: Any, prov: Provenance = Provenance.URI,
                 raw_key: str | None = None) -> "Field":
        return Field(Presence.EXPLICIT, v, prov, raw_key)

    @staticmethod
    def defaulted(v: Any, why: str) -> "Field":
        return Field(Presence.DEFAULTED, v, Provenance.INFERRED, basis=why)

    def to_dict(self) -> dict:
        d: dict[str, Any] = {"presence": self.presence.value}
        if self.presence is not Presence.ABSENT:
            d["v"] = self.v
        if self.provenance is not None:
            d["provenance"] = self.provenance.value
        if self.raw_key is not None:
            d["raw_key"] = self.raw_key
        if self.basis is not None:
            d["basis"] = self.basis
        return d

    @staticmethod
    def from_dict(d: dict) -> "Field":
        return Field(
            presence=Presence(d["presence"]),
            v=d.get("v"),
            provenance=Provenance(d["provenance"]) if d.get("provenance") else None,
            raw_key=d.get("raw_key"),
            basis=d.get("basis"),
        )


@dataclass
class Feature:
    """能力一等公民。组合不折叠: vless + reality + xhttp 是三个 feature。"""

    id: str
    presence: Presence = Presence.EXPLICIT
    provenance: Provenance | None = None
    params: dict[str, Field] = dc_field(default_factory=dict)
    requires: list[str] = dc_field(default_factory=list)
    excludes: list[str] = dc_field(default_factory=list)
    note: str | None = None

    def __post_init__(self) -> None:
        if not valid_feature_id(self.id):
            raise ValueError(f"feature id 不符合命名空间语法: {self.id!r}")

    def to_dict(self) -> dict:
        d: dict[str, Any] = {"id": self.id, "presence": self.presence.value}
        if self.provenance is not None:
            d["provenance"] = self.provenance.value
        if self.params:
            d["params"] = {k: v.to_dict() for k, v in self.params.items()}
        if self.requires:
            d["requires"] = list(self.requires)
        if self.excludes:
            d["excludes"] = list(self.excludes)
        if self.note:
            d["note"] = self.note
        return d

    @staticmethod
    def from_dict(d: dict) -> "Feature":
        return Feature(
            id=d["id"],
            presence=Presence(d.get("presence", "EXPLICIT")),
            provenance=Provenance(d["provenance"]) if d.get("provenance") else None,
            params={k: Field.from_dict(v) for k, v in (d.get("params") or {}).items()},
            requires=list(d.get("requires") or []),
            excludes=list(d.get("excludes") or []),
            note=d.get("note"),
        )


@dataclass
class NodeProfile:
    """内核无关的节点描述。**不含任何内核版本字段**（不变式 I7）。"""

    profile_version: int = 1
    protocol: Feature | None = None
    features: list[Feature] = dc_field(default_factory=list)
    endpoint: dict[str, Field] = dc_field(default_factory=dict)
    auth: dict[str, Field] = dc_field(default_factory=dict)
    metadata: dict[str, Field] = dc_field(default_factory=dict)
    extensions: list[dict] = dc_field(default_factory=list)
    diagnostics: list[dict] = dc_field(default_factory=list)
    raw_uri: str | None = None
    raw_fields: dict[str, Any] = dc_field(default_factory=dict)
    source_format: str | None = None

    # ---------------------------------------------------------------- 查询
    def feature_ids(self) -> list[str]:
        ids = [f.id for f in self.features]
        if self.protocol is not None:
            ids.append(self.protocol.id)
        return ids

    def get_feature(self, fid: str) -> Feature | None:
        if self.protocol is not None and self.protocol.id == fid:
            return self.protocol
        for f in self.features:
            if f.id == fid:
                return f
        return None

    def field(self, group: str, key: str) -> Field | None:
        return getattr(self, group, {}).get(key)

    def explicit_value(self, group: str, key: str) -> Any:
        f = self.field(group, key)
        return f.v if f is not None and f.presence is Presence.EXPLICIT else None

    # ---------------------------------------------------------------- 登记
    def add_feature(self, feat: Feature) -> None:
        for i, existing in enumerate(self.features):
            if existing.id == feat.id:
                merged = dict(existing.params)
                merged.update(feat.params)
                self.features[i] = Feature(
                    id=existing.id, presence=existing.presence,
                    provenance=existing.provenance, params=merged,
                    requires=existing.requires or feat.requires,
                    excludes=existing.excludes or feat.excludes,
                    note=existing.note or feat.note)
                self.diagnostics.append({
                    "code": "FEATURE_MERGED",
                    "detail": f"{feat.id} 重复出现, 参数已合并"})
                return
        self.features.append(feat)

    def add_extension(self, key: str, value: Any, source: str,
                      note: str | None = None) -> None:
        """未建模的键登记到 extensions（不变式 I2）。绝不进入生成物。"""
        for e in self.extensions:
            if e.get("key") == key:
                return
        entry = {"key": key, "value": value, "source": source}
        if note:
            entry["note"] = note
        self.extensions.append(entry)
        self.diagnostics.append({
            "code": "UNKNOWN_PARAM_KEPT",
            "detail": f"{key} 已存入 extensions, 不会进入任何生成物"})

    # ---------------------------------------------------------------- 校验
    def check_invariants(self) -> list[str]:
        problems: list[str] = []
        if self.raw_uri is None and not self.raw_fields:
            problems.append("I1: raw 区完全为空 —— 无法证明原文被保留")
        for group in ("endpoint", "auth", "metadata"):
            for k, f in getattr(self, group).items():
                if f.presence is Presence.INFERRED and not f.basis:
                    problems.append(f"I3: {group}.{k} 是 INFERRED 但缺 basis")
                if f.presence is Presence.ABSENT:
                    problems.append(f"I4: {group}.{k} 不该以 ABSENT 形式存在")
        for feat in self.features:
            if feat.provenance is Provenance.INFERRED and feat.params:
                for pk, pf in feat.params.items():
                    if pf.presence is Presence.INFERRED and not pf.basis:
                        problems.append(f"I3: {feat.id}.{pk} 缺 basis")
        if len(set(self.feature_ids())) != len(self.feature_ids()):
            problems.append("I6: feature id 重复")
        return problems

    # ---------------------------------------------------------------- 序列化
    def to_dict(self) -> dict:
        return {
            "profile_version": self.profile_version,
            "protocol": self.protocol.to_dict() if self.protocol else None,
            "features": [f.to_dict() for f in self.features],
            "endpoint": {k: v.to_dict() for k, v in self.endpoint.items()},
            "auth": {k: v.to_dict() for k, v in self.auth.items()},
            "metadata": {k: v.to_dict() for k, v in self.metadata.items()},
            "extensions": list(self.extensions),
            "diagnostics": list(self.diagnostics),
            "raw": {"uri": self.raw_uri, "source_format": self.source_format,
                    "fields": dict(self.raw_fields)},
        }

    @staticmethod
    def from_dict(d: dict) -> "NodeProfile":
        raw = d.get("raw") or {}
        return NodeProfile(
            profile_version=d.get("profile_version", 1),
            protocol=Feature.from_dict(d["protocol"]) if d.get("protocol") else None,
            features=[Feature.from_dict(f) for f in (d.get("features") or [])],
            endpoint={k: Field.from_dict(v) for k, v in (d.get("endpoint") or {}).items()},
            auth={k: Field.from_dict(v) for k, v in (d.get("auth") or {}).items()},
            metadata={k: Field.from_dict(v) for k, v in (d.get("metadata") or {}).items()},
            extensions=list(d.get("extensions") or []),
            diagnostics=list(d.get("diagnostics") or []),
            raw_uri=raw.get("uri"),
            raw_fields=dict(raw.get("fields") or {}),
            source_format=raw.get("source_format"),
        )

    def roundtrip(self) -> "NodeProfile":
        """序列化 → 反序列化。用于测试'不静默丢信息'。"""
        return NodeProfile.from_dict(self.to_dict())
