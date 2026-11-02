#!/usr/bin/env bash
# ============================================================
# mtg (MTProto proxy) 一键部署脚本  v2.2
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
#   bash mtg-install.sh --doctor             # 运维体检（状态/Recv-Q/fd/看护记录）
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
WD_BIN="/usr/local/bin/mtg-watchdog.sh"
WD_UNIT="/etc/systemd/system/mtg-watchdog.service"
WD_TIMER="/etc/systemd/system/mtg-watchdog.timer"
WD_SVC="mtg-watchdog"
SYSCTL_FILE="/etc/sysctl.d/99-mtg.conf"
DEPLOY_INFO="/etc/mtg-deploy-info.txt"

# 官方 release 的 SHA-256
# 来源: https://github.com/9seconds/mtg/releases/download/v2.2.8/mtg-2.2.8-checksums.txt
declare -A SHA256=(
  [linux-amd64]="7ef19d079d85f4e00d4f8334ec1f3f3c8718e3d0ed1f3109ea9a8673138a2102"
  [linux-arm64]="562a94dd4cafcb8f179b76cfeafb76da12747c8e230bc76235bf8746cc189644"
)

info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,19p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) FRONT_DOMAIN="${2:?-d 需要一个域名}"; shift 2 ;;
    -p) LISTEN_PORT="${2:?-p 需要一个端口}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --purge)     PURGE=1; shift ;;
    --show)      MODE="show"; shift ;;
    --verify)    MODE="verify"; shift ;;
    --doctor)    MODE="doctor"; shift ;;
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

# 按发行版尝试补装 pycryptodome；失败返回非零由调用方降级
try_install_pycryptodome() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y python3-pycryptodome
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3-pycryptodome
  else
    return 1
  fi
}

# 直接写二进制到 stdout（不要用命令替换，NUL 会被丢弃）
u16be() {
  local n="$1"
  printf "\\x$(printf '%02x' $(( (n >> 8) & 255 )))\\x$(printf '%02x' $(( n & 255 )))"
}

u24be() {
  local n="$1"
  printf "\\x$(printf '%02x' $(( (n >> 16) & 255 )))\\x$(printf '%02x' $(( (n >> 8) & 255 )))\\x$(printf '%02x' $(( n & 255 )))"
}

