#!/usr/bin/env bash
# install_mysql.sh - MySQL 8.4 / 5.7 一键安装（CentOS Stream 10）
#
# 参数：
#   --version 8.4|5.7              安装版本（默认 8.4；5.7 走 Podman）
#   --root-password <pwd>          指定 root 密码（否则环境变量 > credentials > 随机）
#   --port <port>                  端口（默认 3306）
#   --bind <addr>                  绑定地址（默认 0.0.0.0）
#   --allow-root-remote            允许 root 从任意主机登录（远程控制）
#   --no-fresh                     检测到既有安装时拒绝执行（默认会自动清理）
#   --skip-firewall                不配置 firewalld
#   --force                        无视已有安装与数据目录检查（危险）
#   -h|--help                      帮助

set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
LOG_MODULE="install"

SKIP_FIREWALL="no"
FORCE="no"
CLI_PASSWORD_SET="no"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--version)          MYSQL_VERSION="${2:?}"; shift 2 ;;
      --root-password)       MYSQL_ROOT_PASSWORD="${2:?}"; CLI_PASSWORD_SET="yes"; shift 2 ;;
      -p|--port)             MYSQL_PORT="${2:?}"; shift 2 ;;
      -b|--bind)             MYSQL_BIND="${2:?}"; shift 2 ;;
      --allow-root-remote)   MYSQL_ALLOW_ROOT_REMOTE="yes"; shift ;;
      --no-allow-root-remote) MYSQL_ALLOW_ROOT_REMOTE="no"; shift ;;
      --no-fresh)            MYSQL_FRESH="no"; shift ;;
      --skip-firewall)       SKIP_FIREWALL="yes"; shift ;;
      --force)               FORCE="yes"; MYSQL_FRESH="yes"; shift ;;
      -h|--help)             usage; exit 0 ;;
      *) echo "未知参数: $1"; usage; exit 1 ;;
    esac
  done
}

# ---------------- 前置检查 ----------------
check_requirements() {
  log_step "检查系统要求"

  [[ -f /etc/os-release ]] || { log_error "无法识别 OS"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  log_event "系统: ${PRETTY_NAME:-unknown}, platform=${PLATFORM_ID:-unknown}"

  local mem_mb disk_gb
  mem_mb=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
  disk_gb=$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  log_event "内存 ${mem_mb}MB, /var 可用 ${disk_gb}GB"
  (( mem_mb >= 1024 )) || { log_error "内存 < 1GB，无法安装"; exit 1; }
  (( disk_gb >= 4 ))   || { log_error "磁盘 < 4GB，无法安装"; exit 1; }

  # 网络探测
  log_event "检查外部网络可达性"
  case "$MYSQL_VERSION" in
    5.7)
      curl -fsS --max-time 10 -o /dev/null "https://registry-1.docker.io/v2/" \
        || { log_error "无法访问 docker registry（5.7 走 Podman 需要）"; exit 1; }
      ;;
    *)
      curl -fsS --max-time 10 -o /dev/null "https://repo.mysql.com/RPM-GPG-KEY-mysql-2023" \
        || { log_error "无法访问 repo.mysql.com"; exit 1; }
      ;;
  esac

  case "$MYSQL_VERSION" in
    8.4|8.0|5.7) : ;;
    *) log_error "不支持的版本: $MYSQL_VERSION（8.4 / 5.7）"; exit 1 ;;
  esac
  log_ok "系统检查通过"
}

