#!/usr/bin/env bash
# ==============================================================================
# mihomo-manager.sh — Mihomo Linux Bootstrap / Installer / Manager
# 内核: github.com/MetaCubeX/mihomo   UI: github.com/MetaCubeX/metacubexd (gh-pages)
#
# 原则：检测 → 备份 → 验证 → 修改 → 验证 → 失败回滚；重复运行安全；
#       安装不依赖服务器可访问 GitHub；不重写用户 config.yaml，只做最小补充。
# ==============================================================================
set -u -o pipefail

SCRIPT_NAME="mihomo-manager"
SCRIPT_VERSION="1.0.0"

DRYRUN=0
ASSUME_YES=0

if [ -t 1 ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_C=""; C_0=""
fi
info(){ echo "[*] $*"; }
ok(){   echo "${C_G}[ok]${C_0} $*"; }
warn(){ echo "${C_Y}[!]${C_0} $*"; }
err(){  echo "${C_R}[✗]${C_0} $*" >&2; }
die(){  err "$@"; exit 1; }

# 所有会真正修改系统的命令都经此执行；dry-run 下只打印
run_cmd(){
  if [ "$DRYRUN" = "1" ]; then
    echo "  [dry-run] $*"
    return 0
  fi
  "$@"
}

confirm(){
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi
  local reply
  read -r -p "$1 [y/N]: " reply
  case "$reply" in y|Y|yes) return 0;; *) return 1;; esac
}

pause(){ read -r -p "按回车继续..." _; }

# ==============================================================================
# 配置与路径
# ==============================================================================
CONF_FILE="${MIHOMO_MANAGER_CONF:-/root/catmi/mihomo-manager.conf}"

load_config(){
  if [ ! -f "$CONF_FILE" ]; then
    if [ "$DRYRUN" = "1" ]; then
      info "（dry-run）配置文件不存在，将生成 $CONF_FILE"
      INSTALL_DIR="/root/catmi"
    else
      cat > "$CONF_FILE" <<'CONF'
# mihomo-manager 配置（可手工编辑，脚本不覆盖你的修改）
INSTALL_DIR=/root/catmi
SERVICE_NAME=mihomo
UPLOAD_DIR=/root/catmi/mihomo-upload
CONFIG_FILE=/root/catmi/config.yaml
UI_DIR=/root/catmi/ui
UI_REPO=MetaCubeX/metacubexd
UI_BRANCH=gh-pages
# 服务器无法直连 GitHub 时填入本机可用代理，如 http://127.0.0.1:7890；留空=直连
MIHOMO_DOWNLOAD_PROXY=
# 备份保留份数
KEEP_BACKUPS=5
CONF
      chmod 600 "$CONF_FILE"
      ok "已生成配置文件：$CONF_FILE"
    fi
  fi
  # shellcheck source=/dev/null
  [ -f "$CONF_FILE" ] && . "$CONF_FILE"
}

apply_paths(){
  INSTALL_DIR="${INSTALL_DIR:-/root/catmi}"; INSTALL_DIR="${INSTALL_DIR%/}"
  SERVICE_NAME="${SERVICE_NAME:-mihomo}"
  BIN="$INSTALL_DIR/mihomo"
  CONFIG_FILE="${CONFIG_FILE:-$INSTALL_DIR/config.yaml}"
  UPLOAD_DIR="${UPLOAD_DIR:-$INSTALL_DIR/mihomo-upload}"
  UI_DIR="${UI_DIR:-$INSTALL_DIR/ui}"
  UI_REPO="${UI_REPO:-MetaCubeX/metacubexd}"
  UI_BRANCH="${UI_BRANCH:-gh-pages}"
  VERSION_FILE="$INSTALL_DIR/version.txt"
  BACKUP_DIR="$INSTALL_DIR/backup"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
  PROXY_PROFILE="/etc/profile.d/mihomo-proxy.sh"
  PROXY_CONF_FILE="${PROXY_CONF_FILE:-$INSTALL_DIR/mihomo-proxy.conf}"
  KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
  MIHOMO_DOWNLOAD_PROXY="${MIHOMO_DOWNLOAD_PROXY:-}"
  # ---- 兼容已有环境：从现有 systemd service 反推真实路径（不假设） ----
  discover_existing
}

