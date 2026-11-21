# Ops-Workspace：个人 DevOps 与云原生实战沙盘

> **🙋 关于作者（先说清楚，免得误判）**
> 软件技术专业出身，正在**从 Linux 运维入行**，计划在 2–3 年内过渡到 DevOps。
> - `docs/01-linux-base`：**我独立做过**——自建过 Minecraft / Terraria 游戏服务器、用 1Panel 部署过应用、日常 CLI 与排障是我的舒适区。
> - `docs/02-devops-journey` 的 A/B/C 三阶段：**跟做完成**（有参考实现、有人在旁带），Shell 长脚本独立从零写仍有阻碍，B 与 C 刚学完、尚未系统复习。
> - 环境：全部在**单机 Homelab**（Rocky Linux 单节点 + 虚拟机）完成，**无企业生产环境经验**。文中标注「生产视角推演」的部分是业界通用做法的整理，不是我的落地记录。
>
> **📌 项目背景与环境界定**
> 本项目是一个基于个人 Homelab 环境（Rocky Linux 单节点 + 虚拟机）构建的 DevOps 实战沙盘。文档中的排障过程均为真实踩坑记录；各阶段末尾的“生产视角推演”模块，是基于当前单机环境对真实生产集群的前瞻性推演。受限于个人硬件资源，暂未在多节点高可用集群中大规模落地，旨在验证技术原理与架构方向。欢迎交流指正。

本项目是一个面向现代互联网架构的 Linux 运维与 DevOps 实战知识库。内容涵盖从传统 Linux 底座排障，到自动化脚本（Shell/Python）开发，再到容器化与 K8s 集群监控的完整演进路线。不仅是学习笔记，更包含大量在真实（或模拟生产）环境中沉淀的生产级工具集。

## 🛠️ 技术栈矩阵

- **OS & 系统底座**：Rocky Linux 10, LVM2（PV/VG/LV 与在线扩容）, XFS, 用户/组与权限模型（umask / SGID / ACL + mask）, TCP/IP, Systemd, Logrotate, SELinux
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
   - 拆解“扩容成功但 `df` 不变”的三类根因（块层与文件系统层分离、扩容对象错位、挂载点被覆盖），并把 PE 容量账本（每 PV 固定 4MiB 不可用、`mkfs` 后容量必小于 LV）写成可复算的判据。
   - 把“权限给了却不生效”拆成 `mask` 与 `#effective` 的可复算判据：生效 = ACL 条目 ∩ mask；`setfacl -m` 每次都会重算 mask，故要制造限制必须最后单独设 `m::`；文件存在 ACL 时 `chmod` 的组位改的是 mask 而非 `group::`。
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

### 1. `labs/k8s-bootstrap/` (K8s 集群部署与灾备)
包含基于 `kubeadm` 从零构建 K8s 集群的 11 个一键执行脚本，并附带了详尽的生产级运维手册（`RUNBOOK.md`）。
- **亮点**：支持完整的 `containerd` 网络代理配置、镜像加速排障，以及基于 etcd 快照与 `kubeadm` 证书复用的**灾难恢复（Disaster Recovery）** 方案。

### 2. `labs/k8s-monitoring/` (云原生监控体系)
包含通过 Helm 部署 `kube-prometheus-stack` 的核心配置 `prom-values.yaml`。
- **亮点**：解决了单节点环境下的 PV/PVC 权限死锁、Helm `global.imageRegistry` 路径污染等真实排障难题。

### 3. `labs/compose-lab2/` (全栈应用容器化)
一个包含前端 Nginx、后端 Python Flask 与数据库 MySQL 的完整 Docker Compose 编排实践。
- **亮点**：实现了前后端网络隔离（frontend/backend）、环境变量注入密码、以及容器健康检查与重启策略。

### 4. `tools/` (自动化运维利器)
- **`shell/svc_health.sh`**：具备受控并发（`wait -n`）、结构化日志与 Systemd 闭环告警的工程化巡检脚本。
- **`shell/lvm-grow-safe.sh`**：扩容前断言“挂载点背后的设备 == 目标 LV”，不一致即退出；只处理 XFS，支持 `--dry-run` 预演。
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

👉 **第一阶段终极知识库**：[docs/01-linux-base/00-linux-ops-overview.md](docs/01-linux-base/00-linux-ops-overview.md)

---

## ⚠️ 免责声明与说明
- **环境限制**：本仓库的自动化脚本与 K8s 监控部署，主要在个人单节点 Lab 环境中完成，未在真实企业级高并发生产环境中进行过全量验证。
- **安全审查**：所有脚本和配置（如涉及密码配置、安全组放行等）在应用于真实环境前，请务必进行脱敏和二次安全审查。
- 项目采用 MIT License 授权。

<p align="center">
  <i>Built with ❤️ for the DevOps Journey.</i>
</p>
