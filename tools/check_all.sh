#!/usr/bin/env bash
# =============================================================
# check_all.sh — 一次跑完所有机械校验
# =============================================================
#
# 为什么要有这个:
#
# 本项目的**主导 bug 类型**是「两处必须一致, 但没有任何机制保证」。已经
# 出现过 10+ 次, 每一次都是同一副面孔: 面板能启动、界面正常、设置能保存,
# 但某个地方悄悄不生效。
#
# 单点修复是不够的 —— 修完这次, 下次改动还会漂。所以每修一处, 就配一个
# 机械校验, 全部挂到这里。改完代码跑一遍, 比人眼可靠。
#
# 用法: bash tools/check_all.sh
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; RESET=$'\e[0m'

total=0; failed=0
declare -a FAILED_NAMES=()

run_gate() {
    local name="$1"; shift
    total=$((total + 1))
    printf "  ${CYAN}▸${RESET} %-26s " "$name"
    local out rc
    out=$("$@" 2>&1); rc=$?
    if (( rc == 0 )); then
        printf "${GREEN}✅${RESET}\n"
    else
        printf "${RED}❌${RESET}\n"
        failed=$((failed + 1))
        FAILED_NAMES+=("$name")
        printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '❌|⚠|不|错|缺|漂移|断线' | awk 'NR<=8' | sed 's/^/      /'
    fi
}

printf "\n${CYAN}═══ 全部机械校验 ═══${RESET}\n\n"

printf "${CYAN}── 一致性闸门 ──${RESET}\n"
run_gate "清单漂移"     bash tools/check_manifest.sh
run_gate "常量漂移"     bash tools/check_mirrors.sh
run_gate "接线完整"     bash tools/check_wiring.sh
run_gate "菜单编号"     bash tools/check_menu_ids.sh
run_gate "yaml 取值守卫" bash tools/check_yaml_guard.sh
# 调用方 vs 生产者: flag 必须存在, 且不许按"给人看的表格"的字段数/分隔符解析。
# 这一类 bug 全部是**静默失败** (列表变空 → 循环不跑 → 检查器打印"没问题"),
# 已经踩过三次 (share 的 NF==2、cdn 的 -F'|'、以及被 2>/dev/null 吞掉的 flag 错)。
run_gate "接口一致"     bash tools/check_interfaces.sh
# `set -euo pipefail` + 命令替换里的 `| head` = 随机猝死（上游吃 SIGPIPE 141）。
# X 内核客户端实测 12 次死 4 次, 用户只看到版本号闪一下就回命令行。
run_gate "管道早退"     bash tools/check_pipe_early.sh

# pre-push 钩子是否已安装。
#
# 钩子本体在 tools/git-hooks/pre-push (版本控制的一部分), 但 git 只认
# .git/hooks/ 下的副本 —— 换台机器 clone 出来是没有的, 于是「推 main 把
# 远端推回退」那个坑会重新出现。所以这里查一次。
#
# 这个坑实际踩了三次, 每次都报 forced update 且**退出码 0**, 看起来像成功。
git_hook() {
    local src=tools/git-hooks/pre-push dst=.git/hooks/pre-push
    [[ -f "$src" ]] || { printf "❌ 钩子源文件缺失: %s\n" "$src"; return 1; }
    if [[ ! -x "$dst" ]]; then
        printf "❌ pre-push 钩子未安装 (或不可执行): %s\n" "$dst"
        printf "   安装: cp %s %s && chmod 755 %s\n" "$src" "$dst" "$dst"
        return 1
    fi
    # 内容必须一致 —— 只存在但内容过期同样没意义
    if ! cmp -s "$src" "$dst"; then
        printf "❌ pre-push 钩子内容过期: %s\n" "$dst"
        printf "   更新: cp %s %s\n" "$src" "$dst"
        return 1
    fi
    return 0
}
run_gate "pre-push 钩子" git_hook

