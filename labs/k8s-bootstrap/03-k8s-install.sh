#!/bin/bash
# ==========================================
# 阶段 3：安装 kubeadm、kubelet、kubectl
# 修复：锁定精确版本号，避免与 04 脚本版本不一致
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo ">>> 正在通过 sudo 提权执行..."
    exec sudo "$0" "$@"
fi

set -e

# 【P1 修复】统一精确版本号，与 04-kubeadm-init.sh 的 K8S_VER 保持一致
K8S_MINOR="v1.32"          # 用于仓库 URL
K8S_PATCH="1.32.13"        # 用于锁定具体版本

echo ">>> [1/3] 添加 Kubernetes 官方仓库..."
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
EOF

echo ">>> [2/3] 安装组件（锁定 ${K8S_PATCH}）..."
dnf makecache -q
dnf install -y -q \
    "kubelet-${K8S_PATCH}" \
    "kubeadm-${K8S_PATCH}" \
    "kubectl-${K8S_PATCH}"
systemctl enable kubelet

echo ">>> [3/3] 验证安装..."
echo ""
echo "✅ 阶段 3 完成！版本信息："
kubeadm version -o short
kubectl version --client -o yaml | grep gitVersion | head -1