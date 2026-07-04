#!/bin/bash
set -euo pipefail

# ============================================
#  Linux 通用远程备份 - 安装配置脚本
#  功能：检测/安装 rclone，交互式生成备份脚本并配置定时任务
#  特性：支持通配符、单文件备份、按数量/天数保留策略
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

cat << 'EOF'

  ____  _____ ____  _   _ __  __ _____    ___  __  __   _    ____  _____ ____  _   _
 |  _ \| ____/ ___|| | | | \/  | ____|  / _ \| \/  | / \  |  _ \| ____/ ___|| | | |
 | |_) | _| \___ \| | | | |\/| |  _|   | | | | |\/| / _ \ | |_) | _| \___ \| |_| |
 |  __/| |___ ___) | |_| | |  | | |___ | |_| | |  / ___ \|  __/| |___ ___) |  _  |
 |_|   |_____|____/ \___/|_|  |_|_____| \___/|_| /_/   \_\_|  |_____|____/|_| |_|

                              Universal Remote Backup
EOF

# ============================================
#  第一步：检测并安装 rclone
# ============================================
step "第一步：检测 rclone"

if command -v rclone &> /dev/null; then
    info "rclone 已安装: $(rclone version | head -1)"
else
    warn "未检测到 rclone，开始安装..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y rclone
    elif command -v yum &> /dev/null; then
        yum install -y epel-release
        yum install -y rclone
    elif command -v dnf &> /dev/null; then
        dnf install -y epel-release
        dnf install -y rclone
    else
        error "未检测到支持的包管理器，请手动安装 rclone"
        exit 1
    fi
    if command -v rclone &> /dev/null; then
        info "rclone 安装成功: $(rclone version | head -1)"
    else
        error "安装后仍无法找到 rclone，请手动安装后重新运行"
        exit 1
    fi
fi

# ============================================
#  第二步：检查 rclone 远程配置
# ============================================
step "第二步：检查 rclone 远程配置"

REMOTES=$(rclone listremotes 2>/dev/null || true)

if [ -z "$REMOTES" ]; then
    warn "当前没有 rclone 远程配置。"
    echo ""
    echo -e "  请先配置远程存储："
    echo -e "    ${CYAN}rclone config${NC}"
    echo ""
    read -p "  配置完成后按 Enter 继续，或输入 q 退出: " -r quit_flag
    if [[ "$quit_flag" == "q" || "$quit_flag" == "Q" ]]; then exit 0; fi
    REMOTES=$(rclone listremotes 2>/dev/null || true)
    if [ -z "$REMOTES" ]; then
        error "仍未检测到远程配置"
        exit 1
    fi
fi

info "检测到以下远程配置："
echo "$REMOTES" | while read -r remote; do
    echo -e "    ${CYAN}→${NC} ${remote}"
done

# ============================================
#  第三步：交互式收集参数
# ============================================
step "第三步：配置备份参数"

# --- 项目名称 ---
echo ""
echo -e "  ${BOLD}项目名称${NC} 用于派生脚本名、日志名、锁文件等"
echo -e "  例：pve-backup、web-server、db-dump、nas-sync"
echo ""
read -r -p "  请输入项目名称: " INPUT_PROJECT_NAME