# 降级验证：纯 bash + openssl 的 FakeTLS ClientHello 探活。
# 只能证明 TLS 记录层有响应，不能证明 MTProto req_pq。
# 返回：0=完整通过（本函数不会返回 0）、3=降级通过、1=失败、2=无法验证
verify_degraded() {
  local ip="$1" port="$2" secret="$3"
  local tmpd n ext_len body_len hs_len key_hex sni_hex sni
  local i b0 b1 b2 b3 ts t0 t1 t2 t3 r0 r1 r2 r3 first st

  if ! [[ "$secret" =~ ^[eE][eE][0-9a-fA-F]+$ ]]; then
    warn "降级验证仅支持 hex 形式的 FakeTLS secret，当前 secret 无法解析"
    return 2
  fi
  if (( ${#secret} < 34 )); then
    warn "secret 长度异常，无法提取 key/SNI"
    return 2
  fi

  key_hex="${secret:2:32}"
  sni_hex="${secret:34}"
  if (( ${#sni_hex} < 2 )) || (( ${#sni_hex} % 2 != 0 )); then
    warn "secret 中缺少合法的 SNI 域名，无法降级验证"
    return 2
  fi

  sni=""
  for ((i = 0; i < ${#sni_hex}; i += 2)); do
    sni+="$(printf "\\x${sni_hex:i:2}")"
  done
  [[ -n "$sni" ]] || { warn "SNI 解析为空，无法降级验证"; return 2; }

  tmpd="$(mktemp -d)"
  n=${#sni}
  ext_len=$((9 + n))
  body_len=$((84 + n))
  hs_len=$((4 + body_len))

  {
    printf '\x00\x00'
    u16be $((5 + n))
    u16be $((3 + n))
    printf '\x00'
    u16be "$n"
    printf '%s' "$sni"
  } > "$tmpd/ext" || { rm -rf "$tmpd"; return 1; }

  {
    printf '\x03\x03'
    head -c 32 /dev/zero
    printf '\x20'
    head -c 32 /dev/urandom
    u16be 2
    printf '\x13\x01'
    printf '\x01\x00'
    u16be "$ext_len"
    cat "$tmpd/ext"
  } > "$tmpd/body" || { rm -rf "$tmpd"; return 1; }

  {
    printf '\x01'
    u24be "$body_len"
    cat "$tmpd/body"
  } > "$tmpd/hs" || { rm -rf "$tmpd"; return 1; }

  {
    printf '\x16\x03\x01'
    u16be "$hs_len"
    cat "$tmpd/hs"
  } > "$tmpd/rec" || { rm -rf "$tmpd"; return 1; }

  if ! openssl dgst -sha256 -mac HMAC -macopt "hexkey:${key_hex}" -binary "$tmpd/rec" > "$tmpd/digest" 2>/dev/null; then
    rm -rf "$tmpd"
    warn "openssl HMAC 计算失败，无法降级验证"
    return 1
  fi

  read -r b0 b1 b2 b3 < <(od -An -tu1 -j28 -N4 "$tmpd/digest")
  ts="$(date +%s)"
  t0=$(( ts & 255 ))
  t1=$(( (ts >> 8) & 255 ))
  t2=$(( (ts >> 16) & 255 ))
  t3=$(( (ts >> 24) & 255 ))
  r0=$(( b0 ^ t0 ))
  r1=$(( b1 ^ t1 ))
  r2=$(( b2 ^ t2 ))
  r3=$(( b3 ^ t3 ))

  {
    head -c 28 "$tmpd/digest"
    printf "\\x$(printf '%02x' "$r0")\\x$(printf '%02x' "$r1")\\x$(printf '%02x' "$r2")\\x$(printf '%02x' "$r3")"
  } > "$tmpd/rnd" || { rm -rf "$tmpd"; return 1; }
  dd if="$tmpd/rnd" of="$tmpd/rec" bs=1 seek=11 conv=notrunc status=none 2>/dev/null \
    || { rm -rf "$tmpd"; return 1; }

  first=""
  st=0
  # shellcheck disable=SC2016
  first="$(timeout 8 bash -c '
    exec 3<>"/dev/tcp/$1/$2" || exit 10
    cat "$3" >&3 || exit 11
    head -c 1 <&3 2>/dev/null | od -An -tu1 | tr -d "[:space:]"
  ' _ "$ip" "$port" "$tmpd/rec" 2>/dev/null)" || st=$?

  rm -rf "$tmpd"

  if (( st == 124 )); then
    warn "降级验证失败：连接超时（8s）— 端口未放行或被中间设备丢弃"
    return 1
  fi
  if (( st != 0 )) || [[ -z "$first" ]]; then
    warn "降级验证失败：TCP 连接失败或未收到响应（退出码 ${st}）"
    return 1
  fi

  case "$first" in
    22|23)
      info "降级验证通过：FakeTLS 握手层可达（首记录 0x$(printf '%02x' "$first")）"
      info "  注意：仅证明 TLS 记录层有响应，未验证 MTProto req_pq"
      info "  完整验证：apt-get install -y python3 python3-pycryptodome"
      return 3
      ;;
    *)
      warn "降级验证失败：首字节 0x$(printf '%02x' "$first")，预期 0x16/0x17"
      return 1
      ;;
  esac
}

do_verify_inner() {
  local secret port ip
  [[ -f "$BIN" ]] || { warn "未安装 mtg（$BIN 不存在）"; return 1; }
  secret="$(extract_secret)" || true
  [[ -n "$secret" ]] || { warn "无法从 $CONF 读取 secret"; return 1; }

  port="$(sed -n 's/^[[:space:]]*bind-to[[:space:]]*=[[:space:]]*"[^"]*:\([0-9]*\)".*/\1/p' "$CONF" | head -1)"
  [[ -n "$port" ]] || port="$LISTEN_PORT"

  ip="$(get_public_ip || true)"
  [[ -n "$ip" ]] || ip="127.0.0.1"

  local need_python=1
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import Crypto' 2>/dev/null; then
      need_python=0
    else
      warn "已找到 python3，但缺少 pycryptodome，无法执行完整端到端验证"
      if [[ -t 0 ]] && command -v read >/dev/null 2>&1; then
        local ans=""
        read -r -p "是否现在安装 python3-pycryptodome？[y/N] " ans || ans=""
        case "$ans" in
          y|Y|yes|YES)
            info "尝试安装 python3-pycryptodome ..."
            if try_install_pycryptodome >/dev/null 2>&1 \
               && python3 -c 'import Crypto' 2>/dev/null; then
              info "安装成功，继续完整验证"
              need_python=0
            else
              warn "安装失败，降级为轻量握手验证"
            fi
            ;;
          *)
            warn "已跳过安装，降级为轻量握手验证"
            ;;
        esac
      else
        warn "非交互环境，已降级为轻量握手验证（未安装 pycryptodome）"
      fi
    fi
  else
    warn "未找到 python3，已降级为轻量握手验证"
  fi

  if (( need_python == 1 )); then
    warn "降级验证：仅检查 FakeTLS 握手层可达，不验证 MTProto req_pq"
    verify_degraded "$ip" "$port" "$secret"
    return $?
  fi

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
  return $?
}

do_verify() {
  local rc=0
  do_verify_inner || rc=$?
  local res
  case "$rc" in
    0) res="完整通过" ;;
    3) res="降级通过（未验证 MTProto）" ;;
    1) res="失败" ;;
    2) res="无法验证（缺依赖）" ;;
    *) res="异常（rc=$rc）" ;;
  esac
  local f
  f="$(dirname "$CONF")/.mtg-last-verify"
  { printf '时间: %s\n结果: %s\n退出码: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$res" "$rc"; } > "$f" 2>/dev/null || true
  chmod 0644 "$f" 2>/dev/null || true
  return "$rc"
}

# ---------- doctor 模式：只读运维体检，不依赖 $BIN ----------
do_doctor() {
  local active enabled pid etimes d h m
  local ssout recvq has_listener=0
  local fd_count threads vmrss_kb vmrss_mb
  local established close_wait
  local wd_active wdlog somaxconn syn
  local port verify_file

  port="$(sed -n 's/^[[:space:]]*bind-to[[:space:]]*=[[:space:]]*"[^"]*:\([0-9]*\)".*/\1/p' "$CONF" 2>/dev/null | head -1 || true)"
  [[ -n "$port" ]] || port="$LISTEN_PORT"

  echo
  echo "=============================================="
  echo " mtg 运维体检"
  echo "=============================================="

  echo
  echo "【服务状态】"
  active="$(systemctl is-active "$SVC" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$SVC" 2>/dev/null || true)"
  pid="$(systemctl show -p MainPID --value "$SVC" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || pid=0
  echo " is-active : ${active:-unknown}"
  echo " is-enabled: ${enabled:-unknown}"
  if (( pid > 0 )) && [[ -d "/proc/${pid}" ]]; then
    etimes="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$etimes" =~ ^[0-9]+$ ]] || etimes=0
    d=$((etimes / 86400))
    h=$(((etimes % 86400) / 3600))
    m=$(((etimes % 3600) / 60))
    echo " MainPID   : ${pid}（已运行 ${d}天 ${h}时 ${m}分）"
  else
    pid=0
    echo " MainPID   : 0（未运行）"
  fi

  echo
  echo "【监听与积压】"
  ssout="$(ss -H -tln "sport = :${port}" 2>/dev/null || true)"
  if [[ -n "$ssout" ]]; then
    has_listener=1
    echo " ${ssout%%$'\n'*}"
    recvq="$(printf '%s\n' "$ssout" | awk 'NR==1{print $2}')"
    [[ "$recvq" =~ ^[0-9]+$ ]] || recvq=0
    echo " Recv-Q    : ${recvq}"
    if (( recvq > 100 )); then
      warn "Recv-Q ${recvq} > 100，疑似 accept 卡死"
    fi
  else
    recvq=0
    echo " 端口 ${port} 无监听"
  fi

  echo
  echo "【进程资源】"
  if (( pid > 0 )) && [[ -d "/proc/${pid}" ]]; then
    fd_count="$(ls "/proc/${pid}/fd" 2>/dev/null | wc -l | tr -d '[:space:]')"
    threads="$(awk '/^Threads:/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
    vmrss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
    [[ "$threads" =~ ^[0-9]+$ ]] || threads="?"
    if [[ "$vmrss_kb" =~ ^[0-9]+$ ]]; then
      vmrss_mb="$(awk -v k="$vmrss_kb" 'BEGIN{printf "%.1f", k/1024}')"
    else
      vmrss_mb="?"
    fi
    echo " fd 数     : ${fd_count:-?}"
    echo " 线程数    : ${threads}"
    echo " VmRSS     : ${vmrss_mb} MB"
  else
    echo " 进程未运行，跳过"
  fi

  echo
  echo "【连接状态】"
  established="$(ss -H -tan state established "( sport = :${port} )" 2>/dev/null | wc -l | tr -d '[:space:]')"
  close_wait="$(ss -H -tan state close-wait "( sport = :${port} )" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "$established" =~ ^[0-9]+$ ]] || established=0
  [[ "$close_wait" =~ ^[0-9]+$ ]] || close_wait=0
  echo " ESTABLISHED: ${established}"
  echo " CLOSE_WAIT : ${close_wait}"
  if (( close_wait > 50 )); then
    warn "CLOSE_WAIT ${close_wait} > 50，可能有连接未正常释放"
  fi

  echo
  echo "【看护状态】"
  wd_active="$(systemctl is-active "$WD_TIMER" 2>/dev/null || true)"
  echo " ${WD_TIMER}: ${wd_active:-unknown}"
  systemctl list-timers --no-pager "$WD_TIMER" 2>/dev/null | head -3 || true
  wdlog="$(journalctl -t mtg-watchdog -n 5 --no-pager 2>/dev/null || true)"
  if [[ -n "$wdlog" && "$wdlog" != *"No entries"* ]]; then
    printf '%s\n' "$wdlog"
  else
    echo " 暂无看护日志"
  fi

  echo
  echo "【内核参数】"
  somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null || true)"
  syn="$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || true)"
  [[ "$somaxconn" =~ ^[0-9]+$ ]] || somaxconn="?"
  [[ "$syn" =~ ^[0-9]+$ ]] || syn="?"
  echo " net.core.somaxconn           = ${somaxconn}（建议 >= 4096）"
  echo " net.ipv4.tcp_max_syn_backlog = ${syn}（建议 >= 1024）"
  if [[ "$somaxconn" =~ ^[0-9]+$ ]] && (( somaxconn < 4096 )); then
    warn "somaxconn 偏低（${somaxconn} < 4096），可手动调整或重跑安装脚本"
  fi
  if [[ "$syn" =~ ^[0-9]+$ ]] && (( syn < 1024 )); then
    warn "tcp_max_syn_backlog 偏低（${syn} < 1024），可手动调整或重跑安装脚本"
  fi

  echo
  echo "【最近验证】"
  verify_file="$(dirname "$CONF")/.mtg-last-verify"
  if [[ -f "$verify_file" ]]; then
    printf ' %s\n' "$(head -1 "$verify_file")"
    printf ' %s\n' "$(sed -n '2p' "$verify_file")"
  else
    echo " 无记录（可执行 --verify）"
  fi

  echo
  echo "【结论】"
  if [[ "$active" != "active" ]]; then
    echo " 结论：服务未运行（建议 systemctl start ${SVC} 或查看 journalctl -u ${SVC} -n 50）"
  elif (( has_listener == 0 )); then
    echo " 结论：疑似启动失败"
  elif (( recvq > 100 )); then
    echo " 结论：疑似假死（accept 卡死），看护应会在 60s 内重启"
  elif (( close_wait <= 50 )); then
    echo " 结论：正常"
  else
    echo " 结论：需人工检查"
  fi
  return 0
}

