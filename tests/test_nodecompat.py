#!/usr/bin/env python3
"""test_nodecompat.py — proxy-node-compat 接入 M 客户端的回归断言。

跑法:
    python3 tests/test_nodecompat.py            # 无内核二进制也能跑（版本由桩提供）
    MIHOMO_BIN=/root/catmi/mihomo-client/mihomo python3 tests/test_nodecompat.py

钉住的是**性质**（不变量），不是某一条规则的快照 —— 规则库升级了不该红，
但下面任意一条断了都说明接入坏了:
  A. 判定只在 compat 发生一次: 适配层里没有任何能力表
  B. 只许收紧: 旧判定说"不能用"的节点, 合并后绝不可能"能用"
  C. UNKNOWN 的含义是"没依据": 无确定结论时一律退回旧判定
  D. 不许静默丢字段: losses/unknowns/extensions/raw_uri 随结果带出
  E. 回滚开关真的能一键回退, 且回退后结果与接入前逐字一致
  F. 真探测: 版本/发行版/build tags 来自 `mihomo -v`, 探测不到就是 None(不猜)
  G. compat 在 mihomo 上不产生假 UNSUPPORTED（全协议扫描为 0）
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "src", "lib")
sys.path.insert(0, LIB)

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  \033[32m✓\033[0m %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("  \033[31m✗\033[0m %s" % msg)


def check(cond, msg):
    ok(msg) if cond else bad(msg)
    return cond


STUB = """#!/bin/sh
cat <<'OUT'
Mihomo Meta v1.19.32 linux arm64 with go1.26.8 Wed Sep 30 16:55:22 UTC 2026
Use tags: with_gvisor
OUT
"""
_tmp = tempfile.mkdtemp(prefix="mnodecompat-")
STUB_BIN = os.path.join(_tmp, "mihomo")
with open(STUB_BIN, "w", encoding="utf-8") as fh:
    fh.write(STUB)
os.chmod(STUB_BIN, 0o755)
os.environ.setdefault("MIHOMO_BIN", STUB_BIN)

import nodecompat as nc          # noqa: E402
import validate as v             # noqa: E402

U = "00000000-0000-4000-8000-000000000000"
PK = "A" * 43


def node(**kw):
    n = {"name": "t", "type": "vless", "server": "192.0.2.1", "port": 443,
         "uuid": U, "tls": True, "servername": "a.example.com", "udp": True}
    n.update(kw)
    return n


print("\n\033[1mA. 判定只在 compat 发生一次\033[0m")
src = open(os.path.join(LIB, "nodecompat.py"), encoding="utf-8").read()
# 适配层不许出现协议白名单 / 版本区间这类"能力知识"
for pat in ("PROXY_TYPES =", "SUPPORTED\", \"UNSUPPORTED", ">= 1.19", "1.19.32,"):
    check(pat not in src, "适配层不含能力规则: %r" % pat)
check("check_node(" in src, "适配层经由 compat 的 check_node() 判定")
check(len(nc.registry().rules) > 0 and len(nc.registry().evidence) > 0,
      "vendored 规则库完整: %d 规则 / %d 证据 / %d URI 规则"
      % (len(nc.registry().rules), len(nc.registry().evidence),
         len(nc.registry().uri_rules)))

print("\n\033[1mB. 只许收紧（保险丝）\033[0m")
for legacy_status in ("SUPPORTED", "SUPPORTED_WITH_LOSS", "UNKNOWN", "UNSUPPORTED"):
    for compat_status in ("SUPPORTED", "SUPPORTED_WITH_WARNING", "SUPPORTED_WITH_LOSS",
                          "UNKNOWN", "UNSUPPORTED"):
        r = nc.merge({"status": legacy_status, "reasons": [], "checks": []},
                     {"status": compat_status, "levels": {},
                      "losses": [{"what": "x"}] if compat_status == "UNKNOWN" else []})
        if nc.STATUS_RANK[r["verdict"]] < nc.STATUS_RANK[legacy_status]:
            bad("放宽未被挡下: 旧=%s compat=%s 合并=%s" % (legacy_status, compat_status,
                                                        r["verdict"]))
            break
        if legacy_status == "UNSUPPORTED" and r["verdict"] != "UNSUPPORTED":
            bad("旧判定要剔除的节点被捞回: compat=%s" % compat_status)
            break
    else:
        continue
    break
else:
    ok("16 种组合: 合并结果永不优于旧判定, 旧判定要剔除的永不复活")

print("\n\033[1mC. UNKNOWN = 没依据 → 退回旧判定\033[0m")
r = nc.merge({"status": "SUPPORTED", "reasons": [], "checks": []},
             {"status": "UNKNOWN", "levels": {k: "UNKNOWN" for k in
                                              ("parse", "config", "runtime", "semantic")},
              "losses": [], "failure_mode": None})
check(r["kind"] == "fallback" and r["verdict"] == "SUPPORTED" and not r["drop"],
      "compat 无结论的 UNKNOWN 不改变判定")
# 真实触发: 没有 compat 规则的协议
for t, desc in (("snell", "snell"), ("wireguard", "wireguard"), ("ssh", "ssh"),
                ("mieru", "mieru")):
    rr = nc.judge(node(type=t, uuid=None, password="p"))
    check(rr["kind"] == "fallback" and rr["verdict"] == rr["legacy"]["status"],
          "%s: 注册表无规则 → 退回旧判定（%s）" % (desc, rr["verdict"]))

print("\n\033[1mD. 不许静默丢字段\033[0m")
probe = node(network="ws", **{"ws-opts": {"path": "/x"},
                              "reality-opts": {"public-key": PK, "short-id": "01"},
                              "client-fingerprint": "chrome",
                              "some-key-the-kernel-ignores": {"nested": 1}})
rr = nc.judge(probe)
c = rr["compat"]
for k in ("losses", "unknowns", "extensions", "raw_uri", "warnings", "reason_codes",
          "levels", "rules_applied", "evidence", "detected_features", "raw_fields"):
    check(k in c, "结果携带 compat.%s" % k)
ext_keys = {e["key"] for e in c["extensions"]}
check("some-key-the-kernel-ignores.nested" in ext_keys,
      "内核不认的键进了 extensions（不变式 I2）: %s" % sorted(ext_keys)[:4])
check(c["raw_fields"].get("some-key-the-kernel-ignores") == {"nested": 1},
      "原始字典整份进 raw_fields")
# profile 自身的不变量
prof = nc.profile_of(probe)
check(not prof.check_invariants(), "NodeProfile 不变量自检: %s" % prof.check_invariants())
rt = prof.roundtrip()
check(rt.to_dict() == prof.to_dict(), "序列化往返无损（不静默丢信息）")

print("\n\033[1mE. 一键回滚\033[0m")
base = nc.judge(node(network="ws", **{"reality-opts": {"public-key": PK, "short-id": "01"}}))
os.environ["MH_COMPAT_ENGINE"] = "legacy"
try:
    rolled = nc.judge(node(network="ws",
                           **{"reality-opts": {"public-key": PK, "short-id": "01"}}))
    check(rolled["compat"] is None and rolled["kind"] == "fallback",
          "MH_COMPAT_ENGINE=legacy: compat 完全不参与")
    check(rolled["verdict"] == rolled["legacy"]["status"],
          "回滚后判定 == 旧判定（%s）" % rolled["verdict"])
    os.environ.pop("MH_COMPAT_ENGINE", None)
    os.environ["XBD_COMPAT_ENGINE"] = "legacy"
    check(nc.judge(probe)["compat"] is None, "别名 XBD_COMPAT_ENGINE=legacy 同样生效")
    os.environ.pop("XBD_COMPAT_ENGINE", None)
finally:
    os.environ.pop("MH_COMPAT_ENGINE", None)
    os.environ.pop("XBD_COMPAT_ENGINE", None)
check(nc.judge(probe)["compat"] is not None, "去掉环境变量后 compat 恢复参与")

print("\n\033[1mF. 真探测（不写死、不猜）\033[0m")
info = nc.probe_kernel(STUB_BIN)
check(info["version"] == "1.19.32" and info["distribution"] == "upstream",
      "版本/发行版来自 `mihomo -v`: %s / %s" % (info["version"], info["distribution"]))
check(info["build_tags"] == ["with_gvisor"], "build tags 来自内核输出: %s" % info["build_tags"])
check(nc.probe_kernel("/nonexistent/mihomo")["version"] is None,
      "探测不到就是 None（不是 '默认支持'）")
# 版本未知时: **版本无关**的规则照常判定（compat 的纪律: 缺信息只影响
# 它真正影响的判断）, 版本相关的规则才判 UNKNOWN。
t_none = nc.Target(kernel="mihomo")
r_plain = nc.judge(node(network="ws"), target=t_none)
check(r_plain["compat"]["status"] == "SUPPORTED_WITH_WARNING",
      "版本未知时版本无关的规则照常判定（vless+ws+tls = %s）"
      % r_plain["compat"]["status"])
r_ws = nc.judge(probe, target=t_none)
check(any("Reality" in (l.get("what") or "") for l in r_ws["compat"]["losses"]),
      "版本无关的组合规则在版本未知时仍然报出损失（ws × reality）")
r_x = nc.judge(node(network="xhttp"), target=t_none)
check(any("版本未知" in u.get("why", "") or "版本未知" in u.get("what", "")
          for u in r_x["compat"]["unknowns"]),
      "版本未知时版本相关的规则记入 unknowns（不是默认支持）")
check(r_x["kind"] == "fallback",
      "版本未知且无确定结论 → 退回旧判定（%s）" % r_x["verdict"])

print("\n\033[1mG. mihomo 上不产生假 UNSUPPORTED\033[0m")
scanned = 0
unsupported = []
for ptype in sorted(v.PROXY_TYPES):
    for tr in (None, "tcp", "ws", "grpc", "h2", "httpupgrade", "xhttp", "kcp", "quic"):
        for sec in ({}, {"tls": True},
                    {"reality-opts": {"public-key": PK, "short-id": "01"}},
                    {"reality-opts": {"public-key": PK, "short-id": "01"},
                     "client-fingerprint": "chrome"}):
            n = {"name": "x", "type": ptype, "server": "192.0.2.1", "port": 443,
                 "password": "p", "psk": "p", "uuid": U, "cipher": "auto",
                 "private-key": "k"}
            if tr:
                n["network"] = tr
            n.update(sec)
            scanned += 1
            res = nc.judge(n)
            if res["verdict"] == "UNSUPPORTED" and res["legacy"]["status"] != "UNSUPPORTED":
                unsupported.append((ptype, tr, sorted(sec)))
check(scanned > 700, "全协议扫描 %d 个组合" % scanned)
check(not unsupported,
      "compat 多判出的 UNSUPPORTED: %d 个 %s" % (len(unsupported), unsupported[:5]))

print("\n\033[1mI. 分享链接通路（parse_uri, 保真最高）\033[0m")
uri = ("vless://%s@192.0.2.9:443?encryption=none&security=reality&sni=a.example.com"
       "&fp=chrome&pbk=%s&sid=0123456789abcdef&type=kcp#KCP" % (U, PK))
ru = nc.judge(uri)
check(ru["compat"] is not None and ru["compat"]["raw_uri"] == uri,
      "raw_uri 与输入逐字节一致（不变式 I1）")
check(ru["legacy"]["status"] == "SUPPORTED" and ru["kind"] == "tightened",
      "分享链接: 旧判定不表态(交给内核), 结论全部来自 compat")
check(any("mkcp" in (l.get("what") or "") for l in ru["compat"]["losses"]),
      "分享链接里 network=kcp 的静默降级被抓到（%s）"
      % [l["what"][:24] for l in ru["compat"]["losses"]])
check(nc.judge("unknownscheme://x@192.0.2.9:1?y=1#U")["kind"] == "fallback",
      "未收录 scheme 的链接 → compat 判 UNKNOWN → 退回旧判定（不误剔）")
check(nc.judge("hysteria2://pw@192.0.2.9:8443?sni=a.example.com#HY2")["compat"]["status"]
      == "SUPPORTED_WITH_WARNING", "hysteria2 链接被判为可用（不是不支持）")

print("\n\033[1mH. 语料双跑\033[0m")
corpus = os.path.join(ROOT, "tools", "compat-corpus.json")
proc = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "nodecompat-compare.py")],
                      capture_output=True, text=True,
                      env=dict(os.environ, MIHOMO_BIN=STUB_BIN))
check(proc.returncode == 0, "nodecompat-compare.py 退出码 0")
check("relaxed    : 0" in proc.stdout, "语料 relaxed = 0（无静默放宽）")
import re as _re
_m = _re.search(r"fuse_fired\s*:\s*(\d+)\s+期望\s*(\d+)\s+(✅|❌)", proc.stdout)
check(bool(_m) and _m.group(1) == _m.group(2) and _m.group(3) == "✅",
      "保险丝触发次数与期望一致（%s）" % (_m.group(0) if _m else "未找到"))
check(json.load(open(corpus, encoding="utf-8"))["cases"], "语料非空")

print("\n\033[1m结果\033[0m")
print("  \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
