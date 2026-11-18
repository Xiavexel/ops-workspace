#!/bin/bash
# ==========================================
# 完整灾难恢复：重装系统后从备份重建集群
# 前置：
#   1. 已重装 Rocky Linux 10
#   2. 备份已拷贝到 /data/backups/<时间戳>/
#   3. 已跑完 01、02、03 阶段脚本
# ==========================================

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

if [ -z "$1" ] || [ ! -d "$1" ]; then
    echo "用法: $0 <备份目录>"
    echo "例如: $0 /data/backups/20260916-033702"
    exit 1
fi

BACKUP_DIR="$1"

# ========== 新增：可调参数（优先读取环境变量） ==========
API_IP="${API_IP:-192.168.2.22}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
K8S_VER="${K8S_VER:-v1.32.13}"
IMAGE_REPO="${IMAGE_REPO:-registry.aliyuncs.com/google_containers}"
# =======================================================

echo ">>> [0/8] 前置检查..."
command -v kubeadm > /dev/null || { echo "❌ 请先安装 kubeadm（跑完 03-k8s-install.sh）"; exit 1; }
command -v containerd > /dev/null || { echo "❌ 请先安装 containerd（跑完 02）"; exit 1; }
[ -f "$BACKUP_DIR/k8s-pki.tar.gz" ] || { echo "❌ 备份缺少 pki"; exit 1; }
tar tzf "$BACKUP_DIR/k8s-pki.tar.gz" > /dev/null 2>&1 || { echo "❌ pki 备份损坏"; exit 1; }
echo "  ✅ 前置检查通过"

echo ">>> [1/8] 停止 containerd 和 kubelet..."
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd
echo "  ✅ 服务已停止"

echo ">>> [2/8] 恢复 containerd 配置..."
tar xzf "$BACKUP_DIR/k8s-configs.tar.gz" -C / etc/containerd/config.toml
systemctl start containerd
sleep 3
echo "  containerd: $(systemctl is-active containerd)"

echo ">>> [3/8] 清理旧的 K8s 状态..."
rm -rf /etc/kubernetes/manifests/* 2>/dev/null || true
rm -rf /var/lib/etcd /var/lib/kubelet/* /etc/cni/net.d 2>/dev/null || true
rm -rf /etc/kubernetes/pki
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -X 2>/dev/null || true
echo "  ✅ 清理完成"

echo ">>> [4/8] 恢复 K8s 证书（P0）..."
mkdir -p /etc/kubernetes
tar xzf "$BACKUP_DIR/k8s-pki.tar.gz" -C /etc/kubernetes
chown -R root:root /etc/kubernetes/pki
chmod 600 /etc/kubernetes/pki/*.key 2>/dev/null || true
chmod 600 /etc/kubernetes/pki/etcd/*.key 2>/dev/null || true
echo "  ✅ 证书已恢复"

echo ">>> [5/8] 恢复 K8s 配置文件..."
tar xzf "$BACKUP_DIR/k8s-configs.tar.gz" -C / \
    etc/kubernetes/admin.conf \
    etc/kubernetes/super-admin.conf \
    etc/kubernetes/kubelet.conf \
    etc/kubernetes/bootstrap-kubelet.conf \
    etc/kubernetes/controller-manager.conf \
    etc/kubernetes/scheduler.conf \
    2>/dev/null || true
echo "  ✅ kubeconfig 已恢复"

echo ">>> [6/8] 恢复系统配置（含 Docker）..."
tar xzf "$BACKUP_DIR/k8s-configs.tar.gz" -C / \
    etc/default/grub etc/sysctl.d/k8s.conf \
    etc/modules-load.d/k8s.conf etc/hosts \
    etc/docker/daemon.json 2>/dev/null || true
sysctl --system > /dev/null 2>&1 || true

# 如果备份里有 Docker 配置，启动 Docker
if [ -f /etc/docker/daemon.json ]; then
    systemctl restart docker 2>/dev/null || true
    echo "  ✅ Docker 配置已恢复并重启"
fi
echo "  ✅ 系统配置已恢复"

echo ">>> [7/8] 重新初始化控制平面（复用已有证书）..."
kubeadm init \
    --apiserver-advertise-address=$API_IP \
    --image-repository=$IMAGE_REPO \
    --pod-network-cidr=$POD_CIDR \
    --kubernetes-version=$K8S_VER \
    --ignore-preflight-errors=all
echo "  ✅ 集群初始化完成"

echo ">>> [8/8] 恢复源配置 + 保存 join 命令..."
tar xzf "$BACKUP_DIR/repo-configs.tar.gz" -C / 2>/dev/null || true
kubeadm token create --print-join-command > /root/kubeadm-join.sh 2>/dev/null || true
chmod 600 /root/kubeadm-join.sh 2>/dev/null || true
echo "  ✅ 完成"

echo ""
echo "=========================================="
echo "✅ 灾难恢复完成！"
echo "=========================================="
echo ""
echo ">>> 后续步骤（以普通用户执行，不要 sudo）："
echo "  cd ~/k8s-bootstrap && ./05-post-init.sh"