if [[ "$MODE" == "doctor" ]]; then
  do_doctor
  exit 0
fi

# ---------- show 模式 ----------
if [[ "$MODE" == "show" ]]; then
  show_links
  exit 0
fi

# ---------- verify 模式 ----------
# 退出码语义：0=通过（完整或降级均视为通过），1=失败，2=无法验证
if [[ "$MODE" == "verify" ]]; then
  rc=0
  do_verify || rc=$?
  case "$rc" in
    0) info "验证结果：完整通过（0）— FakeTLS 握手与 MTProto req_pq 均成功" ;;
    3) info "验证结果：降级通过 — 仅确认 FakeTLS 握手层可达，未验证 MTProto req_pq（如需完整验证请安装 python3-pycryptodome）" ;;
    1) warn "验证结果：失败（1）— 详见上方输出" ;;
    2) warn "验证结果：无法验证（2）— 缺少依赖或 secret 格式不支持" ;;
    *) warn "验证结果：异常退出码 ${rc}" ;;
  esac
  case "$rc" in
    0|3) exit 0 ;;
    1) exit 1 ;;
    *) exit 2 ;;
  esac
fi

# ---------- uninstall 模式 ----------
if [[ "$MODE" == "uninstall" ]]; then
  info "停止并移除看护 timer"
  systemctl disable --now "$WD_TIMER" 2>/dev/null || true
  info "停止看护服务"
  systemctl stop "$WD_SVC" 2>/dev/null || true
  info "删除看护脚本与 unit/timer"
  rm -f "$WD_TIMER" "$WD_UNIT" "$WD_BIN"
  info "清理看护运行状态 /run/mtg-watchdog"
  rm -rf /run/mtg-watchdog

  info "停止并移除服务"
  systemctl stop "$SVC" 2>/dev/null || true
  systemctl disable "$SVC" 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload 2>/dev/null || true

  rm -f "$BIN"
  info "已删除 $BIN"

  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    info "已删除 $SYSCTL_FILE（未主动改回内核参数，如需回滚请重启或 sysctl -w）"
  fi

  rm -f "$DEPLOY_INFO"
  info "已删除部署摘要 $DEPLOY_INFO"
  rm -f "$(dirname "$CONF")/.mtg-last-verify"

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
  info "dry-run: 将写入以下文件"
  info "  ${BIN}"
  info "  ${CONF}"
  info "  ${UNIT}"
  info "  ${WD_BIN}"
  info "  ${WD_UNIT}"
  info "  ${WD_TIMER}"
  info "  看护：每 60s 检查，Recv-Q>100 且持续 3s 则抓栈并重启，每小时最多 3 次"
  info "  ${SYSCTL_FILE}（仅当当前值更小时写入 somaxconn=4096 / tcp_max_syn_backlog=1024）"
  info "  ${DEPLOY_INFO}（部署摘要）"
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
# 可用 \`mtg doctor /etc/mtg.toml\` 自检。

