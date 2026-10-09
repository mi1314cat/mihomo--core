#!/usr/bin/env bash
# =============================================================
# 一键生成全协议节点 (all.sh)
#
#   一次跑完所有能在当前 Mihomo 内核上做 **入站** 的协议,
#   最后统一走 merge → 严格校验 → mihomo -t → 重载。
#
# 与逐个菜单添加的区别:
#   * 不需要反复交互, 端口自动分配
#   * 全部节点共享同一套 UUID / Reality 密钥 / 证书
#   * 任何一个协议失败不影响其他, 末尾统一汇总
#   * 最终只重载一次, 中途不会把服务弄成半死状态
#
# 用法:
#   bash all.sh                    # 自动检测证书, 生成全部
#   bash all.sh --quick            # 不提问, 端口区间自动分配
#   bash all.sh --force            # 重建: 先清掉同协议旧节点再重新生成
#   bash all.sh --no-tls           # 跳过所有需要证书的协议
#   bash all.sh --self-sign        # 没有真证书时生成自签, 让 TLS 协议也全量产出
#   bash all.sh --only reality,trojan,hysteria2
#   bash all.sh --fp firefox       # 换 client-fingerprint (默认 chrome)
#   bash all.sh --dry-run          # 只看会生成什么, 不落盘
#
# 环境变量 (批量一律走显式环境变量, 绝不读应答串 —— 交互提问 + 应答串重放
# 必然整体错位):
#   CLIENT_FP=chrome|firefox|safari|edge|ios|android|random   (等价于 --fp)
#   ALL_CERT_MODE=real|self|none   证书方案: real 只用真证书, self 允许自签
#                                  (等价于 --self-sign), none 等同 --no-tls
#   XHTTP_MODE=auto|stream-one|stream-up|packet-up             (默认 auto)
#   XHTTP_PAD=std|strong|max                                   (默认 std)
#   VMESS_PAD=0|1              VMess 客户端 global-padding 等 (默认 1)
#   ALL_PORT_BASE=20000        端口扫描起点
# =============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SELF_DIR/../lib/env.sh" 2>/dev/null || {
    echo "找不到 src/lib/env.sh, 请从仓库内运行" >&2; exit 1; }

# =============================================================
# 参数解析 —— 此前**这段根本不存在**
#
# 文件头一直写着 --dry-run / --no-tls / --only / --fp, server.sh 的
# _all_run 也确实把它们原样传了进来, 但 all.sh 里没有一行读 $@, 而
# CLIENT_FP / DRY_RUN / USE_TLS / ONLY 也没有任何默认值。在 set -u 下,
# 任何用户点「全协议一键生成」都会立刻死在:
#
#     all.sh: line 58: CLIENT_FP: unbound variable
#
# 于是这个功能对所有人都是**一次都跑不起来**的。
#
# 更危险的是「先预览」那一档: --dry-run 传进来无人接收, DRY_RUN 又是空的,
# 结果"预览"会**真的写文件并重载服务** —— 用户以为只是看一眼。
#
# 排查时先确认过这不是新引入的回归: 基线提交同样是 0 个参数分支、
# 0 个默认值, 所以它从一开始就没工作过。
#
# 默认值一律写成 ${VAR:-默认}: 既能被环境变量覆盖, 单独跑也不会炸。
# =============================================================
CLIENT_FP="${CLIENT_FP:-chrome}"
DRY_RUN="${DRY_RUN:-0}"
USE_TLS="${USE_TLS:-1}"
ONLY="${ONLY:-}"
QUICK="${QUICK:-0}"
FORCE="${FORCE:-0}"
# 证书方案。auto = 有真证书就用、没有就跳过 (旧行为);
# self = 没有真证书就生成自签证书, 让需要 TLS 的协议也全量产出。
# 非交互场景用 ALL_CERT_MODE=real|self|none 指定, 与其它公共参数一致。
CERT_MODE="${CERT_MODE:-${ALL_CERT_MODE:-auto}}"

while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-tls)  USE_TLS=0 ;;
        --self-sign) CERT_MODE=self ;;
        --quick)   QUICK=1 ;;
        --force)   FORCE=1 ;;
        --fp)      CLIENT_FP="${2:-}"; shift ;;
        --fp=*)    CLIENT_FP="${1#*=}" ;;
        --only)    ONLY="${2:-}"; shift ;;
        --only=*)  ONLY="${1#*=}" ;;
        -h|--help)
            sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'
            exit 0 ;;
        *)
            print_error "未知参数: $1"
            print_error "可用: --dry-run | --no-tls | --self-sign | --quick | --force | --only <ids> | --fp <name>"
            exit 2 ;;
    esac
    shift
done

# --only 允许 "a,b" / "a b" / "a, b" 混写, 统一成逗号分隔
if [[ -n "$ONLY" ]]; then
    ONLY="$(printf '%s' "$ONLY" | tr '[:space:]' ',' | tr -s ',' | sed 's/^,//; s/,$//')"
fi

CONF_DIR="${CONF_DIR:-$SRV_ROOT/conf/config.d}"
OUT_DIR="${OUT_DIR:-$SRV_ROOT/out}"
CERTS_DIR="${CERTS_DIR:-$SRV_ROOT/conf/certs}"
MIHOMO_BIN="${MIHOMO_BIN:-$SRV_BIN}"

# =============================================================
# 重建 (--force) 的暂存区
#
# --force 要"先清掉同协议旧节点再重新生成"。直接 rm 是不行的: 万一新配置
# 没通过末尾的 m_sync_reload 校验, 旧节点已经没了, 用户就从"想重建"变成
# "一个节点都没有"。所以清掉的东西先**挪进暂存区**, 末尾校验通过才真删,
# 不通过就原样挪回来。
#
# 暂存区放在 $SRV_ROOT 下而不是 /tmp: /tmp 可能被清、可能跨文件系统 (mv 变
# 成拷贝), 而这里必须保证是同一个文件系统上的原子 mv。
# =============================================================
REBUILD_BAK="$SRV_ROOT/.rebuild-bak"
declare -A _FORCE_DONE=()

if [[ "$FORCE" == "1" && "$DRY_RUN" != "1" ]]; then
    rm -rf "$REBUILD_BAK"
    mkdir -p "$REBUILD_BAK"
fi

# 把某个管理协议名下的节点挪进暂存区 (幂等: 同一 mproto 只做一次)。
#
# 按 mproto 而不是 proto: all.sh 一次会生成多个 vless 变体, 它们共享
# vless-NN 这条编号序列, 所以清理也必须按整条序列来, 否则只清掉变体自己
# 那几个, 剩下的旧序号还会占着位置。
force_wipe_mproto() {
    [[ "$FORCE" == "1" ]] || return 0
    # 预览绝不能动文件 —— --dry-run 的整个意义就是"不落盘"。
    # 这里放行会让 `--dry-run --force` 悄悄挪走旧节点, 而用户以为只是看一眼。
    [[ "$DRY_RUN" == "1" ]] && return 0
    local mproto="$1"
    [[ -z "${_FORCE_DONE[$mproto]:-}" ]] || return 0
    _FORCE_DONE[$mproto]=1

    local f n=0
    for f in "$CONF_DIR/$mproto"-[0-9][0-9].yaml; do
        [[ -f "$f" ]] || continue
        mv -f "$f" "$REBUILD_BAK/" && n=$(( n + 1 ))
    done
    for f in "$OUT_DIR/${mproto}_"*_client-[0-9][0-9].yaml; do
        [[ -f "$f" ]] || continue
        mv -f "$f" "$REBUILD_BAK/" && n=$(( n + 1 ))
    done
    (( n > 0 )) && print_info "重建: 已挪走 $mproto 的 $n 个旧文件 (校验通过后才真删)"
    return 0
}

