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
import glob, os, re, sys

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

def domain_of(p):
    b = os.path.basename(p)
    b = re.sub(r"^cert-\d+-cert-", "", b)
    b = re.sub(r"^cert-", "", b)
    b = re.sub(r"_cert\.pem$", "", b)
    b = re.sub(r"_key\.pem$", "", b)
    b = re.sub(r"\.(crt|pem|key)$", "", b)
    return b.lower()

# 按域名精确配对
by_dom = {}
for k in keys:
    by_dom.setdefault(domain_of(k), k)
for c in certs:
    dom = domain_of(c)
    if dom in by_dom:
        print(f"{c}\t{by_dom[dom]}\t{dom}")
        raise SystemExit

# 配不上就退回: 第一张证书 + 第一把私钥 (内核会校验是否匹配)
if certs and keys:
    print(f"{certs[0]}\t{keys[0]}\t{domain_of(certs[0])}")
else:
    sys.stderr.write(f"cert={len(certs)} key={len(keys)} other={len(others)}\n")
PYCERT
}

# =============================================================
# 生成器
# =============================================================
RESULTS=()

record() {  # record <协议> <端口> <状态> <说明>
    RESULTS+=("$1|$2|$3|$4")
}

ALL_GEN_IDS="reality reality-grpc reality-xhttp trojan trojan-grpc vmess-reality vmess-grpc trojan-tls vless-ws xhttp-tls xhttp-cdn vless xhttp vmess hysteria2 tuicv5 anytls ss snell"

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
    local body="$*"          # 实际生成 listener 的函数名 + 参数

    if ! want "$proto"; then return; fi
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
    if "$body" "$idx" "$port" "$in_file" "$out_file" 2>"$logf"; then
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
g_vless_xhttp_cdn() {
    [[ -n "$CRT" && -n "$KEY" && -n "$SNI" ]] || {
        record "VLESS+xHTTP+CDN" "-" "跳过" "需要证书 (--no-tls 或证书缺失)"
        return 0
    }
    local path; path=$(m_check_ws_path "$(m_gen_path xhc)") || return 1
    render_xhttp_pad
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
    xhttp-opts:
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
    skip-cert-verify: true
EOF
}