# 代理密钥（FakeTLS + 必填）
secret = "${SECRET}"

# 监听地址与端口；0.0.0.0 表示全部 IPv4 网卡
bind-to = "0.0.0.0:${LISTEN_PORT}"

# 并发连接上限。积压事故期间 8192 足够；机器内存越大可再上调
concurrency = 8192

# 优先使用的出口协议族：prefer-ipv4 / prefer-ipv6
prefer-ip = "prefer-ipv4"

# 前端伪装端口（默认 443）。经 CDN/反代接入时才需改动
domain-fronting-port = 443

# DoH 解析地址：DNS 走这里可避开被污染的系统 DNS
[network]
doh-ip = "1.1.1.1"

# 上游网络超时与保活，避免半死连接长期堆积
[network.timeout]
tcp = "5s"
http = "10s"
idle = "5m"
handshake = "10s"

[network.keep-alive]
disabled = false
idle = "15s"
interval = "15s"
count = 9
EOF
  chmod 600 "$CONF"
  if ! "$BIN" doctor "$CONF" >/dev/null 2>&1; then
    warn "配置自检未通过，回滚到最小配置"
    cp -f "$CONF" "${CONF}.rejected" 2>/dev/null || true
    chmod 600 "${CONF}.rejected" 2>/dev/null || true
    cat > "$CONF" <<EOF
