#!/usr/bin/env python3
"""build_uri.py — 节点视图 → 分享链接 (URI 列表) = M 的**普通话产品**

三家互通里的两个产品 (设计: proxy-node-compat/docs/three-way-interop.md §5):

    普通话 (URI 列表)   ← 本文件       任何客户端都能读 (xbd / sb-client / mihomo / 第三方)
    原生   (mihomo YAML) ← build_sub.py 只有 mihomo 内核读

为什么 M 需要这一份
------------------
M 的原生产品是 `proxies:` YAML —— 跨内核客户端 (Xray 的 xbd) **读不了**:
实测 `xbd node sub` 对 mihomo YAML 解析出 19 个空壳 (name=node, address=""),
导入 0/19。这不是谁的 bug, 是跨生态格式边界; 解法不是让 xbd 学 YAML, 而是
M 也产出**普通话**(URI 列表) —— xbd 与 mihomo 内核本来都会解析 URI 列表。

节点集合与原生**必须一致** (设计 §5): 所以收集/过滤逻辑不在这里重写, 直接调
build_sub.build_buckets / select_proxies —— 两条产品同源, 一漂移就是
"两条产品给不同的人, 发布的节点却不一样"。

★ 为什么不是把 out/<proto>_share-NN.txt 拼起来
----------------------------------------------
那是 M 的历史链接产物, 是**派生文件**: 节点删掉重建 (端口/口令换了) 时它不会
跟着变。RN 真机实测 (2026-10-10): 12 条链接里 10 条指向无人监听的端口或已失效
的凭据 —— 专门的校验器就是为这个存在的 (src/share/link_check.py)。
19 个活节点里只有 3 条的链接还自洽。拿它当"普通话产品", 用户会拿到一份几乎
连不上的订阅, 而且是静默的。所以这里**从当前节点视图现算** —— 与 YAML 产品
同一份输入、同一批节点。

字段名从哪来 (不是发明的)
------------------------
每个协议的 query 键都取自本仓库**已有的产出者**与它们记录的实测事实:
  * hysteria2: src/conf/hysteria2.sh:479 `hy2_link()` —— mihomo 的 hy2 URI
    分支只认 sni / insecure / alpn / pinSHA256 / up / down (代码注释里钉了
    converter.go 行号); upmbps/downmbps 是给 sing-box 系写的第二套名字。
  * vless: src/conf/VLESS.sh:367 `render_share_link()` ——
    encryption=none / security / sni / fp / type / mode / path / host / serviceName / ech
  * trojan: src/conf/Trojan.sh:190 `render_share_link()` ——
    security / sni / type / path / host / serviceName / fp / pbk / sid
  * anytls: src/conf/AnyTLS.sh:537 / tuic: src/conf/TUIC.sh:357
  * 链接形状的既有样例: out/*_share-*.txt

URI 表达不了的字段**逐条报出来**(stderr, `[损失] 节点: 字段 —— 原因`), 不静默丢:
"不许为了看起来能用而静默降级" (设计 §3)。形状与 compat 的 losses 口径一致
(docs/uri-representation.md)。

用法:
    build_uri.py --out-dir <out> [--conf-dir <conf>] [--tag all] [-o out.txt]
    build_uri.py --out-dir <out> --conf-dir <conf> --list-losses   # 只报告损失
"""
from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_sub as BS                                            # noqa: E402

# 显示名放在 fragment。**百分号编码**而不是原样写: 名字里有旗帜与空格
# (naming.py 产出 "🇺🇸 mAnyTLS01-TLS"), 裸写进 URL 在个别客户端里会被
# 截断或改写 —— 而名字对不上, 客户端会把**同一个节点落成两份**。
def _frag(name: str) -> str:
    return urllib.parse.quote(str(name or ""), safe="")


def _host(h) -> str:
    """IPv6 字面量必须写成 [addr] (与 src/lib/env.sh 的 m_uri_host 同规则)。"""
    s = str(h or "").strip()
    if not s:
        return ""
    try:
        ip = ipaddress.ip_address(s)
        return f"[{s}]" if ip.version == 6 else s
    except ValueError:
        return s


