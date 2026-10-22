#!/usr/bin/env bash
# backup_mysql.sh - MySQL 备份脚本（cron 友好），自带 30 天清理
#
# 用法：
#   bash backup_mysql.sh                # 全库备份
#   bash backup_mysql.sh --db appdb     # 单库
#   bash backup_mysql.sh --quiet        # cron 用，终端静默
#   bash backup_mysql.sh --no-clean     # 跳过过期清理

set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
LOG_MODULE="backup"

QUIET="no"
DB_ONLY=""
DO_CLEAN="yes"
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || echo host)"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db)       DB_ONLY="${2:?}"; shift 2 ;;
      --quiet|-q) QUIET="yes"; shift ;;
      --no-clean) DO_CLEAN="no"; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) echo "未知参数: $1"; usage; exit 1 ;;
    esac
  done
}

# 只写事件日志；终端静默模式下不刷屏
_bk_log() {
  local level="$1"; shift
  _event "$level" "$LOG_MODULE" "$*"
  if [[ "$QUIET" != "yes" ]]; then
    _emit "$C_BLU" "[$level]" "$*"
  fi
}

detect_deploy_mode() {
  if [[ -r "$MM_CRED_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MM_CRED_FILE"
  fi
  if [[ "${MYSQL_DEPLOY_MODE:-native}" == "podman" ]] \
        && podman container exists "$MM_PODMAN_CONTAINER" 2>/dev/null; then
    MYSQL_DEPLOY_MODE="podman"
  else
    MYSQL_DEPLOY_MODE="native"
  fi
}

run_dump() {
  local target="$1"
  mkdir -p "$target"; chmod 700 "$target"

  local dump_file="${target}/mysql-${DB_ONLY:-all}-${TS}.sql.gz"
  _bk_log INFO "备份输出: $dump_file"

  local extra="" mode_flag=""
  # 版本适配
  local ver; ver="$(mysql_version 2>/dev/null || echo "")"
  if [[ "$ver" == 5.7.* ]]; then
    mode_flag="--master-data=2"
  else
    mode_flag="--source-data=2"
  fi

  if [[ "$MYSQL_DEPLOY_MODE" == "podman" ]]; then
    _bk_log INFO "在容器 $MM_PODMAN_CONTAINER 内执行 mysqldump"
    local args=(
      mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD"
      --single-transaction --routines --triggers --events
      --set-gtid-purged=OFF "$mode_flag" --hex-blob
      --default-character-set=utf8mb4
    )
    if [[ -n "$DB_ONLY" ]]; then
      args+=(--databases "$DB_ONLY")
    else
      args+=(--all-databases)
    fi
    podman exec "$MM_PODMAN_CONTAINER" "${args[@]}" | gzip -c >"$dump_file"
  else
    _bk_log INFO "使用本地 mysqldump"
    local cnf; cnf="$(mktemp /tmp/.bmXXXXXX.cnf)"
    chmod 600 "$cnf"
    cat >"$cnf" <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
EOF
    local args=(
      --defaults-extra-file="$cnf"
      --single-transaction --routines --triggers --events
      --set-gtid-purged=OFF "$mode_flag" --hex-blob
      --default-character-set=utf8mb4
    )
    if [[ -n "$DB_ONLY" ]]; then
      args+=(--databases "$DB_ONLY")
    else
      args+=(--all-databases)
    fi
    if ! mysqldump "${args[@]}" | gzip -c >"$dump_file"; then
      rm -f "$cnf"
      _bk_log ERROR "mysqldump 失败"
      return 1
    fi
    rm -f "$cnf"
  fi

  # md5 + 元信息
  ( cd "$target" && md5sum "$(basename "$dump_file")" > "$(basename "$dump_file").md5" )
  {
    echo "host=$HOST"
    echo "time=$TS"
    echo "mode=$MYSQL_DEPLOY_MODE"
    echo "version=$ver"
    echo "scope=${DB_ONLY:-ALL}"
    echo "file=$(basename "$dump_file")"
    echo "size=$(du -h "$dump_file" | cut -f1)"
  } >"${target}/metadata.txt"

  _bk_log OK "备份完成 ($(du -h "$dump_file" | cut -f1))"

  # 更新 latest 软链
  ln -sfn "$target" "$MM_BACKUP_DIR/latest"
}

cleanup_expired() {
  _bk_log INFO "清理 ${MM_BACKUP_RETAIN_DAYS} 天前的备份与 ${MM_LOG_RETAIN_DAYS} 天前的日志"
  [[ -d "$MM_BACKUP_DIR" ]] || return 0

  # 保留 latest 软链指向的目录（不因 mtime 被误删）
  local latest=""
  [[ -L "$MM_BACKUP_DIR/latest" ]] && latest="$(readlink -f "$MM_BACKUP_DIR/latest")"

  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ -n "$latest" && "$d" == "$latest" ]] && continue
    _bk_log INFO "删除过期备份 $d"
    rm -rf -- "$d"
  done < <(find "$MM_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
            -name "$HOST"_'*' -mtime +"$MM_BACKUP_RETAIN_DAYS" 2>/dev/null)

  # 日志（保留 events.log）
  find "$MM_LOG_DIR" -type f -name '*.log' ! -name 'events.log' \
    -mtime +"$MM_LOG_RETAIN_DAYS" -delete 2>/dev/null || true

  _bk_log OK "过期清理完成"
}

main() {
  parse_args "$@"
  require_root

  # 备份任务：运行日志单独一份（cron 下也很轻量）
  init_logging "backup"
  detect_deploy_mode

  if ! load_credentials; then
    log_error "未找到密码凭据：$MM_CRED_FILE；请先运行 install 或 reset"
    exit 1
  fi

  log_event "开始备份（mode=$MYSQL_DEPLOY_MODE scope=${DB_ONLY:-ALL}）"
  local target="${MM_BACKUP_DIR}/${HOST}_${TS}"
  if run_dump "$target"; then
    log_ok "备份成功 → $target"
  else
    log_error "备份失败"
    exit 1
  fi

  [[ "$DO_CLEAN" == "yes" ]] && cleanup_expired

  log_event "备份任务结束"
}

main "$@"
