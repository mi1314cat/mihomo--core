#!/usr/bin/env python3
"""link_check.py — 分享链接与「真的有人在听」的一致性校验（发布前闸门）

为什么必须有它
--------------
`out/<proto>_share-NN.txt` 是**派生文件**: 节点创建那一刻写下 host:port,
之后节点被删掉重建 (端口变了), 产物不会跟着变 —— 而没有任何机制发现这件事。
RN 真机实测 (2026-10-10): 12 条链接里 **10 条**指向无人监听的端口
(50877 / 21168 / 23512 / 22737 / 42099 / 56676 / 38899 / 23451 …),
`ss -tulnH` 全表都查不到; 而真实监听是 25669-25684 / 28725 / 22812。

后果与 X 内核的"死链"**同后果、不同成因**: 链接发出去是"成功"的, 客户端
拿到却永远连不上, 没有任何一处报错指向真正的原因。

判据 (与 X 内核同一套思路: listen 与发布目标必须自洽)
----------------------------------------------------
从 conf/config.d/*.yaml 取"当前在跑的 listener"(listen + port + type),
每一条链接的 host:port 必须能对上其中之一:

  * 直连节点: 端口必须等于某个 listener 的 port, 且协议族要匹配
    (anytls:// ↔ type: anytls; vless:// ↔ type: vless; …)
  * CDN 节点: host 是 cdn_bindings.tsv 里的回源域名时, 端口必须是前端端口
    (默认 443), 并且该域名绑定的**回源端口**必须是活 listener
  * 对不上 → **拒发**, 并把原因写清楚 (谁、写的多少、现在实际是什么)

退出码: 0 = 全部自洽; 1 = 有陈旧/死链 (调用方应拒发并说明)
           2 = 用法/环境错 (拿不到 conf 或 out)

用法:
    link_check.py --out-dir <out> --conf-dir <conf>            # 只报告
    link_check.py --out-dir <out> --conf-dir <conf> --json     # 机器可读
    link_check.py --out-dir <out> --conf-dir <conf> --prune     # 删掉陈旧链接
    link_check.py --out-dir <out> --conf-dir <conf> --count-only
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("[ERR] 需要 PyYAML: pip3 install pyyaml", file=sys.stderr)
    sys.exit(2)

# <proto>_share-<NN>.txt / <a>_<b>_share-<NN>.txt
SHARE_RE = re.compile(r"^(?P<stem>.+)_share-(?P<num>\d+)\.txt$")
# scheme://[user@][host]:port[/path][?query][#name]
#
# ★ body 用 `.+` 而不是 `\S+`: 显示名 (fragment) 里**带空格** —— 旗帜与名字
#   之间就有一个 ("#🇺🇸 mAnyTLS01-TLS"), 用 \S+ 会把**每一条真实链接**都判成
#   "格式坏了" (实测: RN 12/12 全判坏)。host:port 的切分在 _split_hostport
#   里做 (先切 ? 和 #), 与空格无关。
URI_RE = re.compile(r"^(?P<scheme>[A-Za-z][A-Za-z0-9+.\-]*)://(?P<body>.+)$")

# 链接 scheme ↔ 服务端 listener type。两侧是**两套命名**, 这里显式写出来,
# 不做模糊匹配 —— 匹配错了会把死链放行。
SCHEME_TYPES = {
    "anytls": {"anytls"},
    "hysteria2": {"hysteria2"},
    "hy2": {"hysteria2"},
    "tuic": {"tuic"},
    "vless": {"vless"},
    "trojan": {"trojan"},
    "ss": {"ss", "shadowsocks"},
    "snell": {"snell"},
    "vmess": {"vmess"},
}
LOOPBACK = {"127.0.0.1", "::1", "localhost", "127.0.0.2"}


def _split_hostport(body: str):
    """从 'user@host:port?...' 里取出 (host, port)。IPv6 是 [addr]:port。"""
    tail = body.split("?", 1)[0].split("#", 1)[0]
    if "@" in tail:
        tail = tail.rsplit("@", 1)[1]
    if tail.startswith("["):
        end = tail.find("]")
        if end < 0:
            return "", 0
        host = tail[1:end]
        rest = tail[end + 1:]
        port = int(rest[1:]) if rest.startswith(":") and rest[1:].isdigit() else 0
        return host, port
    if ":" not in tail:
        return tail, 0
    host, _, p = tail.rpartition(":")
    return host, int(p) if p.isdigit() else 0


def parse_link(line: str):
    """一条分享链接 → dict(scheme, host, port, name, userinfo) 或 None。"""
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    m = URI_RE.match(line)
    if not m:
        return None
    body = m.group("body")
    host, port = _split_hostport(body)
    userinfo = ""
    tail = body.split("?", 1)[0].split("#", 1)[0]
    if "@" in tail:
        userinfo = tail.rsplit("@", 1)[0]
    name = ""
    if "#" in line:
        name = line.split("#", 1)[1].strip()
    return {"scheme": m.group("scheme").lower(), "host": host, "port": port,
            "name": name, "userinfo": userinfo, "line": line}


def load_listeners(conf_dir: str):
    """读 conf/config.d/*.yaml 的 listeners → (live_ports, loopback_ports)。

    live_ports:      {port: {"name","type","listen"}}  —— 对外可达的
    loopback_ports:  {port: {...}}                     —— 只绑回环 (要靠反代)
    """
    live, loop = {}, {}
    frag_dir = os.path.join(conf_dir, "config.d")
    for p in sorted(glob.glob(os.path.join(frag_dir, "*.yaml"))):
        try:
            with open(p, encoding="utf-8") as fh:
                d = yaml.safe_load(fh) or {}
        except Exception:                                        # noqa: BLE001
            continue
        if not isinstance(d, dict):
            continue
        for it in (d.get("listeners") or []):
            if not isinstance(it, dict):
                continue
            port = it.get("port")
            if not isinstance(port, int):
                continue
            info = {"name": str(it.get("name") or ""),
                    "type": str(it.get("type") or "").lower(),
                    "listen": str(it.get("listen") or "").strip(),
                    "creds": _frag_creds(it),
                    "frag": os.path.basename(p)}
            if info["listen"].lower() in LOOPBACK:
                loop[port] = info
            else:
                live[port] = info
    return live, loop


def load_bindings(path: str):
    """cdn_bindings.tsv → {domain: [upstream_port,…]} (回源端口必须是活 listener)。"""
    out: dict[str, list[int]] = {}
    if not path or not os.path.isfile(path):
        return out
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 6 or not cols[1]:
                    continue
                try:
                    out.setdefault(cols[1], []).append(int(cols[5]))
                except ValueError:
                    continue
    except OSError:
        return out
    return out


def _frag_creds(it: dict) -> set:
    """片段里的"凭据"字符串 (uuid / password / username 的值与键)。

    users 的形状有两种: 字典 (anytls/hysteria2/tuic) 与字典列表
    (vless/trojan: `- uuid: …` / `- username: …`), 两种都要认。
    """
    out = set()
    u = it.get("users")
    items = []
    if isinstance(u, dict):
        items = [u]
    elif isinstance(u, list):
        items = [x for x in u if isinstance(x, dict)]
    for d in items:
        for k, v in d.items():
            out.add(str(k))
            if isinstance(v, str):
                out.add(v)
    return out


def load_products(out_dir: str):
    """当前客户端产物 (out/*_client-*.yaml) → [(name,type,server,port,creds)]。

    这是"节点现在长什么样"的**权威副本**: 产物与节点同生共死 (删节点走
    m_out_rm_artifacts), 而链接是历史快照。两者对不上 = 链接陈旧。
    """
    prods = []
    for p in sorted(glob.glob(os.path.join(out_dir, "*_client-*.yaml"))):
        try:
            with open(p, encoding="utf-8") as fh:
                d = yaml.safe_load(fh) or {}
        except Exception:                                        # noqa: BLE001
            continue
        if not isinstance(d, dict):
            continue
        for it in (d.get("proxies") or []):
            if not isinstance(it, dict):
                continue
            creds = {str(it[k]) for k in ("uuid", "password") if isinstance(it.get(k), str)}
            if isinstance(it.get("users"), list):                # trojan 多用户形态
                creds |= _frag_creds(it)
            prods.append({"name": str(it.get("name") or ""),
                          "type": str(it.get("type") or "").lower(),
                          "server": str(it.get("server") or ""),
                          "port": it.get("port"),
                          "creds": creds})
    return prods


def link_cred(link: dict) -> str:
    """链接里的身份凭据: vless/vmess=uuid, trojan/anytls/hysteria2=密码,
    tuic=`uuid:密码` 取 uuid。取不到返回空串 (那就只按端口判)。"""
    body = link.get("userinfo") or ""
    if not body:
        return ""
    if link.get("scheme") in ("tuic",):
        return body.split(":", 1)[0]
    if link.get("scheme") in ("ss", "ssr", "snell", "vmess"):
        return ""                       # 形态不同 (base64/vmess-json), 不硬猜
    return body


def check(out_dir: str, conf_dir: str, bindings_path: str = "",
          front_port: int = 443):
    """返回 (rows, stale_count)。rows 每项带 verdict / reason。"""
    live, loop = load_listeners(conf_dir)
    prods = load_products(out_dir)
    binds = load_bindings(bindings_path or os.path.join(os.path.dirname(
        os.path.abspath(conf_dir)), "cdn_bindings.tsv"))
    # 活凭据 = 当前片段里的 users + 当前产物里的 uuid/password。
    # 链接里的凭据**不在**这个集合里 ⇒ 那个节点已经被删掉/重建了 (凭据是
    # 每个节点唯一的, 换端口不一定换凭据, 但删了重建必然换)。
    live_creds = set()
    for p in prods:
        live_creds |= p["creds"]
    for d in (live, loop):
        for info in d.values():
            live_creds |= info["creds"]
    front_ports = set()
    for ports in binds.values():
        front_ports |= set(ports)

    rows = []
    for f in sorted(glob.glob(os.path.join(out_dir, "*_share-*.txt"))):
        base = os.path.basename(f)
        m = SHARE_RE.match(base)
        stem = m.group("stem") if m else base
        num = m.group("num") if m else ""
        try:
            with open(f, encoding="utf-8") as fh:
                lines = [x for x in fh.read().splitlines() if x.strip()]
        except OSError:
            continue
        for line in lines:
            link = parse_link(line)
            if not link:
                rows.append({"file": base, "verdict": "STALE", "line": line,
                             "reason": "不是可解析的分享链接 (格式坏了)"})
                continue
            host, port, scheme = link["host"], link["port"], link["scheme"]
            want = SCHEME_TYPES.get(scheme, set())
            cred = link_cred(link)
            entry = {"file": base, "stem": stem, "num": num, "scheme": scheme,
                     "host": host, "port": port, "name": link["name"],
                     "cred": cred, "verdict": "OK", "reason": ""}

            # ---- ① 凭据: 旧链接的凭据早就不在任何当前节点里了 ----
            if cred and cred not in live_creds:
                entry.update(verdict="STALE", reason=(
                    "链接里的凭据已不在任何当前节点里 (节点被删掉/重建过) —— "
                    "端口就算在听, 认证也过不去"))
                rows.append(entry)
                continue

            # ---- ② 与当前产物逐字段对: 同凭据的产物就是这条链接的目标 ----
            #
            # ⚠ 凭据可能**被多个节点共用** (本项目 vless/trojan/reality/tuic
            #   都用 install_info.env 里同一个 UUID), 所以候选要按协议族先过滤,
            #   否则会报出"同凭据产物指向 25684"这种指错门牌号的结论。
            same = [p for p in prods
                    if cred and cred in p["creds"] and (not want or p["type"] in want)]
            if same:
                hit = [p for p in same if p["server"] == host
                       and str(p["port"]) == str(port)]
                if hit:
                    entry["live_name"] = hit[0]["name"]
                    rows.append(entry)
                    continue
                targets = sorted({f"{p['server']}:{p['port']}" for p in same})
                if port not in live and host not in binds:
                    reason = (f"端口 {port} 无人监听 (节点已删/换端口, "
                              f"链接是陈旧的)")
                else:
                    reason = (f"同凭据的 {scheme} 节点是 {', '.join(targets[:3])}, "
                              f"链接写的却是 {host}:{port} (换了端口/地址没重建)")
                entry.update(verdict="STALE", reason=reason)
                rows.append(entry)
                continue

            if host in binds:
                # ---- CDN 节点: 前端端口 + 回源端口都得对 ----
                if port != front_port:
                    entry.update(verdict="STALE",
                                 reason=f"CDN 链接写的是 {port}, 前端端口是 {front_port}")
                else:
                    ups = [p for p in binds[host] if p in live]
                    if not ups:
                        entry.update(verdict="STALE", reason=(
                            f"CDN 回源端口 {binds[host]} 没有活 listener "
                            f"(域名 {host} 的 nginx 会 502)"))
                    elif want and not (want & {live[p]["type"] for p in ups}):
                        entry.update(verdict="STALE", reason=(
                            f"{scheme}:// 对不上回源节点类型 "
                            f"{sorted({live[p]['type'] for p in ups})}"))
            elif port in live:
                ltype = live[port]["type"]
                if want and ltype not in want:
                    entry.update(verdict="STALE", reason=(
                        f"端口 {port} 是 {ltype} 节点的 ({live[port]['name']}), "
                        f"不是 {scheme}"))
                else:
                    entry["live_name"] = live[port]["name"]
            elif port in loop:
                entry.update(verdict="STALE", reason=(
                    f"端口 {port} 只绑回环 ({loop[port]['listen']}), "
                    f"且链接用的是公网/域名 —— 外部访问不到"))
            else:
                entry.update(verdict="STALE",
                             reason=f"端口 {port} 无人监听 (节点已删/换端口, 链接是陈旧的)")
            rows.append(entry)
    stale = sum(1 for r in rows if r["verdict"] == "STALE")
    return rows, stale


def prune(out_dir: str, rows) -> int:
    """删掉**只含陈旧行**的链接文件（以及同名的 meta json）。

    ★ 只删整体陈旧的: 一个文件里混着好行与坏行时留给人看, 不静默改文件内容
      (链接文件是多行时是"多条节点", 删掉一行会让文件与文件名对不上)。
    """
    by_file: dict[str, list[dict]] = {}
    for r in rows:
        by_file.setdefault(r["file"], []).append(r)
    n = 0
    for base, rs in by_file.items():
        if any(r["verdict"] == "OK" for r in rs):
            continue
        p = os.path.join(out_dir, base)
        stem = rs[0].get("stem") or ""
        num = rs[0].get("num") or ""
        try:
            os.remove(p)
            n += 1
        except OSError:
            continue
        if stem and num:
            for g in (os.path.join(out_dir, f"{stem}_meta-{num}.json"),
                      os.path.join(out_dir, f"{stem.split('_')[-1]}_meta-{num}.json")):
                if os.path.isfile(g):
                    try:
                        os.remove(g)
                    except OSError:
                        pass
    return n


def main(argv) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--conf-dir", default="")
    ap.add_argument("--bindings", default="", help="cdn_bindings.tsv 路径")
    ap.add_argument("--front-port", type=int, default=443,
                    help="CDN 前端端口 (nginx 监听的那个, 默认 443)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--count-only", action="store_true",
                    help="只打印陈旧条数 (给 shell 用)")
    ap.add_argument("--list-stale", action="store_true",
                    help="每行一个**陈旧链接的文件名** (给 shell 用, 无表头)")
    ap.add_argument("--prune", action="store_true", help="删掉整体陈旧的链接文件")
    a = ap.parse_args(argv[1:])

    if not a.out_dir or not a.conf_dir:
        ap.print_help()
        return 2
    if not os.path.isdir(os.path.join(a.conf_dir, "config.d")):
        print(f"[ERR] 找不到 {a.conf_dir}/config.d —— 拿不到'谁在听'的名单",
              file=sys.stderr)
        return 2

    rows, stale = check(a.out_dir, a.conf_dir, a.bindings, a.front_port)

    if a.count_only:
        print(stale)
        return 1 if stale else 0
    if a.list_stale:
        # 机器可读: 只列陈旧文件, 每行一个 (调用方不许去解析下面那张表)
        for b in sorted({r["file"] for r in rows if r["verdict"] != "OK"}):
            print(b)
        return 1 if stale else 0
    if a.json:
        print(json.dumps({"total": len(rows), "stale": stale, "links": rows},
                         ensure_ascii=False, indent=1))
        return 1 if stale else 0
    if not a.quiet:
        if not rows:
            print("(out/ 下还没有分享链接产物)")
        for r in rows:
            if r["verdict"] == "OK":
                continue
            print(f"  [拒发] {r['file']}: {r.get('scheme','')}://"
                  f"{r.get('host','')}:{r.get('port','')} —— {r['reason']}",
                  file=sys.stderr)
        if stale:
            print(f"[拒发] {stale}/{len(rows)} 条分享链接与当前监听不一致 "
                  f"(这些都是连不上的死链)", file=sys.stderr)
        else:
            print(f"[OK] {len(rows)} 条分享链接全部与当前监听一致", file=sys.stderr)
    if a.prune:
        # ★ 删除数打到 stdout (机器可读), 说明打到 stderr —— 调用方靠它计数
        n = prune(a.out_dir, rows) if stale else 0
        print(n)
        if not a.quiet and n:
            print(f"[清理] 已删除 {n} 个整体陈旧的链接产物", file=sys.stderr)
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
