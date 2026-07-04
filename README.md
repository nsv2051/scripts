# 一键设置密钥登陆
 ```
 curl -s https://gitproxy.eu.org/https://raw.githubusercontent.com/nsv2051/scripts/main/add_ssh_key.sh | bash
 ```
# Time Sync Script

这是一个用于设置系统时区并同步时间的 shell 脚本，适用于多种 Linux 系统。它将时区设置为 `Asia/Shanghai`，并通过 `ntpdate` 从 `pool.ntp.org` 同步时间，同时设置每小时自动同步的 cron 任务。

## 功能
- 设置系统时区为 `Asia/Shanghai`
- 检查并自动安装 `ntpdate`（支持 `apt`、`yum`、`dnf`、`pacman`）
- 立即同步系统时间
- 添加每小时第 1 分钟自动同步时间的 cron 任务

## 前提条件
- 需要 root 权限运行（建议使用 `sudo`）
- 需要网络连接以安装依赖和同步时间

## 使用方法

### 一键执行（推荐）
通过 `curl` 或 `wget` 直接从 GitHub 下载并运行脚本：

#### 使用 curl
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/sync-time.sh)"
```
#### 使用 wget
```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/nsv2051/scripts/main/sync-time.sh)"
```
# mtg一键
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/automtg.sh)

```
# System Card - 系统信息快照工具

一个轻量级的 Bash 脚本，用于快速生成美观的系统状态报告，帮助您一目了然地掌握服务器运行状况。

## ✨ 功能特性

- **硬件信息**：CPU、GPU型号
- **系统状态**：内核版本、系统发行版、运行天数、系统负载
- **资源监控**：内存使用率、交换内存、磁盘空间
- **进程统计**：进程总数、在线用户数
- **用户活动**：当前用户、上次登录记录
- **网络信息**：非本地 IPv4 地址
- **自定义信息**：支持从 `/var/infomation/msg.txt` 读取额外信息
- **彩色输出**：不同信息类型使用不同颜色，清晰易读

## 🚀 快速开始

### 运行示例
```bash
# 一键运行（无需安装）
curl -sL https://raw.githubusercontent.com/nsv2051/scripts/main/syscard.sh | bash

# 下载并安装到系统路径
sudo wget https://raw.githubusercontent.com/nsv2051/scripts/main/syscard.sh -O /usr/local/bin/syscard
# 赋予权限
sudo chmod +x /usr/local/bin/syscard
# 之后随时运行
syscard
```
# Linux 系统管理脚本

一个功能全面的交互式系统管理工具，集成了日常运维的常用功能，支持一键配置系统源、网络、CPU、时间同步等。

## ✨ 核心功能

- **系统维护**：软件源更换、系统更新、包管理
- **资源监控**：磁盘检查、进程监控、内存使用
- **网络配置**：DNS设置、网络诊断、IPv6 SLAAC
- **电源管理**：关机、重启
- **高级配置**：CPU电源管理(P-State)、工作模式、NTP时间同步

## 🚀 快速开始

### 运行示例
```bash
# 一键运行（推荐）
bash -c "$(curl -sL https://raw.githubusercontent.com/nsv2051/scripts/main/systool.sh)"

# 下载脚本后运行
wget https://raw.githubusercontent.com/nsv2051/scripts/main/systool.sh
# 赋予权限并运行（需要root）
chmod +x systool.sh
sudo ./systool.sh
```
# Linux 远程自动备份

基于 rclone 的交互式远程备份工具，支持 40+ 云存储平台，一键配置定时备份。

## 功能

- 多远程异地备份（同时备份到多个云盘）
- 通配符支持（`/root/*.sh` 每个文件独立备份）
- 前置/后置钩子（如 `mysqldump` 备份数据库）
- 排除规则、网络重试、孤儿目录清理
- 按数量/天数自动清理旧备份
- 自动生成恢复脚本，交互式选择版本恢复
- 配置持久化（重新运行自动读取旧配置）
- Webhook 通知（钉钉、飞书等）
- 卸载功能

## 使用

```bash
# 一键运行
curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/setup-backup.sh -o /tmp/setup-backup.sh && bash /tmp/setup-backup.sh

# 国内代理
curl -fsSL https://gitproxy.eu.org/https://raw.githubusercontent.com/nsv2051/scripts/main/setup-backup.sh -o /tmp/setup-backup.sh && bash /tmp/setup-backup.sh

# 卸载
bash /opt/remote-backup/setup-backup.sh --uninstall
```

## 生成的文件

```
/opt/remote-backup/
├── {项目名}.sh            # 备份脚本（顶部可编辑配置区直接改）
└── restore-{项目名}.sh    # 恢复脚本

/var/log/remote-backup/    # 按天滚动日志
/var/run/{项目名}.lock     # 锁文件
```

## 常用命令

```bash
# 手动备份
/opt/remote-backup/项目名.sh

# 恢复数据
/opt/remote-backup/restore-项目名.sh

# 查看日志
tail -f /var/log/remote-backup/项目名-$(date +%Y%m%d).log

# 重新配置（自动读取旧配置，回车保留）
bash /opt/remote-backup/setup-backup.sh
```
