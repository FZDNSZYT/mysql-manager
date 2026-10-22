#!/usr/bin/env bash
# lib/common.sh - mysql-manager 公共库
# 严禁直接执行，必须被 source

# ============ 目录约定 ============
MM_LOG_DIR="${MM_LOG_DIR:-/var/log/mysql-manager}"
MM_EVENT_LOG="${MM_EVENT_LOG:-$MM_LOG_DIR/events.log}"
MM_STATE_DIR="${MM_STATE_DIR:-/var/lib/mysql-manager}"
MM_CRED_FILE="${MM_CRED_FILE:-/root/.mysql/credentials}"
MM_BACKUP_DIR="${MM_BACKUP_DIR:-/root/mysql-backups}"
MM_CONF_DIR="${MM_CONF_DIR:-/etc/mysql-manager}"
MM_PODMAN_CONTAINER="${MM_PODMAN_CONTAINER:-mysql57}"
MM_PODMAN_IMAGE="${MM_PODMAN_IMAGE:-docker.io/library/mysql:5.7.44}"
MM_PODMAN_DATADIR="${MM_PODMAN_DATADIR:-/var/lib/mysql57/data}"
MM_NATIVE_DATADIR="${MM_NATIVE_DATADIR:-/var/lib/mysql}"

# ============ 保留策略 ============
MM_LOG_RETAIN_DAYS="${MM_LOG_RETAIN_DAYS:-30}"
MM_BACKUP_RETAIN_DAYS="${MM_BACKUP_RETAIN_DAYS:-30}"

# ============ MySQL 全局变量（唯一权威来源） ============
: "${MYSQL_VERSION:=8.4}"
: "${MYSQL_PORT:=3306}"
: "${MYSQL_BIND:=0.0.0.0}"
: "${MYSQL_ROOT_PASSWORD:=}"
: "${MYSQL_ALLOW_ROOT_REMOTE:=no}"
: "${MYSQL_FRESH:=yes}"
: "${MYSQL_DEPLOY_MODE:=native}"   # native | podman
: "${MYSQL_RUN_LOG:=}"

# ============ 颜色 ============
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BLD=$'\033[1m'; C_NC=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_BLD=''; C_NC=''
fi

# ============ 日志（双写：事件 + 本次运行日志） ============
init_logging() {
  local tag="${1:-run}"
  mkdir -p "$MM_LOG_DIR" "$MM_STATE_DIR"
  chmod 750 "$MM_LOG_DIR" "$MM_STATE_DIR"
  MYSQL_RUN_LOG="$MM_LOG_DIR/${tag}_$(date +%Y%m%d_%H%M%S).log"
  touch "$MYSQL_RUN_LOG" "$MM_EVENT_LOG"
  chmod 640 "$MYSQL_RUN_LOG" "$MM_EVENT_LOG"
  _event INFO "${LOG_MODULE:-main}" "===== 开始 $tag 任务 (pid=$$ user=$(id -un)) ====="
  printf '%s[*] 运行日志: %s\n%s[*] 事件日志: %s%s\n' \
    "$C_BLU" "$MYSQL_RUN_LOG" "$C_BLU" "$MM_EVENT_LOG" "$C_NC"
}

_event() {
  local level="$1" module="$2"; shift 2
  printf '%s | %-5s | %-10s | %s\n' \
    "$(date '+%F %T')" "$level" "$module" "$*" >>"$MM_EVENT_LOG"
}

_emit() {
  local color="$1" tag="$2"; shift 2
  local line
  line="$(date '+%F %T') $tag $*"
  printf '%s%s%s\n' "$color" "$line" "$C_NC"
  [[ -n "${MYSQL_RUN_LOG:-}" ]] && printf '%s\n' "$line" >>"$MYSQL_RUN_LOG"
  return 0
}

log_event() { _event INFO  "${LOG_MODULE:-main}" "$*"; _emit "$C_BLU" "[INFO]" "$*"; }
log_step()  { _event STEP  "${LOG_MODULE:-main}" "$*"; _emit "$C_CYN" "[STEP]" "$*"; }
log_ok()    { _event OK    "${LOG_MODULE:-main}" "$*"; _emit "$C_GRN" "[ OK ]" "$*"; }
log_warn()  { _event WARN  "${LOG_MODULE:-main}" "$*"; _emit "$C_YEL" "[WARN]" "$*" >&2; }
log_error() { _event ERROR "${LOG_MODULE:-main}" "$*"; _emit "$C_RED" "[FAIL]" "$*" >&2; }

