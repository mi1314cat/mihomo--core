#!/usr/bin/env python3
"""test_protocols.py — 逐个协议验证连通性 (在客户端跑)

对每个节点:
  1. 控制 API /proxies/<name>/delay  -> 测延迟
  2. 把 PROXY 组临时切到该节点, 真发一个 HTTP 请求 -> 确认真的能出网

用法: test_protocols.py <secret文件或config.yaml> <控制器地址> <mixed端口>
"""
import json, sys, os, re, time, urllib.request, urllib.parse, subprocess

NL = chr(10)          # 避免在源码里写转义反斜杠时被 shell/补丁搞坏


def load_secret(path):
    """既支持单独的 secret 文件, 也支持直接从 config.yaml 里取"""
    txt = open(path, encoding="utf-8").read()
    if NL not in txt.strip():          # 单行内容 => 就是 secret 文件
        return txt.strip()
    m = re.search("^secret:\\s*['\"]?([^'\"\n]+)", txt, re.M)
    if not m:
        raise SystemExit("在 %s 里找不到 secret" % path)
    return m.group(1).strip()


SECRET = load_secret(sys.argv[1])
HOST, CTRL_PORT, MIXED_PORT = sys.argv[2], sys.argv[3], sys.argv[4]
BASE = "http://%s:%s" % (HOST, CTRL_PORT)
H = {"Authorization": "Bearer " + SECRET}
PROXY_URL = "http://%s:%s" % (HOST, MIXED_PORT)
TEST_URL = "http://www.gstatic.com/generate_204"


def api(path, method="GET", body=None):
    req = urllib.request.Request(BASE + path, headers=H, method=method)
    if body is not None:
        req.data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read()
    return json.loads(raw) if raw.strip() else {}


def probe_delay(name):
    try:
        u = ("%s/proxies/%s/delay?timeout=8000&url=%s"
             % (BASE, urllib.parse.quote(name), urllib.parse.quote(TEST_URL)))
        return json.load(urllib.request.urlopen(
            urllib.request.Request(u, headers=H), timeout=15)).get("delay")
    except Exception:
        return None


def probe_egress():
    try:
        r = subprocess.run(
            ["curl", "-s", "-m", "25", "-x", PROXY_URL, "http://api.ipify.org"],
            capture_output=True, text=True, timeout=35)
        return r.stdout.strip() or "失败"
    except Exception:
        return "失败"


proxies = api("/proxies")["proxies"]
SKIP_TYPES = {"Direct", "Reject", "Pass", "Compatible", "PassRule", "RejectDrop"}


def collect(proxies):
    """顶层 /proxies 只有组, 真实节点藏在 provider 的 Selector.all 里, 必须递归展开"""
    out = {}

    def walk(mapping, depth=0):
        if depth > 4:
            return
        # provider 的 .all 是 [名字, ...] 的列表, 组自己的 .all 也是
        if isinstance(mapping, list):
            for nm in mapping:
                info = proxies.get(nm)
                if isinstance(info, dict):
                    _one(nm, info, depth)
            return
        for name, v in mapping.items():
            if isinstance(v, dict):
                _one(name, v, depth)

    def _one(name, v, depth):
        t = v.get("type", "")
        if t in ("Selector", "URLTest", "Fallback", "LoadBalance"):
            kids = v.get("all") or []
            if isinstance(kids, list):
                for nm in kids:
                    info = proxies.get(nm)
                    if isinstance(info, dict):
                        _one(nm, info, depth + 1)
                    elif isinstance(nm, str) and nm not in out:
                        out[nm] = {"type": "?"}
        elif t not in SKIP_TYPES and not name.startswith(
                ("PROXY", "AUTO", "GLOBAL")):
            out[name] = v

    walk(proxies)
    return out


nodes = collect(proxies)

print("客户端: %s   待测节点: %d" % (HOST, len(nodes)))
print()
print("  %-28s%-11s%8s   实际出口" % ("节点", "类型", "延迟"))
print("  " + "-" * 72)

results = []
for name, v in sorted(nodes.items(), key=lambda x: (x[1].get("type", ""), x[0])):
    try:
        info = api("/proxies/" + urllib.parse.quote(name))
        v = {"type": info.get("type", "?")}
    except Exception:
        v = {"type": "?"}
    d = probe_delay(name)
    try:
        api("/proxies/PROXY", "PUT", {"name": name})
        time.sleep(0.8)
        ip = probe_egress()
    except Exception as e:
        ip = "失败(%s)" % type(e).__name__
    results.append({"name": name, "type": v.get("type", "?"),
                    "delay": d, "egress": ip})
    ds = ("%dms" % d) if isinstance(d, int) else "—"
    print("  %-28s%-11s%8s   %s" % (name, v.get("type", "?"), ds, ip))


def good(r):
    e = str(r["egress"])
    return bool(e) and not e.startswith("失败")


ok = [r for r in results if good(r)]
print()
print("  实际可用 %d/%d" % (len(ok), len(results)))

by_type = {}
for r in results:
    e = by_type.setdefault(r["type"], [0, 0])
    e[1] += 1
    if good(r):
        e[0] += 1
print()
print("  按协议:")
for t, (g, n) in sorted(by_type.items()):
    mark = "✓" if g == n else ("✗" if g == 0 else "!")
    print("    %s %-12s%d/%d" % (mark, t, g, n))

json.dump(results, open("/tmp/proto_results.json", "w"),
          ensure_ascii=False, indent=1)
sys.exit(0 if len(ok) == len(results) else 1)
