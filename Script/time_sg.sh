#!/bin/bash
# ==============================================================================
# 脚本名称: time_sg.sh
# 脚本版本: v1.0.1
# 脚本功能: 在 Debian 系统中一键设置新加坡时区并同步系统时间
# 适用系统: Debian 10/11/12 (也适用于基于 Debian 的发行版如 Ubuntu)
# ==============================================================================

# 定义版本号
VERSION="v1.0.1"

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本需要 root 权限执行。请使用 sudo 运行。"
   echo "示例: sudo $0"
   exit 1
fi

echo "======================================"
echo " 系统时间同步与时区设置脚本 ($VERSION)"
echo " 目标时区: Asia/Singapore (新加坡)"
echo "======================================"

# 1. 更新软件包列表并确保 NTP / chrony 已安装
echo "[1/4] 正在检查并安装时间同步工具..."
apt-get update -y > /dev/null 2>&1

# 优先安装 chrony（现代 Debian 默认），如果不支持则回退到 ntp
if ! apt-get install -y chrony > /dev/null 2>&1; then
    apt-get install -y ntp > /dev/null 2>&1
fi

# 2. 设置时区为新加坡 (Asia/Singapore)
echo "[2/4] 正在设置系统时区为 Asia/Singapore..."
# 检查 timedatectl 是否可用
if command -v timedatectl > /dev/null 2>&1; then
    timedatectl set-timezone Asia/Singapore
else
    # 回退方案：直接操作时区文件
    rm -f /etc/localtime
    ln -s /usr/share/zoneinfo/Asia/Singapore /etc/localtime
    echo "Asia/Singapore" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata > /dev/null 2>&1
fi

# 3. 强制立即同步时间
echo "[3/4] 正在强制同步时间..."
# 判断系统使用的是 chrony 还是 ntpd 并强制同步
if systemctl is-active --quiet chronyd 2>/dev/null; then
    chronyc makestep > /dev/null 2>&1
elif systemctl is-active --quiet ntpd 2>/dev/null; then
    ntpd -gq > /dev/null 2>&1
else
    # 如果服务未运行，尝试启动 chronyd 并同步
    systemctl enable chronyd > /dev/null 2>&1
    systemctl start chronyd > /dev/null 2>&1
    sleep 1
    chronyc makestep > /dev/null 2>&1
fi

# 4. 显示当前时间状态
echo "[4/4] 设置完成！当前系统时间与时区信息如下："
timedatectl 2>/dev/null || date

echo "======================================"
echo " 脚本执行完毕 ($VERSION)"
echo "======================================"
