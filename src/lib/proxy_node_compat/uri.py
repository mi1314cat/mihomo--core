"""Phase 4C · URI 解析与表达能力。

纪律:
  * 解析成功 ≠ 内核支持（本模块只产出 profile, 不做兼容性判断）
  * 原始 URI 与无法识别的参数必须可追溯（raw.uri / raw.fields / extensions）
  * 未知 scheme 也必须能保存并标记, 不能让整批解析失败
  * 回写时: INFERRED 字段不写、extensions 默认不写（除非显式 allow_extensions）
  * 绝不改换传输方式（xhttp 不会变成 ws）
"""

from __future__ import annotations

import base64
import json
from urllib.parse import quote, unquote, urlsplit

from .model import Field, Feature, NodeProfile, Presence, Provenance

# scheme -> (protocol feature id, 已知参数集合)
SCHEMES: dict[str, tuple[str, set[str]]] = {
    "vless": ("standard:vless", {
        "type", "security", "sni", "servername", "alpn", "fp", "flow", "path", "host",
        "mode", "serviceName", "headerType", "seed", "pbk", "sid", "spx", "ech", "pqv",
        "pcs", "vcn", "fm", "encryption", "allowInsecure", "insecure", "extra", "mtu", "tti"}),
    "vmess": ("standard:vmess", {
        # vmess:// 的载荷是 base64(JSON), 键名按生态通用写法（v2rayN / Shadowrocket / mihomo）
        "v", "ps", "add", "port", "id", "uuid", "aid", "scy", "net", "type", "host",
        "path", "tls", "sni", "alpn", "fp", "security", "allowInsecure", "insecure"}),
    "trojan": ("standard:trojan", {
        "type", "security", "sni", "alpn", "fp", "path", "host", "serviceName",
        "allowInsecure", "insecure", "pbk", "sid", "spx", "ech"}),
    "hysteria2": ("standard:hysteria2", {
        "sni", "insecure", "obfs", "obfs-password", "pinSHA256", "alpn", "mport", "ech"}),
    "hy2": ("standard:hysteria2", {"sni", "insecure", "obfs", "obfs-password", "pinSHA256"}),
    "tuic": ("standard:tuic", {"sni", "alpn", "congestion_control", "udp_relay_mode",
                              "allow_insecure", "insecure", "zero_rtt_handshake"}),
    "anytls": ("standard:anytls", {"sni", "insecure", "fp", "alpn"}),
    "socks": ("standard:socks", {"type"}),
    "socks5": ("standard:socks", {"type"}),
    "http": ("standard:http", {"type"}),
    "https": ("standard:http", {"type"}),
    "ss": ("standard:shadowsocks", {"plugin", "type", "security", "pbk", "sid", "spx"}),
}

# 哪些 query 参数对应哪个 feature
SECURITY_PARAMS = {"security": None, "tls": "standard:tls", "reality": "standard:reality"}
TRANSPORT_MAP = {
    "tcp": "standard:transport.tcp", "raw": "standard:transport.tcp",
    "ws": "standard:transport.ws", "websocket": "standard:transport.ws",
    "grpc": "standard:transport.grpc", "gun": "standard:transport.grpc",
    "h2": "standard:transport.http_h2", "http": "standard:transport.http_h2",
    "httpupgrade": "standard:transport.httpupgrade",
    "xhttp": "standard:xhttp", "splithttp": "standard:xhttp",
    "kcp": "standard:mkcp", "mkcp": "standard:mkcp", "quic": "standard:transport.quic",
}

# 这些参数属于哪个 feature 的 params（用于把值挂到正确的 feature 上）
PARAM_OWNER = {
    "path": "transport", "host": "transport", "serviceName": "transport",
    "mode": "transport", "extra": "transport", "headerType": "transport",
    "seed": "transport", "mtu": "transport", "tti": "transport",
    "pbk": "standard:reality", "sid": "standard:reality", "spx": "standard:reality",
    "ech": "standard:ech", "pcs": "standard:ech", "vcn": "standard:ech",
    "pqv": "standard:reality",
    "sni": "standard:tls", "servername": "standard:tls", "alpn": "standard:tls",
    "fp": "standard:tls", "allowInsecure": "standard:tls", "insecure": "standard:tls",
    "flow": "standard:flow",
    "mux": "standard:mux", "mux-enabled": "standard:mux", "smux": "standard:mux",
    "allowInsecure": "standard:tls.allow_insecure", "insecure": "standard:tls.allow_insecure", "obfs": "standard:hysteria2.obfs",
    "obfs-password": "standard:hysteria2.obfs", "pinSHA256": "standard:tls",
    "plugin": "standard:shadowsocks.plugin",
}

