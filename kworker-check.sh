#!/bin/bash
#
# kworker-and-malware-check.sh - Linux 恶意进程伪装与挖矿木马全能检测/清理工具
# 仓库: https://github.com/nsv2051/scripts
#
# 用法: 
#   sudo bash kworker-check.sh          # 仅检测模式
#   sudo bash kworker-check.sh --clean  # 检测并自动清理恶意文件与持久化任务
#

AUTO_CLEAN=0
if [[ "$1" == "--clean" || "$1" == "-c" ]]; then
    AUTO_CLEAN=1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "用法: sudo bash $0 [选项]"
    echo "选项:"
    echo "  --clean, -c   检测到恶意木马、伪装进程及异常定时任务时自动清理并备份"
    echo "  -h, --help    显示此帮助信息"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 身份运行: sudo bash $0"
    exit 1
fi

for CMD in pgrep readlink ss file awk grep; do
    if ! command -v "$CMD" &>/dev/null; then
        echo "缺少依赖: $CMD，请先通过 apt/yum 安装"
        exit 1
    fi
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_TIME=$(date '+%Y%m%d_%H%M%S')
BACKUP_DIR="/root/malware_backup_${LOG_TIME}"

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}    Linux 进程伪装 & 挖矿木马检测工具    ${NC}"
echo -e "${BLUE}=========================================${NC}"

SUSPECT=0
declare -a SUSPECT_PIDS=()
declare -a SUSPECT_FILES=()

# ==========================================
# 1. 扫描伪装成内核线程的进程 (kworker, rcuop 等)
# ==========================================
echo -e "\n${YELLOW}[1/6] 扫描内核伪装进程 (kworker, rcuop 等)...${NC}"
# 查找名字带 kworker、rcuop、rcu_sched 等常见被冒充的进程
TARGET_PIDS=$(pgrep -f -E 'kworker|\.rc.*u.*p|rcu_sched' 2>/dev/null)

if [ -z "$TARGET_PIDS" ]; then
    echo -e "${GREEN}  未发现相关检测特征进程${NC}"
else
    for PID in $TARGET_PIDS; do
        EXE_PATH=$(readlink /proc/$PID/exe 2>/dev/null)
        CMDLINE=$(tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null)

        # 真正的 Linux 内核线程没有 exe 链接 (/proc/$PID/exe 为空)
        if [[ -n "$EXE_PATH" && -f "$EXE_PATH" ]]; then
            echo -e "  ---- PID: $PID ----"
            echo "  cmdline: $CMDLINE"
            echo -e "  ${RED}[危险] 发现用户态可执行文件伪装成内核线程！${NC}"
            echo -e "  ${RED}  exe 路径: $EXE_PATH${NC}"
            SUSPECT=$((SUSPECT + 1))
            SUSPECT_PIDS+=("$PID")
            SUSPECT_FILES+=("$EXE_PATH")

            echo "  文件详情:"
            ls -lh "$EXE_PATH" 2>/dev/null
            echo "  MD5: $(md5sum "$EXE_PATH" 2>/dev/null | awk '{print $1}')"
            file "$EXE_PATH" 2>/dev/null

            CPU=$(ps -p $PID -o %cpu= 2>/dev/null | tr -d ' ')
            if [ -n "$CPU" ]; then
                echo -e "  CPU 占用: ${RED}${CPU}%${NC}"
            fi
        fi
    done
fi