# 最小可用配置（doctor 自检失败后的回滚产物）
secret = "${SECRET}"
bind-to = "0.0.0.0:${LISTEN_PORT}"
EOF
    chmod 600 "$CONF"
    warn "已回滚为最小配置；原配置备份在 ${CONF}.rejected，请检查备份与 journalctl 后手动修复"
  else
    info "配置自检通过（mtg doctor）"
  fi
  info "配置写入 ${CONF}（权限 600）"
  umask "$OLD_UMASK"
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

# 运行期看护：检测 accept 卡死（Recv-Q 积压）并自愈
write_watchdog() {
  info "安装看护脚本 ${WD_BIN}"
  cat > "$WD_BIN" <<'WATCHDOG'
#!/usr/bin/env bash
set -uo pipefail

SVC="${WD_SERVICE:-mtg}"
PORT="${WD_PORT:-443}"
RECVQ_THRESHOLD="${WD_RECVQ_THRESHOLD:-100}"
MAX_RESTARTS="${WD_MAX_RESTARTS:-3}"
STATE_DIR="${WD_STATE_DIR:-/run/mtg-watchdog}"
INSTALL_SCRIPT="${WD_INSTALL_SCRIPT:-__INSTALL_SCRIPT__}"
VERIFY_INTERVAL="${WD_VERIFY_INTERVAL:-86400}"

log() {
  logger -t mtg-watchdog -- "$*" 2>/dev/null || true
  printf '%s\n' "$*" >&2
}

ss_output() {
  ss -H -tln "sport = :${PORT}" 2>/dev/null || true
}

get_recvq() {
  local out="$1"
  [[ -n "$out" ]] || { printf ''; return 0; }
  printf '%s\n' "$out" | awk 'NR==1{print $2}'
}

restart_allowed() {
  local now cutoff f count
  now="$(date +%s)"
  cutoff=$((now - 3600))
  f="$STATE_DIR/restarts"
  touch "$f"
  awk -v cutoff="$cutoff" '$1 + 0 >= cutoff' "$f" > "$f.tmp" 2>/dev/null || true
  mv "$f.tmp" "$f"
  count="$(wc -l < "$f" | tr -d '[:space:]')"
  if (( count >= MAX_RESTARTS )); then
    log "restart budget exhausted (${count}/h)，请人工介入"
    return 1
  fi
  printf '%s\n' "$now" >> "$f"
  return 0
}

mkdir -p "$STATE_DIR"

exec 9>"$STATE_DIR/lock"
flock -n 9 || { log "another watchdog run in progress, skip"; exit 0; }

reason=""
kill_stack=0
q=""

if ! systemctl is-active --quiet "$SVC"; then
  reason="service-not-active"
else
  out="$(ss_output)"
  if [[ -z "$out" ]]; then
    reason="no-listener"
  else
    q="$(get_recvq "$out")"
    if [[ -z "$q" ]]; then
      log "cannot read Recv-Q (insufficient privilege?)"
      exit 0
    fi
    if (( EUID != 0 )); then
      log "not running as root; Recv-Q may be unreliable, active-only check passed"
      exit 0
    fi
    if (( q > RECVQ_THRESHOLD )); then
      sleep 3
      q2="$(get_recvq "$(ss_output)")"
      if [[ -n "$q2" ]] && (( q2 > RECVQ_THRESHOLD )); then
        reason="recvq-stuck:${q}->${q2}"
        kill_stack=1
      fi
    fi
  fi
fi

if [[ -z "$reason" ]]; then
  if [[ -n "$INSTALL_SCRIPT" && -f "$INSTALL_SCRIPT" ]]; then
    vstate="$STATE_DIR/last-verify"
    now="$(date +%s)"
    last=0
    if [[ -f "$vstate" ]]; then
      last="$(stat -c %Y "$vstate" 2>/dev/null || echo 0)"
    fi
    if (( now - last >= VERIFY_INTERVAL )); then
      vrc=0
      timeout 120 "$INSTALL_SCRIPT" --verify </dev/null >/tmp/mtg-verify.log 2>&1 || vrc=$?
      case "$vrc" in
        0) log "daily verify ok" ;;
        3|2) log "daily verify degraded (rc=${vrc}), see /tmp/mtg-verify.log" ;;
        *) log "daily verify failed (rc=${vrc}), see /tmp/mtg-verify.log" ;;
      esac
      touch "$vstate" 2>/dev/null || true
      printf '%s rc=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$vrc" >> "$vstate" 2>/dev/null || true
    fi
  fi
