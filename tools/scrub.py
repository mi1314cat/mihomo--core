#!/usr/bin/env python3
"""
scrub.py — 发布前脱敏

把审计报告里的部署隐私替换成占位符, 使其可以安全地公开到 GitHub。

替换项 (按顺序, 先长后短):
  * 服务器公网 IP                   → <SERVER_IP>
  * 动态域名 (DDNS 服务商后缀)        → <SERVER_DOMAIN>
  * UUID / 分享 token                → <UUID> / <HEX32>
  * GitHub 凭据                      → <GITHUB_TOKEN>

**刻意不替换**的 (属于技术内容, 脱敏会破坏可读性/可复现性):
  * 内核源码路径与行号 (/tmp/mihomo-1.19.32/...:123)
  * 公共探测服务域名 (api.ipify.org 等)
  * 公共 DNS / 保留段 / RFC 示例地址 (见下 SAFE4)
  * 示例用的占位 UUID (00000000-...-000000000000 / 1111...-5555...)
  * 端口号作为"典型值"的讨论 (如 1-1023 特权段)

注意: 本工具最初是给**审计报告**用的, 规则偏宽。当成 CI 门跑时, 必须先
把公共常量排除干净 —— 否则 `--check` 永远有残留, 门永远是红的, 等于没有门。
下面的 SAFE4 就是这份例外表。

⚠ 本文件是**公开**的, 因此只放**通用**规则。
   与具体部署绑定的字面值 (确切的出口 IPv6 段 / 主机名 / 自有域名 / SSH 端口 /
   内部别名) 一律**不能写在这里** —— 那等于把要脱敏的值本身公开出去, 让这份
   工具变成一份"泄露索引"。它们放在 `tools/scrub-private.py` (gitignored),
   本脚本检测到就加载。全新克隆上没有这个文件, 也就没有任何需要保护的私有值。

用法:
    python3 scrub.py <文件...>            # 就地改写
    python3 scrub.py --check <文件...>    # 只检查不修改, 有残留则退出码 1
"""
from __future__ import annotations

import os
import re
import sys

# 明确安全的 IPv4 —— 公开常量、保留段、RFC 示例。不含任何部署信息。
# 少一个都会让 --check 误报, 所以宁可写全。
SAFE4 = (
    r"10\.|127\.|0\.|169\.254\.|192\.168\."              # 私网 / 环回 / 链路本地
    r"|172\.(?:1[6-9]|2\d|3[01])\."                       # 172.16-31 私网
    r"|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\."         # 100.64-127 CGNAT
    r"|198\.1[89]\."                                      # fake-ip (RFC 2544)
    r"|192\.0\.2\.|198\.51\.100\.|203\.0\.113\."          # TEST-NET 1/2/3
    r"|22[4-9]\.|23\d\.|24\d\.|25[0-5]\."                 # 组播 / 保留
    r"|1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9|149\.112\.112\."   # 公共 DNS
    r"|223\.5\.5\.5|119\.29\.29\.29|114\.114\.114\.114"
    r"|208\.67\.222\.222|208\.67\.220\.220"
    r"|1\.2\.3\.4"                                        # 经典示例
)

# 明确安全的 UUID —— 全 0 与递增占位符, 是文档里的示例而非真实凭据。
SAFE_UUID = r"00000000-0000-4000-8000-000000000000|11111111-2222-3333-4444-555555555555"

# 常见动态域名 (DDNS) 服务商后缀 —— 公开知识, 不含任何用户信息。
# 用后缀匹配而不是写死某个具体域名: 既能抓住"某个 DDNS 域名", 又不泄露
# 用户到底用的是哪一个、叫什么名字。
DDNS_SUFFIX = (
    r"dpdns\.org|duckdns\.org|no-ip\.(?:org|com)|dynv6\.net|ddns\.net"
    r"|my\.to|hopto\.org|zapto\.org|serveftp\.com|3utilities\.com"
)

