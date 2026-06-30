#!/bin/bash
#
# check.sh - 检测 kworker 进程是否为恶意程序伪装
# 仓库: https://github.com/nsv2051/scripts
#
# 用法: sudo bash check.sh
#

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "用法: sudo bash $0"
    echo "检测 kworker 进程是否为恶意程序伪装"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 身份运行: sudo bash $0"
    exit 1
fi

for CMD in pgrep readlink ss file; do
    if ! command -v "$CMD" &>/dev/null; then
        echo "缺少依赖: $CMD，请先安装"
        exit 1
    fi
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "========================================="
echo "  kworker 进程检测"
echo "========================================="
echo ""

echo -e "${YELLOW}[1/5] 扫描所有 kworker 进程...${NC}"
KWORKERS=$(pgrep -f kworker)
if [ -z "$KWORKERS" ]; then
    echo -e "${GREEN}  未发现 kworker 进程${NC}"
    exit 0
fi

SUSPECT=0

for PID in $KWORKERS; do
    echo ""
    echo "  ---- PID: $PID ----"

    EXE_PATH=$(readlink /proc/$PID/exe 2>/dev/null)
    CMDLINE=$(tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null)

    echo "  cmdline: $CMDLINE"
    echo "  exe 路径: $EXE_PATH"

    if [[ "$EXE_PATH" == /* ]] && [[ "$EXE_PATH" != "/usr/bin/"* ]] && [[ -f "$EXE_PATH" ]]; then
        echo -e "  ${RED}[危险] 发现用户态可执行文件！${NC}"
        echo -e "  ${RED}  路径: $EXE_PATH${NC}"
        SUSPECT=$((SUSPECT + 1))

        echo "  文件详情:"
        ls -lh "$EXE_PATH" 2>/dev/null
        echo "  MD5: $(md5sum "$EXE_PATH" 2>/dev/null | awk '{print $1}')"
        file "$EXE_PATH" 2>/dev/null
    else
        echo -e "  ${GREEN}[正常] 内核线程，无可疑可执行文件${NC}"
    fi

    CPU=$(ps -p $PID -o %cpu= 2>/dev/null | tr -d ' ')
    if [ -n "$CPU" ]; then
        CPU_INT=${CPU%.*}
        if [ "${CPU_INT:-0}" -gt 50 ]; then
            echo -e "  ${RED}[警告] CPU 占用异常高: ${CPU}%${NC}"
            SUSPECT=$((SUSPECT + 1))
        else
            echo -e "  ${GREEN}[正常] CPU 占用: ${CPU}%${NC}"
        fi
    fi
done

echo ""
echo -e "${YELLOW}[2/5] 扫描常见病毒伪装路径...${NC}"
for PATTERN in "/root/[kworker*" "/tmp/[kworker*" "/var/tmp/[kworker*" "/dev/shm/[kworker*" "/root/.kworker*" "/tmp/.kworker*"; do
    for F in $PATTERN; do
        if [ -e "$F" ]; then
            echo -e "  ${RED}[危险] 发现可疑文件: $F${NC}"
            ls -lh "$F"
            SUSPECT=$((SUSPECT + 1))
        fi
    done
done
echo -e "  扫描完成"

echo ""
echo -e "${YELLOW}[3/5] 检查定时任务...${NC}"
CRON_SUSPECT=$(crontab -l 2>/dev/null | grep -iE 'kworker|wget|curl|base64|eval|chmod.*777')
if [ -n "$CRON_SUSPECT" ]; then
    echo -e "  ${RED}[警告] crontab 中发现可疑条目:${NC}"
    echo "$CRON_SUSPECT"
    SUSPECT=$((SUSPECT + 1))
else
    echo -e "  ${GREEN}[正常] crontab 无可疑条目${NC}"
fi

SYS_CRON=$(grep -rlE 'kworker|base64.*eval' /etc/cron* 2>/dev/null)
if [ -n "$SYS_CRON" ]; then
    echo -e "  ${RED}[警告] 系统 cron 中发现可疑内容:${NC}"
    echo "$SYS_CRON"
    SUSPECT=$((SUSPECT + 1))
fi

echo ""
echo -e "${YELLOW}[4/5] 扫描常见挖矿进程特征...${NC}"
MINER_CHECK=$(ps aux | grep -iE 'xmrig|minergate|stratum|cryptonight|ethminer|pool\.|hashrate' | grep -v grep)
if [ -n "$MINER_CHECK" ]; then
    echo -e "  ${RED}[危险] 发现疑似挖矿进程:${NC}"
    echo "$MINER_CHECK"
    SUSPECT=$((SUSPECT + 1))
else
    echo -e "  ${GREEN}[正常] 未发现挖矿进程${NC}"
fi

echo ""
echo -e "${YELLOW}[5/5] 检查异常网络连接...${NC}"
POOL_CONN=$(ss -tpn | grep -iE '3333|4444|5555|7777|8888|9999|14444|45560' | head -20)
if [ -n "$POOL_CONN" ]; then
    echo -e "  ${RED}[警告] 发现连接到矿池常用端口:${NC}"
    echo "$POOL_CONN"
    SUSPECT=$((SUSPECT + 1))
else
    echo -e "  ${GREEN}[正常] 未发现可疑网络连接${NC}"
fi

echo ""
echo "========================================="
if [ "$SUSPECT" -gt 0 ]; then
    echo -e "${RED}  检测到 $SUSPECT 项可疑！建议进一步排查${NC}"
    exit 1
else
    echo -e "${GREEN}  全部正常，kworker 是合法内核线程${NC}"
    exit 0
fi
echo "========================================="
