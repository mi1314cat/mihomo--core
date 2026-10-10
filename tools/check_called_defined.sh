#!/usr/bin/env bash
# =============================================================
# check_called_defined.sh — 校验「调用的函数」真的存在
# =============================================================
#
# 为什么需要它 (这是「幽灵函数」闸门的镜像):
#
# 本项目的主导 bug 类型是「两处必须一致, 但没有任何机制保证」。函数名就是
# 其中最隐蔽的一处: **定义在一个文件, 调用在另一个文件**(各 lib 互相 source),
# 名字对不上时 bash 不会在启动时报错 —— 只有真的跑到那一行才 command not
# found, 而调用点通常包在 `$( ... 2>/dev/null)` 或 `if ...; then` 里, 报错被
# 吞掉, 剩下的只是一次**静默失败**。
#
# 已经真实翻车过一次:
#   src/conf/hysteria2.sh 有 7 处调用 `extract_cert_domain`, 而真名是
#   `cert_extract_domain` (src/lib/cert.sh:230) —— 少了 `cert_` 前缀。
#   这个名字在整个 git 历史里**从未存在过**。后果: hy2 重建时取不到证书域名,
#   产出的节点 SNI 是空的, 而面板一路打印"已套用"。
#
# 所以查两件事:
#   1. 调用了但**全仓库**都没有定义的名字;
#   2. 排除掉外部命令 (PATH 上的可执行文件) 与 bash 内建/关键字 —— 只有
#      "既没定义、又不在 PATH、又不是内建" 的名字才算**内部函数漏定义**。
#
# 扫描范围:
#   * 调用点: src/**/*.sh        (面板本体; install.sh 的装机命令不在其列)
#   * 定义集: 仓库内全部 *.sh    (跨文件定义是合法的 —— 这正是要支持的用法)
#
# 已知盲区 (故意保守, 宁可漏报不可误报):
#   * heredoc 正文里的 shell 代码不扫 (heredoc 内容不是直接执行的 shell);
#   * 变量命令 `"$fn" args`、`sudo foo` 这类间接调用不扫;
#   * 名字出现在引号里 / case 分支模式里时不当作调用。
#
# 用法: bash tools/check_called_defined.sh    退出码 0=通过 1=有漏定义
# =============================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
fail=0

# 外部命令白名单: 只放"确实存在、但可能没装在跑闸门这台机器上"的 CLI 工具。
# 判据是 PATH + bash 内建, 而 dev 容器/CI 上未必装了 firewalld / X11 剪贴板
# / RHEL 包管理器 —— 不列出来就会把"跑闸门的机器缺工具"误报成"内部函数漏定义"。
# ★ 绝不要把本项目的函数名写进来 —— 那等于把要抓的 bug 类型放走。
EXTERNAL_ALLOW="
apt-get apt dnf yum pacman apk zypper brew
systemctl service journalctl
ufw firewall-cmd nft iptables ip6tables
dig host hostname ss netstat
docker podman
flock stat uuidgen tput shuf od nl
unzip zip wget curl git jq openssl
mihomo xclip xsel pbcopy
"

printf "\n═══ 调用/定义一致性 (调用了但从未定义) ═══\n\n"

command -v python3 >/dev/null 2>&1 || { printf "${RED}❌ 需要 python3${RESET}\n"; exit 2; }

