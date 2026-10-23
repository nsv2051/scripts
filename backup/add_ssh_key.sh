#!/usr/bin/env bash
# 下载公钥并配置 SSH 公钥登录（可重复执行）
set -uo pipefail

info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { warn "此脚本需要 root 权限，且未找到 sudo"; exit 1; }
  exec sudo -- "$0" "$@"
fi

KEY_URL="${KEY_URL:-https://github.com/nsv2051.keys}"
SSH_DIR="${HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONF="/etc/ssh/sshd_config"
TS="$(date +%Y%m%d-%H%M%S)"

sed_escape() { printf '%s' "$1" | sed 's/[\\/&|]/\\&/g'; }

# 幂等写入 sshd_config 的 "关键字 值" 配置
set_sshd_kv() {
  local file="$1" key="$2" value="$3" esc
  [[ -f "$file" ]] || return 1
  esc="$(sed_escape "$value")"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]=]+" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]=]+.*|${key} ${esc}|" "$file"
  else
    printf '%s %s\n' "$key" "$value" >> "$file"
  fi
}

host="$(hostname)" || die "获取主机名失败"
host_re="${host//./\\.}"
if grep -qE "^127\.0\.0\.1[[:space:]]+${host_re}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
  info "/etc/hosts 已包含 $host，跳过"
else
  printf '127.0.0.1 %s\n' "$host" >> /etc/hosts || die "写入 /etc/hosts 失败"
  info "已向 /etc/hosts 添加 127.0.0.1 $host"
fi

mkdir -p "$SSH_DIR" || die "创建 $SSH_DIR 失败"
chmod 700 "$SSH_DIR" || die "设置 $SSH_DIR 权限失败"

tmp="$(mktemp "${SSH_DIR}/.authorized_keys.XXXXXX")" || die "创建临时文件失败"
if ! curl -fsSL --max-time 30 "$KEY_URL" -o "$tmp"; then
  rm -f "$tmp"
  die "下载公钥失败，已保留原 $AUTH_KEYS: $KEY_URL"
fi
if [[ ! -s "$tmp" ]] || ! grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-)' "$tmp"; then
  rm -f "$tmp"
  die "下载内容不是有效公钥，已保留原 $AUTH_KEYS"
fi
chmod 600 "$tmp" || { rm -f "$tmp"; die "设置临时文件权限失败"; }

if [[ -f "$AUTH_KEYS" ]]; then
  cp -p "$AUTH_KEYS" "${AUTH_KEYS}.bak.${TS}" || { rm -f "$tmp"; die "备份 $AUTH_KEYS 失败"; }
  info "已备份 $AUTH_KEYS -> ${AUTH_KEYS}.bak.${TS}"
fi
mv -f "$tmp" "$AUTH_KEYS" || { rm -f "$tmp"; die "替换 $AUTH_KEYS 失败，原文件未改动"; }
chmod 600 "$AUTH_KEYS" || die "设置 $AUTH_KEYS 权限失败"
info "已写入公钥: $AUTH_KEYS"

[[ -f "$SSHD_CONF" ]] || die "未找到 $SSHD_CONF"
SSHD_BAK="${SSHD_CONF}.bak.${TS}"
cp -p "$SSHD_CONF" "$SSHD_BAK" || die "备份 $SSHD_CONF 失败"
info "已备份 $SSHD_CONF -> $SSHD_BAK"

restore_sshd() { cp -p "$SSHD_BAK" "$SSHD_CONF"; }

set_sshd_kv "$SSHD_CONF" PubkeyAuthentication yes || { restore_sshd; die "写入 PubkeyAuthentication 失败，已回滚"; }
set_sshd_kv "$SSHD_CONF" AuthorizedKeysFile .ssh/authorized_keys || { restore_sshd; die "写入 AuthorizedKeysFile 失败，已回滚"; }
set_sshd_kv "$SSHD_CONF" PasswordAuthentication no || { restore_sshd; die "写入 PasswordAuthentication 失败，已回滚"; }
info "已更新 $SSHD_CONF（PubkeyAuthentication/AuthorizedKeysFile/PasswordAuthentication）"

if ! sshd -t; then
  restore_sshd
  die "sshd 配置校验失败，已回滚 $SSHD_CONF"
fi
if ! systemctl restart sshd; then
  restore_sshd
  die "sshd 重启失败，已回滚 $SSHD_CONF，请手动检查"
fi
info "sshd 已重启，公钥登录与密码登录设置已生效"
info "请保持当前会话，另开窗口验证密钥登录后再退出"
