#!/bin/bash
# 网络排查脚本
# 用法：./net-check.sh [目标]
#   目标可以是域名、IP，或完整 URL（http:// 开头）。默认 baidu.com。

set -uo pipefail   # 不开 -e：ping/traceroute 失败是常态，不该让整个排查中断

TARGET="${1:-baidu.com}"
TIMEOUT="${TIMEOUT:-5}"

# 【修复 1】把 URL 剥成主机名。
# ping / traceroute / dig 只接受"主机名或 IP"，直接喂 "http://host/path" 必然解析失败。
SCHEME=""
HOST="${TARGET}"
if [[ "${TARGET}" == *"://"* ]]; then
  SCHEME="${TARGET%%://*}"
  HOST="${TARGET#*://}"
fi
HOST="${HOST%%/*}"   # 去掉 path
HOST="${HOST%%:*}"   # 去掉端口（仅对域名/IPv4 有效；IPv6 裸地址请直接传，不要走这条）

echo "==== 目标: ${TARGET}  (连通性测试用: ${HOST}) ===="
echo ""

echo "===== 1. DNS 解析 ====="
if command -v dig >/dev/null 2>&1; then
  dig +short "${HOST}"
else
  echo "（未装 dig，退回 getent）"
  getent hosts "${HOST}"
fi

echo ""
echo "===== 2. 连通性测试（ICMP） ===="
# 【修复 2】变量一律加双引号：不加引号时含空格或通配符的目标会被拆词/展开
ping -c 4 "${HOST}"

echo ""
echo "===== 3. 路由追踪 ===="
if command -v traceroute >/dev/null 2>&1; then
  traceroute -m 10 "${HOST}"
elif command -v tracepath >/dev/null 2>&1; then
  echo "（未装 traceroute，改用 tracepath）"
  tracepath -m 10 "${HOST}"
else
  echo "（traceroute / tracepath 均未安装：dnf install -y traceroute）"
fi

echo ""
echo "===== 4. HTTP 响应 ===="
if [[ "${SCHEME}" == "http" || "${SCHEME}" == "https" ]]; then
  curl -s -o /dev/null --max-time "${TIMEOUT}" \
       -w "状态码: %{http_code}\n耗时: %{time_total}s\n" "${TARGET}"
else
  echo "（非 HTTP 目标，跳过）"
  echo "  要测端口请用: timeout 3 bash -c 'echo > /dev/tcp/'"${HOST}"'/<端口>' && echo open"
fi