# python 只负责"语法层"的事: 抽出所有命令位置的调用名 + 全仓库定义名,
# 把"没定义"的候选按 `名字<TAB>文件:行` 打出来 (同一个名字可能有多处调用点)。
# 是否外部命令/内建由 bash 侧用 type -t / command -v 判断 (口径最准)。
candidates=$(python3 - <<'PY'
import io, os, re, sys

# ---------- 预扫描: 去掉 heredoc 正文 (保持行号不变) ----------
def code_of_line(line):
    """去掉行尾注释 (引号感知), 用于判断这一行有没有真的 `<<` 操作符。"""
    out, i, n, wstart = [], 0, len(line), True
    while i < n:
        c = line[i]
        if c == '\\':
            out.append(line[i:i+2]); i += 2; wstart = False; continue
        if c == "'":
            j = line.find("'", i + 1); j = n if j < 0 else j + 1
            out.append(line[i:j]); i = j; wstart = False; continue
        if c == '"':
            j = i + 1
            while j < n and line[j] != '"':
                if line[j] == '\\': j += 2; continue
                j += 1
            out.append(line[i:j+1]); i = j + 1; wstart = False; continue
        if c == '#' and wstart:
            break
        if c in ' \t': wstart = True
        elif c not in ';&|(){}<>': wstart = False
        out.append(c); i += 1
    return ''.join(out)


def find_heredoc(line):
    """返回 (代码部分, heredoc 结束标记); 没有 heredoc 时标记为 None。

    ★ 必须引号感知: `RULES_END="# <<< mihomo-panel ..."` 这种**字符串里**的
      `<<` 曾被当成 heredoc 开头, 于是整个文件后半段被当成正文吞掉 ——
      定义集合凭空少了一半, 闸门反而更不容易报警。
    """
    code = code_of_line(line); i, n = 0, len(code)
    while i < n:
        c = code[i]
        if c == '\\': i += 2; continue
        if c == "'":
            j = code.find("'", i + 1); i = n if j < 0 else j + 1; continue
        if c == '"':
            j = i + 1
            while j < n and code[j] != '"':
                if code[j] == '\\': j += 2; continue
                j += 1
            i = j + 1; continue
        if code.startswith('<<', i) and not code.startswith('<<<', i):
            m = re.match(r'<<-?[ \t]*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1', code[i:])
            if m:
                return code[:i], m.group(2)
        i += 1
    return code, None


def strip_heredocs(text):
    lines = text.split('\n'); out = []; i = 0
    while i < len(lines):
        code, tag = find_heredoc(lines[i])
        if tag:
            term = re.compile(r'^\s*' + re.escape(tag) + r'[ \t]*[);]{0,2}[ \t]*$')
            j = i + 1
            while j < len(lines) and not term.match(lines[j]):
                j += 1
            if j < len(lines):                  # 找到结束标记才敢抹; 否则原样保留
                out.append(code)
                out += [''] * (j - i)
                i = j + 1
                continue
        out.append(lines[i]); i += 1
    return '\n'.join(out)


# ---------- 收集定义 ----------
DEF_RE = re.compile(r'^([ \t]*)(?:(function)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*(\(\s*\))?[ \t]*(\{)')
DEF_ALONE_RE = re.compile(r'^([ \t]*)(?:(function)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\s*\)[ \t]*$')


def collect_defs(text):
    """抽出 `name() {` 与 `function name {`; 定义行本身不再被当成调用。"""
    lines = text.split('\n'); defs = {}
    for idx, ln in enumerate(lines):
        m = DEF_RE.match(ln)
        if m and (m.group(2) or m.group(4)):
            defs.setdefault(m.group(3), idx + 1)
            lines[idx] = ' ' * m.start(5) + ln[m.start(5):]
            continue
        m2 = DEF_ALONE_RE.match(ln)
        if m2:                                   # 花括号写在下一行的写法
            j = idx + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and lines[j].lstrip().startswith('{'):
                defs.setdefault(m2.group(3), idx + 1)
                lines[idx] = ' ' * len(ln)
    return defs, '\n'.join(lines)


# ---------- 词法扫描: 找命令位置的调用 ----------
IDENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_.+-]*$')
ASSIGN_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=')
KW_END = {'fi', 'done', 'esac'}
KW_BODY = {'then', 'else', 'elif', 'do'}
KW_KEEP_CMD = {'if', 'then', 'elif', 'else', 'while', 'until', 'do', '!', 'time', '{'}


