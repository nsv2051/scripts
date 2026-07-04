#!/bin/bash
set -euo pipefail

# ============================================
#  Linux 通用远程备份 - 安装配置脚本 v2
#  功能：检测/安装 rclone，交互式生成备份脚本并配置定时任务
#  特性：支持通配符、单文件备份、按数量/天数保留策略
#        前置/后置钩子、输入校验、恢复脚本、孤儿目录清理
#        网络重试、多远程备份、排除规则、卸载功能
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

                        Universal Remote Backup  v2
EOF

# ============================================
#  第零步：判断模式（安装 / 卸载）
# ============================================
DEFAULT_SCRIPT_DIR="/opt/remote-backup"
DEFAULT_LOG_DIR="/var/log/remote-backup"

if [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]]; then
    step "卸载模式"
    echo ""
    echo -e "  已安装的备份脚本："
    idx=0
    scripts=()
    if [ -d "$DEFAULT_SCRIPT_DIR" ]; then
        while IFS= read -r f; do
            scripts+=("$f")
            idx=$((idx + 1))
            echo -e "    ${CYAN}${idx})${NC} $(basename "$f" .sh)"
        done < <(find "$DEFAULT_SCRIPT_DIR" -name "*.sh" -not -name "restore-*" -type f 2>/dev/null | sort)
    fi
    if [ $idx -eq 0 ]; then
        warn "未找到已安装的备份脚本"
        exit 0
    fi
    echo -e "    ${CYAN}a)${NC} 全部卸载"
    echo ""
    read -r -p "  选择要卸载的编号（或 a 全部）: " choice
    to_remove=()
    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        to_remove=("${scripts[@]}")
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#scripts[@]} ]; then
        to_remove=("${scripts[$((choice-1))]}")
    else
        error "无效选择"
        exit 1
    fi

    for script in "${to_remove[@]}"; do
        name=$(basename "$script" .sh)
        # 删除脚本
        rm -f "$script"
        info "已删除: ${script}"
        # 删除恢复脚本
        restore="${DEFAULT_SCRIPT_DIR}/restore-${name}.sh"
        [ -f "$restore" ] && rm -f "$restore" && info "已删除: ${restore}"
        # 删除 crontab 条目
        existing_cron=$(crontab -l 2>/dev/null || true)
        if echo "$existing_cron" | grep -qF "$script"; then
            echo "$existing_cron" | grep -vF "$script" | grep -vF "# ${name} backup" | crontab -
            info "已删除定时任务"
        fi
        # 删除日志
        [ -d "$DEFAULT_LOG_DIR" ] && rm -f "${DEFAULT_LOG_DIR}/${name}"-*.log 2>/dev/null
        # 删除锁文件
        rm -f "/var/run/${name}.lock" 2>/dev/null
        # 删除清单文件
        rm -f "/var/run/${name}.manifest" 2>/dev/null
    done
    echo ""
    info "卸载完成"
    exit 0
fi

# ============================================
#  第一步：检测并安装 rclone
# ============================================
step "第一步：检测 rclone"

# 安装最新版 rclone（二进制方式，版本高于 apt/yum 源）
install_rclone() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armhf)  arch="arm" ;;
        *) error "不支持的架构: $arch"; exit 1 ;;
    esac

    local url="https://downloads.rclone.org/rclone-current-linux-${arch}.zip"
    info "下载 rclone ($arch)..."
    if ! wget -q --show-progress "$url" -O /tmp/rclone-install.zip 2>/dev/null; then
        warn "下载失败，尝试包管理器安装..."
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y rclone
        elif command -v yum &> /dev/null; then
            yum install -y epel-release && yum install -y rclone
        elif command -v dnf &> /dev/null; then
            dnf install -y epel-release && dnf install -y rclone
        else
            error "安装失败，请手动安装: https://rclone.org/downloads/"
            exit 1
        fi
        return
    fi

    unzip -o /tmp/rclone-install.zip -d /tmp/rclone-install > /dev/null
    cp /tmp/rclone-install/rclone-*/rclone /usr/bin/rclone
    chmod +x /usr/bin/rclone
    rm -rf /tmp/rclone-install /tmp/rclone-install.zip
}