# 读取现有 systemd service 的 ExecStart，从中提取 -f <配置> 与 -d <目录>、二进制路径；
# 仅当用户配置的路径不存在、且 service 里存在有效路径时才采纳（绝不覆盖用户显式配置）。
discover_existing(){
  [ "$DRYRUN" = "1" ] && true
  local exe cfgdir cfg ui
  # systemctl show 更稳（兼容别名/Drop-in/原 out service）
  exe="$(systemctl show "$SERVICE_NAME" -P ExecStart 2>/dev/null | sed -n 's/^[^ ]* \\([^;]*\\);.*/\\1/p' | head -n1)"
  [ -n "$exe" ] || exe="$(sed -n 's/^ExecStart=\([^#]*\)$/\1/p' "$SERVICE_FILE" 2>/dev/null | head -n1)"
  [ -n "$exe" ] || return 0
  # 解析参数中的路径
  cfg="$(printf '%s\n' "$exe" | sed -n 's/.*[[:space:]]-f[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | head -n1)"
  binary="$(printf '%s\n' "$exe" | awk '{print $1}' | head -n1)"
  # -d 工作目录
  cfgdir="$(printf '%s\n' "$exe" | sed -n 's/.*[[:space:]]-d[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | head -n1)"

  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
      warn "发现现有 service 实际使用配置文件：$cfg（脚本将沿用该路径）"
      CONFIG_FILE="$cfg"
    fi
  fi
  if [ -n "$binary" ] && [ -x "$binary" ]; then
    if [ ! -x "$BIN" ]; then
      warn "systemd 实际内核路径：$binary（脚本将沿用该路径）"
      BIN="$binary"
      [ -n "$cfgdir" ] || cfgdir="$(dirname "$binary")"
    fi
  fi
  # external-ui 实际目录从配置反推
  if [ -f "$CONFIG_FILE" ]; then
    ui="$(sed -n 's/^external-ui:[[:space:]]*\([^[:space:]]*\)/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n1)"
    if [ -n "$ui" ]; then
      case "$ui" in
        /*) : ;;
        *)  [ -n "$cfgdir" ] && ui="$cfgdir/$ui" ;;
      esac
      if [ -d "$ui" ]; then
        warn "external-ui 实际目录：$ui（脚本将沿用）"
        UI_DIR="$ui"
      fi
    fi
  fi
}

# ==============================================================================
# 基础工具
# ==============================================================================
now_ts(){ date +%Y%m%d-%H%M%S; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
require_root(){ [ "$(id -u)" -eq 0 ] || die "请以 root 运行"; }

# backup_file <文件> → 打印备份路径（stdout）；文件不存在则无输出
backup_file(){
  local src="$1" name
  [ -f "$src" ] || return 0
  name="$(basename "$src")+$(now_ts)"
  [ "$DRYRUN" = "1" ] || mkdir -p "$BACKUP_DIR"
  if [ "$DRYRUN" = "1" ]; then
    echo "  [dry-run] cp -a $src $BACKUP_DIR/$name"
    echo "$BACKUP_DIR/$name"
    return 0
  fi
  cp -a "$src" "$BACKUP_DIR/$name"
  echo "$BACKUP_DIR/$name"
}

prune_backups(){
  [ -d "$BACKUP_DIR" ] || return 0
  [ "$DRYRUN" = "1" ] && return 0
  ls -1t "$BACKUP_DIR" 2>/dev/null \
    | awk -v n="$KEEP_BACKUPS" -F'+' '{i[$1]++; if(i[$1]>n) print}' \
    | while read -r f; do rm -f -- "$BACKUP_DIR/$f"; done
}

# ==============================================================================
# 架构识别
# ==============================================================================
host_arch(){ uname -m; }

uname_to_asset(){
  case "$1" in
    x86_64|amd64)  echo "amd64";;
    aarch64|arm64) echo "arm64";;
    armv7?|armv7)  echo "armv7";;
    armv6?|armv6)  echo "armv6";;
    armv5*)        echo "armv5";;
    i386|i486|i586|i686) echo "386";;
    riscv64)       echo "riscv64";;
    loongarch64)   echo "loong64";;
    ppc64le)       echo "ppc64le";;
    s390x)         echo "s390x";;
    mips64le)      echo "mips64le";;
    mips64)        echo "mips64";;
    mipsle)        echo "mipsle";;
    mips)          echo "mips";;
    *)             echo "";;
  esac
}

asset_to_name(){
  case "$1" in
    amd64) echo "x86_64(amd64)";;
    arm64) echo "arm64";;
    armv7) echo "armv7";;
    armv6) echo "armv6";;
    armv5) echo "armv5";;
    386)   echo "386(i686)";;
    "")    echo "未知";;
    *)     echo "$1";;
  esac
}

# file 的 ELF 输出 → 架构关键字（识别真实架构）
elf_to_asset(){
  local t
  t="$(file -b "$1" 2>/dev/null || true)"
  case "$t" in
    *x86-64*)        echo "amd64";;
    *"Intel 80386"*) echo "386";;
    *aarch64*)       echo "arm64";;
    *"ARM, EABI5"*)  echo "armv7";;
    *loongarch*)     echo "loong64";;
    *mips64*)        echo "mips64";;
    *mips*)          echo "mips";;
    *riscv*)         echo "riscv64";;
    *ppc64*)         echo "ppc64le";;
    *"IBM S/390"*)   echo "s390x";;
    *)               echo "";;
  esac
}

check_arch_match(){
  local bin="$1" need got
  need="$(uname_to_asset "$(host_arch)")"
  [ -n "$need" ] || { err "不支持的系统架构: $(host_arch)"; return 1; }
  if ! need_cmd file; then
    warn "缺少 file 命令，无法做 ELF 架构校验，仅依赖运行测试验证"
    return 0
  fi
  got="$(elf_to_asset "$bin")"
  if [ -z "$got" ]; then
    err "无法识别二进制的 ELF 架构，拒绝安装。file 输出："
    file -b "$bin" 2>/dev/null | head -c 200
    echo ""
    return 1
  fi
  if [ "$got" != "$need" ]; then
    err "架构不匹配："
    err "  当前系统：$(asset_to_name "$need")（uname -m = $(host_arch)）"
    err "  上传内核：$(asset_to_name "$got")"
    err "请上传适用于当前系统的 Mihomo 内核。脚本拒绝覆盖现有 Mihomo。"
    return 1
  fi
  ok "架构校验通过: $(asset_to_name "$got")"
  return 0
}

# ==============================================================================
# 版本与健康检查
# ==============================================================================
core_version(){
  [ -x "$BIN" ] || { echo ""; return 0; }
  "$BIN" -v 2>/dev/null | head -n1 | sed -n 's/.*version \(v[0-9.][^ ]*\).*/\1/p'
}

service_is_active(){ systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; }

health_check(){
  local port sec auth=()
  port="$(grep -E '^external-controller:' "$CONFIG_FILE" 2>/dev/null | head -n1 \
            | sed -n 's/.*:\([0-9]\{2,5\}\).*/\1/p')"
  sec="$(grep -E '^secret:' "$CONFIG_FILE" 2>/dev/null | head -n1 \
            | sed -n "s/^[[:space:]]*secret:[[:space:]]*['\"]\{0,1\}\([A-Za-z0-9._-]\+\)['\"]\{0,1\}.*/\1/p")"
  [ -n "$sec" ] && auth=(-H "Authorization: Bearer $sec")
  if [ -n "$port" ] && need_cmd curl; then
    curl -fsS -m 5 "${auth[@]}" "http://127.0.0.1:$port/version" >/dev/null 2>&1 && return 0
  fi
  service_is_active
}

write_version_file(){
  local v="$1"
  [ -n "$v" ] || { warn "未获取到版本号，跳过 $VERSION_FILE"; return 1; }
  if [ "$DRYRUN" = "1" ]; then
    echo "  [dry-run] echo $v > $VERSION_FILE"
    return 0
  fi
  echo "$v" > "$VERSION_FILE"
}

