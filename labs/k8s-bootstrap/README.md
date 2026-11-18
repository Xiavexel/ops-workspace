# K8s 单节点集群运维工具箱

基于 **Rocky Linux 10** + **containerd.io 2.x** + **Kubernetes v1.32** 的完整部署与灾难恢复方案。

适用于 x86 台式机 / 单节点 Homelab 环境。

---

## 📁 目录结构

```
~/k8s-bootstrap/
├── 01-base-prep.sh          系统基础准备
├── 02-containerd-setup.sh   containerd 安装与配置
├── 03-k8s-install.sh        K8s 组件安装
├── 04-kubeadm-init.sh       集群初始化
├── 05-post-init.sh          后置配置 — ⚠️ 不要 sudo
├── 06-backup-now.sh         集群备份
├── 07-backup-etcd.sh        etcd 快照
├── 08-restore-configs.sh    配置级恢复
├── 09-restore-full.sh       完整灾难恢复
├── 99-cleanup.sh            调试残留清理
├── 10-install-docker.sh     Docker 安装（与 containerd 共存）
├── 11-install-kuboard.sh    Kuboard 部署（单节点适配）
└── README.md                本文件
```

---

## 🚀 场景一：全新系统部署

### 前置条件

- 系统：Rocky Linux 10 Minimal 全新安装
- 硬件：x86_64，建议 ≥ 4 核 / 8G 内存 / 50G 硬盘
- 网络：可访问互联网
- 分区：`/`（≥ 25G）+ `/data`（剩余全部）

### 部署前修改参数

**`01-base-prep.sh`** 第 13 行（改主机名）：
```bash
hostnamectl set-hostname xia-server    # 改成你的主机名
```

**`04-kubeadm-init.sh`** 第 17-20 行：
```bash
API_IP="192.168.2.22"           # 改成你的宿主机内网 IP
POD_CIDR="10.244.0.0/16"        # Flannel 默认网段，一般不改
K8S_VER="v1.32.13"              # 与 03 脚本的 K8S_PATCH 保持一致
IMAGE_REPO="registry.aliyuncs.com/google_containers"
```

**`03-k8s-install.sh`** 第 17-18 行：
```bash
K8S_MINOR="v1.32"               # 与 04 的 K8S_VER 主次版本一致
K8S_PATCH="1.32.13"             # 与 04 的 K8S_VER 完全一致
```

### 执行步骤

```bash
cd ~/k8s-bootstrap
chmod +x *.sh

# 前 4 步用 sudo 执行
sudo ./01-base-prep.sh
sudo ./02-containerd-setup.sh
sudo ./03-k8s-install.sh
sudo ./04-kubeadm-init.sh

# ⚠️ 最后一步不要加 sudo！
./05-post-init.sh

# 验证
kubectl get nodes          # 应为 Ready
kubectl get pods -A        # 所有 Pod 应 Running
```

---

## 💾 场景二：日常备份

### 手动备份

```bash
sudo ~/k8s-bootstrap/06-backup-now.sh
```

**备份内容**（位于 `/data/backups/<时间戳>/`）：

| 文件 | 内容 |
|---|---|
| `k8s-pki.tar.gz` | 所有集群证书（P0 核心资产，20K+） |
| `k8s-configs.tar.gz` | K8s 和系统配置文件（15K+） |
| `repo-configs.tar.gz` | dnf 源和 crictl 配置 |
| `README.txt` | 备份元信息 |

### 定时备份

```bash
crontab -e
```

添加：
```cron
0 2 * * * sudo /home/xia/k8s-bootstrap/06-backup-now.sh >> /var/log/k8s-backup.log 2>&1
0 3 * * * sudo /home/xia/k8s-bootstrap/07-backup-etcd.sh >> /var/log/etcd-backup.log 2>&1
```

### etcd 快照（部署应用后启用）

```bash
sudo ~/k8s-bootstrap/07-backup-etcd.sh
```

---

## 🔧 场景三：配置误改后恢复

**症状**：改坏了 `/etc/containerd/config.toml` 或 GRUB，集群异常，K8s 数据完好。

```bash
sudo ~/k8s-bootstrap/08-restore-configs.sh /data/backups/20260916-033702
```

脚本会：
1. 校验备份完整性
2. 保存当前状态到 `rollback-<时间戳>`
3. 询问是否恢复证书（日常恢复选 **N**）
4. 恢复所有配置文件
5. 重启 containerd 并验证集群

---

## 🔥 场景四：灾难恢复（重装系统）

**症状**：`/` 分区损坏、系统重装、硬盘更换。

### 前置条件

1. 已重装 Rocky Linux 10
2. `/data` 分区已挂载，包含历史备份
3. 备份脚本已拷贝到 `~/k8s-bootstrap/`