# ---------------- 已有安装检测 & 自动清理 ----------------
detect_existing() {
  local found=()
  rpm -qa 2>/dev/null | grep -qE '^mysql-community-(server|client)' \
    && found+=("rpm:mysql-community-*")
  podman container exists "$MM_PODMAN_CONTAINER" 2>/dev/null \
    && found+=("podman:$MM_PODMAN_CONTAINER")
  [[ -d "$MM_NATIVE_DATADIR" && -n "$(ls -A "$MM_NATIVE_DATADIR" 2>/dev/null)" ]] \
    && found+=("datadir:$MM_NATIVE_DATADIR")
  [[ -d "$MM_PODMAN_DATADIR" && -n "$(ls -A "$MM_PODMAN_DATADIR" 2>/dev/null)" ]] \
    && found+=("datadir:$MM_PODMAN_DATADIR")

  if (( ${#found[@]} == 0 )); then
    log_ok "未检测到既有安装，直接开始部署"
    return 0
  fi

  log_warn "检测到既有安装/残留："
  printf '    %s\n' "${found[@]}"

  [[ "$MYSQL_FRESH" == "yes" || "$FORCE" == "yes" ]] || {
    log_error "如需自动清理并重装，请加 --fresh（默认）"
    log_error "如确认手工清理，删除后再执行"
    exit 1
  }
  do_cleanup
}

do_cleanup() {
  log_step "自动清理历史安装（先备份 datadir 到 $MM_BACKUP_DIR）"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local bdir="$MM_BACKUP_DIR/preinstall_$ts"
  mkdir -p "$bdir"; chmod 700 "$bdir"

  # 1) 停服务
  systemctl stop mysqld 2>/dev/null || true
  systemctl disable mysqld 2>/dev/null || true
  pkill -9 -x mysqld 2>/dev/null || true
  podman stop -t 10 "$MM_PODMAN_CONTAINER" 2>/dev/null || true
  podman rm -f "$MM_PODMAN_CONTAINER" 2>/dev/null || true

  # 2) 备份 datadir
  for d in "$MM_NATIVE_DATADIR" "$MM_PODMAN_DATADIR"; do
    if [[ -d "$d" && -n "$(ls -A "$d" 2>/dev/null)" ]]; then
      local name; name="$(basename "$(dirname "$d")")_$(basename "$d")"
      log_event "备份 $d → $bdir/$name.tar.gz"
      tar czf "$bdir/$name.tar.gz" -C / "${d#/}" 2>/dev/null \
        || log_warn "备份 $d 失败（继续清理）"
    fi
  done

  # 3) 卸载 rpm
  local pkgs; pkgs=$(rpm -qa 2>/dev/null | grep -E '^mysql-community-|^mysql57|^mysql-libs|^mysql-server|^mariadb' || true)
  if [[ -n "$pkgs" ]]; then
    log_event "卸载 MySQL/MariaDB 残留包"
    # shellcheck disable=SC2086
    dnf remove -y $pkgs >/dev/null 2>&1 || \
      # shellcheck disable=SC2086
      rpm -e --noscripts --nodeps $pkgs 2>/dev/null || \
      log_warn "部分 rpm 卸载失败，可手工处理"
  fi

  # 4) repo / conf / 数据目录 / 日志 / 二进制残留
  local targets=(
    /etc/yum.repos.d/mysql-community.repo
    /etc/yum.repos.d/mysql57-community.repo
    /etc/my.cnf /etc/my.cnf.d /etc/mysql
    /usr/lib64/mysql /usr/share/mysql
    /var/log/mysqld.log
    /var/log/mysql
    "$MM_NATIVE_DATADIR"
    "$MM_PODMAN_DATADIR"
  )
  for t in "${targets[@]}"; do
    if [[ -e "$t" ]]; then
      log_event "清理 $t"
      rm -rf "$t"
    fi
  done
  shopt -s nullglob
  for f in /etc/yum.repos.d/*[Mm]ysql*.repo; do log_event "清理 $f"; rm -f "$f"; done
  shopt -u nullglob

  # 5) SELinux fcontext
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -d -t mysqld_db_t '/var/lib/mysql(.*)?' 2>/dev/null || true
    semanage fcontext -d -t mysqld_db_t '/var/lib/mysql57(.*)?' 2>/dev/null || true
  fi

  log_ok "历史安装清理完成，旧数据备份到 $bdir"
}

# ---------------- 8.4 原生部署 ----------------
deploy_native_84() {
  log_step "开始部署 MySQL ${MYSQL_VERSION}（原生 RPM）"
  MYSQL_DEPLOY_MODE="native"

  dnf install -y dnf-plugins-core curl tar firewalld policycoreutils-python-utils >/dev/null
  systemctl enable --now firewalld 2>/dev/null || true

  local repo_base
  case "$MYSQL_VERSION" in
    8.4) repo_base="mysql-8.4-community" ;;
    8.0) repo_base="mysql-8.0-community" ;;
  esac

  log_event "导入 GPG Key"
  rpm --import "https://repo.mysql.com/RPM-GPG-KEY-mysql-2023"

  log_event "写入 $MM_CONF_DIR/mysql-community.repo"
  mkdir -p "$MM_CONF_DIR"
  cat >"$MM_CONF_DIR/mysql-community.repo" <<EOF
[mysql-community]
name=MySQL ${MYSQL_VERSION} Community Server
baseurl=https://repo.mysql.com/yum/${repo_base}/el/10/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://repo.mysql.com/RPM-GPG-KEY-mysql-2023
module_hotfixes=1
EOF
  cp -f "$MM_CONF_DIR/mysql-community.repo" /etc/yum.repos.d/mysql-community.repo

  log_event "dnf makecache"
  dnf makecache -q || true

  log_event "安装 mysql-community-server/client"
  dnf install -y mysql-community-server mysql-community-client

  # 自定义配置
  log_event "写入自定义配置 /etc/my.cnf.d/99-mysql-manager.cnf"
  mkdir -p /etc/my.cnf.d
  local mem_mb pool
  mem_mb=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
  if   (( mem_mb >= 65536 )); then pool="32G"
  elif (( mem_mb >= 32768 )); then pool="16G"
  elif (( mem_mb >= 16384 )); then pool="8G"
  elif (( mem_mb >= 8192  )); then pool="4G"
  elif (( mem_mb >= 4096  )); then pool="1G"
  else                            pool="512M"
  fi
  cat >/etc/my.cnf.d/99-mysql-manager.cnf <<EOF
[mysqld]
port=${MYSQL_PORT}
bind-address=${MYSQL_BIND}
character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci
innodb_buffer_pool_size=${pool}
max_connections=500
max_allowed_packet=256M
slow_query_log=1
long_query_time=2
slow_query_log_file=/var/log/mysql-manager/slow.log
default-time-zone='+08:00'
skip_name_resolve=1
log_error=/var/log/mysqld.log

[client]
port=${MYSQL_PORT}
default-character-set=utf8mb4
EOF
  mkdir -p /var/log/mysql-manager
  chown mysql:mysql /var/log/mysql-manager

  log_event "启动 mysqld"
  systemctl daemon-reload
  systemctl enable mysqld >/dev/null
  systemctl restart mysqld

  wait_ready
  set_root_password_native
  secure_mysql_native
  open_remote_native
}

wait_ready() {
  log_step "等待 MySQL 就绪（最多 180s）"
  local i
  for ((i=0; i<180; i++)); do
    if [[ "$MYSQL_DEPLOY_MODE" == "podman" ]]; then
      podman exec "$MM_PODMAN_CONTAINER" mysqladmin -uroot -p"$MYSQL_ROOT_PASSWORD" ping >/dev/null 2>&1 && {
        log_ok "MySQL 已就绪"; return 0; }
    else
      mysqladmin --protocol=socket ping >/dev/null 2>&1 && { log_ok "MySQL 已就绪"; return 0; }
    fi
    sleep 1
  done
  log_error "MySQL 启动超时"
  [[ "$MYSQL_DEPLOY_MODE" == "podman" ]] && podman logs --tail 40 "$MM_PODMAN_CONTAINER" >&2 || \
    tail -n 40 /var/log/mysqld.log >&2 || true
  exit 1
}

set_root_password_native() {
  log_step "设置 root@localhost 密码（全局变量 MYSQL_ROOT_PASSWORD）"
  validate_password "$MYSQL_ROOT_PASSWORD"
  if mysql --protocol=socket -uroot -e "SELECT 1" >/dev/null 2>&1; then
    mysql --protocol=socket -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL
    log_ok "root 密码已在 MySQL 内生效"
  elif mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
    log_event "root 已能使用目标密码登录，跳过"
  else
    log_error "无法连接 MySQL 设置 root 密码"
    exit 1
  fi
}

secure_mysql_native() {
  log_step "基础安全加固"
  mysql_exec_stdin <<'SQL'
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
SQL
  log_ok "安全加固完成"
}

open_remote_native() {
  if [[ "$MYSQL_ALLOW_ROOT_REMOTE" != "yes" ]]; then
    log_event "未开启 root 远程登录（如需要，使用 --allow-root-remote）"
    return 0
  fi
  log_step "开启 root 远程登录（root@'%'）"
  mysql_exec "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}'; \
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;"
  log_ok "root@'%' 创建完成，请确保网络边界与防火墙策略安全"

  if [[ "$SKIP_FIREWALL" != "yes" ]] && systemctl is-active --quiet firewalld; then
    if [[ "$MYSQL_PORT" == "3306" ]]; then
      firewall-cmd --permanent --add-service=mysql >/dev/null
    else
      firewall-cmd --permanent --add-port="${MYSQL_PORT}/tcp" >/dev/null
    fi
    firewall-cmd --reload >/dev/null
    log_ok "firewalld 已放行 MySQL 端口"
  fi
}

# ---------------- 5.7 Podman 部署 ----------------
deploy_podman_57() {
  log_step "开始部署 MySQL 5.7（Podman 容器）"
  MYSQL_DEPLOY_MODE="podman"

  dnf install -y podman firewalld policycoreutils-python-utils >/dev/null
  systemctl enable --now firewalld 2>/dev/null || true

  mkdir -p "$MM_PODMAN_DATADIR" "$MM_CONF_DIR" /var/log/mysql-manager/mysql57
  chmod 750 "$MM_PODMAN_DATADIR"
  # 适配 mysql 用户（镜像内 uid=999）
  [[ -z "$(ls -A "$MM_PODMAN_DATADIR")" ]] && chown 999:999 "$MM_PODMAN_DATADIR" || true

  local bind="$MYSQL_BIND"
  cat >"$MM_CONF_DIR/mysql57.cnf" <<EOF
[mysqld]
port=${MYSQL_PORT}
bind-address=${bind}
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
max_connections=500
max_allowed_packet=256M
default-time-zone='+08:00'
log_error=/var/log/mysql/error.log
slow_query_log=1
long_query_time=2

[client]
port=${MYSQL_PORT}
default-character-set=utf8mb4
EOF

  log_event "拉取镜像 $MM_PODMAN_IMAGE"
  podman pull "$MM_PODMAN_IMAGE"

  local env_opts=(-e "TZ=Asia/Shanghai" -e "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD")
  if [[ "$MYSQL_ALLOW_ROOT_REMOTE" == "yes" ]]; then
    env_opts+=(-e "MYSQL_ROOT_HOST=%")
    log_event "已启用 root 远程访问（MYSQL_ROOT_HOST=%）"
  fi

  log_event "启动容器 $MM_PODMAN_CONTAINER"
  podman run -d --name "$MM_PODMAN_CONTAINER" \
    --restart=always \
    --network host \
    "${env_opts[@]}" \
    -v "${MM_PODMAN_DATADIR}:/var/lib/mysql:Z" \
    -v "${MM_CONF_DIR}/mysql57.cnf:/etc/mysql/conf.d/zz-mysql-manager.cnf:Z" \
    -v "/var/log/mysql-manager/mysql57:/var/log/mysql:Z" \
    "$MM_PODMAN_IMAGE"

  log_event "生成 systemd 单元 container-mysql57.service"
  cat >/etc/systemd/system/container-mysql57.service <<EOF
[Unit]
Description=MySQL 5.7 (Podman container)
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
Restart=always
RestartSec=5
ExecStart=/usr/bin/podman start ${MM_PODMAN_CONTAINER}
ExecStop=/usr/bin/podman stop -t 60 ${MM_PODMAN_CONTAINER}
ExecStartPost=/usr/bin/podman ps ${MM_PODMAN_CONTAINER}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable container-mysql57 >/dev/null 2>&1 || true

  wait_ready

  if [[ "$SKIP_FIREWALL" != "yes" ]] && systemctl is-active --quiet firewalld; then
    if [[ "$MYSQL_PORT" == "3306" ]]; then
      firewall-cmd --permanent --add-service=mysql >/dev/null
    else
      firewall-cmd --permanent --add-port="${MYSQL_PORT}/tcp" >/dev/null
    fi
    firewall-cmd --reload >/dev/null
    log_ok "firewalld 已放行 MySQL 端口"
  fi
}

# ---------------- 收尾 ----------------
verify_install() {
  log_step "验证安装"
  local ver; ver="$(mysql_version || true)"
  [[ -n "$ver" ]] && log_ok "MySQL 版本: $ver" || { log_error "无法获取版本，请检查日志"; exit 1; }

  if [[ "$MYSQL_DEPLOY_MODE" == "podman" ]]; then
    podman ps --filter "name=$MM_PODMAN_CONTAINER" --format '{{.Status}}' >/dev/null \
      && log_ok "容器运行中"
  else
    systemctl is-active --quiet mysqld && log_ok "mysqld 服务运行中"
  fi

  mysql_exec "SELECT @@port, @@bind_address;" || true
}

print_summary() {
  {
    echo
    printf '%s================ MySQL 部署完成 ================%s\n' "$C_BLD" "$C_NC"
    printf '  版本        : %s (%s)\n' "$MYSQL_VERSION" "$MYSQL_DEPLOY_MODE"
    printf '  监听        : %s:%s\n' "$MYSQL_BIND" "$MYSQL_PORT"
    printf '  root 远程   : %s\n' "$MYSQL_ALLOW_ROOT_REMOTE"
    printf '  root 密码   : %s\n' "$MYSQL_ROOT_PASSWORD"
    printf '  凭据文件    : %s\n' "$MM_CRED_FILE"
    printf '  运行日志    : %s\n' "$MYSQL_RUN_LOG"
    printf '  事件日志    : %s\n' "$MM_EVENT_LOG"
    printf '%s------------------------------------------------%s\n' "$C_BLD" "$C_NC"
    printf '  常用命令:\n'
    printf '    改密码 : bash %s/reset_mysql_password.sh\n' "$SELF_DIR"
    printf '    备份   : bash %s/backup_mysql.sh\n' "$SELF_DIR"
    printf '    状态   : %s\n' "$([[ "$MYSQL_DEPLOY_MODE" == "podman" ]] && echo "podman ps" || echo "systemctl status mysqld")"
    printf '%s================================================%s\n' "$C_BLD" "$C_NC"
  } | tee -a "$MYSQL_RUN_LOG"
}

# ---------------- 主流程 ----------------
main() {
  parse_args "$@"

  require_root
  init_logging "install"

  # 密码优先级：命令行 > 环境变量 > credentials > 随机
  if [[ "$CLI_PASSWORD_SET" != "yes" && -z "${MYSQL_ROOT_PASSWORD:-}" ]] \
        && [[ -r "$MM_CRED_FILE" ]]; then
    load_credentials || true
    log_event "从 $MM_CRED_FILE 读取预置密码"
  fi
  if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    MYSQL_ROOT_PASSWORD="$(gen_password 20)"
    log_warn "未指定密码，已随机生成（请从输出中保存）"
  fi
  validate_password "$MYSQL_ROOT_PASSWORD"

  check_requirements
  detect_existing

  case "$MYSQL_VERSION" in
    8.4|8.0) deploy_native_84 ;;
    5.7)     deploy_podman_57 ;;
  esac

  verify_install
  save_credentials

  # 安装完成后清理过期日志（30 天）
  cleanup_old_files

  print_summary
  log_ok "安装任务结束"
}

main "$@"
