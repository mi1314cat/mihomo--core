#!/bin/bash

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
RESET="\e[0m"

print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1"; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1"; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1"; }

print_title() {
    printf "${MAGENTA}${BOLD}"
    printf "╔══════════════════════════════════════════════╗\n"
    printf "║ %-42s ║\n" "$1"
    printf "╚══════════════════════════════════════════════╝\n"
    printf "${RESET}"
}

# ================================
# 执行远程脚本
# ================================
run_script() {
    local url="$1"
    local name="$2"

    print_info "正在运行 $name ..."
    bash <(curl -fsSL "$url")

    if [[ $? -eq 0 ]]; then
        print_ok "$name 执行完成"
    else
        print_error "$name 执行失败"
    fi
}

# ================================
# 重启 mihomo.service（写死）
# ================================
restart_mihomo() {
    print_info "正在重启 mihomo.service ..."
    systemctl restart mihomo.service

    if [[ $? -eq 0 ]]; then
        print_ok "mihomo.service 重启成功"
    else
        print_error "mihomo.service 重启失败"
    fi
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Mihomo 协议管理菜单"

        echo "1) Reality"
        echo "2) Hysteria2"
        echo "3) TUIC"
        echo "4) AnyTLS"
        echo "5) 重启 mihomo.service"
        echo "0) 退出"

        printf "请选择: "
        read choice

        case "$choice" in
            1)
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/Reality.sh" "Reality"
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/synthesisconfiguration.sh" "x"
                if ! systemctl restart mihomo.service; then
                 print_error "重启 mihomo.service 服务失败，请运行 'journalctl -u mihomo -b --no-pager' 获取详情"
                 systemctl status mihomo.service--no-pager || true
                exit 1
                fi
                ;;
            2)
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/hysteria2.sh" "Hysteria2"
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/synthesisconfiguration.sh" "x"
                if ! systemctl restart mihomo.service; then
                 print_error "重启 mihomo.service 服务失败，请运行 'journalctl -u mihomo -b --no-pager' 获取详情"
                 systemctl status mihomo.service--no-pager || true
                exit 1
                fi
                ;;
            3)
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/TUIC.sh" "TUIC"
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/synthesisconfiguration.sh" "x"
                if ! systemctl restart mihomo.service; then
                 print_error "重启 mihomo.service 服务失败，请运行 'journalctl -u mihomo -b --no-pager' 获取详情"
                 systemctl status mihomo.service--no-pager || true
                exit 1
                fi
                ;;
            4)
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/AnyTLS.sh" "AnyTLS"
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/synthesisconfiguration.sh" "x"
                if ! systemctl restart mihomo.service; then
                 print_error "重启 mihomo.service 服务失败，请运行 'journalctl -u mihomo -b --no-pager' 获取详情"
                 systemctl status mihomo.service--no-pager || true
                exit 1
                fi
                ;;
            5)
                if ! systemctl restart mihomo.service; then
                 print_error "重启 mihomo.service 服务失败，请运行 'journalctl -u mihomo -b --no-pager' 获取详情"
                 systemctl status mihomo.service--no-pager || true
                exit 1
                fi
                ;;
            0)
                exit 0
                ;;
            *)
                print_error "无效选项"
                ;;
        esac

        echo
        read -p "按回车继续..."
    done
}

main_menu
