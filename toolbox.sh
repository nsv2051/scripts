#!/usr/bin/env bash
# ============================================================
# toolbox.sh v1.0 —— nsv2051/scripts 统一入口
# 用法:
#   bash toolbox.sh                    菜单
#   bash toolbox.sh -l|--list          列出工具
#   bash toolbox.sh -h|--help          帮助
#   bash toolbox.sh <id> [参数...]     直接运行并透传参数
#   bash toolbox.sh <id> -- [参数...]  同上（-- 为分隔符）
# ============================================================
set -uo pipefail

VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/nsv2051/scripts/main}"
RAW_PROXY="${RAW_PROXY:-https://gitproxy.eu.org}"
QCS_URL="${QCS_URL:-https://ssh.nnn.cx/sh}"

info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

TOOL_IDS=(syscard kworker systool synctime mtg automtg backup ddns ssh)
declare -A TOOL_TYPE TOOL_TARGET TOOL_DESC TOOL_ROOT TOOL_GROUP

TOOL_TYPE[syscard]=local;   TOOL_TARGET[syscard]=syscard.sh
TOOL_DESC[syscard]="系统信息快照（只读）"
TOOL_ROOT[syscard]=0;       TOOL_GROUP[syscard]="查看"

TOOL_TYPE[kworker]=local;   TOOL_TARGET[kworker]=kworker-check.sh
TOOL_DESC[kworker]="挖矿/恶意进程检测"
TOOL_ROOT[kworker]=1;       TOOL_GROUP[kworker]="修复"

TOOL_TYPE[systool]=local;   TOOL_TARGET[systool]=systool.sh
TOOL_DESC[systool]="系统运维菜单（电源/源/DNS/磁盘/网络/CPU/NTP）"
TOOL_ROOT[systool]=1;       TOOL_GROUP[systool]="修复"

TOOL_TYPE[synctime]=local;  TOOL_TARGET[synctime]=sync-time.sh
TOOL_DESC[synctime]="时区 + 时间同步"
TOOL_ROOT[synctime]=1;      TOOL_GROUP[synctime]="修复"

TOOL_TYPE[mtg]=local;       TOOL_TARGET[mtg]=mtg-install.sh
TOOL_DESC[mtg]="mtg MTProto 代理（原生二进制，校验 SHA-256）"
TOOL_ROOT[mtg]=1;           TOOL_GROUP[mtg]="部署"

TOOL_TYPE[automtg]=local;   TOOL_TARGET[automtg]=automtg.sh
TOOL_DESC[automtg]="mtg Docker 版一键（随机端口）"
TOOL_ROOT[automtg]=1;       TOOL_GROUP[automtg]="部署"

TOOL_TYPE[backup]=local;    TOOL_TARGET[backup]=setup-backup.sh
TOOL_DESC[backup]="远程备份配置（rclone + cron）"
TOOL_ROOT[backup]=1;        TOOL_GROUP[backup]="配置（含 SSH）"

TOOL_TYPE[ddns]=local;      TOOL_TARGET[ddns]=ddns.sh
TOOL_DESC[ddns]="Cloudflare DDNS 更新"
TOOL_ROOT[ddns]=0;          TOOL_GROUP[ddns]="配置（含 SSH）"

TOOL_TYPE[ssh]=remote;      TOOL_TARGET[ssh]=https://ssh.nnn.cx/sh
TOOL_DESC[ssh]="SSH 公钥部署（qcs 项目，受管块安全写入）"
TOOL_ROOT[ssh]=1;           TOOL_GROUP[ssh]="配置（含 SSH）"

HAVE_TTY=0
TOOL_TMPDIR=""

cleanup() {
  if [[ -n "$TOOL_TMPDIR" && -d "$TOOL_TMPDIR" ]]; then
    rm -rf "$TOOL_TMPDIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
用法:
  bash toolbox.sh                    交互菜单选择工具
  bash toolbox.sh -l|--list          列出全部工具
  bash toolbox.sh -h|--help          显示本帮助
  bash toolbox.sh <id> [参数...]     直接运行工具（参数原样透传）
  bash toolbox.sh <id> -- [参数...]  同上，-- 用作分隔符

环境变量:
  QCS_URL    qcs 远程脚本地址，默认 https://ssh.nnn.cx/sh
  RAW_PROXY  下载加速通道，默认 https://gitproxy.eu.org（设为空则只直连）
EOF
}

tool_exists() {
  local id
  for id in "${TOOL_IDS[@]}"; do
    [[ "$id" == "$1" ]] && return 0
  done
  return 1
}

list_tools() {
  local id root type
  printf '%-10s %-12s %-6s %s\n' "ID" "类型" "ROOT" "说明"
  for id in "${TOOL_IDS[@]}"; do
    type=${TOOL_TYPE[$id]}
    [[ "$type" == "remote" ]] && type="remote/qcs"
    if (( TOOL_ROOT[$id] )); then root="是"; else root="否"; fi
    printf '%-10s %-12s %-6s %s\n' "$id" "$type" "$root" "${TOOL_DESC[$id]}"
  done
}

