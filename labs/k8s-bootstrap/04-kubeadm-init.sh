#!/bin/bash
# ==========================================
# 阶段 4：初始化 K8s 控制平面
# 前置：确保 sandbox 已指向阿里云（否则会超时）
# 修复：正确清理普通用户家目录 .kube、简化 sandbox 检测
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo ">>> 正在通过 sudo 提权执行..."
    exec sudo "$0" "$@"
fi

# 可修改参数
API_IP="192.168.2.22"
POD_CIDR="10.244.0.0/16"
K8S_VER="v1.32.13"
IMAGE_REPO="registry.aliyuncs.com/google_containers"

# 【修复】正确获取原用户家目录
REAL_USER="${SUDO_USER:-root}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# 前置检查：sandbox 必须指向阿里云
echo ">>> [预检] 检查 containerd sandbox 镜像..."
SANDBOX=$(containerd config dump 2>/dev/null | grep "sandbox = " | head -1)
if ! echo "$SANDBOX" | grep -q "aliyuncs"; then
    echo "❌ sandbox 仍指向：$SANDBOX"
    echo "   请先修正 /etc/containerd/config.toml"
    echo "   正确位置：[plugins.'io.containerd.cri.v1.images'.pinned_images]"
    exit 1
fi
echo "  ✅ sandbox: $SANDBOX"

echo ">>> [1/4] 清理可能存在的旧集群残留..."
kubeadm reset -f 2>/dev/null || true
rm -rf /etc/kubernetes/manifests/* 2>/dev/null || true
rm -rf /var/lib/etcd /var/lib/kubelet/* /etc/cni/net.d 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -X 2>/dev/null || true
ipvsadm --clear 2>/dev/null || true
crictl rmi --prune 2>/dev/null || true

# 【修复】清理 root 和原用户家目录的 .kube
rm -rf /root/.kube
if [ -n "$REAL_HOME" ] && [ "$REAL_HOME" != "/" ]; then
    rm -rf "$REAL_HOME/.kube"
fi

systemctl restart containerd
sleep 2

echo ">>> [2/4] 提前拉取控制平面镜像..."
kubeadm config images pull \
  --image-repository=$IMAGE_REPO \
  --kubernetes-version=$K8S_VER

echo ">>> [3/4] 开始初始化..."
kubeadm init \
  --apiserver-advertise-address=$API_IP \
  --image-repository=$IMAGE_REPO \
  --pod-network-cidr=$POD_CIDR \
  --kubernetes-version=$K8S_VER

echo ""
echo ">>> [4/4] 保存 join 命令供后续参考..."
kubeadm token create --print-join-command > /root/kubeadm-join.sh 2>/dev/null || true
chmod 600 /root/kubeadm-join.sh 2>/dev/null || true
echo "  join 命令已保存到 /root/kubeadm-join.sh"

echo ""
echo "✅ 阶段 4 完成！下一步执行 './05-post-init.sh'（不要 sudo）"