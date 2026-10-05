#!/usr/bin/env bash
# =============================================================
# mihomo 内核安装 (服务端 / 客户端共用)
#
# 相对旧版 mihomo-down.sh 的改动:
#   * 校验 sha256, 防止下载到半截文件还照样安装
#   * 生成基础 conf/config.yaml —— 旧版从不生成, 新装完直接起不来
#   * 启动失败自动回滚到上一个能跑的内核
#   * 保留 x86_64 的 v3 / compatible 指令集自动选择
# =============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/root/catmi/mihomo}"
SERVICE_NAME="${SERVICE_NAME:-mihomo}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GITHUB_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
MIRROR_API="https://cfgithub.gw2333.workers.dev/https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

# 必须写 stderr: 这些函数会在 $(...) 里被调用, 走 stdout 会污染返回值
say() { printf "  %s\n" "$1" >&2; }
die() { printf "\033[31m[错误]\033[0m %s\n" "$1" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "请使用 root 权限运行"

printf "\033[35m\033[1m╔══════════════════════════════════════════════╗\n"
printf "║  Mihomo 内核安装                                 ║\n"
printf "╚══════════════════════════════════════════════╝\033[0m\n"

# ---------- 架构 ----------
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "不支持的架构: $(uname -m)" ;;
esac

SUFFIX=""
if [[ "$ARCH" == "amd64" ]]; then
    FLAGS=$(grep -m1 '^flags' /proc/cpuinfo)
    if grep -qw avx2 <<<"$FLAGS" && grep -qw bmi2 <<<"$FLAGS" && grep -qw fma <<<"$FLAGS"; then
        SUFFIX="-v3"; say "CPU 支持 x86_64-v3, 使用高性能版"
    else
        SUFFIX="-compatible"; say "CPU 不支持 v3, 使用兼容版"
    fi
fi
say "架构: $ARCH${SUFFIX}"

# ---------- 版本 ----------
# 三种方式依次尝试。GitHub API 在不少国内机器上被墙, 但
# releases/latest 的 302 重定向通常可用, git ls-remote 是最后兜底。
resolve_tag() {
    local t=""

    t=$(curl -fsSL --max-time 20 "$GITHUB_API" 2>/dev/null | grep -m1 tag_name | cut -d '"' -f4) || true
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    say "  API 不可用, 走重定向"

    t=$(curl -fsSLI --max-time 20 -o /dev/null -w '%{redirect_url}' \
        "https://github.com/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
        | sed -n 's#.*/tag/##p') || true
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    say "  重定向不可用, 走 git ls-remote"

    t=$(git ls-remote --tags --refs https://github.com/MetaCubeX/mihomo.git 2>/dev/null \
        | awk '{print $2}' | sed 's#refs/tags/##' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1) || true
    [[ -n "$t" ]] && printf '%s' "$t"
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 已有可用内核时可直接指定, 跳过下载。
# 适用场景: GitHub 在本机不可达, 但机器上已经有 arm64/amd64 的 mihomo。
LOCAL_BIN="${MIHOMO_LOCAL_BIN:-}"
if [[ -n "$LOCAL_BIN" && -x "$LOCAL_BIN" ]]; then
    say "使用指定内核: $LOCAL_BIN"
    say "  版本: $("$LOCAL_BIN" -v 2>/dev/null | head -1)"
    cp -f "$LOCAL_BIN" "$TMP/mihomo"
    chmod +x "$TMP/mihomo"
else

say "查询最新版本..."
LATEST_TAG=$(resolve_tag)
LATEST_TAG="${LATEST_TAG//[$'\r\n']/}"
[[ -n "$LATEST_TAG" ]] || die "获取版本失败
  本机可能无法访问 GitHub。若已有可用内核, 可这样指定:
  MIHOMO_LOCAL_BIN=/path/to/mihomo bash core_install.sh"
say "版本: $LATEST_TAG"

BASE="mihomo-linux-${ARCH}${SUFFIX}-${LATEST_TAG}"
DL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}"

say "下载 ${BASE}.gz"
if ! curl -L --retry 3 --retry-delay 2 --fail --max-time 300 -o "$TMP/mihomo.gz" "$DL/${BASE}.gz" 2>/dev/null; then
    say "  主站失败, 走镜像..."
    curl -L --retry 2 --fail --max-time 300 -o "$TMP/mihomo.gz" \
        "https://cfgithub.gw2333.workers.dev/${DL}/${BASE}.gz" 2>/dev/null \
        || die "下载失败 (GitHub 与镜像均不可达)
  本机可能无法访问 GitHub。若已有可用内核, 可这样指定:
  MIHOMO_LOCAL_BIN=/path/to/mihomo bash core_install.sh"
fi

# ---------- 校验 ----------
# Mihomo 官方并未为每个 .gz 发布 .sha256, 因此这里是"有就验, 没有就跳过",
# 但只要拿到就必须对上 —— 防止下到半截文件还照样安装。
EXPECT=""
for u in "${DL}/${BASE}.gz.sha256" "${DL}/mihomo-linux-${ARCH}${SUFFIX}-${LATEST_TAG}.sha256"; do
    curl -fsSL --max-time 15 -o "$TMP/sum.txt" "$u" 2>/dev/null || continue
    EXPECT=$(grep -oiE '[0-9a-f]{64}' "$TMP/sum.txt" 2>/dev/null | head -1)
    [[ -n "$EXPECT" ]] && break
done
if [[ -n "$EXPECT" ]]; then
    ACTUAL=$(sha256sum "$TMP/mihomo.gz" | cut -d' ' -f1)
    [[ "$EXPECT" == "$ACTUAL" ]] || die "sha256 校验失败
  期望: $EXPECT
  实际: $ACTUAL"
    say "sha256 校验通过"
else
    # 没有官方校验和时, 用"能解压 + 能自报版本"作为最低限度的完整性检查
    say "官方未提供校验和, 改用解压与冒烟测试兜底"
fi

gunzip -c "$TMP/mihomo.gz" > "$TMP/mihomo" || die "解压失败"
fi

# ---------- 冒烟测试 ----------
chmod +x "$TMP/mihomo"
"$TMP/mihomo" -v >/dev/null 2>&1 || die "内核无法执行, 架构或指令集不匹配"
say "内核可执行: $("$TMP/mihomo" -v | head -1)"

# ---------- 目录 ----------
mkdir -p "$INSTALL_DIR/conf/config.d" "$INSTALL_DIR/conf/certs" "$INSTALL_DIR/out"

# ---------- geo 数据库 ----------
# 客户端规则会用 GEOSITE/GEOIP, 但这些 .dat/.metadb 文件常常已经存在于机器上
# (别的 mihomo / sing-box 装过)。找出来复制到配置目录, 省掉一次 GitHub 下载
# —— 很多机器根本访问不了 GitHub。
seed_geodata() {
    local found=0 f
    local cands=(
        /root/catmi/geoip.metadb /root/catmi/geosite.metadb
        /root/catmi/GeoIP.dat      /root/catmi/GeoSite.dat
        "$INSTALL_DIR/../geoip.metadb" "$INSTALL_DIR/../geosite.metadb"
        "$INSTALL_DIR/../GeoIP.dat"      "$INSTALL_DIR/../GeoSite.dat"
    )
    for f in "${cands[@]}"; do
        [[ -f "$f" ]] || continue
        local base; base=$(basename "$f")
        [[ -f "$INSTALL_DIR/conf/$base" ]] && continue
        cp -f "$f" "$INSTALL_DIR/conf/$base" && found=$((found+1))
        say "复用已有 geo 数据库: $base"
    done
    [[ "$found" -gt 0 ]] || say "未找到现成 geo 数据库 (规则将自动退化为不依赖 GEOIP/GEOSITE)"
}
seed_geodata

# ---------- 基础配置 ----------
CONF="$INSTALL_DIR/conf/config.yaml"
if [[ ! -f "$CONF" ]]; then
    say "生成基础配置 $CONF"
    cat > "$CONF" <<'EOF'
# mihomo--core 基础配置
#
# 服务端模式: 节点写在 conf/config.d/<proto>-<NN>.yaml,
# 每次增删都会由 merge.py 合并进本文件的 listeners。
# 不要手工改 listeners, 会被覆盖。

mixed-port: 0
allow-lan: false
mode: rule
log-level: info
ipv6: true
external-controller: 127.0.0.1:9090
secret: ""

profile:
  store-selected: true

listeners: []

proxy-groups: []

rules:
  - MATCH,DIRECT
EOF
fi

# ---------- 替换内核 (保留旧版以便回滚) ----------
OLD=""
if [[ -x "$INSTALL_DIR/mihomo" ]]; then
    OLD="$INSTALL_DIR/mihomo.bak"
    cp -f "$INSTALL_DIR/mihomo" "$OLD"
fi
cp -f "$TMP/mihomo" "$INSTALL_DIR/mihomo"
chmod +x "$INSTALL_DIR/mihomo"

# ---------- systemd ----------
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/mihomo -d $INSTALL_DIR/conf
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=3
LimitNOFILE=1048576

StandardOutput=append:$INSTALL_DIR/mihomo.log
StandardError=append:$INSTALL_DIR/error-mihomo.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

# ---------- 启动 + 回滚 ----------
say "启动服务..."
if systemctl restart "$SERVICE_NAME"; then
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        printf "\033[32m[成功]\033[0m 内核安装并启动成功\n"
    else
        printf "\033[33m[警告]\033[0m 进程已退出, 正在回滚\n" >&2
        [[ -n "$OLD" ]] && cp -f "$OLD" "$INSTALL_DIR/mihomo" && systemctl restart "$SERVICE_NAME"
        journalctl -u "$SERVICE_NAME" -n 15 --no-pager >&2 || true
    fi
else
    printf "\033[33m[警告]\033[0m 启动失败, 回滚到上一个内核\n" >&2
    [[ -n "$OLD" ]] && cp -f "$OLD" "$INSTALL_DIR/mihomo" && systemctl restart "$SERVICE_NAME"
    journalctl -u "$SERVICE_NAME" -n 15 --no-pager >&2 || true
fi

printf '\n  安装目录: %s\n  配置目录: %s\n  节点目录: %s/conf/config.d\n' \
    "$INSTALL_DIR" "$INSTALL_DIR/conf" "$INSTALL_DIR"
printf '  管理面板: bash <(curl -fsSL <仓库地址>/install.sh)\n\n'
