#!/usr/bin/env bash
# restore_mysql.sh - MySQL 备份恢复（8.4 原生 / 5.7 Podman 均支持）
#
# 用法：
#   bash restore_mysql.sh --list                            # 列出所有备份
#   bash restore_mysql.sh --latest                          # 恢复最新一次
#   bash restore_mysql.sh --backup-dir /root/mysql-backups/host_20250314_031500
#   bash restore_mysql.sh --latest --db appdb               # 只恢复一个库
#   bash restore_mysql.sh --latest --yes                    # 跳过确认
#   bash restore_mysql.sh --latest --no-backup-before       # 不做恢复前快照（危险）
#
# 行为：
#   1) 校验 md5，防止备份损坏
#   2) 默认在恢复前自动备份当前状态（可 --no-backup-before 关闭）
#   3) 恢复完成后重启服务并打印复核信息

set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
LOG_MODULE="restore"

LIST_ONLY="no"
USE_LATEST="no"
TARGET_DIR=""
DB_ONLY=""
ASSUME_YES="no"
BACKUP_BEFORE="yes"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)              LIST_ONLY="yes"; shift ;;
      --latest)            USE_LATEST="yes"; shift ;;
      --backup-dir)        TARGET_DIR="${2:?}"; shift 2 ;;
      --db)                DB_ONLY="${2:?}"; shift 2 ;;
      --yes|-y)            ASSUME_YES="yes"; shift ;;
      --no-backup-before)  BACKUP_BEFORE="no"; shift ;;
      -h|--help)           usage; exit 0 ;;
      *) echo "未知参数: $1"; usage; exit 1 ;;
    esac
  done
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

# 列出所有备份
list_backups() {
  local root="$1"
  [[ -d "$root" ]] || { log_error "备份目录不存在: $root"; return 1; }

  printf '\n%s%-45s %-10s %-8s %-10s %s%s\n' \
    "$C_BLD" "备份目录" "时间" "大小" "版本" "范围" "$C_NC"
  printf '%s\n' "---------------------------------------------------------------------------------------"

  local found=0 d meta ts size ver scope
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    meta="$d/metadata.txt"
    ts="-"; size="-"; ver="-"; scope="-"
    if [[ -f "$meta" ]]; then
      # shellcheck disable=SC1090
      ts=$(awk -F=  '/^time=/{print $2}' "$meta" || echo -)
      ver=$(awk -F= '/^version=/{print $2}' "$meta" || echo -)
      scope=$(awk -F= '/^scope=/{print $2}' "$meta" || echo -)
    fi
    size=$(du -sh "$d" 2>/dev/null | cut -f1 || echo -)
    printf '%-45s %-10s %-8s %-10s %s\n' "$d" "$ts" "$size" "$ver" "$scope"
    found=1
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)

  (( found )) || log_warn "未找到任何备份目录"
}

# 找到需要恢复的目录
resolve_target() {
  local root="$MM_BACKUP_DIR"

  if [[ "$USE_LATEST" == "yes" ]]; then
    # 优先 latest 软链，其次按名字排序
    if [[ -L "$root/latest" ]]; then
      TARGET_DIR="$(readlink -f "$root/latest")"
    else
      TARGET_DIR=$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)
    fi
  fi

  [[ -n "$TARGET_DIR" ]] || { log_error "未指定备份（--latest 或 --backup-dir）"; exit 1; }
  [[ -d "$TARGET_DIR" ]] || { log_error "备份目录不存在: $TARGET_DIR"; exit 1; }
  log_event "目标备份: $TARGET_DIR"
}

