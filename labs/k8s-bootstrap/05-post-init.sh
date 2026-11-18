#!/bin/bash
# ==========================================
# 阶段 5：kubectl 认证 + 网络插件 + 单节点调度
# 修复：cp -i 卡住问题、Flannel 网络容错
# ==========================================

# kubectl 认证必须以普通用户执行，不要 sudo
if [ "$EUID" -eq 0 ]; then
    echo "❌ 请勿用 sudo 执行此脚本！"
    echo "   kubectl 认证需要写入当前用户的 \$HOME/.kube/"
    echo "   请直接执行：./05-post-init.sh（不要加 sudo）"
    exit 1
fi

set -e
echo ">>> [1/4] 配置 kubectl 认证（当前用户 $USER）..."
mkdir -p "$HOME/.kube"

# 【P0 修复】直接 rm -f，避免 set -e 在文件不存在时退出脚本
rm -f "$HOME/.kube/config"

sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
echo "  ✅ kubectl 配置已写入 $HOME/.kube/config"

echo ">>> [2/4] 查看节点状态（此时应该是 NotReady）..."
kubectl get nodes

echo ">>> [3/4] 部署 Flannel 网络插件..."
if curl -sSLf -o /tmp/kube-flannel.yml \
    https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml; then
    kubectl apply -f /tmp/kube-flannel.yml
else
    echo "  ⚠️  GitHub 拉取失败，尝试镜像加速..."
    if curl -sSLf -o /tmp/kube-flannel.yml \
        https://gh-proxy.com/https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml; then
        kubectl apply -f /tmp/kube-flannel.yml
    else
        echo "  ❌ 所有源都失败，请手动下载 kube-flannel.yml 后执行："
        echo "     kubectl apply -f kube-flannel.yml"
        exit 1
    fi
fi

echo ">>> [4/4] 移除控制平面污点（单节点集群专用）..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo ""
echo "✅ 阶段 5 完成！等待 1-2 分钟让 Flannel 启动，然后执行："
echo "   kubectl get nodes          # 应为 Ready"
echo "   kubectl get pods -A        # 所有 Pod 应 Running"