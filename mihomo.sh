#!/bin/bash

set -e

INSTALL_DIR="/root/catmi/mihomo"
SERVICE_NAME="mihomo"
CONFIG_FILE="$INSTALL_DIR/config.yaml"

echo "📦 安装路径: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 检测发行版
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

DISTRO=$(detect_distro)
echo "🧭 检测系统: $DISTRO"

# 检测平台
UNAME_S="$(uname -s)"
case "$UNAME_S" in
    Linux*) OS="linux" ;;
    Darwin*) OS="darwin" ;;
    *) echo "❌ 不支持系统: $UNAME_S"; exit 1 ;;
esac

# 架构
UNAME_M="$(uname -m)"
case "$UNAME_M" in
    x86_64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) echo "❌ 不支持架构: $UNAME_M"; exit 1 ;;
esac

echo "✅ 平台: $OS, 架构: $ARCH"

# 获取 Mihomo 最新版本
LATEST_TAG=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | cut -d '"' -f 4)
if [[ -z "$LATEST_TAG" ]]; then
    echo "❌ 无法获取版本"
    exit 1
fi

echo "🔖 最新版本: $LATEST_TAG"
FILE_NAME="mihomo-$OS-$ARCH.zip"
DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/$LATEST_TAG/$FILE_NAME"

# 下载并解压
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
curl -L -o "$FILE_NAME" "$DOWNLOAD_URL"
unzip -o "$FILE_NAME"
mv -f mihomo "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/mihomo"

echo "📁 安装成功: $INSTALL_DIR/mihomo"

# 创建服务：根据系统类型
if [[ "$DISTRO" == "alpine" ]]; then
    echo "🛠️ 正在为 Alpine 创建 OpenRC 服务..."

    SERVICE_FILE="/etc/init.d/$SERVICE_NAME"

    cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
#!/sbin/openrc-run
command="$INSTALL_DIR/mihomo"
command_args="-d $INSTALL_DIR"
pidfile="/run/$SERVICE_NAME.pid"
name="Mihomo"
EOF

    sudo chmod +x "$SERVICE_FILE"
    sudo rc-update add "$SERVICE_NAME"
    sudo rc-service "$SERVICE_NAME" restart

    echo "✅ OpenRC 服务已启动 (Alpine)"

else
    echo "🛠️ 正在为 Debian/Ubuntu 创建 systemd 服务..."

    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

    cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Mihomo Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/mihomo -d $INSTALL_DIR
Restart=on-failure
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"

    echo "✅ systemd 服务已启动"
    sudo systemctl status "$SERVICE_NAME" --no-pager
fi

echo "📄 配置文件路径: $CONFIG_FILE"
