#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 检查是否为root用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用root用户运行此脚本！\n" && exit 1

# 系统信息
SYSTEM_NAME=$(grep -i pretty_name /etc/os-release | cut -d \" -f2)
CORE_ARCH=$(arch)

# 介绍信息
clear
cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.mihomo
       -----------------------------------------
EOF
echo -e "${GREEN}System: ${PLAIN}${SYSTEM_NAME}"
echo -e "${GREEN}Architecture: ${PLAIN}${CORE_ARCH}"
echo -e "${GREEN}Version: ${PLAIN}1.0.0"
echo -e "----------------------------------------"

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

# 随机生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}
# 生成端口的函数
generate_port() {
    local protocol="$1"
    while :; do
        port=$((RANDOM % 10001 + 10000))
        read -p "请为 ${protocol} 输入监听端口(默认为随机生成): " user_input
        port=${user_input:-$port}
        ss -tuln | grep -q ":$port\b" || { echo "$port"; return $port; }
        echo "端口 $port 被占用，请输入其他端口"
    done
}
# 随机生成 WS 路径
generate_ws_path() {
    echo "/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)"
}
sudo apt update && sudo apt upgrade -y
sudo apt install ufw -y
sudo apt install -y curl socat git cron openssl gzip
INSTALL_DIR="/root/catmi/mihomo"
INSTALL_DIRs="/root/.config/mihomo"
mkdir -p $INSTALL_DIR
mkdir -p $INSTALL_DIRs

bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/mihomo-down.sh)




openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout $INSTALL_DIR/server.key -out $INSTALL_DIR/server.crt \
    -subj "/CN=bing.com" -days 36500 && \


mv $INSTALL_DIR/server.crt $INSTALL_DIRs/
mv $INSTALL_DIR/server.key $INSTALL_DIRs/

