#!/bin/bash
# ==========================================
# 阶段 10：安装 Docker（与 containerd 共存）
# 功能：Docker CE、数据目录 /data/docker、加速器、cgroup systemd
# 前置：01~05 已完成（Docker 仓库已由 02 脚本添加）
# ==========================================

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

set -e

echo ">>> [1/5] 检查 Docker 仓库..."
if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
    dnf install -y -q dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
fi
echo "  ✅ Docker 仓库已配置"

echo ">>> [2/5] 安装 Docker CE..."
dnf install -y -q \
    docker-ce \
    docker-ce-cli \
    docker-buildx-plugin \
    docker-compose-plugin
echo "  ✅ Docker 组件安装完成"

echo ">>> [3/5] 配置数据目录到 /data/docker..."
mkdir -p /data/docker /etc/docker

# 只在文件不存在时创建，避免覆盖已有配置
if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "/data/docker",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
    echo "  ✅ 已创建 /etc/docker/daemon.json"
else
    echo "  ⚠️  /etc/docker/daemon.json 已存在，跳过创建"
    echo "     当前内容："
    cat /etc/docker/daemon.json | sed 's/^/     /'
fi

# 校验 JSON 格式
if ! python3 -m json.tool /etc/docker/daemon.json > /dev/null 2>&1; then
    echo "❌ daemon.json 格式错误"
    exit 1
fi

echo ">>> [4/5] 启动 Docker..."
systemctl daemon-reload
systemctl enable --now docker
sleep 5

echo ">>> [5/5] 验证..."
echo ""
echo "✅ 阶段 10 完成！验证："
echo "  - 服务状态: $(systemctl is-active docker)"
echo "  - Docker 版本: $(docker --version)"
echo "  - 数据目录: $(docker info 2>/dev/null | grep 'Docker Root Dir' | awk '{print $NF}')"
echo "  - Cgroup 驱动: $(docker info 2>/dev/null | grep 'Cgroup Driver' | awk '{print $NF}')"
echo ""
echo "  - 测试运行 hello-world..."
if docker run --rm hello-world > /dev/null 2>&1; then
    echo "    ✅ hello-world 运行成功"
else
    echo "    ❌ hello-world 运行失败"
    exit 1
fi

echo ""
echo "  - 确认 containerd 未受影响: $(systemctl is-active containerd)"