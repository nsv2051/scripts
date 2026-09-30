#!/bin/bash
#
# kworker-check.sh - Linux 恶意进程伪装与挖矿木马深度检测工具
# 仓库: https://github.com/nsv2051/scripts
# 用法: 
#   curl -fsSL https://raw.githubusercontent.com/nsv2051/scripts/main/kworker-check.sh | bash
#

set -u

# ==========================================
# 0. 基础权限与依赖检查（跨平台自动补全）
# ==========================================
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 身份运行此脚本！"
    exit 1
fi

REQUIRED_CMDS=("pgrep" "readlink" "ss" "file")
MISSING_CMDS=()

for CMD in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$CMD" &>/dev/null; then
        MISSING_CMDS+=("$CMD")
    fi
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    echo -e "\033[0;33m[提示] 检测到缺少工具: ${MISSING_CMDS[*]}，正在自动安装...\033[0m"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq procps coreutils iproute2 file >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y procps-ng coreutils iproute file >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y procps-ng coreutils iproute file >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        apk add --no-cache procps coreutils iproute2 file >/dev/null 2>&1
    fi

    # 二次验证
    for CMD in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$CMD" &>/dev/null; then
            echo -e "\033[0;31m[错误] 依赖安装失败，缺少: $CMD，请手动安装后重试！\033[0m"
            exit 1
        fi
    done
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "========================================="
echo "  Linux 恶意进程与伪装木马全盘检测"
echo "========================================="
echo ""

SUSPECT=0

# ==========================================
# 1. 扫描所有 kworker 进程（排查用户态伪装）
# ==========================================
echo -e "${YELLOW}[1/5] 扫描所有 kworker 进程...${NC}"
KWORKERS=$(pgrep -f kworker || true)

if [ -z "$KWORKERS" ]; then
    echo -e "  ${GREEN}[正常] 未发现任何正在运行的 kworker 进程${NC}"
