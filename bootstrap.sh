#!/usr/bin/env bash
# bootstrap.sh - 从 GitHub 拉取全套脚本并执行 install_mysql.sh
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/yourname/mysql-manager/main/bootstrap.sh \
#     | sudo bash -s -- --version 8.4 --allow-root-remote
#   或本地：
#   sudo bash bootstrap.sh --version 5.7
set -Eeuo pipefail

MM_REPO_RAW="${MM_REPO_RAW:-https://raw.githubusercontent.com/FZDNSZYT/mysql-manager/main}"
MM_INSTALL_DIR="${MM_INSTALL_DIR:-/opt/mysql-manager}"

[[ $EUID -eq 0 ]] || { echo "需要 root 权限"; exit 1; }
command -v curl >/dev/null || {
  echo "安装 curl ..."
  if command -v dnf >/dev/null; then dnf install -y curl; \
  elif command -v apt >/dev/null; then apt-get update -y && apt-get install -y curl; fi
}

mkdir -p "$MM_INSTALL_DIR/lib"
echo "[*] 下载 mysql-manager 到 $MM_INSTALL_DIR (来源: $MM_REPO_RAW)"

FILES=(
  "lib/common.sh"
  "install_mysql.sh"
  "reset_mysql_password.sh"
  "backup_mysql.sh"
  "uninstall_mysql.sh"
  "restore_mysql.sh"
)

for f in "${FILES[@]}"; do
  echo "  - $f"
  if ! curl -fsSL --retry 3 --retry-delay 2 \
      -o "$MM_INSTALL_DIR/$f.tmp" "$MM_REPO_RAW/$f"; then
    echo "[x] 下载失败: $f"; exit 1
  fi
  mv "$MM_INSTALL_DIR/$f.tmp" "$MM_INSTALL_DIR/$f"
  [[ "$f" == *.sh ]] && chmod +x "$MM_INSTALL_DIR/$f"
done

# 校验下载完整性（若提供 MANIFEST）
if curl -fsSL -o "$MM_INSTALL_DIR/MANIFEST.sha256" "$MM_REPO_RAW/MANIFEST.sha256" 2>/dev/null; then
  echo "[*] 校验 MANIFEST ..."
  ( cd "$MM_INSTALL_DIR" && sha256sum -c MANIFEST.sha256 --quiet ) \
    && echo "[+] 校验通过" || { echo "[x] 校验失败，中止"; exit 1; }
fi

echo "[+] 下载完成，开始执行 install_mysql.sh $*"
exec bash "$MM_INSTALL_DIR/install_mysql.sh" "$@"
