#!/usr/bin/env bash
# reset_mysql_password.sh - 随时修改 MySQL root 密码
#
# 用法：
#   bash reset_mysql_password.sh                       # 随机生成新密码
#   bash reset_mysql_password.sh --password 'NewPwd@123'
#   bash reset_mysql_password.sh --old-password 'Old'  # 指定旧密码
#   bash reset_mysql_password.sh --force-reset         # 忘密码（8.4 走 skip-grant-tables）
#
# 说明：
#   - 未安装时：仅把密码预置到 /root/.mysql/credentials（供后续安装使用）
#   - 已安装时：ALTER USER 并同步 credentials

set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
LOG_MODULE="reset-pwd"

NEW_PASSWORD=""
OLD_PASSWORD=""
FORCE_RESET="no"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password)     NEW_PASSWORD="${2:?}"; shift 2 ;;
      --old-password) OLD_PASSWORD="${2:?}"; shift 2 ;;
      --force-reset)  FORCE_RESET="yes"; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) echo "未知参数: $1"; usage; exit 1 ;;
    esac
  done
}

detect_installed() {
  [[ -r "$MM_CRED_FILE" ]] && { # shellcheck disable=SC1090
    source "$MM_CRED_FILE"; } || true

  if [[ "${MYSQL_DEPLOY_MODE:-}" == "podman" ]] && podman container exists "$MM_PODMAN_CONTAINER" 2>/dev/null; then
    return 0
  fi
  if rpm -q mysql-community-server >/dev/null 2>&1 && systemctl is-enabled mysqld >/dev/null 2>&1; then
    MYSQL_DEPLOY_MODE="native"; return 0
  fi
  return 1
}

change_native() {
  local old="${OLD_PASSWORD:-$MYSQL_ROOT_PASSWORD}"

  if [[ "$FORCE_RESET" == "yes" ]]; then
    log_step "【force-reset】通过 skip-grant-tables 重置 root 密码"
    local override="/etc/my.cnf.d/zz-zz-skip-grant.cnf"
    cat >"$override" <<EOF
[mysqld]
skip-grant-tables
skip-networking
EOF
    systemctl restart mysqld
    sleep 3
    mysql --protocol=socket -uroot <<SQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASSWORD}';
FLUSH PRIVILEGES;
SQL
    rm -f "$override"
    systemctl restart mysqld
    return 0
  fi

  log_step "尝试用旧密码登录并修改"
  mysql -uroot -p"$old" -e "SELECT 1" >/dev/null 2>&1 || {
    log_error "旧密码不正确。若已忘记密码，请使用 --force-reset"
    return 1
  }
  mysql -uroot -p"$old" <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASSWORD}';
ALTER USER 'root'@'%' IDENTIFIED BY '${NEW_PASSWORD}';
FLUSH PRIVILEGES;
SQL
}

change_podman() {
  local old="${OLD_PASSWORD:-$MYSQL_ROOT_PASSWORD}"
  log_step "在容器 $MM_PODMAN_CONTAINER 内修改 root 密码"
  if ! podman exec "$MM_PODMAN_CONTAINER" mysql -uroot -p"$old" -e "SELECT 1" >/dev/null 2>&1; then
    log_error "旧密码不正确。5.7 容器下重新设密码流程见 README「忘记密码」"
    return 1
  fi
  podman exec -i "$MM_PODMAN_CONTAINER" mysql -uroot -p"$old" <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASSWORD}';
ALTER USER 'root'@'%' IDENTIFIED BY '${NEW_PASSWORD}';
FLUSH PRIVILEGES;
SQL
}

main() {
  parse_args "$@"
  require_root
  init_logging "reset-pwd"

  if [[ -z "$NEW_PASSWORD" ]]; then
    NEW_PASSWORD="$(gen_password 20)"
    log_warn "未指定新密码，已随机生成"
  fi
  validate_password "$NEW_PASSWORD"

  if detect_installed; then
    log_event "检测到已安装（deploy_mode=$MYSQL_DEPLOY_MODE），开始修改"
    if [[ "$MYSQL_DEPLOY_MODE" == "podman" ]]; then
      change_podman || { log_error "修改失败"; exit 1; }
    else
      change_native || { log_error "修改失败"; exit 1; }
    fi
    MYSQL_ROOT_PASSWORD="$NEW_PASSWORD"
    save_credentials
    log_ok "密码已修改"
  else
    log_warn "未检测到已安装的 MySQL —— 仅更新凭据文件（预置密码）"
    MYSQL_ROOT_PASSWORD="$NEW_PASSWORD"
    save_credentials
    log_ok "已写入 $MM_CRED_FILE，下一次 install_mysql.sh 将直接使用"
  fi

  echo
  printf '%s新密码: %s%s\n' "$C_BLD" "$NEW_PASSWORD" "$C_NC"
  printf '%s保存位置: %s%s\n' "$C_BLD" "$MM_CRED_FILE" "$C_NC"
}

main "$@"