def match_close(s, i, op='(', cl=')'):
    depth, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '\\': i += 2; continue
        if c == "'":
            i += 1
            while i < n and s[i] != "'": i += 1
            i += 1; continue
        if c == '"':
            i += 1
            while i < n and s[i] != '"':
                if s[i] == '\\': i += 2; continue
                if s[i] == '$' and i + 1 < n and s[i+1] == '(':
                    i = match_close(s, i + 1); continue
                i += 1
            i += 1; continue
        if c == op: depth += 1; i += 1; continue
        if c == cl:
            depth -= 1; i += 1
            if depth == 0: return i
            continue
        i += 1
    return n


class Scanner:
    """足够用的 shell 词法扫描器: 只关心"命令位置的第一个词"。

    行号一律由**字符偏移**反算 (1 + text[:off].count('\n')), 不维护行号计数器
    —— 计数器在任何一处漏加/多加都会把后面所有行号带偏, 报出来的位置就是错的。
    """

    def __init__(self, text, path):
        self.s = text; self.path = path
        self.i = 0; self.n = len(text)
        self.cmd_pos = True; self.case_stack = []; self.for_mode = False
        self.pending_array = False
        self.word = ''; self.woff = 0
        self.calls = []

    def line_of(self, off):
        return 1 + self.s.count('\n', 0, off)

    def skip(self, j):
        self.i = min(j, self.n)

    def push(self, c):
        if not self.word: self.woff = self.i
        self.word += c

    def finish_word(self):
        w = self.word; self.word = ''
        if not w: return
        is_assign = bool(ASSIGN_RE.match(w))
        if is_assign and w.endswith('='): self.pending_array = True
        if is_assign and self.cmd_pos: return            # VAR=... 前缀, 后面还是命令位置
        if w == 'in':                                    # case/for 的 in 不在命令位置
            if self.case_stack and self.case_stack[-1] == 'await_in':
                self.case_stack[-1] = 'pattern'
            self.cmd_pos = False; return
        if w in KW_END:
            if w == 'esac' and self.case_stack: self.case_stack.pop()
            if w == 'done': self.for_mode = False
            self.cmd_pos = False; return
        if w in KW_BODY:
            self.cmd_pos = True
            if w == 'do': self.for_mode = False
            return
        if not self.cmd_pos: return
        if w == 'case':
            self.case_stack.append('await_in'); self.cmd_pos = False; return
        if w in ('for', 'select'):
            self.for_mode = True; self.cmd_pos = False; return
        if w in KW_KEEP_CMD:
            self.cmd_pos = True; return
        if self.case_stack and self.case_stack[-1] == 'pattern':
            self.cmd_pos = False; return
        if IDENT_RE.match(w): self.calls.append((w, self.woff))
        self.cmd_pos = False

    def scan(self, start, end):
        si, sn = self.i, self.n
        self.i, self.n = start, end
        while self.i < self.n:
            c = self.s[self.i]
            if c == '\n':
                self.finish_word(); self.skip(self.i + 1)
                self.cmd_pos = not self.for_mode and not (
                    self.case_stack and self.case_stack[-1] == 'pattern')
                continue
            if c in ' \t': self.finish_word(); self.skip(self.i + 1); continue
            if c == '#' and not self.word:
                j = self.s.find('\n', self.i); self.skip(self.n if j < 0 else j); continue
            if c == '\\':
                nx = self.s[self.i+1] if self.i+1 < self.n else ''
                self.push(nx); self.skip(self.i + 2); continue
            if c == "'": self.read_squote(); continue
            if c == '"': self.read_dquote(); continue
            if c == '`':
                j = self.s.find('`', self.i + 1); j = self.n if j < 0 else j
                self.sub_scan(self.i + 1, j); self.push('`'); self.skip(j + 1); continue
            if c == '$' and self.i+1 < self.n and self.s[self.i+1] == '(':
                self.read_cmdsub(); continue
            if c == '$' and self.i+1 < self.n and self.s[self.i+1] == '{':
                j = self.skip_braced(self.i); self.push(self.s[self.i:j]); self.skip(j); continue
            if c == '(' and self.i+1 < self.n and self.s[self.i+1] == '(':
                self.finish_word(); self.skip(self.skip_arith(self.i)); continue
            if c == '(':
                self.finish_word()
                j = match_close(self.s, self.i)
                if self.pending_array:
                    self.pending_array = False; self.scan_array(self.i + 1, j - 1)
                else:
                    self.sub_scan(self.i + 1, j - 1)     # 子 shell / 命令替换内容照扫
                self.skip(j); self.cmd_pos = False; continue
            if c in ')}':
                self.finish_word(); self.skip(self.i + 1)
                if c == ')' and self.case_stack and self.case_stack[-1] == 'pattern':
                    self.case_stack[-1] = 'body'; self.cmd_pos = True
                else:
                    self.cmd_pos = False
                continue
            if c == '{' and (self.i+1 >= self.n or self.s[self.i+1] in ' \t\n;'):
                self.finish_word(); self.skip(self.i + 1); self.cmd_pos = True; continue
            if c in ';|&':
                self.finish_word()
                if self.s.startswith(';;', self.i):
                    self.skip(self.i + (3 if self.s.startswith(';;&', self.i) else 2))
                    if self.case_stack: self.case_stack[-1] = 'pattern'
                    self.cmd_pos = False; continue
                if self.s.startswith(';&', self.i):
                    self.skip(self.i + 2)
                    if self.case_stack: self.case_stack[-1] = 'body'
                    self.cmd_pos = True; continue
                if self.s.startswith('&&', self.i) or self.s.startswith('||', self.i):
                    self.skip(self.i + 2); self.cmd_pos = True; continue
                self.skip(self.i + 1)
                self.cmd_pos = not self.for_mode and not (
                    self.case_stack and self.case_stack[-1] == 'pattern')
                continue
            if c in '<>':
                if self.i+1 < self.n and self.s[self.i+1] == '(':   # <(cmd) 进程替换
                    self.finish_word(); self.skip(self.i + 1)
                    j = match_close(self.s, self.i); self.sub_scan(self.i + 1, j - 1)
                    self.skip(j); continue
                self.finish_word()
                j = self.i
                while j < self.n and self.s[j] in '<>': j += 1
                if j < self.n and self.s[j] == '&': j += 1
                self.skip(j)
                while self.i < self.n and self.s[self.i] in ' \t': self.skip(self.i + 1)
                self.skip_redirect_target(); continue
            self.push(c); self.skip(self.i + 1)
        self.finish_word()
        self.i, self.n = si, sn

    def read_squote(self):
        j = self.s.find("'", self.i + 1); j = self.n if j < 0 else j
        self.push(self.s[self.i:j+1]); self.skip(j + 1)

    def read_dquote(self):
        self.push('"'); self.skip(self.i + 1)
        while self.i < self.n:
            c = self.s[self.i]
            if c == '"': self.push('"'); self.skip(self.i + 1); return
            if c == '\\': self.push(self.s[self.i:self.i+2]); self.skip(self.i + 2); continue
            if c == '$' and self.i+1 < self.n and self.s[self.i+1] == '(':
                self.read_cmdsub(); continue
            if c == '`':
                j = self.s.find('`', self.i + 1); j = self.n if j < 0 else j
                self.sub_scan(self.i + 1, j); self.push('`'); self.skip(j + 1); continue
            self.push(c); self.skip(self.i + 1)

    def read_cmdsub(self):
        if self.s.startswith('$((', self.i):                  # $((算术)) 整体跳过
            self.skip(self.skip_arith(self.i + 1)); self.push('$()'); return
        j = match_close(self.s, self.i + 1)
        self.sub_scan(self.i + 2, j - 1)
        self.push('$()'); self.skip(j)

    def skip_arith(self, i):
        j, depth = i + 2, 1
        while j < self.n:
            c = self.s[j]
            if c == '\\': j += 2; continue
            if c == '(': depth += 1; j += 1; continue
            if c == ')':
                depth -= 1; j += 1
                if depth == 0:
                    if j < self.n and self.s[j] == ')': j += 1
                    break
                continue
            j += 1
        return j

    def skip_braced(self, i):
        j, depth = i + 2, 1
        while j < self.n and depth:
            c = self.s[j]
            if c == '\\': j += 2; continue
            if c == '{': depth += 1
            elif c == '}': depth -= 1
            j += 1
        return j

    def skip_redirect_target(self):
        """重定向目标是一个完整 word: `<<< "$(cmd a b)"` 里有空格。

        天真地按空白切会从中间断开, 剩下的引号把整个词法状态带偏
        (实测: src/conf/AnyTLS.sh 从 372 行起引号全部错位, 误报一片)。
        """
        sw, so, scp = self.word, self.woff, self.cmd_pos
        self.word = ''
        while self.i < self.n:
            c = self.s[self.i]
            if c in ' \t\n;&|<>': break
            if c == '\\': self.skip(self.i + 2); continue
            if c == "'": self.read_squote(); continue
            if c == '"': self.read_dquote(); continue
            if c == '`':
                j = self.s.find('`', self.i + 1); j = self.n if j < 0 else j
                self.sub_scan(self.i + 1, j); self.skip(j + 1); continue
            if c == '$' and self.i+1 < self.n and self.s[self.i+1] == '(':
                self.read_cmdsub(); continue
            if c == '$' and self.i+1 < self.n and self.s[self.i+1] == '{':
                self.skip(self.skip_braced(self.i)); continue
            self.skip(self.i + 1)
        self.word, self.woff, self.cmd_pos = sw, so, scp

    def sub_scan(self, start, end):
        st = (self.i, self.n, self.cmd_pos, self.word, self.woff,
              self.pending_array, self.for_mode, list(self.case_stack))
        self.i, self.n = start, end
        self.cmd_pos = True; self.case_stack = []; self.for_mode = False
        self.pending_array = False; self.word = ''
        self.scan(start, end)
        (self.i, self.n, self.cmd_pos, self.word, self.woff,
         self.pending_array, self.for_mode, cs) = st
        self.case_stack = cs

    def scan_array(self, start, end):
        """数组字面量 `X=(a b c)`: 元素不是命令, 但里面的 $(...) 仍是命令。"""
        si, sn = self.i, self.n
        self.i, self.n = start, end
        while self.i < self.n:
            c = self.s[self.i]
            if c == '\\': self.skip(self.i + 2); continue
            if c == "'":
                j = self.s.find("'", self.i + 1); self.skip((self.n if j < 0 else j) + 1); continue
            if c == '"':
                j = self.i + 1
                while j < self.n and self.s[j] != '"':
                    if self.s[j] == '\\': j += 2; continue
                    j += 1
                self.skip(j + 1); continue
            if c == '$' and self.i+1 < self.n and self.s[self.i+1] == '(':
                self.read_cmdsub(); continue
            if c == '`':
                j = self.s.find('`', self.i + 1); j = self.n if j < 0 else j
                self.sub_scan(self.i + 1, j); self.skip(j + 1); continue
            self.skip(self.i + 1)
        self.i, self.n = si, sn


