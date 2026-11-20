# K8s 单节点集群运行手册（RUNBOOK）

> 本手册面向 **操作执行**，提供分场景的步骤顺序、关键顺序说明和排障指南。
> 项目介绍和脚本清单请见 [`README.md`](./README.md)。

**适用版本**：Rocky Linux 10 + containerd.io 2.x + Kubernetes v1.32.13

---

## 📑 快速索引

| 场景 | 说明 | 跳转 |
|---|---|---|
| **A** | 全新系统首次部署 | [→](#场景-a全新系统首次部署) |
| **B** | 配置误改后恢复（当前系统运行中） | [→](#场景-b配置误改后恢复) |
| **C** | 灾难恢复（重装系统后） | [→](#场景-c灾难恢复重装系统后) |
| **D** | 日常维护命令速查 | [→](#场景-d日常维护命令速查) |
| **E** | 定时备份（crontab） | [→](#场景-e定时备份) |
| **F** | 故障排查入口 | [→](#场景-f故障排查入口) |

其他章节：
- [关键顺序说明](#-关键顺序说明)
- [命令速查表](#-命令速查表)
- [脚本清单](#-脚本清单)

---

## 🎯 关键顺序说明

在开始任何场景前，先理解以下 5 条顺序规则。**违反任意一条都可能导致流程失败。**

| # | 顺序规则 | 原因 |
|---|---|---|
| 1 | **`01 → 02 → 03 → 04`** 必须按序执行 | 后者依赖前者（内核参数 → containerd → K8s 组件 → 集群初始化） |
| 2 | **`05` 不能加 `sudo`** | 需写入普通用户 `$HOME/.kube/config`，root 家目录不生效 |
| 3 | **`10` 在 `09` 之前** | 09 只恢复 `daemon.json` 配置，不装 Docker 本体；先 10 装好，09 再覆盖配置 |
| 4 | **`09` 在 `05` 之前** | 09 重建控制平面，05 才配置 kubectl 认证 |
| 5 | **`11` 在集群 Ready 之后** | Kuboard 依赖可用的 K8s API |

---

## 场景 A：全新系统首次部署

### 前置条件

- ✅ Rocky Linux 10 Minimal 全新安装完成
- ✅ 网卡已配置，能访问互联网
- ✅ 分区：`/`（≥ 25G）+ `/data`（剩余全部）
- ✅ `~/k8s-bootstrap/` 目录和 11 个脚本已就位

### 部署前修改参数

| 脚本 | 修改内容 |
|---|---|
| `01-base-prep.sh` | 第 13 行：主机名（默认 `xia-server`） |
| `03-k8s-install.sh` | 第 17-18 行：`K8S_MINOR`、`K8S_PATCH` |
| `04-kubeadm-init.sh` | 第 17-20 行：`API_IP`、`POD_CIDR`、`K8S_VER` |

> ⚠️ `03` 的 `K8S_PATCH` 必须与 `04` 的 `K8S_VER` 完全一致。

### 执行步骤

```bash
cd ~/k8s-bootstrap
chmod +x *.sh

# ========== 主流程（必跑）==========
sudo ./01-base-prep.sh          # 系统基础
sudo ./02-containerd-setup.sh   # containerd
sudo ./03-k8s-install.sh        # K8s 组件
sudo ./04-kubeadm-init.sh       # 集群初始化
./05-post-init.sh               # kubectl + Flannel（⚠️ 不要 sudo）

# ========== 可选组件 ==========
sudo ./10-install-docker.sh     # Docker
sudo ./11-install-kuboard.sh    # Kuboard

# ========== 首次备份 ==========
sudo ./06-backup-now.sh
```

### 验证

```bash
kubectl get nodes          # 应显示 Ready
kubectl get pods -A        # 所有 Pod 应 Running
```

---

## 场景 B：配置误改后恢复

### 适用情况

**当前系统运行中**，只改坏了配置文件（如 `config.toml`、GRUB），K8s 数据完好。

### 执行步骤

```bash
# 1. 查看可用备份（获取真实的 <时间戳>）
ls -ldt /data/backups/20*/

# 2. 执行恢复（请将 <时间戳> 替换为上一步查到的实际目录名，如 20260916-033702）
sudo ~/k8s-bootstrap/08-restore-configs.sh /data/backups/<时间戳>

# 3. 脚本会：
#    - 保存当前状态到 rollback-<时间戳>
#    - 询问是否恢复 pki 证书（日常恢复选 N）
#    - 恢复所有配置文件
#    - 重启 containerd 和 docker
#    - 验证集群状态
```

### 回滚（如果恢复出问题）

```bash
tar xzf /data/backups/rollback-<时间戳>/current-configs.tar.gz -C /
systemctl restart containerd kubelet
```

---

## 场景 C：灾难恢复（重装系统后）

### 前置条件

- ✅ 已重装 Rocky Linux 10
- ✅ `/data` 分区已挂载，且包含历史备份
- ✅ `~/k8s-bootstrap/` 脚本已恢复

### 执行步骤

```bash
cd ~/k8s-bootstrap
chmod +x *.sh

# ========== 阶段 1：基础环境 ==========
sudo ./01-base-prep.sh
sudo ./02-containerd-setup.sh
sudo ./03-k8s-install.sh

# ========== 阶段 2：装 Docker 本体 ==========
# 09 只恢复 daemon.json，不装 Docker 软件包
sudo ./10-install-docker.sh

# ========== 阶段 3：完整灾难恢复 ==========
# 复用备份证书，重建集群，恢复所有配置
sudo ./09-restore-full.sh /data/backups/<时间戳>

# ========== 阶段 4：kubectl 认证（⚠️ 不要 sudo）==========
./05-post-init.sh

# ========== 阶段 5：可选组件 ==========
sudo ./11-install-kuboard.sh

# ========== 阶段 6：验证 ==========
kubectl get nodes          # 应 Ready
kubectl get pods -A        # 全 Running
```

### 关键机制

`09-restore-full.sh` 复用备份中的集群证书。`kubeadm init` 检测到 `/etc/kubernetes/pki` 已存在时**不会重新生成证书**，因此：

- 集群身份不变
- 之前的 ServiceAccount Token 继续有效
- kubeconfig 文件继续可用
- **之前的应用（Deployment/Service）通过 etcd 快照可恢复**

### 应用数据恢复（可选）

如果备份时有 `07-backup-etcd.sh` 生成的快照，可选择性恢复：

```bash
# 查看 etcd 快照
ls -lh /data/backups/etcd/

# 恢复 etcd 快照需要停止 apiserver，操作较复杂
# 单节点练手环境建议直接重建应用，避免误操作
```

---

## 场景 D：日常维护命令速查

| 需求 | 命令 |
|---|---|
| 手动备份（配置 + 证书） | `sudo ~/k8s-bootstrap/06-backup-now.sh` |
| etcd 快照（应用变更后） | `sudo ~/k8s-bootstrap/07-backup-etcd.sh` |
| 配置误改恢复 | `sudo ~/k8s-bootstrap/08-restore-configs.sh <备份目录>` |
| 清理调试残留 | `sudo ~/k8s-bootstrap/99-cleanup.sh` |
| 查看集群状态 | `kubectl get nodes && kubectl get pods -A` |
| 查看 kubelet 日志 | `sudo journalctl -u kubelet -n 50 --no-pager` |
| 查看 containerd 状态 | `sudo systemctl status containerd` |
| 查看 Docker 状态 | `sudo systemctl status docker` |

---

## 场景 E：定时备份

### 配置 crontab

```bash
crontab -e
```

添加以下内容：

```cron
# 每天 2 点：配置备份
0 2 * * * sudo /home/xia/k8s-bootstrap/06-backup-now.sh >> /var/log/k8s-backup.log 2>&1

# 每天 3 点：etcd 快照
0 3 * * * sudo /home/xia/k8s-bootstrap/07-backup-etcd.sh >> /var/log/etcd-backup.log 2>&1
```

### 验证

```bash
# 查看 crontab
crontab -l

# 查看备份日志
sudo tail -f /var/log/k8s-backup.log
sudo tail -f /var/log/etcd-backup.log

# 查看备份文件
ls -lh /data/backups/20*/
ls -lh /data/backups/etcd/
```

---

## 场景 F：故障排查入口

### 按症状索引

| 症状 | 排查命令 | 可能原因 |
|---|---|---|
| 节点 `NotReady` | `kubectl describe node xia-server` | kubelet 异常、CNI 未就绪 |
| Pod `ImagePullBackOff` | `kubectl describe pod <pod-name>` | 镜像拉取失败、加速器失效 |
| Pod `CrashLoopBackOff` | `kubectl logs <pod-name> --previous` | 应用启动失败 |
| `kubeadm init` 超时 | `sudo journalctl -u kubelet -n 50` | sandbox 镜像未配置 |
| Cockpit 无法访问 | `sudo systemctl status cockpit` | 服务未启动、端口冲突 |
| Docker 无法启动 | `sudo journalctl -u docker -n 50` | daemon.json 格式错误 |
| Kuboard 无法访问 | `kubectl -n kuboard get pods` | Pod 未就绪、etcd 连接失败 |

### 通用排查顺序

```bash
# 1. 看节点状态
kubectl get nodes

# 2. 看所有 Pod 状态
kubectl get pods -A

# 3. 定位问题 Pod，看详情
kubectl describe pod <pod-name> -n <namespace>

# 4. 看容器日志
kubectl logs <pod-name> -n <namespace>

# 5. 看节点日志（如果是节点级问题）
sudo journalctl -u kubelet -n 100 --no-pager

# 6. 看容器运行时
sudo crictl ps -a
sudo crictl images

# 7. 看服务状态
sudo systemctl status containerd docker kubelet
```

---

## 📋 命令速查表

### K8s 常用命令

| 命令 | 说明 |
|---|---|
| `kubectl get nodes` | 查看节点状态 |
| `kubectl get pods -A` | 查看所有命名空间的 Pod |
| `kubectl get svc -A` | 查看所有 Service |
| `kubectl describe pod <name>` | 查看 Pod 详情和事件 |
| `kubectl logs <pod> -f` | 实时查看 Pod 日志 |
| `kubectl exec -it <pod> -- bash` | 进入 Pod |
| `kubectl apply -f <yaml>` | 应用 YAML |
| `kubectl delete -f <yaml>` | 删除 YAML 定义的资源 |
| `kubectl rollout status deployment <name>` | 查看滚动更新进度 |
| `kubectl rollout undo deployment <name>` | 回滚到上一版本 |

### 容器运行时命令

| 命令 | 说明 |
|---|---|
| `sudo crictl ps -a` | 查看所有容器（K8s） |
| `sudo crictl images` | 查看镜像 |
| `sudo ctr image pull <image>` | 手动拉取镜像 |
| `sudo docker ps -a` | 查看所有容器（Docker） |
| `sudo docker images` | 查看 Docker 镜像 |

### 系统服务命令

| 命令 | 说明 |
|---|---|
| `systemctl status <service>` | 查看服务状态 |
| `systemctl restart <service>` | 重启服务 |
| `systemctl is-active <service>` | 检查服务是否运行 |
| `journalctl -u <service> -f` | 实时查看服务日志 |

---

## 📦 脚本清单

| 编号 | 脚本 | 用途 | 加 sudo |
|---|---|---|---|
| 01 | `01-base-prep.sh` | 系统基础准备 | ✅ |
| 02 | `02-containerd-setup.sh` | containerd 安装配置 | ✅ |
| 03 | `03-k8s-install.sh` | K8s 组件安装 | ✅ |
| 04 | `04-kubeadm-init.sh` | 集群初始化 | ✅ |
| 05 | `05-post-init.sh` | kubectl + Flannel | ❌ **不要 sudo** |
| 06 | `06-backup-now.sh` | 集群备份 | ✅ |
| 07 | `07-backup-etcd.sh` | etcd 快照 | ✅ |
| 08 | `08-restore-configs.sh` | 配置级恢复 | ✅ |
| 09 | `09-restore-full.sh` | 完整灾难恢复 | ✅ |
| 10 | `10-install-docker.sh` | Docker 安装 | ✅ |
| 11 | `11-install-kuboard.sh` | Kuboard 部署 | ✅ |
| 99 | `99-cleanup.sh` | 调试残留清理 | ✅ |

---

## 📝 变更日志

| 日期 | 变更 |
|---|---|
| 2026-09-16 | 首次创建，涵盖 6 个场景和关键顺序说明 |