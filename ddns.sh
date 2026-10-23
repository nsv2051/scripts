#!/usr/bin/env bash
# Cloudflare A 记录 DDNS：公网 IP 变化时更新记录
set -uo pipefail

info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: ddns.sh [--check] [-h|--help]

选项:
  --check        只打印公网 IP 与 DNS 解析结果，不发起写请求；一致 rc=0，不一致 rc=1
  -h, --help     显示本帮助

环境变量（环境变量优先于配置文件）:
  CF_API_TOKEN   Cloudflare API Token（推荐）
  CF_API_EMAIL   Cloudflare 账号邮箱（使用 Global API Key 时必填）
  CF_API_KEY     Cloudflare Global API Key（使用邮箱方式时必填）
  CF_ZONE        区域名，例如 example.com
  CF_RECORD      A 记录全名，例如 home.example.com
  CF_PROXIED     是否开启 Cloudflare 代理，默认 false
  CF_TTL         记录 TTL，默认 1（自动）
  IP_URL         获取公网 IP 的地址，默认 https://checkip.amazonaws.com
  DDNS_CONF      配置文件路径，默认 /etc/ddns.conf

兼容旧变量名: cloudflare_auth_email、cloudflare_auth_key、zone、dnsrecord

示例:
  CF_API_TOKEN=xxx CF_ZONE=example.com CF_RECORD=home.example.com bash ddns.sh
  bash ddns.sh --check
EOF
}

MODE=update
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（-h 查看用法）" ;;
  esac
done

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_API_EMAIL="${CF_API_EMAIL:-}"
CF_API_KEY="${CF_API_KEY:-}"
CF_ZONE="${CF_ZONE:-}"
CF_RECORD="${CF_RECORD:-}"
CF_PROXIED="${CF_PROXIED:-}"
CF_TTL="${CF_TTL:-}"
IP_URL="${IP_URL:-}"

conf="${DDNS_CONF:-/etc/ddns.conf}"
if [[ -r "$conf" ]]; then
  env_token="$CF_API_TOKEN"
  env_email="$CF_API_EMAIL"
  env_key="$CF_API_KEY"
  env_zone="$CF_ZONE"
  env_record="$CF_RECORD"
  env_proxied="$CF_PROXIED"
  env_ttl="$CF_TTL"
  env_ip_url="$IP_URL"
  # shellcheck disable=SC1090
  source "$conf"
  [[ -n "$env_token" ]] && CF_API_TOKEN="$env_token"
  [[ -n "$env_email" ]] && CF_API_EMAIL="$env_email"
  [[ -n "$env_key" ]] && CF_API_KEY="$env_key"
  [[ -n "$env_zone" ]] && CF_ZONE="$env_zone"
  [[ -n "$env_record" ]] && CF_RECORD="$env_record"
  [[ -n "$env_proxied" ]] && CF_PROXIED="$env_proxied"
  [[ -n "$env_ttl" ]] && CF_TTL="$env_ttl"
  [[ -n "$env_ip_url" ]] && IP_URL="$env_ip_url"
fi

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_API_EMAIL="${CF_API_EMAIL:-}"
CF_API_KEY="${CF_API_KEY:-}"
CF_ZONE="${CF_ZONE:-${zone:-}}"
CF_RECORD="${CF_RECORD:-${dnsrecord:-}}"
CF_API_EMAIL="${CF_API_EMAIL:-${cloudflare_auth_email:-}}"
CF_API_KEY="${CF_API_KEY:-${cloudflare_auth_key:-}}"
CF_PROXIED="${CF_PROXIED:-false}"
CF_TTL="${CF_TTL:-1}"
IP_URL="${IP_URL:-https://checkip.amazonaws.com}"

missing=()
[[ -n "$CF_ZONE" ]] || missing+=("CF_ZONE")
[[ -n "$CF_RECORD" ]] || missing+=("CF_RECORD")
if [[ -z "$CF_API_TOKEN" ]]; then
  if [[ -z "$CF_API_EMAIL" && -z "$CF_API_KEY" ]]; then
    missing+=("CF_API_TOKEN（或 CF_API_EMAIL + CF_API_KEY）")
  else
    [[ -n "$CF_API_EMAIL" ]] || missing+=("CF_API_EMAIL")
    [[ -n "$CF_API_KEY" ]] || missing+=("CF_API_KEY")
  fi