def sh_files(root):
    out = []
    for dirpath, _, files in os.walk(root):
        out += [os.path.join(dirpath, f) for f in files if f.endswith('.sh')]
    return sorted(out)


def main():
    # 定义集: 仓库内全部 shell 文件 (跨文件定义是本项目的正常用法)
    defined = {}
    for p in sh_files('.'):
        txt = strip_heredocs(io.open(p, encoding='utf-8', errors='replace').read())
        d, _ = collect_defs(txt)
        for k, v in d.items():
            defined.setdefault(k, p + ':' + str(v))
    # 调用点: 只看 src/ 下的面板脚本
    calls = {}
    for p in sh_files('src'):
        txt = strip_heredocs(io.open(p, encoding='utf-8', errors='replace').read())
        _, body = collect_defs(txt)
        sc = Scanner(body, p)
        sc.scan(0, len(body))
        for name, off in sc.calls:
            if name in defined:
                continue
            calls.setdefault(name, [])
            loc = p + ':' + str(sc.line_of(off))
            if loc not in calls[name]:
                calls[name].append(loc)
    sys.stdout.write('#STATS %d %d %d\n' % (len(sh_files('src')), len(defined), len(calls)))
    for name in sorted(calls):
        for loc in calls[name]:
            sys.stdout.write(name + '\t' + loc + '\n')