fi

if [[ -z "$reason" ]]; then
  log "watchdog ok (active, listener present, recvq=${q:-?})"
  exit 0
fi

log "unhealthy: ${reason}"

if (( kill_stack == 1 )); then
  systemctl kill -s QUIT --kill-who=main "$SVC" 2>/dev/null || true
  sleep 1
fi

if ! restart_allowed; then
  exit 0
fi

if systemctl restart "$SVC"; then
  log "restarted ${SVC} (reason=${reason})"
else
  log "restart ${SVC} failed (reason=${reason})"
fi

exit 0
WATCHDOG
  chmod 0755 "$WD_BIN"
  sed -i "s|__INSTALL_SCRIPT__|$(readlink -f "$0")|g" "$WD_BIN"

  info "安装看护 unit/timer"
  cat > "$WD_UNIT" <<EOF
[Unit]
Description=mtg watchdog - detect and recover hung MTProto proxy
Documentation=https://github.com/9seconds/mtg
After=mtg.service

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=${WD_BIN}
EOF
  chmod 0644 "$WD_UNIT"

  cat > "$WD_TIMER" <<'TIMER'
[Unit]
Description=Run mtg watchdog every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
TIMER
  chmod 0644 "$WD_TIMER"
}

# ---------- 4.5 内核参数（保守、可回滚） ----------
# 只上调，不降级；当前值已经足够时完全不碰系统。
apply_sysctl() {
  local somaxconn_target=4096
  local syn_target=1024
  local cur_somaxconn cur_syn need=0 old_umask bak sysctl_dir

  cur_somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null || echo 0)"
  cur_syn="$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo 0)"
  [[ "$cur_somaxconn" =~ ^[0-9]+$ ]] || cur_somaxconn=0
  [[ "$cur_syn" =~ ^[0-9]+$ ]] || cur_syn=0

  (( cur_somaxconn < somaxconn_target )) && need=1
  (( cur_syn < syn_target )) && need=1

  if (( need == 0 )); then
    info "内核参数已足够，跳过（somaxconn=${cur_somaxconn}, tcp_max_syn_backlog=${cur_syn}）"
    return 0
  fi

  # 精简系统/容器可能没有 /etc/sysctl.d；缺目录时 cat > 会失败并中断安装
  sysctl_dir="$(dirname "$SYSCTL_FILE")"
  if [[ ! -d "$sysctl_dir" ]]; then
    if mkdir -p "$sysctl_dir" 2>/dev/null; then
      info "已创建目录 ${sysctl_dir}"
    else
      warn "无法创建 ${sysctl_dir}，跳过内核参数写入"
      return 0
    fi
  fi

  if [[ -f "$SYSCTL_FILE" ]]; then
    bak="${SYSCTL_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    if cp -f "$SYSCTL_FILE" "$bak" 2>/dev/null; then
      info "已备份原 sysctl 文件到 ${bak}"
    else
      warn "备份 ${SYSCTL_FILE} 失败，继续覆盖写入"
    fi
  fi

  old_umask="$(umask)"
  umask 022
  if ! { cat > "$SYSCTL_FILE" <<EOF
# 由 mtg-install.sh 生成 —— 缓解 accept 队列积压
# 现象：高并发时 Recv-Q 持续增长、新连接被丢弃，代理表现为时通时断。
# net.core.somaxconn 控制已完成三次握手的连接队列上限；
# net.ipv4.tcp_max_syn_backlog 控制半连接（SYN）队列上限。
# 回滚：删除本文件后执行 sysctl --system，或直接重启（内核参数自然恢复默认）。
net.core.somaxconn = ${somaxconn_target}
net.ipv4.tcp_max_syn_backlog = ${syn_target}
EOF
  }; then
    warn "写入 ${SYSCTL_FILE} 失败，跳过内核参数（不影响代理运行）"
    umask "$old_umask"
    return 0
  fi
  chmod 0644 "$SYSCTL_FILE"
  umask "$old_umask"

  if ! sysctl --system >/dev/null 2>&1; then
    warn "sysctl --system 执行失败，请手动检查 ${SYSCTL_FILE}"
  fi

  cur_somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null || echo 0)"
  cur_syn="$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo 0)"
  [[ "$cur_somaxconn" =~ ^[0-9]+$ ]] || cur_somaxconn=0
  [[ "$cur_syn" =~ ^[0-9]+$ ]] || cur_syn=0

  if (( cur_somaxconn < somaxconn_target )) || (( cur_syn < syn_target )); then
    warn "内核参数校验未达预期（somaxconn=${cur_somaxconn}, tcp_max_syn_backlog=${cur_syn}）"
    warn "  请手动检查 ${SYSCTL_FILE} 与 sysctl --system 的输出"
  else
    info "内核参数已应用（somaxconn=${cur_somaxconn}, tcp_max_syn_backlog=${cur_syn}）"
  fi
  return 0
}

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
# 日志统一进 journal：journalctl -u mtg 查服务自身输出；
# journalctl -t mtg-watchdog 查看护脚本（logger 写入，与 unit 日志分开）
StandardOutput=journal
StandardError=journal
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

