#!/bin/bash
# Mihomo Auto Install Script (Optimized)
# 支持自动识别 CPU 指令集，自动下载 compatible / v3 版本

set -euo pipefail

INSTALL_DIR="/root/catmi/mihomo"
SERVICE_NAME="mihomo"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GITHUB_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Mihomo 自动安装脚本"
echo "📂 安装目录: $INSTALL_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Root 检测
if [ "$(id -u)" != "0" ]; then
    echo "❌ 请使用 root 权限运行"
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# 检测系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    DISTRO="unknown"
fi

# 架构检测
ARCH_RAW=$(uname -m)

case "$ARCH_RAW" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        echo "❌ 不支持架构: $ARCH_RAW"
        exit 1
        ;;
esac

echo "🧭 系统: $DISTRO"
echo "🖥 架构: $ARCH"

# CPU型号显示
CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ //')
echo "⚙ CPU: $CPU_MODEL"

# x86_64 自动识别 v3 指令集
SUFFIX=""

if [ "$ARCH" = "amd64" ]; then
    FLAGS=$(grep -m1 '^flags' /proc/cpuinfo)

    if echo "$FLAGS" | grep -qw avx2 &&
       echo "$FLAGS" | grep -qw bmi2 &&
       echo "$FLAGS" | grep -qw fma; then

        SUFFIX="-v3"
        echo "✅ CPU支持 x86_64-v3 指令集，使用高性能版"

    else
        SUFFIX="-compatible"
        echo "⚠ CPU不支持 v3，使用兼容版（推荐老E5/E3/VPS）"
    fi
fi

# 获取最新版
echo "🌐 获取 Mihomo 最新版本..."

LATEST_TAG=$(curl -fsSL "$GITHUB_API" | grep tag_name | cut -d '"' -f4)

if [ -z "$LATEST_TAG" ]; then
    echo "❌ 获取版本失败"
    exit 1
fi

echo "🔖 最新版本: $LATEST_TAG"

# 文件名
FILE_NAME="mihomo-linux-${ARCH}${SUFFIX}-${LATEST_TAG}.gz"
URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/${FILE_NAME}"

echo "⬇ 下载文件:"
echo "$FILE_NAME"

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

curl -L --retry 3 --fail -o mihomo.gz "$URL"

echo "📦 解压中..."
gunzip mihomo.gz

mv mihomo "$INSTALL_DIR/mihomo"
chmod +x "$INSTALL_DIR/mihomo"

echo "✅ 安装完成"

# 创建配置目录
mkdir -p "$INSTALL_DIR/conf"

# 写入 systemd
echo "🛠 配置 systemd 服务..."

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

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

echo "🚀 启动 Mihomo..."

if systemctl restart "$SERVICE_NAME"; then
    echo "✅ 启动成功"
else
    echo "❌ 启动失败，查看日志："
    journalctl -u mihomo -n 30 --no-pager
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📂 安装目录: $INSTALL_DIR"
echo "📄 配置目录: $INSTALL_DIR/conf"
echo "📜 日志文件: $INSTALL_DIR/mihomo.log"
echo "🛠 管理命令:"
echo "systemctl status mihomo"
echo "systemctl restart mihomo"
echo "journalctl -u mihomo -f"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
