#!/bin/bash
#===============================================================================
#  docker-sync v1.2.0 - Docker 数据同步控制中心 (rsync + WebDAV)
#===============================================================================
set -u

SCRIPT_VERSION="1.2.0"
SCRIPT_NAME="docker-sync"
TIMEZONE="Asia/Shanghai"
BASE_DIR="/etc/docker-sync"
CONF_FILE="${BASE_DIR}/config.conf"
TELEGRAM_CONF="${BASE_DIR}/telegram.conf"
RCLONE_CONF="${BASE_DIR}/rclone.conf"
SYNC_SCRIPT="/usr/local/bin/docker-sync-worker.sh"
LOG_DIR="/var/log/docker-sync"
LOG_FILE="${LOG_DIR}/sync.log"
LOCK_FILE="/var/lock/docker-sync.lock"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'
C_B='\033[0;34m'; C_C='\033[0;36m'; C_N='\033[0m'

red()    { echo -e "${C_R}$*${C_N}"; }
green()  { echo -e "${C_G}$*${C_N}"; }
yellow() { echo -e "${C_Y}$*${C_N}"; }
blue()   { echo -e "${C_B}$*${C_N}"; }
cyan()   { echo -e "${C_C}$*${C_N}"; }

pause()  { read -r -p "按回车继续..." _; }
need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    red "请使用 root 运行: sudo bash $0"
    exit 1
  fi
}