write_watchdog
systemctl daemon-reload
WD_TIMER_ENABLED=0
if systemctl enable --now "$WD_TIMER" >/dev/null 2>&1; then
  WD_TIMER_ENABLED=1
fi

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
info "日志：journalctl -u ${SVC} 看服务本身，journalctl -t mtg-watchdog 看看护记录（两者分开）"
apply_sysctl
firewall_hint "$LISTEN_PORT"

if systemctl is-enabled --quiet "$WD_TIMER" && systemctl is-active --quiet "$WD_TIMER"; then
  info "看护已启用：每 60s 检查一次（日志 journalctl -t mtg-watchdog）"
else
  warn "看护 timer 未正常启用（enable 结果: ${WD_TIMER_ENABLED:-0}）"
  warn "  排查: systemctl status mtg-watchdog.timer"
  warn "  日志: journalctl -u mtg-watchdog"
fi

write_deploy_info() {
  local wd_state sysctl_state deploy_dir
  wd_state="$(systemctl is-active "$WD_TIMER" 2>/dev/null || true)"
  [[ -n "$wd_state" ]] || wd_state="unknown"
  if [[ -f "$SYSCTL_FILE" ]]; then
    sysctl_state="存在"
  else
    sysctl_state="不存在"
  fi

  # 防御性兜底：/etc 一般存在，但精简系统/容器仍可能缺父目录
  deploy_dir="$(dirname "$DEPLOY_INFO")"
  if [[ ! -d "$deploy_dir" ]]; then
    if mkdir -p "$deploy_dir" 2>/dev/null; then
      info "已创建目录 ${deploy_dir}"
    else
      warn "无法创建 ${deploy_dir}，跳过部署摘要写入"
      return 0
    fi
  fi

  umask 022
  if ! { cat > "$DEPLOY_INFO" <<EOF
# mtg 部署摘要 — 由 mtg-install.sh 生成，重装会覆盖
生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
脚本版本: v2.2（含看护）
mtg 版本: ${MTG_VERSION}
监听端口: ${LISTEN_PORT}
前端域名: ${FRONT_DOMAIN}
安装路径: ${BIN}
配置文件: ${CONF}
systemd 单元: ${UNIT}
看护脚本: ${WD_BIN}
看护定时器: ${WD_TIMER}（状态: ${wd_state}）
内核参数文件: ${SYSCTL_FILE}（${sysctl_state}）
EOF
  }; then
    warn "写入 ${DEPLOY_INFO} 失败，跳过部署摘要（不影响代理运行）"
    return 0
  fi
  chmod 0644 "$DEPLOY_INFO"

  if [[ -n "${SECRET:-}" ]] && grep -qF -- "$SECRET" "$DEPLOY_INFO" 2>/dev/null; then
    warn "部署摘要自检发现 secret，已删除并重写"
    rm -f "$DEPLOY_INFO"
    if ! { cat > "$DEPLOY_INFO" <<EOF
# mtg 部署摘要 — 由 mtg-install.sh 生成，重装会覆盖
生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
脚本版本: v2.2（含看护）
mtg 版本: ${MTG_VERSION}
监听端口: ${LISTEN_PORT}
前端域名: ${FRONT_DOMAIN}
安装路径: ${BIN}
配置文件: ${CONF}
systemd 单元: ${UNIT}
看护脚本: ${WD_BIN}
看护定时器: ${WD_TIMER}（状态: ${wd_state}）
内核参数文件: ${SYSCTL_FILE}（${sysctl_state}）
EOF
    }; then
      warn "写入 ${DEPLOY_INFO} 失败，跳过部署摘要（不影响代理运行）"
      return 0
    fi
    chmod 0644 "$DEPLOY_INFO"
  fi
  info "部署摘要已写入 ${DEPLOY_INFO}"
}

# ---------- 7. 输出 ----------
show_links || true
write_deploy_info || true

echo
echo " 常用命令："
echo "   systemctl status ${SVC}      查看状态"
echo "   journalctl -u ${SVC} -f        实时日志（mtg 进程本身）"
echo "   journalctl -t mtg-watchdog -f  看护日志（重启/假死记录，logger 写入）"
echo "   ${BIN} doctor ${CONF}        配置自检"
echo "   bash $0 --doctor             运维体检"
echo "   bash $0 --show               重新显示链接"
echo "   bash $0 --uninstall          卸载"
echo
echo " secret 保存在 ${CONF}（640 root:mtg，仅 root 与 mtg 组可读），勿外泄"
echo " 若开了防火墙，记得放行 ${LISTEN_PORT}/tcp"
echo "=============================================="