# (正则, 替换, 说明) —— 顺序敏感
RULES: list[tuple[re.Pattern[str], str, str]] = [
    # --- IPv4 公网地址: 排除私网/保留/公共常量 ---
    (re.compile(r"(?<![\d.])(?!(?:" + SAFE4 + r"))"
                r"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"),
     "<SERVER_IP>", "公网 IPv4"),

    # --- 动态域名 ---
    (re.compile(r"\b[a-z0-9][-a-z0-9]*(?:\.[a-z0-9][-a-z0-9]*)*\.(?:" + DDNS_SUFFIX + r")\b", re.I),
     "<SERVER_DOMAIN>", "动态域名"),

    # --- 凭据 ---
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]+"), "<GITHUB_TOKEN>", "GitHub PAT"),
    (re.compile(r"\bghp_[A-Za-z0-9]{20,}"), "<GITHUB_TOKEN>", "GitHub token"),
    (re.compile(r"(?<![0-9a-fA-F-])(?!" + SAFE_UUID + r")"
                r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
                r"[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-fA-F-])"),
     "<UUID>", "UUID"),
    (re.compile(r"(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])"), "<HEX32>", "分享 token"),
]

# 交流痕迹 —— 不是"值", 而是不该出现在公开仓库里的表述。
# 这类残留不泄露凭据, 但会把内部讨论过程带进代码注释。
# 与 RULES 分开: RULES 是"替换成占位符", 这里是"本就不该写进来"。
CONVERSATION: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"学\s*SB|SB\s*原话|SB\s*的对应屏|借鉴\s*SB|SB\s*那边"), "借鉴表述"),
    (re.compile(r"用户(?:反馈|的原话|原话|说|要求|让我|希望|提到|问)"), "用户引语"),
    (re.compile(r"实机走查|走查"), "走查笔记"),
    (re.compile(r"LEARN-FROM-SB"), "内部笔记名"),
    (re.compile(r"对标项目|sing-box-core"), "对标引用"),
    (re.compile(r"(?:实测|踩过|问题)\s*\(\s*\)"), "空括号残留"),
]


def _load_private() -> list[tuple[re.Pattern[str], str, str]]:
    """加载与具体部署绑定的规则 (gitignored)。

    全新克隆上不存在这个文件, 返回空列表 —— 此时通用规则已经够用,
    因为一个干净的仓库里本来就不该有私有值。
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scrub-private.py")
    if not os.path.isfile(path):
        return []
    ns: dict[str, object] = {"__file__": path}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            exec(compile(fh.read(), path, "exec"), ns)  # noqa: S102
    except Exception as e:  # noqa: BLE001
        print(f"⚠ 加载 {path} 失败: {e}", file=sys.stderr)
        return []
    rules = ns.get("PRIVATE_RULES") or []
    return list(rules)  # type: ignore[arg-type]


def all_rules() -> list[tuple[re.Pattern[str], str, str]]:
    return RULES + _load_private()


def conversation_hits(text: str) -> dict[str, int]:
    """交流痕迹计数 —— 单独成函数, 便于 --check 与替换两条路径共用。"""
    hits: dict[str, int] = {}
    for pat, note in CONVERSATION:
        n = len(pat.findall(text))
        if n:
            hits[f"交流痕迹: {note}"] = n
    return hits


def scrub(text: str) -> tuple[str, dict[str, int]]:
    hits: dict[str, int] = {}
    for pat, repl, note in all_rules():
        text, n = pat.subn(repl, text)
        if n:
            hits[f"{note} ({repl})"] = hits.get(f"{note} ({repl})", 0) + n
    return text, hits


def main(argv: list[str]) -> int:
    check = "--check" in argv
    files = [a for a in argv[1:] if not a.startswith("--")]
    if not files:
        print(__doc__)
        return 2

    # 本文件**要**过值规则检查 (RULES 已全是通用模式, 自己扫自己不会误报 ——
    # 这正是以前那条"排除 scrub.py"的错误被修掉的地方)。
    # 但 CONVERSATION 检查要跳过自己: 那些模式的字面量就定义在本文件里,
    # 扫自己必然自命中, 而这不是残留, 是定义。
    me = os.path.abspath(__file__)

    dirty = 0
    for path in files:
        with open(path, "r", encoding="utf-8") as fh:
            original = fh.read()
        cleaned, hits = scrub(original)
        if os.path.abspath(path) != me:
            hits.update(conversation_hits(original))
        if not hits:
            continue
        dirty += 1
        detail = ", ".join(f"{k}×{v}" for k, v in sorted(hits.items()))
        if check:
            print(f"[残留] {path}: {detail}")
        else:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(cleaned)
            print(f"[已脱敏] {path}: {detail}")

    if check and dirty == 0:
        print("✅ 全部干净")
    return 1 if (check and dirty) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