trap 'log_error "脚本在第 $LINENO 行中断（命令: $BASH_COMMAND）"' ERR

# 跑一步：成功/失败都记录
run_step() {
  local desc="$1"; shift
  log_step "$desc"
  if "$@"; then
    log_ok "$desc 完成"
    return 0
  fi
  log_error "$desc 失败"
  return 1
}

# ============ 密码 ============
gen_password() {
  local len="${1:-20}" p
  set +o pipefail
  p=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" 2>/dev/null || true)
  set -o pipefail
  printf '%s' "$p"
}

validate_password() {
  local p="$1"
  [[ -n "$p" ]] || { log_error "密码不能为空"; return 1; }
  if [[ "$p" == *"'"* || "$p" == *"\\"* ]]; then
    log_error "密码中不能包含单引号或反斜杠"
    return 1
  fi
  return 0
}

# 优先级：环境变量 > credentials 文件
load_credentials() {
  if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then return 0; fi
  if [[ -r "$MM_CRED_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MM_CRED_FILE"
    return 0
  fi
  return 1
}

save_credentials() {
  mkdir -p "$(dirname "$MM_CRED_FILE")"
  chmod 700 "$(dirname "$MM_CRED_FILE")"
  local old_umask; old_umask="$(umask)"; umask 077
  {
    printf "# 由 mysql-manager 自动生成 %s\n" "$(date '+%F %T')"
    printf "MYSQL_ROOT_PASSWORD='%s'\n"   "$MYSQL_ROOT_PASSWORD"
    printf "MYSQL_VERSION='%s'\n"         "$MYSQL_VERSION"
    printf "MYSQL_PORT='%s'\n"            "$MYSQL_PORT"
    printf "MYSQL_BIND='%s'\n"            "$MYSQL_BIND"
    printf "MYSQL_DEPLOY_MODE='%s'\n"     "$MYSQL_DEPLOY_MODE"
    printf "MYSQL_ALLOW_ROOT_REMOTE='%s'\n" "$MYSQL_ALLOW_ROOT_REMOTE"
  } >"$MM_CRED_FILE"
  chmod 600 "$MM_CRED_FILE"
  umask "$old_umask"
  log_ok "凭据已写入 $MM_CRED_FILE (0600)"
}

# ============ MySQL 抽象层（对原生 / Podman 一致） ============
mysql_exec() {
  local sql="$1"
  if [[ "$MYSQL_DEPLOY_MODE" == "podman" ]]; then
    podman exec -i "$MM_PODMAN_CONTAINER" \
      mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "$sql"
  else
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "$sql"
  fi
}

mysql_exec_stdin() {
  if [[ "$MYSQL_DEPLOY_MODE" == "podman" ]]; then
    podman exec -i "$MM_PODMAN_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
  else
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
  fi
}

mysql_ping() {
  if [[ "$MYSQL_DEPLOY_MODE" == "podman" ]]; then
    podman exec "$MM_PODMAN_CONTAINER" \
      mysqladmin -uroot -p"$MYSQL_ROOT_PASSWORD" ping >/dev/null 2>&1
  else
    mysqladmin -uroot -p"$MYSQL_ROOT_PASSWORD" ping >/dev/null 2>&1
  fi
}

mysql_version() {
  mysql_exec "SELECT VERSION();" 2>/dev/null | tail -n1
}

# ============ 工具 ============
require_root() {
  [[ $EUID -eq 0 ]] || { echo "需要 root 权限（sudo）" >&2; exit 1; }
}

cleanup_old_files() {
  [[ -d "$MM_LOG_DIR" ]] || return 0
  log_step "清理 $MM_LOG_RETAIN_DAYS 天前的日志"
  find "$MM_LOG_DIR" -type f -name '*.log' ! -name 'events.log' \
    -mtime +"$MM_LOG_RETAIN_DAYS" -delete 2>/dev/null || true
}