# ==============================================================================
# systemd service
# ==============================================================================
render_service_config(){
  cat <<EOF
[Unit]
Description=Mihomo Service (MetaCubeX mihomo core)
Documentation=https://wiki.metacubex.one
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -f $CONFIG_FILE -d $INSTALL_DIR
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

install_service(){
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "配置文件尚不存在：$CONFIG_FILE"
    if [ "$DRYRUN" != "1" ]; then
      if ! confirm "继续安装 service？首次启动可能失败（可先创建配置骨架）"; then
        return 0
      fi
    fi
  fi
  if [ -f "$SERVICE_FILE" ]; then
    warn "systemd service 已存在：$SERVICE_FILE"
    echo "-----------------------------------------------------------"
    systemctl cat "$SERVICE_NAME" 2>/dev/null | sed -n '1,40p' || cat "$SERVICE_FILE"
    echo "-----------------------------------------------------------"
    echo "本脚本模板将使用："
    echo "  ExecStart=$BIN -f $CONFIG_FILE -d $INSTALL_DIR  (Restart=on-failure)"
    if ! confirm "备份现有 service 并用模板接管？"; then
      warn "沿用现有 service"
      return 0
    fi
    local bak
    bak="$(backup_file "$SERVICE_FILE")"
    [ -n "$bak" ] && ok "已备份 → $bak"
  fi
  render_service_config | run_cmd tee "$SERVICE_FILE" >/dev/null
  if [ "$DRYRUN" != "1" ]; then chmod 644 "$SERVICE_FILE"; fi
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable "$SERVICE_NAME"
  ok "service 已安装/更新"
}

# ==============================================================================
# config.yaml 最小补充
# ==============================================================================
has_conf(){ grep -Eq "^${1}:[[:space:]]" "$CONFIG_FILE" 2>/dev/null; }
get_conf(){ sed -n "s/^${1}:[[:space:]]*//p" "$CONFIG_FILE" 2>/dev/null | head -n1; }

config_ensure(){
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "配置文件不存在：$CONFIG_FILE"
    if confirm "创建最小可用骨架（之后请导入你自己的 proxies/groups/rules）？"; then
      run_cmd tee "$CONFIG_FILE" >/dev/null <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
unified-delay: true
external-controller: 127.0.0.1:9090
secret: ''
external-ui: $UI_DIR
EOF
      ok "已创建 $CONFIG_FILE"
    fi
    return 0
  fi

  info "检查配置：$CONFIG_FILE"
  local bak tmp changed=0 val
  bak="$(backup_file "$CONFIG_FILE")"
  [ -n "$bak" ] && [ -f "$bak" ] && ok "已备份 → $bak"
  tmp="$(mktemp -t mihomo-cfg-XXXXXX)"
  cp -f "$CONFIG_FILE" "$tmp"

  # external-ui（缺失才加；存在则尊重现有值）
  if has_conf external-ui; then
    val="$(get_conf external-ui)"
    if [ "$val" != "$UI_DIR" ] && [ -n "$val" ]; then
      warn "external-ui 现值 '$val' ≠ 脚本默认 '$UI_DIR' —— 尊重现有配置，不修改；UI 将部署/检查该现值目录"
      [ -d "$val" ] && UI_DIR="$val"
    fi
  else
    if [ "$DRYRUN" = "1" ]; then
      echo "  [dry-run] 追加 external-ui: $UI_DIR"
    else
      echo "external-ui: $UI_DIR" >> "$tmp"
      changed=1
      ok "已追加缺失字段：external-ui: $UI_DIR"
    fi
  fi

  # external-controller（缺失才加；0.0.0.0 只做安全提示，不擅改）
  if has_conf external-controller; then
    val="$(get_conf external-controller)"
    case "$val" in
      0.0.0.0:*|'*:'*|':::'*|'[::]:*')
        warn "external-controller = $val → RESTful API 监听所有网卡（公网可达）"
        if has_conf secret && [ -n "$(get_conf secret)" ]; then
          warn "  已配置 secret；请保持密码强度并配置防火墙限制访问来源网段（官方建议 wiki.metacubex.one/cn/config/general）"
        else
          warn "  未配置 secret —— 【重大安全风险】任何知道 IP 的人都能控制内核/修改代理！"
          warn "  建议手工执行: 执行 'openssl rand -hex 16' 取值，在 $CONFIG_FILE 中添加"
          warn "    secret: \"<生成的值>\""
          warn "  服务重启后 MetaCubeXD 登录该前端需要输入该 secret。"
        fi
        ;;
      *) : ;;
    esac
  else
    if [ "$DRYRUN" = "1" ]; then
      echo "  [dry-run] 追加 external-controller: 127.0.0.1:9090"
    else
      echo "external-controller: 127.0.0.1:9090" >> "$tmp"
      changed=1
      ok "已追加缺失字段：external-controller: 127.0.0.1:9090（仅本机，安全默认）"
    fi
  fi

  # unified-delay（缺失才加，不强改已有值）
  if ! has_conf unified-delay; then
    if [ "$DRYRUN" = "1" ]; then
      echo "  [dry-run] 追加 unified-delay: true"
    else
      echo "unified-delay: true" >> "$tmp"
      changed=1
      ok "已追加缺失字段：unified-delay: true"
    fi
  fi

  if [ "$changed" = "1" ]; then
    cat "$tmp" > "$CONFIG_FILE"
    ok "配置按最小修改原则更新（你的 proxies/groups/rules/DNS/TUN 原样保留）"
  else
    ok "配置无需修改"
  fi
  rm -f "$tmp"

  if [ -x "$BIN" ] && [ "$DRYRUN" != "1" ]; then
    if "$BIN" -f "$CONFIG_FILE" -t >/dev/null 2>&1; then
      ok "配置语法验证通过（mihomo -t）"
    else
      err "配置语法验证失败："
      "$BIN" -f "$CONFIG_FILE" -t 2>&1 | head -n 12
      return 1
    fi
  fi
}

# ==============================================================================
# UI（MetaCubeXD gh-pages）
# ==============================================================================
backup_dir_now(){
  local d="$1" tag="$2" dest
  dest="$BACKUP_DIR/${tag}+$(now_ts)"
  mkdir -p "$BACKUP_DIR"
  cp -a "$d" "$dest" && echo "$dest"
}

