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

> 上面 `automtg.sh` 是 Docker 版。下面 `mtg-install.sh` 是原生二进制版，两者独立，选一个即可。

# mtg 原生二进制部署（可审计版）

基于 [9seconds/mtg](https://github.com/9seconds/mtg) v2.2.8（MIT），不使用 Docker。
设计目标是每个环节都可验证，适合对来源敏感的场景。

## 与 automtg.sh 的区别

| | automtg.sh | mtg-install.sh |
|---|---|---|
| 运行方式 | Docker | 原生二进制 + systemd |
| 下载校验 | 无 | 强制 SHA-256 |
| 版本 | 跟随 `:2` 标签漂移 | 锁定 2.2.8 |
| 运行用户 | root | 专用低权限用户 `mtg` |
| secret 权限 | 644（全局可读） | 640 `root:mtg` |
| 端口检测 | 无 | 有，占用则中止 |
| 失败处理 | 继续执行 | `set -euo pipefail` |
| 幂等重跑 | 每次重置 secret | 保留原 secret |
| 卸载 | 无 | `--uninstall` |
| 权限加固 | 无 | systemd 沙箱选项 |

## 安全设计

- 版本锁定，不跟随 latest 漂移
- 下载后强制比对 SHA-256，不匹配立即中止且不落盘
- 只从 GitHub Releases 下载，不经第三方镜像
- secret 用 FakeTLS（`ee` 前缀 + 域名前置）
- 配置 `640 root:mtg` —— 仅 root 与 `mtg` 组可读，其他用户无权限
- 专用用户 `mtg` 运行，systemd 启用 `NoNewPrivileges` / `ProtectSystem=strict` / `ProtectHome` 等
- 监听 <1024 端口时自动加 `CAP_NET_BIND_SERVICE`，否则非 root 绑定会被内核拒绝

## 使用方法

```bash
# 先自检，不写任何文件
bash mtg-install.sh --dry-run

# 默认：前端域名 www.microsoft.com，端口 443
bash mtg-install.sh

# 换 SNI 前端域名
bash mtg-install.sh -d www.apple.com

# 换端口（443 被占用时）
bash mtg-install.sh -p 8443

# 重新显示连接链接
bash mtg-install.sh --show

# 卸载（保留配置）；加 --purge 连配置一起删
bash mtg-install.sh --uninstall
bash mtg-install.sh --uninstall --purge
```

远程执行：

```bash
curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/mtg-install.sh -o /tmp/mtg-install.sh
less /tmp/mtg-install.sh          # 建议先读一遍
bash /tmp/mtg-install.sh
```

安装完成后输出 `t.me/proxy?...` 与 `tg://proxy?...` 两种链接，点击即可导入 Telegram。

## 安装后的文件

```
/usr/local/bin/mtg              # 二进制
/etc/mtg.toml                   # 配置（含 secret，640 root:mtg）
/etc/systemd/system/mtg.service # 服务单元
```

## 常用命令

```bash
systemctl status mtg        # 状态
journalctl -u mtg -f        # 日志
mtg access /etc/mtg.toml    # 重新生成连接链接
mtg doctor /etc/mtg.toml    # 配置自检（验证域名可达、SNI-DNS 匹配）
bash mtg-install.sh --show  # 同上，不需记 mtg 的用法
bash mtg-install.sh --verify # 端到端验证（真正握手，见下）
```

## 端到端验证（`--verify`）

`systemctl is-active` 通过、端口在听，**都不能证明代理真的能用**。常见的假阳性有三种：

- 防火墙 DROP 了端口 → 本机看服务正常，外面连不上
- secret 与客户端不一致 → 服务跑着，握手全被拒
- 上游 Telegram DC 不可达 → 服务接受连接，但转发不出去

`--verify` 不看这些表面指标，而是真跑一遍完整链路：

```
FakeTLS ClientHello  →  HMAC 校验  →  obfuscated2 握手  →  MTProto req_pq  →  检查 resPQ
```

只有最后拿到 Telegram 返回的 `resPQ`（构造器 `0x05162463`）且 nonce 一致，才算通过：

```
[*] 端到端验证 1.2.3.4:443（FakeTLS 握手 + MTProto req_pq）
  [v] FakeTLS 握手通过（记录：0x16 -> 0x14 -> 0x17）
  [v] MTProto req_pq 通过（resPQ，nonce 一致）

  结论：代理可用，已成功中继到 Telegram DC
```

依赖 `python3` 与 `pycryptodome`（`apt-get install -y python3-pycryptodome`）。缺依赖时脚本会明确提示并跳过，不会假装成功。

## 注意

- 需要 root 权限
- 支持 `amd64` / `arm64`，其他架构会直接退出
- 端口被其他服务占用时脚本会直接中止，不会装完起不来
- 前端域名需真实可达，它只影响 TLS 握手的 SNI 伪装，不改变流量走向
- 记得放行对应 tcp 端口；**装完请跑一次 `--verify`**，别只看服务状态
- 云厂商安全组是独立一层，只改 iptables/1Panel 不管用，两层都要放行
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
