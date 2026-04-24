#!/usr/bin/env bash
# install_and_merge.sh
# 自动安装缺失依赖并合并 /root/catmi/mihomo/conf/config.d/*.yaml 到 /root/catmi/mihomo/conf/config.yaml
# 只保留一个备份文件: config.yaml.bak
# 运行方式: sudo ./install_and_merge.sh

set -o errexit
set -o nounset
set -o pipefail

CONF_ROOT="/root/catmi/mihomo/conf"
CONF_DIR="$CONF_ROOT/config.d"
MAIN="$CONF_ROOT/config.yaml"
BACKUP="$MAIN.bak"

# 列出必须命令与对应的包名（按 apt / yum / pacman）
declare -A PKG_APT=(
  [python3]="python3"
  [pip3]="python3-pip"
  [curl]="curl"
  [openssl]="openssl"
  [ss]="iproute2"
  [shuf]="coreutils"
  [uuidgen]="uuid-runtime"
)
declare -A PKG_YUM=(
  [python3]="python3"
  [pip3]="python3-pip"
  [curl]="curl"
  [openssl]="openssl"
  [ss]="iproute"
  [shuf]="coreutils"
  [uuidgen]="util-linux"
)
declare -A PKG_PACMAN=(
  [python3]="python"
  [pip3]="python-pip"
  [curl]="curl"
  [openssl]="openssl"
  [ss]="iproute2"
  [shuf]="coreutils"
  [uuidgen]="util-linux"
)

NEEDED_CMDS=(python3 pip3 curl openssl ss shuf uuidgen)

log() { printf "[%s] %s\n" "$(date '+%F %T')" "$1" >&2; }
ok()  { printf "\e[32m[OK]\e[0m %s\n" "$1" >&2; }
warn(){ printf "\e[33m[WARN]\e[0m %s\n" "$1" >&2; }
err() { printf "\e[31m[ERR]\e[0m %s\n" "$1" >&2; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman"; return; fi
  echo "unknown"
}

install_packages() {
  local mgr="$1"
  shift
  local pkgs=("$@")
  case "$mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "检测到命令: $cmd"
    return 0
  fi

  local mgr
  mgr=$(detect_pkg_manager)
  if [[ "$mgr" == "unknown" ]]; then
    err "未检测到受支持的包管理器 (apt/dnf/yum/pacman)。请手动安装: $cmd"
    return 2
  fi

  # 选择包名映射
  local pkg
  case "$mgr" in
    apt) pkg="${PKG_APT[$cmd]:-$cmd}" ;;
    dnf|yum) pkg="${PKG_YUM[$cmd]:-$cmd}" ;;
    pacman) pkg="${PKG_PACMAN[$cmd]:-$cmd}" ;;
    *) pkg="$cmd" ;;
  esac

  log "尝试通过 $mgr 安装: $pkg (对应命令: $cmd)"
  if install_packages "$mgr" "$pkg"; then
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "安装成功: $cmd"
      return 0
    else
      warn "安装完成但未找到命令 $cmd，可能包名不匹配，请手动检查"
      return 3
    fi
  else
    err "通过 $mgr 安装 $pkg 失败，请手动安装 $cmd"
    return 4
  fi
}

# 1) 确保基本命令存在
log "开始检测并安装缺失依赖..."
for c in "${NEEDED_CMDS[@]}"; do
  ensure_command "$c" || true
done

# 2) 确保 pip3 可用并安装 pyyaml
if command -v pip3 >/dev/null 2>&1; then
  if python3 -c "import yaml" >/dev/null 2>&1; then
    ok "Python PyYAML 已安装"
  else
    log "通过 pip3 安装 PyYAML..."
    if pip3 install --no-cache-dir pyyaml >/dev/null 2>&1; then
      ok "PyYAML 安装完成"
    else
      warn "pip3 安装 PyYAML 失败，尝试使用系统包管理器安装 python3-yaml（如果可用）"
      mgr=$(detect_pkg_manager)
      if [[ "$mgr" == "apt" ]]; then
        apt-get update -y && apt-get install -y python3-yaml || true
      fi
    fi
  fi
