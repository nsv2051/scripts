#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# 显示标题
display_header() {
    clear
    echo -e "${GREEN}"
    echo "========================================"
    echo "   Linux 系统管理脚本 v1.1"
    echo "========================================"
    echo -e "${NC}"
}

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}此操作需要管理员权限，请用sudo执行或切换root用户！${NC}"
        return 1
    fi
    return 0
}

# 电源管理
power_management() {
    while true; do
        display_header
        echo -e "${BLUE}电源管理选项：${NC}"
        echo "1) 立即关机"
        echo "2) 立即重启"
        echo "3) 返回主菜单"
        read -p "请选择操作: " power_choice

        case $power_choice in
            1)
                check_root && shutdown now
                break
                ;;
            2)
                check_root && shutdown -r now
                break
                ;;
            3)
                break
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${NC}"
                sleep 1
                ;;
        esac
    done
}

# 磁盘检查
disk_check() {
    display_header
    echo -e "${YELLOW}磁盘使用情况：${NC}"
    df -h

    echo -e "\n${YELLOW}目录大小检查：${NC}"
    read -p "输入要检查的目录路径（默认/）： " directory
    directory=${directory:-/}
    du -sh $directory 2>/dev/null || echo -e "${RED}无法读取目录！${NC}"

    read -n 1 -s -r -p "按任意键继续..."
}

# 资源监控
resource_monitor() {
    while true; do
        display_header
        echo -e "${BLUE}资源监控选项：${NC}"
        echo "1) 实时进程监控（top）"
        echo "2) 内存使用情况"
        echo "3) 返回主菜单"
        read -p "请选择操作: " res_choice

        case $res_choice in
            1)
                top -o %CPU
                ;;
            2)
                echo -e "\n${YELLOW}内存使用：${NC}"
                free -h
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            3)
                break
                ;;
            *)
                echo -e "${RED}无效选项！${NC}"
                sleep 1
                ;;
        esac
    done
}

# 网络诊断
network_check() {
    display_header
    echo -e "${YELLOW}网络接口信息：${NC}"
    ip addr show

    echo -e "\n${YELLOW}网络连通性测试：${NC}"
    read -p "输入要测试的IP/域名（默认8.8.8.8）： " target
    target=${target:-8.8.8.8}
    ping -c 4 $target

    echo -e "\n${YELLOW}路由追踪：${NC}"
    if command -v traceroute &> /dev/null; then
        traceroute $target
    else
        echo -e "${RED}traceroute 未安装，请先安装！${NC}"
    fi

    read -n 1 -s -r -p "按任意键继续..."
}

# 更换软件源
change_repo() {
    display_header
    check_root || return

    echo -e "${YELLOW}可用的软件源镜像：${NC}"
    echo "1) 阿里云"
    echo "2) 腾讯云"
    echo "3) 华为云"
    echo "4) 清华大学"
    echo "5) 网易"
    echo "6) 中科大"
    read -p "请选择软件源镜像 (1-6): " repo_choice

    case $repo_choice in
        1) mirror="http://mirrors.aliyun.com" ;;
        2) mirror="http://mirrors.tencent.com" ;;
        3) mirror="http://mirrors.huaweicloud.com" ;;
        4) mirror="https://mirrors.tuna.tsinghua.edu.cn" ;;
        5) mirror="http://mirrors.163.com" ;;
        6) mirror="https://mirrors.ustc.edu.cn" ;;
        *) 
            echo -e "${RED}无效选项，使用默认源${NC}"
            return
            ;;
    esac

    # 备份原有源
    if [ -f "/etc/apt/sources.list" ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        echo -e "${GREEN}已备份原有源到 /etc/apt/sources.list.bak${NC}"
    fi

    # 根据系统生成新源
    release=$(lsb_release -cs)
    echo -e "${BLUE}正在设置 $mirror 为软件源...${NC}"

    cat > /etc/apt/sources.list <<EOF
deb $mirror/ubuntu/ $release main restricted universe multiverse
deb $mirror/ubuntu/ $release-updates main restricted universe multiverse
deb $mirror/ubuntu/ $release-backports main restricted universe multiverse
deb $mirror/ubuntu/ $release-security main restricted universe multiverse
EOF

    echo -e "${GREEN}软件源已更新！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 更新软件包
update_packages() {
    display_header
    check_root || return

    echo -e "${BLUE}正在更新软件包列表...${NC}"
    apt update

    echo -e "\n${BLUE}正在升级已安装的软件包...${NC}"
    apt upgrade -y

    echo -e "\n${GREEN}软件包更新完成！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 更新系统
update_system() {
    display_header
    check_root || return

    echo -e "${BLUE}正在执行系统更新...${NC}"
    apt update && apt full-upgrade -y && apt autoremove -y

    echo -e "\n${GREEN}系统更新完成！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 设置系统DNS
set_dns() {
    display_header
    check_root || return

    echo -e "${YELLOW}当前DNS配置：${NC}"
    cat /etc/resolv.conf

    echo -e "\n${BLUE}DNS服务器选项：${NC}"
    echo "1) Google DNS (8.8.8.8, 8.8.4.4)"
    echo "2) Cloudflare DNS (1.1.1.1, 1.0.0.1)"
    echo "3) 阿里DNS (223.5.5.5, 223.6.6.6)"
    echo "4) 自定义DNS"
    read -p "请选择DNS服务器 (1-4): " dns_choice

    case $dns_choice in
        1) 
            dns1="8.8.8.8"
            dns2="8.8.4.4"
            ;;
        2)
            dns1="1.1.1.1"
            dns2="1.0.0.1"
            ;;
        3)
            dns1="223.5.5.5"
            dns2="223.6.6.6"
            ;;
        4)
            read -p "输入主DNS服务器: " dns1
            read -p "输入备用DNS服务器: " dns2
            ;;
        *)
            echo -e "${RED}无效选项，未更改DNS设置${NC}"
            return
            ;;
    esac

    # 备份原有配置
    if [ -f "/etc/resolv.conf" ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
        echo -e "${GREEN}已备份原有DNS配置到 /etc/resolv.conf.bak${NC}"
    fi

    # 设置新DNS
    echo "nameserver $dns1" > /etc/resolv.conf
    echo "nameserver $dns2" >> /etc/resolv.conf

    echo -e "\n${GREEN}DNS设置已更新！${NC}"
    echo -e "${YELLOW}新的DNS配置：${NC}"
    cat /etc/resolv.conf
    read -n 1 -s -r -p "按任意键继续..."
}

