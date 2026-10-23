#!/usr/bin/env bash
# ============================================================
# mtg (MTProto proxy) 一键部署脚本
#
# 上游: https://github.com/9seconds/mtg  (MIT License)
# 本脚本不下载任何未校验的文件。二进制走 GitHub Releases，
# 并强制比对 SHA-256；不匹配立即中止。
#
# 用法:
#   bash mtg-install.sh                      # 默认前端域名 www.microsoft.com
#   bash mtg-install.sh -d www.apple.com     # 指定前端域名(SNI)
#   bash mtg-install.sh -p 8443              # 指定端口
#   bash mtg-install.sh --dry-run            # 只检查环境，不落盘
# ============================================================
set -euo pipefail

MTG_VERSION="2.2.8"
FRONT_DOMAIN="www.microsoft.com"
LISTEN_PORT="443"
DRY_RUN=0
BIN="/usr/local/bin/mtg"
CONF="/etc/mtg.toml"
UNIT="/etc/systemd/system/mtg.service"

# 官方 release 的 SHA-256（取自 GitHub API，逐字比对）
declare -A SHA256=(
  [linux-amd64]="7ef19d079d85f4e00d4f8334ec1f3f3c8718e3d0ed1f3109ea9a8673138a2102"
  [linux-arm64]="562a94dd4cafcb8f179b76cfeafb76da12747c8e230bc76235bf8746cc189644"
)

info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while getopts "d:p:h-:" opt; do
  case "$opt" in
    d) FRONT_DOMAIN="$OPTARG" ;;
    p) LISTEN_PORT="$OPTARG" ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    -) case "$OPTARG" in
         dry-run) DRY_RUN=1 ;;
         *) die "未知选项 --$OPTARG" ;;
       esac ;;
    *) exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || die "需要 root 权限运行"

# ---------- 1. 环境检查 ----------
info "检查系统环境"
command -v systemctl >/dev/null || die "需要 systemd"
[[ -f /etc/os-release ]] || warn "无法识别发行版，继续"

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "不支持的架构: $(uname -m)（仅提供 amd64 / arm64）" ;;
esac
PLATFORM="linux-${ARCH}"
info "架构: ${PLATFORM}"

TARBALL="mtg-${MTG_VERSION}-${PLATFORM}.tar.gz"
URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/${TARBALL}"
EXPECTED="${SHA256[$PLATFORM]}"

# 端口占用检查(仅提示,不阻断)
if command -v ss >/dev/null && ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${LISTEN_PORT}$"; then
  warn "端口 ${LISTEN_PORT} 已被占用，请确认（可能是 nginx/其他服务）"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  info "dry-run: 环境检查通过，未做任何修改"
  info "  架构       ${PLATFORM}"
  info "  前端域名   ${FRONT_DOMAIN}"
  info "  监听端口   ${LISTEN_PORT}"
  info "  安装路径   ${BIN}"
  exit 0
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

# ---------- 3. 安装 ----------
info "解包并安装到 ${BIN}"
tar -xzf "${TMP}/${TARBALL}" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 2 -type f -name mtg -perm -u+x | head -1)"
[[ -n "$SRC" ]] || SRC="$(find "$TMP" -maxdepth 2 -type f -name mtg | head -1)"
[[ -n "$SRC" ]] || die "压缩包内未找到 mtg 可执行文件"

install -m 0755 "$SRC" "$BIN"

# 专用低权限用户
if ! id -u mtg >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin mtg
  info "已创建系统用户 mtg"
fi

# ---------- 4. 生成 FakeTLS secret ----------
if [[ -f "$CONF" ]]; then
  warn "配置已存在，保留原 secret: ${CONF}"
  SECRET="$(sed -n 's/^secret *= *"\(.*\)"/\1/p' "$CONF" | head -1)"
else
  info "生成 FakeTLS secret（前端域名 ${FRONT_DOMAIN}）"
  SECRET="$("$BIN" generate-secret "$FRONT_DOMAIN")"
  [[ -n "$SECRET" ]] || die "secret 生成失败"

  umask 077
  cat > "$CONF" <<EOF
# mtg 配置 — 由 mtg-install.sh 生成
# 文档: https://github.com/9seconds/mtg/blob/master/example.config.toml
secret = "${SECRET}"
bind-to = "0.0.0.0:${LISTEN_PORT}"
EOF
  chmod 600 "$CONF"
  info "配置写入 ${CONF}（权限 600）"
fi

# ---------- 5. systemd ----------
info "配置 systemd 服务"
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
# 收紧权限
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=false

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtg.service

sleep 2
if ! systemctl is-active --quiet mtg.service; then
  warn "服务未启动，最近日志："
  journalctl -u mtg.service -n 25 --no-pager
  die "mtg 启动失败"
fi
info "mtg 已启动"

# ---------- 6. 输出连接信息 ----------
PUBIP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo '?')"

echo
echo "=============================================="
echo " 部署完成"
echo "=============================================="
echo " 服务器 IP : ${PUBIP}"
echo " 端口      : ${LISTEN_PORT}"
echo " 前端域名  : ${FRONT_DOMAIN}"
echo
echo " 连接链接（复制到 Telegram 打开）："
"$BIN" access "$CONF" 2>/dev/null | sed -n 's/.*"tme_url": "\([^"]*\)".*/  \1/p' | head -1
echo
echo " secret 已保存在 ${CONF}（chmod 600），勿外泄"
echo
echo " 常用命令："
echo "   systemctl status mtg     查看状态"
echo "   journalctl -u mtg -f     实时日志"
echo "   $BIN doctor $CONF        配置自检"
echo "=============================================="
