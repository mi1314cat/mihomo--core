#!/bin/bash

# ================================
# catmi-mihomo v2.0 主框架脚本
# ================================

BASE_DIR="/root/catmi/mihomo"
MOENV_FILE="$BASE_DIR/install_info.env"
CATMI_ENV="/root/catmi/catmi.env"
OUT_DIR="$BASE_DIR/out"
INSTALL_DIR="$BASE_DIR/conf/config.d"

mkdir -p "$INSTALL_DIR" "$BASE_DIR" "$OUT_DIR"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

print_info()  { echo -e "${GREEN}[Info]${PLAIN} $1"; }
print_warn()  { echo -e "${YELLOW}[Warn]${PLAIN} $1"; }
print_error() { echo -e "${RED}[Error]${PLAIN} $1"; }

# ================================
# 通用工具：二维码生成（base64 + PNG）
# ================================
generate_qr() {
    local text="$1"
    local outfile="$2"

    # base64 文本（方便复制）
    echo -n "$text" | base64 -w 0 > "${outfile}.b64"

    # PNG 二维码（可选）
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -o "${outfile}.png" "$text"
    else
        print_warn "未检测到 qrencode，跳过 PNG 生成：${outfile}.png"
    fi
}

# ================================
# 1. 环境初始化 & 标记 mode=mihomo
# ================================
init_env() {
    print_info "加载环境变量 & 标记 mode=mihomo..."

    # 与 xray 脚本一致的 env 管理
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")

    local DINSTALL_CATMI="/root/catmi"
    local CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

    update_env "$CATMIENV_FILE" mode mihomo
    load_env "$CATMIENV_FILE"

    # 生成核心服务文件 & 域名信息
    bash <(curl -fsSL https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/XRevise.sh)
    bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh)

    # 再加载一次 install_info.env（UUID / DOMAIN_LOWER / WS_PATH 等）
    load_env "$MOENV_FILE"

    # 兼容变量名：如果有 CDOMAIN_LOWER 就优先用
    if [[ -n "$CDOMAIN_LOWER" ]]; then
        DOMAIN_LOWER="$CDOMAIN_LOWER"
    fi

    print_info "环境初始化完成：UUID=$UUID DOMAIN_LOWER=$DOMAIN_LOWER"
}

# ================================
# 2. 生成 Mihomo 服务端入站（listeners）
# ================================
generate_mihomo_listeners() {
    print_info "生成 Mihomo listeners 配置..."

    cat <<EOF > "$INSTALL_DIR/nginx.yaml"
listeners:
  - name: vmess-in-1
    type: vmess
    listen: 127.0.0.1
    port: 9996
    users:
      - username: "1"
        uuid: "${UUID}"
        alterId: 1
    ws-path: "${WS_PATH}"

  - name: vless-in-1
    type: vless
    listen: 127.0.0.1
    port: 9995
    users:
      - username: "1"
        uuid: "${UUID}"
    ws-path: "${WS_PATH1}"

  - name: vless-xhttp
    type: vless
    listen: 127.0.0.1
    port: 9994
    users:
      - username: "user1"
        uuid: "${UUID}"
        flow: xtls-rprx-vision
    xhttp-config:
      path: "${WS_PATH2}"
      mode: auto
EOF

    print_info "Mihomo listeners 写入：$INSTALL_DIR/nginx.yaml"
}

# ================================
# 3. 生成 Clash-Meta 客户端配置
# ================================
generate_clash_meta() {
    print_info "生成 Clash-Meta 客户端配置..."

    cat <<EOF > "$OUT_DIR/clash-meta.yaml"
proxies:
  - name: vmess-ws-tls
    type: vmess
    server: $DOMAIN_LOWER
    port: 443
    cipher: auto
    uuid: $UUID
    alterId: 0
    tls: true
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: $DOMAIN_LOWER
    servername: $DOMAIN_LOWER

  - name: vless-ws-tls
    type: vless
    server: $DOMAIN_LOWER
    port: 443
    uuid: $UUID
    tls: true
    network: ws
    ws-opts:
      path: "${WS_PATH1}"
      headers:
        Host: $DOMAIN_LOWER
    servername: $DOMAIN_LOWER

  - name: vless-xhttp
    type: vless
    server: $DOMAIN_LOWER
    port: 443
    uuid: $UUID
    flow: xtls-rprx-vision
    tls: true
    udp: true
    xhttp-config:
      path: "${WS_PATH2}"
      host: $DOMAIN_LOWER
      mode: auto
EOF

    print_info "Clash-Meta 配置写入：$OUT_DIR/clash-meta.yaml"
}

