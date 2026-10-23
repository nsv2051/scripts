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
#   bash mtg-install.sh --verify             # 端到端握手验证（FakeTLS + MTProto）
# ============================================================
set -euo pipefail

MTG_VERSION="2.2.8"
FRONT_DOMAIN="www.microsoft.com"
LISTEN_PORT="443"
DRY_RUN=0
MODE="install"          # install | uninstall | show | verify
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
    --verify)    MODE="verify"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "未知参数: $1（用 -h 查看用法）" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "需要 root 权限运行"

# ---------- 参数合法性（防止配置注入与畸形值） ----------
# 域名只允许标准主机名；grep 字符串会写进 TOML，不校验可被引号逃逸篡改配置
if ! [[ "$FRONT_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then
  die "前端域名不合法: ${FRONT_DOMAIN}（需形如 www.example.com）"
fi
(( ${#FRONT_DOMAIN} <= 253 )) || die "域名过长"

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


# 防火檧自检：仅提示，不自动改规则（擅改 iptables 风险更高）
firewall_hint() {
  local port="$1"
  command -v iptables >/dev/null 2>&1 || return 0

  # 1Panel 风格：ACCEPT 白名单 + 末尾 DROP，未放行的端口会被直接丢弃
  if iptables -L 1PANEL_BASIC -n >/dev/null 2>&1; then
    if iptables -L 1PANEL_BASIC -n 2>/dev/null | grep -qE "dpt:${port}( |\$)"; then
      info "防火墙：1Panel 已放行 tcp/${port}"
    else
      warn "防火墙：1Panel 未放行 tcp/${port}，外部将连不上！"
      warn "  请在 1Panel → 主机 → 防火墙 添加放行规则：tcp/${port}"
      warn "  （本机 iptables 末尾有 DROP，未放行端口一律丢弃）"
    fi
  fi

  # 云厂商安全组（OCI/AWS/阿里云）在主机之外还有一层，脚本无法探测
  warn "云服务器还需在控制台安全组放行 tcp/${port}，否则同样连不上"
}

# 取公网 IP：多源回退，避免单点失败导致链接残缺
# 优先 IPv4；本脚本 bind-to 用 0.0.0.0（仅 IPv4），
# 纯 IPv6 机器不能默默给出坏链接，必须显式声明。
get_public_ip() {
  local ip url
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
    warn "未取到公网 IPv4。本脚本监听 0.0.0.0（仅 IPv4），"
    warn "若该机仅有 IPv6，需自行把 bind-to 改为 \"[::]:${port}\" 并手动填链接。"
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

# ---------- verify 模式：真握手，不看"服务起来了" ----------
# 只有拿到 Telegram 的 resPQ 才算可用。服务 active + 端口监听都可能是假阳性。
do_verify() {
  local secret port ip
  [[ -f "$BIN" ]] || die "未安装 mtg（$BIN 不存在）"
  secret="$(extract_secret)" || true
  [[ -n "$secret" ]] || die "无法从 $CONF 读取 secret"

  port="$(sed -n 's/^[[:space:]]*bind-to[[:space:]]*=[[:space:]]*"[^"]*:\([0-9]*\)".*/\1/p' "$CONF" | head -1)"
  [[ -n "$port" ]] || port="$LISTEN_PORT"

  command -v python3 >/dev/null 2>&1 || {
    warn "未找到 python3，跳过端到端验证"; return 2
  }
  python3 -c 'import Crypto' 2>/dev/null || {
    warn "缺少 pycryptodome，跳过端到端验证"
    warn "Debian/Ubuntu: apt-get install -y python3-pycryptodome"
    warn "其它系统:      pip3 install pycryptodome"
    return 2
  }

  ip="$(get_public_ip || true)"
  [[ -n "$ip" ]] || ip="127.0.0.1"
  info "端到端验证 ${ip}:${port}（FakeTLS 握手 + MTProto req_pq）"

  MTG_SECRET="$secret" python3 - "$ip" "$port" <<'PYEOF'
import os, sys, socket, struct, hmac, hashlib, time, base64
from Crypto.Cipher import AES

def die(msg):
    print("  [x] " + msg)
    sys.exit(1)

host = sys.argv[1]
port = int(sys.argv[2])
sec = os.environ.get("MTG_SECRET", "").strip()
if not sec:
    die("secret 为空")

try:
    raw = bytes.fromhex(sec)
except ValueError:
    raw = base64.urlsafe_b64decode(sec + "=" * (-len(sec) % 4))

if not raw or raw[0] != 0xee:
    die("secret 首字节不是 0xee（非 faketls 模式），本验证不支持")
key = raw[1:17]
sni = raw[17:].decode()

def ctr(k, iv):
    return AES.new(k, AES.MODE_CTR, nonce=b"", initial_value=int.from_bytes(iv, "big"))

def client_hello():
    n = sni.encode()
    ext = (b"\x00\x00" + struct.pack(">H", 5 + len(n)) + struct.pack(">H", 3 + len(n))
           + b"\x00" + struct.pack(">H", len(n)) + n)
    body = (b"\x03\x03" + b"\x00" * 32 + b"\x20" + os.urandom(32)
            + struct.pack(">H", 2) + b"\x13\x01" + b"\x01\x00"
            + struct.pack(">H", len(ext)) + ext)
    hs = b"\x01" + len(body).to_bytes(3, "big") + body
    rec = b"\x16\x03\x01" + struct.pack(">H", len(hs)) + hs
    d = hmac.new(key, rec, hashlib.sha256).digest()
    ts = struct.pack("<I", int(time.time()))
    rnd = d[:28] + bytes(a ^ b for a, b in zip(d[28:32], ts))
    return rec[:11] + rnd + rec[43:]

def obf_frame(dc=2):
    while True:
        f = bytearray(os.urandom(64))
        if f[0] == 0xef:
            continue
        if bytes(f[0:4]) in (b"HEAD", b"POST", b"GET ", b"OPTI",
                              b"\xdd\xdd\xdd\xdd", b"\xee\xee\xee\xee"):
            continue
        if f[4:8] == b"\x00\x00\x00\x00":
            continue
        break
    f[56:60] = b"\xdd\xdd\xdd\xdd"
    f[60:62] = struct.pack("<h", dc)
    enc = ctr(hashlib.sha256(bytes(f[8:40]) + key).digest(), bytes(f[40:56]))
    full = enc.encrypt(bytes(f))
    wire = bytearray(f)
    wire[56:64] = full[56:64]
    rev = bytes(f[8:56])[::-1]
    dec = ctr(hashlib.sha256(rev[:32] + key).digest(), rev[32:48])
    return bytes(wire), enc, dec

def rec_write(p):
    return b"\x17\x03\x03" + struct.pack(">H", len(p)) + p

def read_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("对端关闭连接")
        b += c
    return b

def read_record(s):
    h = read_exact(s, 5)
    return h[0], read_exact(s, struct.unpack(">H", h[3:5])[0])

try:
    s = socket.create_connection((host, port), timeout=10)
except OSError as e:
    die("无法连接 %s:%d（%s）" % (host, port, e))
s.settimeout(12)
s.sendall(client_hello())

types = []
try:
    for _ in range(8):
        t, p = read_record(s)
        types.append(hex(t))
        if t == 0x17:
            break
except (EOFError, socket.timeout) as e:
    die("FakeTLS 握手无响应（%s）— 多半是端口未放行或被中间设备重置" % type(e).__name__)

if not types or types[0] != "0x16":
    die("FakeTLS 被拒绝（首包 %s）— secret 或 SNI 与服务器不一致"
        % (types[0] if types else "无"))
print("  [v] FakeTLS 握手通过（记录：%s）" % " -> ".join(types))

wire, enc, dec = obf_frame(2)
s.sendall(rec_write(wire))
nonce = os.urandom(16)
mid = (int(time.time()) << 32) & ~3
body = struct.pack("<I", 0xbe7e8ef1) + nonce
payload = b"\x00" * 8 + struct.pack("<Q", mid) + struct.pack("<i", len(body)) + body
s.sendall(rec_write(enc.encrypt(struct.pack("<i", len(payload)) + payload)))

plain = b""
deadline = time.time() + 15
while time.time() < deadline and len(plain) < 4:
    try:
        t, p = read_record(s)
    except (EOFError, socket.timeout):
        break
    if t == 0x17:
        plain += dec.decrypt(p)
s.close()

if len(plain) < 4:
    die("已连通代理，但未收到 Telegram 数据（上游 DC 不可达？）")

ln = struct.unpack("<i", plain[:4])[0]
if not (0 < ln <= len(plain) - 4):
    die("响应分帧异常（长度 %d，实收 %d）" % (ln, len(plain) - 4))
r = plain[4:4 + ln]
if len(r) < 24:
    die("响应过短（%d 字节）" % len(r))
cons = struct.unpack("<I", r[20:24])[0]
if cons != 0x05162463:
    die("响应构造器异常 0x%08x（预期 resPQ）" % cons)
print("  [v] MTProto req_pq 通过（resPQ，nonce %s）"
      % ("一致" if r[24:40] == nonce else "不一致"))
print()
print("  结论：代理可用，已成功中继到 Telegram DC")
sys.exit(0)
PYEOF
}

# ---------- show 模式 ----------
if [[ "$MODE" == "show" ]]; then
  show_links
  exit 0
fi

# ---------- verify 模式 ----------
if [[ "$MODE" == "verify" ]]; then
  rc=0
  do_verify || rc=$?
  exit "$rc"
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
# --proto '=https' 禁止重定向降级到 http（跟随时可能被中间人换成明文/虚假 URL）
curl -fsSL --proto '=https' --proto-redir '=https' \
  --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
  -o "${TMP}/${TARBALL}" "$URL" \
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
# StartLimit* 属于 [Unit] 段；写进 [Service] 会被 systemd 忽略
StartLimitIntervalSec=300
StartLimitBurst=5

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
firewall_hint "$LISTEN_PORT"

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
