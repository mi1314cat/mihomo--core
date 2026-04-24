#!/bin/bash

# ================================
# catmi.mihomo 主框架脚本
# ================================

BASE_DIR="/root/catmi/mihomo"
MOENV_FILE="$BASE_DIR/install_info.env"
CATMI_ENV="/root/catmi/catmi.env"

mkdir -p "$BASE_DIR"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

# ================================
# update_env（与 xray 脚本一致）             这里面用这个
# ================================
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
# ================================
# 1. 写入 catmi.env mode=mihomo
# ================================

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"
update_env $CATMIENV_FILE mode mihomo
load_env $CATMIENV_FILE

print_info "生成 mihomo 服务文件..."

bash <(curl -fsSL https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/conf/XRevise.sh)
bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh)

print_info "服务文件生成完成"


load_env $MOENV_FILE


INSTALL_DIR=$BASE_DIR/conf/config.d
# ================================
# 5. 预留：插件系统（inbounds/outbounds/rules）
# ================================
cat <<EOF > $INSTALL_DIR/nginx.yaml
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

OUT_DIR=$BASE_DIR/out
# ================================
# 6. 预留：config.yaml 构建器
# ================================
cat << EOF > $OUT_DIR/clash-meta.yaml
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
      path: ${WS_PATH}
      headers:
        Host: $DOMAIN_LOWER
    servername: $DOMAIN_LOWER
  - name: vless-ws-tls
    type: vless
    server: $DOMAIN_LOWER
    port: 443
    uuid: $UUID
    tls: true
    alterId: 0
    cipher: auto
    skip-cert-verify: true
    network: ws
    ws-opts:
      headers:
        Host: $DOMAIN_LOWER
      path: ${WS_PATH1}
    servername: $DOMAIN_LOWER
  - name: vless-xhttp
    type: vless
    server: $DOMAIN_LOWER
    port: 443
    uuid: "${UUID}"
    flow: xtls-rprx-vision
    tls: true
    udp: true
    xhttp-config:
      path: "${WS_PATH2}"
      host: $DOMAIN_LOWER
      mode: auto  
EOF


cat << EOF > "$INSTALL_DIR/nginx.json"
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