# ==========================================
# 2. 扫描敏感目录中的隐藏/异常可执行文件
# ==========================================
echo -e "\n${YELLOW}[2/6] 扫描 /dev/shm、/tmp、/var/tmp 隐藏恶意文件...${NC}"
# 针对零宽字符伪装、带点隐藏文件、伪装内核名
for D in /dev/shm /tmp /var/tmp; do
    if [ -d "$D" ]; then
        while IFS= read -r -d '' F; do
            base_f=$(basename "$F")
            # 过滤标准正常套接字或系统目录
            if [[ "$base_f" =~ ^\.r.*u.*p ]] || [[ "$base_f" =~ ^\.kworker ]] || [[ "$base_f" =~ ^\[kworker ]] || [[ "$D" == "/dev/shm" && "$base_f" =~ ^\. ]] || [[ "$base_f" =~ [[:cntrl:]] ]]; then
                echo -e "  ${RED}[危险] 发现可疑隐藏落地程序: $F${NC}"
                ls -lh "$F"
                SUSPECT=$((SUSPECT + 1))
                SUSPECT_FILES+=("$F")
            fi
        done < <(find "$D" -maxdepth 2 -type f -executable -print0 2>/dev/null)
    fi
done

# 补充扫描原脚本中的特定路径通配符
for PATTERN in "/root/[kworker*" "/tmp/[kworker*" "/var/tmp/[kworker*" "/dev/shm/[kworker*" "/root/.kworker*" "/tmp/.kworker*"; do
    for F in $PATTERN; do
        if [ -e "$F" ]; then
            echo -e "  ${RED}[危险] 发现可疑文件: $F${NC}"
            ls -lh "$F"
            SUSPECT=$((SUSPECT + 1))
            SUSPECT_FILES+=("$F")
        fi
    done
done

# ==========================================
# 3. 检查所有用户的 Crontab 及系统 Cron 目录
# ==========================================
echo -e "\n${YELLOW}[3/6] 检查定时任务 (Crontab)...${NC}"
CRON_MALICIOUS_USERS=()

for U in $(cut -d: -f1 /etc/passwd); do
    U_CRON=$(crontab -u "$U" -l 2>/dev/null || true)
    if [ -n "$U_CRON" ]; then
        MATCHED=$(echo "$U_CRON" | grep -iE 'kworker|\.r.*u.*p|/dev/shm|pastebin|base64.*eval|chmod.*777')
        if [ -n "$MATCHED" ]; then
            echo -e "  ${RED}[警告] 用户 $U 的 crontab 中发现可疑条目:${NC}"
            echo "$MATCHED"
            SUSPECT=$((SUSPECT + 1))
            CRON_MALICIOUS_USERS+=("$U")
        fi
    fi
done

SYS_CRON=$(grep -rnE 'kworker|\.r.*u.*p|/dev/shm|base64.*eval' /etc/cron* /etc/crontab 2>/dev/null || true)
if [ -n "$SYS_CRON" ]; then
    echo -e "  ${RED}[警告] 系统级 /etc/cron* 中发现可疑条目:${NC}"
    echo "$SYS_CRON"
    SUSPECT=$((SUSPECT + 1))
fi

# ==========================================
# 4. 扫描已知通用挖矿程序与 CPU 异常进程
# ==========================================
echo -e "\n${YELLOW}[4/6] 扫描通用挖矿特征及高 CPU 占用进程...${NC}"
MINER_CHECK=$(ps aux | grep -iE 'xmrig|minergate|stratum|cryptonight|ethminer|pool\.|hashrate' | grep -v grep || true)
if [ -n "$MINER_CHECK" ]; then
    echo -e "  ${RED}[危险] 发现已知特征挖矿进程:${NC}"
    echo "$MINER_CHECK"
    SUSPECT=$((SUSPECT + 1))
    while read -r line; do
        p=$(echo "$line" | awk '{print $2}')
        [ -n "$p" ] && SUSPECT_PIDS+=("$p")
    done <<< "$MINER_CHECK"
fi

# 检查非系统服务且 CPU > 70% 的可疑进程
HIGH_CPU_PROCS=$(ps aux --sort=-%cpu | awk 'NR>1 {if($3>70.0 && $11!~/(systemd|node|docker|java|python|rsync)/) print $2, $3"%", $11}' | head -5)
if [ -n "$HIGH_CPU_PROCS" ]; then
    echo -e "  ${YELLOW}[提示] 当前 CPU 占用极高的进程 (需留意):${NC}"
    echo "$HIGH_CPU_PROCS"
fi

# ==========================================
# 5. 检查可疑外联与矿池端口
# ==========================================
echo -e "\n${YELLOW}[5/6] 检查网络外联与矿池常用端口...${NC}"
POOL_CONN=$(ss -tpn 2>/dev/null | grep -iE '3333|4444|5555|7777|8888|9999|14444|45560' | head -20 || true)
if [ -n "$POOL_CONN" ]; then
    echo -e "  ${RED}[警告] 发现可疑矿池端口外联:${NC}"
    echo "$POOL_CONN"
    SUSPECT=$((SUSPECT + 1))
else
    echo -e "  ${GREEN}[正常] 未发现矿池常用端口连接${NC}"
fi

# ==========================================
# 6. 处理与清理模块 (交互或一键清理)
# ==========================================
echo -e "\n${BLUE}=========================================${NC}"
if [ "$SUSPECT" -eq 0 ]; then
    echo -e "${GREEN}  检测完成：全部正常，未发现可疑伪装或恶意木马！${NC}"
    echo -e "${BLUE}=========================================${NC}"
    exit 0
fi

echo -e "${RED}  检测到 $SUSPECT 项可疑风险！${NC}"
echo -e "${BLUE}=========================================${NC}"

DO_CLEAN=0
if [ "$AUTO_CLEAN" -eq 1 ]; then
    DO_CLEAN=1
else
    read -p "是否立即一键查杀恶意进程并清理木马文件与定时任务？(y/N): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        DO_CLEAN=1
    fi
fi

if [ "$DO_CLEAN" -eq 1 ]; then
    echo -e "\n${YELLOW}>>> 开始执行清理操作...${NC}"
    mkdir -p "${BACKUP_DIR}"
    echo -e "${GREEN}[备份] 恶意样本及原配置将备份到: ${BACKUP_DIR}${NC}"

    # 1. 杀死恶意进程
    if [ ${#SUSPECT_PIDS[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在终止恶意进程...${NC}"
        for PID in "${SUSPECT_PIDS[@]}"; do
            echo -e "  终止 PID: $PID"
            kill -9 "$PID" 2>/dev/null || true
        done
    fi
    pkill -9 -f '/dev/shm/' 2>/dev/null || true

    # 2. 备份并删除恶意落地文件
    if [ ${#SUSPECT_FILES[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在清除恶意落地文件...${NC}"
        # 去重
        UNIQUE_FILES=($(printf "%s\n" "${SUSPECT_FILES[@]}" | sort -u))
        for F in "${UNIQUE_FILES[@]}"; do
            if [ -e "$F" ]; then
                # 杀掉占用该文件的进程
                fuser -k -9 "$F" 2>/dev/null || true
                cp -a "$F" "${BACKUP_DIR}/" 2>/dev/null || true
                rm -f "$F"
                echo -e "  ${GREEN}已删除文件: $F${NC}"
            fi
        done
    fi

    # 3. 备份并清理恶意 Crontab 条目
    if [ ${#CRON_MALICIOUS_USERS[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在清理用户 crontab 恶意任务...${NC}"
        UNIQUE_USERS=($(printf "%s\n" "${CRON_MALICIOUS_USERS[@]}" | sort -u))
        for U in "${UNIQUE_USERS[@]}"; do
            U_CRON=$(crontab -u "$U" -l 2>/dev/null || true)
            if [ -n "$U_CRON" ]; then
                echo "$U_CRON" > "${BACKUP_DIR}/crontab_${U}.bak"
                echo "$U_CRON" | grep -vE 'kworker|\.r.*u.*p|/dev/shm' > /tmp/clean_cron_$$
                crontab -u "$U" /tmp/clean_cron_$$
                rm -f /tmp/clean_cron_$$
                echo -e "  ${GREEN}用户 $U 的恶意 crontab 已剔除，已备份原任务${NC}"
            fi
        done
    fi

    echo -e "\n${GREEN}✔ 清理完成！所有被删除的文件已备份至: ${BACKUP_DIR}${NC}"
else
    echo -e "\n${YELLOW}已跳过清理，请根据上方输出手动排查。${NC}"
fi
