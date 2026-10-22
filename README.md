# mysql-manager

MySQL 8.4（原生 RPM）/ 5.7（Podman 容器）一键部署工具，面向 CentOS Stream 10。

## 🚀 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/FZDNSZYT/mysql-manager/main/bootstrap.sh \
  | sudo bash -s -- --version 8.4 --root-password 'YourPwd' --allow-root-remote