# vmess:// 载荷(JSON)里已被解析器消费的键 —— 不再走"参数归属"循环。
# 注意: **不包含 "v"**（载荷格式版本号）—— 它读了但没建模, 必须走循环落进 extensions,
# 而不是被这里静默吃掉（不变式 I2: 读了未建模的键至少要在 extensions[] 或 raw.fields 里）。
_VMESS_CONSUMED = {"ps", "add", "port", "id", "uuid", "aid", "scy", "security",
                   "net", "tls"}

# security=reality 时, 这些 query 键是 REALITY 的握手身份 → 挂到 standard:reality 的 params
# （键名用 universal-node-profile.md §1 的写法: server_name / fingerprint），
# 而不是掉进 extensions 变成"未建模"。
_REALITY_IDENTITY = {"sni": "server_name", "servername": "server_name", "fp": "fingerprint"}

# 回写 vmess:// 时允许进入 JSON 的键（VMess QR 的字段集, 含 id/uuid 两种别名写法）。
# 依据: docs/uri-representation.md §1 —— VMess QR 只有固定字段, reality/ech 等塞不进去,
# 因此这些 feature 的参数**不写回**（该损失由 URI 表达力规则逐条报告, 不在这里伪造）。
_VMESS_QR_KEYS = ("v", "ps", "add", "port", "id", "uuid", "aid", "scy", "security", "net",
                  "type", "host", "path", "tls", "sni", "alpn", "fp")
_VMESS_NET = {"standard:transport.tcp": "tcp", "standard:transport.ws": "ws",
              "standard:transport.grpc": "grpc", "standard:transport.http_h2": "h2",
              "standard:transport.httpupgrade": "httpupgrade",
              "standard:transport.quic": "quic", "standard:mkcp": "kcp",
              "standard:xhttp": "xhttp"}


def _b64pad(s: str) -> str:
    return s + "=" * (-len(s) % 4)


def _b64decode_text(text: str) -> str:
    """容忍 %XX 转义 / 标准或 urlsafe 字母表 / 缺省 padding 的 base64 解码。"""
    return base64.urlsafe_b64decode(_b64pad(unquote(text.strip()))).decode("utf-8")


def _vmess_payload(uri: str) -> str:
    """取出 vmess:// 的 base64 载荷。

    **不能用 urlsplit().hostname** —— hostname 会被小写化, 而 base64 大小写敏感。
    """
    body = uri.split("://", 1)[1] if "://" in uri else ""
    return body.split("#", 1)[0].split("?", 1)[0].strip()


def _decode_vmess_body(uri: str) -> dict | None:
    """base64(JSON) → dict。解不出来返回 None（绝不抛错拖垮整批）。"""
    payload = _vmess_payload(uri)
    if not payload:
        return None
    candidates = [payload]
    if payload.endswith("/"):          # 个别客户端会在末尾补一个 '/'
        candidates.append(payload[:-1])
    for cand in candidates:
        try:
            obj = json.loads(_b64decode_text(cand))
        except Exception:
            continue
        if isinstance(obj, dict):
            return obj
    return None


def _first_present(cfg: dict, *keys: str) -> tuple[str | None, object]:
    """返回第一个非空值 + 它在原文里的键名（生态里 id/uuid、scy/security 两种写法并存）。"""
    for k in keys:
        if cfg.get(k) not in (None, ""):
            return k, cfg[k]
    return None, None


def _port_value(v: object) -> object:
    """生态里 port 常写成字符串（"443"），能转 int 就转, 不能就原样保留。"""
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return v


def _parse_query(query: str) -> dict[str, object]:
    """按分享链接规范的语义解析 query（encodeURIComponent: 空格是 %20, '+' 是字面量）。

    **不用 parse_qsl** —— 它按 form-encoding 把 '+' 解成空格。真实链接里的
    `ech=AGH+DQBd…` / base64 取值含 '+', 用 parse_qsl 会在**解析期**就把原文改掉
    （违反 I1「raw.fields 字节不变」, 且会让客户端拿到被破坏的 ech/pbk 值）。
    """
    fields: dict[str, object] = {}
    for chunk in query.split("&"):
        if not chunk:
            continue
        k, _, v = chunk.partition("=")
        fields[unquote(k)] = unquote(v)
    return fields


