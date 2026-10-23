#!/usr/bin/env bash
# ============================================================
# mtg (MTProto proxy) 一键部署脚本  v2.1
#
# 上游: https://github.com/9seconds/mtg  (MIT License)
# 本脚本不执行任何未校验的远程内容。
# 二进制仅来自 GitHub Releases，强制比对 SHA-256。
#
# 用法:
#   bash mtg-install.sh                      # 默认前端 www.microsoft.com，端口 443
#   bash mtg-install.sh -d www.apple.com     # 指定前端域名(SNI)
#   bash mtg-install.sh -p 8443              # 指定端口
#   bash mtg-install.sh --dry-run            # 只检查环境，不写任何文件
#   bash mtg-install.sh --uninstall          # 卸载（保留配置文件）
#   bash mtg-install.sh --uninstall --purge  # 卸载并删除配置
#   bash mtg-install.sh --show               # 仅重新显示连接链接
# ============================================================
set -euo pipefail

MTG_VERSION="2.2.8"
FRONT_DOMAIN="www.microsoft.com"
LISTEN_PORT="443"
DRY_RUN=0
MODE="install"          # install | uninstall | show
PURGE=0
BIN="/usr/local/bin/mtg"
CONF="/etc/mtg.toml"
UNIT="/etc/systemd/system/mtg.service"
SVC="mtg"

# 官方 release 的 SHA-256
# 来源: https://github.com/9seconds/mtg/releases/download/v2.2.8/mtg-2.2.8-checksums.txt
declare -A SHA256=(
  [linux-amd64]="7ef19d079d85f4e00d4f8334ec1f3f3c8718e3d0ed1f3109ea9a8673138a2102"
  [linux-arm64]="562a94dd4cafcb8f179b76cfeafb76da12747c8e230bc76235bf8746cc189644"
)

info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) FRONT_DOMAIN="${2:?-d 需要一个域名}"; shift 2 ;;
    -p) LISTEN_PORT="${2:?-p 需要一个端口}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --purge)     PURGE=1; shift ;;
    --show)      MODE="show"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "未知参数: $1（用 -h 查看用法）" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "需要 root 权限运行"

# ---------- 工具函数 ----------
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && exec 3>&- && return 0 || return 1
  fi
}

port_owned_by_mtg() {
  local p="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -lntpH 2>/dev/null | awk -v port="$p" '$4 ~ ("[:.]" port "$")' | grep -q '"mtg"'
}