# ================================
# 4. 生成 Mihomo 客户端配置
# ================================
generate_mihomo_client() {
    print_info "生成 Mihomo 客户端配置..."

    cat <<EOF > "$OUT_DIR/mihomo-client.yaml"
proxies:
  - name: vmess-ws
    type: vmess
    server: $DOMAIN_LOWER
    port: 443
    uuid: $UUID
    alterId: 0
    cipher: auto
    tls: true
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: $DOMAIN_LOWER

  - name: vless-ws
    type: vless
    server: $DOMAIN_LOWER
    port: 443
    uuid: $UUID
    tls: true
    network: ws
    ws-opts:
      path: "${WS_PATH1}"
      headers:
        Host: $DOMAIN_LOWER

  - name: vless-xhttp
    type: vless
    server: $DOMAIN_LOWER
    port: 443
    uuid: $UUID
    flow: xtls-rprx-vision
    tls: true
    udp: true
    xhttp-config:
      path: "${WS_PATH2}"
      host: $DOMAIN_LOWER
      mode: auto
EOF

    print_info "Mihomo 客户端配置写入：$OUT_DIR/mihomo-client.yaml"
}

# ================================
# 5. 生成 v2rayN 链接（新 URL 格式）+ 二维码
# ================================
generate_v2rayn_links_and_qr() {
    print_info "生成 v2rayN 链接 & 二维码（新 URL 格式）..."

    # VMess WS TLS（新格式）
    local VMESS_WS_LINK="vmess://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&allowInsecure=1&type=ws&host=${DOMAIN_LOWER}&path=${WS_PATH}#vmess-ws-tls"

    # VLESS WS TLS
    local VLESS_WS_LINK="vless://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&type=ws&host=${DOMAIN_LOWER}&path=${WS_PATH1}#vless-ws-tls"

    # VLESS XHTTP
    local VLESS_XHTTP_LINK="vless://${UUID}@${DOMAIN_LOWER}:443?flow=xtls-rprx-vision&security=tls&type=xhttp&host=${DOMAIN_LOWER}&path=${WS_PATH2}#vless-xhttp"

    # 写入文本汇总
    cat <<EOF > "$OUT_DIR/v2rayN.txt"
===== VMess WS TLS =====
$VMESS_WS_LINK

===== VLESS WS TLS =====
$VLESS_WS_LINK

===== VLESS XHTTP =====
$VLESS_XHTTP_LINK
EOF

    # 生成二维码（base64 + PNG）
    generate_qr "$VMESS_WS_LINK"       "$OUT_DIR/vmess-ws"
    generate_qr "$VLESS_WS_LINK"       "$OUT_DIR/vless-ws"
    generate_qr "$VLESS_XHTTP_LINK"    "$OUT_DIR/vless-xhttp"

    print_info "v2rayN 链接写入：$OUT_DIR/v2rayN.txt"
    print_info "二维码 base64 输出："
    echo "  $OUT_DIR/vmess-ws.b64"
    echo "  $OUT_DIR/vless-ws.b64"
    echo "  $OUT_DIR/vless-xhttp.b64"
}

# ================================
# 6. 生成 Nginx 反代片段
# ================================
generate_nginx_snippet() {
    print_info "生成 Nginx 反代片段..."

    cat <<EOF > "$OUT_DIR/nginx.conf"
location ${WS_PATH} {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:9996;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
}

location ${WS_PATH1} {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:9995;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
}

location ${WS_PATH2} {
    proxy_request_buffering off;
    proxy_redirect off;
    proxy_pass http://127.0.0.1:9994;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOF

    print_info "Nginx 片段写入：$OUT_DIR/nginx.conf"
}

# ================================
# 7. 主流程
# ================================
main() {
    init_env
    generate_mihomo_listeners
    generate_clash_meta
    generate_mihomo_client
    generate_v2rayn_links_and_qr
    generate_nginx_snippet

    print_info "全部配置与客户端文件生成完成。"
    echo "输出目录：$OUT_DIR"
}

main "$@"
