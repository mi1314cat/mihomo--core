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

INSTALL_DIR="/root/catmi/mihomo"
OUT_DIR="$INSTALL_DIR/out"
LOG_FILE="$INSTALL_DIR/mihomo.log"
ERR_FILE="$INSTALL_DIR/error-mihomo.log"

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
# 卸载 Mihomo
# ================================
uninstall_mihomo() {
    print_title "卸载 Mihomo"

    read -p "确认卸载 Mihomo？(y/n): " confirm
    [[ "$confirm" != "y" ]] && print_info "已取消卸载" && return

    systemctl stop mihomo.service 2>/dev/null
    systemctl disable mihomo.service 2>/dev/null
    rm -f /etc/systemd/system/mihomo.service

    rm -rf "$INSTALL_DIR"

    systemctl daemon-reload

    print_ok "Mihomo 已卸载完成"
}

# ================================
# 查看客户端配置文件
# ================================
cat_out_files() {
    local dir="$1"

    [[ -d "$dir" ]] || {
        echo "[Info] 目录不存在: $dir"
        return 0
    }

    echo "====== TXT 文件内容 ======"
    echo

    local txt_files=("$dir"/*.txt)
    if ls "$dir"/*.txt >/dev/null 2>&1; then
        for f in "${txt_files[@]}"; do
            echo ">>> 文件：$(basename "$f")"
            echo "----------------------------------------"
            cat "$f"
            echo -e "\n"
        done
    else
        echo "无 TXT 文件"
    fi

    echo
    echo "====== YAML 文件内容 ======"
    echo

    local yaml_files=("$dir"/*.yaml)
    if ls "$dir"/*.yaml >/dev/null 2>&1; then
        for f in "${yaml_files[@]}"; do
            echo ">>> 文件：$(basename "$f")"
            echo "----------------------------------------"
            cat "$f"
            echo -e "\n"
        done
    else
        echo "无 YAML 文件"
    fi
}

# ================================
# 查看客户端配置文件（自动全部展开）
# ================================
view_client_config() {
    cat_out_files "/root/catmi/mihomo/out"
}
# ================================
# 日志子菜单
# ================================
log_menu() {
    while true; do
        print_title "Mihomo 日志菜单"

        echo "1) 实时查看运行日志 (tail -f)"
        echo "2) 查看错误日志"
        echo "3) 查看完整运行日志"
        echo "0) 返回主菜单"

        read -p "请选择: " log_choice

        case "$log_choice" in
            1)
                [[ -f "$LOG_FILE" ]] && tail -f "$LOG_FILE" || print_error "日志不存在"
                ;;
            2)
                [[ -f "$ERR_FILE" ]] && less "$ERR_FILE" || print_error "错误日志不存在"
                ;;
            3)
                [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || print_error "日志不存在"
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选项"
                ;;
        esac
    done
}

# ================================
# 重启 Mihomo
# ================================
restart_mihomo() {
    print_info "正在重启 mihomo.service ..."
    bash <(curl -fsSL https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/synthesisconfiguration.sh) 
    if systemctl restart mihomo.service; then
        print_ok "重启成功"
    else
        print_error "重启失败"
    fi
}
# ================================
# 添加节点子菜单
# ================================
add_node_menu() {
    while true; do
        print_title "添加节点"

        echo "1) Reality"
        echo "2) Hysteria2"
        echo "3) TUIC"
        echo "4) AnyTLS"
        echo "0) 返回主菜单"

        read -p "请选择: " node_choice

        case "$node_choice" in
            1)
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/Reality.sh" "Reality"
                ;;
            2)
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/hysteria2.sh" "Hysteria2"
                ;;
            3)
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/TUIC.sh" "TUIC"
                ;;
            4)
                run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/AnyTLS.sh" "AnyTLS"
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选项"
                ;;
        esac

        read -p "按回车继续..."
    done
}

# ================================
# 系统信息
# ================================
show_system_info() {
    SYSTEM_NAME=$(grep -i pretty_name /etc/os-release | cut -d \" -f2)
    CORE_ARCH=$(arch)

    SERVICE_STATUS=$(systemctl is-active mihomo.service)
    if [[ "$SERVICE_STATUS" == "active" ]]; then
        SERVICE_STATUS="${GREEN}运行中${RESET}"
    else
        SERVICE_STATUS="${RED}未运行${RESET}"
    fi

    clear
    cat << "EOF"
                       |\__/,|   (\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.mihomo
       -----------------------------------------
EOF

    echo -e "${GREEN}System:       ${RESET}${SYSTEM_NAME}"
    echo -e "${GREEN}Architecture: ${RESET}${CORE_ARCH}"
    echo -e "${GREEN}Mihomo 状态:  ${RESET}${SERVICE_STATUS}"
    echo -e "${GREEN}Version:      ${RESET}1.0.0"
    echo -e "----------------------------------------"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        show_system_info
        print_title "Mihomo 协议管理菜单"

        echo "1) 安装 Mihomo"
        echo "2) 添加节点"
        echo "3) 查看客户端配置文件"
        echo "4) 日志菜单"
        echo "5) 重启 Mihomo"
        echo "6) 卸载 Mihomo"
        echo "0) 退出"


        read -p "请选择: " choice

        case "$choice" in
    1) run_script "https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/mihomo-down.sh" "安装 Mihomo" ;;
    2) add_node_menu ;;
    3) view_client_config ;;
    4) log_menu ;;
    5) restart_mihomo ;;
    6) uninstall_mihomo ;;
    0) exit 0 ;;
    *) print_error "无效选项" ;;
esac


        read -p "按回车继续..."
    done
}

main_menu