# 配置CPU电源管理P-State状态
configure_pstate() {
    display_header
    check_root || return

    echo -e "${YELLOW}当前CPU频率信息：${NC}"
    cpupower frequency-info

    echo -e "\n${BLUE}P-State配置选项：${NC}"
    echo "1) 性能模式 (performance)"
    echo "2) 节能模式 (powersave)"
    echo "3) 平衡模式 (ondemand)"
    echo "4) 自定义调速器"
    read -p "请选择P-State模式 (1-4): " pstate_choice

    case $pstate_choice in
        1) governor="performance" ;;
        2) governor="powersave" ;;
        3) governor="ondemand" ;;
        4)
            read -p "输入自定义调速器: " governor
            ;;
        *)
            echo -e "${RED}无效选项，未更改P-State设置${NC}"
            return
            ;;
    esac

    # 设置调速器
    if cpupower frequency-set -g $governor &>/dev/null; then
        echo -e "\n${GREEN}已设置CPU调速器为 $governor${NC}"
    else
        echo -e "\n${RED}设置失败，请检查是否安装了cpufrequtils${NC}"
    fi

    echo -e "\n${YELLOW}更新后的CPU频率信息：${NC}"
    cpupower frequency-info
    read -n 1 -s -r -p "按任意键继续..."
}

# 配置CPU工作模式
configure_cpu_mode() {
    display_header
    check_root || return

    echo -e "${YELLOW}当前CPU信息：${NC}"
    lscpu

    echo -e "\n${BLUE}CPU工作模式选项：${NC}"
    echo "1) 启用所有CPU核心"
    echo "2) 禁用超线程"
    echo "3) 启用性能模式"
    echo "4) 返回主菜单"
    read -p "请选择CPU工作模式 (1-4): " cpu_choice

    case $cpu_choice in
        1)
            echo -e "\n${BLUE}正在启用所有CPU核心...${NC}"
            max_cores=$(nproc --all)
            for ((core=0; core<max_cores; core++)); do
                echo 1 > /sys/devices/system/cpu/cpu$core/online
            done
            echo -e "${GREEN}已启用所有CPU核心${NC}"
            ;;
        2)
            echo -e "\n${BLUE}正在禁用超线程...${NC}"
            for cpu in /sys/devices/system/cpu/cpu*/topology/thread_siblings_list; do
                echo 0 > $cpu 2>/dev/null
            done
            echo -e "${GREEN}已禁用超线程${NC}"
            ;;
        3)
            echo -e "\n${BLUE}正在启用性能模式...${NC}"
            echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
            echo -e "${GREEN}已启用性能模式${NC}"
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}无效选项！${NC}"
            ;;
    esac

    echo -e "\n${YELLOW}更新后的CPU信息：${NC}"
    lscpu
    read -n 1 -s -r -p "按任意键继续..."
}

