# nsv2051/scripts

Debian / Ubuntu 服务器常用运维脚本集合。每个脚本都能单文件运行，也可以从统一的 `toolbox.sh` 入口调用。

## 快速开始

```bash
# 交互菜单
bash <(curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/toolbox.sh)

# 国内网络不好时走加速通道
bash <(curl -fsSL https://gitproxy.eu.org/https://raw.githubusercontent.com/nsv2051/scripts/main/toolbox.sh)
```

## 工具一览

| id | 脚本 | 说明 | 需要 root |
| --- | --- | --- | --- |
| `syscard` | `syscard.sh` | 系统信息快照（只读） | 否 |
| `kworker` | `kworker-check.sh` | 挖矿 / 恶意进程伪装检测 | 是 |
| `systool` | `systool.sh` | 交互式系统运维菜单 | 是 |
| `synctime` | `sync-time.sh` | 时区设置 + 时间同步 | 是 |
| `mtg` | `mtg-install.sh` | mtg MTProto 代理（原生二进制） | 是 |
| `automtg` | `automtg.sh` | mtg MTProto 代理（Docker） | 是 |
| `backup` | `setup-backup.sh` | 基于 rclone 的远程自动备份 | 是 |
| `ddns` | `ddns.sh` | Cloudflare A 记录 DDNS | 否 |
| `ssh` | [qcs](https://github.com/nsv2051/quickly-conf-sshd) | SSH 公钥部署 | 是 |

`backup/` 目录存放已弃用的旧脚本，仅作存档，不建议直接使用。

## 统一入口 toolbox.sh

一个入口覆盖本仓库全部工具：不带参数是交互菜单，带参数直达指定工具。

### 用法

| 命令 | 说明 |
| --- | --- |
| `bash toolbox.sh` | 交互菜单选择工具 |
| `bash toolbox.sh -l` | 列出全部工具 |
| `bash toolbox.sh -h` | 显示帮助 |
| `bash toolbox.sh <id>` | 直接运行指定工具 |
| `bash toolbox.sh <id> -- <参数>` | 运行并透传该工具的参数 |

示例：

```bash
bash toolbox.sh syscard
bash toolbox.sh synctime -- --check
bash toolbox.sh mtg -- --dry-run
bash toolbox.sh ssh -- -c "17 * * * *"
```

需要 root 的工具请用 `sudo bash toolbox.sh <id>`，工具箱不会自动提权。

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `QCS_URL` | `https://ssh.nnn.cx/sh` | `ssh` 项调用的远程脚本地址 |
| `RAW_BASE` | 本仓库 raw 地址 | 本地缺少脚本时的下载源 |
| `RAW_PROXY` | `https://gitproxy.eu.org` | 下载加速通道，直连失败时回落；设为空则只走直连 |

## SSH 公钥部署

本仓库不再维护 SSH 公钥部署脚本，统一使用 [quickly-conf-sshd](https://github.com/nsv2051/quickly-conf-sshd)：

```bash
curl -s https://ssh.nnn.cx/sh | bash -s -- -c
```

脚本采用受管块写入（只修改标记区间内的内容）、逐行校验公钥、失败自动回滚，重复执行不会破坏 `sshd_config` 的其余部分。详见该项目 README。

本仓库 `backup/` 下的 `add_ssh_key.sh`、`pubkey.sh` 是早期的独立实现，已弃用。

## 时区与校时（sync-time.sh）

设置系统时区并校准系统时间（v2.3），适用于 Debian/Ubuntu、RHEL 系、openSUSE、Arch 等发行版。默认时区 `Asia/Shanghai`，默认 NTP 服务器 `ntp.aliyun.com`、`ntp.tencent.com`、`time.cloudflare.com`（按顺序尝试，国内源优先、海外源兜底）。

### 功能

- **守护进程优先**：检测到 chrony / systemd-timesyncd / ntpd 正在运行时，交给守护进程校时，不调用 `ntpdate` 步进时钟
- **偏差自检**：同步后读取实际 NTP 偏差，超过 2 秒明确告警并以非 0 退出，不再只看本地 `date`；读取失败自动重试 2 次，避免瞬时抖动误判
- **cron 绝对路径**：写入 `/usr/sbin/ntpdate`（或实际探测到的绝对路径），避免 cron 默认 PATH 找不到命令而静默失败
- **国内外多源**：默认按「国内优先、海外兜底」顺序尝试三个 NTP 源，海外机器前两个超时后自动落到 Cloudflare anycast
- **每小时校时**：cron 排期为每小时一次（随机分钟错峰），缩短时钟漂移窗口
- **幂等**：通过唯一标记注释去重，重跑不会产生重复 cron 行，并清理旧版写坏的裸 `ntpdate` 行
- **可卸载**：`--uninstall` 只删除本脚本写入的行，保留用户自己的 crontab
- 支持 `--dry-run` 干跑、`--check` 只读自检、`--no-cron`、自定义时区与多服务器

### 参数

| 参数 | 说明 |
| --- | --- |
| `-t, --tz <时区>` | 时区，默认 `Asia/Shanghai`，写入前校验 `/usr/share/zoneinfo/<时区>` |
| `-s, --server <主机>` | NTP 服务器，默认 `ntp.aliyun.com`、`ntp.tencent.com`、`time.cloudflare.com`，可重复指定；一旦使用本参数则整体覆盖默认列表，按顺序尝试 |
| `--dry-run` | 只检测并打印将执行的动作，不写文件、不改时钟、不装包、不碰 crontab |
| `--check` | 只读检测时区、同步状态、NTP 偏差、守护进程和 cron 行；正常退出 0，否则 1 |
| `--uninstall` | 只删除本脚本写入的 cron 行，不改系统时区、不卸载软件包 |
| `--no-cron` | 不写 crontab，也不改动已有 crontab（发现旧版坏行只告警不删除）；适合已有其它校时机制的机器 |
| `-h, --help` | 显示帮助 |

### 一键执行（推荐）

通过 `curl` 或 `wget` 从 GitHub 下载并运行：

```bash
# 默认安装（curl）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/sync-time.sh)"

# 默认安装（wget）
bash -c "$(wget -qO- https://raw.githubusercontent.com/nsv2051/scripts/main/sync-time.sh)"

# 只读自检（curl，传参示例）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/sync-time.sh)" -- --check
```

> 若机器已有 chrony 或 systemd-timesyncd，本脚本不会写 cron，也不会步进时钟，只让守护进程自行校时。

## mtg 一键（Docker 版 automtg.sh）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/automtg.sh)
```

随机生成端口，通过 Docker 运行。与下面的原生二进制版互相独立，选一个即可。

## mtg 原生二进制部署（mtg-install.sh）

基于 [9seconds/mtg](https://github.com/9seconds/mtg) v2.2.8（MIT），不使用 Docker。设计目标是每个环节都可验证，适合对来源敏感的场景。

### 与 automtg.sh 的区别

| | automtg.sh | mtg-install.sh |
| --- | --- | --- |
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

### 安全设计

- 版本锁定，不跟随 latest 漂移
- 下载后强制比对 SHA-256，不匹配立即中止且不落盘
- 只从 GitHub Releases 下载，不经第三方镜像
- secret 用 FakeTLS（`ee` 前缀 + 域名前置）
- 配置 `640 root:mtg` —— 仅 root 与 `mtg` 组可读，其他用户无权限
- 专用用户 `mtg` 运行，systemd 启用 `NoNewPrivileges` / `ProtectSystem=strict` / `ProtectHome` 等
- 监听 <1024 端口时自动加 `CAP_NET_BIND_SERVICE`，否则非 root 绑定会被内核拒绝

### 使用方法

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

### 安装后的文件

```
/usr/local/bin/mtg              # 二进制
/etc/mtg.toml                   # 配置（含 secret，640 root:mtg）
/etc/systemd/system/mtg.service # 服务单元
```

### 常用命令

```bash
systemctl status mtg        # 状态
journalctl -u mtg -f        # 日志
mtg access /etc/mtg.toml    # 重新生成连接链接
mtg doctor /etc/mtg.toml    # 配置自检（验证域名可达、SNI-DNS 匹配）
bash mtg-install.sh --show   # 同上，不需记 mtg 的用法
bash mtg-install.sh --verify # 端到端验证（真正握手，见下）
```

### 端到端验证（`--verify`）

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

### 注意

- 需要 root 权限
- 支持 `amd64` / `arm64`，其他架构会直接退出
- 端口被其他服务占用时脚本会直接中止，不会装完起不来
- 前端域名需真实可达，它只影响 TLS 握手的 SNI 伪装，不改变流量走向
- 记得放行对应 tcp 端口；**装完请跑一次 `--verify`**，别只看服务状态
- 云厂商安全组是独立一层，只改 iptables/1Panel 不管用，两层都要放行

## 系统信息快照（syscard.sh）

轻量级 Bash 脚本，快速生成系统状态报告。只读，不修改任何系统配置。

### 功能特性

- **硬件信息**：CPU、GPU 型号
- **系统状态**：内核版本、系统发行版、运行天数、系统负载
- **资源监控**：内存使用率、交换内存、磁盘空间
- **进程统计**：进程总数、在线用户数
- **用户活动**：当前用户、上次登录记录
- **网络信息**：非本地 IPv4 地址
- **自定义信息**：支持从 `/var/infomation/msg.txt` 读取额外信息
- **彩色输出**：不同信息类型使用不同颜色，清晰易读

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

## 系统运维菜单（systool.sh）

交互式系统管理工具，集成日常运维的常用功能。

### 核心功能

- **系统维护**：软件源更换（阿里、腾讯、华为、清华、网易、中科大）、系统更新、包管理
- **资源监控**：磁盘检查（`df -h` + 指定目录大小）、实时进程监控（`top -o %CPU`）、内存使用（`free -h`）
- **网络配置**：DNS 设置、网络诊断、通过 SLAAC 获取 IPv6
- **电源管理**：关机、重启
- **高级配置**：CPU 电源管理（P-State）、工作模式、NTP 时间同步

NTP 配置为幂等写入：重复设置只会更新 `NTP=` 的值，不会产生重复行，也不会因为原行是注释状态而漏改。

### 运行示例

```bash
# 一键运行（推荐）
bash -c "$(curl -sL https://raw.githubusercontent.com/nsv2051/scripts/main/systool.sh)"

# 下载脚本后运行
wget https://raw.githubusercontent.com/nsv2051/scripts/main/systool.sh
# 赋予权限并运行（需要 root）
chmod +x systool.sh
sudo ./systool.sh
```

## 远程自动备份（setup-backup.sh）

基于 rclone 的交互式远程备份工具，支持 40+ 云存储平台，一键配置定时备份。

### 功能

- 多远程异地备份（同时备份到多个云盘）
- 通配符支持（`/root/*.sh` 每个文件独立备份）
- 前置 / 后置钩子（如 `mysqldump` 备份数据库）
- 排除规则、网络重试、孤儿目录清理
- 按数量 / 天数自动清理旧备份
- 自动生成恢复脚本，交互式选择版本恢复
- 配置持久化（重新运行自动读取旧配置）
- Webhook 通知（钉钉、飞书等）
- 卸载功能

### 使用

```bash
# 一键运行
curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/setup-backup.sh -o /tmp/setup-backup.sh && bash /tmp/setup-backup.sh

# 国内代理
curl -fsSL https://gitproxy.eu.org/https://raw.githubusercontent.com/nsv2051/scripts/main/setup-backup.sh -o /tmp/setup-backup.sh && bash /tmp/setup-backup.sh

# 卸载（--uninstall 或 -u）
bash /opt/remote-backup/setup-backup.sh --uninstall
```

### 生成的文件

```
/opt/remote-backup/
├── {项目名}.sh            # 备份脚本（顶部可编辑配置区直接改）
└── restore-{项目名}.sh    # 恢复脚本

/var/log/remote-backup/    # 按天滚动日志
/var/run/{项目名}.lock     # 锁文件
```

### 常用命令

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

## Cloudflare DDNS（ddns.sh）

把服务器当前的公网 IPv4 写入 Cloudflare 的 A 记录，IP 变化时才调用写接口。

需要 `curl` 与 `jq`；查询现有解析会依次尝试 `dig`、`host`、`getent`（有哪个用哪个）。

### 认证方式

二选一：

- **API Token**（推荐）：只需要 `CF_API_TOKEN`，权限限定 `Zone.DNS:Edit`
- **Global API Key**：需要 `CF_API_EMAIL` + `CF_API_KEY`

### 参数

| 参数 | 说明 |
| --- | --- |
| `--check` | 只打印公网 IP 与当前 DNS 解析结果，不发起写请求；一致退出 0，不一致退出 1 |
| `-h, --help` | 显示帮助 |

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CF_API_TOKEN` | — | Cloudflare API Token（推荐） |
| `CF_API_EMAIL` | — | Cloudflare 账号邮箱（使用 Global API Key 时必填） |
| `CF_API_KEY` | — | Cloudflare Global API Key（使用邮箱方式时必填） |
| `CF_ZONE` | — | 区域名，例如 `example.com` |
| `CF_RECORD` | — | A 记录全名，例如 `home.example.com` |
| `CF_PROXIED` | `false` | 是否开启 Cloudflare 代理 |
| `CF_TTL` | `1` | 记录 TTL，`1` 表示自动 |
| `IP_URL` | `https://checkip.amazonaws.com` | 获取公网 IP 的地址 |
| `DDNS_CONF` | `/etc/ddns.conf` | 配置文件路径 |

环境变量优先于配置文件。兼容旧变量名 `cloudflare_auth_email`、`cloudflare_auth_key`、`zone`、`dnsrecord`。

### 使用

```bash
# 只检查，不写
CF_API_TOKEN=xxx CF_ZONE=example.com CF_RECORD=home.example.com bash ddns.sh --check

# 实际更新
CF_API_TOKEN=xxx CF_ZONE=example.com CF_RECORD=home.example.com bash ddns.sh

# 或写入配置文件（shell 语法，注意 chmod 600）
cat > /etc/ddns.conf <<'EOF'
CF_API_TOKEN=xxx
CF_ZONE=example.com
CF_RECORD=home.example.com
EOF
chmod 600 /etc/ddns.conf
```

记录不存在时会自动创建；已存在则只更新 IP。

## 挖矿与恶意进程检测（kworker-check.sh）

只读检测工具，排查用户态伪装的 `kworker` 进程与挖矿木马。需要 root（部分检查要读其它用户的 crontab 与进程信息）。

### 检测项

1. 扫描所有 `kworker` 进程，找出用户态伪装（真正的 `kworker` 是内核线程，`/proc/<pid>/exe` 应为空）
2. 扫描可疑落地文件：`/dev/shm`、`/tmp`、`/var/tmp`、`/root` 下的可执行文件，含隐藏 / 零宽字符命名
3. 检查系统所有用户及系统级 Crontab
4. 扫描已知挖矿进程特征
5. 检查异常矿池网络连接

缺少 `pgrep`、`readlink`、`ss`、`file` 时会尝试用 `apt` / `yum` / `apk` 自动补装。

### 使用

```bash
curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/kworker-check.sh | bash
```

发现可疑项退出码为 1，全部正常退出 0，方便接进定时巡检。