# 校验 md5
verify_md5() {
  local dir="$1"
  shopt -s nullglob
  local md5s=("$dir"/*.md5)
  shopt -u nullglob
  (( ${#md5s[@]} )) || { log_warn "无 md5 文件，跳过校验"; return 0; }

  log_step "校验备份完整性"
  pushd "$dir" >/dev/null
  if ! md5sum -c ./*.md5 --quiet; then
    popd >/dev/null
    log_error "md5 校验失败，备份文件可能损坏"
    return 1
  fi
  popd >/dev/null
  log_ok "md5 校验通过"
}

# 找到 dump 文件
find_dump_file() {
  local dir="$1"
  shopt -s nullglob
  local dumps=("$dir"/*.sql.gz)
  shopt -u nullglob
  (( ${#dumps[@]} )) || { log_error "目录中无 *.sql.gz 文件"; exit 1; }
  printf '%s' "${dumps[0]}"
}

# 恢复前快速快照
pre_restore_snapshot() {
  [[ "$BACKUP_BEFORE" == "yes" ]] || { log_warn "跳过恢复前快照"; return 0; }

  log_step "恢复前自动快照当前数据库"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local host; host="$(hostname -s 2>/dev/null || echo host)"
  local target="$MM_BACKUP_DIR/${host}_${ts}_pre-restore"

  if bash "$SELF_DIR/backup_mysql.sh" >/dev/null 2>&1; then
    # 把最新一次备份改名标记为 pre-restore
    [[ -L "$MM_BACKUP_DIR/latest" ]] && {
      local src; src="$(readlink -f "$MM_BACKUP_DIR/latest")"
      [[ "$src" != "$target" ]] && mv "$src" "$target" && ln -sfn "$target" "$MM_BACKUP_DIR/latest"
    }
    log_ok "恢复前快照完成 → $target"
  else
    log_warn "恢复前快照失败（继续，但请确认备份可用）"
  fi

  [[ -f "$MM_CRED_FILE" ]] && source "$MM_CRED_FILE" || true
  detect_deploy_mode
}

# 恢复
do_restore() {
  local dump_file="$1"
  log_step "开始恢复: $dump_file"

  local restore_cmd
  if [[ "$MYSQL_DEPLOY_MODE" == "podman" ]]; then
    log_event "通过 podman exec 恢复"
    if [[ -n "$DB_ONLY" ]]; then
      zcat "$dump_file" | podman exec -i "$MM_PODMAN_CONTAINER" \
        mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_ONLY"
    else
      zcat "$dump_file" | podman exec -i "$MM_PODMAN_CONTAINER" \
        mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
    fi
  else
    log_event "通过本地 mysql 客户端恢复"
    if [[ -n "$DB_ONLY" ]]; then
      zcat "$dump_file" | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_ONLY"
    else
      zcat "$dump_file" | mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
    fi
  fi

  log_ok "恢复完成"
}

# 恢复后复核
verify_restore() {
  log_step "复核恢复结果"
  local ver; ver="$(mysql_version || true)"
  [[ -n "$ver" ]] && log_ok "MYSQL 可访问: $ver"

  if [[ -n "$DB_ONLY" ]]; then
    mysql_exec "SELECT COUNT(*) AS tables FROM information_schema.tables WHERE table_schema='${DB_ONLY}';" || true
  else
    mysql_exec "SHOW DATABASES;" || true
  fi
  log_event "复核完毕"
}

# 交互确认
confirm() {
  [[ "$ASSUME_YES" == "yes" ]] && return 0
  [[ -t 0 ]] || { log_warn "非交互式环境，跳过确认（如需强制，请加 --yes）"; return 1; }

  printf '%s即将从 %s 恢复%s\n' "$C_YEL" "$TARGET_DIR" "$C_NC"
  printf '%s        范围: %s%s\n' "$C_YEL" "${DB_ONLY:-全部数据库}" "$C_NC"
  printf '%s        当前模式: %s%s\n' "$C_YEL" "$MYSQL_DEPLOY_MODE" "$C_NC"
  printf '%s恢复会 DROP 并重建同名表，请确认已备份！%s\n' "$C_RED" "$C_NC"
  read -r -p "确认输入 YES 继续: " ans
  [[ "$ans" == "YES" ]] || { log_warn "用户取消"; exit 1; }
}

main() {
  parse_args "$@"
  require_root
  init_logging "restore"
  detect_deploy_mode

  if [[ "$LIST_ONLY" == "yes" ]]; then
    list_backups "$MM_BACKUP_DIR"
    exit 0
  fi

  if ! load_credentials; then
    log_error "缺少凭据文件 $MM_CRED_FILE，请先安装或 reset"
    exit 1
  fi

  resolve_target
  verify_md5 "$TARGET_DIR"
  local dump_file; dump_file=$(find_dump_file "$TARGET_DIR")
  log_event "备份文件: $dump_file"

  confirm
  pre_restore_snapshot

  # 保险起见，重新读一次凭据
  load_credentials || true

  do_restore "$dump_file"
  verify_restore

  log_ok "===== 恢复任务结束 ====="
}

main "$@"
