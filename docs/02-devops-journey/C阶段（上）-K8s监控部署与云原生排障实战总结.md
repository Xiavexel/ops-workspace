# C阶段（上）-K8s监控部署与云原生排障实战总结

**核心定位**：企业级 K8s 监控体系（Prometheus + Grafana）落地实战。本阶段不局限于“把服务跑起来”，而是直面国内真实网络环境与 K8s 底层机制，涵盖：Helm 包管理、Containerd 代理配置、镜像拉取治理、Admission Webhook 准入控制、持久化存储（PV/PVC）权限以及 K8s 命名空间死锁排障。这是一份从“绝望”到“爽文”的 SRE 实战录。

> **返回总览**：[00-linux-ops-overview.md](../01-linux-base/00-linux-ops-overview.md)

---

## 1. 最终部署架构与关键配置

**核心目的**：使用 kube-prometheus-stack 完成一站式监控部署。保证单节点集群稳定运行，规避系统盘空间不足隐患，并准确暴露外部访问端口。

### 核心配置（prom-values.yaml）

```yaml
# 精简版核心配置，剥离冗余，确保 Chart 原生兼容性
grafana:
  service:
    type: NodePort
    nodePort: 30091
  persistence:
    enabled: false

prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    # 【关键】强制指定运行用户组，解决挂载宿主机目录时的 Permission Denied 问题
    securityContext:
      fsGroup: 65534
      runAsUser: 65534
      runAsNonRoot: true
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ""
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi

alertmanager:
  service:
    type: NodePort
    nodePort: 30092
```

---

## 2. 排障实录一：Helm 源与 Chart 下载断裂（EOF）

- **现象**：执行 `helm install` 时卡在下载 Chart 包阶段，报 `Error: ... EOF`。
- **根因分析**：国内访问 GitHub 或部分公共镜像源极不稳定；同时系统代理与 Helm 的连通性未对齐，下载过程中 TCP 连接被重置。
- **解决方案**：
  - 换用国内稳定的 Coding 源：`https://finops-helm.pkg.coding.net/gocrane/prometheus-community`；
  - 如果依然报错，必须在 Helm 命令前临时挂上代理，或者直接使用 OCI 机制拉取。

---

## 3. 排障实录二：镜像拉取灾难与仓库路径污染

这是耗时最长、踩坑最深的环节。经历了 403 Forbidden、401 Unauthorized、DeadlineExceeded 以及各种诡异的重启。

### 现象 1：DaoCloud / 轩辕 / 华为云镜像代理被拒

- **报错**：`unexpected status from HEAD request to https://m.daocloud.io/... : 403 Forbidden`，提示 `this image is not in the allowlist`。
- **原因**：免费的公共代理对特定路径（如 ghcr.io）或冷门镜像（如 kube-state-metrics）拦截或不支持。

### 现象 2：Helm 变量覆盖引发的“路径拼接叠加”

- **报错**：明明配了阿里云地址，拉取却变成 `m.daocloud.io/registry.cn-hangzhou.aliyuncs.com/...`，直接 403。
- **原因**：在 values.yaml 中配置了全局的 `global.imageRegistry: "m.daocloud.io"`。Helm 渲染时会强制给所有子组件加前缀，覆盖了你自定义的 repository 路径。

### 现象 3：底层网络（彻底解决）

任何花里胡哨的镜像打标签、改路径，都不如直接从底层网络打通来得实在。

**✅ 终极治理方案：为 Containerd 配置系统级代理**

```bash
sudo mkdir -p /etc/systemd/system/containerd.service.d
sudo tee /etc/systemd/system/containerd.service.d/http-proxy.conf > /dev/null <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
# 极其关键：NO_PROXY 必须包含内网网段和 K8s 内部域名，否则集群内部通信会中断
Environment="NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local"
EOF
sudo systemctl daemon-reload
sudo systemctl restart containerd
```

**效果**：配置后，代理跑满 3MB/s，所有被墙的 quay.io、registry.k8s.io 镜像瞬间秒拉。

---

## 3.1 排障实录二（番外）：离线镜像兜底大法（crictl + ctr）

在代理彻底打通前，为了抢救卡死的 Pod，我们尝试了运维最经典的手动兜底方案。

*   **操作过程**：
    1. 尝试用 `crictl` 从国内源拉取替代镜像，但发现 `crictl` 报错 `No help topic for 'tag'`。**（避坑经验：`crictl` 是专为 K8s 设计的调试工具，功能精简，不支持打标签操作。）**
    2. 改用底层容器运行时管理工具 `ctr` 进行操作，强行给镜像“喂饭”：