def _q(pairs) -> str:
    """query 串。空值不写 —— 写 `path=` 空串会被个别解析器当成空路径。"""
    out = []
    for k, v in pairs:
        if v is None:
            continue
        v = str(v)
        if v == "":
            continue
        out.append((k, v))
    return urllib.parse.urlencode(out, quote_via=urllib.parse.quote, safe="")


def _b(v) -> str:
    """bool → "1"/"0" (链接侧约定, 不是 Python 的 True/False)。

    实测依据: mihomo 的 URI 解析器对 `insecure` 用 strconv.ParseBool 之类,
    认 1/0/true/false; 而 xbd 侧读的是同一批键。写 "True"/"False" (Python
    repr) 是第三个写法, 部分解析器认不出 —— 不再引入第三种拼法。
    """
    if isinstance(v, str):
        return "1" if v.strip().lower() in ("1", "true", "yes", "on") else "0"
    return "1" if v else "0"


def _hex64(v) -> bool:
    return bool(re.fullmatch(r"[0-9a-fA-F]{64}", str(v or "").strip()))


def _num(v):
    """带宽一类的数值: "50 Mbps" → "50"; 取不到返回 ("", 原因)。

    ★ 这一步不是"宽容解析", 是**必须**做的: RN 真机产物里存在
      `up: 50 Mbps` (带单位、非整数) —— mihomo 的 provider 读得进去, 而
      链接侧的 up/down 是纯数字。把 "50 Mbps" 原样写进链接 = 对方拿不到带宽。
      取不出数字时**不写**该参数并报损失 (宁可不写, 不写坏的)。
    """
    if v is None or isinstance(v, bool):
        return "", "取不到数值"
    if isinstance(v, (int, float)):
        return (f"{v:g}", "")
    s = str(v).strip()
    m = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z/]*)$", s)
    if not m:
        return "", f"不是可解析的带宽值: {v!r}"
    unit = m.group(2).lower()
    if unit and unit not in ("m", "mbps", "mb", "mbit", "mb/s"):
        return "", f"带宽单位不认识: {v!r}"
    return m.group(1), ""