# 末尾用: 校验通过 → 真删暂存区; 不通过 → 挪回来。
rebuild_commit()  { [[ "$FORCE" == "1" ]] && rm -rf "$REBUILD_BAK"; return 0; }
rebuild_rollback() {
    [[ "$FORCE" == "1" && -d "$REBUILD_BAK" ]] || return 0
    local f n=0
    for f in "$REBUILD_BAK"/*; do
        [[ -e "$f" ]] || continue
        # 按文件名里的协议前缀送回原来的目录
        if [[ "$(basename "$f")" == *_client-*.yaml ]]; then
            mv -f "$f" "$OUT_DIR/" && n=$(( n + 1 ))
        else
            mv -f "$f" "$CONF_DIR/" && n=$(( n + 1 ))
        fi
    done
    rmdir "$REBUILD_BAK" 2>/dev/null
    (( n > 0 )) && print_warn "重建未生效, 已还原 $n 个旧文件"
    return 0
}

# UI 原语统一来自 src/lib/ui.sh (颜色/消息分级/标题), 此处不再重复定义。
# 被父级 source 时已加载; 单独运行时由下面的兜底 source 补上。

# =============================================================
# client-fingerprint 校验 (必须在这里拦, 不能只靠内核)
#
# 内核对无法识别的指纹只打一条 log.Warnln 就**静默降级成原生 TLS**,
# 没有任何报错 (component/tls/utls.go:56-59)。
# 也就是说写错了: 面板全绿、-t 通过, 直到第一次真实握手才暴露 —— 典型的
# "运行时才炸的开关"。
# 枚举取 spec §2.3.1, 故意不暴露 5 个已标 deprecated 的历史指纹。
# =============================================================
M_FP_VALUES="chrome firefox safari edge ios android random"
valid_fp() {
    local v
    for v in $M_FP_VALUES; do [[ "$1" == "$v" ]] && return 0; done
    return 1
}
if ! valid_fp "$CLIENT_FP"; then
    print_error "不支持的 client-fingerprint: $CLIENT_FP"
    print_error "可用: $M_FP_VALUES"
    print_error "(内核对未知值只会静默降级为原生 TLS, 所以在这里直接拒绝)"
    exit 1
fi

# =============================================================
# XHTTP 抗探测档位 (批量只认环境变量, 不做任何交互提问)
#
#   std     : 只调 bytes 区间, obfs 关 —— 内核本身就有默认 padding
#             (transport/xhttp/xpadding.go:180-186, 默认 "100-1000")
#   strong  : 开 x-padding-obfs-mode, padding 变成可解码的混淆流量
#   max     : strong + session/seq 挪到 header, URL 长度不再抖动
#
# mode 取值必须 proxy / listener 两侧都合法:
#   proxy     只认 stream-one / stream-up / packet-up (transport/xhttp/client.go:247-251)
#   listener  认 auto / stream-up / stream-one / packet-up (listener/sing_vless/server.go:201-205)
#   => 取交集 auto 最稳 (两侧都放行, server 侧 auto 三条路径全开, server.go:191-225)
# =============================================================
XHTTP_MODE="${XHTTP_MODE:-auto}"
XHTTP_PAD="${XHTTP_PAD:-std}"
XHTTP_PAD_HEADER="X-Pad"; XHTTP_PAD_METHOD="tokenish"
case "$XHTTP_MODE" in
    auto|stream-one|stream-up|packet-up) ;;
    *) print_error "XHTTP_MODE 非法: $XHTTP_MODE (auto / stream-one / stream-up / packet-up)"; exit 1 ;;
esac
XHTTP_PAD_BYTES="100-1000"; XHTTP_PAD_OBFS=0
XHTTP_PAD_PLACEMENT="query"
case "$XHTTP_PAD" in
    std) ;;
    strong) XHTTP_PAD_OBFS=1; XHTTP_PAD_BYTES="256-4096" ;;
    max)    XHTTP_PAD_OBFS=1; XHTTP_PAD_BYTES="512-8192"; XHTTP_PAD_PLACEMENT="header" ;;
    *) print_error "XHTTP_PAD 非法: $XHTTP_PAD (std / strong / max)"; exit 1 ;;
esac
# strong/max 档的 x-padding-key 是每个节点现场随机生成的 (见 render_xhttp_pad),
# 所以这里只提前确认 openssl 在, 免得跑到一半才发现没工具
if [[ "$XHTTP_PAD_OBFS" == "1" ]] && ! command -v openssl >/dev/null 2>&1; then
    print_error "XHTTP_PAD=$XHTTP_PAD 需要 openssl 生成 x-padding-key, 当前环境找不到"; exit 1
fi

# VMess 客户端 padding 开关 (proxy-only, 见 g_vmess_ws 注释)
VMESS_PAD="${VMESS_PAD:-1}"
case "$VMESS_PAD" in 0|1) ;; *) print_error "VMESS_PAD 只能是 0 或 1"; exit 1 ;; esac

# =============================================================
# 端口分配: 从 20000 起找一个没被占用的
# =============================================================
USED_PORTS_FILE=$(mktemp)
trap 'rm -f "$USED_PORTS_FILE"' EXIT
: > "$USED_PORTS_FILE"

collect_used_ports() {
    # 已存在的 config.d + 正在运行的监听
    #
    # ⚠ 必须判 `isinstance(d, dict)`: yaml.safe_load 对**顶层不是映射**的文件
    # (被截断的、写了一半的、根本不是 YAML 的) 返回 str / list, 后面 d.get()
    # 会抛 AttributeError。而那个 try 只包住了 safe_load —— d.get 在 try 外面,
    # 异常直接逃出去, python 退出码非 0, **USED_PORTS_FILE 只写了一半**。
    #
    # 后果不是"少扫一个文件", 而是: 端口表不全 → 已占用的端口被当成空闲重新
    # 分配 → 新节点启动即 bind 失败。一个坏文件毁掉整批节点, 且现场看不出
    # 关联 (报的是端口占用, 根因是另一个文件格式坏)。
    python3 - "$CONF_DIR" >> "$USED_PORTS_FILE" <<'PY'
import glob, sys, yaml
for f in glob.glob(sys.argv[1] + "/*.yaml"):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    for l in (d.get("listeners") or []):
        if isinstance(l, dict) and l.get("port"):
            print(l["port"])
PY
    # 主配置里已有的
    python3 - "${SRV_CONF}/config.yaml" >> "$USED_PORTS_FILE" 2>/dev/null <<'PY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit
if not isinstance(d, dict):
    raise SystemExit
for l in (d.get("listeners") or []):
    if isinstance(l, dict) and l.get("port"):
        print(l["port"])
PY
    # TCP + UDP 都要扫。
    #
    # 只扫 ss -tln 会漏掉 hysteria2 和 tuic —— 它们是 QUIC 协议, **只监听
    # UDP**。实测 13 个节点里有 2 个是 UDP-only; 只查 TCP
    # 的话这些端口会被当成"空闲"分配出去, 生成的节点启动即 bind 失败。
    { ss -tln 2>/dev/null; ss -uln 2>/dev/null; } \
        | awk 'NR>1{print $4}' | sed 's/.*://' >> "$USED_PORTS_FILE"
}

# =============================================================
# 端口区间与游标
# =============================================================
# 对齐 SB 的 batch_next_port (lib.sh:83-110): 一次问一个区间,
# 默认随机起点, 区间内顺延, 耗尽后回落随机端口。
#
# 与之前"固定从 20000 起扫 4000 次"的区别:
#   1. 用户能挑区间 —— 大批量生成时避开自己在用的段位;
#   2. 顺序递增而不是每次从头扫, 批量生成 O(n) 而不是 O(n^2);
#   3. 区间用完不直接失败, 回落随机可用端口 (SB: range exhausted 后
#      静默回落), 否则精心选的区间一满就得从头再来。
PORT_RANGE_START=20000
PORT_RANGE_END=24999
PORT_CURSOR=20000

ask_port_range() {
    # ③ 步骤风格, 与 ①② 一致。把"为什么要问"写出来:
    # 用户挑区间是为了避开自己在用的段位; 留空则由脚本随机挑一段。
    printf '\n' >&2
    printf "  ${BOLD}③ 端口区间${RESET} ${DIM}—— 每个节点一个端口, 自动顺延不冲突${RESET}\n" >&2
    printf "     ${DIM}起止: 20000-25000    只给起点: 30000 (到 39999)${RESET}\n" >&2
    printf "     ${DIM}留空 = 随机挑一段 5000 宽的区间 (推荐, 多机多批不易撞车)${RESET}\n" >&2
    printf "     ${DIM}区间用完不会失败, 会自动回落到随机空闲端口${RESET}\n" >&2
    printf "     ${CYAN}请输入${RESET} [回车=随机]: " >&2
    local v
    read -r v || v=""
    v=$(printf '%s' "$v" | tr -d '[:space:]')

    if [[ -z "$v" ]]; then
        # 默认随机起点, 宽 5000 (与 SB batch.sh:287-319 一致)。
        # 随机是为了让多台机器/多批次的分布不同, 撞车概率更低。
        local s=$(( 20000 + RANDOM % 10000 ))
        PORT_RANGE_START=$s
        PORT_RANGE_END=$(( s + 4999 ))
    elif [[ "$v" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        PORT_RANGE_START="${BASH_REMATCH[1]}"
        PORT_RANGE_END="${BASH_REMATCH[2]}"
    elif [[ "$v" =~ ^[0-9]+$ ]]; then
        PORT_RANGE_START="$v"
        PORT_RANGE_END=$(( v + 9999 ))
    else
        print_warn "无法识别的区间: $v, 改用默认" >&2
        PORT_RANGE_START=20000
        PORT_RANGE_END=24999
    fi

    # 用户可能写成 25000-20000
    (( PORT_RANGE_END < PORT_RANGE_START )) && {
        local t=$PORT_RANGE_START
        PORT_RANGE_START=$PORT_RANGE_END
        PORT_RANGE_END=$t
    }
    (( PORT_RANGE_START < 1024 )) && PORT_RANGE_START=1024
    (( PORT_RANGE_END > 65535 )) && PORT_RANGE_END=65535

    # 把**实际选中的结果**回显出来, 例如:
    #     [OK] 端口区间: 31025 - 36025 (5001 个, 每个节点一个)
    # 只说"回车=随机"而不回显, 用户不知道到底挑了哪一段 ——
    # 而这个区间后面要写进客户端配置, 是要能对得上的。
    printf "     ${GREEN}[OK]${RESET} 端口区间: %s - %s ${DIM}(%d 个, 每个节点一个)${RESET}\n" \
        "$PORT_RANGE_START" "$PORT_RANGE_END" \
        "$(( PORT_RANGE_END - PORT_RANGE_START + 1 ))" >&2
}

# 区间耗尽时的回落: 在 10000-60000 随机找一个没被占用的。
# SB 同样静默回落不报错 (batch.sh:311) —— 用户选的区间是偏好, 不是硬约束。
random_free_port() {
    local p
    for _ in $(seq 1 500); do
        p=$(( 10000 + RANDOM % 50000 ))
        grep -qx "$p" "$USED_PORTS_FILE" && continue
        echo "$p" >> "$USED_PORTS_FILE"
        printf '%s' "$p"
        return 0
    done
    return 1
}

# next_port —— 从游标处顺序取一个空闲端口。
#
# 游标在进程内 (PORT_CURSOR), 每领一个就 +1, 所以批量生成是 O(n)。
# 之前每次都从 PORT_BASE 重新扫, 第 n 个节点要扫 n 次, O(n^2)。
#
# 参数兼容旧的 next_port <base> 形式: 传了 base 就先重置游标到那里。
next_port() {
    if [[ -n "${1:-}" ]]; then PORT_CURSOR=$(( $1 )); fi
    local p
    # ★ 性能: 原来是每轮 `grep -qx "$p" "$USED_PORTS_FILE"` ——
    #   **每个候选端口 fork 一次 grep**。区间长、或前面已用掉很多端口时,
    #   单次调用就要上百毫秒 (实测 80-120ms)。改成先把已用端口读进内存,
    #   用 bash 的字符串匹配判断 —— 只 fork 一次 tr。
    local used=""
    [[ -f "$USED_PORTS_FILE" ]] && used=" $(tr '\n' ' ' < "$USED_PORTS_FILE" 2>/dev/null) "
    while (( PORT_CURSOR <= PORT_RANGE_END )); do
        p=$PORT_CURSOR
        PORT_CURSOR=$(( p + 1 ))
        [[ "$used" == *" $p "* ]] && continue
        echo "$p" >> "$USED_PORTS_FILE"
        printf '%s' "$p"
        return 0
    done
    # 区间用完 —— 回落随机, 不直接失败 (对齐 SB)。
    # 只提示一次: 13 个协议会连着触发 13 次, 刷屏把结果表都冲掉了。
    # 注意 next_port 是在 $(...) 里被调用的, 那是子 shell —— 变量赋值传不回
    # 父进程 (实测 _RANGE_WARNED=1 设了也没用, 照样打 13 次)。用文件标记。
    local wf="${USED_PORTS_FILE}.warned"
    if [[ ! -f "$wf" ]]; then
        print_warn "端口区间 ${PORT_RANGE_START}-${PORT_RANGE_END} 已用完, 后续改用随机端口" >&2
        : > "$wf"
    fi
    random_free_port
}

next_index() {  # next_index <proto>
    # 同 count_indexed: 用 printf -v 而不是 $(printf ...), 每轮省一次 fork。
    # 这个函数原来就是 C 风格循环, 所以它一直很快 (53ms) ——
    # 两处写法的差异正是性能差距的来源, 保持一致。
    local proto="$1" i f
    for (( i = 1; i < 100; i++ )); do
        printf -v f '%s/%s-%02d.yaml' "$CONF_DIR" "$proto" "$i"
        [[ -f "$f" ]] || { printf '%02d' "$i"; return; }
    done
    printf '01'
}

# count_indexed <proto> —— 统计 <proto>-NN.yaml 已有多少个
#
# 不能写成 `ls "$CONF_DIR/$proto-"*.yaml`: proto=vless 时这个 glob 会把
# vless-ws-01.yaml / vless-wss-02.yaml 也数进去, 序号就会算错。
count_indexed() {
    # ★ 性能: 原来写的是
    #       for i in $(seq 1 99); do
    #           [[ -f "$(printf '%s/%s-%02d.yaml' "$CONF_DIR" "$proto" "$i")" ]] && n=$((n + 1))
    #       done
    #   `$(printf ...)` 每轮**fork 一个子 shell**, 99 轮 = 99 次 fork。
    #   实测: 这个函数 **1257ms**, 而做同样文件检查、
    #   只是改用 printf -v 的 next_index 只要 **53ms** —— 差 24 倍。
    #
    #   它的调用方是 gen(), 每个协议调一次, 而 all.sh 有 21 个协议:
    #       21 × 1.2s ≈ 25s
    #   于是 `--dry-run` 整跑 25 秒, 用户感受就是"面板卡住了"。
    #   一次性开销实测只有 792ms —— 慢**全**在这个函数上。
    #
    #   printf -v 是 bash 内建, 直接写进变量, 不 fork。
    local proto="$1" i n=0 f
    for (( i = 1; i < 100; i++ )); do
        printf -v f '%s/%s-%02d.yaml' "$CONF_DIR" "$proto" "$i"
        [[ -f "$f" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# =============================================================
# 前置: 环境变量 / Reality 密钥 / 证书
# =============================================================
ensure_env() {
    [[ -x "$MIHOMO_BIN" ]] || { print_error "未找到 mihomo 内核: $MIHOMO_BIN"; exit 1; }
    if [[ ! -f "$SRV_ENV" ]] || ! m_load_env "$SRV_ENV"; then
        print_info "首次运行, 生成环境变量..."
        bash "$SELF_DIR/XRevise.sh" >/dev/null 2>&1 || {
            print_error "环境变量生成失败"; exit 1; }
    fi
    m_load_env "$SRV_ENV"
    [[ -n "${UUID:-}" ]] || { print_error "缺少 UUID"; exit 1; }
}

ensure_reality() {
    if [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]]; then
        print_info "复用已有 Reality 密钥"; return 0
    fi
    print_info "生成 Reality 密钥对..."
    local out priv pub sid
    out=$("$MIHOMO_BIN" generate reality-keypair 2>/dev/null) || { print_error "密钥生成失败"; return 1; }
    priv=$(grep -i "private" <<<"$out" | head -1 | tr -d ' \r' | cut -d: -f2)
    pub=$(grep -i "public"  <<<"$out" | head -1 | tr -d ' \r' | cut -d: -f2)
    sid=$(grep -i "short"   <<<"$out" | head -1 | tr -d ' \r' | cut -d: -f2)
    [[ -n "$priv" && -n "$pub" ]] || { print_error "无法解析密钥"; return 1; }
    [[ -n "$sid" ]] || sid=$(openssl rand -hex 4)
    m_set_env "$SRV_ENV" PRIVATE_KEY "$priv"
    m_set_env "$SRV_ENV" PUBLIC_KEY  "$pub"
    m_set_env "$SRV_ENV" SHORT_ID    "$sid"
    PRIVATE_KEY="$priv"; PUBLIC_KEY="$pub"; SHORT_ID="$sid"
    print_ok "Reality 密钥已生成并保存"
}

# 证书目录里的命名相当杂:
#   cert-bing.com.crt            + cert-bing.com.key
#   cert-01-cert-x.com.crt       + cert-01-key-x.com.key
#   x.com_cert.pem               + x.com_key.pem
# 最坑的是 *_cert.pem 既是证书, 又因为带 .pem 很容易被当成 key 选进去,
# 结果内核报 "failed to find any PEM data in certificate input"。
# 所以这里**按文件内容**判断, 不靠文件名。
find_cert() {
    python3 - "$CERTS_DIR" <<'PYCERT' 2>/dev/null
import glob, hashlib, os, re, subprocess, sys

d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, "*.crt")) +
               glob.glob(os.path.join(d, "*.pem")) +
               glob.glob(os.path.join(d, "*.key")))

def head(p, n=400):
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read(n)
    except OSError:
        return ""

certs  = [f for f in files if "BEGIN CERTIFICATE" in head(f)]
keys   = [f for f in files if "PRIVATE KEY" in head(f)]
others = [f for f in files if f not in certs and f not in keys]

DOMAIN_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$")

def name_of(p):
    """文件名去壳 —— 只用来**配对** cert/key, 不作为域名。"""
    b = os.path.basename(p)
    b = re.sub(r"^cert-\d+-cert-", "", b)
    b = re.sub(r"^cert-", "", b)
    b = re.sub(r"_cert\.pem$", "", b)
    b = re.sub(r"_key\.pem$", "", b)
    b = re.sub(r"\.(crt|pem|key)$", "", b)
    return b.lower()

def cert_real_domain(p):
    """真域名 —— 打开证书读 SAN / CN。这是唯一可信的来源。"""
    for args in (["openssl", "x509", "-in", p, "-noout", "-ext", "subjectAltName"],
                 ["openssl", "x509", "-in", p, "-noout", "-subject"]):
        try:
            out = subprocess.run(args, capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        m = (re.search(r"DNS:([^,\s]+)", out) if "subjectAltName" in args[-1]
             else re.search(r"CN\s*=\s*([^,\n]+)", out))
        if m:
            dom = m.group(1).strip().strip('"').lower()
            # ★ 必须是真域名。CN 写成 "common name" / "localhost" 的自签证书
            #   会把这两个词原样吐出来, 写进客户端就成了伪 SNI。
            if DOMAIN_RE.match(dom):
                return dom
    return None

def domain_of(p):
    """配对不再用文件名, 但**报出来的域名必须是真域名**。

    旧实现直接 return 文件名, 于是 conf/certs 里是 fullchain.pem + privkey.pem
    这种通用命名时: 两者配不上 -> 走"第一张+第一把"兜底 -> 域名报成 "fullchain"。
    于是 CDN 客户端产物写成 `server: fullchain` (根本不是一个域名, 连不上),
    而合并/严格校验/内核三道关全绿, 面板照样显示"成功 19"。
    实测被污染的还有 6 个协议的客户端 sni 字段。
    """
    return cert_real_domain(p) or name_of(p)

def _run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""

def pub_of_cert(p):
    out = _run(["openssl", "x509", "-in", p, "-noout", "-pubkey"])
    return hashlib.sha256(out.encode()).hexdigest() if out.strip() else None

def pub_of_key(p):
    out = _run(["openssl", "pkey", "-in", p, "-pubout"])
    return hashlib.sha256(out.encode()).hexdigest() if out.strip() else None

def is_trusted(p):
    """CA 签发 (subject != issuer) —— 与 cert.sh 的 cert_is_trusted 同判据。"""
    subj = _run(["openssl", "x509", "-in", p, "-noout", "-subject"]).strip()
    iss  = _run(["openssl", "x509", "-in", p, "-noout", "-issuer"]).strip()
    subj = subj.split("=", 1)[1].strip() if "=" in subj else ""
    iss  = iss.split("=", 1)[1].strip() if "=" in iss else ""
    return bool(subj) and subj != iss

# ★ 配对按**公钥指纹**真比对 —— 不按文件名, 更不按位置。
#
#   原实现先按文件名配, 配不上就退回"第 0 张证书 + 第 0 把私钥"。实测在服务端
#   真实目录上, 按文件名配对 **0 命中** —— 也就是说那条兜底分支**每次都在走**。
#   它只看列表位置, 不看两者是否真是一对: 恰好配上就没事, 顺序一变就生成一个
#   cert/key 不匹配的节点 —— 监听起不来 (内核只会保留上一份有效证书),
#   而面板的合并/严格校验/mihomo -t 三道关**全绿**。
key_by_pub = {}
for k in keys:
    h = pub_of_key(k)
    if h:
        key_by_pub.setdefault(h, k)

matched = []
for c in certs:
    h = pub_of_cert(c)
    if h and h in key_by_pub:
        matched.append((c, key_by_pub[h]))

# 有真证书就优先用真证书。自签证书会让客户端必须 skip-cert-verify, 且 CDN 档位
# 直接不可用 —— 目录里同时存在"自签诱饵证书"和"真 LE 证书"时, 不能因为自签那张
# 文件名排在前面就把它选出来当默认。
trusted = [x for x in matched if is_trusted(x[0])]
pick = (trusted or matched)

if pick:
    c, k = pick[0]
    print(f"{c}\t{k}\t{domain_of(c)}")
    raise SystemExit

# 一张都配不上 -> 什么都**不输出** (调用方会退回 scan_certs 的扫描结果)。
# 绝不用"位置"硬凑一对出来 —— 凑错的那一对会一路绿到底, 只在客户端握手时炸。
sys.stderr.write(f"no matched pair: cert={len(certs)} key={len(keys)} other={len(others)}\n")
PYCERT
}

# =============================================================
# 生成器
# =============================================================
RESULTS=()

record() {  # record <协议> <端口> <状态> <说明>
    RESULTS+=("$1|$2|$3|$4")
}

# vmess-mkcp / vmess-mekya 列出但**默认不生成** (要 ALL_MKCP=1)。
# 放在这里是为了让 `--only vmess-mkcp` 能被点名单独生成, 而不必先改默认集。
ALL_GEN_IDS="reality reality-grpc reality-xhttp vmess-mkcp vmess-mekya cdn-v-ws cdn-v-grpc cdn-m-ws cdn-m-grpc cdn-t-ws cdn-t-grpc trojan trojan-grpc vmess-reality vmess-grpc trojan-tls vless-ws xhttp-tls xhttp-cdn hysteria2 tuicv5 anytls ss snell"

# --only 的 token 必须能对上真实标识符。原来的 want() 对不匹配的 token 静默
# 返回 false, 于是 `--only tuic` (真名 tuicv5) 会安静地什么都不生成,
# 汇总还显示"成功 2", 用户完全看不出来自己漏了一个协议。
check_only_tokens() {
    local t miss=()
    local IFS=,
    for t in $ONLY; do
        [[ -z "$t" ]] && continue
        [[ " $ALL_GEN_IDS " == *" $t "* ]] || miss+=("$t")
    done
    unset IFS
    if (( ${#miss[@]} )); then
        print_error "无法识别的协议标识: ${miss[*]}"
        print_error "可用: $ALL_GEN_IDS"
        return 1
    fi
}

want() {  # 是否选中该协议
    [[ -z "$ONLY" ]] && return 0
    [[ ",$ONLY," == *",$1,"* ]]
}

# gen <proto> <标签> <需要reality> <需要tls> [管理协议]
#
# 第 5 个参数是**管理协议名**, 决定这个节点能在哪个单协议面板里被删除。
#
# 为什么必须有它: 片段文件名和 listener 名是两套东西, 而各单协议脚本删除时
# 只会去找 "<管理协议>-NN.yaml"。早期这里只用 $proto 做文件名, 于是
#   片段 vless-ws-01.yaml → listener vless-wss-01
# VLESS.sh 删除时找的是 vless-01.yaml, 永远找不到 —— 面板**列得出、删不掉**,
# 报"编号不存在"。trojan-tls 同理。
#
# 修法不是改各协议脚本 (那 6 份都要动, 且会破坏它们自己的编号序列),
# 而是让 all.sh 用管理协议名做文件名, listener 名保持不变 —— 单协议脚本
# 于是既能列也能删。
gen() {
    local proto="$1" label="$2" need_reality="$3" need_tls="$4" mproto="${5:-$1}"
    shift 4
    [[ $# -gt 0 ]] && shift        # 吃掉可选的第 5 参数
    # ★ 函数名与**额外参数**必须分开存。
    #   原来这里是一句 local body="$*", 调用处写 "$body" —— 双引号让
    #   "g_cdn_tier vless ws" 整个被当成**一个命令名**去找, 于是报
    #   "g_cdn_tier vless ws: command not found"。
    #   函数名后跟参数 (参数化生成器) 一律失效, 只能写死零参函数。
    local bodyfn="${1:-$proto}"
    shift || true
    local -a bodyargs=("$@")

    if ! want "$proto"; then return; fi

    # ★ 开工前先问内核这个协议认不认。
    #   协议支持是**随内核版本变**的: snell 的 outbound 在 v1.19.24 上是
    #   "unsupport proxy type: snell", 到 v1.19.32 才支持。批量清单写死,
    #   于是每一步都报"成功", 22 个节点全生成完, 合并出的配置最后被内核
    #   整体拒绝 —— 摘要写"成功 22 · 失败 0"紧跟一行校验失败, 两句话互相矛盾。
    #   同一套脚本在 v1.19.32 的机器上跑就没事, 用户只会觉得"随机出错"。
    #   在这里跳过, 摘要会明确写"跳过 · 内核 v1.19.24 不支持 snell"。
    if ! m_kernel_supports "$mproto"; then
        local _kv; _kv=$("${MIHOMO_BIN:-/root/catmi/mihomo/mihomo}" -v 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
        record "$label" "-" "跳过" "内核 ${_kv:-本机} 不支持 $mproto (升级内核后可生成)"
        return
    fi

    # need_tls 语义: 0=不需要证书, 1=有证书即可, 2=必须是**真证书**
    # 档位 2 是给 CDN 用的: 自签证书在直连场景客户端 skip-cert-verify 就行,
    # 但过 CDN 时是 Cloudflare 去回源校验, 它不认自签 CA, 回源必然失败。
    # 症状是"CDN 侧全绿、客户端就是连不上", 极难排查 —— 所以在这里就拦住。
    # 注意: 判定必须放在外壳的**前置检查**里。gen 只有 成功(0)/失败(非0) 两种
    # 返回码, 没有"跳过"通道; 在生成器内部 return 0 会被记成成功, 留下一条
    # 内容缺失却显示通过的记录 (这个坑实际踩到过)。
    if [[ "$need_tls" != "0" && "$USE_TLS" == "0" ]]; then
        record "$label" "-" "跳过" "需要证书 (--no-tls)"; return
    fi
    if [[ "$need_tls" != "0" && -z "$CRT" ]]; then
        record "$label" "-" "跳过" "无可用证书"; return
    fi
    if [[ "$need_tls" == "2" ]] && ! cert_is_trusted "$CRT"; then
        record "$label" "-" "跳过" \
            "需要真证书: $(basename "$CRT") 是自签/自签发, Cloudflare 回源不认"
        return
    fi
    if [[ "$need_reality" == "1" && -z "${PUBLIC_KEY:-}" ]]; then
        record "$label" "-" "跳过" "无 Reality 密钥"; return
    fi

    # 幂等: 已存在的同名节点**一律不覆盖**, 本次接着往后排新序号。
    # 这与原有行为一致 (next_index 永远返回第一个空位), 只是现在明确讲出来,
    # 不然"我明明选了 Trojan, 为什么列表里多了一个 Trojan-02"没人说得清。
    # 编号按**管理协议**排, 而不是按 proto。all.sh 一次会生成多个 vless 变体
    # (ws / ws+tls / xhttp / xhttp+tls), 若各按 "vless-NN" 排号, 四个生成器
    # 会抢同一个空位互相覆盖; 按 mproto 排则它们共享一条序列, 各占一个号,
    # 互不冲突, 且都能被 VLESS.sh 列出和删除。
    #
    # --force (重建) 时先把这个 mproto 的旧节点挪进暂存区, 于是下面的
    # next_index 从 01 重新开始 —— 这就是"强制覆盖"的实现方式。
    force_wipe_mproto "$mproto"

    local n_exist; n_exist=$(count_indexed "$mproto")
    # --force 下这句必须闭嘴: 旧节点已经被 force_wipe_mproto 挪走了, 这里的
    # 计数只可能是**本次同一批里先跑完的变体**, 说"已有 N 个, 不覆盖已有配置"
    # 会让用户以为重建没生效。
    if [[ "$n_exist" != "0" && "$FORCE" != "1" ]]; then
        print_info "$label: 已有 $n_exist 个 $mproto 节点, 本次**追加**新序号 (不覆盖已有配置)"
    fi

    local idx port
    idx=$(next_index "$mproto")
    # 不传参数: 传了会把游标重置回 PORT_BASE, 区间设置就白设了
    port=$(next_port) || { record "$label" "-" "失败" "无可用端口"; return; }

    local in_file out_file
    in_file=$(printf '%s/%s-%s.yaml' "$CONF_DIR" "$mproto" "$idx")
    # out/ 里的客户端文件仍按 proto 命名 (文件名要能看出是哪种传输),
    # 但要带上管理协议前缀避免同名覆盖 —— 例如 WS 与 WSS 两个客户端文件
    # 都叫 vless_client-01.yaml 时后者会覆盖前者, 分享订阅就少一个节点。
    out_file=$(printf '%s/%s_%s_client-%s.yaml' "$OUT_DIR" "$mproto" "$proto" "$idx")

    if [[ "$DRY_RUN" == "1" ]]; then
        record "$label" "$port" "预览" "将写入 $(basename "$in_file")"
        return
    fi

    # 生成器失败**不中断整批** (脚本没有 set -e, 这里是显式的 if/else),
    # 但必须: ① 留下失败原因; ② 清掉自己写了一半的文件 ——
    # 半份 YAML 留在 config.d/ 里会让末尾 m_sync_reload 整体校验失败,
    # 于是"一个协议生成失败"变成"全部节点回滚" (原子性)。
    # 前提是 next_index 保证 in_file/out_file 本来不存在, 所以 rm 不会误伤旧配置。
    local logf why
    logf=$(mktemp)
    # 额外参数放在固定四参之后, 生成器按位置取: $1=序号 $2=端口
    # $3=源站片段 $4=客户端产物, 再往后才是调用方传的自定义参数。
    if "$bodyfn" "$idx" "$port" "$in_file" "$out_file" \
        ${bodyargs[@]+"${bodyargs[@]}"} 2>"$logf"; then
        # CDN 档位若没配回源域名, 生成的节点**连不上** (Cloudflare 找不到
        # 源站)。但结果表标"成功"、提示又在一百多行之前, 用户完全看不出来
        # 这批节点是废的。这里如实标成"待回源", 让它在表里就露出来。
        if [[ "$label" == CDN:* && -z "$CDN_DOMAIN" ]]; then
            record "$label" "$port" "待回源" "未设 CDN_DOMAIN, 需服务端面板 → CDN 回源 挂一次"
            return
        fi
        record "$label" "$port" "成功" ""
    else
        why=$(tail -2 "$logf" | awk 'NF && !seen[$0]++' | tr '\n' ' ' | cut -c1-100)
        rm -f "$in_file" "$out_file"
        record "$label" "$port" "失败" "${why:-生成器返回非 0}"
    fi
    rm -f "$logf"
}

# ---------- 各协议模板 ----------

# =============================================================
# xhttp 抗探测字段 —— **一份字符串同时喂两侧**
#
# listener 的 xhttp-config (listener/inbound/vless.go:42-47) 与
# proxy   的 xhttp-opts    (adapter/outbound/vless.go:99-104)
# 字段同名同义, 这里靠"只渲染一次"来保证逐字段一致 —— 手写两份迟早漂移。
#
# 铁律: x-padding-key / x-padding-header **只在 x-padding-obfs-mode: true
#       时才生效** (transport/xhttp/config.go:502-509), 且两侧必须一致,
#       否则客户端发的 padding 服务端解不开, 直接连不上。
# 放置位置枚举 queryInHeader/cookie/header/query/path/body/auto
#       (transport/xhttp/config.go:21-29)
# 生成方法 repeat-x / tokenish (transport/xhttp/xpadding.go:16-18)
# =============================================================
render_xhttp_pad() {
    XHTTP_PAD_FIELDS="      x-padding-bytes: \"$XHTTP_PAD_BYTES\""
    if [[ "$XHTTP_PAD_OBFS" == "1" ]]; then
        # 每个节点现场生成一份独立的 key/session/seq。
        # 同一把钥匙开所有节点 = 一个可关联特征, 批量生成时尤其明显。
        # base64(12 字节) 恰好 16 字符且无 '=' 填充, 再把 +/ 换成 URL 安全字符。
        local k sk qk
        k=$(openssl rand -base64 12 2>/dev/null | tr '+/' '-_')
        if [[ -z "$k" ]]; then
            # 拿不到 key 就退回 std 档 —— 半份配置带空 key 比不带更糟。
            # 两侧共用同一份渲染结果, 所以退回后依然是一致的。
            print_warn "生成 x-padding-key 失败, 本节点退回 std 档 (无 obfs padding)"
            return 0
        fi
        XHTTP_PAD_FIELDS="${XHTTP_PAD_FIELDS}
      x-padding-obfs-mode: true
      x-padding-key: \"$k\"
      x-padding-header: $XHTTP_PAD_HEADER
      x-padding-placement: $XHTTP_PAD_PLACEMENT
      x-padding-method: $XHTTP_PAD_METHOD"
        if [[ "$XHTTP_PAD" == "max" ]]; then
            sk=$(openssl rand -base64 12 2>/dev/null | tr '+/' '-_')
            qk=$(openssl rand -base64 12 2>/dev/null | tr '+/' '-_')
            XHTTP_PAD_FIELDS="${XHTTP_PAD_FIELDS}
      session-placement: header
      session-key: $sk
      seq-placement: header
      seq-key: $qk"
        fi
    fi
}

# 供生成器里的 heredoc 调用: 展开 REALITY 服务端块 (带正确的 6 空格缩进)
_m_reality_block() { # <dest> <私钥> <short-id>
    printf '    reality-config:\n      dest: %s:443\n      private-key: %s\n      short-id:\n        - %s\n      server-names:\n        - %s' \
        "$1" "$2" "$3" "$1"
}

# =============================================================
# 补齐的生成器 —— 把「已验证可用」的组合补进一键全协议
#
# 每个组合都经过真实内核实测验证, 并标出它为什么这么写。三条硬约束:
#
#   ① REALITY 预置绝不排 ws —— vless/vmess/trojan 的 REALITY+ws 实测全 0/5,
#      而 tcp/grpc/h2 都通过, 且对照组通过 (不是环境问题)。见 K-1。
#   ② 客户端 REALITY 的 SNI 字段名按协议不同:
#        vless / vmess -> servername
#        trojan        -> sni         ← 写错会静默退回普通 TLS 校验,
#                                       报出 x509 证书错误 (K-8)
#   ③ flow 只能写在 users[] 条目下, 不能写 listener 顶层 (K-9)。
# =============================================================

# gRPC 服务名: 两侧必须逐字符一致, 所以一个节点只生成一次。
# 加随机后缀是为了避免所有节点共用同一个服务名 —— 那是个可关联特征。
# 随机路径: 长度够 + 不可猜。短路径/固定路径正是被扫的特征。
m_gen_path() { # <前缀>
    local pre="${1:-p}" rnd
    rnd=$(openssl rand -hex 4 2>/dev/null) || rnd="00000000"
    printf '/%s-%s' "$pre" "$rnd"
}

m_gen_grpc_name() { # <前缀> <序号>
    local pre="${1:-gs}" idx="${2:-1}" rnd
    rnd=$(openssl rand -hex 3 2>/dev/null) || rnd="000000"
    printf '%s%s%s' "$pre" "$idx" "$rnd"
}

# ---------- VLESS + gRPC + REALITY (直连) ----------
# 实测 5/5。gRPC 跑在 HTTP/2 上, 形状像正常应用调用。
g_vless_grpc_reality() {
    local svc; svc=$(m_gen_grpc_name gs "$1")
    NODE_TAG="$(m_node_tag VLESS "$1" reality gRPC)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VLESS + gRPC + REALITY (直连)
# 实测可用。listener 侧只有 grpc-service-name, 没有 network 字段。
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
    grpc-service-name: $svc
$(_m_reality_block "$dest_server" "$PRIVATE_KEY" "$SHORT_ID")
EOF
    NODE_TAG="$(m_node_tag VLESS "$1" reality gRPC)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: vless
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    network: grpc
    tls: true
    udp: true
    servername: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP
    grpc-opts:
      grpc-service-name: $svc
EOF
}

# ---------- VLESS + xHTTP + REALITY (直连, M 内核独有) ----------
# 实测 5/5。xHTTP 伪装成普通 HTTP 接口调用。
g_vless_xhttp_reality() {
    local path; path=$(m_check_ws_path "$(m_gen_path xhr)") || return 1
    render_xhttp_pad
    NODE_TAG="$(m_node_tag VLESS "$1" reality XHTTP)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VLESS + xHTTP + REALITY (直连)
# 实测可用。listener 侧靠 xhttp-config 非空判定传输, 无 network 字段。
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
    xhttp-config:
      mode: $XHTTP_MODE
      path: $path
${XHTTP_PAD_FIELDS}
$(_m_reality_block "$dest_server" "$PRIVATE_KEY" "$SHORT_ID")
EOF
    NODE_TAG="$(m_node_tag VLESS "$1" reality XHTTP)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: vless
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    network: xhttp
    tls: true
    udp: true
    servername: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP
    xhttp-opts:
      mode: $XHTTP_MODE
      path: $path
${XHTTP_PAD_FIELDS}
EOF
}

# ---------- VLESS + xHTTP + TLS 过 CDN ----------
# 与上面「直连」版的区别: 客户端连的是 **Cloudflare 后面的域名**而不是源站 IP。
# 直连版靠 REALITY 免证书; 本版必须用**真证书** ——
# 自签证书会被 Cloudflare 回源校验拒绝 (CF 不认你的自签 CA)。
# =============================================================
# CDN 档位统一生成器 (2026-10-07 新增)
#
# 为什么用**一个参数化函数**而不是再抄 8 份 g_xxx_cdn():
#   这些档位的结构是完全一样的 —— 差别只有三处: 协议类型、传输、鉴权字段。
#   抄 8 份意味着以后改一处要改 8 处, 漏改的那份不会报错, 只会在用户配
#   CDN 时才暴露 (症状是"CDN 侧全绿、客户端连不上", 极难排查)。
#
# 调用: g_cdn_tier <协议> <传输>
#   协议: vless | vmess | trojan
#   传输: ws | grpc | xhttp
#   → 3 × 3 = 9 个 CDN 档位
#
# ★ 为什么只有这三个协议能走 CDN:
#   Cloudflare 橙云代理的是 **HTTP 流**。只有把协议包在 HTTP 承载里
#   (ws / gRPC / xHTTP) 才过得去。REALITY / AnyTLS / Hysteria2 / TUIC /
#   Shadowsocks / Snell 都是裸 TCP 或 UDP, Cloudflare 根本不会转发 ——
#   症状同样是"节点在订阅里, 但连不上"。
#   （sing-box 那边也是同样的结论: 它的 batch.sh 注释写着"只有
#    vless/vmess/trojan 有 Transport 字段, 其他协议给 CDN 也走不通",
#    3 协议 × ws/grpc = 6 个。我们多出 xHTTP 这一维, 所以是 9 个。）
#
# ★ 客户端 server 一律写 CDN 域名, 端口 443:
#   CDN 档位连的是**边缘**, 不是源站端口。写成源站端口是 CDN 档位最常见的
#   配置错误 —— 源站端口只在 listener 里用, 供后台配 Origin Rule。
# =============================================================
g_cdn_tier() {
    # 标准四参 ($1=序号 $2=端口 $3=源站片段 $4=客户端产物) 由 gen 统一传入,
    # 后面两个是调用方 (gen 那行) 追加的自定义参数。
    local _idx="$1" _port="$2" _in="$3" _out="$4" proto="${5:-}" tr="${6:-}"
    [[ -n "$proto" && -n "$tr" ]] || { print_error "g_cdn_tier 需要 <协议> <传输> 两个参数"; return 1; }
    local -A TNAME=( [ws]=WS [grpc]=gRPC [xhttp]=xHTTP )
    local -A PNAME=( [vless]=VLESS [vmess]=VMess [trojan]=Trojan )
    local tn="${TNAME[$tr]}" pn="${PNAME[$proto]}"
    local path svc=""

    # path 只对 ws / xhttp 有意义; gRPC 用 service-name, 不带斜杠。
    case "$tr" in
        ws)    path=$(m_check_ws_path "$(m_gen_path cdn$tr)") || return 1 ;;
        xhttp) path=$(m_check_ws_path "$(m_gen_path cdn$tr)") || return 1
               render_xhttp_pad ;;
        grpc)  svc=$(m_gen_grpc_name cg "$_idx") || return 1 ;;
    esac

    NODE_TAG="$(m_node_tag "$pn" "$_idx" cdn "$tn")"

    # ---- 鉴权字段: 三个协议唯一真正不同的地方 ----
    # VLESS   : uuid
    # VMess   : uuid + alterId + cipher (cipher 只在客户端侧)
    # Trojan  : password
    local auth=""
    # ⚠ 密码一律用 $UUID, 与既有 Trojan 生成器 (g_trojan_tls 等) 保持一致。
    #   这里原先写的是 $TROJAN_PASS —— 而全脚本**从来没有给这个变量赋过值**。
    #   set -u 下引用未定义变量会让**整个 shell 当场退出** (不是返回非零,
    #   而是不管不顾直接 die), 症状是 all.sh 跑到一半日志戛然而止、exit=1、
    #   一条错误信息都没有。只有 bash -x 追到最后一条命令才定位得到。
    case "$proto" in
        vmess)  auth="      - uuid: $UUID"$'\n'"        alterId: 0" ;;
        trojan) auth="      - password: \"$UUID\"" ;;
        *)      auth="      - uuid: $UUID" ;;
    esac

    # ---- 服务端: listener ----
    # 传输字段名同样按协议/传输分叉: listener 侧 ws 是 ws-path,
    # grpc 是 grpc-service-name, xhttp 是 xhttp-config 块。
    local trfield=""
    case "$tr" in
        ws)    trfield="    ws-path: $path" ;;
        grpc)  trfield="    grpc-service-name: $svc" ;;
        xhttp) trfield=$'    xhttp-config:\n      mode: '"$XHTTP_MODE"$'\n      path: '"$path"$'\n'"$XHTTP_PAD_FIELDS" ;;
    esac

    cat > "$3" <<EOF
# 由 all.sh 一键生成 · $pn + $tn + CDN (过 Cloudflare)
# ★ 这是**源站**: 由 Cloudflare 回源到它, 监听 0.0.0.0 且用真证书。
#   客户端连的是 CDN 边缘 (443), 不是这里的 $2 —— 本端口只用于配 Origin Rule。
# ⚠ 必须真证书: Cloudflare 回源时不认自签 CA, 用自签必然回源失败。
listeners:
  - name: $NODE_TAG
    type: $proto
    listen: "0.0.0.0"
    port: $2
    users:
$auth
$trfield
    certificate: $CRT
    private-key: $KEY
EOF

    # ---- 客户端: proxy ----
    local ctrfield="" cipherline=""
    case "$tr" in
        ws)    ctrfield=$'    ws-opts:\n      path: '"$path" ;;
        grpc)  ctrfield=$'    grpc-opts:\n      grpc-service-name: '"$svc" ;;
        xhttp) ctrfield=$'    xhttp-opts:\n      mode: '"$XHTTP_MODE"$'\n      path: '"$path"$'\n'"$XHTTP_PAD_FIELDS" ;;
    esac
    [[ "$proto" == "vmess" ]] && cipherline="    cipher: auto"

    # ECH 默认开。
    #
    # ★ 这里曾经因为"实测连不上"被关掉过 —— 结论是错的, 关错了地方。
    #   当时看到 7 个 CDN 节点全挂, 就认定 ECH 有问题, 于是默认关闭。
    #   实际根因不在 ECH, 也不在 nginx, 更不是协议不支持过 CDN:
    #   **客户端的 DNS 解析器问不到 HTTPS/SVCB 记录 (type 65)**,
    #   而 ECHConfig 正装在那条记录里。
    #
    #   证据链:
    #     路由器 DNS (192.168.1.1 / fe80::1)  查 type 65 → 0 字节
    #     1.1.1.1 / 223.5.5.5 (AliDNS)        查 type 65 → 有 ECHConfig
    #     mihomo 日志: [DNS] <域名> --> [] HTTPS   ← 空的, 静默失败
    #     同一批节点换成不带 #PROXY 的 DoH → ECH 立刻恢复
    #       mTrojan04-CDN-WS 1258ms / mVLESS04-CDN-WS 967ms
    #
    # nginx 完全无辜: ECH 加密的是 ClientHello, 只有 Cloudflare 边缘能解密;
    # Cloudflare 解密后用普通 TLS 回源, nginx 看到的就是常规 HTTPS。
    #
    # 真正的修法在客户端 (client.sh): 主解析的 DoH 不带 #PROXY。
    # 带 #PROXY 会形成循环依赖 —— 解析域名要先连代理, 而代理地址本身
    # 是域名又要解析, mihomo 遇到死锁不报错, 只是静默丢掉这条查询。
    local ech=""
    if [[ "${ALL_ECH:-1}" == "1" ]] && [[ "${CDN_ECH_ALL:-1}" == "1" ]] \
       && declare -F cdn_ech_ready >/dev/null 2>&1 && cdn_ech_ready "$SNI"; then
        ech=$'    ech-opts:\n      enable: true\n      query-server-name: '"$SNI"$'\n'
    fi

    NODE_TAG="$(m_node_tag "$pn" "$_idx" cdn "$tn")"
    cat > "$4" <<EOF
# ★ 客户端产物 · $pn + $tn + CDN
#   连的是 CDN 边缘: server=$SNI port=443。源站端口不在这里出现。
proxies:
  - name: $NODE_TAG
    type: $proto
    server: $SNI
    port: 443
    username: ""
$cipherline
EOF
    case "$proto" in
        vless)  echo "    uuid: $UUID" >> "$4" ;;
        vmess)  { echo "    uuid: $UUID"; echo "    alterId: 0"; } >> "$4" ;;
        trojan) { echo "    password: \"$UUID\""; } >> "$4" ;;
    esac
    cat >> "$4" <<EOF
    network: $tr
    tls: true
    udp: true
    servername: $SNI
    client-fingerprint: $CLIENT_FP
$ech$ctrfield
EOF
}

g_vless_xhttp_cdn() {
    [[ -n "$CRT" && -n "$KEY" && -n "$SNI" ]] || {
        record "VLESS+xHTTP+CDN" "-" "跳过" "需要证书 (--no-tls 或证书缺失)"
        return 0
    }
    local path; path=$(m_check_ws_path "$(m_gen_path xhc)") || return 1
    render_xhttp_pad

    # ---- ECH: 探测到就默认开 (2026-10-07) ----
    #
    # 为什么 CDN 档位默认开、而不是继续问一次:
    #   ECH 的全部意义就是"别让中间人看见你在连哪个域名"。而 CDN 档位的流量
    #   本来就要经过 Cloudflare —— 这是唯一一个开 ECH **零额外代价**的档位
    #   (不换 IP、不换端口、不多一跳), 不开等于白放着。
    #
    # 判据用 DNS (HTTPS RR 有没有 ech=), 不用 cf-manager:
    #   只要域名走橙云, Cloudflare 就自动下发 ECHConfig, 不需要 API。
    #   实测本项目的 CDN 域名直接就有 ech= (public_name=cloudflare-ech.com),
    #   而抓包证实开启后明文 SNI 只剩 cloudflare-ech.com, 真实域名消失。
    #
    # ALL_ECH=0 可关 (走 Cloudflare API 开过、或域名 ECH 探测有假阳性时)。
    # cdn_ech_ready 只证明"域名下发了 ECHConfig", 不证明"客户端拿得到"。
    # 两者不是一回事: 解析器不支持 type 65 就等于没下发 (根因见上面)。
    ECH_OPTS_FIELDS=""
    if [[ "${ALL_ECH:-1}" == "1" ]] && [[ "${CDN_ECH_ALL:-1}" == "1" ]] \
       && declare -F cdn_ech_ready >/dev/null 2>&1 \
       && cdn_ech_ready "$SNI"; then
        # 用 $'...' 而不是 "...": 后者里的 \n 是**字面两个字符**, 会被原样
        # 写进 YAML, 生成出 ech-opts:\n  这样的坏缩进。
        ECH_OPTS_FIELDS=$'    ech-opts:\n      enable: true\n      query-server-name: '"$SNI"$'\n'
        printf "     ${DIM}ECH: 已启用 (%s 下发了 ECHConfig, 明文 SNI 将变成 cloudflare-ech.com)${RESET}\n" "$SNI" >&2
    fi

    NODE_TAG="$(m_node_tag VLESS "$1" tls XHTTP CDN)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VLESS + xHTTP + TLS (过 Cloudflare CDN)
# 这是**源站**: 由 Cloudflare 回源到它, 所以监听 0.0.0.0 且用真证书。
# 建议在 Cloudflare 侧设置 Origin Rule 回源到本端口。
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
    xhttp-config:
      mode: $XHTTP_MODE
      path: $path
${XHTTP_PAD_FIELDS}
    certificate: $CRT
    private-key: $KEY
EOF
    NODE_TAG="$(m_node_tag VLESS "$1" tls XHTTP CDN)"
    cat > "$4" <<EOF
# ★ 这是**客户端**产物, 它连的是 CDN 边缘 (443), 不是你的源站。
#   你的源站监听在端口 $2 —— 必须去 CDN 后台把回源指向 本机IP:$2,
#   并把该域名的 DNS 记录改成走 CDN (橙云)。这一步做漏了, 节点必然连不上,
#   而客户端这边看不出任何异常。源站端口写在这里就是为了让它有据可查。
proxies:
  - name: $NODE_TAG
    type: vless
    server: $SNI
    port: 443
    uuid: $UUID
    network: xhttp
    tls: true
    udp: true
    servername: $SNI
    client-fingerprint: $CLIENT_FP
${ECH_OPTS_FIELDS}    xhttp-opts:
      mode: $XHTTP_MODE
      path: $path
${XHTTP_PAD_FIELDS}
EOF
}

# ---------- Trojan + gRPC + REALITY (直连) ----------
g_trojan_grpc_reality() {
    local svc; svc=$(m_gen_grpc_name tg "$1")
    NODE_TAG="$(m_node_tag Trojan "$1" reality gRPC)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · Trojan + gRPC + REALITY (直连)
listeners:
  - name: $NODE_TAG
    type: trojan
    listen: "0.0.0.0"
    port: $2
    users:
      - password: $UUID
    grpc-service-name: $svc
$(_m_reality_block "$dest_server" "$PRIVATE_KEY" "$SHORT_ID")
EOF
    NODE_TAG="$(m_node_tag Trojan "$1" reality gRPC)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    udp: true
    # ★ trojan 用 sni, 不是 servername —— 写成 servername 会**静默退回普通
    #   TLS 校验**, 然后报一个和 REALITY 毫无关系的 x509 证书错误 (K-8)。
    sni: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP
    network: grpc
    grpc-opts:
      grpc-service-name: $svc
EOF
}

# ---------- Trojan + HTTP/2 + REALITY: 不提供 ----------
# mihomo 的 trojan **出站**没有 h2 传输, 所以这个组合在本内核上不存在:
#   * TrojanOption 没有 HTTP2Opts 字段 (adapter/outbound/trojan.go:45-69)
#   * `switch t.option.Network` 只认 ws / grpc, 其余落到 default
#     -> `DialContext(ctx, "tcp", ...)` 裸 TCP (trojan.go:79 / :211-216)
#   * 全内核 `h2-opts` 只在 vless.go:79 与 vmess.go:80 定义
# 即客户端写 `network: h2` 会被**静默降级**成裸 TCP, 写 `h2-opts` 则被静默忽略。
# 二者都写, 产物就是一个"名字写着 H2、实际走 TCP"的节点, 且 `h2-opts` 会被
# validate.py 判为 trojan 的 ERROR —— 生成器不该产出自家校验器拒绝的东西。
# 参考实现 (sing-box) 的 trojan 支持 http 传输, 这是**内核差异**, 不是待补的功能。

# ---------- VMess + 裸 TCP + REALITY (直连) ----------
# ---- mkcp / mekya 档位 (2026-10-07 新增) ----
#
# 这两种传输内核早就支持 (二进制里有 mkcp-config / mekya-config / mkcp-opts /
# mekya-opts), 项目一直没有生成入口 —— 补上是纯增量。
#
# ⚠ 定位要说清楚, 别当主力档推荐:
#   * mkcp 是 mKCP 的改良, 自带伪装与抗重传, 但把 UDP 跑在 TCP 之上,
#     抗封锁能力弱于 REALITY, 且**不能过 Cloudflare**。
#   * mekya 更弱一档, 主要只在特定客户端生态里有意义。
#   日常主力仍然是 REALITY / xHTTP / gRPC。
#
# 参数取 mKCP 官方默认: mtu 1350, tti 50, up 50, down 200, congestion false
g_vmess_mkcp() {
    NODE_TAG="$(m_node_tag VMess "$1" tls KCP)"
    local mtu="${VMESS_KCP_MTU:-1350}" tti="${VMESS_KCP_TTI:-50}"
    local up="${VMESS_KCP_UP:-50}" down="${VMESS_KCP_DOWN:-200}"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VMess + mKCP (mKCP 跑在 TCP 之上, 自带抗重传/伪装)
listeners:
  - name: $NODE_TAG
    type: vmess
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
        alterId: 0
    mkcp-config:
      mtu: $mtu
      tti: $tti
      uplink-capacity: $up
      downlink-capacity: $down
      congestion: false
      read-buffer-size: 2
      write-buffer-size: 2
    certificate: $CRT
    private-key: $KEY
EOF
    NODE_TAG="$(m_node_tag VMess "$1" tls KCP)"
    cat > "$4" <<EOF
# 客户端产物 · VMess + mKCP
proxies:
  - name: $NODE_TAG
    type: vmess
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    alterId: 0
    cipher: auto
    network: mkcp
    tls: true
    udp: true
    servername: $SNI
    client-fingerprint: $CLIENT_FP
    mkcp-opts:
      mtu: $mtu
      tti: $tti
      uplink-capacity: $up
      downlink-capacity: $down
      congestion: false
EOF
}

g_vmess_mekya() {
    NODE_TAG="$(m_node_tag VMess "$1" tls MEKYA)"
    local up="${VMESS_MEKYA_UP:-50}" down="${VMESS_MEKYA_DOWN:-200}"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VMess + Mekya
listeners:
  - name: $NODE_TAG
    type: vmess
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
        alterId: 0
    mekya-config:
      up: "$up Mbps"
      down: "$down Mbps"
    certificate: $CRT
    private-key: $KEY
EOF
    NODE_TAG="$(m_node_tag VMess "$1" tls MEKYA)"
    cat > "$4" <<EOF
# 客户端产物 · VMess + Mekya
proxies:
  - name: $NODE_TAG
    type: vmess
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    alterId: 0
    cipher: auto
    network: mekya
    tls: true
    udp: true
    servername: $SNI
    client-fingerprint: $CLIENT_FP
    mekya-opts:
      up: "$up Mbps"
      down: "$down Mbps"
EOF
}

g_vmess_reality() {
    NODE_TAG="$(m_node_tag VMess "$1" reality)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VMess + TCP + REALITY (直连)
listeners:
  - name: $NODE_TAG
    type: vmess
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
        alterId: 0
$(_m_reality_block "$dest_server" "$PRIVATE_KEY" "$SHORT_ID")
EOF
    NODE_TAG="$(m_node_tag VMess "$1" reality)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: vmess
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    alterId: 0
    cipher: auto
    network: tcp
    tls: true
    udp: true
    servername: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP
EOF
}

# ---------- VMess + gRPC + REALITY (直连) ----------
g_vmess_grpc_reality() {
    local svc; svc=$(m_gen_grpc_name vg "$1")
    NODE_TAG="$(m_node_tag VMess "$1" reality gRPC)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VMess + gRPC + REALITY (直连)
listeners:
  - name: $NODE_TAG
    type: vmess
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
        alterId: 0
    grpc-service-name: $svc
$(_m_reality_block "$dest_server" "$PRIVATE_KEY" "$SHORT_ID")
EOF
    NODE_TAG="$(m_node_tag VMess "$1" reality gRPC)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: vmess
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    alterId: 0
    cipher: auto
    network: grpc
    tls: true
    udp: true
    servername: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP
    grpc-opts:
      grpc-service-name: $svc
EOF
}

g_reality() {
NODE_TAG="$(m_node_tag VLESS "$1" reality)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
        flow: xtls-rprx-vision
    # ★ listener 端是 reality-config + 私钥; reality-opts/public-key 是**客户端**用的
    reality-config:
      dest: ${dest_server}:443
      private-key: $PRIVATE_KEY
      short-id:
        - $SHORT_ID
      server-names:
        - $dest_server
EOF
NODE_TAG="$(m_node_tag VLESS "$1" reality)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: vless
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP
EOF
}

g_trojan_reality() {
NODE_TAG="$(m_node_tag Trojan "$1" reality)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: trojan
    listen: "0.0.0.0"
    port: $2
    users:
      - username: $UUID
        password: $UUID
    reality-config:
      dest: ${dest_server}:443
      private-key: $PRIVATE_KEY
      short-id:
        - $SHORT_ID
      server-names:
        - $dest_server
EOF
NODE_TAG="$(m_node_tag Trojan "$1" reality)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    udp: true
    sni: $dest_server
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP
EOF
}

g_trojan_tls() {
NODE_TAG="$(m_node_tag Trojan "$1" tls)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: trojan
    listen: "0.0.0.0"
    port: $2
    users:
      - username: $UUID
        password: $UUID
    certificate: $CRT
    private-key: $KEY
EOF
NODE_TAG="$(m_node_tag Trojan "$1" tls)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: trojan
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    udp: true
    sni: $SNI
    skip-cert-verify: $CERT_SKIP_VERIFY
EOF
}

g_vless_ws_tls() {
    local path="/wss$1"
NODE_TAG="$(m_node_tag VLESS "$1" tls WS)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
    ws-path: $path
    certificate: $CRT
    private-key: $KEY
EOF
NODE_TAG="$(m_node_tag VLESS "$1" tls WS)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: vless
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    network: ws
    tls: true
    udp: true
    skip-cert-verify: $CERT_SKIP_VERIFY
    servername: $SNI
    ws-opts:
      path: $path
EOF
}

# =============================================================
# VLESS + XHTTP
#
# 为什么明文 + 随机端口的 XHTTP **也能跑通** (逐条源码依据):
#   1. listener 侧 xhttp 只是一个挂在 httpServer 上的 HTTP handler;
#      整个 listener 对所有传输一视同仁地只做 listen(port) 再决定要不要套 TLS:
#      listener/sing_vless/server.go:257-278。**内核从不校验端口必须是 443。**
#   2. 套不套 TLS 由 security mode 决定; 明文 VLESS 只要显式 allow-insecure
#      就放行, 与 WS 完全同一条路径: server.go:275-277。
#   3. handler 的注册条件是 xhttp-config 的 path/host/mode 任一非空
#      (server.go:207-256), 明文同样注册, 并且明文 HTTP/2 (h2c) 也开了
#      (server.go:249)。
#   4. 客户端侧: tls:false 时 streamTLSConn 原样返回裸 conn
#      (adapter/outbound/vless.go:337), xhttp 走的是同一个包装函数
#      (vless.go:673-675), 所以明文 xhttp 端到端成立。
#   结论: 沿用本脚本既有的 "公网 IP + 随机端口" 写法即可, 不必强行 443。
#   ⚠️ 但要讲清代价: XHTTP 的价值在于"看起来就是普通 HTTP/1.1 站点",
#      跑在高位明文端口 + IP 直连时, 既没有 TLS 指纹也没有 CDN 前置,
#      抗探测收益远低于 443 + 域名 + 证书 + CDN。批量默认出**明文 + TLS 两个**,
#      真要上线请优先用 xhttp-tls 那个并配好域名。
# =============================================================
g_vless_xhttp_tls() {
    local path; path=$(m_check_ws_path "$(m_gen_path xhttps)") || return 1
    render_xhttp_pad
NODE_TAG="$(m_node_tag VLESS "$1" tls XHTTP)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VLESS + XHTTP + TLS
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
    xhttp-config:
      mode: $XHTTP_MODE
      path: $path
${XHTTP_PAD_FIELDS}
    certificate: $CRT
    private-key: $KEY
EOF
NODE_TAG="$(m_node_tag VLESS "$1" tls XHTTP)"
    cat > "$4" <<EOF
# 由 all.sh 一键生成 · VLESS + XHTTP + TLS 客户端
proxies:
  - name: $NODE_TAG
    type: vless
    server: $XHTTP_DIRECT_HOST
    port: $2
    uuid: $UUID
    network: xhttp
    tls: true
    udp: true
    skip-cert-verify: $CERT_SKIP_VERIFY
    servername: $SNI
    # uTLS ClientHello 伪装。XHTTP 把握手指纹做在 HTTP 握手层,
    # 这里给真实浏览器指纹才有意义 (明文 xhttp 用不上, 故明文那版不写)。
    client-fingerprint: $CLIENT_FP
    # xhttp-opts 与 listener 的 xhttp-config **逐字段一致** (同一份字符串渲染)
    xhttp-opts:
      mode: $XHTTP_MODE
      path: $path
${XHTTP_PAD_FIELDS}
EOF
}

# =============================================================
# VMess: global-padding / authenticated-length
#
# 结论: **只写客户端 (proxy) 一侧**, listener 侧写不了也不该写 ——
#   字段定义只在 adapter/outbound/vmess.go:86-87;
#   listener 的 VmessOption (listener/inbound/vmess.go:12-30) 根本没有这两个字段,
#   写上去内核会静默忽略 (common/structure 只对"缺无 omitempty 的字段"报错,
#   多写的键一律不报, docs/PROTOCOL-OPTIONS-SPEC.md §3.3)。
#   所以它们纯粹是**客户端出站行为**, 作用在加密流上, 与本脚本写的监听端无关。
#
# ⚠️ 对端警告 (必须让用户知道):
#   这是客户端行为, **对端也需支持, 否则可能握手失败**。
#   实现在外部库 sing-vmess, 本机源码里只有两个 ClientWith* 入口
#   (adapter/outbound/vmess.go:478-483), 对端解码逻辑查不到。
#   本项目生成的节点两端都是 mihomo, 所以默认开 (VMESS_PAD=1);
#   若要把 out/ 里的客户端配置喂给非 mihomo 客户端, 请 VMESS_PAD=0 重新生成。
#
# alterId 保持 0: mihomo 内核既无废弃标记也无拒绝逻辑, 纯透传
# (adapter/outbound/vmess.go:59), 0 是唯一安全值。
#   ⚠️ alterId 与 cipher 的 tag 都**没有** omitempty, 少写会被内核硬报
#   "has unset fields: alterId" —— 这两个必须留在 proxy 侧 (spec §0.7)。
# =============================================================
vmess_pad_client_block() {
    if [[ "$VMESS_PAD" == "1" ]]; then
        VMESS_PAD_BLOCK="    # ↓ 客户端行为: 对端也需支持, 否则可能握手失败 (见上方注释)
    global-padding: true
    authenticated-length: true"
    else
        VMESS_PAD_BLOCK="    # VMESS_PAD=0: 本次未开 global-padding / authenticated-length"
    fi
}

g_hysteria2() {
NODE_TAG="$(m_node_tag Hysteria2 "$1" tls)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: hysteria2
    listen: "0.0.0.0"
    port: $2
    users:
      user1: $UUID
    certificate: $CRT
    private-key: $KEY
    masquerade: https://www.bing.com
EOF
NODE_TAG="$(m_node_tag Hysteria2 "$1" tls)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: hysteria2
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    sni: $SNI
    skip-cert-verify: $CERT_SKIP_VERIFY
    up: "30"
    down: "200"
EOF
}

g_tuicv5() {
NODE_TAG="$(m_node_tag TUIC "$1" tls)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: tuic
    listen: "0.0.0.0"
    port: $2
    users:
      $UUID: $UUID
    certificate: $CRT
    private-key: $KEY
    congestion-controller: bbr
    max-idle-time: 15000
    alpn:
      - h3
EOF
NODE_TAG="$(m_node_tag TUIC "$1" tls)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: tuic
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    password: $UUID
    sni: $SNI
    skip-cert-verify: $CERT_SKIP_VERIFY
    alpn:
      - h3
    congestion-controller: bbr
EOF
}

g_anytls() {
NODE_TAG="$(m_node_tag AnyTLS "$1" tls)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: anytls
    listen: "0.0.0.0"
    port: $2
    users:
      $UUID: $UUID
    certificate: $CRT
    private-key: $KEY
EOF
NODE_TAG="$(m_node_tag AnyTLS "$1" tls)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: anytls
    server: $PUBLIC_IP
    port: $2
    password: $UUID
    sni: $SNI
    skip-cert-verify: $CERT_SKIP_VERIFY
    udp: true
    client-fingerprint: $CLIENT_FP
EOF
}

g_shadowsocks() {
NODE_TAG="$(m_node_tag Shadowsocks "$1" plain)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: shadowsocks
    listen: "0.0.0.0"
    port: $2
    cipher: aes-128-gcm
    password: $UUID
    udp: true
EOF
NODE_TAG="$(m_node_tag Shadowsocks "$1" plain)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: ss
    server: $PUBLIC_IP
    port: $2
    cipher: aes-128-gcm
    password: $UUID
    udp: true
EOF
}

g_snell() {
NODE_TAG="$(m_node_tag Snell "$1" plain)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: snell
    listen: "0.0.0.0"
    port: $2
    psk: $UUID
    version: "3"
EOF
NODE_TAG="$(m_node_tag Snell "$1" plain)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: snell
    server: $PUBLIC_IP
    port: $2
    psk: $UUID
    version: "3"
EOF
}

# =============================================================
# 主流程
# =============================================================
PORT_BASE="${ALL_PORT_BASE:-20000}"

printf "${MAGENTA}${BOLD}╔══════════════════════════════════════════════╗\n"
printf "║  一键生成全协议节点                              ║\n"
printf "╚══════════════════════════════════════════════╝${RESET}\n"
# 先把"将要问什么"讲清楚 —— 对齐 SB batch.sh 的做法:
#     echo -e "${CYAN}交互项: 对外地址 → 证书方案 → 端口范围 → CDN → 服务器标识.${RESET}"
# 用户最怕的是"不知道还要问几项、不知道什么时候结束"。先给全貌, 再逐项问。
printf "  ${CYAN}将要问的: 证书 → 对外地址 → 端口区间${RESET}\n" >&2
printf "  ${DIM}其余沿用各协议默认值; 端口冲突或生成失败会自动清理, 收尾统一校验 + 热重载${RESET}\n" >&2

# 所有函数已定义后再校验 --only, 否则 bash 会在定义前调用
check_only_tokens || exit 1
ensure_env
ensure_reality
# 不再把输出丢进 /dev/null: 那样一旦 m_pick_dest 真的问起来 (dest 空/非法时),
# 提示被吞掉而 read 仍然阻塞 —— 脚本看着像卡死, 随手一按就改掉了 dest_server。
# 已配置时 m_pick_dest 只打印一行"沿用 install_info.env", 不会吵。
m_pick_dest "${dest_server:-}" || true
# 兜底值取**实测可用**的域名。老代码这里写的是 www.bing.com, 而实测它在
# REALITY 下必然 authentication failed (普通 TLS 却是通的) —— 也就是说,
# 不手动选 dest 的用户 100% 拿到一个连不上、却显示成功的 REALITY 节点。
[[ -n "${dest_server:-}" ]] || dest_server="www.microsoft.com"

# 批量生成前对 dest 做一次防呆。批量的特点是"一次生成一堆", 一旦 dest 是坏的,
# 同批所有 REALITY 变体 (本脚本有 8 个) 会**整批**失败, 而且失败得很安静。
# M_REALITY_SKIP_PROBE=1 可跳过 (给确定 dest 可用的自动化场景省 5 秒)。
m_reality_dest_check "${dest_server:-}" 2>/dev/null || true

# ---------- ① 证书 ----------
#
# 呈现对齐 SB: 用 ①②③ 标步骤, 每步**说清这一问是干什么的**, 并直接给出结论
# (✅ 用什么 / — 没有), 而不是把"没有证书"打成 [Warn] 让人以为出错了。
# "没有证书"是**正常状态**, 它的后果是"跳过一部分协议", 不是失败。
printf '\n' >&2
printf "  ${BOLD}① 证书${RESET} ${DIM}—— 需要 TLS 的协议用它${RESET}\n" >&2

CRT=""; KEY=""; SNI=""
if [[ "$USE_TLS" == "0" ]]; then
    printf "     ${DIM}--no-tls: 只生成不需要证书的协议${RESET}\n" >&2
    printf "     ${GREEN}[OK]${RESET} 证书: 不使用 ${DIM}(按 --no-tls 要求)${RESET}\n" >&2
else
    # 这里已经在函数外, 写 local 会报 "can only be used in a function"
    #
    # 先数一遍本机可用证书。scan_certs 搜 8 处 (本项目 conf/certs / nginx /
    # letsencrypt / acme.sh / cloudflare / docker nginx 挂载点 ...)。
    # 注意: 不能写 local (此处不在函数内)。
    ALL_CERT_N=0
    if declare -F scan_certs >/dev/null 2>&1; then
        scan_certs >/dev/null 2>&1 && ALL_CERT_N=${#FOUND_CERTS[@]}
    fi
    pair=$(find_cert)
    # find_cert 只搜 $CERTS_DIR **一个**目录, 而证书常躺在别处 —— 实测服务端
    # 就是这样: 真证书在 nginx 的 certs 目录, conf/certs 是空的, 于是 7 个
    # TLS 协议被**整批跳过**, 面板却显示"本机没有可用证书"。
    # 所以 find_cert 空时退回 scan_certs 的结果 (它已按优先级排好)。
    # 只扩大搜索范围、不缩小, 因此不会把原本能找到的证书弄丢。
    if [[ -z "$pair" ]] && (( ALL_CERT_N > 0 )); then
        __ce="${FOUND_CERTS[0]}"
        __cc="${__ce%%|*}"; __cr="${__ce#*|}"; __ck="${__cr%%|*}"
        pair="${__cc}"$'\t'"${__ck}"$'\t'"$(cert_extract_domain "$__cc" 2>/dev/null)"
    fi
    if [[ -n "$pair" ]]; then
        IFS=$'\t' read -r CRT KEY SNI <<<"$pair"
        # ★ 证书域名必须是**真域名**。find_cert 已经会读 SAN/CN 了, 但证书本身
        #   可能是 CN 乱写的自签 (localhost / common name), 或者 openssl 完全
        #   读不出来 —— 这时 SNI 会是空串或一个不像域名的残值。
        #   空 SNI 会被下面的 TLS 档位拦住, 但**不像域名**的残值会一路写进
        #   客户端产物 (server: / sni:), 症状是节点永远连不上而面板全绿。
        #   这里一次性堵死: 不像域名就当作"没有可用域名"。
        if ! [[ "$SNI" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then
            printf "     ${YELLOW}—${RESET} 证书 %s 里没有可用的域名 (CN/SAN 不像域名), CDN 档位将跳过\n" \
                   "$(basename "${CRT:-未知}")" >&2
            SNI=""
        fi
    fi
    [[ -n "$CRT" && -f "$CRT" && -n "$KEY" && -f "$KEY" ]] || { CRT=""; KEY=""; SNI=""; }

    if [[ -n "$CRT" ]]; then
        # 把"本机到底有几张可用证书"这个事实直接摆出来 —— 用户一眼知道有多少
        # 备选, 而不是进去之后才发现只有一张。
        #
        # 措辞注意: ALL_CERT_N 来自 scan_certs (全盘 8 处), 而选中的这张可能来自
        # find_cert (只搜 conf/certs)。两者口径不同时, 说"N 张…已自动选优先级
        # 最高的这张"会让用户对不上账 (明明选了 A, 却被告知有 4 张 B)。
        # 所以只陈述"检测到 N 张可用", 不暗示选中项出自这 N 张。
        printf "     ${GREEN}✅${RESET} %s ${DIM}(域名 %s)${RESET}\n" "$(basename "$CRT")" "$SNI" >&2
        if (( ALL_CERT_N > 1 )); then
            printf "     ${DIM}本机共检测到 %d 张可用证书, 已自动选用其中优先级最高的${RESET}\n" "$ALL_CERT_N" >&2
        fi
        printf "     ${GREEN}[OK]${RESET} 证书: %s\n" "${SNI:-$CRT}" >&2

        # ★ 有真证书时也把"自签"这条路摆出来 —— 对齐 SB 的
        #   「1) 使用本机真实证书 (检测到 N 张) / 2) 自签证书」二选一。
        #
        #   为什么有真证书还要给自签选项: 真证书的域名是 CA 签给**那个域名**的,
        #   节点 SNI 就被钉死在它上面; 想换一个更"像正常网站"的 SNI 做伪装,
        #   只能自签。我们之前只有"没证书时才回退自签", 于是"有证书但想换 SNI"
        #   的用户没有任何入口。
        #
        #   默认选 1 (真证书): 它过 CDN 有效、客户端不用 skip-cert-verify,
        #   是更安全的一侧 —— 不能因为"多问一句"就把默认行为改坏。
        __want_self=0
        case "$CERT_MODE" in
            self) __want_self=1 ;;
            real) ;;                    # 明确要求只用真证书, 不问
            auto)
                if [[ -t 0 && "$QUICK" != "1" ]]; then
                    # 多张证书时**列出来让用户按域名挑**, 而不是只报一个总数。
                    # 只给"检测到 N 张, 已自动选用优先级最高的"时, 用户没有
                    # 任何入口换一张 —— 而同一台机器上哪张该用, nginx 站点的
                    # server_name 就是答案 (做法对齐 SB)。
                    if (( ALL_CERT_N > 1 )); then
                        # 按**域名**去重, 不按路径。
                        # 同一张证书在磁盘上通常有多份 (acme.sh 的 x.pem、cloudflare
                        # 的源站证书、nginx/certs 下的副本), 路径确实不同, 所以按
                        # 路径去重没用 —— 用户看到同一个域名连着出现 4 次, 编号还
                        # 和预期对不上, 很容易选错 (SB 的 sb_dedup_certs_by_domain
                        # 处理的正是这个)。保留第一份: scan_certs 的扫描顺序里
                        # 先扫到的通常正是现有 nginx 站点在用的那张。
                        __ucerts=(); declare -A __seen_dom=()
                        for __ce in "${FOUND_CERTS[@]}"; do
                            __cdom="$(cert_extract_domain "${__ce%%|*}" 2>/dev/null)"
                            # 抽不出真域名的 (自签 CN 写成 "common name" 之类) 不列,
                            # 选它必然连不上, 列出来只是干扰。
                            [[ "$__cdom" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]] || continue
                            [[ -n "${__seen_dom[$__cdom]:-}" ]] && continue
                            __seen_dom[$__cdom]=1
                            __ucerts+=("$__ce")
                        done
                        __sites_n=0
                        declare -a __dsites=()
                        while read -r __s; do [[ -n "$__s" ]] && __dsites+=("$__s"); done < <(m_nginx_domains 2>/dev/null)
                        __sites_n=${#__dsites[@]}
                        # ⚠ 标题里的张数必须用**去重之后**的个数, 且要在去重之后才打印。
                        #   先打印再去重会让标题写 9 张、下面只列 3 个; 自签那项再按
                        #   去重前的 ALL_CERT_N 编号, 于是和第 3 张重号 —— 用户按 3
                        #   拿到的到底是证书还是自签, 取决于列表长度。
                        printf "     ${CYAN}用哪张证书?${RESET} ${DIM}按域名去重后 %d 张${RESET}\n" "${#__ucerts[@]}" >&2
                        (( __sites_n > 0 )) && printf "     ${DIM}(检测到 %d 个 nginx 站点域名)${RESET}\n" "$__sites_n" >&2
                        __ci=1
                        for __ce in "${__ucerts[@]}"; do
                            __cdom="$(cert_extract_domain "${__ce%%|*}" 2>/dev/null)"
                            __mark=""; (( __sites_n > 0 )) && m_domain_in_nginx_site "$__cdom" && __mark="  ${GREEN}← nginx 站点在用${RESET}"
                            printf "       ${CYAN}%d${RESET}) %-40s%s\n" "$__ci" "${__cdom:-?}" "$__mark" >&2
                            __ci=$((__ci+1))
                        done
                        __self_no=$(( ${#__ucerts[@]} + 1 ))
                        printf "       %s%d${RESET}) 现生成自签 ${DIM}(可自定义域名; 客户端需 skip-cert-verify; 过 CDN 无效)${RESET}\n" \
                            "$CYAN" "$__self_no" >&2
                        printf "     选哪张 (回车 = 1):${RESET} " >&2
                        __ans=""; read -r __ans || true
                        __ans="$(clean_input "${__ans:-1}")"
                        if [[ "$__ans" =~ ^[0-9]+$ ]] && (( __ans >= 1 && __ans < ${#__ucerts[@]} )); then
                            __ce="${__ucerts[$((__ans-1))]}"
                            __cc="${__ce%%|*}"; __cr="${__ce#*|}"; __ck="${__cr%%|*}"
                            CRT="$__cc"; KEY="$__ck"; SNI="$(cert_extract_domain "$__cc" 2>/dev/null)"
                            CERT_IS_SELF=0
                            printf "     ${GREEN}[OK]${RESET} 证书: %s\n" "${SNI:-$CRT}" >&2
                        elif [[ "$__ans" == "$__self_no" ]]; then
                            __want_self=1
                        fi
                    else
                        printf "     ${CYAN}用哪张证书?${RESET}\n" >&2
                        printf "       ${CYAN}1${RESET}) 本机真实证书 ${DIM}%s${RESET} ${GREEN}(推荐)${RESET}\n" "${SNI:-$CRT}" >&2
                        printf "       ${CYAN}2${RESET}) 现生成自签 ${DIM}(可自定义域名; 客户端需 skip-cert-verify; 过 CDN 无效)${RESET}\n" >&2
                        printf "     请选择 ${DIM}[默认 1]:${RESET} " >&2
                        __ans=""; read -r __ans || true
                        [[ "$__ans" == "2" ]] && __want_self=1
                        CERT_IS_SELF=0
                    fi
                fi ;;
        esac
        if (( __want_self )); then
            CERT_IS_SELF=1
            printf "     ${DIM}自签域名 (回车=随机伪装域名):${RESET} " >&2
            __dom=""; read -r __dom || true
            [[ -z "$__dom" ]] && __dom=$(random_domain)
            if generate_cert "$__dom" >/dev/null 2>&1; then
                CRT="$CERT_FILE"; KEY="$KEY_FILE"; SNI="$CERT_DOMAIN"
                printf "     ${GREEN}✅${RESET} 已改用自签证书 ${DIM}(域名 %s)${RESET}\n" "$SNI" >&2
                printf "     ${DIM}客户端已写 skip-cert-verify; CDN 档位仍会跳过 (CF 不认自签)${RESET}\n" >&2
                printf "     ${GREEN}[OK]${RESET} 证书: %s ${DIM}(自签)${RESET}\n" "$SNI" >&2
            else
                # 自签失败**不能**把已经找到的真证书丢掉 —— 那等于把用户
                # 从"能用"推回"跳过一半协议"。留着真证书继续。
                printf "     ${RED}✗${RESET} 自签生成失败, 继续用本机真实证书 %s\n" "${SNI:-$CRT}" >&2
                printf "     ${GREEN}[OK]${RESET} 证书: %s\n" "${SNI:-$CRT}" >&2
            fi
        fi
    else
        # 没找到可用证书。
        #
        # 旧行为是直接跳过所有需要 TLS 的协议, 于是 6 个协议
        # (Trojan+TLS / VLESS+WS+TLS / XHTTP+TLS / Hysteria2 / TUIC / AnyTLS)
        # 整批记"跳过" —— 用户点了"全协议", 拿到的却是残缺的一套。
        # 这里补一条自签出路, 让"全协议"真的是全协议。
        #
        # 自签的代价必须当场说清, 不能等用户发现连不上才知道:
        #   * 客户端要 skip-cert-verify —— 6 个 TLS 生成器已经都写了这一行
        #   * **过 CDN 必然失败** —— Cloudflare 回源校验不认自签 CA。
        #     所以 CDN 档位照旧跳过 (need_tls=2 的硬拦不动, 这是刻意的)
        __want_self=0
        case "$CERT_MODE" in
            self) __want_self=1 ;;
            auto)
                if [[ -t 0 && "$QUICK" != "1" ]]; then
                    printf "     ${YELLOW}—${RESET} 本机没有可用证书\n" >&2
                    printf "     ${DIM}不生成的话, 需要证书的协议会被跳过:${RESET}\n" >&2
                    printf "     ${DIM}Hysteria2 / TUIC / AnyTLS / Trojan+TLS / VLESS+WS+TLS / XHTTP+TLS${RESET}\n" >&2
                    printf "     ${CYAN}生成自签证书?${RESET} ${DIM}(客户端用 skip-cert-verify 跳过校验; 过 CDN 无效) [Y/n]: ${RESET}" >&2
                    __ans=""; read -r __ans || true
                    [[ -z "$__ans" || "$__ans" =~ ^[Yy] ]] && __want_self=1
                fi ;;
        esac
        if (( __want_self )); then
            if generate_cert "$(random_domain)" >/dev/null 2>&1; then
                CRT="$CERT_FILE"; KEY="$KEY_FILE"; SNI="$CERT_DOMAIN"
                printf "     ${GREEN}✅${RESET} 已生成自签证书 %s ${DIM}(域名 %s)${RESET}\n" \
                    "$(basename "$CRT")" "$SNI" >&2
                printf "     ${DIM}客户端已写 skip-cert-verify; CDN 档位仍会跳过 (CF 不认自签)${RESET}\n" >&2
                printf "     ${GREEN}[OK]${RESET} 证书: %s ${DIM}(自签)${RESET}\n" "$SNI" >&2
            else
                printf "     ${RED}✗${RESET} 自签证书生成失败, 按无证书处理\n" >&2
                printf "     ${GREEN}[OK]${RESET} 证书: 无 ${DIM}(将跳过需要证书的协议)${RESET}\n" >&2
            fi
        else
            printf "     ${YELLOW}—${RESET} 本机没有可用证书\n" >&2
            printf "     ${DIM}需要证书的协议 (Hysteria2 / TUIC / AnyTLS / Trojan+TLS / VLESS+WS+TLS 等)${RESET}\n" >&2
            printf "     ${DIM}会被跳过, 其余照常生成 —— 这不是错误${RESET}\n" >&2
            printf "     ${DIM}想让它们也生成: 加 --self-sign (或 ALL_CERT_MODE=self) 生成自签证书${RESET}\n" >&2
            printf "     ${GREEN}[OK]${RESET} 证书: 无 ${DIM}(将跳过需要证书的协议)${RESET}\n" >&2
        fi
    fi
fi

# ---------- 证书落位检查: 必须在**选完证书之后** ----------
#
# ★ 位置是关键。原来的防护跑在选证书**之前**, 而交互式选证书菜单里
#   `CRT="$__cc"` 会把它重新赋成扫描到的原始路径 —— 防护刚做完就被覆盖,
#   等于没做。实测在生产机上: 13 个 TLS 节点全部绑不上, 面板却报"成功"。
#
# mihomo 的 SAFE_PATHS 只允许读 -d 工作目录内的证书:
#     Listener mVLESS02-TLS-XHTTP listen err: parse certificate failed ...
#     path is not subpath of home directory or SAFE_PATHS:
#     /etc/letsencrypt/live/<域名>/fullchain.pem
#     allowed paths: [/root/catmi/mihomo/conf]
# 致命之处是 `mihomo -t` **照样通过** —— 它只验语法, bind 失败只进日志。
#
# ★ 这里现在分两步, 而且**第一步与证书在哪无关**:
#     1) 配对校验 —— 不管证书在不在配置目录里都要做
#     2) 落位     —— 只有在配置目录外才需要复制
#   原来两步被 `! cert_path_in_confdir "$CRT"` 一起跳过了: 只要 CRT 已经在
#   conf/certs 内 (批量路径的常态 —— find_cert 就是从那儿找的), 配对**完全不验**。
#   而 find_cert 曾经用"第 0 张证书 + 第 0 把私钥"的位置兜底, 配错也没人拦,
#   一直到客户端握手才炸。已在配置目录里的副本同样可能是坏的。
if [[ -n "${CRT:-}" ]] && declare -F cert_key_match >/dev/null 2>&1; then
    if ! cert_key_match "$CRT" "$KEY"; then
        printf "     ${RED}✗${RESET} 证书与私钥不配对: %s <-> %s\n" \
               "$(basename "$CRT")" "$(basename "${KEY:-<未提供>}")" >&2
        printf "     ${DIM}配不上的证书写进配置, 节点监听起不来而校验全绿 —— 按无证书处理${RESET}\n" >&2
        CRT=""; KEY=""; SNI=""
    elif declare -F cert_ensure_safe_path >/dev/null 2>&1 && \
         declare -F cert_path_in_confdir >/dev/null 2>&1 && \
         ! cert_path_in_confdir "$CRT"; then
        if cert_ensure_safe_path "$CRT" "$KEY"; then
            [[ -n "${CERT_FILE:-}" && -f "$CERT_FILE" ]] && CRT="$CERT_FILE"
            [[ -n "${KEY_FILE:-}" && -f "$KEY_FILE" ]] && KEY="$KEY_FILE"
        else
            printf "     ${RED}✗${RESET} 证书无法复制进配置目录, 需要证书的协议将跳过\n" >&2
            CRT=""; KEY=""; SNI=""
        fi
    fi
elif [[ -n "${CRT:-}" ]] && declare -F cert_ensure_safe_path >/dev/null 2>&1 && \
     declare -F cert_path_in_confdir >/dev/null 2>&1 && \
     ! cert_path_in_confdir "$CRT"; then
    # 兜底: 老版本被单独 source 时没有 cert_key_match, 仍按原逻辑复制
    if cert_ensure_safe_path "$CRT" "$KEY"; then
        [[ -n "${CERT_FILE:-}" && -f "$CERT_FILE" ]] && CRT="$CERT_FILE"
        [[ -n "${KEY_FILE:-}" && -f "$KEY_FILE" ]] && KEY="$KEY_FILE"
    else
        printf "     ${RED}✗${RESET} 证书无法复制进配置目录, 需要证书的协议将跳过\n" >&2
        CRT=""; KEY=""; SNI=""
    fi
fi

# 证书是不是自签, **以证书内容为准**, 不靠"用户走了哪条路"推断。
#
# 原来 CERT_IS_SELF 只在交互式选证书分支里赋值。而自动选择 (find_cert) 与
# `--quick` 根本不进那个分支 —— CERT_IS_SELF 保持未赋值, 默认按"可信"处理,
# 于是自签证书也会写 skip-cert-verify=false, 客户端直接拒绝连接。
if [[ -n "${CRT:-}" ]] && declare -F cert_is_trusted >/dev/null 2>&1; then
    if cert_is_trusted "$CRT"; then CERT_IS_SELF=0; else CERT_IS_SELF=1; fi
fi

# 证书来自外部续期 (LE / 符号链接) 时, 顺带确认自动同步在位。
# 幂等且自带判据 (本机没有 LE 证书时什么都不做)。
if [[ -n "${CRT:-}" ]] && declare -F cert_sync_ensure_timer >/dev/null 2>&1; then
    cert_sync_ensure_timer
fi

# 客户端是否跳过证书校验: **只有自签证书才需要**。
#
# 原来 6 个 TLS 模板里写死了 `skip-cert-verify: true`, 不管证书可不可信 ——
# 于是拿到一张有效的 Let's Encrypt 证书时, 客户端仍然不校验, 等于放弃了
# TLS 一半的意义: 中间人可以拿一张自己签的证书冒充服务端, 客户端照单全收。
# 直接连的节点受害最明显 (走 CDN 的至少域名是别人的)。
#
# 自签证书必须跳过, 否则客户端直接拒绝连接 —— 那个代价是"连不上", 比
# "能连但可被冒充"更难排查, 所以自签时保留 true。
CERT_SKIP_VERIFY="true"
if [[ "${CERT_IS_SELF:-0}" != "1" ]]; then
    CERT_SKIP_VERIFY="false"
    printf "     ${GREEN}[OK]${RESET} 证书受信任, 客户端将校验证书 ${DIM}(skip-cert-verify=false)${RESET}\n" >&2
fi

# ---------- ② 对外地址 ----------
printf '\n' >&2
printf "  ${BOLD}② 对外地址${RESET} ${DIM}—— 客户端配置里写的就是这个${RESET}\n" >&2
# "无需选择" 写法: 一个本来要问、但答案唯一的问题, 直接变成**告知**。
# 既省一次交互, 又让用户知道"这事脚本想过了, 不是忘了问"。
printf "     ${GREEN}[OK]${RESET} 服务端监听: 0.0.0.0 ${DIM}(全部网卡, 无需选择)${RESET}\n" >&2
PUBLIC_IP=$(m_server_ip)
[[ -z "$PUBLIC_IP" ]] && { print_error "拿不到对外地址, 请先在 install_info.env 里设置 PUBLIC_IP"; exit 1; }
printf "     ${GREEN}✅${RESET} %s\n" "$PUBLIC_IP" >&2
printf "     ${GREEN}[OK]${RESET} 客户端配置写入: %s\n" "$PUBLIC_IP" >&2

# m_client_host() 在证书域名不可用时回落 **$SERVER_IP** (src/lib/env.sh:126-133),
# 而本脚本统一用的是 PUBLIC_IP —— 不先把 SERVER_IP 补上, 走到那个回落分支时
# `set -u` 会直接报 "SERVER_IP: unbound variable" 把整批脚本干掉。
SERVER_IP="$PUBLIC_IP"
# M_NO_DOMAIN / "cloudflare.com" 这类哨兵域名在这里会被 m_client_host 换成 IP;
# 另外再兜一层"看起来不像域名"的判断, 防止证书文件名推出来的伪域名
# (env.sh:113-123 记录过: 客户端连的是别人的站点、面板却全绿的假节点)。
# 直连地址: 一律用本机 IP。不过 CDN 就别填域名 —— 域名是 CDN 场景才需要的,
# 混用会让用户分不清产物到底走不走 CDN。
XHTTP_DIRECT_HOST="${PUBLIC_IP:-127.0.0.1}"
# CDN 场景的地址 (证书域名); 仅 xhttp-cdn 使用
XHTTP_CLIENT_HOST=$(m_client_host "$SNI")
[[ "$XHTTP_CLIENT_HOST" =~ ^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$ ]] || XHTTP_CLIENT_HOST="$PUBLIC_IP"
printf "     ${DIM}XHTTP 的 Host 头也用它: %s${RESET}\n" "$XHTTP_CLIENT_HOST" >&2

# ---------- ② 之二、CDN 回源域名 ----------
#
# ★ 为什么批量模式也必须问这个 (2026-10-07 新增)
#
#   xhttp-cdn 这个档位生成的**客户端产物**连的是 Cloudflare 边缘 (443),
#   服务器端监听的是一个"等 Cloudflare 回源"的源站端口。而 Cloudflare 能不能
#   回源到它, 取决于 Nginx 里有没有对应的 location —— 那一步以前**只有交互式
#   的「挂到 CDN」菜单**会做。
#
#   于是 `--quick` (不提问) 这条最省事的批量路径: 节点生成成功、面板显示
#   "成功 19"、三道关全绿, 但 CDN 那一条永远连不上。实测就是这个症状:
#   38 个节点里只有 1 个失败, 失败的那个恰好是 CDN 档位。
#
#   现在批量也把 CDN 挂上: 域名可用 CDN_DOMAIN 环境变量传入 (适合无人值守),
#   交互模式直接问一句, --quick 模式没有域名就**明确提示**而不是闷头生成一个
#   连不上的节点。
printf '\n' >&2
printf "  ${BOLD}② 之二、CDN 回源${RESET} ${DIM}—— Cloudflare 要能回源到 CDN 档位节点${RESET}\n" >&2
CDN_DOMAIN="${CDN_DOMAIN:-}"
CDN_SITE="${CDN_SITE:-}"
if [[ "$QUICK" == "1" && -z "$CDN_DOMAIN" ]]; then
    printf "     ${YELLOW}—${RESET} --quick 且未设 CDN_DOMAIN ${DIM}(批量不提问)${RESET}\n" >&2
    printf "     ${DIM}将生成 xhttp-cdn 源站, 但不会写入 Nginx 回源 —— 该节点需要你之后在${RESET}\n" >&2
    printf "     ${DIM}服务端面板 → CDN 回源 挂一次。无人值守请设 CDN_DOMAIN=你的域名${RESET}\n" >&2
elif [[ -n "$CDN_DOMAIN" ]]; then
    printf "     ${GREEN}✅${RESET} %s ${DIM}(CDN_DOMAIN)${RESET}\n" "$CDN_DOMAIN" >&2
elif [[ "${CERT_IS_SELF:-0}" != "1" && -n "${SNI:-}" ]]; then
    # ② 已经选了真证书 -> 域名**已经知道了**, 不再把站点重列一遍让用户选第二次。
    #
    # 原来这里不管 ① 选了什么都要再列一遍站点, 于是同一个域名连问两遍:
    # 在 ① 选了 aacanaps..., 到 ② 还得再选一次 aacanaps...。两问问的是
    # 同一件事 —— Cloudflare 回源要打到的那个域名, ① 已经回答过了。
    #
    # 这里只问"挂不挂", 域名沿用。只有选了**自签**才需要另外挑一张 CA 可信
    # 的证书: Cloudflare 一律拒绝自签回源。
    printf "     ${CYAN}CDN 模式${RESET} ${DIM}—— vless/vmess/trojan 走 Cloudflare, 其余协议只能直连${RESET}\n" >&2
    printf "       ${CYAN}1${RESET}) 挂 CDN ${DIM}(回源 %s, 沿用 ② 选的证书)${RESET}\n" "$SNI" >&2
    printf "       ${CYAN}2${RESET}) 本批全部直连\n" >&2
    printf "     选哪个 ${DIM}[默认 1]:${RESET} " >&2
    __cm=""; read -r __cm || true
    __cm="$(clean_input "${__cm:-1}")"
    if [[ "$__cm" == "2" ]]; then
        CDN_DOMAIN=""
    else
        CDN_DOMAIN="$SNI"
        printf "     ${GREEN}✅${RESET} %s ${DIM}(沿用 ② 选的证书)${RESET}\n" "$CDN_DOMAIN" >&2
    fi
else
    # 把本机 nginx 站点列出来当候选 —— Cloudflare 回源打的是这个 nginx,
    # 而这些 server_name 就是它现在真在对外服务的域名, 直接选最省事。
    # 原来这里只有一句"回车 = 本批不挂 CDN"让用户手打, 明明配好的站点
    # 要自己回忆域名。
    __sites=(); declare -a __sites=()
    while read -r __s; do [[ -n "$__s" ]] && __sites+=("$__s"); done < <(m_nginx_domains 2>/dev/null)
    if (( ${#__sites[@]} > 0 )); then
        printf "     ${CYAN}CDN 回源域名${RESET} ${DIM}— 选本机 nginx 站点, Cloudflare 要能回源到它${RESET}\n" >&2
        printf "     ${DIM}检测到 %d 个 nginx 站点域名${RESET}\n" "${#__sites[@]}" >&2
        __i=1
        for __s in "${__sites[@]}"; do
            printf "       ${CYAN}%d${RESET}) %s\n" "$__i" "$__s" >&2
            __i=$((__i+1))
        done
        printf "       %s0${RESET}) 不挂 CDN\n" "${CYAN}" >&2
        printf "     选哪个 (回车 = 1, 不挂则输 0):${RESET} " >&2
        __cd=""; read -r __cd || true
        __cd="$(clean_input "${__cd:-1}")"
        if [[ "$__cd" =~ ^[0-9]+$ ]] && (( __cd >= 1 && __cd <= ${#__sites[@]} )); then
            CDN_DOMAIN="${__sites[$((__cd-1))]}"
        elif [[ "$__cd" == "0" ]]; then
            CDN_DOMAIN=""
        elif [[ -n "$__cd" ]]; then
            # 也接受直接手打域名
            [[ "$__cd" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && CDN_DOMAIN="$__cd"
        fi
    else
        printf "     ${DIM}CDN 回源域名 (回车 = 本批不挂 CDN):${RESET} " >&2
        __cd=""; read -r __cd || true
        [[ -n "$__cd" ]] && CDN_DOMAIN="$__cd"
        printf "     ${DIM}未检测到 nginx 站点; 可直接输入域名, 或留空跳过${RESET}\n" >&2
    fi
    [[ -n "$CDN_DOMAIN" ]] && printf "     ${GREEN}✅${RESET} %s\n" "$CDN_DOMAIN" >&2
fi

mkdir -p "$CONF_DIR" "$OUT_DIR" "$CERTS_DIR"
collect_used_ports


# 端口区间只在真正交互时问。
#
# 批量模式的约定是"公共参数一律走显式环境变量, 绝不读应答串"
# (脚本头注释第 21 行), 所以非 TTY 场景不能在这里停顿。
# 提供 ALL_PORT_RANGE=起-止 走非交互, 否则用默认区间。
# --quick 与 ALL_PORT_RANGE 一样走非交互, 只是不要求用户先想好区间。
if [[ -n "${ALL_PORT_RANGE:-}" ]]; then
    if [[ "$ALL_PORT_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        PORT_RANGE_START="${BASH_REMATCH[1]}"
        PORT_RANGE_END="${BASH_REMATCH[2]}"
    fi
    if (( PORT_RANGE_END < PORT_RANGE_START )); then
        _t=$PORT_RANGE_START; PORT_RANGE_START=$PORT_RANGE_END; PORT_RANGE_END=$_t
    fi
    PORT_CURSOR=$PORT_RANGE_START
    # 与 ask_port_range 的收尾保持**同一格式** —— 同一件事在两条路径上
    # 呈现不同, 用户会以为是两种不同的东西。非交互路径也要回显实际区间。
    printf "     ${GREEN}[OK]${RESET} 端口区间: %s - %s ${DIM}(%d 个, 来自 ALL_PORT_RANGE)${RESET}\n" \
        "$PORT_RANGE_START" "$PORT_RANGE_END" \
        "$(( PORT_RANGE_END - PORT_RANGE_START + 1 ))" >&2
elif [[ "$QUICK" == "1" ]]; then
    # --quick: 不问, 直接用默认起点开一段。
    PORT_CURSOR=${ALL_PORT_BASE:-20000}
    PORT_RANGE_END=$(( PORT_CURSOR + 4999 ))
    printf "     ${GREEN}[OK]${RESET} 端口区间: %s - %s ${DIM}(自动分配, --quick 不提问)${RESET}\n" \
        "$PORT_CURSOR" "$PORT_RANGE_END" >&2
elif [[ -t 0 ]]; then
    ask_port_range
    PORT_CURSOR=$PORT_RANGE_START
else
    # 非交互: 用 ALL_PORT_BASE 起的一段, 行为与旧版一致
    PORT_CURSOR=${ALL_PORT_BASE:-20000}
    PORT_RANGE_END=$(( PORT_CURSOR + 4999 ))
fi

printf '\n'
#                        proto           标签                 reality tls  管理协议  生成器
# vmess / ss / snell 仍没有对应的单协议面板, 只能在这里生成、也删不掉 ——
# 想删请用「面板 5) 更新配置」或直接删 conf/config.d 下的文件。
# REALITY 组: 一律 tcp/grpc/xhttp, **绝不排 ws** (实测 REALITY+ws 全 0/5, 见 K-1)
# (这条注释原来写的是 "tcp/grpc/h2" —— trojan-h2 生成器删除时漏改, 已订正。
#  本组现在只有 tcp / grpc / xhttp 三种传输, 没有任何 h2。)
gen reality        "VLESS+Reality"         1 0 reality   g_reality
gen reality-grpc   "VLESS+gRPC+Reality"    1 0 reality   g_vless_grpc_reality
gen reality-xhttp  "VLESS+xHTTP+Reality"   1 0 reality   g_vless_xhttp_reality
gen trojan         "Trojan+Reality"        1 0 trojan    g_trojan_reality
gen trojan-grpc    "Trojan+gRPC+Reality"   1 0 trojan    g_trojan_grpc_reality
# trojan-h2 不在此列: mihomo 的 trojan 出站没有 h2 传输 (见上方说明)。
# ⚠ mkcp / mekya **默认不生成**, 要显式 ALL_MKCP=1 才开。
#
#   实测踩过: 默认开启时, 客户端选中 mKCP 节点会让 **mihomo-client 整个卡死** ——
#   端口还在听 (7890/9090/1053 都能连), 但代理不再出网, sshd 也因为
#   CPU 被吃光而起不来 (TCP 能连上但 SSH banner 永远超时)。只能靠物理重启恢复。
#
#   mKCP 把 UDP 跑在 TCP 之上再自己管重传/拥塞, 在拥塞控制关闭
#   (congestion: false) 时自旋倾向明显。加上它是**传输层重实现**, 各版本
#   内核行为不一致 —— 同样是 mkcp, 有的版本正常, 有的直接把客户端拖垮。
#
#   所以定位成"能力补齐": 能生成、能校验、内核认, 但**不进默认档位**,
#   由用户在明确知道代价的前提下用 ALL_MKCP=1 主动开启。
if [[ "${ALL_MKCP:-0}" == "1" ]]; then
    gen vmess-mkcp   "VMess+mKCP"          0 2 vmess     g_vmess_mkcp
    gen vmess-mekya  "VMess+Mekya"         0 2 vmess     g_vmess_mekya
fi
# VMess 整体不进默认档位 (实测决策), 但**没有删掉**, 需要时显式开启:
#   ALL_VMESS=1 bash src/conf/all.sh
#
# 为什么移出默认:
#   * 特征明显, 主动探测成本低 —— 同样的伪装需求 REALITY 和 TLS 都能满足,
#     而且做得好得多 (见 E-2)。VLESS-REALITY 全套可用, 没有非用 VMess 不可。
#   * 同样一批节点里, VMess-CDN 的两个 (mVMess03-CDN-WS / mVMess04-CDN-gRPC)
#     实测连不上, 而同源的 VLESS-CDN 两个都通。
#   * 性能不如 VLESS, 没有独有优势。
if [[ "${ALL_VMESS:-0}" == "1" ]]; then
    gen vmess-reality  "VMess+TCP+Reality"     1 0 vmess     g_vmess_reality
    gen vmess-grpc     "VMess+gRPC+Reality"    1 0 vmess     g_vmess_grpc_reality
fi
# 证书组
gen trojan-tls     "Trojan+TLS"            0 1 trojan    g_trojan_tls
gen vless-ws       "VLESS+WS+TLS"          0 1 vless     g_vless_ws_tls
gen xhttp-tls      "VLESS+XHTTP+TLS"       0 1 vless     g_vless_xhttp_tls
gen xhttp-cdn      "VLESS+XHTTP+CDN"       0 2 vless     g_vless_xhttp_cdn

# ---- CDN 档位 (3 协议 × 3 传输 = 9 个) ----
#
# 为什么一次生成 9 个而不是 1 个:
#   Cloudflare 边缘会看到你的**流量形态**。只用一种传输, 特征单一; 把
#   ws / gRPC / xHTTP 混着用, 同一批节点对外表现是异构的, 更难被聚类识别。
#   (sing-box 那边也是这个思路, 它的 batch.sh 明写"传输形态不同, 便于分散
#    流量特征"。)
#
# 全部需要**真证书** (第 4 列 = 2): Cloudflare 回源时不认自签 CA,
# 用自签必然回源失败, 且症状是"CDN 侧全绿、客户端连不上", 极难排查。
#
# ⚠ **VMess / Trojan 没有 xHTTP 档位** —— 不是漏写, 是内核不支持:
#   xHTTP 的 listener 侧字段是 `xhttp-config`, 而它只存在于 **vless** 的
#   listener 模式里 (validate.py LISTENER 的 vless 分支才有这一项)。
#   写给 vmess/trojan 的 listener 会被**静默忽略** —— listener 退化成裸 TCP,
#   客户端却按 xHTTP 去连, 必然连不上。
#   现象是自家 validate.py 报「未知键 xhttp-config（内核会静默忽略）」,
#   那条警告就是在拦这个。宁可少两个档位, 也不能发"永远连不上"的死节点。
#   所以 CDN 档位实际是 7 个: vless×{ws,grpc} (xHTTP 已有专档 xhttp-cdn) +
#   vmess×{ws,grpc} + trojan×{ws,grpc}。
#
# 只有 vless/vmess/trojan 出现在这里 —— 别的协议是裸 TCP/UDP,
# Cloudflare 不转发, 给了也是连不上的死节点。
gen cdn-v-ws       "CDN: VLESS+WS"         0 2 vless     g_cdn_tier vless ws
gen cdn-t-ws       "CDN: Trojan+WS"        0 2 trojan    g_cdn_tier trojan ws
# ⚠ CDN 的 gRPC 档位 (VLESS / Trojan) **不进默认**, 实测两个都不通:
#
#   mTrojan05-CDN-gRPC: **绕过 Cloudflare 直连源站同样不通** —— 与 CDN 无关。
#       断点在 mihomo 客户端到 Trojan-gRPC-TLS 监听之间。同一台的
#       mTrojan02-REALITY-gRPC 是通的 (233ms), 所以 Trojan+gRPC 传输本身能用,
#       配 TLS 就断。官方文档列了 grpc, 所以不是"不支持", 是实现层面的问题。
#   mVLESS05-CDN-gRPC:  直连源站 731ms 通, 走 CDN 不通 —— 在 CDN 侧。
#       但同批的 mVMess04-CDN-gRPC 走 CDN 是通的 (221ms), 说明 Cloudflare
#       本身支持 gRPC。两条路径都到过 nginx 且返回 200, 不是被边缘拦掉。
#
# 去掉不丢覆盖: Trojan+gRPC 由 mTrojan02-REALITY-gRPC 满足 (REALITY 更强),
# VLESS 走 CDN 由 mVLESS04-CDN-WS 满足。
# 留着只是让面板多两个永远连不上的节点 —— 故障节点比缺失节点更糟, 用户得
# 逐个排查才知道它是不是坏了。需要时显式开启: ALL_CDN_GRPC=1
if [[ "${ALL_CDN_GRPC:-0}" == "1" ]]; then
    gen cdn-v-grpc     "CDN: VLESS+gRPC"       0 2 vless     g_cdn_tier vless grpc
    gen cdn-t-grpc     "CDN: Trojan+gRPC"      0 2 trojan    g_cdn_tier trojan grpc
fi
if [[ "${ALL_VMESS:-0}" == "1" ]]; then
    gen cdn-m-ws       "CDN: VMess+WS"         0 2 vmess     g_cdn_tier vmess ws
    gen cdn-m-grpc     "CDN: VMess+gRPC"       0 2 vmess     g_cdn_tier vmess grpc
fi
# 明文档 (无 TLS)



gen hysteria2      "Hysteria2"      0 1 hysteria2 g_hysteria2
gen tuicv5         "TUIC v5"        0 1 tuicv5    g_tuicv5
gen anytls         "AnyTLS"         0 1 anytls    g_anytls
# Shadowsocks / Snell 不进默认档位 —— 两个都是**无加密**。
#
# 已经有 REALITY 和 TLS 的时候, 明文协议没有任何存在理由: 它不会比加密的更
# 难被封 (一样是已知协议的已知特征), 却把所有流量暴露在链路上。
# Snell 还有一层问题: 协议本身早已停止维护。
# 需要时显式开启: ALL_PLAIN=1 bash src/conf/all.sh
if [[ "${ALL_PLAIN:-0}" == "1" ]]; then
    gen ss             "Shadowsocks"    0 0 ss        g_shadowsocks
    gen snell          "Snell"          0 0 snell     g_snell
fi

# ---------- 汇总 ----------
printf "\n${BOLD}生成结果${RESET}\n"
printf "  %-18s %-8s %-8s %s\n" "协议" "端口" "状态" "备注"
printf "  %s\n" "────────────────────────────────────────────────────"
local_fail=0 n_ok=0 n_skip=0 n_prev=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r p port st note <<<"$r"
    case "$st" in
        成功) stc="${GREEN}${st}${RESET}"; n_ok=$((n_ok+1)) ;;
        待回源) stc="${YELLOW}${st}${RESET}"; n_skip=$((n_skip+1)) ;;
        预览) stc="${CYAN}${st}${RESET}"; n_prev=$((n_prev+1)) ;;
        失败) stc="${RED}${st}${RESET}"; local_fail=$((local_fail+1)) ;;
        *)    stc="${YELLOW}${st}${RESET}"; n_skip=$((n_skip+1)) ;;
    esac
    printf "  %-18s %-8s %-18b %s\n" "$p" "$port" "$stc" "$note"
done

# ---------- 三桶汇总 (ok / skip / fail) ----------
#
# 只在表尾打一行计数不够 —— 用户真正要回答的问题是"少了什么、为什么少"。
# 所以跳过项与失败项各自再列一遍明细, 失败项带上生成器 stderr 的尾部。
printf "\n${BOLD}汇总${RESET}  "
if [[ "$n_prev" -gt 0 ]]; then
    printf "${CYAN}预览 %d${RESET} · " "$n_prev"
fi
# ⚠️ 颜色常量是字面量 "\033[32m" (bash 双引号里不解释 \033), 只有 printf 的
# **格式串**才会把转义还原 —— 所以颜色必须留在格式串里, 不能当 %s 参数传。
printf "${GREEN}成功 %d${RESET} · ${YELLOW}跳过 %d${RESET} · ${RED}失败 %d${RESET}\n" \
    "$n_ok" "$n_skip" "$local_fail"

if [[ "$n_skip" -gt 0 ]]; then
    printf "${YELLOW}跳过明细${RESET}\n"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r p _ st note <<<"$r"
        [[ "$st" == "跳过" ]] && printf "  · %-18s %s\n" "$p" "$note"
    done
fi
if [[ "$local_fail" -gt 0 ]]; then
    printf "${RED}失败明细${RESET} (这些协议没生成, 其余照常生效)\n"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r p port st note <<<"$r"
        [[ "$st" == "失败" ]] && printf "  · %-18s 端口 %-6s %s\n" "$p" "$port" "$note"
    done
fi

if [[ "$DRY_RUN" == "1" ]]; then
    printf "\n${YELLOW}预览模式, 未写入任何文件${RESET}\n"
    [[ "$FORCE" == "1" ]] && printf "${DIM}(--force 在预览下不会挪走任何旧节点)${RESET}\n"
    exit 0
fi

# ---------- 统一校验 + 重载 ----------
printf "\n${BOLD}校验并应用${RESET}\n"
# ---- 把本批生成的 CDN 档位节点挂到 Nginx 回源 ----
#
# 幂等: 绑定表按 tag 存取, 重跑覆盖同 tag 的旧行, 再整体重渲染该域名的全部
# 绑定 —— 与交互式「挂到 CDN」走的是同一套 cdn.sh 函数, 不是第二套逻辑。
_all_cdn_wire() {
    [[ -n "${CDN_DOMAIN:-}" ]] || return 0
    declare -F cdn_supported_transport >/dev/null 2>&1 || return 0
    # shellcheck disable=SC1091
    source "$SELF_DIR/../lib/cdn.sh" 2>/dev/null || return 0
    cdn_available || { printf "     ${YELLOW}-${RESET} 找不到 nginx_apply.py, 跳过 CDN 挂载\n" >&2; return 0; }

    local dom="$CDN_DOMAIN" site="" n=0 f meta tr path port tag dgre
    # 域名里的 . 要转义后再做正则匹配 (grep -E 是 BRE/ERE, . 任意字符)
    dgre=${dom//./\\.}
    if [[ -n "${CDN_SITE:-}" && -f "${CDN_SITE:-}" ]]; then
        site="$CDN_SITE"
    else
        while read -r cand; do
            [[ -n "$cand" && -f "$cand" ]] || continue
            if grep -qE "^[ \t]*server_name[ \t]+[^;]*\b${dgre}\b" "$cand" 2>/dev/null; then
                site="$cand"; break
            fi
        done < <(python3 "$CDN_APPLY_PY" --list-paths 2>/dev/null)
    fi
    if [[ -z "$site" ]]; then
        printf "     ${YELLOW}-${RESET} 没找到 server_name 含 %s 的 Nginx 站点, 跳过 CDN 挂载\n" "$dom" >&2
        printf "     ${DIM}CDN 节点仍已生成, 但客户端连不上 —— 请先让该域名在 Nginx 上跑起来,\n" >&2
        printf "     ${DIM}之后在 服务端面板 -> CDN 回源 挂一次即可。${RESET}\n" >&2
        return 0
    fi
    printf "     ${DIM}CDN 回源站点: %s${RESET}\n" "$site" >&2

    cdn_bind_init
    # 先剔除孤儿绑定 (片段已被 --force 重建冲掉的旧 tag)。
    # 不做这一步的话, nginx 里会留下指向已废弃端口的 location, 而那个端口
    # 日后被别的节点复用时就会把流量转错节点 —— 见 cdn_bind_prune_orphan 注释。
    local pruned
    pruned=$(cdn_bind_prune_orphan "$CONF_DIR")
    if [[ -n "$pruned" ]]; then
        printf "     ${DIM}清理孤儿绑定 (片段已不存在): %s${RESET}\n" \
            "$(printf '%s' "$pruned" | tr '\n' ' ')" >&2
    fi

    for f in "$CONF_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        grep -qiE '^#.*(CDN|Cloudflare)' "$f" 2>/dev/null || continue
        meta=$(cdn_node_meta_from_fragment "$f"); tr="${meta%%|*}"; path="${meta##*|}"
        cdn_supported_transport "$tr" || continue
        port=$(awk '/^[[:space:]]*port:[[:space:]]*/{print $2; exit}' "$f")
        tag=$(basename "$f" .yaml)
        if cdn_bind_add "$tag" "$dom" "$site" "$tr" "$path" "$port"; then
            printf "     ${GREEN}+${RESET} %-14s %-9s %-24s -> %s\n" "$tag" "$tr" "$path" "$port" >&2
            n=$((n+1))
        fi
    done
    (( n > 0 )) || { printf "     ${YELLOW}-${RESET} 本批没有 CDN 档位节点, 无需挂载\n" >&2; return 0; }
    if cdn_apply_domain "$dom" "$site" >/dev/null 2>&1; then
        printf "     ${GREEN}${BOLD}CDN 回源已写入并重载${RESET} ${DIM}(%d 个节点)${RESET}\n" "$n" >&2
        printf "     ${DIM}剩下一步在 Cloudflare 后台: Origin Rule 指向源站 %s, DNS 开橙云${RESET}\n" "${PUBLIC_IP:-<你的源站IP>}" >&2
    else
        printf "     ${YELLOW}-${RESET} CDN 回源写入失败, 已自动回滚 (节点本身不受影响)\n" >&2
    fi
    return 0
}

