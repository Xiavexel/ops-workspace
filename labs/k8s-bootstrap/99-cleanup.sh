#!/bin/bash
# ==========================================
# 收尾清理：集群稳定后清理调试残留
# 前置：01~11 已跑完、集群 Ready、kubectl 已配置
# 用途：清理临时备份和一次性脚本，展示磁盘占用
# ==========================================
shopt -s nullglob  # 无匹配时展开为空，不保留字面量

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# 获取原用户信息
REAL_USER="${SUDO_USER:-$USER}"

if [ "$REAL_USER" = "root" ]; then
    echo "❌ 请以普通用户执行：./99-cleanup.sh（脚本内部会 sudo）"
    exit 1
fi
SUDO_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# 【P3 修复】用 && 替代已弃用的 -a
if [ -z "$SUDO_HOME" ] || [ "$SUDO_HOME" = "/" ] || \
   { [ "$SUDO_HOME" = "/root" ] && [ "$REAL_USER" != "root" ]; }; then
    echo "❌ 无法确定用户 $REAL_USER 的家目录（当前值：'$SUDO_HOME'），拒绝执行"
    exit 1
fi
echo ">>> 目标用户：$REAL_USER，家目录：$SUDO_HOME"

# 前置检查：集群必须 Ready 才允许清理
echo ">>> [预检] 确认集群状态..."
NODE_STATUS=$(sudo -u "$REAL_USER" kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
if [ "$NODE_STATUS" != "Ready" ]; then
    echo "❌ 集群未 Ready（当前：'$NODE_STATUS'），拒绝清理！"
    exit 1
fi
echo "  ✅ 集群状态：Ready"

echo ""
echo ">>> [1/4] 清理 containerd 配置备份..."
rm -fv /etc/containerd/config.toml.bak.* 2>/dev/null
rm -fv /etc/docker/daemon.json.bak.* 2>/dev/null

echo ">>> [2/4] 清理 GRUB 备份（如果有）..."
rm -fv /etc/default/grub.bak.* 2>/dev/null

echo ">>> [3/4] 清理一次性临时脚本..."
rm -fv "$SUDO_HOME"/fix-grub.sh 2>/dev/null
rm -fv "$SUDO_HOME"/fix-containerd.sh 2>/dev/null
rm -fv "$SUDO_HOME"/setup-containerd.sh 2>/dev/null
rm -fv "$SUDO_HOME"/bootstrap-k8s.sh 2>/dev/null

echo ">>> [4/4] 清理历史 kubeconfig 备份..."
rm -rfv "$SUDO_HOME"/.kube.bak.* 2>/dev/null
rm -rfv /root/.kube.bak.* 2>/dev/null

echo ""
echo "=========================================="
echo "✅ 清理完成！"
echo "=========================================="
echo ""
echo ">>> 保留项（不要删）："
echo "  - $SUDO_HOME/k8s-bootstrap/   （01~11 脚本）"
echo "  - /etc/yum.repos.d.bak        （dnf 源回滚兜底）"
echo "  - /etc/containerd/config.toml （当前生效配置）"
if [ -f /etc/docker/daemon.json ]; then echo "  - /etc/docker/daemon.json     （当前 Docker 配置）"; fi
if [ -d /data/docker ];            then echo "  - /data/docker                （Docker 数据目录，可能很大）"; fi
if [ -d /data/containerd ];        then echo "  - /data/containerd            （containerd 数据目录，可能很大）"; fi
echo "  - /etc/default/grub           （当前 GRUB 配置）"
echo ""
echo ">>> 磁盘状态："
df -h / /data 2>/dev/null

echo ""
echo ">>> /data 详细占用（一级目录）："
if [ -d /data ]; then
    sudo du -sh /data/* 2>/dev/null | sort -rh
else
    echo "  /data 目录不存在"
fi

echo ""
echo ">>> K8s/Docker 关键目录："
for dir in /data/containerd /data/docker /data/backups; do
    if [ -d "$dir" ]; then
        echo "  $dir: $(sudo du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    fi
done
echo ""
echo ">>> 集群状态："
sudo -u "$REAL_USER" kubectl get nodes