# 定义函数，返回随机选择的域名
random_website() {
   domains=(
        "one-piece.com"
        "lovelive-anime.jp"
        "swift.com"
        "academy.nvidia.com"
        "cisco.com"
        "amd.com"
        "apple.com"
        "music.apple.com"
        "fandom.com"
        "tidal.com"
        "mora.jp"
        "booth.pm"
        "leercapitulo.com"
        "itunes.apple.com"
        "download-installer.cdn.mozilla.net"
        "images-na.ssl-images-amazon.com"
        "swdist.apple.com"
        "swcdn.apple.com"
        "updates.cdn-apple.com"
        "mensura.cdn-apple.com"
        "osxapps.itunes.apple.com"
        "aod.itunes.apple.com"
        "www.google-analytics.com"
        "dl.google.com"
    )


    total_domains=${#domains[@]}
    random_index=$((RANDOM % total_domains))
    
    # 输出选择的域名
    echo "${domains[random_index]}"
}
# 生成密钥
read -rp "请输入回落域名: " dest_server
[ -z "$dest_server" ] && dest_server=$(random_website)


read -p "cdn域名: " DOMAIN_LOWER

# 提示输入监听端口号

PORT=${PORT:-443}
read -p "请输入 reality 监听端口: " reality_port
if [[ -z "$reality_port" ]]; then
    reality_port=$((RANDOM % 55535 + 10000))  # 生成 10000-65535 的随机端口
fi

hysteria2_port=$((reality_port + 1))
tuic_port=$((reality_port + 2))
anytls_port=$((reality_port + 3))
Vmess_port=$((reality_port + 4))

echo "已设置端口如下："
echo "reality:   $reality_port"
echo "hysteria2: $hysteria2_port"
echo "tuic:      $tuic_port"
echo "anytls:    $anytls_port"
echo "Vmess:    $Vmess_port"
# 生成 UUID 和 WS 路径
UUID=$(generate_uuid)
WS_PATH=$(generate_ws_path)
WS_PATH1=$(generate_ws_path)






key_pair=$($INSTALL_DIR/mihomo generate reality-keypair)
private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')

short_id=$(openssl rand -hex 8)
hy_password=$(openssl rand -hex 16)



# 获取公网 IP 地址
PUBLIC_IP_V4=$(curl -s https://api.ipify.org)
PUBLIC_IP_V6=$(curl -s https://api64.ipify.org)

# 选择使用哪个公网 IP 地址
echo "请选择要使用的公网 IP 地址:"
echo "1. $PUBLIC_IP_V4"
echo "2. $PUBLIC_IP_V6"
read -p "请输入对应的数字选择 [默认1]: " IP_CHOICE

# 如果没有输入（即回车），则默认选择1
IP_CHOICE=${IP_CHOICE:-1}

# 选择公网 IP 地址
if [ "$IP_CHOICE" -eq 1 ]; then
    PUBLIC_IP=$PUBLIC_IP_V4
    # 设置第二个变量为“空”
    VALUE=""
    link_ip="$PUBLIC_IP"
elif [ "$IP_CHOICE" -eq 2 ]; then
    PUBLIC_IP=$PUBLIC_IP_V6
    # 设置第二个变量为 "[::]:"
    VALUE="[::]:"
    link_ip="[$PUBLIC_IP]"
else
    echo "无效选择，退出脚本"
    exit 1
fi

# 配置文件生成

cat <<EOF > $INSTALL_DIR/config.yaml

listeners:


- name: anytls-in-1
  type: anytls
  port: $anytls_port
  listen: "::"
  users:
    username1: $hy_password
  certificate: $INSTALL_DIR/server.crt
  private-key: $INSTALL_DIR/server.key
  padding-scheme: |
   stop=8
   0=30-30
   1=100-400
   2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
   3=9-9,500-1000
   4=500-1000
   5=500-1000
   6=500-1000
   7=500-1000


- name: hy-in
  type: hysteria2
  port: $hysteria2_port
  listen: "::"
  users:
    user1: $hy_password
  ignore-client-bandwidth: false
  masquerade: ""
  alpn:
  - h3
  certificate: $INSTALL_DIR/server.crt
  private-key: $INSTALL_DIR/server.key
  
- name: reality
  type: vless
  port: $reality_port # 支持使用ports格式，例如200,302 or 200,204,401-429,501-503
  listen: "::"
  users:
    - username: 1
      uuid: $UUID
      flow: xtls-rprx-vision
  reality-config:
    dest: $dest_server:443
    private-key: $private_key # 可由 mihomo generate reality-keypair 命令生成
    short-id:
      - $short_id
    server-names:
      - $dest_server


- name: tuicv5-in
  type: tuic
  port: $tuic_port
  listen: "::"
  users:
    uuid: $UUID
    password: $hy_password
  certificate: $INSTALL_DIR/server.crt
  private-key: $INSTALL_DIR/server.key
  congestion-controller: bbr
  max-idle-time: 15000
  authentication-timeout: 1000
  alpn:
    - h3
  max-udp-relay-packet-size: 1500
   
- name: vmess-in-2
  type: vmess
  port: $Vmess_port
  listen: "::"
  users:
    - username: 1
      uuid: $UUID
      alterId: 1
  ws-path: "${WS_PATH}"
 
- name: vmess-in-1
  type: vmess
  port: 9999
  listen: 127.0.0.1
  users:
    - username: 1
      uuid: $UUID
      alterId: 1
  ws-path: "${WS_PATH}" 
  
- name: vless-in-1
  type: vless
  port: 9998
  listen: 127.0.0.1
  users:
    - username: 1
      uuid: $UUID
  ws-path: "${WS_PATH1}" # 如果不为空则开启 websocket 传输层   






EOF

# 重载systemd服务配置
sudo systemctl daemon-reload
sudo systemctl enable mihomo
sudo systemctl restart mihomo || { echo "重启 mihomo 服务失败"; exit 1; }




{
    echo "xray 安装完成！"
    echo "服务器地址：${PUBLIC_IP}"
    echo "IP_CHOICE：${IP_CHOICE}"
    echo "端口：${PORT}"
    echo "UUID：${UUID}"
    echo "vless WS 路径：${WS_PATH}"
    echo "vmess WS 路径：${WS_PATH1}"
    echo "配置文件已保存到：/etc/xrayls/config.json"
} > "/root/catmi/install_info.txt"





cat << EOF > $INSTALL_DIR/clash-meta.yaml
- name: Hysteria2
  server: $PUBLIC_IP
  port: $hysteria2_port
  type: hysteria2
  up: 40 Mbps
  down: 150 Mbps
  sni: bing.com
  password: $hy_password
  skip-cert-verify: true
  alpn:
    - h3
- name: Reality
  port: $reality_port
  server: $PUBLIC_IP
  type: vless
  network: tcp
  udp: true
  tls: true
  servername: $dest_server
  skip-cert-verify: true
  reality-opts:
    public-key: $public_key
    short-id: $short_id
  uuid: $UUID
  flow: xtls-rprx-vision
  client-fingerprint: chrome
- name: vmess-ws-tls
  type: vmess
  server: $PUBLIC_IP
  port: $Vmess_port
  cipher: auto
  uuid: $UUID
  alterId: 0
  tls: false
  network: ws
  ws-opts:
    path: ${WS_PATH1}
    headers: {}
- name: anytls
  type: anytls
  server: $PUBLIC_IP
  port: $anytls_port
  password: $UUID
  client-fingerprint: chrome
  udp: true
  idle-session-check-interval: 30
  idle-session-timeout: 30
  skip-cert-verify: true
- name: tuic
  type: tuic
  server: $PUBLIC_IP
  port: $tuic_port
  uuid: $UUID
  password: $hy_password
  alpn:
    - h3
  disable-sni: true
  reduce-rtt: true
  request-timeout: 8000
  udp-relay-mode: native
  congestion-controller: bbr
  skip-cert-verify: true
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
    path: ${WS_PATH1}
    headers:
      Host: $DOMAIN_LOWER
  servername: $DOMAIN_LOWER
- type: vless
  name: vless-ws-tls
  server: $DOMAIN_LOWER
  port: 443
  uuid: $UUID
  tls: true
  skip-cert-verify: true
  network: ws
  ws-opts:
    headers:
      Host: $DOMAIN_LOWER
    path: ${WS_PATH}
  servername: $DOMAIN_LOWER

EOF




share_link="
tuic://$UUID:$hy_password@$link_ip:$tuic_port?alpn=h3&congestion_control=bbr#tuic
hysteria2://$hy_password@$link_ip:$hysteria2_port??sni=bing.com&insecure=1#Hysteria2
vless://$UUID@$link_ip:$reality_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#Reality
vmess://$UUID@$link_ip:$Vmess_port?encryption=none&allowInsecure=1&type=ws&path=${WS_PATH1}#vmess-ws-tls
vless://$UUID@$DOMAIN_LOWER:443?encryption=none&security=tls&sni=$DOMAIN_LOWER&allowInsecure=1&type=ws&host=$DOMAIN_LOWER&path=${WS_PATH}#vless-ws-tls
vmess://$UUID@$DOMAIN_LOWER:443?encryption=none&security=tls&sni=$DOMAIN_LOWER&allowInsecure=1&type=ws&host=$DOMAIN_LOWER&path=${WS_PATH1}#vmess-ws-tls
"
echo "${share_link}" > $INSTALL_DIR/v2ray.txt



sudo systemctl status mihomo

cat $INSTALL_DIR/v2ray.txt
cat $INSTALL_DIR/clash-meta.yaml
