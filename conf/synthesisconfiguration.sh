#!/usr/bin/env bash
# install_and_merge.sh (2026-stable)
# 自动安装依赖 + 合并 config.d/*.yaml → config.yaml
# 仅保留一个备份 config.yaml.bak
# 运行方式: sudo ./install_and_merge.sh

set -o errexit
set -o nounset
set -o pipefail

CONF_ROOT="/root/catmi/mihomo/conf"
CONF_DIR="$CONF_ROOT/config.d"
MAIN="$CONF_ROOT/config.yaml"
BACKUP="$MAIN.bak"

# ===== 日志函数 =====
log()  { printf "[%s] %s\n" "$(date '+%F %T')" "$1" >&2; }
ok()   { printf "\e[32m[OK]\e[0m %s\n" "$1" >&2; }
warn() { printf "\e[33m[WARN]\e[0m %s\n" "$1" >&2; }
err()  { printf "\e[31m[ERR]\e[0m %s\n" "$1" >&2; }

# ===== 包管理器映射 =====
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

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman"; return; fi
  echo "unknown"
}

install_packages() {
  local mgr="$1"; shift
  case "$mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y "$@"
      ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    *) return 1 ;;
  esac
}

ensure_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "检测到命令: $cmd"
    return 0
  fi

  local mgr pkg
  mgr=$(detect_pkg_manager)
  [[ "$mgr" == "unknown" ]] && { err "无法安装 $cmd，请手动处理"; return 2; }

  case "$mgr" in
    apt) pkg="${PKG_APT[$cmd]:-$cmd}" ;;
    yum|dnf) pkg="${PKG_YUM[$cmd]:-$cmd}" ;;
    pacman) pkg="${PKG_PACMAN[$cmd]:-$cmd}" ;;
  esac

  log "尝试通过 $mgr 安装: $pkg"
  install_packages "$mgr" "$pkg" || warn "安装失败: $pkg"
}

# ===== 1) 安装依赖 =====
log "开始检测并安装缺失依赖..."
for c in "${NEEDED_CMDS[@]}"; do ensure_command "$c" || true; done


# ===== 2) 安装 PyYAML =====
if python3 -c "import yaml" >/dev/null 2>&1; then
  ok "PyYAML 已安装"
else
  log "尝试通过 pip3 安装 PyYAML..."
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --no-cache-dir pyyaml >/dev/null 2>&1 || true
  fi

  # 再次检测
  if python3 -c "import yaml" >/dev/null 2>&1; then
    ok "PyYAML 已通过 pip3 安装"
  else
    log "pip3 安装失败，尝试通过系统包安装 python3-yaml..."
    mgr=$(detect_pkg_manager)
    case "$mgr" in
      apt) apt-get install -y python3-yaml ;;
      yum|dnf) yum install -y python3-pyyaml || dnf install -y python3-pyyaml ;;
      pacman) pacman -Sy --noconfirm python-yaml ;;
    esac
  fi

  # 最终检测
  if python3 -c "import yaml" >/dev/null 2>&1; then
    ok "PyYAML 安装成功"
  else
    err "PyYAML 安装失败，无法继续"
    exit 9
  fi
fi


# ===== 3) 合并逻辑 =====
log "开始合并 $CONF_DIR → $MAIN"

[[ -d "$CONF_DIR" ]] || { err "目录不存在: $CONF_DIR"; exit 5; }

TMP="$(mktemp)"  # 不污染 conf 目录

python3 - "$MAIN" "$CONF_DIR" > "$TMP" <<'PY'
import sys, os, glob, yaml

MAIN = sys.argv[1]
CONF_DIR = sys.argv[2]

# 读取主配置
existing = {}
if os.path.isfile(MAIN):
    try:
        existing = yaml.safe_load(open(MAIN)) or {}
    except Exception:
        existing = {}

# 收集 listeners
listeners_from_dir = []
for p in sorted(glob.glob(os.path.join(CONF_DIR, "*.yaml"))):
    try:
        d = yaml.safe_load(open(p)) or {}
    except Exception:
        continue

    lst = d.get("listeners")
    if not isinstance(lst, list):
        continue

    for it in lst:
        if isinstance(it, dict):
            listeners_from_dir.append(it)

# existing listeners
existing_listeners = existing.get("listeners") or []
if not isinstance(existing_listeners, list):
    existing_listeners = []
existing_listeners = [x for x in existing_listeners if isinstance(x, dict)]

# 去重
def key_of(item):
    return item.get("name") if isinstance(item, dict) else None

final = []
seen = set()

for it in listeners_from_dir:
    k = key_of(it) or f"anon_{id(it)}"
    if k not in seen:
        final.append(it)
        seen.add(k)

for it in existing_listeners:
    k = key_of(it) or f"anon_{id(it)}"
    if k not in seen:
        final.append(it)
        seen.add(k)

# 输出
out = {k: v for k, v in existing.items() if k != "listeners"}
out["listeners"] = final

yaml.safe_dump(out, sys.stdout, sort_keys=False, allow_unicode=True)
PY

# ===== 写入结果 =====
if [[ -s "$TMP" ]]; then
  [[ -f "$MAIN" ]] && cp -f "$MAIN" "$BACKUP"
  mv -f "$TMP" "$MAIN"
  ok "合并完成 → $MAIN (备份: $BACKUP)"
else
  err "Python 合并失败，未生成内容"
  rm -f "$TMP"
  exit 7
fi

exit 0