if m_sync_reload; then
    # 重建成功 → 暂存区里的旧文件正式作废
    rebuild_commit
    if [[ "$local_fail" -eq 0 ]]; then
        printf "\n${GREEN}${BOLD}全协议节点已生成并生效${RESET}\n"
    else
        # 有失败也照样重载: 成功的那些是好的, 回滚反而把它们一起弄没。
        # 退出码仍非 0, 让调用方 (含 CI) 知道"这一批没全成"。
        printf "\n${YELLOW}${BOLD}已生成并生效, 但有 %d 个协议失败 (见上面「失败明细」)${RESET}\n" "$local_fail"
    fi
    printf "  配置目录: %s\n" "$CONF_DIR"
    printf "  分享内容: %s\n" "$OUT_DIR"

    # 生成完就该能直接用 —— 过去要用户自己再走一遍「生成分享链接」,
    # 中间还夹着"选次数 / 选有效期 / 确认对外地址"三个问题, 于是常常就停在
    # "节点有了, 怎么给客户端"这一步。
    #
    # 次数与有效期取最保守的默认值: 1 次 / 24 小时。链接会直接写进订阅, 而
    # 订阅是要转手给别人的 —— 一次性的链接泄露了也用不了第二次, 到期自动作废。
    # 想要长期链接在面板里自己发, 不批量发。
    if [[ "${NO_SHARE:-0}" != "1" ]] && \
       declare -F share_gen_tag_auto >/dev/null 2>&1; then
        # shellcheck disable=SC1090
        source "${SELF_SHARE_DIR:-$SELF_DIR/../share}/share.sh" 2>/dev/null || true
        if declare -F share_gen_tag_auto >/dev/null 2>&1; then
            share_gen_tag_auto all 1 24 || print_warn "分享链接自动生成失败, 可在面板「生成分享链接」里手动发"
        fi
        # 节点刚变过 —— 顺手把**已有**分享链接的内容刷新一遍 (token/URL 不变)。
        # 不刷的话, 老链接会一直发上一批节点, 直到有人打开分享菜单。
        declare -F share_refresh_all >/dev/null 2>&1 && share_refresh_all
    fi

    # ---- CDN 回源自动挂载 (2026-10-07 新增) ----
    #
    # 放在**重启成功之后**: 此时 conf/config.d 里是这批真实产物, 传输与路径
    # 可以直接读回来 (cdn_node_meta_from_fragment 是唯一真源), 不用猜。
    # 失败不回滚整批节点 —— CDN 是锦上添花, 源站本身已经起来了。
    _all_cdn_wire

    printf "\n  下一步: 服务端面板 → 生成分享链接, 或直接\n"
    printf "          python3 %s --out-dir %s --list\n\n" \
        "$SELF_DIR/../share/build_sub.py" "$OUT_DIR"
    exit $(( local_fail > 0 ? 1 : 0 ))
else
    # 校验没过 → 把重建挪走的旧节点原样还回去, 否则用户从"想重建"
    # 直接变成"一个节点都没有"。
    rebuild_rollback
    printf "\n${RED}${BOLD}校验未通过, 配置已回滚${RESET}\n"
    exit 1
fi