main()
PY
)

declare -A SITES=()
declare -a ORDER=()
while IFS=$'\t' read -r name loc; do
    [[ -n "$name" && -n "$loc" ]] || continue
    [[ -n "${SITES[$name]:-}" ]] || ORDER+=("$name")
    SITES[$name]+=" $loc"
done <<< "$candidates"

# 分类: bash 内建 / 关键字 -> 放行; PATH 上有 -> 外部命令放行;
# 白名单里的 CLI 工具 (本机可能没装) -> 放行; 其余 = 内部函数漏定义。
declare -a BAD=()
declare -a ALLOWED_ABSENT=()
declare -A ALLOW_SET=()
for a in $EXTERNAL_ALLOW; do ALLOW_SET[$a]=1; done
for name in "${ORDER[@]:-}"; do
    [[ -n "$name" ]] || continue
    t="$(type -t -- "$name" 2>/dev/null || true)"
    case "$t" in builtin|keyword|function|alias) continue ;; esac
    if command -v -- "$name" >/dev/null 2>&1; then continue; fi
    if [[ -n "${ALLOW_SET[$name]:-}" ]]; then
        ALLOWED_ABSENT+=("$name"); continue
    fi
    BAD+=("$name")
done

if (( ${#ALLOWED_ABSENT[@]} > 0 )); then
    printf "  ${YELLOW}⚠${RESET}  本机没装 (按外部 CLI 工具放行): %s\n" "${ALLOWED_ABSENT[*]}"
fi

if (( ${#BAD[@]} == 0 )); then
    stats=$(printf '%s\n' "$candidates" | sed -n 's/^#STATS //p')
    read -r n_files n_defs n_cand <<< "$stats"
    n_all=$(find . -name '*.sh' -not -path './.git/*' | wc -l)
    printf "  ${GREEN}✅${RESET} 命令位置的调用名全部有定义或为外部命令/内建\n"
    printf "     (面板脚本 %s 个 / 全仓库定义 %s 个函数 (%s 个 shell 文件参与) / 无定义候选 %s 个)\n" \
        "${n_files:-?}" "${n_defs:-?}" "${n_all:-?}" "${n_cand:-?}"
    exit 0
fi

printf "  ${RED}❌${RESET} 调用了、但整个仓库从来没有定义过的内部函数 (%d 个):\n" "${#BAD[@]}"
for name in "${BAD[@]}"; do
    sites=(${SITES[$name]})
    for loc in "${sites[@]:0:4}"; do
        printf "       %s: %s\n" "$loc" "$name"
    done
    (( ${#sites[@]} > 4 )) && printf "       ... 另有 %d 处调用点\n" "$(( ${#sites[@]} - 4 ))"
done
printf "  ${RED}❌${RESET} 调用点拼错函数名 = 运行到那一行才 command not found,\n"
printf "     而它通常包在 \$(... 2>/dev/null) 或 if ...; then 里 → 静默失败。\n"
printf "     修法: 改成仓库里真实存在的名字 (grep -rn '函数名()' src/)。\n"
exit 1