```bash
# 1. 拉取国内阿里云可用镜像
sudo crictl pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-state-metrics:v2.20.0

# 2. 使用 ctr 强行打上 K8s 期望的原始标签（注意必须指定 k8s.io 命名空间）
sudo ctr -n k8s.io images tag \
  registry.cn-hangzhou.aliyuncs.com/google_containers/kube-state-metrics:v2.20.0 \
  registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0

# 3. 验证打标签是否成功
sudo crictl images | grep kube-state-metrics
```

**为什么没继续用这个方案？**

单节点环境涉及的镜像太多（Grafana、Prometheus、Alertmanager 等），一个个手动拉取并重命名成本极高。这也是为什么我们最终选择从根本上解决网络问题，为 containerd 配置系统代理（即上文的终极治理方案）。

---

## 4. 排障实录三：Admission Webhook 连环坑与 CrashLoopBackOff

在试图绕过镜像拉取时，踩到了 Chart 内部机制的雷。

- **坑 A（版本不兼容）**：为了拉取成功，手动将镜像替换为旧版阿里云 v1.6.8，但 Chart 版本极新，启动参数里包含 `--secret-type`，老版本不认，直接 CrashLoopBackOff。
- **坑 B（关闭 Webhook 引发的事故）**：在 values 中设置了 `admissionWebhooks.enabled: false`。结果 Pod 卡在 ContainerCreating，报错 `secret "monitoring-kube-prometheus-admission" not found`。
  - **根因**：虽然关掉了生成证书的 Job，但 Operator 的 Deployment 模板里依然硬编码挂载了这个 Secret 卷，K8s 找不到 Secret 就拒绝启动。
  - **错误解法**：手动用 openssl 造假证书。虽然卷挂上了，但老版本的 Operator 依然因参数不兼容继续崩溃。
  - **终极解法**：全部推翻，恢复原生。把 values.yaml 里所有对 webhook 的关闭、镜像的篡改全部删掉。既然代理通了，就用官方原生的配置——Helm 自己生成证书、自己拉取镜像，完美闭环。

> **经验教训**：在生产环境使用 Helm 部署复杂架构时，尽量不要去魔改默认的 Core 组件（特别是包含 Admission Webhook 的组件），否则极其容易陷入“按下葫芦浮起瓢”的死循环。

---

## 5. 排障实录四：持久化存储与权限死锁（Permission Denied）

当镜像全绿、Operator 正常运行后，最核心的 prometheus-0 却陷入了 CrashLoopBackOff。

- **现象**：`kubectl logs` 查看到关键报错：
  `Error opening query log file" component=activeQueryTracker file=/prometheus/queries.active err="open /prometheus/queries.active: permission denied"`
- **根因分析**：
  - 在 prom-values.yaml 中指定了使用 hostPath 挂载到宿主机的 `/data/k8s-storage/prometheus` 以节省系统盘空间；
  - 容器内的 Prometheus 进程默认以 nobody（UID 65534）运行，而宿主机的这个目录权限可能是 root:root，导致无法写入。
- **解决方案**：
  1. **宿主机侧**：强行修正目录权限。

```bash
sudo mkdir -p /data/k8s-storage/prometheus
sudo chown -R 65534:65534 /data/k8s-storage/prometheus
```

  2. **K8s 侧**：在 prom-values.yaml 中注入 securityContext，强制 K8s 在挂载卷时调整权限。

```yaml
prometheus:
  prometheusSpec:
    securityContext:
      fsGroup: 65534
      runAsUser: 65534
      runAsNonRoot: true
```

  3. 重新应用 Helm 升级，Pod 秒变 2/2 Running。

---

## 6. 排障实录五：K8s 终极名场面——Namespace 卡死 Terminating

在反复重装的绝望期，执行 `kubectl delete ns monitoring` 后命名空间彻底卡死，这是每一个 K8s 运维都会遇到的经典陷阱。

- **现象**：`kubectl get ns` 中 monitoring 永远处于 Terminating，并且新建同名命名空间报错。
- **根因分析**：Namespace 内部存在无法回收的 Finalizers（终结器）。通常是因为 CRD（自定义资源）没有被彻底清理，或者残留的 Pod 因为节点网络/存储问题无法优雅退出，导致 K8s 一直在等待。
- **解决方案（暴力破解法）**：
  1. 先尝试强杀所有内部资源：

