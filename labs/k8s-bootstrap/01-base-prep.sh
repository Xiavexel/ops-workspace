#!/bin/bash
# ==========================================
# 阶段 1：Rocky Linux 10 基础环境准备
# 功能：主机名、SELinux、防火墙、Swap、内核参数、国内 dnf 源
# 修复：metalink 处理 + sysctl 容错 + 缓存清理
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo ">>> 正在通过 sudo 提权执行..."
    exec sudo "$0" "$@"
fi

set -e
echo ">>> [1/6] 设置主机名..."
NEW_HOSTNAME="${NEW_HOSTNAME:-xia-server}"
hostnamectl set-hostname "$NEW_HOSTNAME"
grep -q "127.0.0.1.*$NEW_HOSTNAME" /etc/hosts || echo "127.0.0.1   $NEW_HOSTNAME" >> /etc/hosts

echo ">>> [2/6] 关闭 SELinux（宽容模式）..."
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
sed -i 's/^SELINUX=disabled/SELINUX=permissive/' /etc/selinux/config

# 【新增】安装 SELinux 管理工具（提供 semanage 等命令）
# 用于 Cockpit SELinux 页面和后续策略调整
echo "  - 安装 policycoreutils-python-utils（提供 semanage）..."
dnf install -y -q policycoreutils-python-utils || true

echo ">>> [3/6] 关闭防火墙（练手环境）..."
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

echo ">>> [4/6] 关闭 Swap..."
swapoff -a 2>/dev/null || true
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo ">>> [5/6] 配置内核模块与网络参数..."
modprobe overlay
modprobe br_netfilter

cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# 【修复】sysctl --system 遇到不支持参数会返回非 0，加容错
sysctl --system > /dev/null 2>&1 || true

echo ">>> [6/6] 配置国内 dnf 源..."
if [ ! -d /etc/yum.repos.d.bak ]; then
    cp -r /etc/yum.repos.d /etc/yum.repos.d.bak
fi

# 【修复】Rocky 10 默认用 metalink，必须一起处理
sed -i 's|^metalink=|#metalink=|g' /etc/yum.repos.d/rocky*.repo
sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/rocky*.repo
# 【P2 修复】兼容 http/https 和变量路径的 baseurl
sed -i 's|^#baseurl=.*dl\.rockylinux\.org|baseurl=https://mirrors.aliyun.com/rockylinux|g' \
    /etc/yum.repos.d/rocky*.repo

# 清缓存 + 重建
dnf clean all > /dev/null 2>&1 || true
dnf makecache -q

echo ""
echo "✅ 阶段 1 完成！验证："
echo "  - 主机名: $(hostname)"
echo "  - Swap 状态: $(swapon --show 2>/dev/null | wc -l) 行（0 表示已关）"
echo "  - ip_forward: $(sysctl -n net.ipv4.ip_forward)"
echo "  - SELinux: $(getenforce)"
echo "  - 启用的 dnf 仓库数: $(dnf repolist enabled 2>/dev/null | tail -n +2 | wc -l)"