resolve_local() {
  local name="$1"
  LOCAL_SCRIPT=""

  if [[ -f "$SCRIPT_DIR/$name" ]]; then
    LOCAL_SCRIPT="$SCRIPT_DIR/$name"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warn "本地缺少 $name，且未找到 curl，无法下载"
    return 1
  fi

  if [[ -z "$TOOL_TMPDIR" ]]; then
    TOOL_TMPDIR="$(mktemp -d)" || { warn "无法创建临时目录"; return 1; }
  fi

  LOCAL_SCRIPT="$TOOL_TMPDIR/$name"
  if ! curl -fsSL --max-time 60 --retry 2 "$RAW_BASE/$name" -o "$LOCAL_SCRIPT"; then
    warn "直连下载失败，尝试加速通道..."
    if [[ -n "$RAW_PROXY" ]] && curl -fsSL --max-time 60 --retry 2 "$RAW_PROXY/$RAW_BASE/$name" -o "$LOCAL_SCRIPT"; then
      :
    else
      if [[ -n "$RAW_PROXY" ]]; then
        warn "下载 $name 失败: $RAW_BASE/$name 或 $RAW_PROXY/$RAW_BASE/$name"
      else
        warn "下载 $name 失败: $RAW_BASE/$name"
      fi
      LOCAL_SCRIPT=""
      return 1
    fi
  fi
  sed -i 's/\r$//' "$LOCAL_SCRIPT"
  return 0
}

run_remote() {
  local -a args=("$@")
  local -a status=()
  local s rc=0

  if ! command -v curl >/dev/null 2>&1; then
    warn "未找到 curl，请先安装 curl"
    return 1
  fi

  curl -fsSL --max-time 60 --retry 2 -A 'curl/8' "$QCS_URL" | bash -s -- "${args[@]}"
  status=("${PIPESTATUS[@]}")
  for s in "${status[@]}"; do
    (( s != 0 )) && rc=$s
  done
  return "$rc"
}

run_local() {
  local name="$1"
  shift
  local -a args=("$@")

  resolve_local "$name" || return 1

  if (( HAVE_TTY )); then
    bash "$LOCAL_SCRIPT" "${args[@]}" </dev/tty
  else
    bash "$LOCAL_SCRIPT" "${args[@]}"
  fi
}

run_tool() {
  local id="$1"
  shift
  local -a args=("$@")
  local allow_help=0 a

  if [[ "$id" == "ssh" ]]; then
    for a in "${args[@]}"; do
      [[ "$a" == "-h" || "$a" == "--help" ]] && allow_help=1
    done
  fi

  if (( TOOL_ROOT[$id] )) && (( EUID != 0 )) && (( ! allow_help )); then
    warn "此工具需要 root 权限，请用: sudo bash toolbox.sh $id"
    return 1
  fi

  if [[ "${TOOL_TYPE[$id]}" == "remote" ]]; then
    run_remote "${args[@]}"
  else
    run_local "${TOOL_TARGET[$id]}" "${args[@]}"
  fi
}

show_menu() {
  local i id group current="" root_mark remote_mark
  printf '\033[1mnsv2051/scripts 工具箱 v%s\033[0m\n' "$VERSION"
  printf '%s\n' "========================================"
  for i in "${!TOOL_IDS[@]}"; do
    id=${TOOL_IDS[$i]}
    group=${TOOL_GROUP[$id]}
    if [[ "$group" != "$current" ]]; then
      printf '\n[%s]\n' "$group"
      current="$group"
    fi
    root_mark=""
    (( TOOL_ROOT[$id] )) && root_mark=" [root]"
    remote_mark=""
    [[ "${TOOL_TYPE[$id]}" == "remote" ]] && remote_mark=" [远程/qcs]"
    printf '  %d) %-9s %s%s%s\n' "$((i + 1))" "$id" "${TOOL_DESC[$id]}" "$root_mark" "$remote_mark"
  done
  printf '\n  q) 退出\n  l) 重新列出\n'
}

menu() {
  local ans id idx rc
  while true; do
    show_menu
    printf '\n请选择: '
    if ! read -r ans <&3; then
      printf '\n'
      return 0
    fi
    case "$ans" in
      q|Q) return 0 ;;
      l|L) continue ;;
      '') continue ;;
      *)
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#TOOL_IDS[@]} )); then
          idx=$((ans - 1))
          id=${TOOL_IDS[$idx]}
          if (( TOOL_ROOT[$id] )) && (( EUID != 0 )); then
            warn "此工具需要 root 权限，请用: sudo bash toolbox.sh $id"
            continue
          fi
          run_tool "$id"
          rc=$?
          (( rc != 0 )) && warn "工具 $id 退出码: $rc"
          read -r -p "按回车返回菜单..." _ <&3 || true
        else
          warn "无效输入: $ans"
        fi
        ;;
    esac
  done
}

if { exec 3</dev/tty; } 2>/dev/null; then
  HAVE_TTY=1
fi

case "${1:-}" in
  -l|--list) list_tools; exit 0 ;;
  -h|--help) usage; exit 0 ;;
esac

if [[ $# -eq 0 ]]; then
  if (( ! HAVE_TTY )); then
    usage >&2
    exit 1
  fi
  menu
  exit 0
fi

id="$1"
shift
if ! tool_exists "$id"; then
  die "未知工具: $id（使用 -l 查看可用工具）"
fi
if [[ "${1:-}" == "--" ]]; then
  shift
fi

run_tool "$id" "$@"
rc=$?
exit "$rc"
