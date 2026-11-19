#!/bin/bash
# ==========================================
# 安全关机脚本
# 功能：优雅停止 K8s → Docker → 系统关机
# 用法：./safe-shutdown.sh [reboot|poweroff]
# ==========================================

set -e

# 颜色（必须定义在下方校验之前，否则报错信息里的色码是空的）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 参数：默认关机，可传 reboot 重启
ACTION="${1:-poweroff}"

# 【修复】参数合法性必须在停服务之前校验
# 原写法把校验放在最后：误输入 `restart` 也会先把 kubelet/docker/containerd 全部停掉
if [ "$ACTION" != "reboot" ] && [ "$ACTION" != "poweroff" ]; then
    echo -e "${RED}❌ 未知操作：$ACTION（只支持 reboot / poweroff）${NC}"
    exit 1
fi

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  安全关机流程${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# ========== 1. 确认操作 ==========
echo -e "${YELLOW}>>> 当前集群状态：${NC}"
sudo -u "${SUDO_USER:-$USER}" kubectl get nodes 2>/dev/null || echo "  (无法连接集群)"
echo ""
echo -e "${YELLOW}>>> 即将执行：${GREEN}$ACTION${NC}"
read -p ">>> 确认？(yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "已取消"
    exit 0
fi

# ========== 2. 停止 K8s ==========
echo ""
echo -e "${YELLOW}>>> [1/4] 停止 kubelet（K8s 控制平面会随之停止）...${NC}"
sudo systemctl stop kubelet 2>/dev/null || true
echo -e "${GREEN}    ✅ kubelet 已停止${NC}"

# ========== 3. 停止 Docker ==========
echo ""
echo -e "${YELLOW}>>> [2/4] 停止 Docker...${NC}"
if systemctl is-active docker &>/dev/null; then
    sudo systemctl stop docker
    echo -e "${GREEN}    ✅ Docker 已停止${NC}"
else
    echo -e "${GREEN}    ⏭  Docker 未运行，跳过${NC}"
fi

# ========== 4. 停止 containerd ==========
echo ""
echo -e "${YELLOW}>>> [3/4] 停止 containerd...${NC}"
sudo systemctl stop containerd 2>/dev/null || true
echo -e "${GREEN}    ✅ containerd 已停止${NC}"

# ========== 5. 同步磁盘 + 关机 ==========
echo ""
echo -e "${YELLOW}>>> [4/4] 同步磁盘并${ACTION}...${NC}"
sync
sleep 2

if [ "$ACTION" = "reboot" ]; then
    echo -e "${GREEN}    正在重启...${NC}"
    sudo systemctl reboot
else
    echo -e "${GREEN}    正在关机...${NC}"
    sudo systemctl poweroff
fi