#!/bin/bash
# 网络排查脚本
# 用法：./net-check.sh <目标地址>

TARGET=${1:-baidu.com}

echo "===== 1. DNS 解析 ====="
dig +short $TARGET

echo ""
echo "===== 2. 连通性测试 ====="
ping -c 4 $TARGET

echo ""
echo "===== 3. 路由追踪 ====="
traceroute -m 10 $TARGET

echo ""
echo "===== 4. HTTP 响应 ====="
if [[ $TARGET == http* ]]; then
    curl -w "\n状态码: %{http_code}\n耗时: %{time_total}s\n" -o /dev/null -s $TARGET
else
    echo "（非 HTTP 目标，跳过）"
fi