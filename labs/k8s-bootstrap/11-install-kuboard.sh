#!/bin/bash
# ==========================================
# 阶段 11：安装 Kuboard v3（K8s 可视化管理）
# 功能：部署 Kuboard + 单节点适配（含 2 个踩坑修复）
# 前置：01~05 已完成，集群 Ready
# 踩坑：
#   1. 单节点需要给 node 打 k8s.kuboard.cn/role=etcd 标签
#   2. 需要显式注入 KUBOARD_ETCD_ENDPOINTS（官方 YAML 遗漏）
# ==========================================

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

set -e

# ========== 可调参数 ==========
HOST_IP="192.168.2.22"        # 宿主机内网 IP
KUBOARD_HTTP_PORT="30080"     # Web 访问端口
KUBOARD_AGENT_PORT="30081"    # Agent 通信端口
KUBOARD_ETCD_PORT="2381"      # Kuboard 内置 etcd 端口
KUBOARD_VERSION="v3"          # Kuboard 版本
# ==============================

# 获取 REAL_USER（用于 kubectl 操作）
REAL_USER="${SUDO_USER:-$USER}"

echo ">>> [1/7] 检查端口占用..."
for port in $KUBOARD_HTTP_PORT $KUBOARD_AGENT_PORT; do
    if ss -tulnp 2>/dev/null | grep -q ":$port "; then
        echo "❌ 端口 $port 已被占用"
        exit 1
    fi
done
echo "  ✅ 端口 $KUBOARD_HTTP_PORT / $KUBOARD_AGENT_PORT 空闲"

echo ">>> [2/7] 检查 Kuboard 是否已部署..."
if sudo -u "$REAL_USER" kubectl get ns kuboard > /dev/null 2>&1; then
    echo "  ⚠️  kuboard 命名空间已存在"
    read -p "  是否重新部署？(y/N): " CONFIRM
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        sudo -u "$REAL_USER" kubectl delete namespace kuboard --timeout=60s || true
    else
        echo "  已取消"
        exit 0
    fi
fi

echo ">>> [3/7] 下载 Kuboard YAML..."
KUBOARD_YAML="/tmp/kuboard-${KUBOARD_VERSION}.yaml"
curl -sSL -o "$KUBOARD_YAML" \
    "https://addons.kuboard.cn/kuboard/kuboard-${KUBOARD_VERSION}.yaml"
echo "  已下载: $(ls -lh "$KUBOARD_YAML" | awk '{print $5}')"

echo ">>> [4/7] 应用 YAML..."
sudo -u "$REAL_USER" kubectl apply -f "$KUBOARD_YAML"

echo ">>> [5/7] 等待 Deployment 创建（最多 60 秒）..."
for i in {1..12}; do
    if sudo -u "$REAL_USER" kubectl -n kuboard get deployment kuboard-v3 > /dev/null 2>&1; then
        echo "  ✅ Deployment 已创建"
        break
    fi
    if [ $i -eq 12 ]; then
        echo "❌ 超时，Deployment 未创建"
        exit 1
    fi
    sleep 5
done

echo ">>> [6/7] 单节点适配（2 个坑修复）..."

# 【坑 1】单节点需要给 node 打 k8s.kuboard.cn/role=etcd 标签
NODE_NAME=$(sudo -u "$REAL_USER" kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
echo "  - 给节点 $NODE_NAME 打 etcd 标签..."
sudo -u "$REAL_USER" kubectl label node "$NODE_NAME" \
    k8s.kuboard.cn/role=etcd --overwrite

# 【坑 2】显式注入 KUBOARD_ETCD_ENDPOINTS
echo "  - 注入 KUBOARD_ETCD_ENDPOINTS=http://${HOST_IP}:${KUBOARD_ETCD_PORT}..."

# 先检查是否已有此环境变量（避免重复）
if sudo -u "$REAL_USER" kubectl -n kuboard get deployment kuboard-v3 \
    -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' \
    | grep -q "KUBOARD_ETCD_ENDPOINTS"; then
    echo "    ⚠️  环境变量已存在，使用 replace"
    ENV_INDEX=$(sudo -u "$REAL_USER" kubectl -n kuboard get deployment kuboard-v3 \
        -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' \
        | tr ' ' '\n' | grep -n "KUBOARD_ETCD_ENDPOINTS" | cut -d: -f1)
    ENV_INDEX=$((ENV_INDEX - 1))
    sudo -u "$REAL_USER" kubectl -n kuboard patch deployment kuboard-v3 --type json -p "[
      {
        \"op\": \"replace\",
        \"path\": \"/spec/template/spec/containers/0/env/${ENV_INDEX}/value\",
        \"value\": \"http://${HOST_IP}:${KUBOARD_ETCD_PORT}\"
      }
    ]"
else
    sudo -u "$REAL_USER" kubectl -n kuboard patch deployment kuboard-v3 --type json -p "[
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/containers/0/env/-\",
        \"value\": {
          \"name\": \"KUBOARD_ETCD_ENDPOINTS\",
          \"value\": \"http://${HOST_IP}:${KUBOARD_ETCD_PORT}\"
        }
      }
    ]"
fi

echo "  ✅ 单节点适配完成"

echo ">>> [7/7] 等待 Pod 就绪（最多 3 分钟）..."
for i in {1..36}; do
    KUBOARD_STATUS=$(sudo -u "$REAL_USER" kubectl -n kuboard get pods \
        -l k8s.kuboard.cn/name=kuboard-v3 \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    if [ "$KUBOARD_STATUS" = "true" ]; then
        echo "  ✅ kuboard-v3 已就绪"
        break
    fi
    if [ $i -eq 36 ]; then
        echo "  ⚠️  超时，请手动检查："
        sudo -u "$REAL_USER" kubectl -n kuboard get pods
        exit 1
    fi
    sleep 5
done

echo ""
echo "=========================================="
echo "✅ 阶段 11 完成！Kuboard 已部署"
echo "=========================================="
echo ""
echo ">>> 访问地址：http://${HOST_IP}:${KUBOARD_HTTP_PORT}"
echo ">>> 初始账号：admin / Kuboard123"
echo ""
echo ">>> Pod 状态："
sudo -u "$REAL_USER" kubectl -n kuboard get pods
echo ""
echo ">>> Service 信息："
sudo -u "$REAL_USER" kubectl -n kuboard get svc