else
  warn "pip3 不可用，无法安装 PyYAML。请手动安装 pip3 或 PyYAML。"
fi

# 3) 运行合并逻辑（内嵌合并脚本）
log "开始合并 $CONF_DIR 下所有 .yaml 到 $MAIN（会覆盖并保留单一备份 $BACKUP）"

if [[ ! -d "$CONF_DIR" ]]; then
  err "目录不存在: $CONF_DIR"
  exit 5
fi

# 临时文件
TMP="$(mktemp "$CONF_ROOT/merge.XXXXXX.yaml")" || { err "无法创建临时文件"; exit 6; }

# 优先使用 python3 + PyYAML
if command -v python3 >/dev/null 2>&1; then
  python3 - "$MAIN" "$CONF_DIR" > "$TMP" <<'PY'
import sys, os, glob, yaml

MAIN = sys.argv[1]
CONF_DIR = sys.argv[2]

existing = {}
if os.path.isfile(MAIN):
    try:
        with open(MAIN, 'r') as f:
            existing = yaml.safe_load(f) or {}
    except Exception:
        existing = {}

listeners_from_dir = []
pattern = os.path.join(CONF_DIR, "*.yaml")
for p in sorted(glob.glob(pattern)):
    try:
        d = yaml.safe_load(open(p)) or {}
    except Exception:
        continue
    lst = d.get('listeners')
    if isinstance(lst, list):
        listeners_from_dir.extend(lst)

existing_listeners = existing.get('listeners') or []
if not isinstance(existing_listeners, list):
    existing_listeners = []

def key_of(item):
    return item.get('name') if isinstance(item, dict) else None

final_list = []
seen = set()
for it in listeners_from_dir:
    k = key_of(it) or f"__anon__{id(it)}"
    if k in seen: continue
    final_list.append(it)
    seen.add(k)
for it in existing_listeners:
    k = key_of(it) or f"__anon__{id(it)}"
    if k in seen: continue
    final_list.append(it)
    seen.add(k)

out = {}
for k,v in existing.items():
    if k != 'listeners':
        out[k] = v
out['listeners'] = final_list

yaml.safe_dump(out, sys.stdout, sort_keys=False, allow_unicode=True)
PY

  if [[ -s "$TMP" ]]; then
    # 只保留一个备份（覆盖）
    if [[ -f "$MAIN" ]]; then
      cp -f "$MAIN" "$BACKUP" 2>/dev/null || true
    fi
    mv -f "$TMP" "$MAIN"
    ok "合并完成: $MAIN (备份: $BACKUP)"
    exit 0
  else
    warn "Python 合并未生成内容，尝试回退到文本拼接"
    rm -f "$TMP" 2>/dev/null || true
  fi
fi

# 回退：文本拼接
TMP2="$(mktemp "$CONF_ROOT/merge.txt.XXXXXX")" || { err "无法创建临时文件"; exit 7; }
{
  echo "# 自动生成，请勿手动修改"
  echo "listeners:"
} > "$TMP2"

shopt -s nullglob
files=("$CONF_DIR"/*.yaml)
for f in "${files[@]}"; do
  awk '
    BEGIN {p=0}
    /^[[:space:]]*listeners[[:space:]]*:/ {p=1; next}
    p { print }
  ' "$f" >> "$TMP2"
  echo "" >> "$TMP2"
done

if [[ -f "$MAIN" ]]; then
  cp -f "$MAIN" "$BACKUP" 2>/dev/null || true
fi
awk 'NF{print}' "$TMP2" > "$MAIN"
rm -f "$TMP2" 2>/dev/null || true
ok "合并完成 (回退模式): $MAIN (备份: $BACKUP)"
exit 0
