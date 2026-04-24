#!/bin/bash

set -e

INSTALL_DIR="/root/catmi/mihomo"
SERVICE_NAME="mihomo"
CONFIG_FILE="$INSTALL_DIR/config.yaml"

echo "📦 安装路径: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 检测系统类型
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

# 检测是否为 root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行此脚本"
    exit 1
fi

# 平台架构
UNAME_S="$(uname -s)"
case "$UNAME_S" in
    Linux*) OS="linux" ;;
    *) echo "❌ 不支持系统: $UNAME_S"; exit 1 ;;
esac

UNAME_M="$(uname -m)"
case "$UNAME_M" in
    x86_64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) echo "❌ 不支持架构: $UNAME_M"; exit 1 ;;
esac

echo "✅ 平台: $OS, 架构: $ARCH"

# 获取 Mihomo 最新版本
echo "🌐 获取 Mihomo 最新版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | cut -d '"' -f 4)
if [[ -z "$LATEST_TAG" ]]; then
    echo "❌ 无法获取版本"
    exit 1
fi

echo "🔖 最新版本: $LATEST_TAG"
GZ_FILE="mihomo-${OS}-${ARCH}-${LATEST_TAG}.gz"
DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/${GZ_FILE}"

# 下载并解压
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
echo "⬇️ 下载 $GZ_FILE ..."
curl --location --retry 3 --fail -o "$GZ_FILE" "$DOWNLOAD_URL"

echo "📦 解压..."
gzip -d "$GZ_FILE"
BIN_NAME="mihomo-${OS}-${ARCH}-${LATEST_TAG}"
mv "$BIN_NAME" "$INSTALL_DIR/mihomo"
chmod +x "$INSTALL_DIR/mihomo"

echo "✅ 已安装到 $INSTALL_DIR/mihomo"

# 创建服务
if [[ "$DISTRO" == "alpine" ]]; then
    echo "🛠️ 创建 OpenRC 服务（Alpine）..."
    SERVICE_FILE="/etc/init.d/$SERVICE_NAME"

    cat <<EOF > "$SERVICE_FILE"
#!/sbin/openrc-run
command="$INSTALL_DIR/mihomo"
command_args="-f $INSTALL_DIR/config.yaml"
pidfile="/run/$SERVICE_NAME.pid"
output_log="$INSTALL_DIR/mihomo.log"
error_log="$INSTALL_DIR/error-mihomo.log"
name="Mihomo"
command_background=true
EOF

    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME"
    rc-service "$SERVICE_NAME" restart

    if [ -f "$SERVICE_FILE" ]; then
        echo "✅ OpenRC 服务文件写入成功：$SERVICE_FILE"
    else
        echo "❌ OpenRC 服务文件写入失败，请检查权限"
        exit 1
    fi

    echo "✅ OpenRC 服务已启动（Alpine）"

else
    echo "🛠️ 创建 systemd 服务（Debian/Ubuntu）..."
    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Mihomo Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/mihomo -d $INSTALL_DIR/conf
Restart=on-failure
User=root
LimitNOFILE=65535
StandardOutput=append:$INSTALL_DIR/mihomo.log
StandardError=append:$INSTALL_DIR/error-mihomo.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    echo "✅ systemd 服务已启动"
    systemctl status "$SERVICE_NAME" --no-pager
fi

echo "📄 配置文件路径: $CONFIG_FILE"
