#!/bin/bash
# ==========================================
# 阶段 2：containerd.io 安装与配置
# 功能：Docker 仓库、containerd.io、数据目录、SystemdCgroup、sandbox 镜像、加速器
# 修复：sandbox 路径、CRI 读取 certs.d、显式验证
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo ">>> 正在通过 sudo 提权执行..."
    exec sudo "$0" "$@"
fi

set -e
echo ">>> [1/6] 添加 Docker 官方仓库..."
dnf install -y -q dnf-plugins-core
if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
fi

echo ">>> [2/6] 安装 containerd.io..."
dnf install -y -q containerd.io

echo ">>> [3/6] 生成默认配置并修改关键项..."
mkdir -p /etc/containerd /data/containerd
containerd config default > /etc/containerd/config.toml

BACKUP="/etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)"
cp /etc/containerd/config.toml "$BACKUP"
echo "  配置已备份到 $BACKUP"

# 3.1 数据目录迁移到 /data
sed -i 's|^root = .*|root = "/data/containerd"|g' /etc/containerd/config.toml

# 3.2 启用 SystemdCgroup
sed -i 's|SystemdCgroup = false|SystemdCgroup = true|g' /etc/containerd/config.toml

# 3.3 【关键】sandbox 镜像在 containerd 2.x 的新位置：
#   [plugins.'io.containerd.cri.v1.images'.pinned_images].sandbox
# 默认配置里已有此行的 registry.k8s.io 值，直接替换
sed -i "s|sandbox = 'registry.k8s.io/pause:[^']*'|sandbox = 'registry.aliyuncs.com/google_containers/pause:3.10'|g" /etc/containerd/config.toml
sed -i "s|sandbox = \"registry.k8s.io/pause:[^\"]*\"|sandbox = \"registry.aliyuncs.com/google_containers/pause:3.10\"|g" /etc/containerd/config.toml

# 3.4 兜底：万一某些 containerd 版本的默认配置里根本没有 sandbox 行
if ! grep -q "registry.aliyuncs.com/google_containers/pause" /etc/containerd/config.toml; then
    echo "  ⚠️  默认配置没有 sandbox 行，手动插入..."
    awk '
      /\[plugins\..*io\.containerd\.cri\.v1\.images.*pinned_images\]/ {
        print
        print "      sandbox = '\''registry.aliyuncs.com/google_containers/pause:3.10'\''"
        next
      }
      { print }
    ' /etc/containerd/config.toml > /etc/containerd/config.toml.new
    mv /etc/containerd/config.toml.new /etc/containerd/config.toml
fi

echo ">>> [4/6] 启用 CRI 读取 certs.d 加速配置..."
# 【关键】containerd 2.x 的 images registry 插件默认 config_path 为空
# 只有设置了 config_path，才会去读 /etc/containerd/certs.d/ 下的 hosts.toml
# 不加这一行，kubelet 拉镜像会直连 registry-1.docker.io（国外）
sed -i "/\[plugins\.'io\.containerd\.cri\.v1\.images'\.registry\]/,/^$/ s|config_path = ''|config_path = '/etc/containerd/certs.d'|" /etc/containerd/config.toml

# 验证是否改成功
REGISTRY_PATH=$(grep -A 2 "io.containerd.cri.v1.images'.registry" /etc/containerd/config.toml | grep "config_path" | head -1 | grep -oP "(?<=')[^']+(?=')")
if [ "$REGISTRY_PATH" != "/etc/containerd/certs.d" ]; then
    echo "❌ images.registry.config_path 未正确设置（当前：'$REGISTRY_PATH'）"
    echo "   请手动检查 /etc/containerd/config.toml"
    exit 1
fi
echo "  ✅ registry.config_path = $REGISTRY_PATH"

echo ">>> [5/6] 配置镜像加速器..."
mkdir -p /etc/containerd/certs.d/docker.io
cat > /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://docker.1ms.run"

[host."https://docker.1ms.run"]
  capabilities = ["pull", "resolve"]

[host."https://docker.xuanyuan.me"]
  capabilities = ["pull", "resolve"]
EOF

# 双保险：给 registry.k8s.io 也配加速
mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<EOF
server = "https://registry.aliyuncs.com/google_containers"

[host."https://registry.aliyuncs.com/google_containers"]
  capabilities = ["pull", "resolve"]
EOF

echo ">>> [6/6] 启动并验证..."
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd
sleep 3

echo ""
echo "✅ 阶段 2 完成！验证："
echo "  - 服务状态: $(systemctl is-active containerd)"
echo "  - 数据目录: $(grep '^root' /etc/containerd/config.toml)"
echo "  - Cgroup 驱动: $(grep 'SystemdCgroup' /etc/containerd/config.toml | head -1 | tr -d ' ')"

# 【关键】显式验证 sandbox 生效
SANDBOX_LINE=$(containerd config dump 2>/dev/null | grep "sandbox = " | head -1)
echo "  - sandbox 镜像:"
echo "    $SANDBOX_LINE"
if ! echo "$SANDBOX_LINE" | grep -q "aliyuncs"; then
    echo ""
    echo "❌ sandbox 未生效！请手动检查 /etc/containerd/config.toml"
    echo "   期望位置：[plugins.'io.containerd.cri.v1.images'.pinned_images]"
    exit 1
fi

# 【关键】显式验证 certs.d 配置生效
DUMP_PATH=$(containerd config dump 2>/dev/null | grep -A 2 "io.containerd.cri.v1.images'.registry" | grep "config_path" | head -1 | grep -oP "(?<=')[^']+(?=')")
echo "  - registry.config_path: $DUMP_PATH"
if [ "$DUMP_PATH" != "/etc/containerd/certs.d" ]; then
    echo "❌ certs.d 未生效！镜像加速将不工作"
    exit 1
fi

echo ""
echo "  - 测试从 Docker Hub 拉取 pause 镜像（验证加速器生效）..."
if ctr image pull docker.io/library/nginx:alpine > /dev/null 2>&1; then
    echo "    ✅ Docker Hub 拉取成功，加速器工作正常"
    ctr image rm docker.io/library/nginx:alpine > /dev/null 2>&1 || true
else
    echo "    ❌ Docker Hub 拉取失败"
    exit 1
fi

echo ""
echo "  - 测试 pause 镜像拉取..."
if ctr image pull registry.aliyuncs.com/google_containers/pause:3.10 > /dev/null 2>&1; then
    echo "    ✅ pause 镜像拉取成功"
else
    echo "    ❌ pause 镜像拉取失败，请检查网络"
    exit 1
fi