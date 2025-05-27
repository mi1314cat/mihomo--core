#!/bin/bash

# 定义脚本URL（必须在函数之前）
SCRIPT_A1="https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/mihomo.sh"
SCRIPT_A2="https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/n-mihomo.sh"
SCRIPT_B1="https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/alpine-mihomo.sh"
SCRIPT_B2="https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/n-alpine-mihomo.sh"

# 检查系统类型并运行对应的脚本
run_script() {
    local os_name="$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')"

    case "$os_name" in
        debian|ubuntu)
            echo "检测到系统: $os_name"
            install_mihomo
            ;;
        alpine)
            echo "检测到系统: $os_name"
            install_alpine_mihomo
            ;;
        *)
            echo "❌ 不支持的系统: $os_name。此脚本不支持当前系统，程序退出。"
            exit 1
            ;;
    esac
}

# 安装函数（Debian/Ubuntu）
install_mihomo() {
    echo
    echo "请选择 Mihomo 安装版本："
    echo "1. mihomo"
    echo "2. mihomo-4"
    echo "3. 删除mihomo"
    read -p "请输入对应的数字选择 [默认1]: " unmi
    unmi=${unmi:-1}

    case "$unmi" in
        1)
            bash <(curl -fsSL "$SCRIPT_A1") || echo "❌ 下载执行失败：$SCRIPT_A1"
            ;;
        2)
            bash <(curl -fsSL "$SCRIPT_A2") || echo "❌ 下载执行失败：$SCRIPT_A2"
            ;;
        3)
            systemctl stop mihomo
            rm -rf /root/catmi/install_info.txt
            rm -rf /root/catmi/DOMAIN_LOWER.txt
            rm -rf /root/catmi/mihomo
            rm -rf /root/.config/mihomo
            rm -rf /etc/systemd/system/mihomo.service
            systemctl daemon-reload
            
            ;;    
        *)
            echo "❌ 无效选择，退出脚本"
            exit 1
            ;;
    esac
}

# 安装函数（Alpine）
install_alpine_mihomo() {
    echo
    echo "请选择 Alpine 版本的 Mihomo 安装："
    echo "1. mihomo"
    echo "2. mihomo-4"
    echo "3. 删除mihomo"
    read -p "请输入对应的数字选择 [默认1]: " anmi
    anmi=${anmi:-1}

    case "$anmi" in
        1)
            bash <(curl -fsSL "$SCRIPT_B1") || echo "❌ 下载执行失败：$SCRIPT_B1"
            ;;
        2)
            bash <(curl -fsSL "$SCRIPT_B2") || echo "❌ 下载执行失败：$SCRIPT_B2"
            ;;
        3)
            rc-service mihomo stop
            rc-update del mihomo
            rm -rf /root/catmi/install_info.txt
            rm -rf /root/catmi/DOMAIN_LOWER.txt
            rm -rf /root/catmi/mihomo
            rm -rf /root/.config/mihomo
            rm -rf /etc/init.d/mihomo
            
            ;;     
        *)
            echo "❌ 无效选择，退出脚本"
            exit 1
            ;;
    esac
}

# 启动主函数
run_script
