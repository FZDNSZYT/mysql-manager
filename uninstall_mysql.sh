#!/usr/bin/env bash
# uninstall_mysql.sh - 卸载 MySQL（默认先备份 datadir）
# 参数：--purge  连数据目录一起删除（会先备份到 /root/mysql-backups）

set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
LOG_MODULE="uninstall"

PURGE="no"
[[ "${1:-}" == "--purge" ]] && PURGE="yes"

main() {
  require_root
  init_logging "uninstall"

  [[ -r "$MM_CRED_FILE" ]] && { # shellcheck disable=SC1090
    source "$MM_CRED_FILE"; } || true

  log_step "停止并清理"
  systemctl stop mysqld 2>/dev/null || true
  systemctl disable mysqld 2>/dev/null || true
  podman stop -t 20 "$MM_PODMAN_CONTAINER" 2>/dev/null || true
  podman rm -f "$MM_PODMAN_CONTAINER" 2>/dev/null || true
  systemctl disable container-mysql57 2>/dev/null || true
  rm -f /etc/systemd/system/container-mysql57.service
  systemctl daemon-reload 2>/dev/null || true

  local pkgs; pkgs=$(rpm -qa 2>/dev/null | grep -E '^mysql-community-' || true)
  if [[ -n "$pkgs" ]]; then
    # shellcheck disable=SC2086
    dnf remove -y $pkgs >/dev/null 2>&1 || true
  fi

  if [[ "$PURGE" == "yes" ]]; then
    local ts; ts="$(date +%Y%m%d_%H%M%S)"
    local bdir="$MM_BACKUP_DIR/uninstall_$ts"
    mkdir -p "$bdir"
    for d in "$MM_NATIVE_DATADIR" "$MM_PODMAN_DATADIR"; do
      [[ -d "$d" && -n "$(ls -A "$d" 2>/dev/null)" ]] || continue
      tar czf "$bdir/$(basename "$(dirname "$d")")_$(basename "$d").tar.gz" -C / "${d#/}" || true
    done
    rm -rf "$MM_NATIVE_DATADIR" "$MM_PODMAN_DATADIR"
    log_ok "数据目录已删，备份至 $bdir"
  fi

  log_ok "卸载完成"
}

main "$@"