# 取公网 IP：多源回退，避免单点失败导致链接残缺
get_public_ip() {
  local ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://ip.sb https://icanhazip.com; do
    ip="$(curl -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

extract_secret() {
  sed -n 's/^[[:space:]]*secret[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONF" 2>/dev/null | head -1
}

show_links() {
  local ip port secret tme tg
  [[ -f "$BIN" ]] || die "未安装 mtg（$BIN 不存在）"
  [[ -f "$CONF" ]] || die "未找到配置 $CONF"

  secret="$(extract_secret)"
  [[ -n "$secret" ]] || die "无法从 $CONF 读取 secret"
  port="$(sed -n 's/^[[:space:]]*bind-to[[:space:]]*=[[:space:]]*"[^"]*:\([0-9]*\)".*/\1/p' "$CONF" | head -1)"
  [[ -n "$port" ]] || port="$LISTEN_PORT"

  ip="$(get_public_ip || true)"
  if [[ -z "$ip" ]]; then
    warn "公网 IP 获取失败，请手动填入服务器 IP"
    ip="<你的服务器IP>"
  fi

  # 链接用 URL 编码更稳，但 secret 为 base64 时含 / + = ，Telegram 能正确解析 ；这里保持原样以兼容
  tme="https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}"
  tg="tg://proxy?server=${ip}&port=${port}&secret=${secret}"

  echo
  echo "=============================================="
  echo " 服务器 IP : ${ip}"
  echo " 端口      : ${port}"
  echo
  echo " TG 链接（点击导入）："
  echo "   ${tme}"
  echo
  echo " 备用协议链接："
  echo "   ${tg}"
  echo "=============================================="
}

# ---------- show 模式 ----------
if [[ "$MODE" == "show" ]]; then
  show_links
  exit 0
fi

# ---------- uninstall 模式 ----------
if [[ "$MODE" == "uninstall" ]]; then
  info "停止并移除服务"
  systemctl stop "$SVC" 2>/dev/null || true
  systemctl disable "$SVC" 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload 2>/dev/null || true

  rm -f "$BIN"
  info "已删除 $BIN"

  if [[ $PURGE -eq 1 ]]; then
    rm -f "$CONF"
    info "已删除配置 $CONF（secret 一并销毁）"
  else
    info "已保留配置 $CONF（如需彻底清除请加 --purge）"
  fi

  if id -u mtg >/dev/null 2>&1; then
    userdel mtg 2>/dev/null && info "已删除系统用户 mtg" || warn "删除用户 mtg 失败，可手动处理"
  fi

  info "卸载完成"
  exit 0
fi

# ---------- 1. 环境检查 ----------
info "检查系统环境"
command -v systemctl >/dev/null || die "需要 systemd"

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "不支持的架构: $(uname -m)（仅提供 amd64 / arm64）" ;;
esac
PLATFORM="linux-${ARCH}"
info "架构: ${PLATFORM}"

[[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) \
  || die "端口非法: ${LISTEN_PORT}"

TARBALL="mtg-${MTG_VERSION}-${PLATFORM}.tar.gz"
URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/${TARBALL}"
EXPECTED="${SHA256[$PLATFORM]}"
[[ -n "$EXPECTED" ]] || die "缺少该架构的校验值"

# 端口占用：仅当被“非 mtg 进程”占用时才失败。
# 重装/改端口时 mtg 自己在监听，不能误判为冲突。
PORT_BUSY=0
if port_in_use "$LISTEN_PORT"; then
  if port_owned_by_mtg "$LISTEN_PORT"; then
    info "端口 ${LISTEN_PORT} 由现有 mtg 服务占用，将重启复用"
  else
    PORT_BUSY=1
  fi
fi

# 非特权绑定低端口的能力说明
UNPRIV_START="$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)"
NEED_CAP=0
if (( LISTEN_PORT < UNPRIV_START )); then
  NEED_CAP=1
fi

if [[ $DRY_RUN -eq 1 ]]; then
  info "dry-run: 环境检查通过，未做任何修改"
  info "  架构       ${PLATFORM}"
  info "  前端域名   ${FRONT_DOMAIN}"
  info "  监听端口   ${LISTEN_PORT}"
  info "  安装路径   ${BIN}"
  if [[ $PORT_BUSY -eq 1 ]]; then
    warn "端口 ${LISTEN_PORT} 已被占用 —— 正式运行会失败，请用 -p 换端口"
  else
    info "  端口状态   可用"
  fi
  if [[ $NEED_CAP -eq 1 ]]; then
    info "  提权需求   需 CAP_NET_BIND_SERVICE（<${UNPRIV_START} 端口，脚本会自动配置）"
  fi
  exit 0
fi

if [[ $PORT_BUSY -eq 1 ]]; then
  die "端口 ${LISTEN_PORT} 已被占用。请换端口重试，例如: bash $0 -p 8443"
fi

# ---------- 2. 下载并校验 ----------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

info "下载 mtg v${MTG_VERSION}"
curl -fsSL --retry 3 --connect-timeout 15 -o "${TMP}/${TARBALL}" "$URL" \
  || die "下载失败: $URL"

info "校验 SHA-256"
ACTUAL="$(sha256sum "${TMP}/${TARBALL}" | cut -d' ' -f1)"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  die "校验失败！期望 ${EXPECTED}，实际 ${ACTUAL} —— 已中止，未安装任何文件"
fi
info "校验通过"

# ---------- 3. 安装二进制 ----------
info "解包并安装到 ${BIN}"
tar -xzf "${TMP}/${TARBALL}" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 2 -type f -name mtg -perm -u+x | head -1)"
[[ -n "$SRC" ]] || SRC="$(find "$TMP" -maxdepth 2 -type f -name mtg | head -1)"
[[ -n "$SRC" ]] || die "压缩包内未找到 mtg 可执行文件"

install -m 0755 "$SRC" "$BIN"

if ! id -u mtg >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin mtg
  info "已创建系统用户 mtg"
fi

# ---------- 4. 配置与 secret ----------
SECRET=""
if [[ -f "$CONF" ]]; then
  SECRET="$(extract_secret)"
  if [[ -n "$SECRET" ]]; then
    info "检测到已有配置，沿用原 secret（不重置）"
  else
    warn "已有配置文件但读不到 secret，将重新生成"
  fi
fi

if [[ -z "$SECRET" ]]; then
  info "生成 FakeTLS secret（前端域名 ${FRONT_DOMAIN}）"
  SECRET="$("$BIN" generate-secret "$FRONT_DOMAIN")"
  [[ -n "$SECRET" ]] || die "secret 生成失败"

  OLD_UMASK="$(umask)"
  umask 077
  cat > "$CONF" <<EOF
# mtg 配置 — 由 mtg-install.sh 生成
# 文档: https://github.com/9seconds/mtg/blob/master/example.config.toml
secret = "${SECRET}"
bind-to = "0.0.0.0:${LISTEN_PORT}"
EOF
  chmod 600 "$CONF"
  info "配置写入 ${CONF}（权限 600）"
else
  # 已有 secret，仅同步端口，保持 600
  PORT_OLD="$(sed -n 's/^[[:space:]]*bind-to[[:space:]]*=[[:space:]]*"[^"]*:\([0-9]*\)".*/\1/p' "$CONF" | head -1)"
  if [[ "$PORT_OLD" != "$LISTEN_PORT" ]]; then
    warn "端口变化 ${PORT_OLD:-?} -> ${LISTEN_PORT}，更新配置"
    sed -i "s|^[[:space:]]*bind-to[[:space:]]*=.*|bind-to = \"0.0.0.0:${LISTEN_PORT}\"|" "$CONF"
  fi
  chmod 600 "$CONF"
  info "配置已就绪（权限 600）"
fi

# 服务以 mtg 用户运行，必须能读配置；用组权限而不是放宽到 644。
# root:mtg + 640 => 仅 root 和 mtg 组可读，其他用户无权限。
chown root:mtg "$CONF"
chmod 640 "$CONF"
info "配置权限 640 root:mtg（仅 root 与 mtg 组可读）"

# ---------- 5. systemd ----------
info "配置 systemd 服务"
CAP_LINES=""
if [[ $NEED_CAP -eq 1 ]]; then
  # 非 root 绑定 <1024 端口所必需，否则服务会以 EACCES 启动失败
  CAP_LINES="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
fi

cat > "$UNIT" <<EOF
[Unit]
Description=mtg - MTProto proxy
Documentation=https://github.com/9seconds/mtg
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtg
Group=mtg
ExecStart=${BIN} run ${CONF}
Restart=always
RestartSec=3
${CAP_LINES}
# 权限收紧
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1
systemctl restart "$SVC"

# ---------- 6. 启动校验 ----------
info "等待服务就绪"
OK=0
for _ in $(seq 1 10); do
  sleep 1
  if systemctl is-active --quiet "$SVC" && port_in_use "$LISTEN_PORT"; then
    OK=1; break
  fi
done

if [[ $OK -ne 1 ]]; then
  warn "服务未正常就绪，最近日志："
  journalctl -u "$SVC" -n 30 --no-pager || true
  die "mtg 启动失败"
fi
info "服务已启动并在 ${LISTEN_PORT} 监听"

# ---------- 7. 输出 ----------
show_links

echo
echo " 常用命令："
echo "   systemctl status ${SVC}      查看状态"
echo "   journalctl -u ${SVC} -f      实时日志"
echo "   ${BIN} doctor ${CONF}        配置自检"
echo "   bash $0 --show               重新显示链接"
echo "   bash $0 --uninstall          卸载"
echo
echo " secret 保存在 ${CONF}（640 root:mtg，仅 root 与 mtg 组可读），勿外泄"
echo " 若开了防火墙，记得放行 ${LISTEN_PORT}/tcp"
echo "=============================================="