else
    for PID in $KWORKERS; do
        [ ! -d "/proc/$PID" ] && continue

        COMM=$(cat "/proc/$PID/comm" 2>/dev/null || true)
        CMDLINE=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)
        EXE=$(readlink "/proc/$PID/exe" 2>/dev/null || true)

        # 核心判定准则：真正内核线程 exe 必定为空
        if [ -n "$EXE" ]; then
            echo -e "\n  ${RED}[危险] 发现恶意伪装进程！PID: $PID (${COMM})${NC}"
            echo -e "  伪装真实落地路径: $EXE"
            FILE_INFO=$(file "$EXE" 2>/dev/null || true)
            echo -e "  文件类型: $FILE_INFO"
            SUSPECT=$((SUSPECT + 1))
        elif [ -n "$CMDLINE" ] && [[ ! "$CMDLINE" =~ ^\[kworker ]]; then
            echo -e "\n  ${RED}[危险] 异常伪装进程！PID: $PID cmdline 异常: $CMDLINE${NC}"
            SUSPECT=$((SUSPECT + 1))
        else
            # 真实内核线程，仅监控 CPU
            CPU=$(ps -p "$PID" -o %cpu= 2>/dev/null | tr -d ' ')
            CPU_INT=${CPU%.*}
            if [ "${CPU_INT:-0}" -gt 85 ]; then
                echo -e "  ${YELLOW}[注意] 内核线程 PID: $PID CPU 较高 (${CPU}%)，通常为高 I/O 引起${NC}"
            fi
        fi
    done
    [ "$SUSPECT" -eq 0 ] && echo -e "  ${GREEN}[正常] 所有 kworker 均为合法系统内核线程${NC}"
fi

# ==========================================
# 2. 扫描常见临时与隐藏目录落地伪装文件
# ==========================================
echo ""
echo -e "${YELLOW}[2/5] 扫描可疑落地文件 (含隐藏/零宽字符木马)...${NC}"
FOUND_FILES=0

# 遍历排查 /dev/shm, /tmp, /var/tmp, /root
for SCAN_DIR in /dev/shm /tmp /var/tmp /root; do
    [ ! -d "$SCAN_DIR" ] && continue

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo -e "  ${RED}[危险] 发现可疑文件: $f${NC}"
        ls -lha "$f"
        SUSPECT=$((SUSPECT + 1))
        FOUND_FILES=$((FOUND_FILES + 1))
    done < <(find "$SCAN_DIR" -maxdepth 2 -type f \( \
        -name "*kworker*" -o \
        -name ".*rc*u*p*" -o \
        -name ".xmr*" -o \
        -path "/dev/shm/.*" \
    \) 2>/dev/null)
done

if [ "$FOUND_FILES" -eq 0 ]; then
    echo -e "  ${GREEN}[正常] 未发现任何伪装落地的木马文件${NC}"
fi

# ==========================================
# 3. 检查系统所有用户及系统级 Crontab
# ==========================================
echo ""
echo -e "${YELLOW}[3/5] 检查系统各用户 Crontab 及系统任务...${NC}"
CRON_MALICIOUS=0

# 检查当前用户及 /etc/passwd 用户
for U in $(cut -d: -f1 /etc/passwd 2>/dev/null); do
    U_CRON=$(crontab -u "$U" -l 2>/dev/null || true)
    if [ -n "$U_CRON" ]; then
        SUSP_LINE=$(echo "$U_CRON" | grep -iE 'kworker|\.r.*u.*p|/dev/shm|xmrig|pastebin|curl.*\|.*sh|wget.*\|.*sh' || true)
        if [ -n "$SUSP_LINE" ]; then
            echo -e "  ${RED}[警告] 用户 [$U] 的 crontab 中发现可疑条目:${NC}"
            echo "$SUSP_LINE"
            SUSPECT=$((SUSPECT + 1))
            CRON_MALICIOUS=$((CRON_MALICIOUS + 1))
        fi
    fi
done

# 检查 /etc/cron*
SYS_CRON_SUSP=$(grep -rnE 'kworker|\.r.*u.*p|/dev/shm' /etc/cron* /etc/crontab 2>/dev/null || true)
if [ -n "$SYS_CRON_SUSP" ]; then
    echo -e "  ${RED}[警告] 系统计划任务 (/etc/cron*) 发现异常:${NC}"
    echo "$SYS_CRON_SUSP"
    SUSPECT=$((SUSPECT + 1))
    CRON_MALICIOUS=$((CRON_MALICIOUS + 1))
fi

if [ "$CRON_MALICIOUS" -eq 0 ]; then
    echo -e "  ${GREEN}[正常] 计划任务无可疑驻留条目${NC}"
fi

# ==========================================
# 4. 扫描已知挖矿进程特征
# ==========================================
echo ""
echo -e "${YELLOW}[4/5] 扫描常见挖矿特征进程...${NC}"
MINER_PROCS=$(ps aux | grep -iE 'xmrig|minergate|stratum|cryptonight|ethminer|pool\.|hashrate|\.rc.*u.*p' | grep -v grep || true)
if [ -n "$MINER_PROCS" ]; then
    echo -e "  ${RED}[危险] 发现疑似挖矿/木马进程:${NC}"
    echo "$MINER_PROCS"
    SUSPECT=$((SUSPECT + 1))
else
    echo -e "  ${GREEN}[正常] 未发现已知挖矿进程${NC}"
fi

# ==========================================
# 5. 检查可疑外联与矿池端口
# ==========================================
echo ""
echo -e "${YELLOW}[5/5] 检查异常矿池网络连接...${NC}"
POOL_CONN=$(ss -tpn 2>/dev/null | grep -iE '3333|4444|5555|7777|8888|9999|14444|45560' | head -15 || true)
if [ -n "$POOL_CONN" ]; then
    echo -e "  ${RED}[警告] 检测到矿池常见外联端口连接:${NC}"
    echo "$POOL_CONN"
    SUSPECT=$((SUSPECT + 1))
else
    echo -e "  ${GREEN}[正常] 未发现可疑外联连接${NC}"
fi

# ==========================================
# 总结输出
# ==========================================
echo ""
echo "========================================="
if [ "$SUSPECT" -gt 0 ]; then
    echo -e "${RED}  检测到 $SUSPECT 项可疑风险！请及时排查与清理！${NC}"
    echo "========================================="
    exit 1
else
    echo -e "${GREEN}  全部正常，系统未见 kworker 伪装与恶意木马！${NC}"
    echo "========================================="
    exit 0
fi
