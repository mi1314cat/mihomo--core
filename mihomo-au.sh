#!/bin/bash

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
            echo "不支持的系统: $os_name。此脚本不支持当前系统，程序退出。"
            exit 1
            ;;
    esac
}



install_mihomo() {
    echo "1. mihomo"
    echo "2. mihomo-4 "
    read -p "请输入对应的数字选择 [默认1]: " unmi

# 如果没有输入（即回车），则默认选择1
unmi=${unmi:-1}

# 选择公网 IP 地址
if [ "$unmi" -eq 1 ]; then
    bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/"$SCRIPT_A1")
elif [ "$unmi" -eq 2 ]; then
    bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/"$SCRIPT_A2")
else
    echo "无效选择，退出脚本"
    exit 1
fi
}

install_alpine_mihomo() {
    echo "1. mihomo"
    echo "2. mihomo-4 "
    read -p "请输入对应的数字选择 [默认1]: " anmi

# 如果没有输入（即回车），则默认选择1
anmi=${anmi:-1}

# 选择公网 IP 地址
if [ "$anmi" -eq 1 ]; then
    bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/"$SCRIPT_B1")
elif [ "$anmi" -eq 2 ]; then
    bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/"$SCRIPT_B2")
else
    echo "无效选择，退出脚本"
    exit 1
fi
}


# 定义脚本URL
SCRIPT_A1="https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/mihomo.sh"
SCRIPT_A2="https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/n-mihomo.sh"
SCRIPT_B1="https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/alpine-mihomo.sh"
SCRIPT_B2="https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/n-alpine-mihomo.sh"