def parse_uri(uri: str) -> NodeProfile:
    """解析分享链接。未知 scheme / 未知参数都不会导致失败。"""
    uri = uri.strip()
    parts = urlsplit(uri)
    scheme = (parts.scheme or "").lower()
    raw_fields: dict[str, object] = _parse_query(parts.query)
    frag_text = unquote(parts.fragment) if parts.fragment else ""

    profile = NodeProfile(raw_uri=uri, source_format="URI", raw_fields=raw_fields)

    if frag_text:
        profile.metadata["name"] = Field.explicit(frag_text, Provenance.URI, "#")

    if scheme not in SCHEMES:
        # ★ 未知协议也要能保存并标记
        profile.protocol = Feature(id=f"unknown:{scheme or 'noscheme'}",
                                   presence=Presence.EXPLICIT,
                                   provenance=Provenance.URI)
        for k, v in raw_fields.items():
            profile.add_extension(k, v, "URI", "未知协议, 参数原样保留")
        if parts.hostname:
            profile.endpoint["host"] = Field.explicit(parts.hostname, Provenance.URI, "host")
        if parts.port:
            profile.endpoint["port"] = Field.explicit(parts.port, Provenance.URI, "port")
        profile.diagnostics.append({"code": "UNKNOWN_SCHEME",
                                    "detail": f"未收录的 scheme: {scheme}"})
        return profile

    proto_id, known = SCHEMES[scheme]
    profile.protocol = Feature(id=proto_id, presence=Presence.EXPLICIT,
                               provenance=Provenance.URI)

    host = parts.hostname or ""
    q: dict[str, object] = dict(raw_fields)
    transport_key = "type"      # 用哪个键选传输（vmess JSON 里是 net）
    sec_key = "security"        # 用哪个键选安全层（vmess JSON 的 security 是加密方式, TLS 看 tls）
    consumed = {"type", "security", "encryption"}   # 已消费的键, 不再走参数归属循环

    if scheme == "vmess":
        # ★ vmess://: 载荷是 base64(JSON), 不在 query 里
        cfg = _decode_vmess_body(uri)
        if cfg is None:
            # 解不出来也要能保存并标记（不丢、不猜、不让整批解析失败）:
            # 载荷本身进 raw.fields, 同时登记一个 unknown: feature —— 引擎据此判 UNKNOWN,
            # 不会被"protocol=standard:vmess"骗成 SUPPORTED（未知 ≠ 支持）。
            profile.raw_fields["_vmess_body"] = _vmess_payload(uri)
            profile.add_feature(Feature(
                id="unknown:vmess.body-unparsed", presence=Presence.EXPLICIT,
                provenance=Provenance.URI,
                note="vmess 载荷无法解码为 JSON: 只登记原文, 不猜任何字段"))
            profile.diagnostics.append({
                "code": "VMESS_BODY_UNPARSED",
                "detail": "base64(JSON) 载荷无法解码; 原文保留在 raw.uri 与 raw.fields._vmess_body"})
            return profile
        q = dict(cfg)
        profile.raw_fields = dict(cfg)          # 原始键值原样保存（含未知键, I1）
        transport_key, sec_key = "net", "tls"
        consumed = set(_VMESS_CONSUMED)
        if cfg.get("add") not in (None, ""):
            profile.endpoint["host"] = Field.explicit(cfg["add"], Provenance.URI, "add")
        if cfg.get("port") not in (None, ""):
            profile.endpoint["port"] = Field.explicit(_port_value(cfg["port"]),
                                                      Provenance.URI, "port")
        rid, vm_id = _first_present(cfg, "id", "uuid")     # 两种写法都要认
        if rid:
            profile.auth["uuid"] = Field.explicit(vm_id, Provenance.URI, rid)
        if cfg.get("aid") not in (None, ""):
            profile.auth["alter_id"] = Field.explicit(cfg["aid"], Provenance.URI, "aid")
        rscy, vm_scy = _first_present(cfg, "scy", "security")
        if rscy:
            profile.auth["method"] = Field.explicit(vm_scy, Provenance.URI, rscy)
        if cfg.get("ps") not in (None, ""):                # 备注: 不覆盖 fragment 里的名字
            key = "remark" if "name" in profile.metadata else "name"
            profile.metadata[key] = Field.explicit(cfg["ps"], Provenance.URI, "ps")
    else:
        if scheme == "ss":  # SIP002: userinfo 是 base64(method:password)
            try:
                decoded = base64.urlsafe_b64decode(_b64pad(parts.username or "")).decode()
                method, _, password = decoded.partition(":")
                profile.auth["method"] = Field.explicit(method, Provenance.URI, "userinfo")
                profile.auth["password"] = Field.explicit(password, Provenance.URI, "userinfo")
            except Exception:
                profile.diagnostics.append({"code": "SS_USERINFO_UNPARSED",
                                            "detail": "userinfo 不是合法 base64"})
        else:
            if parts.username:
                key = "uuid" if proto_id in ("standard:vless",) else "password"
                profile.auth[key] = Field.explicit(unquote(parts.username),
                                                   Provenance.URI, "userinfo")
            if parts.password:
                profile.auth["password"] = Field.explicit(unquote(parts.password),
                                                          Provenance.URI, "userinfo")
        profile.endpoint["host"] = Field.explicit(host, Provenance.URI, "host")
        profile.endpoint["port"] = Field.explicit(parts.port or (443 if parts.port is None else None),
                                                  Provenance.URI, "port")

    # ---- transport / security / 其它 feature
    if scheme == "vmess":
        tname = str(q.get("net") or "").strip().lower()   # vmess 的 type 是 header 类型, 不是传输
    else:
        tname = str(q.get("type") or q.get("net") or "").strip().lower()
    if tname:
        tid = TRANSPORT_MAP.get(tname)
        if tid is None:
            # 未知传输: 保留原值, 记为 vendor/unknown feature, 绝不改换
            profile.add_feature(Feature(id=f"unknown:transport.{tname}",
                                        presence=Presence.EXPLICIT,
                                        provenance=Provenance.URI,
                                        note=f"未收录的传输方式 {transport_key}={tname}"))
            profile.add_extension(transport_key, q[transport_key], "URI",
                                  "未知传输方式, 原样保留")
        else:
            profile.add_feature(Feature(id=tid, presence=Presence.EXPLICIT,
                                        provenance=Provenance.URI))
    else:
        profile.add_feature(Feature(id="standard:transport.tcp", presence=Presence.DEFAULTED,
                                    provenance=Provenance.INFERRED,
                                    note="未写传输方式(type/net), 按规范默认 raw/tcp"))
    sec = str(q.get(sec_key) or "").strip().lower()
    if sec == "tls":
        profile.add_feature(Feature(id="standard:tls", presence=Presence.EXPLICIT,
                                    provenance=Provenance.URI))
    elif sec == "reality":
        profile.add_feature(Feature(id="standard:reality", presence=Presence.EXPLICIT,
                                    provenance=Provenance.URI))
    elif sec in ("", "none"):
        if proto_id in ("standard:trojan", "standard:hysteria2", "standard:tuic",
                        "standard:anytls"):
            profile.add_feature(Feature(id="standard:tls", presence=Presence.DEFAULTED,
                                        provenance=Provenance.INFERRED,
                                        note=f"{proto_id} 默认走 TLS"))
    if q.get("allowInsecure") or q.get("insecure"):
        profile.add_feature(Feature(id="standard:tls.allow_insecure",
                                    presence=Presence.EXPLICIT, provenance=Provenance.URI))
    if q.get("mux") or q.get("mux-enabled") or q.get("smux"):
        profile.add_feature(Feature(id="standard:mux", presence=Presence.EXPLICIT,
                                    provenance=Provenance.URI))
    if q.get("flow"):
        profile.add_feature(Feature(id="standard:flow", presence=Presence.EXPLICIT,
                                    provenance=Provenance.URI))
    if q.get("ech") or q.get("pqv") or q.get("pcs") or q.get("vcn"):
        profile.add_feature(Feature(id="standard:ech", presence=Presence.EXPLICIT,
                                    provenance=Provenance.URI))

    # ---- VLESS 后量子加密（gap: 原来只在 raw.fields 里, profile 里看不见 → 漏判/假阳性）
    if proto_id == "standard:vless" and q.get("encryption") not in (None, ""):
        profile.add_feature(Feature(
            id="standard:vless.encryption", presence=Presence.EXPLICIT,
            provenance=Provenance.URI,
            params={"encryption": Field.explicit(q["encryption"], Provenance.URI, "encryption")},
            note="VLESS encryption（取值含 mlkem768x25519plus… 后量子加密）; 值原样保存"))

    # ---- 参数归属（挂到对应 feature 上, 否则进 extensions）
    reality_feat = profile.get_feature("standard:reality")
    # security=reality 时 sni/fp 属于 REALITY 的握手身份（reality serverNames / uTLS 指纹）,
    # 必须挂到 standard:reality 上, 不能掉进 extensions。security=tls 时仍归 standard:tls。
    reality_identity = reality_feat is not None and (
        sec == "reality" or profile.get_feature("standard:tls") is None)
    for k, v in q.items():
        if k in consumed:
            continue
        owner = PARAM_OWNER.get(k)
        pkey = k
        if reality_identity and k in _REALITY_IDENTITY:
            owner, pkey = "standard:reality", _REALITY_IDENTITY[k]
        if owner == "transport":
            tid = TRANSPORT_MAP.get(tname)
            feat = profile.get_feature(tid) if tid else None
        elif owner is None:
            feat = None
        else:
            feat = profile.get_feature(owner)
            if feat is None and owner.startswith("standard:") and owner not in (
                    "standard:xhttp", "standard:ech", "standard:reality"):
                feat = None
        if feat is not None:
            feat.params[pkey] = Field.explicit(v, Provenance.URI, k)
        elif owner in ("standard:ech", "standard:reality"):
            # 对应 feature 不存在 → 用参数本身反推一个 feature（如 pbk 隐含 reality）
            implied = {"standard:reality": "standard:reality",
                       "standard:ech": "standard:ech"}[owner]
            if profile.get_feature(implied) is None:
                profile.add_feature(Feature(id=implied, presence=Presence.INFERRED,
                                            provenance=Provenance.INFERRED,
                                            note=f"由参数 {k} 反推"))
            profile.get_feature(implied).params[k] = Field.explicit(v, Provenance.URI, k)
        elif k not in known:
            profile.add_extension(k, v, "URI")   # ★ 未知参数进 extensions, 绝不丢
        else:
            profile.add_extension(k, v, "URI", "已收录但未建模到具体 feature")

    # AnyReality: 组合特征（vendor 命名空间, 无特例分支）
    if (profile.get_feature("standard:reality") is not None
            and proto_id == "standard:shadowsocks"):
        profile.add_feature(Feature(
            id="mi1314cat:anyreality.ss-reality", presence=Presence.EXPLICIT,
            provenance=Provenance.INFERRED,
            requires=["standard:shadowsocks", "standard:reality"],
            note="SS2022 叠加 REALITY（由 security=reality 推断）"))
    return profile


