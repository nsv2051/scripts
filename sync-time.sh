#!/usr/bin/env bash
# ============================================================
# sync-time.sh v2.0 —— 时区设置 + 时间同步
# 用法: bash sync-time.sh [-t 时区] [-s 服务器]... [--dry-run] [--no-cron]
#       bash sync-time.sh --check | --uninstall | -h
# 参数: -t/--tz 时区(默认 Asia/Shanghai)  -s/--server 服务器(可重复)
#       --dry-run 只检测  --check 只读自检  --uninstall 删 cron 行
#       --no-cron 不写 crontab  -h/--help 帮助
# ============================================================
set -euo pipefail
TZ_NAME="Asia/Shanghai"; declare -a SERVERS=("ntp.aliyun.com") USABLE=()
DRY_RUN=0; MODE="install"; NO_CRON=0; SERVER_OVERRIDE=0
MARKER="# sync-time.sh: auto sync (managed by nsv2051/scripts)"
TZ_RAW=""
NTPDATE_BIN=""; DAEMON=""; PM=""; CRON_SERVER=""
info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,9p' "$0"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tz) [[ $# -ge 2 ]] || die "-t 需要时区（-h 查看用法）"; TZ_NAME="$2"; shift 2 ;;
    -s|--server) [[ $# -ge 2 ]] || die "-s 需要主机名（-h 查看用法）"; if (( SERVER_OVERRIDE == 0 )); then SERVERS=(); SERVER_OVERRIDE=1; fi; SERVERS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --check) MODE=check; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --no-cron) NO_CRON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（-h 查看用法）" ;;
  esac
done
TZ_RAW="$TZ_NAME"
TZ_PATH="$(readlink -f "/usr/share/zoneinfo/$TZ_NAME" 2>/dev/null || true)"
[[ -n "$TZ_NAME" && -n "$TZ_PATH" && "$TZ_PATH" == /usr/share/zoneinfo/* ]] || die "无效时区: $TZ_RAW"
TZ_NAME="${TZ_PATH#/usr/share/zoneinfo/}"
detect_pm() {
  local c
  PM=""
  for c in apt-get dnf yum zypper pacman; do command -v "$c" >/dev/null 2>&1 && { PM="$c"; return 0; }; done
  return 0
}
# 无 systemd 的容器里 systemctl 不存在，按“无守护进程”处理，不能中断自检
detect_daemon() {
  DAEMON=""; command -v systemctl >/dev/null 2>&1 || return 0
  systemctl is-active --quiet chronyd 2>/dev/null && { DAEMON=chrony; return 0; }
  systemctl is-active --quiet chrony 2>/dev/null && { DAEMON=chrony; return 0; }
  systemctl is-active --quiet systemd-timesyncd 2>/dev/null && { DAEMON=systemd-timesyncd; return 0; }
  systemctl is-active --quiet ntpd 2>/dev/null && { DAEMON=ntpd; return 0; }
  return 0
}
apply_timezone() {
  local cur now
  cur="$(readlink -f /etc/localtime 2>/dev/null || true)"
  if [[ "$cur" == "/usr/share/zoneinfo/$TZ_NAME" ]]; then info "已是 $TZ_NAME，跳过时区设置"
  elif (( DRY_RUN )); then info "[dry-run] 将执行: ln -sfn /usr/share/zoneinfo/$TZ_NAME /etc/localtime"
  else ln -sfn "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime || die "设置 /etc/localtime 失败"; info "时区已设置为 $TZ_NAME"; fi
  # 仅 Debian 系或已有 /etc/timezone 的系统同步该文件，其它系统不强行创建
  if [[ -f /etc/timezone || -f /etc/debian_version ]]; then
    now="$(cat /etc/timezone 2>/dev/null || true)"
    if [[ "$now" == "$TZ_NAME" ]]; then info "/etc/timezone 已是 $TZ_NAME，跳过"
    elif (( DRY_RUN )); then info "[dry-run] 将执行: echo $TZ_NAME > /etc/timezone"
    else printf '%s\n' "$TZ_NAME" > /etc/timezone || warn "写入 /etc/timezone 失败"; info "/etc/timezone 已更新"; fi
  else info "系统无 /etc/timezone 且非 Debian 系，跳过"; fi
}
within_2s() { [[ -n "$1" ]] || return 1; awk -v v="$1" 'BEGIN { if (v < 0) v = -v; exit (v <= 2) ? 0 : 1 }'; }
chrony_offset() {
  local out raw sign
  command -v chronyc >/dev/null 2>&1 || return 1
  out="$(chronyc tracking 2>/dev/null)" || return 1
  raw="$(printf '%s\n' "$out" | sed -n 's/.*System time[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9.]*\)[[:space:]]*seconds.*/\1/p' | head -n1)"
  [[ -n "$raw" ]] || return 1
  sign="+"; case "$out" in *"seconds slow"*) sign="-" ;; esac
  printf '%s' "${sign}${raw#-}"
}
# ntpdate -q 的偏移量是第 4 字段，输出里没有 "offset" 字样，不能按词匹配
ntpdate_field_offset() {
  awk '$1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $4 ~ /^[+-]?[0-9]+(\.[0-9]+)?$/ { print $4; exit }'
}
ntpdate_offset() {
  local bin s out raw
  bin="$(command -v ntpdate 2>/dev/null || true)"
  [[ -n "$bin" ]] || return 1
  for s in "${SERVERS[@]}"; do
    out="$("$bin" -q "$s" 2>/dev/null)" || continue
    raw="$(printf '%s\n' "$out" | ntpdate_field_offset)"
    if [[ -n "$raw" ]]; then printf '%s' "$raw"; return 0; fi
  done
  return 1
}
td_synced() {
  local v
  command -v timedatectl >/dev/null 2>&1 || return 1
  v="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [[ -n "$v" ]] || v="$(timedatectl show -p NTPSynchronized 2>/dev/null | sed -n 's/^NTPSynchronized=//p' || true)"
  if [[ -z "$v" ]]; then v="$(timedatectl status 2>/dev/null || true)"; case "$v" in *"System clock synchronized: yes"*) return 0 ;; esac; fi
  [[ "$v" == "yes" ]]
}
wait_for_sync() {
  local i off
  if [[ "$DAEMON" == "ntpd" ]]; then sleep 2; return 0; fi
  for ((i = 1; i <= 15; i++)); do
    if [[ "$DAEMON" == "chrony" ]] && command -v chronyc >/dev/null 2>&1; then
      off="$(chrony_offset || true)"; if [[ -n "$off" ]] && within_2s "$off"; then return 0; fi
    elif [[ "$DAEMON" == "systemd-timesyncd" ]] && td_synced; then return 0; fi
    sleep 1
  done
  return 1
}
handle_daemon() {
  info "检测到 NTP 守护进程: $DAEMON，交给守护进程校时，不步进时钟"
  if (( DRY_RUN )); then
    case "$DAEMON" in
      chrony) info "[dry-run] 将执行: chronyc makestep" ;;
      systemd-timesyncd) info "[dry-run] 将执行: timedatectl set-ntp true" ;;
      ntpd) info "[dry-run] 将执行: service ntpd restart" ;;
    esac
    info "守护进程本身就在校时，本脚本不会写 crontab"; return 0
  fi
  case "$DAEMON" in
    chrony) if command -v chronyc >/dev/null 2>&1; then chronyc makestep >/dev/null 2>&1 || warn "chronyc makestep 失败"; else warn "未找到 chronyc"; fi ;;
    systemd-timesyncd) if command -v timedatectl >/dev/null 2>&1; then timedatectl set-ntp true >/dev/null 2>&1 || warn "timedatectl set-ntp true 失败"; else warn "未找到 timedatectl"; fi ;;
    ntpd) if command -v service >/dev/null 2>&1; then service ntpd restart >/dev/null 2>&1 || warn "重启 ntpd 失败"; else warn "未找到 service，请手动重启 ntpd"; fi ;;
  esac
  info "等待校时收敛（最多 15 秒）"
  if wait_for_sync; then info "守护进程已确认同步"; else warn "15 秒内未确认同步，可稍后运行 --check"; fi
  cleanup_legacy_cron
  info "守护进程本身就在校时，跳过 crontab 以避免与其抢时钟"
}
ensure_ntpdate() {
  NTPDATE_BIN="$(command -v ntpdate 2>/dev/null || true)"
  if [[ -n "$NTPDATE_BIN" ]]; then info "已找到 ntpdate: $NTPDATE_BIN"; return 0; fi
  detect_pm
  if (( DRY_RUN )); then
    if [[ -n "$PM" ]]; then info "[dry-run] 将执行: 使用 $PM 安装 ntpdate"; else warn "未检测到包管理器，正式运行会失败"; fi
    return 0
  fi
  [[ -n "$PM" ]] || die "未安装 ntpdate，且未找到受支持的包管理器"
  info "未找到 ntpdate，使用 $PM 安装"
  case "$PM" in
    apt-get)
      apt-get update -qq || warn "apt-get update 失败，继续尝试安装"
      if ! apt-get install -y ntpdate >/dev/null 2>&1; then
        warn "apt-get 安装 ntpdate 失败，回退 ntpsec-ntpdate"
        apt-get install -y ntpsec-ntpdate || die "安装 ntpdate 失败"
      fi ;;
    dnf) dnf install -y ntpdate || die "安装 ntpdate 失败" ;;
    yum) yum install -y ntpdate || die "安装 ntpdate 失败" ;;
    zypper) zypper -n install ntp || die "安装 ntp 失败" ;;
    pacman) pacman -S --noconfirm ntp || die "安装 ntp 失败" ;;
    *) die "不支持的包管理器: $PM" ;;
  esac
  NTPDATE_BIN="$(command -v ntpdate 2>/dev/null || true)"
  [[ -n "$NTPDATE_BIN" ]] || die "安装 ntpdate 失败"
  info "安装完成: $NTPDATE_BIN"
}
dns_ok() {
  local h="$1"
  if command -v getent >/dev/null 2>&1 && getent hosts "$h" >/dev/null 2>&1; then return 0; fi
  if command -v ping >/dev/null 2>&1 && ping -c1 -W2 "$h" >/dev/null 2>&1; then return 0; fi
  # 极简容器可能既无 getent 也无 ping，硬判失败会误杀，交给 ntpdate 自己解析
  if ! command -v getent >/dev/null 2>&1 && ! command -v ping >/dev/null 2>&1; then return 0; fi
  return 1
}
select_servers() {
  local s
  USABLE=()
  for s in "${SERVERS[@]}"; do
    if dns_ok "$s"; then USABLE+=("$s"); else warn "DNS 预检失败，跳过: $s"; fi
  done
  (( ${#USABLE[@]} > 0 )) || die "所有 NTP 服务器均无法解析"
}
do_sync() {
  local s off synced=0
  for s in "${USABLE[@]}"; do
    info "同步时间: $NTPDATE_BIN -u -b $s"
    if "$NTPDATE_BIN" -u -b "$s" >/dev/null 2>&1; then CRON_SERVER="$s"; synced=1; break; fi
    warn "与 $s 同步失败，尝试下一个"
  done
  (( synced == 1 )) || die "所有 NTP 服务器同步失败"
  off="$("$NTPDATE_BIN" -q "$CRON_SERVER" 2>/dev/null | ntpdate_field_offset || true)"
  if [[ -z "$off" ]]; then warn "同步后无法读取偏差"; return 1; fi
  if within_2s "$off"; then info "同步完成，偏差 ${off} 秒"; return 0; fi
  warn "同步后偏差仍为 ${off} 秒"; return 1
}
# 删除标记行及其下一行；install 时额外清掉旧版写坏的裸 ntpdate 行
strip_managed() {
  printf '%s\n' "$1" | awk -v m="$MARKER" -v legacy="${2:-0}" '
    skip { skip = 0; next }
    $0 == m { skip = 1; next }
    legacy == 1 && $0 !~ /^[ \t]*#/ && $0 ~ /(^|[ \t])ntpdate[ \t]+pool\.ntp\.org([ \t>]|$)/ { next }
    { print }'
}
cron_line_exists() {
  local tab
  command -v crontab >/dev/null 2>&1 || return 1
  tab="$(crontab -l 2>/dev/null || true)"
  [[ "$tab" == *"$MARKER"* ]]
}
write_cron() {
  local server="$1" min line current filtered
  min=$((RANDOM % 60))
  line="${min} * * * * ${NTPDATE_BIN} -u -s ${server} >/dev/null 2>&1"
  if (( DRY_RUN )); then info "[dry-run] 将执行: 写入 crontab: $line"; return 0; fi
  command -v crontab >/dev/null 2>&1 || { warn "未找到 crontab，跳过写入（时间同步本身已完成）"; return 0; }
  current="$(crontab -l 2>/dev/null || true)"; filtered=""
  if [[ -n "$current" ]]; then filtered="$(strip_managed "$current" 1)"; fi
  if [[ -n "$filtered" ]]; then { printf '%s\n' "$filtered"; printf '%s\n%s\n' "$MARKER" "$line"; } | crontab -
  else printf '%s\n%s\n' "$MARKER" "$line" | crontab -; fi
  if ! crontab -l 2>/dev/null | grep -F -- "$MARKER" >/dev/null; then warn "crontab 写入后校验失败"; return 1; fi
  if [[ ! -x "$NTPDATE_BIN" ]]; then warn "cron 中 ntpdate 路径不可执行: $NTPDATE_BIN"; return 1; fi
  info "已写入 cron: 每小时 ${min} 分（服务器 ${server}）"
}
uninstall_cron() {
  local current filtered
  if ! command -v crontab >/dev/null 2>&1; then info "未发现 sync-time 写入的 cron 行"; return 0; fi
  current="$(crontab -l 2>/dev/null || true)"
  if [[ -z "$current" || "$current" != *"$MARKER"* ]]; then info "未发现 sync-time 写入的 cron 行"; return 0; fi
  filtered="$(strip_managed "$current" 0)"
  if [[ -n "$filtered" ]]; then printf '%s\n' "$filtered" | crontab -; else crontab -r 2>/dev/null || true; fi
  info "已删除 sync-time 写入的 cron 行"
}

# 守护进程分支不写 cron，但仍要清掉旧版 v1 留下的坏行，否则用户跑完等于没修
cleanup_legacy_cron() {
  local current filtered
  command -v crontab >/dev/null 2>&1 || return 0
  current="$(crontab -l 2>/dev/null || true)"
  [[ -n "$current" ]] || return 0
  filtered="$(strip_managed "$current" 1)"
  [[ "$filtered" == "$current" ]] && return 0
  if (( NO_CRON )); then
    warn "检测到旧版写坏的 sync-time cron 行；--no-cron 下不改动 crontab，可运行 --uninstall 或手动删除"
    return 0
  fi
  if [[ -n "$filtered" ]]; then printf '%s\n' "$filtered" | crontab -; else crontab -r 2>/dev/null || true; fi
  info "已清理旧版 sync-time 写入的 cron 行（cron 默认 PATH 找不到 /usr/sbin/ntpdate）"
}

do_check() {
  local cur off synced="no" tz_ok=0 svc="无" rc=1
  cur="$(readlink -f /etc/localtime 2>/dev/null || true)"
  if [[ "$cur" == "/usr/share/zoneinfo/$TZ_NAME" ]]; then tz_ok=1; fi
  detect_daemon
  if [[ -n "$DAEMON" ]]; then svc="$DAEMON (active)"; fi
  off="$(chrony_offset || true)"
  if [[ -z "$off" ]]; then off="$(ntpdate_offset || true)"; fi
  if [[ -n "$off" ]]; then if within_2s "$off"; then synced=yes; fi
  elif td_synced; then synced=yes; fi
  printf '时区        : %s (/etc/localtime -> %s)\n' "$TZ_NAME" "${cur:-未设置}"
  printf '已同步      : %s\nNTP 服务    : %s\n' "$synced" "$svc"
  if [[ -n "$off" ]]; then case "$off" in +*|-*) printf '当前偏差    : %s 秒\n' "$off" ;; *) printf '当前偏差    : +%s 秒\n' "$off" ;; esac
  else printf '当前偏差    : 未知\n'; fi
  if cron_line_exists; then printf 'cron 行     : 存在\n'; else printf 'cron 行     : 不存在\n'; fi
  if (( tz_ok == 1 )) && [[ "$synced" == "yes" ]]; then rc=0; fi
  return "$rc"
}
print_summary() {
  local cur distro np
  cur="$(readlink -f /etc/localtime 2>/dev/null || true)"
  distro="$(awk -F= '/^PRETTY_NAME=/{sub(/^PRETTY_NAME=/,""); gsub(/"/,""); print; exit}' /etc/os-release 2>/dev/null || true)"
  [[ -n "$distro" ]] || distro="$(uname -s)"
  np="${NTPDATE_BIN:-$(command -v ntpdate 2>/dev/null || true)}"
  np="${np:-未安装（将自动安装）}"
  info "环境摘要"
  if [[ ${EUID} -eq 0 ]]; then info "  root: yes"; else info "  root: no"; fi
  info "  时区: $TZ_NAME -> ${cur:-未设置}"; info "  distro: $distro"; info "  包管理器: ${PM:-无}"; info "  ntpdate: $np"; info "  守护进程: ${DAEMON:-无}"
}
detect_pm
if [[ "$MODE" == check ]]; then rc=0; do_check || rc=$?; exit "$rc"; fi
if [[ "$MODE" == uninstall ]]; then
  if (( DRY_RUN )); then info "[dry-run] 将执行: 删除 sync-time 写入的 crontab 行，不动其它条目"; exit 0; fi
  [[ ${EUID} -eq 0 ]] || die "需要 root 权限运行（sudo）"; uninstall_cron; exit 0
fi
if (( ! DRY_RUN )); then [[ ${EUID} -eq 0 ]] || die "需要 root 权限运行（sudo）"; fi
apply_timezone
detect_daemon
if [[ -n "$DAEMON" ]]; then handle_daemon; if (( DRY_RUN )); then print_summary; fi; exit 0; fi
ensure_ntpdate
if (( DRY_RUN )); then
  info "[dry-run] 将执行: DNS 预检 ${SERVERS[*]}"
  info "[dry-run] 将执行: ${NTPDATE_BIN:-/usr/sbin/ntpdate} -u -b <首个可用服务器>"
  info "[dry-run] 将执行: ${NTPDATE_BIN:-/usr/sbin/ntpdate} -q <服务器> 读取实际偏差"
  if (( NO_CRON == 0 )); then info "[dry-run] 将执行: 写入带标记的 crontab 行"; else info "已指定 --no-cron，不写 crontab"; fi
  print_summary; exit 0
fi
select_servers
if ! do_sync; then exit 1; fi
if (( NO_CRON )); then info "已指定 --no-cron，跳过 crontab"; else write_cron "$CRON_SERVER" || exit 1; fi
info "全部完成"