configure_time_environment() {
  if [[ ! -e "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    yellow "未找到 ${TIMEZONE} 时区数据，正在安装 tzdata..."
    pkg_install tzdata || {
      red "无法安装时区数据，请先安装 tzdata"
      return 1
    }
  fi

  export TZ="$TIMEZONE"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$TIMEZONE" || yellow "警告: 无法修改系统时区，将继续使用任务级 ${TIMEZONE}"
    timedatectl set-ntp true || yellow "警告: 无法启用系统 NTP，请确认宿主机已有时间同步服务"
  else
    yellow "警告: 未找到 timedatectl，将使用任务级 ${TIMEZONE}，请自行确认系统时间已同步"
  fi
}

#===============================================================================
#  基础工具
#===============================================================================
ensure_dirs() {
  mkdir -p "$BASE_DIR" "$LOG_DIR"
  chmod 700 "$BASE_DIR"
}

init_config_if_missing() {
  ensure_dirs
  if [[ ! -f "$CONF_FILE" ]]; then
    cat > "$CONF_FILE" << 'EOF'
# docker-sync 配置
SYNC_METHOD_SSH="false"
SYNC_METHOD_WD="false"

SSH_USER="root"
SSH_KEY="/root/.ssh/id_ed25519_docker_sync"
SSH_PORT="22"
TARGETS="10.0.0.2"
SYNC_PATHS="/opt"
REMOTE_SYNC_PATHS=""
STOP_CONTAINERS="true"
STOP_TIMEOUT="30"
RSYNC_DELETE="true"
RSYNC_EXCLUDES=""

WEBDAV_URL=""
WEBDAV_USER=""
WEBDAV_PASS=""
WEBDAV_DIR=""

SSH_AUTO="true"
SSH_SCHEDULE="23:30"
WD_AUTO="false"
WD_SCHEDULE="03:00"
EOF
    chmod 600 "$CONF_FILE"
  fi
}

init_telegram_config_if_missing() {
  ensure_dirs
  if [[ ! -f "$TELEGRAM_CONF" ]]; then
    local old_token="" old_chat_id="" old_hostname=""
    if [[ -f "$CONF_FILE" ]]; then
      old_token=$(sed -n 's/^TELEGRAM_BOT_TOKEN="\(.*\)"$/\1/p' "$CONF_FILE" | tail -n 1)
      old_chat_id=$(sed -n 's/^TELEGRAM_CHAT_ID="\(.*\)"$/\1/p' "$CONF_FILE" | tail -n 1)
      old_hostname=$(sed -n 's/^HOSTNAME_ALIAS="\(.*\)"$/\1/p' "$CONF_FILE" | tail -n 1)
    fi
    cat > "$TELEGRAM_CONF" << EOF
# docker-sync Telegram 通知配置（独立于同步方案）
TELEGRAM_ENABLED="$([[ -n "$old_token" && -n "$old_chat_id" ]] && echo true || echo false)"
TELEGRAM_BOT_TOKEN="$old_token"
TELEGRAM_CHAT_ID="$old_chat_id"
HOSTNAME_ALIAS="${old_hostname:-$(hostname)}"
EOF
    chmod 600 "$TELEGRAM_CONF"
    # 迁移完成后移除旧位置，避免同步配置继续持有通知参数。
    sed -i '/^TELEGRAM_BOT_TOKEN=/d; /^TELEGRAM_CHAT_ID=/d; /^HOSTNAME_ALIAS=/d' "$CONF_FILE"
  fi
}

load_config() {
  init_config_if_missing
  init_telegram_config_if_missing
  source "$CONF_FILE"
  source "$TELEGRAM_CONF"
  SYNC_METHOD_SSH="${SYNC_METHOD_SSH:-false}"
  SYNC_METHOD_WD="${SYNC_METHOD_WD:-false}"
  TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-false}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
  HOSTNAME_ALIAS="${HOSTNAME_ALIAS:-$(hostname)}"
  SSH_USER="${SSH_USER:-root}"
  SSH_KEY="${SSH_KEY:-/root/.ssh/id_ed25519_docker_sync}"
  SSH_PORT="${SSH_PORT:-22}"
  TARGETS="${TARGETS:-10.0.0.2}"
  SYNC_PATHS="${SYNC_PATHS:-/opt}"
  REMOTE_SYNC_PATHS="${REMOTE_SYNC_PATHS:-}"
  STOP_CONTAINERS="${STOP_CONTAINERS:-true}"
  STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
  RSYNC_DELETE="${RSYNC_DELETE:-true}"
  RSYNC_EXCLUDES="${RSYNC_EXCLUDES:-}"
  WEBDAV_URL="${WEBDAV_URL:-}"
  WEBDAV_USER="${WEBDAV_USER:-}"
  WEBDAV_PASS="${WEBDAV_PASS:-}"
  WEBDAV_DIR="${WEBDAV_DIR:-}"
  SSH_AUTO="${SSH_AUTO:-true}"
  SSH_SCHEDULE="${SSH_SCHEDULE:-23:30}"
  WD_AUTO="${WD_AUTO:-false}"
  WD_SCHEDULE="${WD_SCHEDULE:-03:00}"
}

save_kv() {
  local key="$1" val="$2"
  init_config_if_missing
  sed -i "/^${key}=/d" "$CONF_FILE"
  printf '%s="%s"\n' "$key" "$val" >> "$CONF_FILE"
}

save_telegram_kv() {
  local key="$1" val="$2"
  init_telegram_config_if_missing
  sed -i "/^${key}=/d" "$TELEGRAM_CONF"
  printf '%s="%s"\n' "$key" "$val" >> "$TELEGRAM_CONF"
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    red "无法识别包管理器，请手动安装: $*"
    return 1
  fi
}

#===============================================================================
#  公共配置函数
#===============================================================================
setup_telegram() {
  command -v curl >/dev/null 2>&1 || pkg_install curl
  while true; do
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
      echo "当前已有 Telegram 配置，直接回车可保留原值。"
    fi
    read -r -p "Bot Token: " tok
    read -r -p "Chat ID: " cid
    read -r -p "主机显示名 [默认 ${HOSTNAME_ALIAS:-$(hostname)}]: " ha
    tok="${tok:-$TELEGRAM_BOT_TOKEN}"
    cid="${cid:-$TELEGRAM_CHAT_ID}"
    ha="${ha:-${HOSTNAME_ALIAS:-$(hostname)}}"
    if [[ -z "$tok" || -z "$cid" ]]; then
      red "Bot Token 和 Chat ID 不能为空。"
      continue
    fi
    echo "正在发送测试消息..."
    curl -sS -X POST "https://api.telegram.org/bot${tok}/sendMessage" \
      --data-urlencode "chat_id=${cid}" \
      --data-urlencode "text=🔔 docker-sync 测试消息 $(TZ="$TIMEZONE" date '+%F %T %Z')" >/dev/null
    read -r -p "是否收到了 Telegram 测试消息? [y/N]: " tg_ok
    if [[ "$tg_ok" == "y" || "$tg_ok" == "Y" ]]; then
      save_telegram_kv TELEGRAM_BOT_TOKEN "$tok"
      save_telegram_kv TELEGRAM_CHAT_ID "$cid"
      save_telegram_kv HOSTNAME_ALIAS "$ha"
      save_telegram_kv TELEGRAM_ENABLED "true"
      load_config
      green "Telegram 配置验证完成"
      break
    else
      red "未收到测试消息，请检查 Token 和 Chat ID 是否正确，重新配置。"
    fi
  done
}

menu_telegram() {
  need_root
  while true; do
    clear
    load_config
    cyan "===== Telegram 通知配置 ====="
    echo "当前状态: $([ "$TELEGRAM_ENABLED" == "true" ] && green "已启用" || red "未启用")"
    echo "主机显示名: ${HOSTNAME_ALIAS}"
    echo " 1) 配置/修改 Telegram 通知"
    echo " 2) 禁用 Telegram 通知（保留配置）"
    echo " 0) 返回主菜单"
    read -r -p "请选择: " c
    case "$c" in
      1) setup_telegram; pause ;;
      2) save_telegram_kv TELEGRAM_ENABLED "false"; green "Telegram 通知已禁用"; pause ;;
      0) return ;;
      *) red "无效选项"; sleep 1 ;;
    esac
  done
}