### 执行步骤

```bash
cd ~/k8s-bootstrap
chmod +x *.sh

# 前 3 步正常执行
sudo ./01-base-prep.sh
sudo ./02-containerd-setup.sh
sudo ./03-k8s-install.sh

# 第 4 步替换为灾难恢复
sudo ./09-restore-full.sh /data/backups/20260916-033702

# 最后一步仍然不要 sudo
./05-post-init.sh

# 验证
kubectl get nodes
kubectl get pods -A
```

### 关键机制

`09-restore-full.sh` 复用备份中的集群证书。`kubeadm init` 检测到 `/etc/kubernetes/pki` 已存在时**不会重新生成证书**，因此：
- 集群身份不变
- 之前的 ServiceAccount Token 继续有效
- kubeconfig 文件继续可用

---

## 🧹 场景五：清理调试残留

```bash
sudo ~/k8s-bootstrap/99-cleanup.sh
```

**清理**：
- `config.toml.bak.*`
- `grub.bak.*`
- `~/` 下的一次性临时脚本
- `~/.kube.bak.*`

**保留**：
- `~/k8s-bootstrap/` 整个目录
- `/etc/yum.repos.d.bak`
- 当前生效的所有配置

---

## 🎛️ 场景六：可选组件安装

### Docker 安装（10）
```bash
sudo ~/k8s-bootstrap/10-install-docker.sh
```

### Kuboard 安装（11）
```bash
sudo ~/k8s-bootstrap/11-install-kuboard.sh
```

---

## ⚠️ 已知坑速查表

| 症状 | 根因 | 修复位置 |
|---|---|---|
| 物理屏幕卡在 `systemd-vconsole-setup` | Radeon 显卡驱动死锁 | GRUB 加 `nomodeset fbcon=nodefer radeon.modeset=0` |
| `dnf install containerd` 找不到 | RHEL 系包名为 `containerd.io` | 添加 Docker 官方仓库 |
| `kubeadm init` 4 分钟超时 | containerd 2.x sandbox 路径变了 | `io.containerd.cri.v1.images.pinned_images.sandbox` |
| `sandbox_image` 写入无效 | sed 单双引号不匹配 | 匹配时用单引号 |
| 备份包只有 45 字节 | tar 多 `-C` 用法错误 | 统一用 `-C /` + 相对路径 |
| dnf 源替换无效 | Rocky 10 用 `metalink` | sed 时同时处理 metalink/mirrorlist |
| `kubectl cp` 拉 etcd 快照失败 | distroless 镜像无 tar | 走 hostPath 直接读取 |
| 05 脚本秒退无输出 | `[ -f x ] && cmd` 在 `set -e` 下退出 | 直接 `rm -f` 或用 `\|\| true` |
| kubelet 版本与 apiserver 不匹配 | 03 用 v1.32、04 用 v1.32.13 | 03 锁定精确 patch 版本 |
| Pod `ImagePullBackOff`，DNS 解析到 IPv6 公网 IP | `io.containerd.cri.v1.images.registry.config_path = ''`，导致 certs.d 加速配置无效 | 设为 `'/etc/containerd/certs.d'` |

---

## 📌 版本兼容性

| 组件 | 版本 |
|---|---|
| Rocky Linux | 10.x |
| containerd.io | 2.3.5+ |
| Kubernetes | v1.32.13 |
| Flannel | v0.25+ |
> ⚠️ containerd 2.x 必须显式设置 `images.registry.config_path`，否则 `/etc/containerd/certs.d/` 下的镜像加速配置全部失效。

### 升级 K8s 时需同步修改

| 脚本 | 变量 |
|---|---|
| `03-k8s-install.sh` | `K8S_MINOR` 和 `K8S_PATCH` |
| `04-kubeadm-init.sh` | `K8S_VER` |
| `09-restore-full.sh` | `--kubernetes-version` 参数 |

---

## 🆘 快速排查命令

```bash
# 集群状态
kubectl get nodes
kubectl get pods -A

# kubelet 日志
sudo journalctl -u kubelet -n 50 --no-pager

# containerd 状态
sudo systemctl status containerd
sudo containerd config dump | grep -E "sandbox|SystemdCgroup|^root"

# 容器运行时
sudo crictl ps -a
sudo crictl images

# 磁盘占用
df -h
sudo du -sh /data/*
```

---

## 📝 变更日志

- **2026-09-16**：首次完成，覆盖 Rocky Linux 10 + K8s v1.32 单节点全流程
- **2026-09-16 复审**：修复 05 脚本 `set -e` 提前退出 bug；锁定 03 精确版本；README 重写
- **2026-09-16 三轮修复**：containerd `images.registry.config_path` 未启用导致加速器不生效