if [[ ! "$INPUT_PROJECT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "项目名称只能包含字母、数字、下划线和连字符"
    exit 1
fi

# --- 远程名称 ---
echo ""
echo -e "  ${BOLD}可用的远程名称：${NC}"
echo "$REMOTES" | while read -r remote; do
    echo -e "    ${CYAN}•${NC} ${remote}"
done
echo ""
read -r -p "  请输入 rclone 远程名称（如 OD:）: " INPUT_REMOTE
if [[ ! "$INPUT_REMOTE" == *: ]]; then
    INPUT_REMOTE="${INPUT_REMOTE}:"
fi

# --- 远程备份目录 ---
read -r -p "  请输入远程子目录（如 backups/${INPUT_PROJECT_NAME}）: " INPUT_REMOTE_DIR
INPUT_REMOTE_DIR=$(echo "$INPUT_REMOTE_DIR" | sed 's|^/||;s|/$||')
if [ -z "$INPUT_REMOTE_DIR" ]; then
    INPUT_REMOTE_DIR="${INPUT_PROJECT_NAME}"
fi

REMOTE_FULL="${INPUT_REMOTE}${INPUT_REMOTE_DIR}"
info "远程完整路径: ${REMOTE_FULL}"

# --- 备份文件/文件夹 ---
echo ""
echo -e "  ${BOLD}请输入需要备份的文件或文件夹路径：${NC}"
echo -e "  （支持通配符，如 ${CYAN}/root/*.sh${NC} 匹配所有 .sh 文件）"
echo -e "  （每行输入一个，输入 ${YELLOW}done${NC} 结束）"
echo ""

BACKUP_FOLDERS_INPUT=()
while true; do
    read -r -p "  路径: " folder_path
    if [[ "$folder_path" == "done" || -z "$folder_path" ]]; then
        if [ ${#BACKUP_FOLDERS_INPUT[@]} -eq 0 ]; then
            warn "至少需要一个文件或文件夹"
            continue
        fi
        break
    fi
    folder_path="${folder_path%/}"
    # 不检查通配符路径是否存在
    if [[ "$folder_path" == *"*"* ]] || [ -e "$folder_path" ]; then
        BACKUP_FOLDERS_INPUT+=("$folder_path")
        if [[ "$folder_path" == *"*"* ]]; then
            info "已添加（通配符）: ${folder_path}"
        else
            info "已添加: ${folder_path}"
        fi
    else
        warn "路径不存在: ${folder_path}，强制添加？(y/n)"
        read -r -p "  " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            BACKUP_FOLDERS_INPUT+=("$folder_path")
            info "已添加（路径不存在）: ${folder_path}"
        fi
    fi
done

# --- 脚本与日志路径 ---
echo ""
DEFAULT_SCRIPT_DIR="/opt/remote-backup"
DEFAULT_LOG_DIR="/var/log/remote-backup"

read -r -p "  脚本安装目录 [${DEFAULT_SCRIPT_DIR}]: " INPUT_SCRIPT_DIR
INPUT_SCRIPT_DIR="${INPUT_SCRIPT_DIR:-$DEFAULT_SCRIPT_DIR}"

read -r -p "  日志目录 [${DEFAULT_LOG_DIR}]: " INPUT_LOG_DIR
INPUT_LOG_DIR="${INPUT_LOG_DIR:-$DEFAULT_LOG_DIR}"

SCRIPT_PATH="${INPUT_SCRIPT_DIR}/${INPUT_PROJECT_NAME}.sh"

# --- 定时任务 ---
echo ""
echo -e "  ${BOLD}常用 Cron 表达式：${NC}"
echo -e "    ${CYAN}0 3 * * *${NC}       每天凌晨 3:00"
echo -e "    ${CYAN}0 */6 * * *${NC}     每隔 6 小时"
echo -e "    ${CYAN}0 2 * * 0${NC}       每周日凌晨 2:00"
echo -e "    ${CYAN}0 1 1 * *${NC}       每月 1 日凌晨 1:00"
echo ""
read -r -p "  Cron 定时表达式 [0 3 * * *]: " INPUT_CRON
INPUT_CRON="${INPUT_CRON:-0 3 * * *}"

# --- 保留策略 ---
echo ""
echo -e "  ${BOLD}保留策略：${NC}"
echo -e "    ${CYAN}1)${NC} 按数量保留（保留最近 N 份备份文件）"
echo -e "    ${CYAN}2)${NC} 按天数保留（删除超过 N 天的备份文件）"
echo ""
read -r -p "  请选择 (1/2) [1]: " INPUT_RETENTION_CHOICE
INPUT_RETENTION_CHOICE="${INPUT_RETENTION_CHOICE:-1}"

if [ "$INPUT_RETENTION_CHOICE" = "2" ]; then
    INPUT_RETENTION_TYPE="days"
    read -r -p "  保留天数 [30]: " INPUT_RETENTION_DAYS
    INPUT_RETENTION_DAYS="${INPUT_RETENTION_DAYS:-30}"
    INPUT_RETENTION_COUNT=3
    RETENTION_DISPLAY="按天数保留 ${INPUT_RETENTION_DAYS} 天"
else
    INPUT_RETENTION_TYPE="count"
    read -r -p "  保留最近几份 [3]: " INPUT_RETENTION_COUNT
    INPUT_RETENTION_COUNT="${INPUT_RETENTION_COUNT:-3}"
    INPUT_RETENTION_DAYS=30
    RETENTION_DISPLAY="按数量保留 ${INPUT_RETENTION_COUNT} 份"
fi

# --- 压缩级别 ---
read -r -p "  压缩级别 1-9（越大越慢越小）[6]: " INPUT_COMPRESSION
INPUT_COMPRESSION="${INPUT_COMPRESSION:-6}"

# --- 锁机制 ---
read -r -p "  启用文件锁防重复运行？(y/n) [y]: " INPUT_LOCK
INPUT_LOCK="${INPUT_LOCK:-y}"

# --- 带宽限制 ---
echo ""
echo -e "  ${BOLD}带宽限制：${NC}"
echo -e "    留空表示不限速"
echo -e "    示例：${CYAN}1M${NC} 表示 1MB/s，${CYAN}500K${NC} 表示 500KB/s"
echo ""
read -r -p "  上传带宽限制（留空不限速）: " INPUT_BWLIMIT
INPUT_BWLIMIT="${INPUT_BWLIMIT:-}"

# --- 日志保留天数 ---
read -r -p "  日志保留天数 [30]: " INPUT_LOG_RETENTION_DAYS
INPUT_LOG_RETENTION_DAYS="${INPUT_LOG_RETENTION_DAYS:-30}"

# --- 通知 ---
echo ""
read -r -p "  备份失败时发送 webhook 通知？（留空跳过）: " INPUT_WEBHOOK_URL
INPUT_WEBHOOK_URL="${INPUT_WEBHOOK_URL:-}"

# ============================================
#  第四步：生成备份脚本
# ============================================
step "第四步：生成备份脚本"

mkdir -p "$INPUT_SCRIPT_DIR" "$INPUT_LOG_DIR"

# 构建 BACKUP_ITEMS 数组内容
FOLDERS_ARRAY=""
for folder in "${BACKUP_FOLDERS_INPUT[@]}"; do
    # 转义双引号和反斜杠
    escaped_folder="${folder//\\/\\\\}"
    escaped_folder="${escaped_folder//\"/\\\"}"
    FOLDERS_ARRAY+="    \"${escaped_folder}\"
"
done

cat > "$SCRIPT_PATH" << 'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

# ============================================
#  PROJECT_NAME_PLACEHOLDER 远程备份脚本
#
#  ★ 后期修改说明：
#    修改下方【可编辑配置区】即可，无需重新运行 setup 脚本。
#    修改后直接保存，定时任务自动生效。
# ============================================

# PATH for cron environment
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ========== 可编辑配置区 ==========

STATUS_PROJECT="PROJECT_NAME_PLACEHOLDER"

# rclone 远程路径（远程名称:子目录）
REMOTE_FULL="REMOTE_FULL_PLACEHOLDER"

# 需要备份的文件或文件夹（支持通配符，如 "/root/*.sh"）
# 通配符会自动展开，匹配到的每个文件单独备份
BACKUP_ITEMS=(
BACKUP_ITEMS_PLACEHOLDER)

# 保留策略："count" 按数量保留 / "days" 按天数保留
RETENTION_TYPE="RETENTION_TYPE_PLACEHOLDER"

# 按数量保留时生效：保留最近几份
RETENTION_COUNT=RETENTION_COUNT_PLACEHOLDER

# 按天数保留时生效：保留多少天
RETENTION_DAYS=RETENTION_DAYS_PLACEHOLDER

# 压缩级别 1-9（越大压缩率越高但越慢，3~6 为推荐范围）
COMPRESSION_LEVEL=COMPRESSION_LEVEL_PLACEHOLDER

# 文件锁防重复运行（true/false）
ENABLE_LOCK=ENABLE_LOCK_PLACEHOLDER

# webhook 通知地址（留空不通知）
WEBHOOK_URL="WEBHOOK_URL_PLACEHOLDER"

# rclone 带宽限制（留空不限速，如 1M、500K）
BWLIMIT="BWLIMIT_PLACEHOLDER"

# 日志保留天数
LOG_RETENTION_DAYS=LOG_RETENTION_DAYS_PLACEHOLDER

# ========== 以下为系统变量，一般无需修改 ==========

TIMESTAMP=$(date +%Y%m%d%H%M%S)
HOSTNAME=$(hostname -s)
BACKUP_PATH_PREFIX=$(mktemp -d "/tmp/${STATUS_PROJECT}-XXXXXXXX")
LOG_DIR="LOG_DIR_PLACEHOLDER"
LOG_FILE="${LOG_DIR}/${STATUS_PROJECT}-$(date +%Y%m%d).log"
LOCK_FILE="/var/run/${STATUS_PROJECT}.lock"

set -o errtrace

mkdir -p "${LOG_DIR}"

# ---------- 工具函数 ----------

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${msg}" | tee -a "${LOG_FILE}"
}

acquire_lock() {
    if [ "${ENABLE_LOCK}" = "true" ]; then
        if [ -f "${LOCK_FILE}" ]; then
            local lock_pid
            lock_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
            if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
                log "错误：另一个备份进程正在运行 (PID: ${lock_pid})"
                exit 1
            else
                log "残留锁文件，进程已不存在，重新获取"
                rm -f "${LOCK_FILE}"
            fi
        fi
        echo $$ > "${LOCK_FILE}"
    fi
}

release_lock() {
    if [ "${ENABLE_LOCK}" = "true" ]; then
        rm -f "${LOCK_FILE}"
    fi
}

cleanup() {
    if [ -d "${BACKUP_PATH_PREFIX}" ]; then
        rm -rf "${BACKUP_PATH_PREFIX}"
    fi
}

cleanup_old_logs() {
    if [ -d "${LOG_DIR}" ]; then
        find "${LOG_DIR}" -name "*.log" -type f -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true
        log "已清理 ${LOG_RETENTION_DAYS} 天前的旧日志"
    fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

send_notification() {
    if [ -z "${WEBHOOK_URL}" ]; then
        return 0
    fi
    local title content payload
    title=$(json_escape "$1")
    content=$(json_escape "$2")
    payload="{\"title\":\"${title}\",\"content\":\"${content}\"}"
    curl -s -o /dev/null \
        -H "Content-Type: application/json" \
        -X POST \
        -d "${payload}" \
        --max-time 10 \
        "${WEBHOOK_URL}" 2>/dev/null || true
}

on_error() {
    local line_no="${1:-unknown}"
    log "错误发生在第 ${line_no} 行"
    cleanup
    release_lock
    send_notification "[失败] ${STATUS_PROJECT}" "主机 ${HOSTNAME} 备份异常(行${line_no})，请检查日志 ${LOG_FILE}"
    exit 1
}

trap 'on_error ${LINENO}' ERR
trap 'log "收到中断信号"; cleanup; release_lock; exit 130' INT TERM

# ---------- 单个条目备份（支持通配符展开）----------

backup_one() {
    local src="$1"
    local name archive dest size

    # 安全展开通配符（支持含空格的文件名）
    local items=()
    if [[ "$src" == *"*"* || "$src" == *"?"* || "$src" == *"["* ]]; then
        # 是通配符模式，安全展开
        while IFS= read -r -d '' item; do
            items+=("$item")
        done < <(eval "printf '%s\0' $src" 2>/dev/null || true)
        if [ ${#items[@]} -eq 0 ]; then
            log "  ⚠ 未匹配到: ${src}"
            return 1
        fi
    else
        # 普通路径
        if [ ! -e "$src" ]; then
            log "  ⚠ 路径不存在: ${src}"
            return 1
        fi
        items=("$src")
    fi

    for item in "${items[@]}"; do
        if [ ! -e "${item}" ]; then
            log "  ⚠ 未匹配到: ${src}"
            return 1
        fi

        name=$(basename "${item}")
        archive="${BACKUP_PATH_PREFIX}/${name}_${TIMESTAMP}.tar.gz"
        dest="${REMOTE_FULL}/${name}/"

        log "━━━ ${name} ━━━"

        # 压缩
        log "  → 压缩中..."
        GZIP="-${COMPRESSION_LEVEL}" tar -czf "${archive}" \
            -C "$(dirname "${item}")" "${name}" 2>>"${LOG_FILE}"
        size=$(du -h "${archive}" | cut -f1)
        log "  ✓ 压缩完成 (${size})"

        # 上传
        local rclone_opts=(-P --log-file="${LOG_FILE}" --log-level INFO)
        if [ -n "${BWLIMIT}" ]; then
            rclone_opts+=(--bwlimit "${BWLIMIT}")
            log "  → 带宽限制: ${BWLIMIT}"
        fi
        log "  → 上传到 ${dest} ..."
        rclone copy "${archive}" "${dest}" "${rclone_opts[@]}"
        log "  ✓ 上传完成"

        # 完整性校验
        log "  → 校验中..."
        local remote_size
        remote_size=$(rclone size "${dest}" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | head -1 | cut -d: -f2 || echo "0")
        local local_size
        local_size=$(stat -c%s "${archive}" 2>/dev/null || echo "0")
        if [ "${remote_size}" -gt 0 ] && [ "${local_size}" -gt 0 ]; then
            log "  ✓ 校验通过 (本地: $(numfmt --to=iec ${local_size} 2>/dev/null || echo "${local_size}B"), 远程: $(numfmt --to=iec ${remote_size} 2>/dev/null || echo "${remote_size}B"))"
        else
            log "  ⚠ 校验跳过（无法获取大小）"
        fi

        # 删除本地临时文件
        rm -f "${archive}"
        log "  ✓ 完成"
    done
}

# ---------- 按数量清理 ----------

clean_old_by_count() {
    local remote_dir="$1"
    local files="" file_count=0 to_delete=""

    files=$(rclone lsf "${remote_dir}" --files-only 2>/dev/null | sort -V || true)

    if [ -z "${files}" ]; then
        log "  ${remote_dir}: 无备份文件"
        return 0
    fi

    file_count=$(echo "${files}" | wc -l)

    if [ "${file_count}" -le "${RETENTION_COUNT}" ]; then
        log "  ${remote_dir}: ${file_count} 份，无需清理"
        return 0
    fi

    to_delete=$(echo "${files}" | head -n $((${file_count} - ${RETENTION_COUNT})))

    while IFS= read -r file; do
        if [ -n "${file}" ]; then
            log "  删除: ${remote_dir}${file}"
            rclone delete "${remote_dir}${file}" 2>/dev/null || true
        fi
    done <<< "${to_delete}"
}

# ---------- 按天数清理 ----------

clean_old_by_days() {
    log "━━━ 清理过期备份（保留 ${RETENTION_DAYS} 天）━━━"
    rclone delete "${REMOTE_FULL}" \
        --min-age "${RETENTION_DAYS}d" \
        -P --log-file="${LOG_FILE}" --log-level INFO 2>/dev/null || \
        log "  ⚠ 清理出错（不影响本次备份）"
}

# ---------- 清理调度 ----------

clean_old() {
    if [ "${RETENTION_TYPE}" = "count" ]; then
        log "━━━ 清理旧备份（保留最近 ${RETENTION_COUNT} 份）━━━"
        for item_entry in "${BACKUP_ITEMS[@]}"; do
            local resolved_items=()
            if [[ "$item_entry" == *"*"* || "$item_entry" == *"?"* || "$item_entry" == *"["* ]]; then
                while IFS= read -r -d '' resolved; do
                    resolved_items+=("$resolved")
                done < <(eval "printf '%s\0' $item_entry" 2>/dev/null || true)
            else
                resolved_items=("$item_entry")
            fi
            for item in "${resolved_items[@]}"; do
                if [ -e "${item}" ]; then
                    local item_name
                    item_name=$(basename "${item}")
                    clean_old_by_count "${REMOTE_FULL}/${item_name}/"
                fi
            done
        done
    else
        clean_old_by_days
    fi
}

# ---------- 主流程 ----------

log "========================================"
log "  STATUS_PROJECT_DISPLAY 备份开始"
log "  主机: ${HOSTNAME}"
log "  目标: ${REMOTE_FULL}"
log "  条目: ${#BACKUP_ITEMS[@]} 个"
log "  保留: RETENTION_DISPLAY_PLACEHOLDER"
log "========================================"

acquire_lock

total=${#BACKUP_ITEMS[@]}
success=0
failed=0
failed_list=""

for folder in "${BACKUP_ITEMS[@]}"; do
    if backup_one "${folder}"; then
        ((success++))
    else
        ((failed++)) || true
        failed_list+="    - ${folder}\n"
    fi
done

clean_old
cleanup
cleanup_old_logs

log "========================================"
log "  汇总: 总计 ${total} | 成功 ${success} | 失败 ${failed}"
[ "${failed}" -gt 0 ] && echo -e "${failed_list}" | tee -a "${LOG_FILE}"
log "========================================"

release_lock

if [ "${failed}" -gt 0 ]; then
    send_notification "[失败] STATUS_PROJECT_DISPLAY" "主机 ${HOSTNAME}: ${failed}/${total} 个条目备份失败"
    exit 1
fi

send_notification "[成功] STATUS_PROJECT_DISPLAY" "主机 ${HOSTNAME}: 全部 ${total} 个条目备份成功"
SCRIPT_EOF

# ---------- 替换占位符 ----------

# 转义 sed 分隔符用到的特殊字符
escape_for_sed() {
    local s="$1" delim="${2:-/}"
    s="${s//\\/\\\\}"
    s="${s//${delim}/\\${delim}}"
    s="${s//&/\\&}"
    echo "$s"
}

# 统一用 § 作为 sed 分隔符（路径和 URL 中不会出现）
sed -i "s§PROJECT_NAME_PLACEHOLDER§$(escape_for_sed "${INPUT_PROJECT_NAME}" '§')§g" "$SCRIPT_PATH"
sed -i "s§REMOTE_FULL_PLACEHOLDER§$(escape_for_sed "${REMOTE_FULL}" '§')§g" "$SCRIPT_PATH"
sed -i "s§RETENTION_TYPE_PLACEHOLDER§$(escape_for_sed "${INPUT_RETENTION_TYPE}" '§')§g" "$SCRIPT_PATH"
sed -i "s§RETENTION_COUNT_PLACEHOLDER§${INPUT_RETENTION_COUNT}§g" "$SCRIPT_PATH"
sed -i "s§RETENTION_DAYS_PLACEHOLDER§${INPUT_RETENTION_DAYS}§g" "$SCRIPT_PATH"
sed -i "s§COMPRESSION_LEVEL_PLACEHOLDER§${INPUT_COMPRESSION}§g" "$SCRIPT_PATH"
sed -i "s§ENABLE_LOCK_PLACEHOLDER§${INPUT_LOCK}§g" "$SCRIPT_PATH"
sed -i "s§WEBHOOK_URL_PLACEHOLDER§$(escape_for_sed "${INPUT_WEBHOOK_URL}" '§')§g" "$SCRIPT_PATH"
sed -i "s§BWLIMIT_PLACEHOLDER§$(escape_for_sed "${INPUT_BWLIMIT}" '§')§g" "$SCRIPT_PATH"
sed -i "s§LOG_RETENTION_DAYS_PLACEHOLDER§${INPUT_LOG_RETENTION_DAYS}§g" "$SCRIPT_PATH"
sed -i "s§LOG_DIR_PLACEHOLDER§$(escape_for_sed "${INPUT_LOG_DIR}" '§')§g" "$SCRIPT_PATH"
sed -i "s§RETENTION_DISPLAY_PLACEHOLDER§$(escape_for_sed "${RETENTION_DISPLAY}" '§')§g" "$SCRIPT_PATH"
sed -i "s§STATUS_PROJECT_DISPLAY§$(escape_for_sed "${INPUT_PROJECT_NAME}" '§')§g" "$SCRIPT_PATH"

# 替换 BACKUP_ITEMS 数组
python3 -c "
import sys
items = sys.argv[1:]
lines = []
for item in items:
    escaped = item.replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"')
    lines.append(f'    \"{escaped}\"')
result = '\n'.join(lines)
print(result)
" "${BACKUP_FOLDERS_INPUT[@]}" > /tmp/_backup_items.txt 2>/dev/null || {
    # fallback: 用 bash 处理
    > /tmp/_backup_items.txt
    for folder in "${BACKUP_FOLDERS_INPUT[@]}"; do
        escaped="${folder//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        echo "    \"${escaped}\"" >> /tmp/_backup_items.txt
    done
}

# 用 awk 替换 BACKUP_ITEMS 占位符
awk -v content="$(cat /tmp/_backup_items.txt)" '
/^BACKUP_ITEMS_PLACEHOLDER$/ { print content; next }
{ print }
' "$SCRIPT_PATH" > "$SCRIPT_PATH.tmp" && mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"

rm -f /tmp/_backup_items.txt

chmod +x "$SCRIPT_PATH"
info "备份脚本已生成: ${SCRIPT_PATH}"

# ============================================
#  第五步：配置定时任务
# ============================================
step "第五步：配置定时任务"

CRON_COMMENT="# ${INPUT_PROJECT_NAME} backup"
CRON_ENTRY="${INPUT_CRON} ${SCRIPT_PATH} >> ${INPUT_LOG_DIR}/cron.log 2>&1"

EXISTING_CRON=$(crontab -l 2>/dev/null || true)

if echo "$EXISTING_CRON" | grep -qF "${SCRIPT_PATH}"; then
    warn "检测到旧的定时任务，将替换..."
    EXISTING_CRON=$(echo "$EXISTING_CRON" | grep -vF "${SCRIPT_PATH}" | grep -vF "# ${INPUT_PROJECT_NAME} backup")
fi

# 构建新 crontab，避免多余空行
NEW_CRON=""
if [ -n "$EXISTING_CRON" ]; then
    NEW_CRON="${EXISTING_CRON}
"
fi
NEW_CRON+="${CRON_COMMENT}
${CRON_ENTRY}"

echo "$NEW_CRON" | crontab - 2>/dev/null && {
    info "定时任务配置成功"
} || {
    warn "自动写入 crontab 失败，请手动添加："
    echo -e "  ${CYAN}${CRON_ENTRY}${NC}"
}

# ============================================
#  第六步：输出摘要
# ============================================
step "安装完成"

echo ""
echo -e "  ${BOLD}项目:${NC}  ${INPUT_PROJECT_NAME}"
echo -e "  ┌──────────────────────────────────────────────────────┐"
echo -e "  │  脚本    :  ${CYAN}${SCRIPT_PATH}${NC}"
echo -e "  │  远程    :  ${CYAN}${REMOTE_FULL}${NC}"
echo -e "  │  备份项  :  ${CYAN}${#BACKUP_FOLDERS_INPUT[@]} 个${NC}"
for f in "${BACKUP_FOLDERS_INPUT[@]}"; do
echo -e "  │     - ${CYAN}${f}${NC}"
done
echo -e "  │  定时    :  ${CYAN}${INPUT_CRON}${NC}"
echo -e "  │  保留    :  ${CYAN}${RETENTION_DISPLAY}${NC}"
echo -e "  │  日志    :  ${CYAN}${INPUT_LOG_DIR}/${NC}"
[ -n "$INPUT_BWLIMIT" ] && echo -e "  │  带宽    :  ${CYAN}${INPUT_BWLIMIT}${NC}"
echo -e "  └──────────────────────────────────────────────────────┘"
echo ""
echo -e "  ${BOLD}常用命令：${NC}"
echo -e "    手动执行  :  ${CYAN}${SCRIPT_PATH}${NC}"
echo -e "    编辑配置  :  ${CYAN}vim ${SCRIPT_PATH}${NC}"
echo -e "    查看定时  :  ${CYAN}crontab -l${NC}"
echo -e "    查看日志  :  ${CYAN}tail -f ${INPUT_LOG_DIR}/${INPUT_PROJECT_NAME}-$(date +%Y%m%d).log${NC}"
echo -e "    删除定时  :  ${CYAN}crontab -e  (删除对应行)${NC}"
echo ""
echo -e "  ${YELLOW}后期修改：直接编辑脚本顶部配置区即可${NC}"
echo ""
