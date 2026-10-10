#!/usr/bin/env python3
"""节点名的旗帜 —— "这台服务器在哪个地区"必须一眼看得出来。

**旗帜是服务器的属性, 不是名字的一部分** —— 这一点决定了它必须由
服务端按自己的 IP 归属地写上, 而不是让每个客户端各自猜。

    🇺🇸 mAnyTLS01-TLS          （默认: 旗帜 + 原来的 tag）
    🇭🇰 ds-mVLESS01-REALITY    （客户端按订阅名加前缀时, 前缀落在旗帜之后）

为什么必须是"属性"而不是名字的一部分：

  · 名字要进配置文件、分享链接的 # 片段、客户端列表, 还要被客户端按
    "订阅名前缀"改写 —— 每次改写都会经过它, 一不小心就把旗帜抹掉。
    踩过的坑: 用户把名字改短之后, 旗帜跟着没了 —— 因为改写逻辑只当成
    一段普通字符串处理。
  · 多台服务器各跑一份全协议时, tag 完全一样（都是 mAnyTLS01-TLS）,
    客户端按名字存节点, 后导入的会把先导入的**覆盖**掉 —— 静默少节点。
    旗帜 + 前缀就是为这件事存在的。

旗帜只加一次, 加在**最前面**；名字里已经有旗帜（用户自己写的那种）就原样
尊重, 不再叠一层。

用法（CLI, 给 bash 调）：

    naming.py flag                 # 当前旗帜（可能为空串）
    naming.py ensure <名字>        # 没有旗帜就补一个, 有就原样返回
    naming.py --selftest           # 自检（不联网）

环境变量：
    M_ROOT        安装根（默认 /root/catmi/mihomo），缓存在 <M_ROOT>/share-state/
    M_SKIP_FLAG   非空 = 不要旗帜（离线/隐私场景）
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.request

ROOT = os.environ.get("M_ROOT", "/root/catmi/mihomo")
STATE_DIR = os.environ.get("M_STATE_DIR", os.path.join(ROOT, "share-state"))
FLAG_CACHE = os.path.join(STATE_DIR, "flag")

# 旗帜 = 两个连着的区域指示符号（U+1F1E6..U+1F1FF）。
# 用正则判"有没有旗帜", 而不是比字符串前缀 —— 用户完全可能自带别的国家的旗帜。
FLAG_RE = re.compile("[\U0001F1E6-\U0001F1FF]{2}")

# 归属地查询源。多源回退: 单个接口时好时坏, 现查失败就没旗帜了。
GEO_SOURCES = (
    "http://ip-api.com/json/?fields=countryCode",
    "https://ifconfig.co/json",
    "http://ip-api.com/json/",
)


def iso_to_flag(iso: str) -> str:
    """ISO 3166-1 alpha-2 → 国旗 emoji。不合法就返回空串。"""
    c = (iso or "").strip().upper()
    if len(c) != 2 or not c.isalpha():
        return ""
    return "".join(chr(0x1F1E6 + ord(x) - 65) for x in c)


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _write(path: str, text: str) -> None:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except OSError:
        pass


def detect_iso(timeout: float = 4.0) -> str:
    for url in GEO_SOURCES:
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                data = json.loads(resp.read(4096).decode("utf-8", "replace"))
        except Exception:                                        # noqa: BLE001
            continue
        code = (data.get("countryCode") or data.get("country_iso")
                or data.get("country_code") or "")
        code = re.sub(r"[^A-Za-z]", "", str(code)).upper()
        if len(code) == 2:
            return code
    return ""


def flag_emoji(refresh: bool = False) -> str:
    """当前旗帜。查不到返回空串, 但**不缓存空结果** ——
    接口临时不通时缓存了空, 之后永远没有旗帜, 而用户只会觉得"前缀丢了"。"""
    if os.environ.get("M_SKIP_FLAG"):
        return ""
    if not refresh:
        cached = _read(FLAG_CACHE)
        if cached:
            return cached
    flag = iso_to_flag(detect_iso())
    if flag:
        _write(FLAG_CACHE, flag)
    return flag


def ensure_flag(name: str) -> str:
    """名字里没有旗帜就补一个；有就原样保留（用户自己的旗帜优先）。"""
    name = (name or "").strip()
    if not name:
        return name
    if FLAG_RE.search(name):
        return name
    flag = flag_emoji()
    return (flag + " " + name).strip() if flag else name


def selftest() -> int:
    """不联网的部分全部验一遍（联网的只在缓存存在时验）。"""
    bad = 0
    tmp = "/tmp/mihomo-naming-check"

    def ck(cond, what):
        nonlocal bad
        print(("  [PASS] " if cond else "  [FAIL] ") + what)
        if not cond:
            bad += 1

    ck(iso_to_flag("US") == "\U0001F1FA\U0001F1F8", "ISO US → 🇺🇸")
    ck(iso_to_flag("hk") == "\U0001F1ED\U0001F1F0", "ISO hk（小写）→ 🇭🇰")
    ck(iso_to_flag("U") == "" and iso_to_flag("USA") == "" and iso_to_flag("") == "",
       "非法 ISO 一律空串（不瞎猜）")

    global FLAG_CACHE
    saved = FLAG_CACHE
    old_skip = os.environ.pop("M_SKIP_FLAG", None)
    try:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp, exist_ok=True)
        FLAG_CACHE = os.path.join(tmp, "flag")
        _write(FLAG_CACHE, "\U0001F1FA\U0001F1F8")          # 🇺🇸
        ck(flag_emoji() == "\U0001F1FA\U0001F1F8", "旗帜读缓存（不联网）")
        ck(ensure_flag("mAnyTLS01-TLS") == "\U0001F1FA\U0001F1F8 mAnyTLS01-TLS",
           "裸名字 → 旗帜 + 名字")
        ck(ensure_flag("\U0001F1ED\U0001F1F0 我自己起的")
           == "\U0001F1ED\U0001F1F0 我自己起的", "自带旗帜的名字原样保留")
        ck(ensure_flag("\U0001F1FA\U0001F1F8 mAnyTLS01-TLS")
           == "\U0001F1FA\U0001F1F8 mAnyTLS01-TLS", "幂等: 重复调用不会叠两层")
        ck(ensure_flag("") == "", "空名字返回空（不造出一个只有旗帜的名字）")
        os.environ["M_SKIP_FLAG"] = "1"
        ck(flag_emoji() == "", "M_SKIP_FLAG=1 → 不要旗帜")
        ck(ensure_flag("mTrojan01-REALITY") == "mTrojan01-REALITY",
           "关掉旗帜时名字原样（不是空的）")
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
        FLAG_CACHE = saved
        if old_skip is not None:
            os.environ["M_SKIP_FLAG"] = old_skip
        else:
            os.environ.pop("M_SKIP_FLAG", None)

    print(f"\n命名自检: {'PASS' if bad == 0 else str(bad) + ' 项失败'}")
    return 1 if bad else 0


def main(argv) -> int:
    cmd = argv[1] if len(argv) > 1 else "flag"
    if cmd == "--selftest":
        return selftest()
    if cmd == "flag":
        print(flag_emoji())
    elif cmd == "ensure":
        print(ensure_flag(argv[2] if len(argv) > 2 else ""))
    elif cmd == "refresh":
        print(flag_emoji(refresh=True))
    else:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