def generate_uri(profile: NodeProfile, *, allow_extensions: bool = False) -> str:
    """回写链接。INFERRED 字段不写回（不伪装成用户显式提供）。"""
    proto = profile.protocol.id if profile.protocol else "unknown"
    if proto == "standard:vmess":
        return _generate_vmess_uri(profile, allow_extensions=allow_extensions)
    scheme = {"standard:vless": "vless", "standard:trojan": "trojan",
              "standard:shadowsocks": "ss", "standard:hysteria2": "hysteria2",
              "standard:tuic": "tuic", "standard:anytls": "anytls",
              "standard:socks": "socks", "standard:http": "http"}.get(proto, "")
    if not scheme:
        raise ValueError(f"无法为该 protocol 生成标准链接: {proto}")

    host = profile.endpoint.get("host")
    port = profile.endpoint.get("port")
    user = ""
    for key in ("uuid", "password"):
        f = profile.auth.get(key)
        if f is not None and f.presence is Presence.EXPLICIT:
            user = quote(str(f.v))
            break
    if scheme == "ss":
        m = profile.auth.get("method")
        pw = profile.auth.get("password")
        if m and pw and m.presence is Presence.EXPLICIT:
            blob = base64.urlsafe_b64encode(f"{m.v}:{pw.v}".encode()).decode().rstrip("=")
            user = blob

    q: list[tuple[str, str]] = []
    for feat in profile.features:
        for pk, pf in feat.params.items():
            if pf.presence is Presence.EXPLICIT:   # 只写显式值
                q.append((pf.raw_key or pk, str(pf.v)))
        if feat.id == "standard:transport.ws":
            q.append(("type", "ws"))
        elif feat.id == "standard:xhttp":
            q.append(("type", "xhttp"))
        elif feat.id == "standard:transport.grpc":
            q.append(("type", "grpc"))
        elif feat.id == "standard:reality":
            q.append(("security", "reality"))
        elif feat.id == "standard:tls" and feat.presence is Presence.EXPLICIT:
            q.append(("security", "tls"))
    if allow_extensions:
        for e in profile.extensions:
            q.append((e["key"], str(e["value"])))

    name = profile.metadata.get("name")
    frag = ""
    if name is not None and name.presence is Presence.EXPLICIT:
        frag = "#" + quote(str(name.v))
    query = "&".join(f"{k}={v}" for k, v in q)
    return f"{scheme}://{user}@{host.v if host else ''}:{port.v if port else ''}" \
           + (f"?{query}" if query else "") + frag


