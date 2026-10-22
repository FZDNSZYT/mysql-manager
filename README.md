# mysql-manager

MySQL 8.4（原生 RPM）/ 5.7（Podman 容器）一键部署工具，面向 CentOS Stream 10。

## 🚀 快速开始

```bash
git clone https://github.com/FZDNSZYT/mysql-manager.git \
chmod 777 mysql-manager \
bash mysql-manager/install_mysql.sh \
  --version 8.4 \
  --root-password 'YourStr0ngPwd!2025' \
  --allow-root-remote