fi
if (( ${#missing[@]} > 0 )); then
  die "缺少必要配置: ${missing[*]}（-h 查看用法）"
fi

command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装"
command -v jq >/dev/null 2>&1 || die "缺少 jq，请先安装"

headers=(-H "Content-Type: application/json")
if [[ -n "$CF_API_TOKEN" ]]; then
  headers+=(-H "Authorization: Bearer $CF_API_TOKEN")
else
  headers+=(-H "X-Auth-Email: $CF_API_EMAIL" -H "X-Auth-Key: $CF_API_KEY")
fi

resolve_ip() {
  local out ip
  if command -v dig >/dev/null 2>&1; then
    out="$(dig +short A "$CF_RECORD" 2>/dev/null || true)"
    ip="$(printf '%s\n' "$out" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)"
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  if command -v host >/dev/null 2>&1; then
    out="$(host -t A "$CF_RECORD" 2>/dev/null || true)"
    ip="$(printf '%s\n' "$out" | sed -n 's/.* has address //p' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)"
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  if command -v getent >/dev/null 2>&1; then
    out="$(getent hosts "$CF_RECORD" 2>/dev/null || true)"
    ip="$(printf '%s\n' "$out" | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)"
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  return 1
}

api() {
  local method="$1" url="$2" data="${3:-}" resp ok
  if [[ -n "$data" ]]; then
    resp="$(curl -sS --max-time 15 -X "$method" "$url" "${headers[@]}" --data "$data")" || die "API 请求失败: $url"
  else
    resp="$(curl -sS --max-time 15 -X "$method" "$url" "${headers[@]}")" || die "API 请求失败: $url"
  fi
  ok="$(printf '%s\n' "$resp" | jq -r '.success // false' 2>/dev/null || true)"
  if [[ "$ok" != "true" ]]; then
    printf '%s\n' "$resp" | jq -c '.errors // []' >&2 2>/dev/null || printf '%s\n' "$resp" >&2
    die "Cloudflare API 返回失败: $url"
  fi
  printf '%s\n' "$resp"
}

ip="$(curl -fsS --max-time 15 "$IP_URL" 2>/dev/null)" || die "获取公网 IP 失败: $IP_URL"
ip="${ip//[[:space:]]/}"
[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "获取到的公网 IP 格式不正确: $ip"

if [[ "$MODE" == "check" ]]; then
  dns_ip="$(resolve_ip || true)"
  printf '当前公网 IP   : %s\n' "$ip"
  printf 'DNS 解析结果  : %s\n' "${dns_ip:-（无解析结果）}"
  if [[ -n "$dns_ip" && "$dns_ip" == "$ip" ]]; then
    info "DNS 记录与公网 IP 一致"
    exit 0
  fi
  warn "DNS 记录与公网 IP 不一致"
  exit 1
fi

dns_ip="$(resolve_ip || true)"
if [[ "$dns_ip" == "$ip" ]]; then
  info "$CF_RECORD 已指向 $ip，无需更新"
  exit 0
fi
if [[ -z "$dns_ip" ]]; then
  warn "未能解析 $CF_RECORD，继续尝试更新"
else
  info "$CF_RECORD 当前指向 $dns_ip，准备更新为 $ip"
fi

[[ "$CF_TTL" =~ ^[0-9]+$ ]] || die "CF_TTL 必须为整数: $CF_TTL"
case "$CF_PROXIED" in
  true|false) ;;
  *) die "CF_PROXIED 只能为 true 或 false: $CF_PROXIED" ;;
esac
payload="$(jq -n --arg type A --arg name "$CF_RECORD" --arg content "$ip" \
  --argjson ttl "$CF_TTL" --argjson proxied "$CF_PROXIED" \
  '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')" \
  || die "生成请求数据失败（检查 CF_TTL/CF_PROXIED）"

zone_enc="$(jq -rn --arg v "$CF_ZONE" '$v|@uri')"
resp="$(api GET "https://api.cloudflare.com/client/v4/zones?name=${zone_enc}&status=active")" || exit 1
zoneid="$(printf '%s\n' "$resp" | jq -r '.result[0].id // empty')"
[[ -n "$zoneid" ]] || die "未找到区域 $CF_ZONE"

record_enc="$(jq -rn --arg v "$CF_RECORD" '$v|@uri')"
resp="$(api GET "https://api.cloudflare.com/client/v4/zones/${zoneid}/dns_records?type=A&name=${record_enc}")" || exit 1
recordid="$(printf '%s\n' "$resp" | jq -r '.result[0].id // empty')"

if [[ -z "$recordid" ]]; then
  resp="$(api POST "https://api.cloudflare.com/client/v4/zones/${zoneid}/dns_records" "$payload")" || exit 1
  info "已创建 A 记录 $CF_RECORD -> $ip"
else
  resp="$(api PUT "https://api.cloudflare.com/client/v4/zones/${zoneid}/dns_records/${recordid}" "$payload")" || exit 1
  info "已更新 A 记录 $CF_RECORD -> $ip"
fi