printf "\n${CYAN}── 语法 ──${RESET}\n"
syntax_shell() {
    local bad=0 f
    for f in src/*.sh src/lib/*.sh src/conf/*.sh src/share/*.sh tools/*.sh install.sh; do
        [[ -f "$f" ]] || continue
        bash -n "$f" 2>/dev/null || { printf "❌ %s\n" "$f"; bad=1; }
    done
    return $bad
}
syntax_py() {
    local bad=0 f
    for f in src/lib/*.py src/conf/*.py tools/*.py src/share/*.py; do
        [[ -f "$f" ]] || continue
        python3 -m py_compile "$f" 2>/dev/null || { printf "❌ %s\n" "$f"; bad=1; }
    done
    find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
    return $bad
}
run_gate "shell 语法"   syntax_shell
run_gate "python 语法"  syntax_py

printf "\n${CYAN}── 发布脱敏 ──${RESET}\n"
scrub_scan() {
    # GitHub 只给我们自己用, 是功能性的 —— 不能把部署信息带上去。
    #
    # 为什么必须做成门: 这个坑**重犯过**。历史上手动跑过一次脱敏, 之后又改
    # 了代码, 新写的注释里把真实 IP / 隧道地址 / SSH 端口又带回来了。手工
    # 跑一次的检查不是检查。
    #
    # 只查 git 跟踪的文件 —— 未被跟踪的 docs/private/ 本来就不上传。
    #
    # ★ 这里**不再排除 tools/scrub.py**。以前排除它, 理由是"它的 RULES 里
    #   就是这些模式的正则文本, 查它必然自命中" —— 但这个理由本身是错的:
    #   正因为把**真实值**写进了公开的正则, 这份工具才变成了泄露索引
    #   (确切的出口 IPv6 段 / 主机名 / 自有域名 / SSH 端口 / 内部别名全在里面)。
    #   现在 scrub.py 只放通用规则, 具体值在 gitignored 的 scrub-private.py。
    #   于是校验器可以、也必须校验自己。
    local files
    # ★ 已跟踪 + **未跟踪但没被 gitignore** 的都要扫。
    #   原来只有 `git ls-files`, 于是**新建的文件在被 git add 之前完全不在
    #   扫描范围里** —— 而这正是密钥最容易溜进去的窗口: 报告/笔记里贴了一段
    #   token, 检查全绿, git add -a 一提交, 密钥就进了历史, 直到 push 被
    #   GitHub 的 secret scanning 拦下才发现。
    #   (实测就是这么翻车的: E2E 报告里原样带着 PAT。)
    files=$( { git ls-files; git ls-files --others --exclude-standard; } \
             | grep -v '^tools/scrub-private\.py$' | sort -u )
    [[ -n "$files" ]] || { printf "❌ 没拿到文件清单 (不在 git 仓库里?)\n"; return 1; }
    # shellcheck disable=SC2086
    python3 tools/scrub.py --check $files
}
run_gate "发布脱敏"     scrub_scan

printf "\n${CYAN}── 局域网分发脱敏 ──${RESET}\n"
# 分发给别的设备的配置里, 本机专属字段必须剥干净。
#
# 这一类是**安全属性**而不是格式偏好: 漏掉 `dns.listen` 的后果是接收设备在
# 它所有网卡上开一个 DNS 服务 (本机早就修掉的"开放解析器"问题), 或者因为
# 1053 被占而直接起不来。而剥除清单靠"人记得加" —— 所以每次跑都验一遍。
run_gate "LAN 分发脱敏" python3 src/share/lan_config.py --selftest
# 节点名的旗帜: 服务端 m_node_tag / 客户端加前缀 / 关旗帜回落 —— 三处都能
# 把它抹掉, 所以要验"真的接上了", 不只是验函数。
run_gate "节点命名旗帜" bash tools/check_naming.sh
# 分享产物: 生成是否成功 (带旗帜名 vs 裸名台账) / 链接端口与监听是否自洽 /
# 链接里有没有会让整条订阅归零的参数 (obfs=none)。这一批全是**静默失败**:
# 面板照常显示, 用户拿到空订阅或死链, 没有一处报错指向真正的原因。
run_gate "分享产物"     bash tools/check_share_products.sh
# ★ 对角线: **M 分享 → M 客户端** 这条链不许再断。
#   已经断过一次 (加旗帜命名 → 裸名台账与带旗帜产物名等值比较 → 交集 0/19 →
#   分享订阅生成 100% 失败, 用户拿不到任何节点)。这道理是本项目的"印证过的
#   功能"里最贵的一条: 自己分享给自己都认不出来, 用户没法自己发现。
#   闸门故意同时覆盖带旗帜名与裸名两种输入。真内核层用 MIHOMO_BIN 启用。
run_gate "对角线(分享→客户端)" bash tools/check_diagonal.sh

printf "\n${CYAN}── 幽灵函数 (定义了但没人调) ──${RESET}\n"
phantom_scan() {
    python3 - <<'PY'
import io, os, re, sys
files = [os.path.join(r, f) for r, _, fs in os.walk('src') for f in fs if f.endswith('.sh')]
files.append('install.sh')
defined = set()
def _strip_heredocs(text):
    """把 <<'TAG' ... TAG 的**内容**整段去掉。

    为什么必须去: 内嵌的 python 里 `_mlib = sys.argv[3]` 这种赋值长得和
    shell 的函数调用一模一样 (行首一个下划线开头的标识符), 会被幽灵函数扫描
    误判成"引用了一个不存在的函数"。而heredoc 内容根本不是 shell 代码 ——
    把它当 shell 去扫, 报出来的"幽灵函数"全是假的。
    实测踩过: 导入器里内嵌的 python 变量 _mlib / _mihomo_types 被报成幽灵函数。
    """
    out, lines, i = [], text.split('\n'), 0
    while i < len(lines):
        m = re.search(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?", lines[i])
        if m:
            tag = m.group(1)
            out.append(re.sub(r"<<-?\s*'?\"?[A-Za-z_][A-Za-z0-9_]*'?\"?", '', lines[i]))
            i += 1
            while i < len(lines) and not re.match(rf'^\s*{re.escape(tag)}\s*$', lines[i]):
                i += 1
            i += 1
            continue
        out.append(lines[i]); i += 1
    return '\n'.join(out)

for p in files:
    defined |= set(re.findall(r'^\s*([_a-zA-Z]\w*)\(\)\s*\{', _strip_heredocs(io.open(p, encoding='utf-8').read()), re.M))
miss = {}
for p in files:
    for i, l in enumerate(_strip_heredocs(io.open(p, encoding='utf-8').read()).split('\n'), 1):
        c = l.split('#')[0]
        c = re.sub(r'\$\{[^}]*\}', ' ', c)
        c = re.sub(r'\$\w+', ' ', c)
        for m in re.finditer(r'(?:^|[;|&(]\s*|\$\()\s*(_[a-z]\w*)\s', c):
            if m.group(1) not in defined:
                miss.setdefault(m.group(1), []).append(f'{os.path.basename(p)}:{i}')
miss = {k: v for k, v in miss.items() if k != '_n'}

# ---- 孤立菜单函数 ----
#
# 上面的扫描只看 `_[a-z]` 开头的函数, 所以 `cdn_menu` 这种**没下划线**的
# 菜单函数漏网了。实测: cdn_menu 定义在 cdn.sh:639, 全仓库
# **零调用点** —— 整个 CDN 回源管理菜单没有任何入口, 用户根本进不去。
# 而它内部还藏着一个渲染 bug (ui_menu 传了 5 个参数), 一直没人发现。
#
# 教训: 一个够不到的菜单等于不存在, 而且它的问题永远不会暴露。
# 所以单独查一遍所有 *_menu 函数的调用点。
orphan_menu = []
for p in files:
    src = io.open(p, encoding='utf-8').read()
    for i, l in enumerate(src.split('\n'), 1):
        m = re.match(r'^([a-zA-Z_]\w*_menu)\(\)\s*\{', l)
        if not m:
            continue
        name = m.group(1)
        if name == 'ui_menu':          # 是渲染原语, 由 install.sh 定义
            continue
        calls = 0
        for q in files:
            for j, ll in enumerate(io.open(q, encoding='utf-8').read().split('\n'), 1):
                code = ll.split('#')[0]
                if re.match(r'^\s*' + re.escape(name) + r'\(\)', ll):
                    continue           # 定义行本身
                if re.search(r'(?<![\w-])' + re.escape(name) + r'(?=[\s;|&)]|$)', code):
                    calls += 1
        if calls == 0:
            orphan_menu.append(f'{os.path.basename(p)}:{i} {name}')

if miss:
    for k, v in sorted(miss.items()):
        print(f'❌ {k} 未定义, 被引用: {", ".join(v[:3])}')
if orphan_menu:
    for o in orphan_menu:
        print(f'❌ 孤立菜单函数 (零调用点, 用户进不去): {o}')
if miss or orphan_menu:
    sys.exit(1)
PY
}
# server.sh 里 BATCH_PROTO_ONLY 写死了 all.sh 的档位 id。两份清单分处两个
# 文件, 任何一边增删档位都不会通知对方 —— 上一轮删掉明文 "vmess" 档位后,
# 「添加节点 → 7) VMess」就静默失效: check_only_tokens 整批 return 1,
# 用户看到的是"无法识别的协议标识", 完全想不到是菜单里写了个过期 id。
#
# 这类漂移靠人记不住, 只能自动查。
ids_consistent() {
    python3 - <<'PY'
import re, sys
srv = open("src/server.sh", encoding="utf-8").read()
allsh = open("src/conf/all.sh", encoding="utf-8").read()

m = re.search(r'ALL_GEN_IDS="([^"]*)"', allsh)
if not m:
    print("❌ 找不到 ALL_GEN_IDS"); sys.exit(1)
legal = set(m.group(1).split())

bad = []
for mm in re.finditer(r'BATCH_PROTO_ONLY=\(([^)]*)\)', srv):
    for grp in re.findall(r'"([^"]*)"', mm.group(1)):
        for tok in grp.split(","):
            tok = tok.strip()
            # 跳过 shell 变量引用 (--only "$only" 这类) —— 它们不是字面 id,
            # 真正的字面 id 一律是纯小写字母/数字/短横线
            if tok and "$" not in tok and not re.fullmatch(r"[A-Za-z0-9_-]+", tok):
                continue
            if tok and tok not in legal:
                bad.append(tok)

# --only 的单值形式也常常被手写
for mm in re.finditer(r'_all_run\s+--only\s+"([^"]+)"', srv):
    for tok in mm.group(1).split(","):
        tok = tok.strip()
        if "$" in tok or not re.fullmatch(r"[A-Za-z0-9_-]+", tok):
            continue
        if tok and tok not in legal:
            bad.append(tok)

if bad:
    print("❌ 菜单/脚本里引用了 all.sh 里不存在的档位 id: %s" % ", ".join(sorted(set(bad))))
    print("   合法 id: %s" % " ".join(sorted(legal)))
    sys.exit(1)
PY
}

run_gate "档位 id 一致"   ids_consistent
# 预置表不能宣传**对应协议脚本产不出来**的东西。
#
# 实测翻车: VLESS 预置表里有 4 档挂着 REALITY, 而 src/conf/VLESS.sh 里
# 一个 reality 字都没有 (REALITY 是独立的 Reality.sh)。用户一路回车选中
# "① 隐匿优先 · REALITY", 面板照打"已套用预置", 实际产出纯 TLS 节点,
# 没有一句"已降级"。预置表借用隔壁脚本的能力 = 骗用户。
preset_scope() {
    python3 - <<'PY'
import re, sys, os
pre = open("src/lib/preset.sh", encoding="utf-8").read()
rows = re.findall(r'"([a-z0-9-]+\|[^"]*\|[^"]*)"', pre)
# 协议 -> 脚本路径
SCRIPT = {"vless": "src/conf/VLESS.sh", "vmess": None,
          "trojan": "src/conf/Trojan.sh", "anytls": "src/conf/AnyTLS.sh",
          "hysteria2": "src/conf/hysteria2.sh", "tuic": "src/conf/TUIC.sh",
          "ss": None, "snell": None}
bad = []
for r in rows:
    cols = r.split("|")
    if len(cols) < 7:
        continue
    # 行结构: 协议|id|显示名|传输|mux|flow|证书|说明|标签|extra
    #        0    1   2      3    4    5    6
    proto, cert = cols[0], cols[6].strip()
    path = SCRIPT.get(proto)
    if not path or not os.path.exists(path):
        continue
    # ⚠ 必须**去掉注释**再判断。脚本注释里出现 "REALITY" 是正常的
    #   (说明为什么这里不做 REALITY), 直接全文 grep 会把注释当成实现,
    #   关卡就永远不报警 —— 那样这道关卡等于没有。
    src = open(path, encoding="utf-8").read()
    code = "\n".join(re.sub(r"#.*$", "", ln) for ln in src.splitlines())
    # 判据看**实际产出 REALITY 的东西**: 写进配置的 reality-opts,
    # 或调用生成密钥的函数。只看变量名会被一堆同名局部变量带偏。
    implements_reality = ("reality-opts" in code
                          or "gen_reality_keys" in code
                          or "generate_reality" in code)
    if cert == "reality" and not implements_reality:
        bad.append("%s: 预置标 REALITY 但 %s 里没有 reality 实现" % (proto, path))
if bad:
    for b in sorted(set(bad)):
        print("❌ " + b)
    print("   预置表只能描述该脚本**真的能产出**的形态; 借隔壁脚本的能力等于骗用户。")
    sys.exit(1)
PY
}

run_gate "预置不越权"   preset_scope

run_gate "幽灵函数"     phantom_scan

printf "\n"
if (( failed )); then
    printf "${RED}═══ %d/%d 项未通过 ═══${RESET}\n" "$failed" "$total"
    printf "  失败: %s\n\n" "${FAILED_NAMES[*]}"
    exit 1
fi
printf "${GREEN}═══ 全部 %d 项通过 ═══${RESET}\n\n" "$total"
exit 0