ui_install(){
  [ "$DRYRUN" = "1" ] || [ -d "$UI_DIR" ] || mkdir -p "$UI_DIR"
  if [ -n "$(ls -A "$UI_DIR" 2>/dev/null)" ]; then
    ok "UI 目录已存在: $UI_DIR（更新前会先备份）"
  fi
  if ! need_cmd unzip; then
    die "缺少 unzip，无法部署 UI（Debian: apt install unzip）"
  fi
  if [ "$DRYRUN" = "1" ]; then
    echo "  [dry-run] 下载 https://github.com/$UI_REPO/archive/refs/heads/$UI_BRANCH.zip 并解压到 $UI_DIR"
    return 0
  fi
  local url="https://github.com/$UI_REPO/archive/refs/heads/$UI_BRANCH.zip"
  local tmpzip tmpout inner oldbak
  tmpzip="$(mktemp -t mihomo-ui-XXXXXX.zip)"
  tmpout="$(mktemp -d -t mihomo-ui-XXXXXX)"
  info "下载官方 gh-pages: $url"
  if curl -fsSL --connect-timeout 10 -m 300 ${MIHOMO_DOWNLOAD_PROXY:+-x "$MIHOMO_DOWNLOAD_PROXY"} \
       -o "$tmpzip" "$url"; then
    :
  else
    err "UI 下载失败（可能无法访问 GitHub）。"
    err "  · 检查/填写 $CONF_FILE 中 MIHOMO_DOWNLOAD_PROXY"
    err "  · 或手工在能联网设备下载该 zip，解压后把内层目录内容拷贝到 $UI_DIR"
    rm -f "$tmpzip"; rm -rf "$tmpout"; return 1
  fi
  unzip -q -o "$tmpzip" -d "$tmpout" || { err "UI 解压失败"; rm -f "$tmpzip"; rm -rf "$tmpout"; return 1; }
  inner="$(find "$tmpout" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [ -z "$inner" ] || [ ! -f "$inner/index.html" ]; then
    err "zip 内容异常（未找到 index.html）"
    rm -f "$tmpzip"; rm -rf "$tmpout"; return 1
  fi
  if [ -n "$(ls -A "$UI_DIR" 2>/dev/null)" ]; then
    oldbak="$(backup_dir_now "$UI_DIR" ui)"
    [ -n "$oldbak" ] && ok "已备份现有 UI → $oldbak"
  fi
  find "$UI_DIR" -mindepth 1 -delete
  cp -a "$inner/." "$UI_DIR/"
  rm -f "$tmpzip"; rm -rf "$tmpout"
  prune_backups
  ok "MetaCubeXD 已部署到 $UI_DIR（访问 http://<external-controller>/ui/）"
}

# ==============================================================================
# 内核安装（验证后替换 + 失败回滚）
# ==============================================================================
install_core_from_path(){
  local cand="$1" ver="$2" bak was_active=0
  [ -f "$cand" ] || { err "候选二进制不存在：$cand"; return 1; }
  if service_is_active; then was_active=1; fi
  if [ -f "$BIN" ]; then
    bak="$(backup_file "$BIN")"
    [ -n "$bak" ] && ok "已备份当前内核 → $bak"
  fi

  if [ "$DRYRUN" = "1" ]; then
    echo "  [dry-run] systemctl stop $SERVICE_NAME (若在运行)"
    echo "  [dry-run] install -m 755 $cand $BIN"
    echo "  [dry-run] systemctl start $SERVICE_NAME"
  else
    if [ "$was_active" = "1" ]; then systemctl stop "$SERVICE_NAME" || warn "停止服务失败"; fi
    install -m 755 "$cand" "$BIN" \
      || { err "替换内核失败"; rollback_core "$bak" "$was_active"; return 1; }
    if ! systemctl start "$SERVICE_NAME"; then
      err "服务启动失败，自动回滚"
      rollback_core "$bak" "$was_active"; return 1
    fi
    sleep 2
    if ! health_check; then
      err "健康检查未通过，自动回滚"
      rollback_core "$bak" "$was_active"; return 1
    fi
  fi

  write_version_file "$ver"
  prune_backups
  ok "内核 $ver 已安装并健康运行"
}

rollback_core(){
  local bak="$1" was_active="$2"
  if [ -n "${bak:-}" ] && [ -f "$bak" ]; then
    warn "回滚：$bak → $BIN"
    install -m 755 "$bak" "$BIN"
  else
    err "无可用备份，无法自动回滚，请手工处理 $BIN"
  fi
  if [ "$was_active" = "1" ]; then
    systemctl start "$SERVICE_NAME"
  fi
}

# 解压发行包；stdout 输出二进制路径
extract_distarchive(){
  local src="$1" tmp cand mime
  tmp="$(mktemp -d -t mihomo-x-XXXXXX)"
  mime="$(file -b --mime-type "$src" 2>/dev/null)"
  if [ "$mime" = "application/gzip" ] || [ "$mime" = "application/x-gzip" ]; then
    cp -f "$src" "$tmp/pkg.gz"
    gunzip -f "$tmp/pkg.gz" || { err "gunzip 失败"; rm -rf "$tmp"; return 1; }
    if tar -tf "$tmp/pkg" >/dev/null 2>&1; then
      tar -xf "$tmp/pkg" -C "$tmp" || { rm -rf "$tmp"; return 1; }
      rm -f "$tmp/pkg"
    fi
  elif [ "$mime" = "application/zip" ]; then
    unzip -q -o "$src" -d "$tmp" || { rm -rf "$tmp"; return 1; }
  else
    err "无法识别压缩包（$mime）。Linux 官方发布推荐 .gz（gzip 包单个内核文件）。"
    rm -rf "$tmp"; return 1
  fi
  cand="$(find "$tmp" -type f -name 'mihomo*' 2>/dev/null | head -n1)"
  [ -z "$cand" ] && cand="$(find "$tmp" -type f -size +5M 2>/dev/null | head -n1)"
  if [ -z "$cand" ]; then
    err "解压后未找到 mihomo 二进制"
    rm -rf "$tmp"; return 1
  fi
  chmod +x "$cand" 2>/dev/null
  echo "$cand"
  # 注意：调用方使用该校验后应自行删除该临时目录；这里把目录路径也回显
}

