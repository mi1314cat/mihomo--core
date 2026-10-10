#!/usr/bin/env python3
"""nodecompat.py — M 客户端「节点能不能用」的兼容判定适配层。

本文件是 proxy-node-compat（vendored 在 src/lib/proxy_node_compat/）与
M 客户端原有判定之间的唯一桥梁。职责严格限定为三件事：

  1. **表示转换**: mihomo 的节点字典（provider YAML 里的一个条目）→ NodeProfile。
     若条目里带原始分享链接，则直接走 compat 的 parse_uri（保真最高）。
  2. **目标真探测**: 真跑 `<mihomo> -v` 取版本 / 发行版 / build tags，不写死、不猜。
  3. **机械合并**: compat 判定 vs 客户端原有判定，**取更差者**（只许收紧），
     并保留一键回滚。

**本文件不含任何能力规则。** 所有「这个内核支不支持 X」的结论都来自
proxy_node_compat 的规则库；本文件只做上面三件事。判定只在 compat 发生一次
（engine.py 的纪律 4），调用方只消费结果。

回滚开关（不改代码、不改文件）:
    MH_COMPAT_ENGINE=legacy        # M 侧的名字
    XBD_COMPAT_ENGINE=legacy       # 与 X 客户端统一的别名
任一为 legacy 即整条链路退回客户端原有判定。

命令行自检:
    python3 nodecompat.py kernel              # 打印真探测到的 Target
    python3 nodecompat.py selftest            # 合并层不变量自检
    python3 nodecompat.py json <节点文件>      # 逐节点判定（YAML 或单条 JSON）
    python3 nodecompat.py compare <节点文件>   # 旧 vs compat vs 合并 三列对照
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

try:
    from proxy_node_compat import NodeProfile, Target, Field, Feature, Presence, \
        Provenance, Registry, check_node, default_registry_path, parse_uri
    from proxy_node_compat.uri import TRANSPORT_MAP
    from proxy_node_compat.engine import LEVELS
    _IMPORT_ERR = None
except Exception as _e:                                    # pragma: no cover
    _IMPORT_ERR = _e

# 客户端原有的字段白名单表 —— **不另抄一份**。抄一份就是第二个真源，
# 以后 validate.py 加了新协议这里必然忘记同步，于是判定会把合法节点判坏。
try:
    import validate as _validate
except Exception:                                          # pragma: no cover
    _validate = None

# =============================================================
# 状态词表
#
# 直接沿用 compat 的词汇（不发明第二套），只在**显示**时翻译成中文标签。
# =============================================================
STATUS_RANK = {
    "SUPPORTED": 0,
    "SUPPORTED_WITH_WARNING": 1,
    "SUPPORTED_WITH_LOSS": 2,
    "UNKNOWN": 3,
    "UNSUPPORTED": 4,
}
LABEL = {
    "SUPPORTED": "支持",
    "SUPPORTED_WITH_WARNING": "支持!",
    "SUPPORTED_WITH_LOSS": "支持!",
    "UNKNOWN": "未知",
    "UNSUPPORTED": "不支持",
}
# 只有这一种状态会在导入时剔除节点。UNKNOWN 的含义是「我们没有依据」，
# 不是「不能用」—— 拿它去删用户已有的节点是越权。
DROP_STATUS = "UNSUPPORTED"

ENGINE_ENV = ("MH_COMPAT_ENGINE", "XBD_COMPAT_ENGINE")
LEGACY = "legacy"


def engine() -> str:
    """compat（默认）或 legacy（一键回滚）。大小写不敏感。"""
    for name in ENGINE_ENV:
        v = (os.environ.get(name) or "").strip().lower()
        if v:
            return LEGACY if v in ("legacy", "off", "0", "old") else "compat"
    return "compat"


def reason_disabled() -> str | None:
    """为什么退回旧判定（没有原因时返回 None）。"""
    if engine() == LEGACY:
        return "环境变量指定 %s=%s" % (ENGINE_ENV[0], LEGACY)
    if _IMPORT_ERR is not None:
        return "proxy_node_compat 不可用: %s" % _IMPORT_ERR
    return None


# =============================================================
# 目标真探测
# =============================================================
def _run(argv) -> str:
    """整体捕获再匹配 —— 不用管道。上游写管道时收到 SIGPIPE(141) 会让
    `set -euo pipefail` 的调用方随机猝死（本项目已踩过）。"""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=10)
    except Exception:
        return ""
    try:
        return p.stdout.decode("utf-8", "replace")
    except Exception:                                      # pragma: no cover
        return ""


def _version_bin(binary: str | None = None) -> str:
    if binary:
        return binary
    return (os.environ.get("MIHOMO_BIN") or os.environ.get("CLI_BIN")
            or "/root/catmi/mihomo-client/mihomo")


def probe_kernel(binary: str | None = None) -> dict:
    """真探测内核身份。探测不到就返回空值 —— 不写死、不猜。

    compat 对「版本未知」的处理是 UNKNOWN（不是「默认支持」），
    适配层随后按"compat 没有确定结论就退回旧判定"处理，行为不变。
    """
    out = _run([_version_bin(binary), "-v"])
    if not out.strip():
        return {"version": None, "distribution": None, "build_tags": None,
                "raw": "", "probed": False}
    first = out.strip().splitlines()[0].strip()
    version = None
    for tok in first.replace(",", " ").split():
        t = tok.strip().lstrip("vV")
        if t and t[0].isdigit() and t.count(".") >= 1:
            version = t
            break
    # 官方二进制自称 Mihomo Meta；别的名字按 fork 处理（fork 不继承上游，
    # compat 会直接判 UNKNOWN → 退回旧判定）。
    low = first.lower()
    distribution = "upstream" if "mihomo" in low else (first.split()[0] if first else None)
    tags = None
    for line in out.splitlines():
        if line.strip().lower().startswith("use tags:"):
            tags = [t for t in line.split(":", 1)[1].replace(",", " ").split() if t]
    return {"version": version, "distribution": distribution,
            "build_tags": tags, "raw": first, "probed": True}


_TARGET_CACHE: dict = {}


def kernel_target(binary: str | None = None, refresh: bool = False):
    """→ compat 的 Target(kernel="mihomo", version=<真探测>)。带缓存。"""
    key = _version_bin(binary)
    if refresh or key not in _TARGET_CACHE:
        info = probe_kernel(binary)
        _TARGET_CACHE[key] = Target(
            kernel="mihomo",
            distribution=info["distribution"],
            version=info["version"],
            build_tags=info["build_tags"],
            runtime_options={},
        )
    return _TARGET_CACHE[key]


# =============================================================
# 注册表（61KB 规则，逐节点调用必须缓存）
# =============================================================
_REGISTRY_CACHE: list = []


def registry(refresh: bool = False):
    if refresh or not _REGISTRY_CACHE:
        _REGISTRY_CACHE.append(Registry.load(default_registry_path()))
    return _REGISTRY_CACHE[0]


# =============================================================
# 节点表示转换: mihomo provider 条目 → NodeProfile
# =============================================================
# 协议映射: mihomo 的 type → compat 的 protocol feature。
# 没有对应规则的协议（snell / wireguard / ssh / mieru / hysteria(v1) / shadow-tls …）
# 一律映射到 unknown: 命名空间 —— compat 会判 UNKNOWN，合并层随后退回旧判定，
# 因此这些协议的行为**与接入前逐字一致**。
_TYPE_PROTOCOL = {
    "vless": "standard:vless",
    "vmess": "standard:vmess",
    "trojan": "standard:trojan",
    "ss": "standard:shadowsocks",
    "hysteria2": "standard:hysteria2",
    "tuic": "standard:tuic",
    "anytls": "standard:anytls",
    "socks5": "standard:socks",
    "http": "standard:http",
}
# 这些协议天生走 TLS（YAML 里没有 tls 字段也一定是 TLS）
_IMPLICIT_TLS = ("trojan", "hysteria2", "tuic", "anytls")

# TLS 相关参数: YAML 键 → profile 参数名。
# client-fingerprint → fingerprint 是**必须**的写法: compat 的运行期条件
# `client_fingerprint_present` 只认 fingerprint/fp 这两个参数名
# （engine.py:_PROFILE_RUNTIME_FACTS）。写成别的名字会让有指纹的节点
# 被误判成"缺指纹"。
_TLS_PARAMS = {"sni": "sni", "servername": "servername", "alpn": "alpn",
               "skip-cert-verify": "skip_cert_verify", "fingerprint": "fingerprint",
               "client-fingerprint": "fingerprint", "certificate": "certificate",
               "private-key": "private_key"}
_REALITY_PARAMS = {"public-key": "public_key", "short-id": "short_id",
                   "support-x25519mlkem768": "support_x25519mlkem768"}
_URI_KEYS = ("raw-uri", "raw_uri", "_uri", "uri")


def _has(d: dict, k: str) -> bool:
    return isinstance(d, dict) and d.get(k) not in (None, "", False, [], {})


def profile_of(proxy, raw_uri: str | None = None) -> "NodeProfile":
    """节点 → NodeProfile（内核无关，不含任何内核版本字段）。

    两种输入，保真度从高到低:
      * 分享链接（字符串，或字典里带 raw-uri 键）→ 走 compat 的 parse_uri。
        这是保真最高的一路: 值一个字节都不重写（不变式 I1）。
      * mihomo 的节点字典 → 按字段映射成 feature。绝不静默丢字段
        （不变式 I2）: 每个被读到但没建模的键都进 extensions[]，
        原始字典整份进 raw_fields。
    """
    if _IMPORT_ERR is not None:
        raise RuntimeError("proxy_node_compat 不可用: %s" % _IMPORT_ERR)
    if isinstance(proxy, str):
        # 分享链接: 直接交给 compat 的解析器。raw_uri 原样保留,
        # 未知 scheme / 未知参数都不会让整批失败（parse_uri 的既有纪律）。
        prof = parse_uri(proxy.strip())
        prof.diagnostics.append({
            "code": "URI_IMPORT",
            "detail": "来自分享链接: 原始字符串整份保留在 raw.uri"})
        return prof
    if not isinstance(proxy, dict):
        raise TypeError("节点必须是字典或分享链接字符串")

    # ---- 原始分享链接优先（保真最高，与 X 客户端 "source 以 -uri 结尾" 同款）
    if not raw_uri:
        for k in _URI_KEYS:
            v = proxy.get(k)
            if isinstance(v, str) and "://" in v:
                raw_uri = v.strip()
                break
    if raw_uri:
        prof = parse_uri(raw_uri)
        # 链接是**同一个节点**的另一份表示: 把 YAML 独有的键补进 extensions，
        # 保证两条来源都在结果里（不因"链接能解析"就把 YAML 丢掉）。
        for k, v in proxy.items():
            if k in _URI_KEYS:
                continue
            prof.add_extension(k, v, "MIHOMO_YAML",
                               "原始链接可解析; 该键只存在于 YAML 一侧, 原样保留")
        prof.raw_fields = dict(proxy)
        prof.diagnostics.append({"code": "MIHOMO_YAML_WITH_URI",
                                 "detail": "同时拿到原始链接与 YAML 条目, 判定走链接"})
        return prof

    prof = NodeProfile(source_format="mihomo_yaml", raw_fields=dict(proxy),
                       raw_uri=None)
    prof.diagnostics.append({"code": "MIHOMO_YAML_IMPORT",
                             "detail": "来自 mihomo provider 条目"})

    consumed: set = set()

    # ---- 协议
    ptype = str(proxy.get("type") or "").strip().lower()
    consumed.add("type")
    pid = _TYPE_PROTOCOL.get(ptype)
    if pid is None:
        pid = "unknown:mihomo.%s" % (ptype or "noscheme")
        prof.diagnostics.append({
            "code": "UNKNOWN_PROTOCOL",
            "detail": "compat 规则库没有 %r 的协议规则（未知 ≠ 不支持, 由合并层退回旧判定）"
                      % ptype})
    prof.protocol = Feature(id=pid, presence=Presence.EXPLICIT,
                            provenance=Provenance.MIHOMO_YAML)

    # ---- endpoint / auth / metadata
    if _has(proxy, "name"):
        prof.metadata["name"] = Field.explicit(proxy["name"], Provenance.MIHOMO_YAML, "name")
        consumed.add("name")
    for k in ("server", "port"):
        if _has(proxy, k):
            prof.endpoint["host" if k == "server" else "port"] = Field.explicit(
                proxy[k], Provenance.MIHOMO_YAML, k)
            consumed.add(k)
    auth_key = {"vless": "uuid", "vmess": "uuid", "tuic": "uuid"}.get(ptype, "password")
    for k in ("uuid", "password", "token", "username", "method", "cipher", "psk"):
        if _has(proxy, k) and k not in consumed:
            prof.auth[auth_key if k in ("uuid", "password", "token") else k] = \
                Field.explicit(proxy[k], Provenance.MIHOMO_YAML, k)
            consumed.add(k)
    if _has(proxy, "alterId"):
        prof.auth["alter_id"] = Field.explicit(proxy["alterId"], Provenance.MIHOMO_YAML, "alterId")
        consumed.add("alterId")

    # ---- 传输
    tname = str(proxy.get("network") or proxy.get("net") or "").strip().lower()
    consumed.update(("network", "net"))
    if tname:
        tid = TRANSPORT_MAP.get(tname)
        if tid is None:
            prof.add_feature(Feature(id="unknown:transport.%s" % tname,
                                     presence=Presence.EXPLICIT,
                                     provenance=Provenance.MIHOMO_YAML,
                                     note="未收录的传输方式 network=%s" % tname))
            prof.add_extension("network", proxy.get("network"), "MIHOMO_YAML",
                               "未知传输方式, 原样保留")
        else:
            prof.add_feature(Feature(id=tid, presence=Presence.EXPLICIT,
                                     provenance=Provenance.MIHOMO_YAML))
    else:
        # mihomo 不写 network 时的默认是 tcp（不是"未知"）
        prof.add_feature(Feature(id="standard:transport.tcp", presence=Presence.DEFAULTED,
                                 provenance=Provenance.INFERRED,
                                 note="未写 network, 按 mihomo 默认 raw/tcp"))

    # ---- 安全层: reality > tls > 隐式 tls
    reality = proxy.get("reality-opts")
    if isinstance(reality, dict) and reality:
        feat = Feature(id="standard:reality", presence=Presence.EXPLICIT,
                       provenance=Provenance.MIHOMO_YAML)
        for k, v in reality.items():
            if k in _REALITY_PARAMS:
                feat.params[_REALITY_PARAMS[k]] = Field.explicit(
                    v, Provenance.MIHOMO_YAML, k)
            else:
                prof.add_extension("reality-opts.%s" % k, v, "MIHOMO_YAML",
                                   "reality-opts 里未建模的键")
        prof.add_feature(feat)
    elif _has(proxy, "tls") or str(proxy.get("tls", "")).lower() == "true":
        prof.add_feature(Feature(id="standard:tls", presence=Presence.EXPLICIT,
                                 provenance=Provenance.MIHOMO_YAML))
    elif ptype in _IMPLICIT_TLS:
        prof.add_feature(Feature(id="standard:tls", presence=Presence.DEFAULTED,
                                 provenance=Provenance.INFERRED,
                                 note="%s 协议天生走 TLS" % ptype))
    consumed.update(("reality-opts", "tls"))

    # ---- TLS 参数（sni/servername/alpn/指纹…）
    # reality 节点上 sni/fp 是 REALITY 的握手身份, 与 uri.py 的处理保持一致:
    # 同时挂到 reality（语义正确）与 tls（运行期条件需要看到 fingerprint）。
    tls_feat = prof.get_feature("standard:tls")
    real_feat = prof.get_feature("standard:reality")
    for k, pkey in _TLS_PARAMS.items():
        if k not in proxy:
            continue
        v = proxy[k]
        consumed.add(k)
        if tls_feat is not None:
            tls_feat.params[pkey] = Field.explicit(v, Provenance.MIHOMO_YAML, k)
        if real_feat is not None and k in ("sni", "servername", "client-fingerprint",
                                           "fingerprint"):
            real_feat.params["server_name" if k in ("sni", "servername") else "fingerprint"] = \
                Field.explicit(v, Provenance.MIHOMO_YAML, k)

    # ---- 其它能改变能力的开关
    if _has(proxy, "flow"):
        prof.add_feature(Feature(id="standard:flow", presence=Presence.EXPLICIT,
                                 provenance=Provenance.MIHOMO_YAML,
                                 params={"flow": Field.explicit(proxy["flow"], Provenance.MIHOMO_YAML, "flow")}))
    consumed.add("flow")
    ech = proxy.get("ech-opts")
    if isinstance(ech, dict) and ech.get("enable"):
        feat = Feature(id="standard:ech", presence=Presence.EXPLICIT,
                       provenance=Provenance.MIHOMO_YAML)
        for k, v in ech.items():
            if k == "enable":
                continue
            feat.params[k] = Field.explicit(v, Provenance.MIHOMO_YAML, k)
        prof.add_feature(feat)
        consumed.add("ech-opts")
    if _has(proxy, "smux") or _has(proxy, "mux"):
        key = "smux" if _has(proxy, "smux") else "mux"
        prof.add_feature(Feature(id="standard:mux", presence=Presence.EXPLICIT,
                                 provenance=Provenance.MIHOMO_YAML,
                                 params={key: Field.explicit(proxy[key], Provenance.MIHOMO_YAML, key)}))
        consumed.add(key)
    if ptype == "vless" and proxy.get("encryption") not in (None, ""):
        prof.add_feature(Feature(
            id="standard:vless.encryption", presence=Presence.EXPLICIT,
            provenance=Provenance.MIHOMO_YAML,
            params={"encryption": Field.explicit(proxy["encryption"], Provenance.MIHOMO_YAML, "encryption")},
            note="VLESS encryption 取值原样保存"))
    consumed.add("encryption")
    if ptype == "ss" and proxy.get("plugin"):
        prof.add_feature(Feature(id="standard:shadowsocks.plugin", presence=Presence.EXPLICIT,
                                 provenance=Provenance.MIHOMO_YAML,
                                 params={"plugin": Field.explicit(proxy["plugin"], Provenance.MIHOMO_YAML, "plugin")}))
        consumed.add("plugin")

    # ---- 剩下的一律进 extensions（不变式 I2: 读了没建模的键必须留痕）
    for k, v in proxy.items():
        if k in consumed:
            continue
        if isinstance(v, dict):
            for kk, vv in v.items():
                prof.add_extension("%s.%s" % (k, kk), vv, "MIHOMO_YAML",
                                   "嵌套结构里的键, 尚未建模到 profile")
        else:
            prof.add_extension(k, v, "MIHOMO_YAML", "尚未建模到 profile")
    return prof


# =============================================================
# 旧判定（客户端原有的那一套）
# =============================================================
def legacy_verdict(proxy) -> dict:
    """客户端**接入前**就有的判定: 协议白名单 + 内核不认的字段剔除。

    判据从 validate.py 自己的表里取，不另抄一份清单。

    分享链接（字符串）是**例外**: 客户端对这条路根本不逐条判 —— 它把整个
    文件原样交给内核内置的订阅转换器（见 client.sh 的 URI 列表分支）。
    所以旧判定在这里就是"不表态"，一切能力结论都来自 compat。
    """
    out = {"status": "SUPPORTED", "reasons": [], "dropped_fields": [],
           "malformed": None, "checks": []}
    if isinstance(proxy, str):
        out["checks"].append({
            "item": "protocol", "verdict": "SUPPORTED",
            "detail": "分享链接由内核内置转换器解析, 旧判定不逐条判"})
        out["reasons"].append("分享链接: 旧判定不表态（原样交给内核解析器）")
        return out
    if not isinstance(proxy, dict):
        out.update(status="UNSUPPORTED", malformed="不是字典")
        return out
    missing = [k for k in ("name", "type", "server", "port") if proxy.get(k) in (None, "")]
    if missing:
        out.update(status="UNSUPPORTED", malformed="缺 " + "/".join(missing))
        return out
    t = str(proxy.get("type", "")).lower()
    types = set(getattr(_validate, "PROXY_TYPES", set()) or set())
    if types and t not in types:
        out["status"] = "UNSUPPORTED"
        out["reasons"].append("mihomo 核心不支持该协议类型 %s" % t)
        out["checks"].append({"item": "protocol", "verdict": "UNSUPPORTED",
                              "detail": "%s 不在 validate.PROXY_TYPES 里" % t})
        return out
    out["checks"].append({"item": "protocol", "verdict": "SUPPORTED",
                          "detail": "%s 在 validate.PROXY_TYPES 里" % t})
    # 内核不认的字段: 会被静默忽略, 所以这里算**确定的**能力损失。
    if _validate is not None and hasattr(_validate, "strip_unknown"):
        _kept, dropped = _validate.strip_unknown(dict(proxy))
        if dropped:
            out["status"] = "SUPPORTED_WITH_LOSS"
            out["dropped_fields"] = sorted(dropped)
            out["reasons"].append(
                "有 %d 个字段内核会静默忽略（导入时已剔除）: %s"
                % (len(dropped), ", ".join(sorted(dropped)[:6])))
            out["checks"].append({"item": "fields", "verdict": "SUPPORTED_WITH_LOSS",
                                  "detail": "剔除: " + ", ".join(sorted(dropped))})
    return out


# =============================================================
# compat 判定
# =============================================================
def compat_verdict(proxy: dict, target=None, raw_uri: str | None = None) -> dict:
    """走 compat 的**唯一**判定点。异常一律落回 legacy（调用方处理）。"""
    prof = profile_of(proxy, raw_uri=raw_uri)
    res = check_node(prof, target or kernel_target(), registry())
    d = res.to_dict()
    d["extensions"] = list(prof.extensions)
    d["diagnostics"] = list(prof.diagnostics)
    d["raw_fields"] = dict(prof.raw_fields)
    d["profile"] = prof.to_dict()
    d["levels"] = {k: d["levels"].get(k, "UNKNOWN") for k in LEVELS}
    return d


def _compat_conclusion(c: dict) -> bool:
    """compat 是否给出了**确定的**结论。

    UNKNOWN 的含义是「我们没有依据」，不是「不能用」。没有任何确定结论的
    UNKNOWN 若拿去参与"取更差者"，会把客户端本来判定可用的节点凭空变成
    未知 —— 那不是保守，是拿无知当结论。所以这种 UNKNOWN 直接退回旧判定。
    """
    if c.get("losses"):
        return True
    if c.get("failure_mode") == "hard_error":
        return True
    return "UNSUPPORTED" in (c.get("levels") or {}).values()


# =============================================================
# 合并层（只做两条策略，不写任何能力规则）
# =============================================================
def merge(legacy: dict, compat: dict | None, disabled_reason: str | None = None) -> dict:
    """取更差者 + UNKNOWN 回退。返回结果携带 compat 的**全部**字段。

    `kind` 是机械分类, 供对比台与回归断言直接消费（不再靠字符串猜）:
        same       与旧判定一致
        tightened  新判定更严（compat 生效）
        fallback   退回旧判定（compat 判 UNKNOWN 且无确定结论 / 引擎被关掉）
        blocked    compat 想放宽, 被保险丝挡下（这是 bug）
    """
    out = {
        "verdict": legacy["status"],
        "label": LABEL.get(legacy["status"], legacy["status"]),
        "verdict_source": "legacy",
        "kind": "fallback",
        "drop": legacy["status"] == DROP_STATUS,
        "reasons": list(legacy.get("reasons") or []),
        "legacy": legacy,
        "compat": compat,
        # downgrades 只记**会影响"剔不剔节点"这个决定**的放宽。
        #
        # 为什么不把"compat 比旧判定宽"一律记进来: 两个引擎量的不是同一件事。
        # 旧判定有一维 compat 按设计不管 —— 字段名的对错 (trojan 写 servername
        # 会被内核静默忽略)。于是"旧=SUPPORTED_WITH_LOSS / compat=SUPPORTED"
        # 是**常态**, 每一条都记就等于这个计数器永远是红的, 而永远红的门等于
        # 没有门 (本项目的既有教训)。真正要挡的是下面这一种。
        "downgrades": [],
        "wider": False,
    }
    if compat is None:
        out["verdict_source"] = "legacy（compat 未参与: %s）" % (disabled_reason or "未知")
        return out
    # 规则 1: compat 判 UNKNOWN 且没有任何确定结论 → 退回旧判定
    if compat.get("status") == "UNKNOWN" and not _compat_conclusion(compat):
        out["verdict_source"] = "legacy（compat 判 UNKNOWN, 无确定结论）"
        return out
    # 规则 2: 取更差者 —— compat 只能收紧, 不能放宽
    new = compat["status"]
    if STATUS_RANK.get(new, 3) > STATUS_RANK.get(out["verdict"], 0):
        out["verdict"] = new
        out["label"] = LABEL.get(new, new)
        out["kind"] = "tightened"
    else:
        out["kind"] = "same"
    out["verdict_source"] = "compat" if out["kind"] == "tightened" else "compat（与旧判定一致）"
    if STATUS_RANK.get(new, 3) < STATUS_RANK.get(legacy["status"], 0):
        out["wider"] = True
        # ★ 唯一必须挡下的放宽: 旧判定要**剔除**这个节点, 而 compat 说能用。
        #   放过它就等于 compat 把客户端明确判定不可用的节点捞回来 ——
        #   那才是真正的退步。
        if legacy["status"] == DROP_STATUS and new != DROP_STATUS:
            out["downgrades"].append({
                "what": "旧判定要剔除该节点 (UNSUPPORTED), compat 却判 %s" % new,
                "action": "已拒绝放宽, 保留旧判定（剔除）"})
            out["verdict"] = legacy["status"]
            out["label"] = LABEL.get(legacy["status"], legacy["status"])
            out["verdict_source"] = "legacy（compat 想放宽, 被保险丝挡下）"
            out["kind"] = "blocked"
    out["drop"] = out["verdict"] == DROP_STATUS
    return out


def judge(proxy, target=None, raw_uri: str | None = None) -> dict:
    """单节点判定的**唯一入口**（节点字典或分享链接字符串）。
    任何异常都落回旧判定, UI 不会崩。"""
    legacy = legacy_verdict(proxy)
    why = reason_disabled()
    if why:
        return merge(legacy, None, why)
    try:
        return merge(legacy, compat_verdict(proxy, target=target, raw_uri=raw_uri))
    except Exception as e:                                 # pragma: no cover
        return merge(legacy, None, "适配层异常: %r" % (e,))


def judge_all(proxies, target=None) -> list:
    return [judge(p, target=target) for p in proxies]


# =============================================================
# 结果 → 给人看的一行
# =============================================================
def describe(res: dict, limit: int = 3) -> str:
    """把损失/未知讲清楚 —— 「支持!」必须能解释为什么。"""
    c = res.get("compat") or {}
    bits = []
    for ls in c.get("losses") or []:
        what = ls.get("what") or ls.get("feature")
        if what and what not in bits:
            bits.append(str(what))
    for w in c.get("warnings") or []:
        d = w.get("detail")
        if d and d not in bits:
            bits.append(str(d))
    if not bits and res.get("reasons"):
        bits = list(res["reasons"])
    if not bits:
        return ""
    if len(bits) > limit:
        return "; ".join(bits[:limit]) + " 等 %d 项" % len(bits)
    return "; ".join(bits)


def summary(res: dict) -> str:
    bits = [res["verdict"], res["verdict_source"]]
    c = res.get("compat") or {}
    if c:
        bits.append("levels=%s" % json.dumps(c.get("levels"), ensure_ascii=False))
        if c.get("reason_codes"):
            bits.append("reasons=%s" % ",".join(c["reason_codes"]))
        bits.append("losses=%d unknowns=%d warnings=%d extensions=%d"
                    % (len(c.get("losses") or []), len(c.get("unknowns") or []),
                       len(c.get("warnings") or []), len(c.get("extensions") or [])))
    return " | ".join(bits)


# =============================================================
# 命令行
# =============================================================
def _load_nodes(path: str) -> list:
    text = open(path, encoding="utf-8").read()
    if path.endswith(".json"):
        d = json.loads(text)
        if isinstance(d, list):
            return d
        if isinstance(d, dict):
            for k in ("proxies", "nodes"):
                if isinstance(d.get(k), list):
                    return d[k]
        return [d]
    try:
        import yaml
    except ImportError:
        print("[ERR] 需要 PyYAML 才能读 YAML", file=sys.stderr)
        raise SystemExit(2)
    d = yaml.safe_load(text)
    if isinstance(d, list):
        return d
    if isinstance(d, dict) and isinstance(d.get("proxies"), list):
        return d["proxies"]
    return [d]


def _selftest() -> int:
    """合并层的不变量: 只许收紧、UNKNOWN 无结论必回退、字段不丢。"""
    bad = 0
    cases = [
        ({"status": "SUPPORTED"}, {"status": "UNSUPPORTED"}, "UNSUPPORTED", True, "收紧"),
        ({"status": "SUPPORTED"}, {"status": "SUPPORTED"}, "SUPPORTED", False, "一致"),
        ({"status": "UNSUPPORTED"}, {"status": "SUPPORTED"}, "UNSUPPORTED", True, "不许放宽"),
        ({"status": "SUPPORTED"}, {"status": "UNKNOWN", "losses": [], "levels": {}},
         "SUPPORTED", False, "无结论的 UNKNOWN 回退"),
        ({"status": "SUPPORTED"}, {"status": "UNKNOWN", "losses": [{"what": "x"}],
                                   "levels": {"runtime": "UNKNOWN"}},
         "UNKNOWN", False, "有确定损失的 UNKNOWN 生效"),
        ({"status": "SUPPORTED_WITH_LOSS"}, {"status": "SUPPORTED"}, "SUPPORTED_WITH_LOSS",
         False, "旧判定更差时保留旧判定"),
    ]
    for leg, com, want, want_drop, name in cases:
        leg = dict(leg, reasons=[], checks=[])
        r = merge(leg, com)
        if r["verdict"] != want or r["drop"] != want_drop:
            print("❌ %s: 得到 %s/drop=%s, 期望 %s/drop=%s"
                  % (name, r["verdict"], r["drop"], want, want_drop))
            bad += 1
    # 放宽必被挡下且留痕
    r = merge({"status": "UNSUPPORTED", "reasons": [], "checks": []},
              {"status": "SUPPORTED", "levels": {}})
    if not r["downgrades"] or r["verdict"] != "UNSUPPORTED":
        print("❌ 放宽未被保险丝挡下")
        bad += 1
    # compat 字段必须随结果带出（不许静默丢）
    fake = {"status": "SUPPORTED_WITH_LOSS", "levels": {"runtime": "SUPPORTED_WITH_LOSS"},
            "losses": [{"what": "w"}], "unknowns": [{"what": "u"}],
            "warnings": [{"code": "c"}], "extensions": [{"key": "k", "value": 1}],
            "raw_uri": "vless://x@y:1", "rules_applied": ["r"], "reason_codes": ["R"]}
    r = merge({"status": "SUPPORTED", "reasons": [], "checks": []}, fake)
    for k in ("losses", "unknowns", "warnings", "extensions", "raw_uri", "rules_applied"):
        if r["compat"].get(k) != fake.get(k):
            print("❌ 合并结果丢了 compat.%s" % k)
            bad += 1
    print("✅ selftest: %d 项通过" % (len(cases) + 2) if not bad else "❌ selftest 失败 %d" % bad)
    return 1 if bad else 0


def main(argv) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "kernel":
        info = probe_kernel()
        print(json.dumps({"probe": info, "target": kernel_target().to_dict()},
                         ensure_ascii=False, indent=1))
        return 0
    if cmd == "selftest":
        return _selftest()
    if cmd in ("json", "compare"):
        nodes = _load_nodes(argv[2])
        for i, n in enumerate(nodes, 1):
            res = judge(n)
            if cmd == "json":
                print(json.dumps(res, ensure_ascii=False, indent=1))
            else:
                c = res.get("compat") or {}
                print("%2d %-28s 旧=%-20s compat=%-20s 合并=%-20s %s"
                      % (i, str(n.get("name"))[:28], res["legacy"]["status"],
                         (c.get("status") or "-"), res["verdict"], describe(res)))
        return 0
    print("未知子命令: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
