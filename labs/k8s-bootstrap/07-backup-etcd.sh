#!/bin/bash
# ==========================================
# etcd 快照备份（已实战验证：单节点集群 2.3MB/次）
# 修复：宿主机无 etcdctl 时走 kubectl exec + hostPath 复制
#       绕过 distroless 镜像无 tar 的限制
# 依赖：kubectl（以 SUDO_USER 身份执行）
# ==========================================

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

REAL_USER="${SUDO_USER:-$USER}"
BACKUP_DIR="/data/backups/etcd"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_NAME="etcd-$TIMESTAMP.db"
SNAPSHOT_PATH="$BACKUP_DIR/$SNAPSHOT_NAME"

mkdir -p "$BACKUP_DIR"

# 【关键】etcd 数据目录（kubeadm 默认 hostPath 挂载）
HOST_ETCD_DIR="/var/lib/etcd"

if command -v etcdctl > /dev/null 2>&1; then
    echo ">>> 使用宿主机 etcdctl 生成快照..."
    ETCDCTL_API=3 etcdctl snapshot save "$SNAPSHOT_PATH" \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key
else
    echo ">>> 宿主机无 etcdctl，走 kubectl exec + hostPath 复制..."

    # 1. 找到 etcd Pod
    ETCD_POD=$(sudo -u "$REAL_USER" kubectl -n kube-system get pods \
        -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$ETCD_POD" ]; then
        echo "❌ 未找到 etcd Pod，请检查集群状态"
        exit 1
    fi
    echo "  etcd Pod: $ETCD_POD"

    # 2. 通过 kubectl exec 在容器内生成快照到 /var/lib/etcd（hostPath）
    sudo -u "$REAL_USER" kubectl -n kube-system exec "$ETCD_POD" -- \
        etcdctl snapshot save "$HOST_ETCD_DIR/$SNAPSHOT_NAME" \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key

    # 3. 【修复】快照文件已经出现在宿主机 hostPath 目录下，直接 mv
    #    不再使用 kubectl cp（因为 distroless 容器无 tar）
    if [ -f "$HOST_ETCD_DIR/$SNAPSHOT_NAME" ]; then
        mv "$HOST_ETCD_DIR/$SNAPSHOT_NAME" "$SNAPSHOT_PATH"
        echo "  ✅ 快照已从 hostPath 移动到备份目录"
    else
        echo "❌ 快照文件未出现在 $HOST_ETCD_DIR，可能 hostPath 被修改"
        exit 1
    fi
fi

echo ""
echo ">>> 清理 7 天前的旧快照..."
find "$BACKUP_DIR" -name "etcd-*.db" -mtime +7 -delete

echo ""
echo "✅ etcd 快照完成：$SNAPSHOT_PATH"
ls -lh "$BACKUP_DIR"