# 通过SLAAC获取IPv6
enable_slaac_ipv6() {
    display_header
    check_root || return

    echo -e "${YELLOW}当前网络接口：${NC}"
    ip -6 addr show

    read -p "输入要配置IPv6的网络接口名称 (如eth0): " interface

    if ! ip link show $interface &>/dev/null; then
        echo -e "${RED}无效的网络接口！${NC}"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    # 启用IPv6
    echo -e "\n${BLUE}正在启用IPv6...${NC}"
    sysctl -w net.ipv6.conf.$interface.disable_ipv6=0

    # 配置SLAAC
    echo -e "\n${BLUE}正在配置SLAAC...${NC}"
    sysctl -w net.ipv6.conf.$interface.autoconf=1
    sysctl -w net.ipv6.conf.$interface.accept_ra=2

    echo -e "\n${GREEN}已为 $interface 启用SLAAC IPv6${NC}"
    echo -e "\n${YELLOW}更新后的IPv6配置：${NC}"
    ip -6 addr show $interface
    read -n 1 -s -r -p "按任意键继续..."
}

# 幂等写入 ini 风格键值：已存在则整行替换，否则插入 [Time] 后或追加
set_conf_kv() {
    local file="$1" key="$2" value="$3" esc
    [ -f "$file" ] || return 1
    esc=$(printf '%s' "$value" | sed 's/[\\|&]/\\&/g')
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key}=${esc}|" "$file"
    elif grep -qE '^[[:space:]]*\[Time\][[:space:]]*$' "$file"; then
        sed -i -E "/^[[:space:]]*\[Time\][[:space:]]*$/a ${key}=${esc}" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# 设置NTP自动校时服务器
configure_ntp() {
    display_header
    check_root || return

    echo -e "${YELLOW}当前NTP服务器：${NC}"
    timedatectl show-timesync 2>/dev/null | grep -E '^Server' || echo "（当前无活动的 NTP 服务器）"

    echo -e "\n${BLUE}NTP服务器选项：${NC}"
    echo "1) 阿里云NTP"
    echo "2) 腾讯云NTP"
    echo "3) 国家授时中心"
    echo "4) 自定义NTP"
    read -p "请选择NTP服务器 (1-4): " ntp_choice

    case $ntp_choice in
        1) ntp="ntp.aliyun.com" ;;
        2) ntp="ntp.tencent.com" ;;
        3) ntp="cn.ntp.org.cn" ;;
        4)
            read -p "输入自定义NTP服务器: " ntp
            ;;
        *)
            echo -e "${RED}无效选项，未更改NTP设置${NC}"
            return
            ;;
    esac

    # 设置NTP
    timedatectl set-ntp true
    if [ -f "/etc/systemd/timesyncd.conf" ]; then
        set_conf_kv /etc/systemd/timesyncd.conf NTP "$ntp"
        set_conf_kv /etc/systemd/timesyncd.conf FallbackNTP "ntp.ubuntu.com"
        systemctl restart systemd-timesyncd
    else
        echo -e "${RED}未找到timesyncd.conf文件，可能需要手动配置${NC}"
    fi

    echo -e "\n${GREEN}已设置NTP服务器为 $ntp${NC}"
    echo -e "\n${YELLOW}更新后的NTP状态：${NC}"
    timedatectl status
    read -n 1 -s -r -p "按任意键继续..."
}

# 主菜单
while true; do
    display_header
    echo -e "${BLUE}主菜单：${NC}"
    echo "1) 电源管理"
    echo "2) 更换软件源"
    echo "3) 更新软件包"
    echo "4) 更新系统"
    echo "5) 设置系统DNS"
    echo "6) 磁盘检查"
    echo "7) 资源监控"
    echo "8) 网络诊断"
    echo "9) 退出脚本"
    echo "10) 配置CPU电源管理P-State状态"
    echo "11) 配置CPU工作模式"
    echo "12) 通过SLAAC获取IPv6"
    echo "15) 设置NTP自动校时服务器"
    read -p "请输入选项 (1-12,15): " main_choice

    case $main_choice in
        1)
            power_management
            ;;
        2)
            change_repo
            ;;
        3)
            update_packages
            ;;
        4)
            update_system
            ;;
        5)
            set_dns
            ;;
        6)
            disk_check
            ;;
        7)
            resource_monitor
            ;;
        8)
            network_check
            ;;
        9)
            echo -e "\n${GREEN}脚本已退出。${NC}"
            exit 0
            ;;
        10)
            configure_pstate
            ;;
        11)
            configure_cpu_mode
            ;;
        12)
            enable_slaac_ipv6
            ;;
        15)
            configure_ntp
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入！${NC}"
            sleep 1
            ;;
    esac
done