# ==============================================================================
# 上传包导入
# ==============================================================================
import_install(){
  if [ ! -d "$UPLOAD_DIR" ]; then
    if [ "$DRYRUN" = "1" ]; then
      info "（dry-run）将创建上传目录：$UPLOAD_DIR"
    else
      mkdir -p "$UPLOAD_DIR"; warn "已创建上传目录：$UPLOAD_DIR"
    fi
  fi
  info "扫描上传目录：$UPLOAD_DIR"
  local -a cands=()
  local line
  while IFS= read -r line; do
    cands+=( "$line" )
  done < <(find "$UPLOAD_DIR" -maxdepth 1 -type f ! -name '.*' \
             \( -name '*.gz' -o -name '*.tgz' -o -name '*.tar.gz' -o -name '*.zip' \) \
             -size +1M 2>/dev/null | sort)

  if [ "${#cands[@]}" -eq 0 ]; then
    warn "上传目录为空。把官方 Release 的 mihomo-linux-XXX-vX.Y.Z.gz 放入该目录即可。"
    info "官方下载: https://github.com/MetaCubeX/mihomo/releases/latest"
    info "当前系统: $(asset_to_name "$(uname_to_asset "$(host_arch)")")（uname -m = $(host_arch)）"
    return 1
  fi

  local pick i c chosen cand ver vline
  if [ "${#cands[@]}" -gt 1 ]; then
    warn "检测到 ${#cands[@]} 个候选包："
    i=1
    for c in "${cands[@]}"; do
      printf '  %2d) %-55s %s\n' "$i" "$(basename "$c")" "$(du -h "$c" | cut -f1)"
      i=$((i+1))
    done
    read -r -p "请输入序号 1-${#cands[@]}（回车取消）: " pick
    [ -n "$pick" ] || { warn "已取消"; return 1; }
    case "$pick" in *[!0-9]*|'') err "输入无效"; return 1;; esac
    [ "$pick" -ge 1 ] && [ "$pick" -le "${#cands[@]}" ] || { err "序号越界"; return 1; }
  else
    pick=1
  fi
  chosen="${cands[$((pick-1))]}"
  ok "选择: $(basename "$chosen")"

  cand="$(extract_distarchive "$chosen")" || return 1
  info "找到内核二进制：$cand"
  if ! check_arch_match "$cand"; then
    err "架构不匹配，已中止导入（原包保留在 $UPLOAD_DIR，方便换文件）"
    return 1
  fi
  vline="$("$cand" -v 2>/dev/null | head -n1)"
  if [ -z "$vline" ]; then
    err "无法执行该二进制（mihomo -v 无输出）"
    return 1
  fi
  ver="$(printf '%s' "$vline" | sed -n 's/.*version \(v[0-9.][^ ]*\).*/\1/p')"
  ok "内核自检：$vline"
  ok "识别版本：${ver:-未知}"
  install_core_from_path "$cand" "$ver"
  rm -f "$cand"
}

# ==============================================================================
# 自动下载更新
# ==============================================================================
asset_candidates(){
  # 输出候选文件名，从优到普通（compatible 在所有 x86_64 上都能跑）
  local arch="$1" tag="$2"
  case "$arch" in
    amd64)   printf '%s\nmihomo-linux-amd64-%s.gz\n' "mihomo-linux-amd64-compatible-$tag.gz" "$tag" ;;
    arm64)   echo "mihomo-linux-arm64-$tag.gz" ;;
    armv7)   echo "mihomo-linux-armv7-$tag.gz" ;;
    armv6)   echo "mihomo-linux-armv6-$tag.gz" ;;
    armv5)   echo "mihomo-linux-armv5-$tag.gz" ;;
    386)     echo "mihomo-linux-386-$tag.gz" ;;
    riscv64) echo "mihomo-linux-riscv64-$tag.gz" ;;
    loong64) echo "mihomo-linux-loong64-abi2-$tag.gz" ;;
    *)       : ;;
  esac
}

download_update(){
  local arch tag cur file dest cand ver vline url ret=1
  local -a curlpx=( )
  arch="$(uname_to_asset "$(host_arch)")"
  [ -n "$arch" ] || { err "架构 $(host_arch) 未纳入自动下载，请使用导入流程"; return 1; }
  cur="$(core_version)"

  info "获取最新 Release 信息..."
  # 也兼顾 curl 参数复用（数组，避免 word-split）
  [ -n "$MIHOMO_DOWNLOAD_PROXY" ] && curlpx=( -x "$MIHOMO_DOWNLOAD_PROXY" )
  tag="$(curl "${curlpx[@]}" \
         -fsSL --connect-timeout 10 -m 20 "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
         | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4)"
  if [ -z "$tag" ]; then
    # API 失败时用 releases/latest 重定向兜底
    tag="$(curl "${curlpx[@]}" \
           -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 10 -m 20 \
           "https://github.com/MetaCubeX/mihomo/releases/latest" 2>/dev/null | sed -n 's|.*/tag/||p')"
  fi
  [ -n "$tag" ] || { err "无法获取最新版本（代理不可用或 GitHub 被封锁）。可改用导入流程（上传安装包到 $UPLOAD_DIR）。"; return 1; }
  ok "最新 Release: $tag"

  if [ -n "$cur" ] && [ "$cur" = "$tag" ]; then
    ok "当前已是最新版本 $cur"
    return 0
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    url="https://github.com/MetaCubeX/mihomo/releases/download/$tag/$file"
    info "下载: $file"
    dest="$(mktemp -t mihomo-dl-XXXXXX.gz)"
    if ! curl "${curlpx[@]}" -fSL --connect-timeout 10 -m 900 -o "$dest" "$url"; then
      warn "下载失败: $file"; rm -f "$dest"; continue
    fi
    cand="$(extract_distarchive "$dest")" || { rm -f "$dest"; continue; }
    rm -f "$dest"
    if ! check_arch_match "$cand"; then warn "架构不匹配: $file"; rm -f "$cand"; continue; fi
    vline="$("$cand" -v 2>/dev/null | head -n1)"
    ver="$(printf '%s' "$vline" | sed -n 's/.*version \(v[0-9.][^ ]*\).*/\1/p')"
    ok "验证通过：$vline"
    install_core_from_path "$cand" "$ver" && ret=0
    rm -f "$cand"
    break
  done < <(asset_candidates "$arch" "$tag")

  if [ "$ret" != "0" ]; then
    err "所有候选文件下载均失败。现有内核未受影响。"
    err "可把官方 .gz 上传到 $UPLOAD_DIR 后使用导入功能。"
  fi
  return $ret
}

# ==============================================================================
# 系统代理管理
# ==============================================================================
proxy_conf_write(){
  local http="$1" https="$2" socks="$3"
  {
    echo "# 由 $SCRIPT_NAME 于 $(now_ts) 生成"
    echo "http_proxy=$http";      echo "HTTP_PROXY=$http"
    echo "https_proxy=$https";    echo "HTTPS_PROXY=$https"
    [ -n "$socks" ] && { echo "all_proxy=$socks"; echo "ALL_PROXY=$socks"; }
    echo "no_proxy=localhost,127.0.0.1,::1"; echo "NO_PROXY=localhost,127.0.0.1,::1"
    echo "export http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY"
  } > "$PROXY_CONF_FILE"
  chmod 644 "$PROXY_CONF_FILE"
}