setup_common_paths() {
  echo "--- 路径与 Docker 策略 ---"
  read -r -p "需要同步的源端路径 (如 /opt): " p
  p="${p%/}"
  save_kv SYNC_PATHS "$p"
  
  read -r -p "同步前是否停止当前运行的容器? [true/false，默认 true]: " sc
  save_kv STOP_CONTAINERS "${sc:-true}"
  read -r -p "容器停止超时秒数 [默认 30]: " st
  save_kv STOP_TIMEOUT "${st:-30}"
}

#===============================================================================
#  Worker 脚本生成
#===============================================================================
install_worker_script() {
  ensure_dirs
  cat > "$SYNC_SCRIPT" << 'WORKER'
#!/bin/bash
set -u
SCRIPT_VERSION="1.2.0"
TIMEZONE="Asia/Shanghai"
export TZ="$TIMEZONE"
BASE_DIR="/etc/docker-sync"
CONF_FILE="${BASE_DIR}/config.conf"
TELEGRAM_CONF="${BASE_DIR}/telegram.conf"
RCLONE_CONF="${BASE_DIR}/rclone.conf"
LOG_DIR="/var/log/docker-sync"
LOG_FILE="${LOG_DIR}/sync.log"
LOCK_FILE="/var/lock/docker-sync.lock"

MODE="${1:-all}"
mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

load_config() {
  source "$CONF_FILE"
  [[ -f "$TELEGRAM_CONF" ]] && source "$TELEGRAM_CONF"
  SYNC_METHOD_SSH="${SYNC_METHOD_SSH:-false}"
  SYNC_METHOD_WD="${SYNC_METHOD_WD:-false}"
  TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-false}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
  HOSTNAME_ALIAS="${HOSTNAME_ALIAS:-$(hostname)}"
  SSH_USER="${SSH_USER:-root}"
  SSH_KEY="${SSH_KEY:-/root/.ssh/id_ed25519_docker_sync}"
  SSH_PORT="${SSH_PORT:-22}"
  TARGETS="${TARGETS:-}"
  SYNC_PATHS="${SYNC_PATHS:-/opt}"
  REMOTE_SYNC_PATHS="${REMOTE_SYNC_PATHS:-}"
  STOP_CONTAINERS="${STOP_CONTAINERS:-true}"
  STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
  RSYNC_DELETE="${RSYNC_DELETE:-true}"
  RSYNC_EXCLUDES="${RSYNC_EXCLUDES:-}"
  WEBDAV_DIR="${WEBDAV_DIR:-}"
}

cleanup_archives() {
  if [[ -n "${ARCHIVE_DIR:-}" && -d "$ARCHIVE_DIR" ]]; then
    rm -rf -- "$ARCHIVE_DIR"
  fi
}

archive_name_part() {
  local value="$1"
  value="${value//\//_}"
  value="$(printf '%s' "$value" | tr -cs 'A-Za-z0-9._-' '_')"
  printf '%s' "${value:-root}"
}

create_archive() {
  local src="$1" archive="$2"
  local parent base exclude_member

  if [[ "$src" == "/" ]]; then
    parent="/"
    base="."
  else
    parent="$(dirname -- "$src")"
    base="$(basename -- "$src")"
  fi

  # 避免源目录覆盖 /var/tmp 时把正在生成的归档再次打入自身。
  if [[ "$parent" == "/" ]]; then
    exclude_member="${ARCHIVE_DIR#/}"
  else
    exclude_member="${ARCHIVE_DIR#"${parent}/"}"
  fi

  tar --exclude="$exclude_member" --exclude="./$exclude_member" \
    -czf "$archive" -C "$parent" -- "$base"
}

