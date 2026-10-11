#!/usr/bin/env python3
"""三家互通 · 内核声明与格式选择 (格式层, 与 compat 的能力层分工明确)。

    · 服务端: 把"我是哪个内核的哪个发行版 + 我提供哪些格式 + 每种格式从哪取"
      写进**它自己生成的那个订阅地址**(查询串)。
    · 客户端: 读这一个地址就能决定"拉原生还是拉普通话" —— 不猜 User-Agent、
      不做往返协商、不改任何已发出的载荷格式。

设计原文(字段定义 / 为什么不能放响应头 / 为什么不能放内容里 /
决策规则与回退链 / 与 compat 的分工):
    proxy-node-compat/docs/three-way-interop.md
参照实现(X 内核, 已真机验收):
    xray--core conf/lib/interop.py + Client/lib/interop.py
    proxy-node-compat/research/integration/three-way-interop-x.md

本文件是**同一份实现, 服务端与客户端共用**(M 的 src/lib/ 两侧都装):
    src/share/share.sh  (服务端, 建分享时声明)
    src/client.sh       (客户端, 读声明决定拉哪一份)
X 那边是两份逐字节副本 + 门禁比对 sha256, 因为它的服务端与客户端在两个目录里;
M 的服务端与客户端共享 src/lib/, 所以这里**只有一份** —— 少一份副本就少一处
漂移("服务端声明的字段名和客户端读的字段名不一致"的表现是**静默全走普通话**:
没有报错, 只是原生格式永远拿不到)。门禁断言仓库里不存在第二份。

为什么声明放 URL 查询串(三条都是可验证的, 不是偏好):
  1. 公共服务 proxy-share-service 的路由先剥查询串再分发
     (`share_service.py` `path = self.path.split("?", 1)[0]`),
     所以未知查询参数对返回内容**零影响** —— 第三方客户端即使原样拉走带声明的
     地址, 拿到的仍是原来那份载荷。
  2. 公共服务发不出 provider 自定义响应头(`_send()` 只发 Content-Type /
     Content-Length / Cache-Control, `extra` 只有 Content-Disposition),
     唯一的 meta 端点是「回环 + Bearer」的管理 API, 远端客户端读不到。
  3. 改载荷内容(在订阅里塞声明行)会动到已经发出去的格式, 而第三方解析器对
     它的容忍度在本环境**无法证明** → 按项目纪律不允许当成前提。

M 侧的格式词表(**发行版标签与 compat 的能力判定同源**):
    官方 mihomo 二进制 → `upstream`(nodecompat.probe_kernel 的口径: 版本行里
    有 mihomo 就是官方上游); 认不出/fork → 版本行首词。**不许**另起一套
    "mihomo" 之类的新名字 —— X 的设计文档明确警告过: 声明里那个标签必须和
    compat 用来判能力的那个标签是同一个字符串, 否则"声明匹配上了、能力判定却
    按另一个名字走"。门禁用真二进制比对两者的输出。
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import urllib.parse

# ---------------------------------------------------------------- 常量
# 声明规范的版本。不认识的版本 = 不认识这份声明 → 走最通用的普通话。
INTEROP_SCHEMA = 1

# 声明存在标记。它必须显式存在, 否则"声明缺失"与"某些参数恰好同名的第三方
# 订阅地址"分不开 —— 而这两种情况的处置是**必须**区分开的(缺失要报出来)。
MARKER = "interop"
PARAM_KERNEL = "kernel"
PARAM_DIST = "distribution"
PARAM_VERSION = "version"
PARAM_FORMATS = "formats"
URL_PREFIX = "url-"

# 内核词表 —— 与公共分享服务的 provider 命名**同一套**
# (proxy-share-service 的 provider 取值: mihomo / xray / sing-box)。
KERNELS = ("xray", "sing-box", "mihomo")

# 本文件所属的内核。M 仓库 = mihomo 内核。
MY_KERNEL = "mihomo"

# 普通话格式名。它**恒在**清单里, 且它的地址就是主 URL 本身。
FORMAT_URI = "uri"

# 决策结果(reason code)。客户端日志、门禁断言、验收报告都引用这几个字符串,
# 所以它们是接口的一部分, 不许随手改。
R_NO_DECL = "no-declaration"          # 地址上没有声明
R_BAD_SCHEMA = "unknown-schema"       # 声明在, 但规范版本不认识
R_UNKNOWN_KERNEL = "unknown-kernel"   # kernel 缺失 / 不是内核名
R_CROSS_KERNEL = "cross-kernel"       # 内核不同
R_SELF_UNKNOWN = "self-unknown"       # 本机内核/发行版探测不出来(不猜)
R_DIST_NOT_LISTED = "distribution-not-listed"   # 发行版不在 formats 清单里
R_NO_URL = "no-url-for-format"        # 声明了格式, 却没给地址
R_BAD_URL = "bad-native-url"          # 给了地址, 但不是可用的 http(s) URL
R_NATIVE = "native-listed"            # 走原生
CHOICE_NATIVE = "native"
CHOICE_URI = "uri"


# ================================================================ 声明
def normalize_label(v) -> str:
    """发行版/内核标签归一: 去空白 + 小写。

    `mihomo -v` 打的是 `Mihomo Meta v1.19.32 …`(首词带大写), 而声明里统一
    小写; 两边各自 lower() 一次就够了, 不做更花的别名表 —— 别名表本身就是漂移源。
    """
    return str(v or "").strip().lower()


def build_declaration(kernel, distribution, version="", formats=(FORMAT_URI,),
                      urls=None) -> dict:
    """组装一份声明(有序 dict, 便于生成稳定可读的查询串)。

    urls: {格式名: 取件地址}。`uri` 的地址是主 URL 本身, 不重复写。
    返回的 dict 里 `formats` 一定是 list, `urls` 一定是 dict。
    """
    fmts = []
    for f in formats or ():
        f = normalize_label(f)
        if f and f not in fmts:
            fmts.append(f)
    if FORMAT_URI not in fmts:
        fmts.insert(0, FORMAT_URI)          # 普通话是保底项, 必须恒在
    clean_urls = {}
    for k, v in (urls or {}).items():
        k = normalize_label(k)
        if k and k != FORMAT_URI and str(v or "").strip():
            clean_urls[k] = str(v).strip()
    # 「给了取件地址」本身就是「提供这个格式」的声明 —— 只写 url-<fmt> 而不写
    # formats=<fmt> 的话, 客户端会判"清单里没有我的发行版"而永远走普通话,
    # 而地址上明明挂着原生产物(声明自相矛盾, 且不报错)。
    for k in clean_urls:
        if k not in fmts:
            fmts.append(k)
    if not all(f in clean_urls or f == FORMAT_URI for f in fmts):
        # 声明的清单里有格式却没地址 → 直接把它从清单里去掉(宁可不声明,
        # 不要声明一个客户端取不到的格式: 那会让客户端先试原生再回退,
        # 白跑一次且日志里多一条假的失败)。
        fmts = [f for f in fmts if f == FORMAT_URI or f in clean_urls]
    return {
        MARKER: INTEROP_SCHEMA,
        PARAM_KERNEL: normalize_label(kernel),
        PARAM_DIST: normalize_label(distribution),
        PARAM_VERSION: str(version or "").strip(),
        PARAM_FORMATS: fmts,
        "urls": clean_urls,
    }


# 取件地址里的这些字符**保持原样**: `:` `/` `@` `[` `]`。
#
# 不是为了好看, 是可验证的: M 的"切换地址族"会把 out/share_tag-*.txt 里的
# `//<旧host>[:/]` 全量替换成新 host (src/lib/env.sh:m_share_links_switch_family)。
# 地址若把 `://` 编码成 %3A%2F%2F, 那条替换**匹配不到**声明里的原生地址 ——
# 订阅地址切到新族、原生地址还停在旧族, 客户端走原生就拉不动(会回退并打印
# 原因, 但这是一次白跑 + 一条假失败)。保持原样则两侧一起被改写。
# 对端解析不受影响: X 的客户端与 M 的客户端都用 parse_qsl 解码, 原始字符
# 本来就等价于解码后的结果(两个方向都已真机验证)。
URL_SAFE = "/:@[]"


def _encode_query(pairs) -> str:
    """查询串编码: url-* 的值用 URL_SAFE, 其余字段全编码。"""
    out = []
    for k, v in pairs:
        k = str(k)
        safe = URL_SAFE if normalize_label(k).startswith(URL_PREFIX) else ""
        out.append(urllib.parse.quote(k, safe="") + "="
                   + urllib.parse.quote(str(v), safe=safe))
    return "&".join(out)


def declaration_query(decl) -> str:
    """声明 → 查询串(不含 `?`)。字段顺序固定: 先固定名, 再逐格式的地址。"""
    d = decl or {}
    parts = [
        (MARKER, str(d.get(MARKER, INTEROP_SCHEMA))),
        (PARAM_KERNEL, d.get(PARAM_KERNEL, "")),
        (PARAM_DIST, d.get(PARAM_DIST, "")),
        (PARAM_VERSION, d.get(PARAM_VERSION, "")),
        (PARAM_FORMATS, ",".join(d.get(PARAM_FORMATS, []) or [])),
    ]
    out = [(k, v) for k, v in parts if str(v or "") != ""]
    for fmt, url in (d.get("urls") or {}).items():
        out.append((URL_PREFIX + fmt, url))
    return _encode_query(out)


def declare_url(url, decl) -> str:
    """把声明并进一个订阅地址(保留地址原有的其它查询参数)。

    原有参数**保留**: 有些面板会在订阅地址上带自己的参数(`?token=` 之类),
    我们只**追加**声明, 不重写别人的地址。
    """
    u = urllib.parse.urlsplit(str(url or "").strip())
    q = urllib.parse.parse_qsl(u.query, keep_blank_values=True)
    q = [(k, v) for k, v in q if normalize_label(k) not in
         (MARKER, PARAM_KERNEL, PARAM_DIST, PARAM_VERSION, PARAM_FORMATS)
         and not normalize_label(k).startswith(URL_PREFIX)]
    extra = urllib.parse.parse_qsl(declaration_query(decl), keep_blank_values=True)
    frag = u.fragment
    return urllib.parse.urlunsplit(
        (u.scheme, u.netloc, u.path, _encode_query(q + extra), frag))


def _resolve_native_ref(ref, base):
    """把**同源相对引用**(`/share/<token>`)按主地址的源拼成绝对地址。

    为什么只做这一种形式 (契约 §3): 不引入完整 `urljoin` 语义 —— 那会把
    `//other.host/x`(协议相对引用, 属于**别的源**)和 `../x` 这类东西一起猜进来。
    只处理"以**单个** `/` 开头、且末段非空"的路径引用; 其余**原样保留**, 交给
    `decide()` 照旧判 `bad-native-url`(**不猜**)。没有 base(裸查询串形态)时也不猜。
    """
    s = str(ref or "").strip()
    if not s.startswith("/") or s.startswith("//") or not base:
        return s
    if s.endswith("/") or "/" not in s[1:]:
        return s        # `/share/` 是目录、`/x` 是单段路径 —— 都不是取件地址, 不猜
    return base + s


def parse_declaration(text):
    """从订阅地址(或裸查询串)里读声明。读不到返回 None。

    只读**查询串**: 片段里的同名字段一律不认(那是别的客户端的显示名载体,
    同一份语义有两套载体必然漂移)。任何异常都返回 None("没有声明"),
    **绝不抛** —— 一个畸形地址不该让客户端连普通话都拉不了。
    """
    try:
        s = str(text or "").strip()
        if not s:
            return None
        # ★ 判据必须是"**有没有 scheme**", 不能是"串里有没有 `://`"。
        #   我们的 url-* 值**保留 `://` 原样** (URL_SAFE, "切换地址族"靠它),
        #   于是**裸查询串里也会出现 `://`**。拿 `"://" not in s` 当"这是裸
        #   查询串"的判据, 会把**我们自己产出的声明**判成"没有查询串":
        #   parse 返回 None → decide 落到 no-declaration → **静默走普通话**,
        #   不报错。真实故障: `interop.py declare` 的输出喂回 `interop.py
        #   decide` 永远拿不到原生(跨实现一致性台抓到的唯一"只有 M 不通过")。
        #
        #   注意: 这里用 urlsplit 的 scheme **真探测**, 不是再换一个子串判据
        #   (`"://" in s` 同样会把上面那种裸查询串误判成完整地址 → query 解析
        #   成空串 → 依然静默)。见 tools/check_interop.sh ③ 的往返断言。
        if s.startswith("?"):
            q = s.lstrip("?")                       # 裸查询串(带 ? 前缀)
            base = ""
        else:
            _p = urllib.parse.urlsplit(s)
            if _p.scheme and _p.netloc:
                q = _p.query                        # 完整订阅地址
                # 相对引用要按**主地址的源**拼回绝对地址 (见 _resolve_native_ref)。
                base = "%s://%s" % (_p.scheme, _p.netloc)
            elif "=" in s:
                q = s                               # 裸查询串(无 ? 前缀)
                base = ""                           # 没有源 → 相对引用不猜
            else:
                q = ""                              # 没有查询串 → 没有声明
                base = ""
        raw = {}
        for k, v in urllib.parse.parse_qsl(q, keep_blank_values=True):
            raw.setdefault(k, v)       # 同名参数取第一个(声明是我们自己写的)
        low = {normalize_label(k): v for k, v in raw.items()}
        if MARKER not in low:
            return None
        try:
            schema = int(str(low.get(MARKER, "")).strip())
        except ValueError:
            schema = -1
        urls = {}
        for k, v in low.items():
            if k.startswith(URL_PREFIX) and len(k) > len(URL_PREFIX):
                # 同源相对引用按主地址拼回绝对地址; 拼不出就原样保留(不猜)。
                urls[k[len(URL_PREFIX):]] = _resolve_native_ref(v, base)
        fmts = [normalize_label(x) for x in
                str(low.get(PARAM_FORMATS, "")).split(",") if x.strip()]
        return {
            MARKER: schema,
            PARAM_KERNEL: normalize_label(low.get(PARAM_KERNEL, "")),
            PARAM_DIST: normalize_label(low.get(PARAM_DIST, "")),
            PARAM_VERSION: str(low.get(PARAM_VERSION, "")).strip(),
            PARAM_FORMATS: fmts,
            "urls": urls,
            # 声明是"认识的"才允许用它做决策。规范版本 / 内核名不在词表里
            # 都算不认识 —— 不认识的声明与没有声明同等对待(走普通话)。
            "recognized": schema == INTEROP_SCHEMA
            and normalize_label(low.get(PARAM_KERNEL, "")) in KERNELS,
            "raw": raw,
        }
    except Exception:                                            # noqa: BLE001
        return None


def _usable_url(u) -> bool:
    try:
        p = urllib.parse.urlsplit(str(u or "").strip())
        return p.scheme in ("http", "https") and bool(p.netloc)
    except Exception:                                            # noqa: BLE001
        return False


def decide(decl, my_kernel, my_distribution):
    """决策: 返回 (choice, reason, url, detail)。

    choice ∈ {"native", "uri"}; url 是**该去取**的地址(uri 时为空串,
    调用方用自己手里那个主地址)。detail 是给人看的一句话(进日志 / 验收报告)。

    规则(与设计文档 §3 逐条对应):
      声明缺失 / 版本不认识 / 内核缺失或不认识 → uri
      跨内核                                    → uri
      本机发行版探测不出来                       → uri   (不猜)
      本机发行版不在 formats 清单里               → uri
      清单里有本机发行版但没给地址 / 地址不是 http(s) → uri
      否则                                      → native(地址)
    """
    if not decl:
        return CHOICE_URI, R_NO_DECL, "", "地址上没有内核声明"
    if not decl.get("recognized"):
        return CHOICE_URI, R_BAD_SCHEMA if decl.get(MARKER) != INTEROP_SCHEMA \
            else R_UNKNOWN_KERNEL, "", (
                "声明规范版本 %s 不认识" % decl.get(MARKER)
                if decl.get(MARKER) != INTEROP_SCHEMA
                else "声明的内核 %r 不在内核词表里" % decl.get(PARAM_KERNEL, ""))
    mine = normalize_label(my_kernel)
    dist = normalize_label(my_distribution)
    if not mine or not dist:
        return CHOICE_URI, R_SELF_UNKNOWN, "", "本机内核/发行版探测不出来(不猜)"
    if decl.get(PARAM_KERNEL) != mine:
        return CHOICE_URI, R_CROSS_KERNEL, "", (
            "服务端内核 %s ≠ 本机 %s" % (decl.get(PARAM_KERNEL), mine))
    if dist not in (decl.get(PARAM_FORMATS) or []):
        return CHOICE_URI, R_DIST_NOT_LISTED, "", (
            "服务端提供的格式 %s 里没有本机发行版 %s"
            % (",".join(decl.get(PARAM_FORMATS) or []) or "(空)", dist))
    native = (decl.get("urls") or {}).get(dist, "")
    if not native:
        return CHOICE_URI, R_NO_URL, "", "声明里有 %s 格式, 却没给取件地址" % dist
    if not _usable_url(native):
        return CHOICE_URI, R_BAD_URL, "", "原生取件地址不是可用的 http(s) 地址: %s" % native
    return CHOICE_NATIVE, R_NATIVE, native, (
        "同内核同发行版 (%s/%s) → 取原生" % (mine, dist))


# ================================================================ 本机事实
def binary_candidates():
    """本机 mihomo 二进制的查找顺序。

    服务端与客户端**装在不同目录**(/root/catmi/mihomo/mihomo 与
    /root/catmi/mihomo-client/mihomo), 而两边都要报同一个发行版标签 ——
    所以这里按"环境变量 → 服务端 → 客户端 → PATH"找一遍, 不写死一个路径。
    """
    cands = []
    for var in ("MIHOMO_BIN", "CLI_BIN"):
        v = os.environ.get(var, "").strip()
        if v:
            cands.append(v)
    for root in (os.environ.get("SRV_ROOT"), os.environ.get("CLI_ROOT"),
                 "/root/catmi/mihomo", "/root/catmi/mihomo-client"):
        if root:
            cands.append(os.path.join(root, "mihomo"))
    cands.append("mihomo")
    out = []
    for c in cands:
        if os.path.sep in c and not os.path.exists(c):
            continue
        if c not in out:
            out.append(c)
    return out


def mihomo_version_text(bins=None):
    """跑 `mihomo -v` → (版本号, 发行版标签)。探测不到返回 ("", "")。

    ★ **真探测, 不写死**; 规则与 src/lib/nodecompat.py:probe_kernel() **逐条
      一致**(官方二进制自称 Mihomo → `upstream`, 其它取版本行首词):
      声明里的标签必须和 compat 判能力用的标签是同一个字符串, 否则会出现
      "声明匹配上了、能力判定却按另一个名字走"。门禁用真二进制比对两者输出。
    ★ interop.py **不 import nodecompat**: 客户端安装里不一定有它(判能力层
      可以缺席), 而"我是谁"这条事实缺席会让客户端**永远走普通话**(静默),
      所以这里自带同规则实现, 用门禁钉住一致性。
    """
    forced = os.environ.get("MH_INTEROP_VERSION", "").strip()
    if forced:
        return forced, os.environ.get("MH_INTEROP_DIST", "upstream").strip() or "upstream"
    for b in (bins if bins is not None else binary_candidates()):
        try:
            p = subprocess.run([b, "-v"], capture_output=True, text=True, timeout=10)
            text = ((p.stdout or "") + (p.stderr or "")).strip()
        except Exception:                                        # noqa: BLE001
            continue
        if not text:
            continue
        first = text.splitlines()[0].strip()
        version = ""
        for tok in first.replace(",", " ").split():
            t = tok.strip().lstrip("vV")
            if t and t[0].isdigit() and t.count(".") >= 1:
                version = t
                break
        low = first.lower()
        dist = "upstream" if MY_KERNEL in low else (
            normalize_label(first.split(" ", 1)[0]) if first.split(" ", 1) else "")
        return version, dist
    return "", ""


def self_facts(prefix=None) -> dict:
    """本机内核事实: {kernel, distribution, version, ok, note}。

    `ok=False` 表示探测不出来 —— 调用方**必须**把它当"不知道"(服务端不产出
    原生声明、客户端走普通话), 不许退回一个写死的默认发行版。
    """
    ver, name = mihomo_version_text()
    if not name:
        return {"kernel": MY_KERNEL, "distribution": "", "version": "",
                "ok": False,
                "note": "mihomo 二进制探测不到(没有 -v 输出; 试过 %s)"
                        % ", ".join(binary_candidates())}
    return {"kernel": MY_KERNEL, "distribution": name, "version": ver,
            "ok": True, "note": ""}


# ================================================================ CLI
def _usage():
    return ("用法:\n"
            "  interop.py declare --kernel K --distribution D [--version V]\n"
            "                     [--url-<fmt> URL ...] --url <订阅地址>\n"
            "  interop.py parse <订阅地址>\n"
            "  interop.py decide <订阅地址> [--kernel K] [--distribution D]\n"
            "  interop.py self\n")


def main(argv):
    import json
    if len(argv) < 2:
        print(_usage(), file=sys.stderr)
        return 2
    cmd = argv[1]

    def opt(name, default=""):
        return argv[argv.index(name) + 1] if name in argv and \
            argv.index(name) + 1 < len(argv) else default

    if cmd == "self":
        print(json.dumps(self_facts(), ensure_ascii=False))
        return 0
    if cmd == "parse":
        if len(argv) < 3:
            print(_usage(), file=sys.stderr)
            return 2
        d = parse_declaration(argv[2])
        print(json.dumps(d, ensure_ascii=False))
        return 0
    if cmd == "decide":
        if len(argv) < 3:
            print(_usage(), file=sys.stderr)
            return 2
        facts = self_facts()
        k = opt("--kernel", facts["kernel"])
        dist = opt("--distribution", facts["distribution"])
        d = parse_declaration(argv[2])
        choice, reason, url, detail = decide(d, k, dist)
        print(json.dumps({"choice": choice, "reason": reason, "url": url,
                          "detail": detail, "mine": {"kernel": k,
                                                     "distribution": dist},
                          "declaration": d}, ensure_ascii=False))
        return 0
    if cmd == "declare":
        urls = {}
        for i, a in enumerate(argv):
            if a.startswith("--url-"):
                urls[a[len("--url-"):]] = opt(a)
        decl = build_declaration(opt("--kernel"), opt("--distribution"),
                                 opt("--version"),
                                 formats=opt("--formats", FORMAT_URI).split(","),
                                 urls=urls)
        print(declare_url(opt("--url"), decl))
        return 0
    print(_usage(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
