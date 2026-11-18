#!/bin/bash
# ==========================================
# K8s 集群备份脚本 v3
# 功能：备份证书、配置、源信息，并生成恢复说明
# 修复：tar -C 用法 / README 引用路径 / 空 tar 检测 / 旧备份清理
# ==========================================

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

set -e

# ========== 可调参数 ==========
BACKUP_ROOT="/data/backups"
KEEP_DAYS=30                   # 保留最近 30 天的备份，0 表示不清理
# ==============================

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

echo ">>> [1/5] 备份 K8s 证书（P0 核心资产）..."
tar czf "$BACKUP_DIR/k8s-pki.tar.gz" -C /etc/kubernetes pki
chmod 600 "$BACKUP_DIR/k8s-pki.tar.gz"
echo "    $(du -sh "$BACKUP_DIR/k8s-pki.tar.gz" | awk '{print $1}')"

echo ">>> [2/5] 备份 K8s 配置文件..."

# 待备份文件清单（相对 / 的路径）
FILES_TO_BACKUP=(
    etc/kubernetes/admin.conf
    etc/kubernetes/super-admin.conf
    etc/kubernetes/kubelet.conf
    etc/kubernetes/bootstrap-kubelet.conf
    etc/kubernetes/controller-manager.conf
    etc/kubernetes/scheduler.conf
    etc/containerd/config.toml
    etc/docker/daemon.json
    etc/default/grub
    etc/sysctl.d/k8s.conf
    etc/modules-load.d/k8s.conf
    etc/hosts
)

# 过滤出实际存在的文件（跳过可能被 kubeadm 清理的）
EXISTING_FILES=()
SKIPPED_FILES=()
for f in "${FILES_TO_BACKUP[@]}"; do
    if [ -e "/$f" ]; then
        EXISTING_FILES+=("$f")
    else
        SKIPPED_FILES+=("$f")
    fi
done

# 报告跳过项
if [ ${#SKIPPED_FILES[@]} -gt 0 ]; then
    echo "    ⚠️  以下文件不存在，已跳过："
    for f in "${SKIPPED_FILES[@]}"; do
        echo "       - /$f"
    done
fi

# 执行备份（只有在有文件时才执行）
if [ ${#EXISTING_FILES[@]} -eq 0 ]; then
    echo "❌ 没有可备份的文件"
    exit 1
fi

tar czf "$BACKUP_DIR/k8s-configs.tar.gz" -C / "${EXISTING_FILES[@]}"

CONFIG_COUNT=$(tar tzf "$BACKUP_DIR/k8s-configs.tar.gz" | wc -l)
echo "    文件数: $CONFIG_COUNT"

# 【新增】检测配置文件包是否为空，防止 tar -C 用法回归
if [ "$CONFIG_COUNT" -lt 5 ]; then
    echo "❌ k8s-configs.tar.gz 只有 $CONFIG_COUNT 个文件，可能为空！"
    echo "   请检查 tar -C 用法是否正确"
    exit 1
fi

echo ">>> [3/5] 备份 yum 源和 crictl 配置..."
tar czf "$BACKUP_DIR/repo-configs.tar.gz" -C / \
    etc/yum.repos.d/docker-ce.repo \
    etc/yum.repos.d/kubernetes.repo \
    etc/crictl.yaml
REPO_COUNT=$(tar tzf "$BACKUP_DIR/repo-configs.tar.gz" | wc -l)
echo "    文件数: $REPO_COUNT"

echo ">>> [4/5] 生成恢复说明..."
# 【修复】引用路径改为归档后的 08/09 脚本名
cat > "$BACKUP_DIR/README.txt" <<EOF
================================================
K8s 集群备份元信息
================================================
备份时间：$(date)
主机名：$(hostname)
K8s 版本：$(kubeadm version -o short 2>/dev/null)
containerd 数据目录：$(grep '^root' /etc/containerd/config.toml)
Cgroup 驱动：$(grep 'SystemdCgroup' /etc/containerd/config.toml | head -1 | tr -d ' ')
sandbox 镜像：$(containerd config dump 2>/dev/null | grep "sandbox = " | head -1 | tr -d ' ')

备份文件：
  - k8s-pki.tar.gz        集群证书（P0，20K+）
  - k8s-configs.tar.gz    K8s 和系统配置（${CONFIG_COUNT} 个文件）
  - repo-configs.tar.gz   dnf 源和 crictl 配置（${REPO_COUNT} 个文件）

================================================
恢复方式
================================================
场景 A：配置误改（当前系统运行中）
  sudo ~/k8s-bootstrap/08-restore-configs.sh $BACKUP_DIR

场景 B：灾难恢复（重装系统后）
  # 先跑 01~03 阶段脚本
  sudo ~/k8s-bootstrap/09-restore-full.sh $BACKUP_DIR
  # 再以普通用户执行
  ~/k8s-bootstrap/05-post-init.sh

⚠️ 恢复前请先备份当前状态（08 脚本会自动做），
   或参考 ~/k8s-bootstrap/README.md 的完整说明。
EOF

echo ">>> [5/5] 清理旧备份（保留最近 ${KEEP_DAYS} 天）..."
if [ "$KEEP_DAYS" -gt 0 ]; then
    # 只清理纯时间戳格式的备份目录，不碰 rollback-* 目录
    find "$BACKUP_ROOT" -maxdepth 1 -type d \
        -name "20[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*" \
        -mtime +${KEEP_DAYS} \
        -exec rm -rf {} + 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "✅ 备份完成：$BACKUP_DIR"
echo "=========================================="
ls -lh "$BACKUP_DIR"
echo ""
echo "总大小：$(du -sh "$BACKUP_DIR" | awk '{print $1}')"
echo ""
echo "现有备份列表（最近 5 个）："
ls -1dt "$BACKUP_ROOT"/20*/ 2>/dev/null | head -5