send_telegram() {
  local msg="$1"
  load_config
  if [[ "${TELEGRAM_ENABLED:-false}" != "true" || -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then return 0; fi
  [[ ${#msg} -gt 3500 ]] && msg="${msg:0:3500}
...(截断)"
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${msg}" \
    --connect-timeout 10 --max-time 30 >/dev/null || log "Telegram 发送失败"
}

format_duration() {
  local s=$1
  printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}

ssh_cmd() {
  local host="$1"; shift
  ssh -i "$SSH_KEY" -p "${SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 -o ServerAliveInterval=15 "${SSH_USER}@${host}" "$@"
}

START_TS=$(date +%s)
RUNNING=()
SYNC_OK=true
TARGET_RESULTS=()
ARCHIVE_DIR=""
ARCHIVE_PATHS=()
ARCHIVE_NAMES=()
PACK_OK=true
load_config
trap cleanup_archives EXIT

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  send_telegram "❌ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 失败: 已有任务在运行"
  exit 1
fi

log "========== docker-sync (${MODE}) 开始 =========="

if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
  msg="Docker 不可用"; log "失败: $msg"
  send_telegram "❌ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 失败\n原因: ${msg}"; exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  msg="缺少归档工具 tar"; log "失败: $msg"
  send_telegram "❌ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 失败\n原因: ${msg}"; exit 1
fi

# 健康检查
if [[ "$MODE" == "all" || "$MODE" == "ssh" ]]; then
  if [[ "$SYNC_METHOD_SSH" == "true" ]]; then
    if [[ ! -f "$SSH_KEY" ]]; then
      msg="SSH 密钥不存在: $SSH_KEY"; log "失败: $msg"
      send_telegram "❌ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 失败\n原因: ${msg}"; exit 1
    fi
    if [[ -z "${TARGETS// }" || -z "${SYNC_PATHS// }" ]]; then
      msg="TARGETS 或 SYNC_PATHS 未配置"; log "失败: $msg"
      send_telegram "❌ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 失败\n原因: ${msg}"; exit 1
    fi
    for t in $TARGETS; do
      if ! ssh_cmd "$t" "echo ok" >/dev/null 2>&1; then
        msg="无法 SSH 到 ${t}:${SSH_PORT}"; log "失败: $msg"
        send_telegram "❌ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 失败\n原因: ${msg}"; exit 1
      fi
    done
  fi
fi

for p in $SYNC_PATHS; do
  if [[ ! -e "$p" ]]; then
    msg="本地路径不存在: $p"; log "失败: $msg"
    send_telegram "❌ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 失败\n原因: ${msg}"; exit 1
  fi
done
log "健康检查通过"

# 停容器
if [[ "$STOP_CONTAINERS" == "true" || "$STOP_CONTAINERS" == "yes" || "$STOP_CONTAINERS" == "1" ]]; then
  mapfile -t RUNNING < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
  if [[ ${#RUNNING[@]} -gt 0 ]]; then
    log "停止运行中容器: ${RUNNING[*]}"
    docker stop -t "${STOP_TIMEOUT}" "${RUNNING[@]}" || log "警告: 部分 stop 失败"
  else
    log "无运行中容器"
  fi
fi

resolve_dest() {
  local dest="${REMOTE_SYNC_PATHS%/}"
  printf '%s\n' "${dest:-/}"
}

# 将每个源目录归档一次，SSH 与 WebDAV 复用同一个包。
RUN_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
ARCHIVE_HOST=$(archive_name_part "$(hostname)")
umask 077
if ARCHIVE_DIR=$(mktemp -d /var/tmp/docker-sync.XXXXXX); then
  for p in $SYNC_PATHS; do
    src="$p"
    [[ "$src" != "/" ]] && src="${src%/}"
    path_part=$(archive_name_part "${src#/}")
    archive_name="${ARCHIVE_HOST}_${path_part}_${RUN_TIMESTAMP}.tar.gz"
    archive_path="${ARCHIVE_DIR}/${archive_name}"
    log "打包 ${src} -> ${archive_name}"
    if create_archive "$src" "$archive_path" >>"$LOG_FILE" 2>&1; then
      ARCHIVE_PATHS+=("$archive_path")
      ARCHIVE_NAMES+=("$archive_name")
      log "  OK: ${archive_name} ($(du -h "$archive_path" | awk '{print $1}'))"
    else
      log "  FAIL: 无法打包 $src"
      PACK_OK=false
      SYNC_OK=false
    fi
  done
else
  log "失败: 无法创建归档临时目录"
  PACK_OK=false
  SYNC_OK=false
fi

# SSH/rsync 同步
if [[ "$MODE" == "all" || "$MODE" == "ssh" ]]; then
  if [[ "$SYNC_METHOD_SSH" == "true" ]]; then
    for t in $TARGETS; do
      t_ok="$PACK_OK"
      for i in "${!ARCHIVE_PATHS[@]}"; do
        archive_path="${ARCHIVE_PATHS[$i]}"
        archive_name="${ARCHIVE_NAMES[$i]}"
        dest=$(resolve_dest)
        log "rsync ${archive_name} -> ${t}:${dest}"
        ssh_cmd "$t" "mkdir -p $(printf '%q' "$dest")" 2>/dev/null || true
        if rsync -az --timeout=300 \
            -e "ssh -i ${SSH_KEY} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15" \
            "$archive_path" "${SSH_USER}@${t}:${dest}/" >>"$LOG_FILE" 2>&1; then
          log "  OK: $archive_name -> $t:$dest"
        else
          log "  FAIL: $archive_name -> $t:$dest"; t_ok=false; SYNC_OK=false
        fi
      done
      $t_ok && TARGET_RESULTS+=("SSH-${t}:OK") || TARGET_RESULTS+=("SSH-${t}:FAIL")
    done
  fi
fi

# WebDAV 同步
if [[ "$MODE" == "all" || "$MODE" == "wd" ]]; then
  if [[ "$SYNC_METHOD_WD" == "true" ]]; then
    if ! command -v rclone >/dev/null 2>&1; then
      log "WebDAV 已启用但未找到 rclone，跳过"
      TARGET_RESULTS+=("WebDAV:FAIL"); SYNC_OK=false
    else
      log "同步到 WebDAV..."
      wd_ok="$PACK_OK"
      for i in "${!ARCHIVE_PATHS[@]}"; do
        archive_path="${ARCHIVE_PATHS[$i]}"
        archive_name="${ARCHIVE_NAMES[$i]}"
        dest="${WEBDAV_DIR%/}"
        [[ -z "$dest" ]] && dest="/"
        if [[ "$dest" == "/" ]]; then
          remote_file="wd:/${archive_name}"
        else
          remote_file="wd:${dest}/${archive_name}"
        fi
        if rclone copyto "$archive_path" "$remote_file" --config "$RCLONE_CONF" >>"$LOG_FILE" 2>&1; then
          log "  OK WebDAV: $archive_name -> $dest"
        else
          log "  FAIL WebDAV: $archive_name -> $dest"; wd_ok=false; SYNC_OK=false
        fi
      done
      $wd_ok && TARGET_RESULTS+=("WebDAV:OK") || TARGET_RESULTS+=("WebDAV:FAIL")
    fi
  fi
fi

# 启容器
START_FAIL=false
if [[ ${#RUNNING[@]} -gt 0 ]]; then
  log "启动容器: ${RUNNING[*]}"
  if ! docker start "${RUNNING[@]}"; then
    START_FAIL=true; SYNC_OK=false; log "容器启动失败"
  fi
fi

DUR=$(format_duration $(( $(date +%s) - START_TS )))
CLIST="${RUNNING[*]:-无}"
TRES=$(IFS=', '; echo "${TARGET_RESULTS[*]}")
[[ -z "$TRES" ]] && TRES="无"
ALIST=$(IFS=', '; echo "${ARCHIVE_NAMES[*]}")
[[ -z "$ALIST" ]] && ALIST="无"

if $SYNC_OK && ! $START_FAIL; then
  log "========== 成功 耗时 ${DUR} =========="
  send_telegram "✅ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 成功
时间: $(date '+%F %T %Z')
耗时: ${DUR}
目标: ${TRES}
路径: ${SYNC_PATHS}
归档: ${ALIST}
容器: ${CLIST}
日志: ${LOG_FILE}"
  exit 0
else
  reason="同步失败"
  $START_FAIL && reason="${reason}; 容器启动失败"
  log "========== 失败 耗时 ${DUR} =========="
  send_telegram "❌ [${HOSTNAME_ALIAS}] docker-sync (${MODE}) 失败
时间: $(date '+%F %T %Z')
耗时: ${DUR}
原因: ${reason}
目标: ${TRES}
路径: ${SYNC_PATHS}
归档: ${ALIST}
容器: ${CLIST}
日志: ${LOG_FILE}"
  exit 1
fi
WORKER
  chmod 700 "$SYNC_SCRIPT"
}

#===============================================================================
#  菜单 1：安装/配置同步方案
#===============================================================================
menu_install_sync() {
  need_root
  while true; do
    clear
    cyan "===== 1. 安装/配置同步方案 ====="
    load_config
    echo "当前状态:"
    echo " - SSH (rsync): $([ "$SYNC_METHOD_SSH" == "true" ] && green "已启用" || red "未启用")"
    echo " - WebDAV:     $([ "$SYNC_METHOD_WD" == "true" ] && green "已启用" || red "未启用")"
    echo "--------------------------"
    echo " 1) 配置 SSH (rsync) 同步"
    echo " 2) 配置 WebDAV (rclone) 同步"
    echo " 0) 返回主菜单"
    read -r -p "请选择: " c
    case "$c" in
      1) install_ssh_flow ;;
      2) install_wd_flow ;;
      0) return ;;
      *) red "无效选项"; sleep 1 ;;
    esac
  done
}

install_ssh_flow() {
  init_config_if_missing
  yellow ">>> [1/3] 安装依赖 (curl rsync openssh-client)..."
  pkg_install curl rsync openssh-client 2>/dev/null || pkg_install curl rsync openssh-clients
  if ! command -v docker >/dev/null 2>&1; then yellow "警告: 未检测到 docker"; fi

  yellow ">>> [2/3] 配置 SSH 与同步路径..."
  read -r -p "SSH 用户 [默认 root]: " u
  read -r -p "目标 SSH 端口 [默认 22]: " sp
  read -r -p "密钥路径 [默认 /root/.ssh/id_ed25519_docker_sync]: " k
  save_kv SSH_USER "${u:-root}"
  save_kv SSH_PORT "${sp:-22}"
  save_kv SSH_KEY "${k:-/root/.ssh/id_ed25519_docker_sync}"
  load_config
  if [[ ! -f "$SSH_KEY" ]]; then
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "docker-sync"
    chmod 600 "$SSH_KEY"
    green "已生成密钥: $SSH_KEY"
  fi
  echo "请将以下公钥放到目标对端机的 authorized_keys:"
  cat "${SSH_KEY}.pub"
  echo
  
  read -r -p "目标内网 IP (如 10.0.0.2): " t
  save_kv TARGETS "$t"
  
  setup_common_paths
  
  read -r -p "对端存放归档的目录 (留空=/，如 /usr/local/sync): " rp
  save_kv REMOTE_SYNC_PATHS "$rp"
  if [[ -n "$rp" ]]; then yellow "提示: 归档文件将直接存放到对端 ${rp%/}/ 下"; fi
  
  save_kv SYNC_METHOD_SSH "true"
  
  yellow ">>> [3/3] 生成同步执行脚本..."
  install_worker_script
  
  green "SSH 同步方案配置完成！"
  yellow "提示: rsync 内网同步需要两台机器网络互通，请确保已自行配置好 WireGuard 或其他内网穿透。"
  pause
}

install_wd_flow() {
  init_config_if_missing
  yellow ">>> [1/3] 安装依赖..."
  pkg_install curl rsync openssh-client 2>/dev/null || pkg_install curl rsync openssh-clients
  if ! command -v rclone >/dev/null 2>&1; then
    yellow "安装 rclone..."
    curl -fsSL https://rclone.org/install.sh | sudo bash
  fi
  
  yellow ">>> [2/3] 配置 WebDAV 与同步路径..."
  read -r -p "WebDAV 地址 (如 https://dav.example.com): " wd_url
  read -r -p "WebDAV 用户名: " wd_user
  read -r -s -p "WebDAV 密码: " wd_pass
  echo
  read -r -p "远程同步的文件夹名称 (如 backup): " wd_dir
  save_kv WEBDAV_URL "$wd_url"
  save_kv WEBDAV_USER "$wd_user"
  save_kv WEBDAV_PASS "$wd_pass"
  save_kv WEBDAV_DIR "$wd_dir"
  
  setup_common_paths
  
  save_kv SYNC_METHOD_WD "true"
  
  obscured_pass=$(rclone obscure "${wd_pass}")
  cat > "$RCLONE_CONF" << WDEOF
[wd]
type = webdav
url = ${wd_url}
vendor = other
user = ${wd_user}
pass = ${obscured_pass}
WDEOF
  chmod 600 "$RCLONE_CONF"
  
  yellow ">>> [3/3] 生成同步执行脚本..."
  install_worker_script
  
  green "WebDAV 同步方案配置完成！"
  pause
}

#===============================================================================
#  菜单 2：定时任务配置
#===============================================================================
menu_schedule() {
  need_root
  configure_time_environment || { pause; return; }
  load_config
  if [[ "$SYNC_METHOD_SSH" != "true" && "$SYNC_METHOD_WD" != "true" ]]; then
    red "未检测到已启用的同步方案，请先运行选项 1"
    pause; return
  fi
  
  clear
  cyan "===== 2. 定时任务配置 ====="
  echo "当前启用的方案: $([ "$SYNC_METHOD_SSH" == "true" ] && echo -n "SSH ")$([ "$SYNC_METHOD_WD" == "true" ] && echo -n "WebDAV")"
  
  # SSH 方案配置
  if [[ "$SYNC_METHOD_SSH" == "true" ]]; then
    echo "[SSH 同步] 当前: $([ "$SSH_AUTO" == "true" ] && echo "自动 ($SSH_SCHEDULE)" || echo "手动")"
    read -r -p "SSH 同步设为自动? [y/N]: " ssh_auto
    if [[ "$ssh_auto" == "y" || "$ssh_auto" == "Y" ]]; then
      save_kv SSH_AUTO "true"
      while true; do
        read -r -p "SSH 自动同步时间 HH:MM [默认 ${SSH_SCHEDULE}]: " ssh_sch
        ssh_sch=${ssh_sch:-$SSH_SCHEDULE}
        if [[ ! "$ssh_sch" =~ ^([0-1]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
          red "格式错误，应为 HH:MM"
        else
          save_kv SSH_SCHEDULE "$ssh_sch"
          break
        fi
      done
    else
      save_kv SSH_AUTO "false"
    fi
  fi
  
  # WebDAV 方案配置
  if [[ "$SYNC_METHOD_WD" == "true" ]]; then
    echo "[WebDAV 同步] 当前: $([ "$WD_AUTO" == "true" ] && echo "自动 ($WD_SCHEDULE)" || echo "手动")"
    read -r -p "WebDAV 同步设为自动? [y/N]: " wd_auto
    if [[ "$wd_auto" == "y" || "$wd_auto" == "Y" ]]; then
      save_kv WD_AUTO "true"
      while true; do
        read -r -p "WebDAV 自动同步时间 HH:MM [默认 ${WD_SCHEDULE}]: " wd_sch
        wd_sch=${wd_sch:-$WD_SCHEDULE}
        if [[ ! "$wd_sch" =~ ^([0-1]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
          red "格式错误，应为 HH:MM"
        else
          # 检查是否与 SSH 冲突
          if [[ "$SYNC_METHOD_SSH" == "true" && "$SSH_AUTO" == "true" && "$wd_sch" == "$SSH_SCHEDULE" ]]; then
            red "时间不能与 SSH 的自动同步时间 ($SSH_SCHEDULE) 相同，请重新输入！"
          else
            save_kv WD_SCHEDULE "$wd_sch"
            break
          fi
        fi
      done
    else
      save_kv WD_AUTO "false"
    fi
  fi
  
  load_config
  yellow "应用定时配置..."
  # 升级已有安装时同步刷新 worker；配置文件与现有同步方案保持不变。
  install_worker_script
  
  # 停用旧服务
  systemctl stop docker-sync.timer docker-sync-ssh.timer docker-sync-wd.timer 2>/dev/null || true
  systemctl disable docker-sync.timer docker-sync-ssh.timer docker-sync-wd.timer 2>/dev/null || true
  rm -f /etc/systemd/system/docker-sync*.service /etc/systemd/system/docker-sync*.timer

  # 创建 Service
  cat > /etc/systemd/system/docker-sync-ssh.service << 'EOF'
[Unit]
Description=docker-sync SSH worker
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
Environment=TZ=Asia/Shanghai
ExecStart=/usr/local/bin/docker-sync-worker.sh ssh
Nice=10
TimeoutStartSec=7200

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/docker-sync-wd.service << 'EOF'
[Unit]
Description=docker-sync WebDAV worker
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
Environment=TZ=Asia/Shanghai
ExecStart=/usr/local/bin/docker-sync-worker.sh wd
Nice=10
TimeoutStartSec=7200

[Install]
WantedBy=multi-user.target
EOF

  # 生成对应 Timer
  gen_timer() {
    local name="$1" sched="$2"
    local hh mm
    hh=$(echo "$sched" | cut -d: -f1); mm=$(echo "$sched" | cut -d: -f2)
    hh=$((10#$hh)); mm=$((10#$mm))
    cat > /etc/systemd/system/${name}.timer << EOF
[Unit]
Description=docker-sync ${name} timer
Requires=${name}.service

[Timer]
OnCalendar=*-*-* $(printf '%02d:%02d:00' "$hh" "$mm") Asia/Shanghai
Persistent=true
Unit=${name}.service

[Install]
WantedBy=timers.target
EOF
  }

  if [[ "$SYNC_METHOD_SSH" == "true" && "$SSH_AUTO" == "true" ]]; then
    gen_timer "docker-sync-ssh" "$SSH_SCHEDULE"
  fi
  if [[ "$SYNC_METHOD_WD" == "true" && "$WD_AUTO" == "true" ]]; then
    gen_timer "docker-sync-wd" "$WD_SCHEDULE"
  fi

  systemctl daemon-reload
  if [[ "$SYNC_METHOD_SSH" == "true" && "$SSH_AUTO" == "true" ]]; then
    systemctl enable --now docker-sync-ssh.timer
  fi
  if [[ "$SYNC_METHOD_WD" == "true" && "$WD_AUTO" == "true" ]]; then
    systemctl enable --now docker-sync-wd.timer
  fi
  green "定时任务已应用"
  systemctl list-timers --no-pager 2>/dev/null | grep docker-sync || true
  pause
}

#===============================================================================
#  菜单 4：卸载同步程序
#===============================================================================
menu_uninstall_sync() {
  need_root
  clear
  cyan "===== 4. 卸载同步程序 ====="
  echo "将删除: systemd 服务/timer、worker 脚本、同步配置(rclone.conf等)与日志目录"
  echo "不会删除: Docker, rclone, rsync 等基础软件"
  echo
  read -r -p "确认卸载? [y/N]: " y
  [[ "$y" != "y" && "$y" != "Y" ]] && return

  load_config
  local saved_ssh_key="$SSH_KEY"
  read -r -p "是否同时卸载 Telegram 通知方案并删除其配置? [y/N]: " yt

  systemctl stop docker-sync*.timer 2>/dev/null || true
  systemctl disable docker-sync*.timer 2>/dev/null || true
  systemctl stop docker-sync*.service 2>/dev/null || true
  rm -f /etc/systemd/system/docker-sync*.service /etc/systemd/system/docker-sync*.timer
  systemctl daemon-reload

  rm -f "$SYNC_SCRIPT"
  rm -f "$CONF_FILE" "$RCLONE_CONF"
  if [[ "$yt" == "y" || "$yt" == "Y" ]]; then
    rm -f "$TELEGRAM_CONF"
    green "Telegram 通知方案已卸载。"
  else
    yellow "已保留 Telegram 通知配置: $TELEGRAM_CONF"
  fi
  rmdir "$BASE_DIR" 2>/dev/null || true
  rm -rf "$LOG_DIR"

  if [[ -f "$saved_ssh_key" ]]; then
    read -r -p "删除同步专用 SSH 密钥 ${saved_ssh_key}? [y/N]: " yk
    if [[ "$yk" == "y" || "$yk" == "Y" ]]; then
      rm -f "$saved_ssh_key" "${saved_ssh_key}.pub"
    fi
  fi
  green "同步主程序已卸载。"
  pause
}

#===============================================================================
#  主菜单
#===============================================================================
main_menu() {
  need_root
  init_config_if_missing
  while true; do
    clear
    echo -e "${C_C}"
    cat << 'BANNER'
╔══════════════════════════════════════════════╗
║           docker-sync 控制中心               ║
║       Docker 数据同步 (rsync + WebDAV)       ║
╚══════════════════════════════════════════════╝
BANNER
    echo -e "${C_N}"
    echo "  版本: ${SCRIPT_VERSION}    时区: ${TIMEZONE}"
    echo
    echo "  1) 安装/配置同步方案 (支持双方案共存)"
    echo "  2) 定时任务配置 (错开时间校验)"
    echo "  3) Telegram 通知配置 (独立配置)"
    echo "  4) 卸载同步程序"
    echo "  0) 退出"
    echo
    read -r -p "请选择: " choice
    case "$choice" in
      1) menu_install_sync ;;
      2) menu_schedule ;;
      3) menu_telegram ;;
      4) menu_uninstall_sync ;;
      0) echo "bye"; exit 0 ;;
      *) red "无效选项"; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  ""|menu) main_menu ;;
  sync)
    need_root
    [[ -x "$SYNC_SCRIPT" ]] || { red "主程序未安装，请先运行菜单 1"; exit 1; }
    mode="${2:-all}"
    bash "$SYNC_SCRIPT" "$mode"
    ;;
  status)
    need_root
    load_config
    echo "当前方案: SSH($SYNC_METHOD_SSH) WebDAV($SYNC_METHOD_WD)"
    echo "版本: ${SCRIPT_VERSION}  时区: ${TIMEZONE} ($(TZ="$TIMEZONE" date '+%F %T %Z'))"
    echo "Telegram 通知: $([ "$TELEGRAM_ENABLED" == "true" ] && echo "已启用 (${HOSTNAME_ALIAS})" || echo "未启用")"
    [[ "$SYNC_METHOD_SSH" == "true" ]] && echo "SSH: $([ "$SSH_AUTO" == "true" ] && echo "自动 $SSH_SCHEDULE" || echo "手动")"
    [[ "$SYNC_METHOD_WD" == "true" ]] && echo "WD:  $([ "$WD_AUTO" == "true" ] && echo "自动 $WD_SCHEDULE" || echo "手动")"
    systemctl list-timers --no-pager 2>/dev/null | grep docker-sync || true
    echo "--- 最近日志 ---"
    tail -n 20 "$LOG_FILE" 2>/dev/null || echo "暂无日志"
    ;;
  *)
    echo "用法:"
    echo "  sudo bash $0              # 进入菜单"
    echo "  sudo bash $0 sync [all|ssh|wd] # 立即执行同步(默认all)"
    echo "  sudo bash $0 status       # 查看状态与日志"
    exit 1
    ;;
esac