# ------------------------------------------------------------------ 每协议
# 返回 (uri, losses)。uri 为空表示这个节点做不出链接。
def _uri_vlesslike(p, scheme, user):
    """vless / trojan 共用的一支 (两者传输与 TLS 参数完全同形)。"""
    losses = []
    host = p.get("server")
    port = p.get("port")
    net = str(p.get("network") or "tcp").lower()
    q = []
    if scheme == "vless":
        q.append(("encryption", p.get("encryption") or "none"))
        if p.get("flow"):
            q.append(("flow", p["flow"]))
    real = p.get("reality-opts") if isinstance(p.get("reality-opts"), dict) else {}
    tls_on = bool(p.get("tls")) or bool(p.get("servername") or p.get("sni")) or bool(real)
    if real:
        q.append(("security", "reality"))
    elif tls_on:
        q.append(("security", "tls"))
    if net and net != "tcp":
        q.append(("type", net))
    else:
        q.append(("type", "tcp"))
    sni = p.get("servername") or p.get("sni")
    if sni:
        q.append(("sni", sni))
    if p.get("client-fingerprint"):
        q.append(("fp", p["client-fingerprint"]))
    elif real:
        losses.append("reality 节点缺 client-fingerprint —— 链接里不写 fp "
                      "(不猜一个默认指纹)")
    if real:
        q.append(("pbk", real.get("public-key") or real.get("public_key")))
        q.append(("sid", real.get("short-id") or real.get("short_id")))
        if real.get("support-x25519mlkem768"):
            q.append(("pqv", _b(real.get("support-x25519mlkem768"))))
        for k in real:
            if k not in ("public-key", "public_key", "short-id", "short_id",
                         "support-x25519mlkem768"):
                losses.append(f"reality-opts.{k} —— 链接规范里没有这个键")
    if p.get("skip-cert-verify") is not None and not real:
        # reality 分支的 skip-cert-verify 无意义 (握手由 pbk/sid 决定), 不写
        q.append(("insecure", _b(p.get("skip-cert-verify"))))
    if p.get("alpn") and not real:
        alpn = p["alpn"]
        q.append(("alpn", ",".join(alpn) if isinstance(alpn, list) else alpn))
    if p.get("certificate") or p.get("private-key"):
        losses.append("certificate/private-key (mTLS 客户端证书) —— "
                      "分享链接装不下 PEM, 原生 YAML 里有")
    if p.get("packet-encoding"):
        q.append(("packetEncoding", p["packet-encoding"]))

    # ---- 传输 ----
    if net == "ws":
        ws = p.get("ws-opts") if isinstance(p.get("ws-opts"), dict) else {}
        q.append(("path", ws.get("path") or "/"))
        hdr = ws.get("headers") if isinstance(ws.get("headers"), dict) else {}
        h = hdr.get("Host") or hdr.get("host") or ws.get("host")
        if h:
            q.append(("host", h))
        elif sni:
            # M 的既有产出者 (VLESS.sh/Trojan.sh) 在 ws 分支写 host=$CLIENT_HOST
            # —— 由服务端自己决定, 客户端侧 YAML 里没有 Host 头时用 sni 兜底,
            # 与 YAML 的 servername 是同一个值, 不引入新事实。
            q.append(("host", sni))
        for k in ws:
            if k not in ("path", "headers", "host", "max-early-data",
                         "early-data-header-name", "v2ray-http-upgrade"):
                losses.append(f"ws-opts.{k} —— 链接规范里没有这个键")
    elif net == "grpc":
        gr = p.get("grpc-opts") if isinstance(p.get("grpc-opts"), dict) else {}
        sn = gr.get("grpc-service-name") or gr.get("serviceName")
        if sn:
            q.append(("serviceName", sn))
        else:
            losses.append("grpc 节点缺 grpc-service-name —— 链接里没有 serviceName")
        if gr.get("grpc-mode") not in (None, "", "gun"):
            losses.append(f"grpc-opts.grpc-mode={gr.get('grpc-mode')} —— 链接不带 mode")
    elif net == "xhttp":
        xh = p.get("xhttp-opts") if isinstance(p.get("xhttp-opts"), dict) else {}
        q.append(("path", xh.get("path") or "/"))
        if xh.get("mode"):
            q.append(("mode", xh["mode"]))
        hm = xh.get("host") or xh.get("headers", {}).get("Host") if isinstance(
            xh.get("headers"), dict) else xh.get("host")
        if hm:
            q.append(("host", hm))
        for k in xh:
            if k in ("path", "mode", "host", "headers"):
                continue
            # x-padding-bytes / xhttp-level 之类是 mihomo 私有形态:
            # 链接里没有对应键 → 必须报损失, 不许假装还在。
            losses.append(f"xhttp-opts.{k}={xh[k]} —— 分享链接规范里没有这个键 "
                          "(原生 YAML 里有)")
    elif net == "h2":
        h2 = p.get("h2-opts") if isinstance(p.get("h2-opts"), dict) else {}
        q.append(("path", h2.get("path") or "/"))
        if h2.get("host"):
            q.append(("host", h2["host"] if isinstance(h2["host"], str)
                      else ",".join(h2["host"])))
    elif net not in ("tcp",):
        losses.append(f"network={net} —— 链接侧的 type 没有这个取值 (按 tcp 写会更糟: "
                      "对方会把 tcp 当成真的在跑)")

    # ---- ECH (mihomo ech-opts / Xray 的 ech=) ----
    ech = p.get("ech-opts") if isinstance(p.get("ech-opts"), dict) else {}
    if ech.get("enable"):
        q.append(("ech", ECH_QUERY))
        losses.append("ech-opts.query-server-name 等 ECH 细分项 —— 链接只带 "
                      "ConfigList 发现串 (compat: uri.vless.ech = PARTIAL)")

    # ---- 其它在 YAML 里存在但链接装不下的 ----
    for k in p:
        if k in ("name", "type", "server", "port", "network", "tls", "udp",
                 "sni", "servername", "alpn", "skip-cert-verify", "client-fingerprint",
                 "flow", "encryption", "packet-encoding", "reality-opts",
                 "ws-opts", "grpc-opts", "xhttp-opts", "h2-opts", "ech-opts",
                 "username", "uuid", "password", "certificate", "private-key",
                 "fingerprint", "mport", "ports", "hop-interval"):
            continue
        losses.append(f"{k} —— 分享链接里没有对应键 (原生 YAML 里有)")

    uri = f"{scheme}://{user}@{_host(host)}:{port}"
    query = _q(q)
    return uri + (f"?{query}" if query else "") + "#" + _frag(p.get("name")), losses


