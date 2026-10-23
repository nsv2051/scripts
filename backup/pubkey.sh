#!/usr/bin/env bash
# 注意：破坏性操作 —— 会强制覆盖 $HOME/.ssh/authorized_keys 并禁用密码登录
set -uo pipefail

info() { printf '\033[32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { warn "此脚本需要 root 权限，且未找到 sudo"; exit 1; }
  exec sudo -- "$0" "$@"
fi

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

if [[ -d "$SSH_DIR" ]]; then
  SSH_OLD="${HOME}/.ssh_old.${TS}"
  mv "$SSH_DIR" "$SSH_OLD" || die "备份 $SSH_DIR 失败"
  info "已备份 $SSH_DIR -> $SSH_OLD"
fi

mkdir -p "$SSH_DIR" || die "创建 $SSH_DIR 失败"
chmod 700 "$SSH_DIR" || die "设置 $SSH_DIR 权限失败"

tmp="$(mktemp "${SSH_DIR}/.authorized_keys.XXXXXX")" || die "创建临时文件失败"
cat > "$tmp" <<'EOF'
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAuT63Rq9NpIleAgjiFCJC3K48pTPDWAL40p4p8NYDsyIqmYEjB9Bnr+WDXnzIPb3sqfo9wonavws/McNRaVYXnhHoZgNloYwqgiotvROQMNaHlZg1qXoFQ7Rbp7Y1k3iqSmfByh4lluYgS1dKANdh89xUJVW8LuZsZyYrgyYJ34OX8cGXgKiTl2j0CQh19yzO3b47R7OvX9iUQ+sDla7glYkEPUx7vwp+FMHSMXAzoFN+ONbjder1rxX/2ILIhiLZgu6F3EX4rtQCS8e4LzIwbEYjVIty012zEFms9MGpAh3e1vZvCVlpgXpJh1YI/xJ8YED25+6vUKpNBQiXohORAw==
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCo3j60agbaTXHgrlomRCbfeIadeYq9y9bwDR6jof6bp37AEbaKgYE5mt31CxLtVmDgRTG8HpT2Jm794JLuTDiPVP2moNGAn+BYehostv0H07iZ5r8nJBRdDL4M8GESyoOAGnnRmw7hjesqwHiBDBcNY/vZd7me90jgKskACfVrzYPP/uRbwulW9P9HVY7p8SOFkpdQg4UTymcgSp7S6f0XWub1kQ5+4G1z9pWg9QIXIXOEFFtsv7bIxR1zwHRfK3tw8ERQN8A9VGmqx1ZLTOSswM+cT+RD3l7fUV48mC9p04B0emdSSqWyv/35DPa6ujnc6uXPORklE1cNQult5swdKy/s2YzjDqfh70FrOYUYaxcdwGLsJhStClUrx0QXRhqStdRZjHZAR7N+PeXqrR7enuilgpaaENWdFkWA5So3kJHY3/ASWXfez7JSc6/4LUTKybaCNE6saLJ+mxWSG/ijxLeJO/RjLtF1IqNILjJ2HefkBZpRYHI6JHkXqXW5V80=
EOF
chmod 600 "$tmp" || { rm -f "$tmp"; die "设置临时文件权限失败"; }
mv -f "$tmp" "$AUTH_KEYS" || { rm -f "$tmp"; die "写入 $AUTH_KEYS 失败"; }
chmod 600 "$AUTH_KEYS" || die "设置 $AUTH_KEYS 权限失败"
info "已覆盖写入公钥: $AUTH_KEYS"

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