proxy_enable(){
  local http="${1:-}" https="${2:-}" socks="${3:-}"
  if [ -z "$http" ]; then
    read -r -p "HTTP  Proxy (如 http://192.168.1.178:10809 或 http://127.0.0.1:7890): " http
    [ -n "$http" ] || { err "HTTP Proxy 不能为空"; return 1; }
    [ -n "$https" ] || https="$http"
  else
    [ -n "$https" ] || https="$http"
  fi
  [ -n "$socks" ] || true

  # 冲突/幂等检测
  if [ -f "$PROXY_CONF_FILE" ]; then
    local old_http old_https old_socks identical=1
    old_http="$(grep -E '^http_proxy=' "$PROXY_CONF_FILE" | head -n1 | cut -d= -f2-)"
    old_https="$(grep -E '^https_proxy=' "$PROXY_CONF_FILE" | head -n1 | cut -d= -f2-)"
    old_socks="$(grep -E '^all_proxy=' "$PROXY_CONF_FILE" | head -n1 | cut -d= -f2-)"
    [ "$old_http" = "$http" ] && [ "$old_https" = "$https" ] && [ "${old_socks:-}" = "$socks" ] || identical=0
    if [ "$identical" = "1" ]; then
      ok "系统代理已为相同值（幂等，不重复写入）"
      # shellcheck source=/dev/null
      . "$PROXY_CONF_FILE"
      export http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
      return 0
    fi
    warn "更新已存在的 $PROXY_CONF_FILE："
    warn "  旧 http_proxy=$old_http  新 http_proxy=$http"
    warn "  旧 https_proxy=$old_https 新 https_proxy=$https"
    warn "  旧 all_proxy=$old_socks 新 all_proxy=$socks"
    confirm "确认更新？" || { warn "未做修改"; return 1; }
  fi
  local others
  others="$(detect_other_proxy_sources || true)"
  if [ -n "$others" ]; then
    warn "⚠ 检测到系统里还有其他进程/配置在设置代理环境变量："
    printf '%s\n' "$others" | sed 's/^/    /'
    warn "说明：bash 登录先加载 /etc/profile.d（含本工具配置），再加载 ~/.bashrc 等——"
    warn "  若其他来源最后赋值，将覆盖本工具的代理变量（对本 shell 与新 shell 均如此）。"
    warn "  这些文件本工具【不会修改】。若确定要本工具代理生效，可自行注释掉上述来源里的 proxy 行，"
    warn "  或让本工具使用与其他工具相同的端口从而值一致、互不冲突。"
    confirm "仍要继续启用本工具的系统代理？" || { warn "已放弃（未写入任何内容）"; return 1; }
  fi

  proxy_conf_write "$http" "$https" "$socks"

  if [ "$DRYRUN" = "1" ]; then
    echo "  [dry-run] 写入 $PROXY_PROFILE: [ -f '$PROXY_CONF_FILE' ] && . '$PROXY_CONF_FILE'"
    return 0
  fi
  if [ -f "$PROXY_PROFILE" ] && ! grep -q "mihomo-proxy.conf" "$PROXY_PROFILE"; then
    warn "$PROXY_PROFILE 已存在但非本脚本管理，为避免覆盖他人配置，中止。请手工合并。"
    return 1
  fi
  mkdir -p /etc/profile.d
  cat > "$PROXY_PROFILE" <<EOF
# managed by $SCRIPT_NAME — 由 mihomo-manager 系统代理功能开启/关闭
[ -f "$PROXY_CONF_FILE" ] && . "$PROXY_CONF_FILE"
EOF
  chmod 644 "$PROXY_PROFILE"
  # shellcheck source=/dev/null
  . "$PROXY_CONF_FILE"
  export http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
  ok "系统代理已启用（$PROXY_PROFILE 引用 $PROXY_CONF_FILE）"
  info "  新登录 shell 自动生效；当前已打开的其他 shell 请执行: source $PROXY_CONF_FILE"
  info "  已写入小写 + 大写两套变量，兼容不同程序读取习惯"
}

proxy_disable(){
  if [ "$DRYRUN" = "1" ]; then
    echo "  [dry-run] 删除 $PROXY_CONF_FILE 和 $PROXY_PROFILE"
    return 0
  fi
  if [ -f "$PROXY_CONF_FILE" ]; then
    rm -f "$PROXY_CONF_FILE"
    ok "已删除 $PROXY_CONF_FILE"
  else
    warn "$PROXY_CONF_FILE 不存在（可能未启用）"
  fi
  if [ -f "$PROXY_PROFILE" ] && grep -q "mihomo-proxy.conf" "$PROXY_PROFILE"; then
    rm -f "$PROXY_PROFILE"
    ok "已删除 $PROXY_PROFILE"
  elif [ -f "$PROXY_PROFILE" ]; then
    warn "$PROXY_PROFILE 非本脚本生成，保留不动"
  fi
  unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null
  ok "系统代理已关闭。新登录 shell / 重启后即恢复未配置状态。"
}

proxy_status(){
  echo "HTTP_PROXY    : ${HTTP_PROXY:-${http_proxy:-（未设置）}}"
  echo "HTTPS_PROXY   : ${HTTPS_PROXY:-${https_proxy:-（未设置）}}"
  echo "ALL_PROXY     : ${ALL_PROXY:-${all_proxy:-（未设置）}}"
  echo "当前 shell 是 : $([ -n "${http_proxy:-}" ] && echo '生效(本 shell)' || echo '未生效(本 shell 未导入)')"
  echo "配置文件      : $PROXY_CONF_FILE $([ -f "$PROXY_CONF_FILE" ] && echo '(启用√)' || echo '(未启用)')"
  echo "profile.d 入口: $PROXY_PROFILE $([ -f "$PROXY_PROFILE" ] && echo '(存在√)' || echo '(不存在)')"
  if [ -f "$PROXY_CONF_FILE" ]; then
    echo "---- $PROXY_CONF_FILE ----"
    cat "$PROXY_CONF_FILE"
  fi
}

proxy_cli(){
  case "${1:-status}" in
    on|set)  shift 2>/dev/null || true; proxy_enable "${1:-}" "${2:-}" "${3:-}" ;;
    off)     proxy_disable ;;
    status)  proxy_status ;;
    *)       echo "用法: $SCRIPT_NAME proxy on|off|status"; echo "  on 提示输入或 proxy on <http> <https> <socks>" ;;
  esac
}