```bash
kubectl delete pod --all -n monitoring --force --grace-period=0
```

  2. 如果依然卡死，直接通过 API 抹除 Finalizer 数组：

```bash
# 导出当前状态 JSON
kubectl get ns monitoring -o json > /tmp/monitoring.json

# 使用 sed 将 finalizers 数组清空
sed -i 's/"finalizers": \[.*\]/"finalizers": []/' /tmp/monitoring.json

# 通过 raw API 强制替换，完成删除
kubectl replace --raw "/api/v1/namespaces/monitoring/finalize" -f /tmp/monitoring.json
```

---

## 7. Grafana 验证与密码获取（易错点）

当所有 Pod 全部 Running 后，直接访问 `http://192.168.2.22:30091`。很多新手会卡在不知道密码，或者在尝试猜测 admin/prom-operator 失败后放弃。

- **错误做法**：瞎猜密码，或者以为安装失败。
- **正确做法**：Chart 生成的密码是随机 Base64 字符串，藏在 Secret 里。

```bash
# 提取真实的 admin 密码
kubectl get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
```

拿到密码后登录，在 `Dashboards -> Kubernetes / Compute Resources / Namespace (Pods)` 中，选中 default 命名空间，即可看到你的 nginx-test 和 mysql-0 的实时 CPU、内存曲线！

---

## 8. 平台化 / GitOps 视角

在企业实际生产中，我们绝不会每次都敲一长串 `helm install` 命令。

- **声明式管理**：这份 prom-values.yaml 就是监控栈的“唯一真实源”。只要你把它推送到 Git 仓库（我们 A/B 阶段做的工作区），不管以后节点宕机还是迁移，只需重新应用一次即可复活整个监控体系。
- **多环境隔离**：通过不同的 Values 文件（如 `dev-values.yaml`、`prod-values.yaml`），可以轻松管理开发与生产环境的 Grafana 密码、存储大小、域名等差异。
- **接入 CI/CD**：未来接入 GitOps（如 ArgoCD）后，只要开发人员修改了 YAML 并合并到主干，GitOps 工具会自动感知并执行 `helm upgrade`，实现完全自动化的配置漂移修复。

---

## 9. SRE 视角复盘与架构演进建议

本次监控栈的落地，不仅是工具部署，更是对 K8s 底层原理与网络架构的一次深度验证。从 SRE（站点可靠性工程）视角，沉淀以下演进建议：

1. **镜像供应链治理（Supply Chain）**：对于国内环境，依赖公网代理拉取镜像不可控。在生产环境中，应部署私有镜像仓库（如 Harbor），通过定时任务将 `quay.io` 和 `registry.k8s.io` 的镜像单向同步至内网，K8s 仅从内网仓库拉取，彻底解决网络与安全合规问题。
2. **容器运行时网络代理**：配置 `containerd` 的 `HTTP_PROXY` 时，必须严格界定 `NO_PROXY` 范围（包括 Pod 网段、Service 网段和集群内部域名），防止内部 API 通信被代理网关拦截，导致集群脑裂或服务发现异常。
3. **存储与权限隔离**：对于 StatefulSet（如 Prometheus），PV 的挂载必须配合 `securityContext` 与 `fsGroup`，确保容器内非 Root 用户（如 65534）对宿主机目录具有属组权限，避免因权限死锁导致的数据丢失或组件无法启动。
4. **配置即代码（Config as Code）**：本次沉淀的 `prom-values.yaml` 应作为监控栈的“单一真实源”纳入 Git 版本控制。未来结合 GitOps（如 ArgoCD），可实现集群配置的自动同步与防漂移（Drift Detection）。

---

## 10. 自测清单

- [ ] 能独立配置 containerd 代理，并解释 NO_PROXY 为什么必须包含内网网段。
- [ ] 知道 `global.imageRegistry` 会引发 Helm 模板的路径覆盖问题。
- [ ] 掌握 `crictl pull` + `ctr -n k8s.io images tag` 的离线镜像兜底操作，并能解释为什么 `crictl` 不能打标签。
- [ ] 掌握 Namespace 卡在 Terminating 的强制释放大法。
- [ ] 能配置 securityContext 解决宿主机 PV 的权限不足（Permission Denied）问题。
- [ ] 能熟练在 Grafana 中提取 Secret 密码，并根据 Namespace 查看 Pod 资源曲线。