ECH_QUERY = "cloudflare-ech.com+https://dns.alidns.com/dns-query"
DEFAULT_HY2_ALPN = "h3"


def build_uri(p) -> tuple[str, list[str]]:
    """mihomo proxy 条目 → (分享链接, 损失列表)。做不出链接时 uri 为空。"""
    t = str(p.get("type") or "").strip().lower()
    name = p.get("name")
    losses: list[str] = []

    if t in ("vless", "trojan"):
        user = p.get("uuid") if t == "vless" else p.get("password")
        if not user:
            return "", [f"{t} 节点缺 {'uuid' if t == 'vless' else 'password'} —— "
                        "链接没法表达认证信息"]
        return _uri_vlesslike(p, t, urllib.parse.quote(str(user), safe=""))

    if t == "anytls":
        pw = p.get("password")
        if not pw:
            return "", ["anytls 节点缺 password"]
        q = [("sni", p.get("sni") or p.get("servername"))]
        if p.get("skip-cert-verify") is not None:
            q.append(("insecure", _b(p.get("skip-cert-verify"))))
        if p.get("client-fingerprint"):
            q.append(("fp", p["client-fingerprint"]))
        if p.get("alpn"):
            q.append(("alpn", ",".join(p["alpn"]) if isinstance(p["alpn"], list)
                      else p["alpn"]))
        for k in p:
            if k in ("name", "type", "server", "port", "password", "sni",
                     "servername", "skip-cert-verify", "client-fingerprint",
                     "alpn", "udp"):
                continue
            losses.append(f"{k} —— 分享链接的 anytls 形态里没有这个键 "
                          "(原生 YAML 里有)")
        return (f"anytls://{urllib.parse.quote(str(pw), safe='')}@"
                f"{_host(p.get('server'))}:{p.get('port')}?"
                f"{_q(q)}#{_frag(name)}"), losses

    if t in ("hysteria2", "hy2"):
        pw = p.get("password")
        if not pw:
            return "", ["hysteria2 节点缺 password"]
        q = [("sni", p.get("sni") or p.get("servername"))]
        insecure = p.get("skip-cert-verify")
        pin = p.get("pinSHA256") or p.get("pin")
        # ★ 自签节点的证书 pin: M 的客户端 YAML 把 sha256 写在 `fingerprint:` 里
        #   (hysteria2.sh:468, 已知缺陷 P-4 —— mihomo 的 hysteria2 fingerprint
        #   语义是证书指纹, 但同一个键在别的协议里是 uTLS 指纹名, 混用会误导)。
        #   判据是**值本身** (64 位十六进制 = sha256), 不是猜。
        #
        # ★★ 参数名必须**两个都写**: 两家客户端读的不是同一个键 ——
        #     mihomo 的 hy2 URI 分支只认 `pinSHA256`(写 `pin` 被静默忽略,
        #       hysteria2.sh:493-496 的实测结论, 行号来自 mihomo 源码);
        #     Xray 系 (xbd/lib/node.py:489) 只读 `pin=`;
        #   实测踩到: 只写 pinSHA256 时, xbd 解析出的 pinned_cert_sha256 为空 →
        #   自签节点按"校验证书"走 → `mHysteria202-TLS` 真连 http=000 (其余 14 个
        #   全 204)。这与带宽参数是同一类问题, 处理方式也照抄那套"两套名字都写":
        #   各自取自己认识的那个, 多出来的是普通未知参数。
        fp = p.get("fingerprint")
        if not pin and _hex64(fp):
            pin = str(fp).strip()
            losses.append("fingerprint 是 64 位十六进制 (证书 sha256) —— 按 "
                          "pinSHA256(mihomo)+pin(Xray 系) 两个键写进链接; 该键在 M 的"
                          "客户端 YAML 里与 uTLS 指纹名同名 (P-4)")
        elif fp and not _hex64(fp):
            q.append(("fp", fp))
        if pin:
            q.append(("pinSHA256", pin))     # mihomo 认这个
            q.append(("pin", pin))           # Xray 系 (xbd) 认这个
        elif insecure is not None:
            q.append(("insecure", _b(insecure)))
        alpn = p.get("alpn") or DEFAULT_HY2_ALPN
        q.append(("alpn", ",".join(alpn) if isinstance(alpn, list) else alpn))
        for key, alias in (("up", "upmbps"), ("down", "downmbps")):
            val, why = _num(p.get(key))
            if val:
                # 两套名字都写: mihomo 的 hy2 分支只认 up/down, sing-box 系面板
                # 认 upmbps/downmbps (hysteria2.sh:484-490 的实测结论)。
                q.append((key, val))
                q.append((alias, val))
            elif p.get(key) is not None:
                losses.append(f"{key}={p.get(key)!r} —— {why}, 链接里不写带宽")
        if p.get("obfs"):
            q.append(("obfs", p["obfs"]))
            q.append(("obfs-password", p.get("obfs-password")))
        if p.get("ports") or p.get("mport"):
            losses.append("ports/hop-interval (端口跳跃) —— 链接形态里没有 mport, "
                          "原生 YAML 的 ports 才带跳跃 (客户端会以为只有一个端口)")
        for k in p:
            if k in ("name", "type", "server", "port", "password", "sni",
                     "servername", "skip-cert-verify", "alpn", "up", "down",
                     "obfs", "obfs-password", "ports", "hop-interval", "udp",
                     "fingerprint", "pinSHA256", "pin", "mport"):
                continue
            losses.append(f"{k} —— 分享链接里没有对应键 (原生 YAML 里有)")
        return (f"hysteria2://{urllib.parse.quote(str(pw), safe='')}@"
                f"{_host(p.get('server'))}:{p.get('port')}?"
                f"{_q(q)}#{_frag(name)}"), losses

    if t == "tuic":
        uuid, pw = p.get("uuid"), p.get("password")
        if not uuid:
            return "", ["tuic 节点缺 uuid"]
        q = [("sni", p.get("sni") or p.get("servername")),
             ("alpn", ",".join(p["alpn"]) if isinstance(p.get("alpn"), list)
              else (p.get("alpn") or "h3"))]
        if p.get("skip-cert-verify") is not None:
            v = _b(p.get("skip-cert-verify"))
            # 两套名字都写 (TUIC.sh:357 的既有产出者就是这么发的:
            # insecure 给 mihomo 系, allowInsecure 给另一批客户端)。
            q.append(("insecure", v))
            q.append(("allowInsecure", v))
        cc = p.get("congestion-controller") or p.get("congestion_control")
        if cc:
            q.append(("congestion_control", cc))
        if p.get("udp-relay-mode"):
            q.append(("udp_relay_mode", p["udp-relay-mode"]))
        for k in p:
            if k in ("name", "type", "server", "port", "uuid", "password", "sni",
                     "servername", "skip-cert-verify", "alpn", "udp",
                     "congestion-controller", "congestion_control",
                     "udp-relay-mode", "disable-sni"):
                continue
            losses.append(f"{k} —— 分享链接的 tuic 形态里没有这个键 "
                          "(原生 YAML 里有)")
        user = f"{urllib.parse.quote(str(uuid), safe='')}"
        if pw:
            user += f":{urllib.parse.quote(str(pw), safe='')}"
        return (f"tuic://{user}@{_host(p.get('server'))}:{p.get('port')}?"
                f"{_q(q)}#{_frag(name)}"), losses

    if t == "shadowsocks":
        method, pw = p.get("cipher") or p.get("method"), p.get("password")
        if not (method and pw):
            return "", ["shadowsocks 节点缺 cipher/password"]
        blob = base64.urlsafe_b64encode(f"{method}:{pw}".encode()).decode().rstrip("=")
        if p.get("plugin"):
            losses.append("plugin/plugin-opts —— 链接里只写 SIP002 的 plugin 参数, "
                          "本函数不猜它的序列化形式, 故未写")
        return (f"ss://{blob}@{_host(p.get('server'))}:{p.get('port')}"
                f"#{_frag(name)}"), losses

    if t == "vmess":
        body = {"v": "2", "ps": str(name or ""), "add": str(p.get("server") or ""),
                "port": str(p.get("port") or ""), "id": str(p.get("uuid") or ""),
                "aid": str(p.get("alterId") or 0), "scy": str(p.get("cipher") or "auto")}
        if p.get("network"):
            body["net"] = str(p["network"])
        if p.get("tls"):
            body["tls"] = "tls"
        if p.get("servername") or p.get("sni"):
            body["sni"] = str(p.get("servername") or p.get("sni"))
        ws = p.get("ws-opts") if isinstance(p.get("ws-opts"), dict) else {}
        if ws.get("path"):
            body["path"] = str(ws["path"])
        payload = base64.b64encode(json.dumps(
            body, ensure_ascii=False, separators=(",", ":")).encode()).decode()
        return f"vmess://{payload}", losses

    return "", [f"type={t} 还没有链接形态 (原生 YAML 里有这个节点)"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--conf-dir", default="")
    ap.add_argument("--import-dir", default="")
    ap.add_argument("--providers-dir", default="")
    ap.add_argument("--tag", default="all")
    ap.add_argument("-o", "--output", default="")
    ap.add_argument("--base64", action="store_true",
                    help="base64 包一层 (标准 v2ray 订阅形态; 默认逐行明文)")
    ap.add_argument("--list-losses", action="store_true",
                    help="只列出 URI 装不下的字段 (机器可读, 一行一条)")
    args = ap.parse_args()

    buckets = BS.build_buckets(args.out_dir, args.conf_dir, args.import_dir,
                               args.providers_dir)
    proxies = BS.select_proxies(buckets, args.tag)
    if not proxies:
        print(f"[ERR] 没有任何可用节点 (tag={args.tag})", file=sys.stderr)
        return 1

    lines, skipped = [], []
    nloss = 0
    for p in proxies:
        uri, losses = build_uri(p)
        if not uri:
            skipped.append((p.get("name"), losses[0] if losses else "未知原因"))
            continue
        lines.append(uri)
        for x in losses:
            nloss += 1
            msg = "[损失] %s: %s" % (p.get("name"), x)
            if args.list_losses:
                print(msg)
            else:
                print(msg, file=sys.stderr)

    if skipped:
        # 一条都做不出链接时**不许**输出空产品当成功 —— 那正是"看起来能用"。
        for nm, why in skipped:
            msg = "[未覆盖] %s: %s" % (nm, why)
            if args.list_losses:
                print(msg)
            else:
                print(msg, file=sys.stderr)
            nloss += 1

    if not lines:
        print("[ERR] 一个节点都做不出分享链接 —— 普通话产品会是空的",
              file=sys.stderr)
        return 1

    if args.list_losses:
        return 0

    body = "\n".join(lines) + "\n"
    if args.base64:
        body = base64.b64encode(body.encode()).decode() + "\n"
    if args.output:
        tmp = args.output + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(f"# mihomo--core 自动生成的分享链接 (URI 列表, tag={args.tag})\n")
            fh.write(f"# 共 {len(lines)} 条; 与原生 YAML 产品同一批节点\n")
            fh.write(body)
        os.replace(tmp, args.output)
        print(f"[OK] 已生成 {args.output} ({len(lines)} 条链接, "
              f"{nloss} 处损失已报)", file=sys.stderr)
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
