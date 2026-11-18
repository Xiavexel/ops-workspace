# Ops-Workspace：个人 DevOps 与云原生实战沙盘

本项目是一个面向现代互联网架构的 Linux 运维与 DevOps 实战知识库。内容涵盖从传统 Linux 底座排障，到自动化脚本（Shell/Python）开发，再到容器化与 K8s 集群监控的完整演进路线。

不仅是学习笔记，更包含大量在真实（或模拟生产）环境中踩过的坑与沉淀的生产级工具集。

## 🛠️ 技术栈矩阵

- **OS & 系统底座**：Rocky Linux 10, TCP/IP, Systemd, Logrotate, SELinux
- **核心网关与中间件**：Nginx (反向代理/限流/HTTPS), MySQL 8.0 (主从备份/慢查询分析)
- **自动化与开发**：Shell (Bash 并发/异常捕获), Python (Paramiko/K8s API)
- **容器与云原生**：Docker, Docker Compose, Kubernetes (kubeadm/Flannel), Helm
- **可观测性**：Prometheus, Grafana, Alertmanager

---

## 🌟 核心实战亮点（排障与架构）

相比于普通的配置堆砌，本项目更注重记录真实场景下的排障思路：

1. **Linux 底层排障**：
   - 解决 `rm` 大文件后空间不释放的“幽灵文件”问题（基于 `lsof` 与 `/proc` 机制）。
   - 从 OSI 模型自下而上排查网络故障（从 `tcpdump` 抓包到 `curl -w` 耗时拆解）。
2. **Nginx 生产网关坑点**：
   - 深入解析 `proxy_pass` 尾斜杠导致 404 的底层原因。
   - 解决因 IPv6 监听缺失或 `return` 短路导致限流配置失效的问题。
3. **K8s 监控与云原生排障**：
   - 突破国内网络限制：为 `containerd` 配置系统级 `HTTP_PROXY` 解决镜像拉取失败。
   - 修复 Helm Chart 变量继承污染、PV/PVC 挂载权限导致的 `Permission Denied` 问题。
   - 暴力破解 K8s Namespace 卡在 `Terminating` 状态的 Finalizer 死锁。

---

## 📂 目录导航

本项目分为三大核心目录：

- **[`docs/`](./docs/)**：体系化的知识库与阶段总结，包含 `01-linux-base`（底层硬核底座）与 `02-devops-journey`（DevOps 进阶实战）。
- **[`labs/`](./labs/)**：所有实战演练的源代码与配置文件，包括 K8s 一键部署脚本、Docker 多阶段构建、监控栈 Values 等。
- **[`tools/`](./tools/)**：日常运维沉淀的自动化工具脚本（Shell 巡检、Python 批量管理）。

---

## 🔍 核心目录深度解析

### 1. `labs/k8s-bootstrap/` (K8s 生产级部署与灾备)
包含基于 `kubeadm` 从零构建 K8s 集群的 11 个一键执行脚本，并附带了详尽的生产级运维手册（`RUNBOOK.md`）。
- **亮点**：支持完整的 `containerd` 网络代理配置、镜像加速排障，以及基于 etcd 快照与 `kubeadm` 证书复用的**灾难恢复（Disaster Recovery）** 方案。

### 2. `labs/k8s-monitoring/` (云原生监控体系)
包含通过 Helm 部署 `kube-prometheus-stack` 的核心配置 `prom-values.yaml`。
- **亮点**：解决了单节点环境下的 PV/PVC 权限死锁、Helm `global.imageRegistry` 路径污染等真实排障难题。

### 3. `labs/compose-lab2/` (全栈应用容器化)
一个包含前端 Nginx、后端 Python Flask 与数据库 MySQL 的完整 Docker Compose 编排实践。
- **亮点**：实现了前后端网络隔离（frontend/backend）、环境变量注入密码、以及容器健康检查与重启策略。

### 4. `tools/` (自动化运维利器)
- **`shell/svc_health.sh`**：具备受控并发（`wait -n`）、结构化日志与 Systemd 闭环告警的生产级巡检脚本。
- **`python/ssh_batch.py`**：基于 Paramiko 的批量 SSH 并发执行工具。
- **`python/api_monitor.py`**：通过 HTTP 接口探测服务存活并触发告警的轻量级探针。

---

## 🚀 快速开始 (Quick Start)

### 1. 运行生产级 Shell 巡检

```bash
cd tools/shell
chmod +x svc_health.sh
# 根据当前机器的服务配置修改 services.conf 后执行
sudo ./svc_health.sh -c services.conf -v
```

### 2. 一键初始化 K8s 集群 (以 Rocky Linux 10 为例)

```bash
cd labs/k8s-bootstrap
chmod +x *.sh
# 请务必参照 README.md 中的顺序执行
sudo ./01-base-prep.sh
sudo ./02-containerd-setup.sh
# ... 依次执行至 05
```

### 3. 查看详细知识库

如果你想系统性地阅读底层排障与架构演进思路，请从总览文档开始：

👉 **第一阶段终极知识库**：[00-linux-ops-overview.md](docs/01-linux-base/00-linux-ops-overview.md)

---

## ⚠️ 免责声明与说明

- 本仓库中的所有脚本和配置主要用于个人学习与 Homelab 环境演练。在将其中的配置应用于真实生产环境（如涉及密码配置、安全组放行等）前，请务必进行脱敏和二次安全审查。
- 项目采用 MIT License 授权。

<p align="center">
  <i>Built with ❤️ for the DevOps Journey.</i>
</p>