def _generate_vmess_uri(profile: NodeProfile, *, allow_extensions: bool = False) -> str:
    """vmess:// ← base64(JSON)。

    只写 presence=EXPLICIT 的值（推断/DEFAULTED 不写回, 不伪造用户意图）;
    只有 VMess QR 的字段集能进 body（_VMESS_QR_KEYS）, 其它 feature 的参数
    （reality/ech/mux…）不写回 —— 该损失由 URI 表达力规则报告, 不在这里假装能表达。
    extensions 默认丢弃, 仅在 allow_extensions=True 时原样写回。
    """
    if any(d.get("code") == "VMESS_BODY_UNPARSED" for d in profile.diagnostics):
        # 载荷没解析出来就回写 = 用空 JSON 覆盖原文（静默丢字段）→ 拒绝, 让调用方用 raw.uri
        raise ValueError("vmess 载荷未解析(VMESS_BODY_UNPARSED), 拒绝回写以免丢字段; "
                         "请原样使用 profile.raw_uri")
    body: dict[str, object] = {}
    host = profile.endpoint.get("host")
    port = profile.endpoint.get("port")
    if host is not None and host.presence is Presence.EXPLICIT:
        body["add"] = str(host.v)
    if port is not None and port.presence is Presence.EXPLICIT:
        body["port"] = str(port.v)
    for key, name in (("uuid", "id"), ("alter_id", "aid"), ("method", "scy")):
        f = profile.auth.get(key)
        if f is not None and f.presence is Presence.EXPLICIT:
            body[f.raw_key or name] = str(f.v)

    name = profile.metadata.get("name")
    remark = profile.metadata.get("remark")
    if remark is not None and remark.presence is Presence.EXPLICIT:
        body["ps"] = str(remark.v)
    elif name is not None and name.presence is Presence.EXPLICIT and name.raw_key == "ps":
        body["ps"] = str(name.v)
    frag = ""
    if name is not None and name.presence is Presence.EXPLICIT and name.raw_key != "ps":
        frag = "#" + quote(str(name.v))       # fragment 里的名字来自 '#', 不是 ps

    for feat in profile.features:
        net = _VMESS_NET.get(feat.id)
        if net and feat.presence is Presence.EXPLICIT:
            body["net"] = net
        if feat.id == "standard:tls" and feat.presence is Presence.EXPLICIT:
            body["tls"] = "tls"
        for pk, pf in feat.params.items():
            qk = pf.raw_key or pk
            if pf.presence is Presence.EXPLICIT and qk in _VMESS_QR_KEYS:
                body[qk] = str(pf.v)
    if allow_extensions:                       # 显式要求时才写未知键
        for e in profile.extensions:
            body.setdefault(str(e["key"]), e["value"])

    payload = base64.urlsafe_b64encode(
        json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()).decode()
    return f"vmess://{payload}{frag}"


def parse_json_node(data: dict, fmt: str) -> NodeProfile:
    """从内核配置片段（Xray/sing-box 出站 / mihomo proxy）建 profile。"""
    prof = NodeProfile(source_format=fmt, raw_fields=dict(data))
    prof.diagnostics.append({"code": "JSON_IMPORT", "detail": f"来自 {fmt} 配置片段"})
    for k, v in data.items():
        prof.add_extension(k, v, fmt, "尚未建模到 profile")
    return prof