if command -v rclone &> /dev/null; then
    _rclone_ver=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
    _rclone_num=${_rclone_ver#v}
    _rclone_major=${_rclone_num%%.*}
    _rclone_rest=${_rclone_num#*.}
    _rclone_minor=${_rclone_rest%%.*}
    # 检查版本是否低于 v1.55（不支持 config reconnect）
    if [ "${_rclone_major}" -lt 1 ] 2>/dev/null || \
       { [ "${_rclone_major}" -eq 1 ] && [ "${_rclone_minor}" -lt 55 ]; } 2>/dev/null; then
        warn "rclone 版本 ${_rclone_ver} 过旧，升级到最新版..."
        install_rclone
        info "rclone 已升级: $(rclone version | head -1)"
    else
        info "rclone 已安装: $(rclone version | head -1)"
    fi
else
    warn "未检测到 rclone，安装最新版..."
    install_rclone
    if command -v rclone &> /dev/null; then
        info "rclone 安装成功: $(rclone version | head -1)"
    else
        error "安装失败，请手动安装: https://rclone.org/downloads/"
        exit 1
    fi
fi

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

# ---------- 校验函数 ----------
validate_cron() {
    local expr="$1"
    local fields
    fields=$(echo "$expr" | awk '{print NF}')
    [ "$fields" -eq 5 ] || return 1
    # 简单校验每个字段的字符合法性
    echo "$expr" | grep -qE '^[0-9*/, -]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+$' || return 1
    return 0
}

validate_number() {
    local val="$1" min="$2" max="$3" label="$4"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        error "${label} 必须是数字"
        return 1
    fi
    if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ]; then
        error "${label} 必须在 ${min}-${max} 之间"
        return 1
    fi
    return 0
}

# ---------- 读取已有配置 ----------
load_existing_config() {
    local script="$1"
    [ -f "$script" ] || return 1

    _get_val() {
        local var="$1"
        grep -E "^${var}=" "$script" 2>/dev/null \
            | tail -1 \
            | sed "s/^${var}=//; s/^\"//; s/\"$//; s/^'//; s/'$//" \
            || true
    }

    _get_array() {
        local name="$1"
        # 提取数组内容：找到 NAME=( 到最近的 ) 之间的引号字符串
        # 兼容旧版和新版脚本格式
        python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    c = f.read()
# 找到数组定义：NAME=( ... )
m = re.search(r'(?m)^\s*' + re.escape(sys.argv[2]) + r'=\(([^)]*)\)', c)
if m:
    items = re.findall(r'\"([^\"]*)\"', m.group(1))
    for item in items:
        print(item)
" "$script" "$name" 2>/dev/null || true
    }

    _get_items()   { _get_array "BACKUP_ITEMS"; }
    _get_excludes(){ _get_array "EXCLUDE_PATTERNS"; }
    _get_remotes() { _get_array "REMOTE_LIST"; }

    EXISTING_RETENTION_TYPE=$(_get_val "RETENTION_TYPE")
    EXISTING_RETENTION_COUNT=$(_get_val "RETENTION_COUNT")
    EXISTING_RETENTION_DAYS=$(_get_val "RETENTION_DAYS")
    EXISTING_COMPRESSION=$(_get_val "COMPRESSION_LEVEL")
    EXISTING_ENABLE_LOCK=$(_get_val "ENABLE_LOCK")
    EXISTING_WEBHOOK_URL=$(_get_val "WEBHOOK_URL")
    EXISTING_BWLIMIT=$(_get_val "BWLIMIT")
    EXISTING_LOG_RETENTION=$(_get_val "LOG_RETENTION_DAYS")
    EXISTING_LOG_DIR=$(_get_val "LOG_DIR")
    EXISTING_PRE_CMD=$(_get_val "PRE_BACKUP_CMD")
    EXISTING_POST_CMD=$(_get_val "POST_BACKUP_CMD")
    EXISTING_RETRY_COUNT=$(_get_val "RETRY_COUNT")

    # REMOTE_LIST 数组（多远程）
    EXISTING_REMOTES=()
    while IFS= read -r r; do
        [ -n "$r" ] && EXISTING_REMOTES+=("$r")
    done < <(_get_remotes)
    # 兼容旧版 REMOTE_FULL 单远程
    if [ ${#EXISTING_REMOTES[@]} -eq 0 ]; then
        local rf
        rf=$(_get_val "REMOTE_FULL")
        [ -n "$rf" ] && EXISTING_REMOTES+=("$rf")
    fi

    EXISTING_ITEMS=()
    while IFS= read -r item; do
        [ -n "$item" ] && EXISTING_ITEMS+=("$item")
    done < <(_get_items)

    EXISTING_EXCLUDES=()
    while IFS= read -r ex; do
        [ -n "$ex" ] && EXISTING_EXCLUDES+=("$ex")
    done < <(_get_excludes)

    # 从 crontab 读取已有 cron 表达式
    EXISTING_CRON_EXPR=""
    local cron_line
    cron_line=$(crontab -l 2>/dev/null | grep -F "$script" | head -1 || true)
    if [ -n "$cron_line" ]; then
        EXISTING_CRON_EXPR=$(echo "$cron_line" | awk '{print $1" "$2" "$3" "$4" "$5}')
    fi

    return 0
}

# ---------- 主交互流程 ----------

step "第三步：配置备份参数"

echo ""
echo -e "  ${BOLD}项目名称${NC} 用于派生脚本名、日志名、锁文件等"
echo -e "  例：pve-backup、web-server、db-dump、nas-sync"
echo ""
read -r -p "  请输入项目名称: " INPUT_PROJECT_NAME

if [[ ! "$INPUT_PROJECT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "项目名称只能包含字母、数字、下划线和连字符"
    exit 1
fi

HAS_EXISTING_CONFIG=false
PRE_CHECK_SCRIPT="${DEFAULT_SCRIPT_DIR}/${INPUT_PROJECT_NAME}.sh"
if [ -f "$PRE_CHECK_SCRIPT" ]; then
    warn "检测到已有配置: ${PRE_CHECK_SCRIPT}"
    echo -e "  ${BOLD}是否读取已有配置作为默认值？(Y/n)${NC}"
    read -r -p "  " USE_EXISTING
    if [[ "$USE_EXISTING" != "n" && "$USE_EXISTING" != "N" ]]; then
        if load_existing_config "$PRE_CHECK_SCRIPT"; then
            HAS_EXISTING_CONFIG=true
            info "已读取配置，回车保留原值，输入新值可覆盖"
        else
            warn "读取失败，将重新配置"
        fi
    fi
fi

# --- 远程名称（支持多远程）---
echo ""
echo -e "  ${BOLD}可用的远程名称：${NC}"
echo "$REMOTES" | while read -r remote; do
    echo -e "    ${CYAN}•${NC} ${remote}"
done

INPUT_REMOTES=()
if [ "$HAS_EXISTING_CONFIG" = true ] && [ ${#EXISTING_REMOTES[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}当前配置的远程：${NC}"
    for _er in "${EXISTING_REMOTES[@]}"; do
        echo -e "    ${CYAN}•${NC} ${_er}"
    done
    echo -e "  ${BOLD}是否保留？(Y/n)${NC}"
    read -r -p "  " KEEP_REMOTES
    if [[ "$KEEP_REMOTES" != "n" && "$KEEP_REMOTES" != "N" ]]; then
        INPUT_REMOTES=("${EXISTING_REMOTES[@]}")
    fi
fi

if [ ${#INPUT_REMOTES[@]} -eq 0 ]; then
    echo ""
    echo -e "  ${BOLD}输入远程路径（格式: 远程名:子目录）${NC}"
    echo -e "  （每行一个，输入 ${YELLOW}done${NC} 结束，支持多远程异地备份）"
    echo ""
    while true; do
        read -r -p "  远程路径: " remote_entry
        if [[ "$remote_entry" == "done" || -z "$remote_entry" ]]; then
            [ ${#INPUT_REMOTES[@]} -gt 0 ] && break
            warn "至少需要一个远程路径"
            continue
        fi
        INPUT_REMOTES+=("$remote_entry")
        info "已添加: ${remote_entry}"
    done
fi

info "远程路径: ${INPUT_REMOTES[*]}"

# --- 备份文件/文件夹 ---
echo ""
echo -e "  ${BOLD}请输入需要备份的文件或文件夹路径：${NC}"
echo -e "  （支持通配符，如 ${CYAN}/root/*.sh${NC} 匹配所有 .sh 文件）"
echo -e "  （每行输入一个，输入 ${YELLOW}done${NC} 结束）"
echo ""

BACKUP_FOLDERS_INPUT=()

if [ "$HAS_EXISTING_CONFIG" = true ] && [ ${#EXISTING_ITEMS[@]} -gt 0 ]; then
    echo -e "  ${BOLD}已有备份项：${NC}"
    for _ei in "${EXISTING_ITEMS[@]}"; do
        echo -e "    ${CYAN}•${NC} ${_ei}"
    done
    echo ""
    echo -e "  ${BOLD}是否保留这些备份项？(Y/n)${NC}"
    read -r -p "  " KEEP_ITEMS
    if [[ "$KEEP_ITEMS" != "n" && "$KEEP_ITEMS" != "N" ]]; then
        BACKUP_FOLDERS_INPUT=("${EXISTING_ITEMS[@]}")
        info "已保留 ${#BACKUP_FOLDERS_INPUT[@]} 个备份项"
    fi
fi

if [ ${#BACKUP_FOLDERS_INPUT[@]} -eq 0 ]; then
    while true; do
        read -r -p "  路径: " folder_path
        if [[ "$folder_path" == "done" || -z "$folder_path" ]]; then
            [ ${#BACKUP_FOLDERS_INPUT[@]} -gt 0 ] && break
            warn "至少需要一个文件或文件夹"
            continue
        fi
        folder_path="${folder_path%/}"
        if [[ "$folder_path" == *"*"* ]] || [ -e "$folder_path" ]; then
            BACKUP_FOLDERS_INPUT+=("$folder_path")
            info "已添加: ${folder_path}"
        else
            warn "路径不存在: ${folder_path}，强制添加？(y/n)"
            read -r -p "  " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                BACKUP_FOLDERS_INPUT+=("$folder_path")
                info "已添加（路径不存在）: ${folder_path}"
            fi
        fi
    done
fi

# --- 排除规则 ---
echo ""
echo -e "  ${BOLD}排除规则（不需要的文件/目录）${NC}"
echo -e "  示例：${CYAN}node_modules${NC}、${CYAN}.git${NC}、${CYAN}*.tmp${NC}"
echo -e "  （每行一个，输入 ${YELLOW}done${NC} 结束，留空跳过）"
echo ""

EXCLUDE_INPUT=()

if [ "$HAS_EXISTING_CONFIG" = true ] && [ ${#EXISTING_EXCLUDES[@]} -gt 0 ]; then
    echo -e "  ${BOLD}已有排除规则：${NC}"
    for _ex in "${EXISTING_EXCLUDES[@]}"; do
        echo -e "    ${CYAN}•${NC} ${_ex}"
    done
    echo -e "  ${BOLD}是否保留？(Y/n)${NC}"
    read -r -p "  " KEEP_EXCLUDES
    if [[ "$KEEP_EXCLUDES" != "n" && "$KEEP_EXCLUDES" != "N" ]]; then
        EXCLUDE_INPUT=("${EXISTING_EXCLUDES[@]}")
        info "已保留 ${#EXCLUDE_INPUT[@]} 条排除规则"
    fi
fi

if [ ${#EXCLUDE_INPUT[@]} -eq 0 ]; then
    while true; do
        read -r -p "  排除: " exclude_entry
        if [[ "$exclude_entry" == "done" || -z "$exclude_entry" ]]; then
            break
        fi
        EXCLUDE_INPUT+=("$exclude_entry")
        info "已添加排除: ${exclude_entry}"
    done
fi

# --- 前置/后置钩子 ---
echo ""
echo -e "  ${BOLD}备份钩子（可选）${NC}"
echo -e "  前置命令在压缩前执行（如 ${CYAN}mysqldump ... > /tmp/db.sql${NC}）"
echo -e "  后置命令在上传完成后执行（如 ${CYAN}rm /tmp/db.sql${NC}）"
echo ""

DEFAULT_PRE_CMD="${EXISTING_PRE_CMD:-}"
DEFAULT_POST_CMD="${EXISTING_POST_CMD:-}"
PRE_HINT=""
POST_HINT=""
[ -n "$DEFAULT_PRE_CMD" ] && PRE_HINT=" [已配置]"
[ -n "$DEFAULT_POST_CMD" ] && POST_HINT=" [已配置]"

read -r -p "  前置命令（留空跳过）${PRE_HINT}: " INPUT_PRE_CMD
INPUT_PRE_CMD="${INPUT_PRE_CMD:-$DEFAULT_PRE_CMD}"

read -r -p "  后置命令（留空跳过）${POST_HINT}: " INPUT_POST_CMD
INPUT_POST_CMD="${INPUT_POST_CMD:-$DEFAULT_POST_CMD}"

# --- 脚本与日志路径 ---
echo ""
EXISTING_SCRIPT_DIR=""
[ "$HAS_EXISTING_CONFIG" = true ] && EXISTING_SCRIPT_DIR=$(dirname "$PRE_CHECK_SCRIPT")

read -r -p "  脚本安装目录 [${EXISTING_SCRIPT_DIR:-$DEFAULT_SCRIPT_DIR}]: " INPUT_SCRIPT_DIR
INPUT_SCRIPT_DIR="${INPUT_SCRIPT_DIR:-${EXISTING_SCRIPT_DIR:-$DEFAULT_SCRIPT_DIR}}"

EXISTING_LOG_DIR_VAL="${EXISTING_LOG_DIR:-$DEFAULT_LOG_DIR}"
read -r -p "  日志目录 [${EXISTING_LOG_DIR_VAL}]: " INPUT_LOG_DIR
INPUT_LOG_DIR="${INPUT_LOG_DIR:-$EXISTING_LOG_DIR_VAL}"

SCRIPT_PATH="${INPUT_SCRIPT_DIR}/${INPUT_PROJECT_NAME}.sh"
RESTORE_PATH="${INPUT_SCRIPT_DIR}/restore-${INPUT_PROJECT_NAME}.sh"

# --- 定时任务 ---
echo ""
echo -e "  ${BOLD}常用 Cron 表达式：${NC}"
echo -e "    ${CYAN}0 3 * * *${NC}       每天凌晨 3:00"
echo -e "    ${CYAN}0 */6 * * *${NC}     每隔 6 小时"
echo -e "    ${CYAN}0 2 * * 0${NC}       每周日凌晨 2:00"
echo -e "    ${CYAN}0 1 1 * *${NC}       每月 1 日凌晨 1:00"
echo ""

DEFAULT_CRON="${EXISTING_CRON_EXPR:-0 3 * * *}"
while true; do
    read -r -p "  Cron 定时表达式 [${DEFAULT_CRON}]: " INPUT_CRON
    INPUT_CRON="${INPUT_CRON:-$DEFAULT_CRON}"
    if validate_cron "$INPUT_CRON"; then
        break
    fi
    error "Cron 表达式格式错误，应为 5 个字段（分 时 日 月 周）"
done

# --- 保留策略 ---
echo ""
echo -e "  ${BOLD}保留策略：${NC}"
echo -e "    ${CYAN}1)${NC} 按数量保留（保留最近 N 份备份文件）"
echo -e "    ${CYAN}2)${NC} 按天数保留（删除超过 N 天的备份文件）"
echo ""

DEFAULT_RETENTION_CHOICE="1"
DEFAULT_RETENTION_COUNT="3"
DEFAULT_RETENTION_DAYS="30"
if [ "$HAS_EXISTING_CONFIG" = true ]; then
    [ "${EXISTING_RETENTION_TYPE:-}" = "days" ] && DEFAULT_RETENTION_CHOICE="2"
    DEFAULT_RETENTION_COUNT="${EXISTING_RETENTION_COUNT:-3}"
    DEFAULT_RETENTION_DAYS="${EXISTING_RETENTION_DAYS:-30}"
fi

read -r -p "  请选择 (1/2) [${DEFAULT_RETENTION_CHOICE}]: " INPUT_RETENTION_CHOICE
INPUT_RETENTION_CHOICE="${INPUT_RETENTION_CHOICE:-$DEFAULT_RETENTION_CHOICE}"

if [ "$INPUT_RETENTION_CHOICE" = "2" ]; then
    INPUT_RETENTION_TYPE="days"
    while true; do
        read -r -p "  保留天数 [${DEFAULT_RETENTION_DAYS}]: " INPUT_RETENTION_DAYS
        INPUT_RETENTION_DAYS="${INPUT_RETENTION_DAYS:-$DEFAULT_RETENTION_DAYS}"
        validate_number "$INPUT_RETENTION_DAYS" 1 3650 "保留天数" && break
    done
    INPUT_RETENTION_COUNT=3
    RETENTION_DISPLAY="按天数保留 ${INPUT_RETENTION_DAYS} 天"
else
    INPUT_RETENTION_TYPE="count"
    while true; do
        read -r -p "  保留最近几份 [${DEFAULT_RETENTION_COUNT}]: " INPUT_RETENTION_COUNT
        INPUT_RETENTION_COUNT="${INPUT_RETENTION_COUNT:-$DEFAULT_RETENTION_COUNT}"
        validate_number "$INPUT_RETENTION_COUNT" 1 999 "保留份数" && break
    done
    INPUT_RETENTION_DAYS=30
    RETENTION_DISPLAY="按数量保留 ${INPUT_RETENTION_COUNT} 份"
fi

# --- 压缩级别 ---
DEFAULT_COMPRESSION="${EXISTING_COMPRESSION:-6}"
while true; do
    read -r -p "  压缩级别 1-9（越大越慢越小）[${DEFAULT_COMPRESSION}]: " INPUT_COMPRESSION
    INPUT_COMPRESSION="${INPUT_COMPRESSION:-$DEFAULT_COMPRESSION}"
    validate_number "$INPUT_COMPRESSION" 1 9 "压缩级别" && break
done

# --- 锁机制 ---
DEFAULT_LOCK="y"
[ "$HAS_EXISTING_CONFIG" = true ] && [ "${EXISTING_ENABLE_LOCK:-}" = "false" ] && DEFAULT_LOCK="n"
read -r -p "  启用文件锁防重复运行？(y/n) [${DEFAULT_LOCK}]: " INPUT_LOCK
INPUT_LOCK="${INPUT_LOCK:-$DEFAULT_LOCK}"

# --- 网络重试 ---
DEFAULT_RETRY="${EXISTING_RETRY_COUNT:-3}"
while true; do
    read -r -p "  上传失败重试次数 [${DEFAULT_RETRY}]: " INPUT_RETRY_COUNT
    INPUT_RETRY_COUNT="${INPUT_RETRY_COUNT:-$DEFAULT_RETRY}"
    validate_number "$INPUT_RETRY_COUNT" 0 10 "重试次数" && break
done

# --- 带宽限制 ---
echo ""
DEFAULT_BWLIMIT="${EXISTING_BWLIMIT:-}"
BWLIMIT_HINT=""
[ -n "$DEFAULT_BWLIMIT" ] && BWLIMIT_HINT=" [${DEFAULT_BWLIMIT}]"
echo -e "  ${BOLD}带宽限制：${NC} 留空不限速，示例：${CYAN}1M${NC}、${CYAN}500K${NC}"
read -r -p "  上传带宽限制${BWLIMIT_HINT}: " INPUT_BWLIMIT
INPUT_BWLIMIT="${INPUT_BWLIMIT:-$DEFAULT_BWLIMIT}"

# --- 日志保留天数 ---
DEFAULT_LOG_RETENTION="${EXISTING_LOG_RETENTION:-30}"
while true; do
    read -r -p "  日志保留天数 [${DEFAULT_LOG_RETENTION}]: " INPUT_LOG_RETENTION_DAYS
    INPUT_LOG_RETENTION_DAYS="${INPUT_LOG_RETENTION_DAYS:-$DEFAULT_LOG_RETENTION}"
    validate_number "$INPUT_LOG_RETENTION_DAYS" 1 3650 "日志保留天数" && break
done

# --- 通知 ---
echo ""
DEFAULT_WEBHOOK="${EXISTING_WEBHOOK_URL:-}"
WEBHOOK_HINT=""
[ -n "$DEFAULT_WEBHOOK" ] && WEBHOOK_HINT=" [已配置]"
read -r -p "  备份失败时发送 webhook 通知？（留空跳过）${WEBHOOK_HINT}: " INPUT_WEBHOOK_URL
INPUT_WEBHOOK_URL="${INPUT_WEBHOOK_URL:-$DEFAULT_WEBHOOK}"

# ============================================
#  第四步：生成备份脚本
# ============================================
step "第四步：生成备份脚本"

mkdir -p "$INPUT_SCRIPT_DIR" "$INPUT_LOG_DIR"

# 构建 BACKUP_ITEMS 数组内容
FOLDERS_ARRAY=""
for folder in "${BACKUP_FOLDERS_INPUT[@]}"; do
    escaped_folder="${folder//\\/\\\\}"
    escaped_folder="${escaped_folder//\"/\\\"}"
    FOLDERS_ARRAY+="    \"${escaped_folder}\"
"
done

# 构建 REMOTE_LIST 数组内容
REMOTE_ARRAY=""
for r in "${INPUT_REMOTES[@]}"; do
    escaped_r="${r//\\/\\\\}"
    escaped_r="${escaped_r//\"/\\\"}"
    REMOTE_ARRAY+="    \"${escaped_r}\"
"
done

# 构建 EXCLUDE_PATTERNS 数组内容
EXCLUDE_ARRAY=""
for ex in "${EXCLUDE_INPUT[@]}"; do
    escaped_ex="${ex//\\/\\\\}"
    escaped_ex="${escaped_ex//\"/\\\"}"
    EXCLUDE_ARRAY+="    \"${escaped_ex}\"
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

# 远程路径列表（支持多远程异地备份）
REMOTE_LIST=(
REMOTE_LIST_PLACEHOLDER)

# 需要备份的文件或文件夹（支持通配符，如 "/root/*.sh"）
BACKUP_ITEMS=(
BACKUP_ITEMS_PLACEHOLDER)

# 排除规则（rclone --exclude 模式）
EXCLUDE_PATTERNS=(
EXCLUDE_PATTERNS_PLACEHOLDER)

# 备份前执行的命令（留空跳过，如 "mysqldump -u root dbname > /tmp/db.sql"）
PRE_BACKUP_CMD="PRE_BACKUP_CMD_PLACEHOLDER"

# 备份后执行的命令（留空跳过，如 "rm -f /tmp/db.sql"）
POST_BACKUP_CMD="POST_BACKUP_CMD_PLACEHOLDER"

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

# 上传失败重试次数（0 不重试）
RETRY_COUNT=RETRY_COUNT_PLACEHOLDER

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
MANIFEST_FILE="/var/run/${STATUS_PROJECT}.manifest"

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

# 带重试的 rclone copy
rclone_copy_with_retry() {
    local src="$1" dst="$2"
    shift 2
    local extra_opts=("$@")
    local attempt=0
    local max=$((RETRY_COUNT + 1))

    while [ $attempt -lt $max ]; do
        attempt=$((attempt + 1))
        if [ $attempt -gt 1 ]; then
            log "  ⏳ 第 ${attempt}/${max} 次尝试..."
            sleep 5
        fi
        if rclone copy "$src" "$dst" "${extra_opts[@]}"; then
            return 0
        fi
        log "  ⚠ 上传失败（第 ${attempt} 次）"
    done
    return 1
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

# ---------- 单个条目备份 ----------

backup_one() {
    local src="$1"
    local name archive dest size

    # 安全展开通配符
    local items=()
    if [[ "$src" == *"*"* || "$src" == *"?"* || "$src" == *"["* ]]; then
        while IFS= read -r -d '' item; do
            items+=("$item")
        done < <(eval "printf '%s\0' $src" 2>/dev/null || true)
        if [ ${#items[@]} -eq 0 ]; then
            log "  ⚠ 未匹配到: ${src}"
            return 1
        fi
    else
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
        dest_base="${BACKUP_PATH_PREFIX}/${name}/"

        log "━━━ ${name} ━━━"

        # 压缩
        log "  → 压缩中..."
        GZIP="-${COMPRESSION_LEVEL}" tar -czf "${archive}" \
            -C "$(dirname "${item}")" "${name}" 2>>"${LOG_FILE}"
        size=$(du -h "${archive}" | cut -f1)
        log "  ✓ 压缩完成 (${size})"

        # 上传到每个远程
        for remote in "${REMOTE_LIST[@]}"; do
            local dest="${remote}/${name}/"
            local rclone_opts=(-P --log-file="${LOG_FILE}" --log-level INFO)
            [ -n "${BWLIMIT}" ] && rclone_opts+=(--bwlimit "${BWLIMIT}")
            # 添加排除规则
            for pattern in "${EXCLUDE_PATTERNS[@]}"; do
                rclone_opts+=(--exclude "${pattern}")
            done

            log "  → 上传到 ${dest} ..."
            if rclone_copy_with_retry "${archive}" "${dest}" "${rclone_opts[@]}"; then
                log "  ✓ 上传完成 → ${remote}"
            else
                log "  ✗ 上传失败 → ${remote}（已重试 ${RETRY_COUNT} 次）"
                return 1
            fi

            # 校验
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
        done

        rm -f "${archive}"
        record_manifest "${name}"
        log "  ✓ 完成"
    done
}

# ---------- 按数量清理 ----------

clean_old_by_count() {
    local remote_dir="$1"
    local files="" file_count=0

    files=$(rclone lsf "${remote_dir}" --files-only 2>/dev/null | sort -V || true)
    [ -z "${files}" ] && return 0

    file_count=$(echo "${files}" | wc -l)
    [ "${file_count}" -le "${RETENTION_COUNT}" ] && return 0

    local to_delete
    to_delete=$(echo "${files}" | head -n $((${file_count} - ${RETENTION_COUNT})))

    while IFS= read -r file; do
        if [ -n "${file}" ]; then
            log "  删除: ${remote_dir}${file}"
            rclone delete "${remote_dir}${file}" 2>/dev/null || true
        fi
    done <<< "${to_delete}"
}

# ---------- 按天数清理（仅清理本脚本备份的子目录） ----------

clean_old_by_days() {
    local remote_dir="$1"
    log "  清理 ${remote_dir} 中 ${RETENTION_DAYS} 天前的文件..."
    rclone delete "${remote_dir}" \
        --min-age "${RETENTION_DAYS}d" \
        --log-file="${LOG_FILE}" --log-level INFO 2>/dev/null || \
        log "  ⚠ 清理出错（不影响本次备份）"
}

# ---------- 孤儿目录清理（仅清理本脚本管理的目录） ----------

# 记录本次备份的目录到清单
record_manifest() {
    local name="$1"
    # 去重写入
    if [ -f "${MANIFEST_FILE}" ]; then
        grep -qxF "$name" "${MANIFEST_FILE}" 2>/dev/null || echo "$name" >> "${MANIFEST_FILE}"
    else
        echo "$name" > "${MANIFEST_FILE}"
    fi
}

clean_orphan_dirs() {
    local remote="$1"

    # 清单文件不存在则跳过（首次运行，不会误删任何东西）
    if [ ! -f "${MANIFEST_FILE}" ]; then
        log "  清单文件不存在，跳过孤儿清理"
        return 0
    fi

    # 读取清单中记录的目录名
    local managed_names=()
    while IFS= read -r line; do
        [ -n "$line" ] && managed_names+=("$line")
    done < "${MANIFEST_FILE}"

    [ ${#managed_names[@]} -eq 0 ] && return 0

    # 构建当前仍在备份的目录名集合
    local active_names=()
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
            [ -e "${item}" ] && active_names+=("$(basename "${item}")")
        done
    done

    # 只清理：在清单中 AND 不在当前备份项中 的目录
    log "━━━ 清理已移除的备份目录（仅限本脚本管理的目录）━━━"
    for managed in "${managed_names[@]}"; do
        local is_active=false
        for active in "${active_names[@]}"; do
            if [ "$managed" = "$active" ]; then
                is_active=true
                break
            fi
        done
        if [ "$is_active" = false ]; then
            # 二次确认：远程目录确实存在才删
            if rclone lsf "${remote}${managed}/" --dirs-only &>/dev/null; then
                log "  🗑 清理: ${remote}${managed}/（已从备份项中移除）"
                rclone purge "${remote}${managed}/" 2>/dev/null || true
            fi
        fi
    done

    # 更新清单：只保留当前活跃的
    printf "%s\n" "${active_names[@]}" > "${MANIFEST_FILE}"
}

# ---------- 清理调度 ----------

clean_old() {
    for remote in "${REMOTE_LIST[@]}"; do
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
                        clean_old_by_count "${remote}/${item_name}/"
                    fi
                done
            done
        else
            log "━━━ 清理过期备份（保留 ${RETENTION_DAYS} 天）━━━"
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
                        clean_old_by_days "${remote}/${item_name}/"
                    fi
                done
            done
        fi
        # 孤儿目录清理
        clean_orphan_dirs "${remote}"
    done
}

# ---------- 主流程 ----------

log "========================================"
log "  STATUS_PROJECT_DISPLAY 备份开始"
log "  主机: ${HOSTNAME}"
log "  远程: ${REMOTE_LIST[*]}"
log "  条目: ${#BACKUP_ITEMS[@]} 个"
log "  保留: RETENTION_DISPLAY_PLACEHOLDER"
log "========================================"

acquire_lock

# 预刷新远程 Token（防止长时间压缩后 Token 过期）
# rclone config reconnect 需要 v1.55+，旧版本跳过
_rclone_ver=$(rclone version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
_rclone_major=${_rclone_ver%%.*}
_rclone_minor=${_rclone_ver#*.}
if [ "${_rclone_major}" -ge 1 ] && [ "${_rclone_minor}" -ge 55 ] 2>/dev/null; then
    for _remote in "${REMOTE_LIST[@]}"; do
        _remote_name="${_remote%%:*}"
        log "  → 刷新 ${_remote_name} 授权..."
        rclone config reconnect "${_remote_name}" --auto-confirm 2>>"${LOG_FILE}" || \
            log "  ⚠ 刷新失败（可能需要手动授权: rclone config reconnect ${_remote_name}）"
    done
else
    log "  ℹ rclone 版本 $(rclone version 2>/dev/null | head -1 | awk '{print $2}') 较旧，跳过 Token 预刷新"
fi

# 前置钩子
if [ -n "${PRE_BACKUP_CMD}" ]; then
    log "━━━ 执行前置命令 ━━━"
    log "  $ ${PRE_BACKUP_CMD}"
    eval "${PRE_BACKUP_CMD}" 2>>"${LOG_FILE}" || {
        log "  ✗ 前置命令执行失败"
        release_lock
        send_notification "[失败] ${STATUS_PROJECT}" "主机 ${HOSTNAME}: 前置命令失败"
        exit 1
    }
    log "  ✓ 前置命令完成"
fi

total=${#BACKUP_ITEMS[@]}
success=0
failed=0
failed_list=""

for folder in "${BACKUP_ITEMS[@]}"; do
    if backup_one "${folder}"; then
        success=$((success + 1))
    else
        failed=$((failed + 1))
        failed_list+="    - ${folder}\n"
    fi
done

clean_old
cleanup
cleanup_old_logs

# 后置钩子
if [ -n "${POST_BACKUP_CMD}" ]; then
    log "━━━ 执行后置命令 ━━━"
    log "  $ ${POST_BACKUP_CMD}"
    eval "${POST_BACKUP_CMD}" 2>>"${LOG_FILE}" || {
        log "  ⚠ 后置命令执行失败（不影响备份结果）"
    }
    log "  ✓ 后置命令完成"
fi

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

# 用 Python 做占位符替换（兼容各种字符编码）
# 第一步：替换不含特殊字符的简单值
sed -i "s/PROJECT_NAME_PLACEHOLDER/${INPUT_PROJECT_NAME}/g" "$SCRIPT_PATH"
sed -i "s/RETENTION_TYPE_PLACEHOLDER/${INPUT_RETENTION_TYPE}/g" "$SCRIPT_PATH"
sed -i "s/RETENTION_COUNT_PLACEHOLDER/${INPUT_RETENTION_COUNT}/g" "$SCRIPT_PATH"
sed -i "s/RETENTION_DAYS_PLACEHOLDER/${INPUT_RETENTION_DAYS}/g" "$SCRIPT_PATH"
sed -i "s/COMPRESSION_LEVEL_PLACEHOLDER/${INPUT_COMPRESSION}/g" "$SCRIPT_PATH"
sed -i "s/ENABLE_LOCK_PLACEHOLDER/${INPUT_LOCK}/g" "$SCRIPT_PATH"
sed -i "s/RETRY_COUNT_PLACEHOLDER/${INPUT_RETRY_COUNT}/g" "$SCRIPT_PATH"
sed -i "s/LOG_RETENTION_DAYS_PLACEHOLDER/${INPUT_LOG_RETENTION_DAYS}/g" "$SCRIPT_PATH"

# 第二步：含特殊字符的值用 Python 替换
python3 - "$SCRIPT_PATH" "${INPUT_WEBHOOK_URL}" "${INPUT_BWLIMIT}" "${INPUT_LOG_DIR}" "${RETENTION_DISPLAY}" "${INPUT_PRE_CMD}" "${INPUT_POST_CMD}" "${INPUT_PROJECT_NAME}" << 'PYEOF_REPLACE'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    c = f.read()
for k, v in [
    ("WEBHOOK_URL_PLACEHOLDER", sys.argv[2]),
    ("BWLIMIT_PLACEHOLDER", sys.argv[3]),
    ("LOG_DIR_PLACEHOLDER", sys.argv[4]),
    ("RETENTION_DISPLAY_PLACEHOLDER", sys.argv[5]),
    ("PRE_BACKUP_CMD_PLACEHOLDER", sys.argv[6]),
    ("POST_BACKUP_CMD_PLACEHOLDER", sys.argv[7]),
    ("STATUS_PROJECT_DISPLAY", sys.argv[8]),
]:
    c = c.replace(k, v)
with open(filepath, 'w') as f:
    f.write(c)
PYEOF_REPLACE

# 第三步：数组占位符用 Python 替换
export _PY_BACKUP_ITEMS="$FOLDERS_ARRAY"
export _PY_REMOTE_LIST="$REMOTE_ARRAY"
export _PY_EXCLUDES="$EXCLUDE_ARRAY"
python3 - "$SCRIPT_PATH" << 'PYEOF_ARRAY'
import sys, os
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    c = f.read()
for env_key, ph in [
    ("_PY_BACKUP_ITEMS", "BACKUP_ITEMS_PLACEHOLDER"),
    ("_PY_REMOTE_LIST", "REMOTE_LIST_PLACEHOLDER"),
    ("_PY_EXCLUDES", "EXCLUDE_PATTERNS_PLACEHOLDER"),
]:
    c = c.replace(ph, os.environ.get(env_key, ""))
with open(filepath, 'w') as f:
    f.write(c)
PYEOF_ARRAY

chmod +x "$SCRIPT_PATH"
info "备份脚本已生成: ${SCRIPT_PATH}"

# ============================================
#  第五步：生成恢复脚本
# ============================================
step "第五步：生成恢复脚本"

cat > "$RESTORE_PATH" << 'RESTORE_EOF'
#!/bin/bash
set -euo pipefail

# ============================================
#  PROJECT_NAME_PLACEHOLDER 恢复脚本
#  从远程备份中恢复文件
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

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

REMOTE_LIST=(
REMOTE_LIST_PLACEHOLDER)

echo ""
echo -e "  ${BOLD}PROJECT_NAME_PLACEHOLDER 备份恢复${NC}"
echo ""

# 选择远程
if [ ${#REMOTE_LIST[@]} -eq 1 ]; then
    REMOTE="${REMOTE_LIST[0]}"
    echo -e "  远程: ${CYAN}${REMOTE}${NC}"
else
    echo -e "  ${BOLD}可用远程：${NC}"
    for i in "${!REMOTE_LIST[@]}"; do
        echo -e "    ${CYAN}$((i+1)))${NC} ${REMOTE_LIST[$i]}"
    done
    echo ""
    read -r -p "  选择远程 [1]: " remote_choice
    remote_choice="${remote_choice:-1}"
    REMOTE="${REMOTE_LIST[$((remote_choice-1))]}"
fi

# 列出可用备份
echo ""
echo -e "  ${BOLD}扫描远程目录...${NC}"
DIRS=$(rclone lsf "${REMOTE}" --dirs-only 2>/dev/null | sed 's|/$||' || true)

if [ -z "$DIRS" ]; then
    error "远程没有备份目录"
    exit 1
fi

echo -e "  ${BOLD}可恢复的备份项：${NC}"
idx=0
declare -a dir_list
while IFS= read -r d; do
    dir_list+=("$d")
    idx=$((idx+1))
    echo -e "    ${CYAN}${idx})${NC} ${d}"
done <<< "$DIRS"

echo ""
read -r -p "  选择要恢复的编号: " dir_choice
if [[ ! "$dir_choice" =~ ^[0-9]+$ ]] || [ "$dir_choice" -lt 1 ] || [ "$dir_choice" -gt ${#dir_list[@]} ]; then
    error "无效选择"
    exit 1
fi
SELECTED_DIR="${REMOTE}/${dir_list[$((dir_choice-1))]}"

# 列出该目录下的备份文件
echo ""
echo -e "  ${BOLD}可用的备份文件：${NC}"
FILES=$(rclone lsf "${SELECTED_DIR}" --files-only 2>/dev/null | sort -Vr || true)

if [ -z "$FILES" ]; then
    error "该目录下没有备份文件"
    exit 1
fi

file_idx=0
declare -a file_list
while IFS= read -r f; do
    file_list+=("$f")
    file_idx=$((file_idx+1))
    echo -e "    ${CYAN}${file_idx})${NC} ${f}"
done <<< "$FILES"

echo ""
echo -e "  ${BOLD}恢复选项：${NC}"
echo -e "    ${CYAN}1)${NC} 恢复最新一份"
echo -e "    ${CYAN}2)${NC} 选择特定版本"
echo -e "    ${CYAN}3)${NC} 恢复全部"
echo ""
read -r -p "  选择 [1]: " restore_choice
restore_choice="${restore_choice:-1}"

read -r -p "  恢复到哪个目录 [/tmp/restore-${INPUT_PROJECT_NAME}]: " RESTORE_DIR
RESTORE_DIR="${RESTORE_DIR:-/tmp/restore-PROJECT_NAME_PLACEHOLDER}"
mkdir -p "$RESTORE_DIR"

do_restore() {
    local file="$1"
    local tmp_archive="/tmp/${file}"
    echo -e "  → 下载 ${CYAN}${file}${NC} ..."
    rclone copy "${SELECTED_DIR}/${file}" /tmp/ -P
    echo -e "  → 解压到 ${CYAN}${RESTORE_DIR}${NC} ..."
    tar -xzf "$tmp_archive" -C "$RESTORE_DIR"
    rm -f "$tmp_archive"
    echo -e "  ${GREEN}[✓]${NC} 恢复完成: ${RESTORE_DIR}"
}

case "$restore_choice" in
    1)
        do_restore "${file_list[0]}"
        ;;
    2)
        read -r -p "  输入文件编号: " fnum
        if [[ "$fnum" =~ ^[0-9]+$ ]] && [ "$fnum" -ge 1 ] && [ "$fnum" -le ${#file_list[@]} ]; then
            do_restore "${file_list[$((fnum-1))]}"
        else
            error "无效编号"
            exit 1
        fi
        ;;
    3)
        for f in "${file_list[@]}"; do
            do_restore "$f"
        done
        ;;
    *)
        error "无效选择"
        exit 1
        ;;
esac

echo ""
info "全部恢复完成！文件位于: ${RESTORE_DIR}"
RESTORE_EOF

# 替换恢复脚本占位符
sed -i "s/PROJECT_NAME_PLACEHOLDER/${INPUT_PROJECT_NAME}/g" "$RESTORE_PATH"
export _PY_REMOTE_LIST="$REMOTE_ARRAY"
python3 - "$RESTORE_PATH" << 'PYEOF_RESTORE'
import sys, os
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    c = f.read()
c = c.replace("REMOTE_LIST_PLACEHOLDER", os.environ.get("_PY_REMOTE_LIST", ""))
with open(filepath, 'w') as f:
    f.write(c)
PYEOF_RESTORE

chmod +x "$RESTORE_PATH"
info "恢复脚本已生成: ${RESTORE_PATH}"

# ============================================
#  第六步：配置定时任务
# ============================================
step "第六步：配置定时任务"

CRON_COMMENT="# ${INPUT_PROJECT_NAME} backup"
CRON_ENTRY="${INPUT_CRON} ${SCRIPT_PATH} >> ${INPUT_LOG_DIR}/cron.log 2>&1"

EXISTING_CRON=$(crontab -l 2>/dev/null || true)

if echo "$EXISTING_CRON" | grep -qF "${SCRIPT_PATH}"; then
    warn "检测到旧的定时任务，将替换..."
    EXISTING_CRON=$(echo "$EXISTING_CRON" | grep -vF "${SCRIPT_PATH}" | grep -vF "# ${INPUT_PROJECT_NAME} backup")
fi

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
#  第七步：输出摘要
# ============================================
step "安装完成"

echo ""
echo -e "  ${BOLD}项目:${NC}  ${INPUT_PROJECT_NAME}"
echo -e "  ┌──────────────────────────────────────────────────────┐"
echo -e "  │  备份脚本:  ${CYAN}${SCRIPT_PATH}${NC}"
echo -e "  │  恢复脚本:  ${CYAN}${RESTORE_PATH}${NC}"
echo -e "  │  远程    :  ${CYAN}${INPUT_REMOTES[*]}${NC}"
echo -e "  │  备份项  :  ${CYAN}${#BACKUP_FOLDERS_INPUT[@]} 个${NC}"
for f in "${BACKUP_FOLDERS_INPUT[@]}"; do
echo -e "  │     - ${CYAN}${f}${NC}"
done
if [ ${#EXCLUDE_INPUT[@]} -gt 0 ]; then
echo -e "  │  排除    :  ${CYAN}${#EXCLUDE_INPUT[@]} 条${NC}"
for ex in "${EXCLUDE_INPUT[@]}"; do
echo -e "  │     - ${CYAN}${ex}${NC}"
done
fi
[ -n "$INPUT_PRE_CMD" ] && echo -e "  │  前置    :  ${CYAN}${INPUT_PRE_CMD}${NC}"
[ -n "$INPUT_POST_CMD" ] && echo -e "  │  后置    :  ${CYAN}${INPUT_POST_CMD}${NC}"
echo -e "  │  定时    :  ${CYAN}${INPUT_CRON}${NC}"
echo -e "  │  保留    :  ${CYAN}${RETENTION_DISPLAY}${NC}"
echo -e "  │  重试    :  ${CYAN}${INPUT_RETRY_COUNT} 次${NC}"
echo -e "  │  日志    :  ${CYAN}${INPUT_LOG_DIR}/${NC}"
[ -n "$INPUT_BWLIMIT" ] && echo -e "  │  带宽    :  ${CYAN}${INPUT_BWLIMIT}${NC}"
echo -e "  └──────────────────────────────────────────────────────┘"
echo ""
echo -e "  ${BOLD}常用命令：${NC}"
echo -e "    手动备份  :  ${CYAN}${SCRIPT_PATH}${NC}"
echo -e "    恢复数据  :  ${CYAN}${RESTORE_PATH}${NC}"
echo -e "    编辑配置  :  ${CYAN}vim ${SCRIPT_PATH}${NC}"
echo -e "    查看定时  :  ${CYAN}crontab -l${NC}"
echo -e "    查看日志  :  ${CYAN}tail -f ${INPUT_LOG_DIR}/${INPUT_PROJECT_NAME}-$(date +%Y%m%d).log${NC}"
echo -e "    卸载      :  ${CYAN}curl -fsSL ... | bash -s -- --uninstall${NC}"
echo ""
echo -e "  ${YELLOW}后期修改：直接编辑脚本顶部配置区即可${NC}"
echo ""