# ==============================================================================
# 检查 / 状态 / 日志 / 备份
# ==============================================================================
check_all(){
  local v
  echo "--- 内核 ---"
  if [ -x "$BIN" ]; then
    v="$("$BIN" -v 2>/dev/null | head -n1)"
    ok "$v"
  else
    err "内核不存在：$BIN"
  fi
  echo "--- 架构 ---"
  echo "  系统: $(asset_to_name "$(uname_to_asset "$(host_arch)")")"
  [ -x "$BIN" ] && need_cmd file && echo "  内核实际: $(file -b "$BIN" | head -c 120)"
  echo "--- 配置 ---"
  if [ -f "$CONFIG_FILE" ]; then
    grep -nE '^(external-ui|external-controller|unified-delay|secret):' "$CONFIG_FILE"
    [ "$DRYRUN" != "1" ] && [ -x "$BIN" ] && \
      "$BIN" -f "$CONFIG_FILE" -t >/dev/null 2>&1 && ok "配置语法验证通过" \
      || warn "配置语法验证失败（见菜单 config）"
  else
    warn "配置文件不存在"
  fi
  echo "--- systemd ---"
  if systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | head -n 8; then :; fi
  echo "--- UI ---"
  [ -f "$UI_DIR/index.html" ] && ok "MetaCubeXD 已安装: $UI_DIR" || warn "UI 未安装"
  echo "--- 系统代理 ---"
  proxy_status_head
}

proxy_status_head(){
  echo "  HTTP_PROXY=${HTTP_PROXY:-${http_proxy:-}}  HTTPS_PROXY=${HTTPS_PROXY:-${https_proxy:-}}  ALL_PROXY=${ALL_PROXY:-${all_proxy:-}}"
  echo "  本工具配置: $PROXY_CONF_FILE $([ -f "$PROXY_CONF_FILE" ] && echo 已在启用 || echo 未启用)"
  echo "  系统其他代理来源（本工具不修改它们，仅检测报告）:"
  local found=0
  found="$(detect_other_proxy_sources)" || true
  if [ -n "$found" ]; then
    printf '%s\n' "$found" | sed 's/^/    /'
  else
    echo "    (未检测到其他来源)"
  fi
}

