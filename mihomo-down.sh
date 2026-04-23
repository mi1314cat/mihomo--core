#!/bin/bash
set -e

# ================================
# Catmiup v4.3 · Mihomo Installer
# Inbound-only 版（代理服务器专用）
# ================================

BASE_DIR="/root/catmi/mihomo"
BIN_PATH="$BASE_DIR/mihomo"
CONFIG_DIR="$BASE_DIR/conf"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
SERVICE_NAME="mihomo"

echo "📦 安装路径: $BASE_DIR"
mkdir -p "$BASE_DIR"

# -------------------------------
# 创建目录结构（Inbound-only）
# -------------------------------
mkdir -p "$CONFIG_DIR/config.d"
mkdir -p "$BASE_DIR"/{geodata,logs}

# 主配置文件（修复 include 路径）
cat <<EOF > "$CONFIG_PATH"
include: ./config.d/*.yaml
EOF

echo "📄 主配置文件已生成: $CONFIG_PATH"

# -------------------------------
# 检测系统
# -------------------------------
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

DISTRO=$(detect_distro)
echo "🧭 系统: $DISTRO"

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 运行"
    exit 1
fi

# -------------------------------
# 检测架构
# -------------------------------
case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) echo "❌ 不支持架构"; exit 1 ;;
esac

echo "🔧 架构: $ARCH"

# -------------------------------
# 获取最新版本（加 UA 防限流）
# -------------------------------
echo "🌐 获取 Mihomo 最新版本..."
LATEST_JSON=$(curl -A "Mozilla/5.0" -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)
LATEST_TAG=$(echo "$LATEST_JSON" | grep '"tag_name":' | cut -d '"' -f 4)

if [[ -z "$LATEST_TAG" ]]; then
    echo "❌ 无法获取版本"
    exit 1
fi

echo "🔖 最新版本: $LATEST_TAG"

# -------------------------------
# 下载并解压（Linux 版 + 强校验）
# -------------------------------
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

DOWNLOAD_URL=$(echo "$LATEST_JSON" \
    | grep browser_download_url \
    | grep "linux-$ARCH" \
    | grep ".gz" \
    | cut -d '"' -f 4 \
    | head -n 1)

if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "❌ 无法找到适合架构的 Linux 版 Mihomo"
    exit 1
fi

GZ_FILE=$(basename "$DOWNLOAD_URL")

echo "⬇️ 下载: $GZ_FILE"
curl --location --retry 3 --fail -o "$GZ_FILE" "$DOWNLOAD_URL"

echo "📦 解压..."
gzip -d "$GZ_FILE"

# 更稳健的二进制识别
BIN_NAME=$(find . -maxdepth 1 -type f -name "mihomo*" | head -n 1)

if ! file "$BIN_NAME" | grep -q "ELF 64-bit LSB executable"; then
    echo "❌ 下载的不是 Linux 可执行文件（可能被限流或下载错误）"
    exit 1
fi

mv "$BIN_NAME" "$BIN_PATH"
chmod +x "$BIN_PATH"

echo "✅ 已安装到 $BIN_PATH"

# -------------------------------
# 创建 systemd/OpenRC 服务
# -------------------------------
if [[ "$DISTRO" == "alpine" ]]; then
    echo "🛠 创建 OpenRC 服务..."

    SERVICE_FILE="/etc/init.d/$SERVICE_NAME"

    cat <<EOF > "$SERVICE_FILE"
#!/sbin/openrc-run
command="$BIN_PATH"
command_args="-f $CONFIG_PATH"
pidfile="/run/$SERVICE_NAME.pid"
command_background=true
output_log="$BASE_DIR/logs/mihomo.log"
error_log="$BASE_DIR/logs/error.log"
EOF

    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME"
    rc-service "$SERVICE_NAME" restart

else
    echo "🛠 创建 systemd 服务..."

    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Mihomo Service (Inbound-only)
After=network.target

[Service]
ExecStart=$BIN_PATH -f $CONFIG_PATH
Restart=on-failure
User=root
LimitNOFILE=65535

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

ExecReload=/bin/kill -HUP \$MAINPID

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
fi

echo "🎉 安装完成"
echo "📌 配置目录: $CONFIG_DIR"
echo "📌 多配置目录: $CONFIG_DIR/config.d"
echo "📌 使用: systemctl status $SERVICE_NAME"