g_vless_ws() {
    local path="/ws$1"
NODE_TAG="$(m_node_tag VLESS "$1" plain WS)"
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
    # v1.19.x 起, 明文 VLESS 入站必须显式 allow-insecure,
    # 否则内核直接拒绝: "disallow using Vless without any certificates/..."
    allow-insecure: true
EOF
NODE_TAG="$(m_node_tag VLESS "$1" plain WS)"
    cat > "$4" <<EOF
proxies:
  - name: $NODE_TAG
    type: vless
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    network: ws
    tls: false
    udp: true
    ws-opts:
      path: $path
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
    skip-cert-verify: true
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
g_vless_xhttp() {
    # 路径过短容易被扫到, 借 env.sh 的共享校验过一道 (>=8 字符, 见 M_MIN_WS_PATH_LEN)
    local path; path=$(m_check_ws_path "$(m_gen_path xhttp)") || return 1
    render_xhttp_pad
NODE_TAG="$(m_node_tag VLESS "$1" plain XHTTP)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成 · VLESS + XHTTP (明文)
listeners:
  - name: $NODE_TAG
    type: vless
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
    # listener 侧**没有** network 字段, 传输方式靠 xhttp-config 是否非空判定
    # (listener/inbound/vless.go:17; listener/sing_vless/server.go:207)
    xhttp-config:
      mode: $XHTTP_MODE
      path: $path
${XHTTP_PAD_FIELDS}
    # 与明文 WS 同一条约束: 不写 allow-insecure, 内核拒绝启动
    # "disallow using Vless without any certificates/..." (server.go:275-277)
    allow-insecure: true
EOF
NODE_TAG="$(m_node_tag VLESS "$1" plain XHTTP)"
    cat > "$4" <<EOF
# 由 all.sh 一键生成 · VLESS + XHTTP (明文) 客户端
proxies:
  - name: $NODE_TAG
    type: vless
    server: $XHTTP_DIRECT_HOST
    port: $2
    uuid: $UUID
    network: xhttp
    tls: false
    udp: true
    # xhttp-opts 与 listener 的 xhttp-config **逐字段一致** (同一份字符串渲染)
    xhttp-opts:
      mode: $XHTTP_MODE
      path: $path
${XHTTP_PAD_FIELDS}
EOF
}

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
    skip-cert-verify: true
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

g_vmess_ws() {
    local path="/vm$1"
    vmess_pad_client_block
NODE_TAG="$(m_node_tag VMess "$1" plain)"
    cat > "$3" <<EOF
# 由 all.sh 一键生成
listeners:
  - name: $NODE_TAG
    type: vmess
    listen: "0.0.0.0"
    port: $2
    users:
      - uuid: $UUID
        # alterId: 0 是唯一安全值 (adapter/outbound/vmess.go:59)
        alterId: 0
    ws-path: $path
    # 注意: global-padding / authenticated-length 在 listener 上**不存在**
    # (listener/inbound/vmess.go:12-30), 它们只属于客户端, 理由见本函数上方注释。
EOF
NODE_TAG="$(m_node_tag VMess "$1" plain)"
    cat > "$4" <<EOF
# 由 all.sh 一键生成
proxies:
  - name: $NODE_TAG
    type: vmess
    server: $PUBLIC_IP
    port: $2
    uuid: $UUID
    # ⚠️ alterId / cipher 的 tag 无 omitempty, 漏写内核直接报 unset fields
    # (adapter/outbound/vmess.go:59-60)
    alterId: 0
    cipher: auto
    network: ws
    tls: false
    udp: true
${VMESS_PAD_BLOCK}
    ws-opts:
      path: $path
EOF
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
    skip-cert-verify: true
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
    skip-cert-verify: true
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
    skip-cert-verify: true
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
    fi
    [[ -n "$CRT" && -f "$CRT" && -n "$KEY" && -f "$KEY" ]] || { CRT=""; KEY=""; SNI=""; }

    # ★ 证书必须在 -d 工作目录内, 否则 mihomo **拒绝加载** (SAFE_PATHS):
    #     Listener mVLESS01-TLS-WS listen err: ... path is not subpath of home
    #     directory or SAFE_PATHS: /etc/letsencrypt/live/<域名>/fullchain.pem
    #   致命之处在于 **mihomo -t 不报错** —— 合并/严格校验/内核三道关全绿,
    #   面板显示"成功 19", 实际 7 个 TLS 监听根本没起来 (实测真实可用 12/19),
    #   客户端连这些节点全部 connection refused。
    #
    #   cert.sh 的 ask_cert 早就调用了 cert_ensure_safe_path (单协议路径没事),
    #   只有 all.sh 这条"★推荐第一次选这个"的批量路径漏了 —— 于是最被推荐的
    #   入口产出最残缺的结果。
    if declare -F cert_ensure_safe_path >/dev/null 2>&1 && \
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
                    printf "     ${CYAN}用哪张证书?${RESET}\n" >&2
                    printf "       ${CYAN}1${RESET}) 本机真实证书 ${DIM}%s${RESET} ${GREEN}(推荐)${RESET}\n" "${SNI:-$CRT}" >&2
                    printf "       ${CYAN}2${RESET}) 现生成自签 ${DIM}(可自定义域名; 客户端需 skip-cert-verify; 过 CDN 无效)${RESET}\n" >&2
                    printf "     请选择 ${DIM}[默认 1]:${RESET} " >&2
                    __ans=""; read -r __ans || true
                    [[ "$__ans" == "2" ]] && __want_self=1
                fi ;;
        esac
        if (( __want_self )); then
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
gen vmess-reality  "VMess+TCP+Reality"     1 0 vmess     g_vmess_reality
gen vmess-grpc     "VMess+gRPC+Reality"    1 0 vmess     g_vmess_grpc_reality
# 证书组
gen trojan-tls     "Trojan+TLS"            0 1 trojan    g_trojan_tls
gen vless-ws       "VLESS+WS+TLS"          0 1 vless     g_vless_ws_tls
gen xhttp-tls      "VLESS+XHTTP+TLS"       0 1 vless     g_vless_xhttp_tls
gen xhttp-cdn      "VLESS+XHTTP+CDN"       0 2 vless     g_vless_xhttp_cdn
# 明文档 (无 TLS)
gen vless          "VLESS+WS"              0 0 vless     g_vless_ws
gen xhttp          "VLESS+XHTTP"           0 0 vless     g_vless_xhttp
gen vmess          "VMess+WS"              0 0 vmess     g_vmess_ws
gen hysteria2      "Hysteria2"      0 1 hysteria2 g_hysteria2
gen tuicv5         "TUIC v5"        0 1 tuicv5    g_tuicv5
gen anytls         "AnyTLS"         0 1 anytls    g_anytls
gen ss             "Shadowsocks"    0 0 ss        g_shadowsocks
gen snell          "Snell"          0 0 snell     g_snell

# ---------- 汇总 ----------
printf "\n${BOLD}生成结果${RESET}\n"
printf "  %-18s %-8s %-8s %s\n" "协议" "端口" "状态" "备注"
printf "  %s\n" "────────────────────────────────────────────────────"
local_fail=0 n_ok=0 n_skip=0 n_prev=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r p port st note <<<"$r"
    case "$st" in
        成功) stc="${GREEN}${st}${RESET}"; n_ok=$((n_ok+1)) ;;
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
