#!/bin/bash
# ==========================================
# 配置级恢复：从备份恢复配置文件
# 场景：当前系统运行中，配置被误改
# 不影响 K8s 集群数据
# ==========================================

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

if [ -z "$1" ] || [ ! -d "$1" ]; then
    echo "用法: $0 <备份目录>"
    echo "例如: $0 /data/backups/20260916-033702"
    echo ""
    echo "可用备份："
    ls -1dt /data/backups/*/ 2>/dev/null | head -10
    exit 1
fi

BACKUP_DIR="$1"

echo ">>> 校验备份完整性..."
for f in k8s-pki.tar.gz k8s-configs.tar.gz repo-configs.tar.gz; do
    [ -f "$BACKUP_DIR/$f" ] || { echo "❌ 缺少 $f"; exit 1; }
done
tar tzf "$BACKUP_DIR/k8s-configs.tar.gz" > /dev/null 2>&1 || { echo "❌ k8s-configs 损坏"; exit 1; }
echo "  ✅ 备份完整"

echo ""
echo ">>> 即将恢复以下内容（会覆盖当前）："
echo "   - /etc/kubernetes/*.conf"
echo "   - /etc/containerd/config.toml"
echo "   - /etc/docker/daemon.json"
echo "   - /etc/default/grub"
echo "   - /etc/sysctl.d/k8s.conf / /etc/modules-load.d/k8s.conf"
echo "   - /etc/hosts"
echo "   - /etc/yum.repos.d/{docker-ce,kubernetes}.repo / /etc/crictl.yaml"
read -p ">>> 输入 yes 确认继续: " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "已取消" && exit 0

# 保存当前状态（回滚用）
ROLLBACK="/data/backups/rollback-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ROLLBACK"
echo ""
echo ">>> [1/5] 保存当前状态到 $ROLLBACK..."
tar czf "$ROLLBACK/current-configs.tar.gz" -C / \
    etc/kubernetes etc/containerd/config.toml etc/docker/daemon.json \
    etc/default/grub etc/sysctl.d/k8s.conf \
    etc/modules-load.d/k8s.conf etc/hosts 2>/dev/null
echo "  ✅ 回滚快照已保存"

echo ">>> [2/5] 是否恢复 pki 证书？"
read -p ">>> （仅集群重建时选 y，日常恢复选 N）[y/N]: " RESTORE_PKI
if [ "$RESTORE_PKI" = "y" ] || [ "$RESTORE_PKI" = "Y" ]; then
    tar xzf "$BACKUP_DIR/k8s-pki.tar.gz" -C /etc/kubernetes
    chown -R root:root /etc/kubernetes/pki
    chmod 600 /etc/kubernetes/pki/*.key /etc/kubernetes/pki/etcd/*.key 2>/dev/null || true
    echo "  ✅ 证书已恢复"
else
    echo "  ⏭  跳过证书恢复"
fi

echo ">>> [3/5] 恢复 K8s 配置文件..."
tar xzf "$BACKUP_DIR/k8s-configs.tar.gz" -C /
echo "  ✅ 完成"

echo ">>> [4/5] 恢复源配置..."
tar xzf "$BACKUP_DIR/repo-configs.tar.gz" -C /
echo "  ✅ 完成"

echo ">>> [5/5] 重载服务..."
systemctl daemon-reload
systemctl restart containerd
systemctl restart docker 2>/dev/null || true
sleep 2
echo "  containerd: $(systemctl is-active containerd)"
echo "  docker:     $(systemctl is-active docker 2>/dev/null || echo '未安装')"

echo ""
echo "=========================================="
echo "✅ 配置恢复完成"
echo "=========================================="
echo ""
echo ">>> 集群状态："
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" = "root" ]; then
    kubectl get nodes 2>/dev/null || echo "  (等待 apiserver 重启，30 秒后重试)"
else
    sudo -u "$REAL_USER" kubectl get nodes 2>/dev/null || echo "  (等待 apiserver 重启，30 秒后重试)"
fi
echo ""
echo ">>> 回滚命令（如果出问题）："
echo "  tar xzf $ROLLBACK/current-configs.tar.gz -C /"
echo "  systemctl restart containerd kubelet"