# 扫描常见 shell 配置里对 *_proxy 的赋值，输出形如 "路径:行号: 内容"
detect_other_proxy_sources(){
  local pat='(^|[[:space:]])(export[[:space:]]+)?(http_proxy|https_proxy|all_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY)='
  {
    grep -nE "$pat" /etc/profile 2>/dev/null
    grep -nE "$pat" /etc/profile.d/*.sh 2>/dev/null | grep -v "profile.d/$(basename "$PROXY_PROFILE"):"
    grep -nE "$pat" /etc/environment ~/.bashrc ~/.profile ~/.bash_profile 2>/dev/null
  } | sed "s|$HOME|~|2" | sort -u
}

proxy_status(){ proxy_status_head; }

show_status_full(){
  local v
  v="$(core_version)"
  echo "── Mihomo 状态 ─────────────────────────"
  if service_is_active; then
    echo "${C_G}● 运行中${C_0}    版本: ${C_C}${v:-未知}${C_0}    架构: $(asset_to_name "$(uname_to_asset "$(host_arch)")")"
  else
    echo "${C_R}● 未运行${C_0}    版本: ${C_C}${v:-未知}${C_0}    架构: $(asset_to_name "$(uname_to_asset "$(host_arch)")")"
  fi
  echo "  内核    : $BIN"
  echo "  配置    : $CONFIG_FILE $([ -f "$CONFIG_FILE" ] || echo 缺失)"
  echo "  UI      : $( [ -f "$UI_DIR/index.html" ] && echo 已安装 || echo 未安装 )  ($UI_DIR)"
  echo "  service : $SERVICE_FILE $([ -f "$SERVICE_FILE" ] && echo 存在 || echo 缺失)"
  [ -f "$VERSION_FILE" ] && echo "  version.txt: $(cat "$VERSION_FILE")"
  echo "  系统代理: $([ -f "$PROXY_CONF_FILE" ] && echo 已启用 || echo 未启用)"
  echo "  最近日志 :"
  journalctl -u "$SERVICE_NAME" -n 5 --no-pager -q 2>/dev/null | sed 's/^/    /'
}

backup_menu(){
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    info "备份目录为空：$BACKUP_DIR"; pause; return 0
  fi
  echo "可用备份（新→旧）："
  ls -1t "$BACKUP_DIR" | head -n "$KEEP_BACKUPS" | nl
  local b
  read -r -p "输入要回滚的完整文件名（回车取消）: " b
  [ -n "$b" ] || return 0
  local src="$BACKUP_DIR/$b"
  if [ ! -f "$src" ]; then err "文件不存在"; return 1; fi
  [ -f "$SERVICE_FILE" ] && confirm "确认执行回滚？会覆盖当前对应文件/重启服务。" || return 0
  case "$b" in
    mihomo.service+*)
      cp -a "$src" "$SERVICE_FILE"; systemctl daemon-reload
      systemctl restart "$SERVICE_NAME" 2>/dev/null; ok "已恢复 service";;
    config.yaml+*)
      cp -a "$src" "$CONFIG_FILE"; ok "已恢复 config.yaml（如需请 restart）";;
    mihomo+*)
      cp -a "$src" "$BIN"; chmod 755 "$BIN"; systemctl restart "$SERVICE_NAME"; ok "已恢复内核并重启";;
    ui+*)
      rm -rf "$UI_DIR" && cp -a "$src" "$UI_DIR"; ok "已恢复 UI";;
    *) err "未识别的备份类型，请手工恢复";;
  esac
}

# ==============================================================================
# 交互菜单
# ==============================================================================
show_dashboard(){
  local v
  v="$(core_version)"
  if service_is_active; then
    echo "${C_G}● 运行中${C_0}  版本: ${C_C}${v:-未知}${C_0}  架构: $(asset_to_name "$(uname_to_asset "$(host_arch)")")"
  else
    echo "${C_R}● 未运行${C_0}  版本: ${C_C}${v:-未知}${C_0}  架构: $(asset_to_name "$(uname_to_asset "$(host_arch)")")"
  fi
  echo "  内核 : $BIN"
  echo "  配置 : $CONFIG_FILE $([ -f "$CONFIG_FILE" ] && echo ✓ || echo ✗)"
  echo "  UI   : $( [ -f "$UI_DIR/index.html" ] && echo 已安装 || echo 未安装 )"
  echo "  系统代理: $([ -f "$PROXY_CONF_FILE" ] && echo 已启用 || echo 未启用)"
}

main_menu(){
  while true; do
    clear
    echo "========================================="
    echo "  Mihomo Manager  (v$SCRIPT_VERSION)"
    echo "========================================="
    show_dashboard
    cat <<'EOF'
-----------------------------------------
 1) 安装/导入 Mihomo 内核（扫描上传目录）
 2) 自动下载/更新 Mihomo
 3) 检查 Mihomo
 4) 启动
 5) 停止
 6) 重启
 7) 查看详细状态
 8) 查看日志 (Ctrl+C 退出)
 9) 检查/补充配置文件
10) 安装/更新 MetaCubeXD UI
11) 系统代理设置
12) 备份 / 回滚
 0) 退出
EOF
    local num
    read -r -p "请选择: " num
    case "$num" in
      1)  import_install;  pause ;;
      2)  download_update; pause ;;
      3)  check_all;       pause ;;
      4)  run_cmd systemctl start "$SERVICE_NAME"; journalctl -u "$SERVICE_NAME" -n 5 --no-pager -q; pause ;;
      5)  run_cmd systemctl stop  "$SERVICE_NAME"; pause ;;
      6)  run_cmd systemctl restart "$SERVICE_NAME"; sleep 1; health_check && echo "[ok] 服务健康" || warn "服务可能未成功启动"; pause ;;
      7)  show_status_full; pause ;;
      8)  journalctl -u "$SERVICE_NAME" -n 100 -f --no-pager -q ;;
      9)  config_ensure;   pause ;;
      10) ui_install;      pause ;;
      11) proxy_menu;      pause ;;
      12) backup_menu;     pause ;;
      0)  exit 0 ;;
      *) ;;
    esac
  done
}

proxy_menu(){
  while true; do
    echo
    echo "==== 系统代理（$PROXY_PROFILE → $PROXY_CONF_FILE）===="
    proxy_status_head
    cat <<'EOF'
 a) 启用/修改系统代理（永久 + 当前 shell）
 b) 关闭系统代理
 v) 查看详细状态
 m) 返回上级
EOF
    local c
    read -r -p "请选择: " c
    case "$c" in
      a) proxy_enable;   pause ;;
      b) proxy_disable;  pause ;;
      v) proxy_status;   pause ;;
      m|q|*) break ;;
    esac
  done
}

# ==============================================================================
# CLI
# ==============================================================================
usage(){
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION — Mihomo Linux Bootstrap / Installer / Manager

用法:  $SCRIPT_NAME [子命令] [--dry-run] [--yes]

子命令：
  install   全自动 bootstrap：导入内核 → service → 配置补充 → UI
  import    从上传目录安装/更新内核（不访问网络）
  update    在线下载并更新内核（读取 MIHOMO_DOWNLOAD_PROXY）
  ui        部署/更新 MetaCubeXD UI
  service   安装/接管 systemd service
  config    检查并最小补充 config.yaml
  check     全面检查
  proxy     子命令: on|off|status
  backup    列出+执行回滚
  status    显示状态
  start / stop / restart / logs
  menu      交互菜单（默认）
选项:
  --dry-run    只打印动作，不真正执行
  --yes        自动同意交互确认
  -h/--help    帮助
EOF
}

ensure_shortcut(){
  # 提供 "catmi" 快捷命令（root 下安装到 /usr/local/bin）
  local link="/usr/local/bin/catmi"
  if [ "$DRYRUN" = "1" ]; then
    [ -e "$link" ] && [ "$(readlink -f "$link" 2>/dev/null)" = "$SCRIPT_SELF" ] && return 0
    echo "  [dry-run] ln -sf $SCRIPT_SELF $link"
    return 0
  fi
  if [ -L "$link" ] || [ -e "$link" ]; then
    if [ "$(readlink -f "$link" 2>/dev/null)" = "$SCRIPT_SELF" ]; then
      return 0
    fi
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      warn "/usr/local/bin/catmi 已被其他脚本占用，未覆盖。"
      return 0
    fi
  fi
  if [ -w /usr/local/bin ] || [ "$(id -u)" -eq 0 ]; then
    rm -f "$link"
    ln -sf "$SCRIPT_SELF" "$link" && ok "快捷命令已就绪: catmi (→ $SCRIPT_SELF)"
  fi
}

main(){
  # 先扫全量 argv 吸收全局选项，剩余第一个词作为子命令
  local cmd="menu"
  cmd_args=( )
  local args=( "$@" ) a pending_cmd=""
  for a in "${args[@]:-}"; do
    case "$a" in
      --dry-run) DRYRUN=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help|help) usage; exit 0 ;;
      *) [ -n "$a" ] && { if [ -z "$pending_cmd" ]; then pending_cmd="$a"; else cmd_args+=( "$a" ); fi } ;;
    esac
  done
  cmd="${pending_cmd:-menu}"

  SCRIPT_SELF="${BASH_SOURCE[0]}"
  SCRIPT_SELF="$(readlink -f "$SCRIPT_SELF" 2>/dev/null || echo "$SCRIPT_SELF")"
  load_config
  apply_paths
  [ "$DRYRUN" = "1" ] || require_root

  # 安装/确保 catmi 快捷命令（/usr/local/bin/catmi → 本脚本）
  ensure_shortcut
  case "$cmd" in
    menu)      main_menu ;;
    install)   import_install && install_service && config_ensure && ui_install && check_all ;;
    import)    import_install ;;
    update)    download_update ;;
    ui)        ui_install ;;
    service)   install_service ;;
    config)    config_ensure ;;
    check)     check_all ;;
    proxy)     proxy_cli "${cmd_args[@]:-}" ;;
    backup)    backup_menu ;;
    status)    show_status_full ;;
    start)     run_cmd systemctl start "$SERVICE_NAME"; sleep 1; health_check && ok "服务健康" || err "服务未启动，查看: journalctl -u $SERVICE_NAME -e" ;;
    stop)      run_cmd systemctl stop  "$SERVICE_NAME" ;;
    restart)   run_cmd systemctl restart "$SERVICE_NAME"; sleep 1; health_check && ok "服务健康" || warn "服务可能启动失败" ;;
    logs)      journalctl -u "$SERVICE_NAME" -f --no-pager -n 100 ;;
    -h|--help|help|'') usage ;;
    *)         usage; die "未知子命令: $cmd" ;;
  esac
}

main "$@"
