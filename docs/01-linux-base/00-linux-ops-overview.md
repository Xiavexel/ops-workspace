# 第一阶段终极知识库：传统 Linux 运维硬核底座与全链路避坑指南

本阶段目标：从“桌面运维/基础操作”升维至“生产环境排障与配置”。掌握服务托管、网络排障、性能定位、核心中间件（Nginx/MySQL）的底层运维逻辑，并具备编写生产级脚本的思维。

> **📌 测试环境说明**：本知识库中的实操命令与排障过程，均在个人 Rocky Linux 单节点 Lab 中完成。各阶段末尾的“生产视角推演”探讨的是生产环境的演进方向，请结合实际的集群规模与业务形态进行权衡。

## 文档导航

| 模块 | 速查（本文档） | 明细文档 |
|---|---|---|
| 网络与连通性 | 模块一 | [01-linux-network-troubleshooting.md](01-linux-network-troubleshooting.md) |
| 系统服务/日志/磁盘 | 模块二 | [02-linux-service-log-disk-management.md](02-linux-service-log-disk-management.md) |
| LVM 卷管理与在线扩容 | 模块二（存储扩展） | [06-lvm-and-filesystem-management.md](06-lvm-and-filesystem-management.md) |
| 用户/组/权限/sudoers（umask·ACL·mask） | 模块二（权限） | [07-user-group-acl-permissions.md](07-user-group-acl-permissions.md) |
| 主机暴露面与 SSH 加固 | 模块二（安全加固） | [08-host-exposure-and-ssh-hardening.md](08-host-exposure-and-ssh-hardening.md) |
| 性能瓶颈（CPU/内存/IO） | 模块三 | [03-performance-bottleneck-troubleshooting.md](03-performance-bottleneck-troubleshooting.md) |
| Nginx 网关 | 模块四 | [04-nginx-config-troubleshooting.md](04-nginx-config-troubleshooting.md) |
| MySQL 运维 | 模块五 | [05-mysql-ops-and-tuning.md](05-mysql-ops-and-tuning.md) |
| Shell 工程化 | 模块六（速查版） | [A阶段-Shell工程化实战总结.md](../02-devops-journey/A阶段-Shell工程化实战总结.md) |
| Python 自动化 | 模块七（速查版） | [B阶段-Python运维开发实战总结.md](../02-devops-journey/B阶段-Python运维开发实战总结.md) |
| K8s 监控与排障 | 模块八（速查版） | [C阶段（上）-K8s监控部署与云原生排障实战总结.md](../02-devops-journey/C阶段（上）-K8s监控部署与云原生排障实战总结.md) |


---

## 模块一：网络与底层连通性排障

**核心目标**：快速定位“服务打不开”是 DNS、网络、端口还是应用层的问题。

### 1. 核心排查逻辑

- **DNS 排查**：`dig domain.com`。国内环境用 `223.5.5.5` 通常比 `8.8.8.8` 快得多。
- **路由追踪**：`traceroute domain.com`。**避坑**：如果输出中出现大量 `* * *`，通常不是断网，而是中间的路由器/防火墙禁用了 ICMP 回显。只要目标能 `ping` 通就没事。
- **端口监听**：`ss -tulnp | grep <端口>`。看服务是监听在 `0.0.0.0`（对外）还是 `127.0.0.1`（仅本机）。
- **HTTP 耗时**：`curl -w "\nTCP: %{time_connect}s\n首字节: %{time_starttransfer}s\n"`。
  - `time_connect` 大：网络延迟高。
  - `time_starttransfer` 大：服务端处理慢（代码死循环或数据库慢查询）。
- **抓包分析**：`tcpdump -i any port 80`。如果只看到 `[S]`（客户端请求）没看到 `[S.]`（服务端响应），说明被防火墙拦截或服务根本没监听。

**明细文档**：[01-linux-network-troubleshooting.md](01-linux-network-troubleshooting.md)

---

## 模块二：Linux 系统与底层存储避坑

### 1. 磁盘爆满与幽灵文件（极度经典）

- **现象**：用 `rm -f` 删除了几十 G 的大日志，但 `df -h` 看磁盘依然 100% 满载。
- **原因**：文件虽然删了，但被 Java/Nginx 等进程占着“文件描述符（FD）”，Linux 内核不释放底层数据块。
- **解决**：
  1. `sudo lsof | grep deleted` 找出 PID 和 FD。
  2. `echo "" | sudo tee /proc/<PID>/fd/<FD> > /dev/null` 强制清空，无需重启进程即可释放空间。

### 2. Systemd 服务托管坑点

- **重启被锁定**：配置了 `Restart=always`，但服务连续启动失败（默认 10 秒内超过 5 次，对应 `StartLimitIntervalSec`/`StartLimitBurst` 的默认值，不同发行版可能调整），会被 Systemd 锁定为 `failed`。修复代码后，必须执行 `sudo systemctl reset-failed <服务名>` 才能重新启动。
- **覆盖配置**：直接改 `/usr/lib/...` 会被系统升级覆盖。必须用 `sudo systemctl edit <服务名>` 生成 `override.conf` 片段。
- **日志无限大**：Systemd 自带 `journalctl` 有默认大小限制，但传统应用日志（如 Nginx）必须配 `logrotate`（`size 100M`, `rotate 7`, `compress`）。**避坑**：`logrotate` 中 `size` 与 `daily` 并存时只按 `size` 判断（详见 02 明细文档）。

### 3. 扩容成功但 `df` 不变（三类根因）

- **A 层次没走完**：`lvextend` 只改块设备长度，`df` 读的是 XFS 超级块里的 `blocks` 字段，必须再执行 `xfs_growfs <挂载点>`。判定：`blockdev --getsize64` 已变大而 `df` 不变。
- **B 对象错位**：扩的是某块 LV，`df` 看的却是“该路径所在文件系统”的超级块，两者可以是两块不同的设备。判定：`findmnt -no SOURCE <路径>` 归一化后与目标 LV 不一致。
- **C 挂载层级错**：`mount` 是叠加不是替换，后挂的设备遮住先挂的，`df` 只显示最上层。判定：`umount` 一次后 `df` 数字突变。
- **容量对不上标称**：每个 PV 固定预留 4MiB 给 LVM 元数据（`not usable 4.00 MiB`），10GiB 盘只有 2559 个 PE；文件系统自身还要吃元数据（1GiB LV `mkfs.xfs` 后 `df` 只有 960M）。规划按 PE 算，留 5% 余量。

### 4. 权限判据：umask / mask / effective

- **默认权限**：`文件 = 666 & ~umask`，`目录 = 777 & ~umask`；`022` → `644/755`，`077` → `600/700`。新文件的属组取自进程 egid，不是父目录属组（要继承得给目录设 SGID）。
- **目录的 `x` 是穿越位**：只有 `r` 没 `x` → 看得见名字、进不去；只有 `x` 没 `r` → 进得去但 `ls` 列不出名字。看目录自身要用 `ls -ld`，`ls -l dir/*` 根本看不到目录。
- **ACL 的判据只有 `#effective`**：实际生效 = 条目 ∩ `mask`，而 `mask` 只约束 named user / named group / `group::`。`setfacl -m` 每次都会重算 mask，所以要制造限制必须"条目先设完、最后单独 `m::`"；文件有 ACL 时 `chmod` 的组位改的是 mask，不是 `group::`。
- **排查顺序（错一层结论就错）**：先 `ls -ld` / `stat -c` 定语主与八进制位 → 再 `getfacl` 看有没有 ACL → 最后**只看 `#effective`** 判能不能用。
- **sudoers 的两条反直觉**：规则里**写了参数** → 命令行必须精确匹配（多一个 `-n 5` 就拒）；**不写参数** → 任意参数都放行。所以"给某人只放开某条命令"的正确形态是**root 拥有的包装脚本**（参数写死、不转发 `$@`），安全边界在脚本代码里，不在 sudoers 行里。免密测试一律带 `sudo -n`，否则 `timestamp_timeout` 会让结论失真。

| 我要判断…… | 看什么 | 判据 |
|---|---|---|
| 新文件/目录会是什么权限 | `umask` | `666 & ~umask` / `777 & ~umask`；022→644/755，077→600/700 |
| 权限几位、属主是谁 | `stat -c` | 八进制 + 属主:属组 + 路径一行给全，比 `ls -l` 的 rwx 串更适合写报告 |
| 目录本身的权限 | `ls -ld <目录>` | `ls -l dir/*` 看不到目录：`*` 已被 shell 展开成文件列表 |
| 能否进入目录 | 目录是否有 `x` | 无 `x` 一律进不去；有 `x` 无 `r` 则进得去但 `ls` 列不出名字 |
| ACL 是否设上 | `getfacl -p <路径>` | 出现 `user:名字` 与 `mask::` 行 |
| ACL 为何不生效 | `#effective:` 列 | 生效 = 条目 ∩ mask；显示 `#effective:---` 即被裁光 |
| 谁裁的权限 | `mask::` | 被 `chmod` 的组位或 `setfacl -m` 的重算改过 |
| 某个账号现在有哪些 sudo 权限 | `sudo -l -U <用户>` | 加 `-U` 查别人（需 root）；输出只应出现你写的那几条，多一条都算超授 |
| sudo 规则写了却没生效 | `visudo -c` / `sudo -l -U <用户>` | 先看语法与权限（`0440`）；`sudo -l` 里压根没条目 → 多半是文件名含 `.`，被 `/etc/sudoers.d` 静默跳过 |

### 5. 暴露面与 SSH 加固

- **先读 `ss` 再谈防火墙**：`sudo ss -tulnp | sort -k4` 逐行回答"谁在听、听在哪、谁需要"。`firewalld` 是 `inactive` 不代表没规则——K8s/Docker 的 `KUBE-*`/`DOCKER-*` 链在 `nft` 里，而 `INPUT` 可能仍是 `policy accept`（等于主机侧不设防）。
- **`firewall-cmd --add-port` 管不到容器端口**：Docker 直接插 `DOCKER` 链、NodePort 走 DNAT；"规则加了却没效果"第一步是确认流量走哪条链，而不是继续加规则。
- **端口 owner 是 `systemd(pid=1)` = socket 激活**：去 `systemctl list-units --type=socket` 找同端口（本机 `9090` 是 Cockpit，不是 Prometheus）。
- **SSH 加固顺序即安全**：先建密钥通道并验证 → 再禁密码 → 最后禁 root。判据取**生效值** `sshd -T`，不取文件内容。
- **`sshd` 同一关键字先匹配先赢**：`sshd_config.d/` 里若 `01-` 写了 `PermitRootLogin yes`，你的 `99-` 就是废的。用 `grep -rn PermitRootLogin` 定位，改那个"先"的，别搞文件名前缀竞赛。
- **主机密钥变更先核对指纹**：`sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 与客户端收到的比对，一致才 `ssh-keygen -R <host>` 清旧记录；**绝不用 `StrictHostKeyChecking=no`**。

**明细文档**：[02-linux-service-log-disk-management.md](02-linux-service-log-disk-management.md)　[06-lvm-and-filesystem-management.md](06-lvm-and-filesystem-management.md)　[07-user-group-acl-permissions.md](07-user-group-acl-permissions.md)　[08-host-exposure-and-ssh-hardening.md](08-host-exposure-and-ssh-hardening.md)

---

## 模块三：性能瓶颈排查（CPU/内存/IO）

**核心目标**：服务器卡顿时的快速止血。

- **CPU/负载**：`uptime` 看负载，`top` 按 `P` 排序。`load average` 不要超过 CPU 核心数。
- **内存**：`free -h` 看 **`available`** 列（不要被 `used` 欺骗，Linux 会用空闲内存做缓存）。
- **OOM Killer**：服务无故消失，查 `dmesg | grep -i oom`，看是不是内存耗尽被内核强制杀死了。
- **磁盘 IO**：`iostat -x 1` 看 `%util` 是否到 100%，`iotop -o` 找读写大户。如果负载极高但 CPU 空闲，查 `ps` 里是否有大量处于 `D` 状态（不可中断）的进程。

**明细文档**：[03-performance-bottleneck-troubleshooting.md](03-performance-bottleneck-troubleshooting.md)

---

## 模块四：Nginx 生产级网关与坑点

### 1. 核心排障逻辑

- **502 Bad Gateway**：Nginx 能连通，但后端挂了。检查后端进程和端口。
- **504 Gateway Timeout**：后端处理超时。检查后端日志或数据库慢查询。

### 2. 经典避坑指南

- **总是返回默认欢迎页**：
  - **坑 1（IPv6 截胡）**：本地 `curl` 默认走 IPv6，如果 `server` 块只写了 `listen 80;`，请求会被主配置的 `[::]:80` 抢走。解决：加 `listen [::]:80;`。
  - **坑 2（默认抢占）**：主配置有 `default_server` 截胡。解决：注释掉默认配置。
- **限流配了但不生效（全是200）**：
  - **坑 1（短路执行）**：`location` 里用了 `return 200`。Nginx 在 `REWRITE` 阶段直接返回，根本走不到 `PREACCESS` 阶段的限流模块。解决：去掉 `return`，改为访问真实文件或 `proxy_pass`。
  - **坑 2（测试太弱）**：用 `for` 循环串行请求，未触发限流窗口。解决：用 `ab -n 50 -c 10`。
- **反向代理报 404**：`proxy_pass http://api:5000`（无斜杠），会把完整 URI 转发给后端。若后端无此路径前缀，需改成 `proxy_pass http://api:5000/;`（带斜杠剥离前缀）。
- **改配置未生效**：每次修改后必须 `sudo nginx -t` 检查语法，再 `sudo systemctl reload nginx` 平滑重载。

**明细文档**：[04-nginx-config-troubleshooting.md](04-nginx-config-troubleshooting.md)

---

## 模块五：MySQL 生产运维与坑点

### 1. 安全与权限

- 必须运行 `mysql_secure_installation` 移除匿名用户、禁止 root 远程登录。
- 严禁业务用 root 账号，必须建独立业务库和用户，按需赋权。

### 2. 备份与认证坑点

- **备份报错**：普通账号执行 `mysqldump` 报错 `Access denied; you need (at least one of) the PROCESS privilege(s)`。
  - **解决**：千万别给业务账号乱加高权限，直接在命令中加 `--no-tablespaces` 即可。
- **认证报错**：Python/Docker 连 MySQL 8.0 报错 `cryptography required`。
  - **解决**：客户端装 `cryptography` 库。**⚠️ MySQL 8.4 起 `mysql_native_password` 已默认移除**，"降级插件"的老办法在 8.4 上会报 `Plugin ... is not loaded`，8.4+ 只能让客户端支持 `caching_sha2_password`。

### 3. 慢查询排查

- 开启 `slow_query_log`，`long_query_time = 1`。
- 查日志 `/var/lib/mysql/<hostname>-slow.log`，重点看 `Query_time`（耗时）和 `Rows_examined`（扫描行数），找开发加索引。

**明细文档**：[05-mysql-ops-and-tuning.md](05-mysql-ops-and-tuning.md)

---

## 模块六：Shell 脚本工程化（生产级基础）

> 本模块为速查版，完整版（含完整代码骨架、并发示例、Systemd 告警闭环与自测清单）见 [A阶段-Shell工程化实战总结.md](../02-devops-journey/A阶段-Shell工程化实战总结.md)。

**核心目标**：写出有防御性编程思维、能挂到 cron/CI 上放心运行的脚本。

### 骨架四件套

1. **严格模式**：`set -Eeuo pipefail`（命令错即退、未定义变量报错、管道错误捕获）。
2. **收紧分隔符**：`IFS=$'\n\t'`（防止文件路径里有空格导致分词错误）。
3. **异常捕获与清理**：`trap 'on_error ${LINENO}' ERR` 和 `trap cleanup EXIT`（保证临时文件释放，打印错误行号）。
4. **参数解析**：`getopts`。

### 经典脚本坑点

- **丢数据**：`while read` 读取文件时，最后一行如果没有换行符，会丢数据。必须用 `|| [[ -n "${name}" ]]` 兜底。
- **意外退出**：`((FAILS++))` 当变量为 0 时返回值为 1，在 `set -e` 下会导致脚本意外崩溃。应改为 `FAILS=$((FAILS + 1))`。

---

## 模块七：Python 运维开发（生产级基础）

> 本模块为速查版，完整版见 [B阶段-Python运维开发实战总结.md](../02-devops-journey/B阶段-Python运维开发实战总结.md)。

**核心目标**：用 Python 处理复杂的 API 请求、数据解析与并发 SSH 管理。

### 核心避坑指南

- **并发监控陷阱**：使用 `ThreadPoolExecutor` 时，子线程返回的元组（如 `(url, False, "Timeout")`）在 Python 中**永远为真**。主线程必须解包后再判断 `ok` 状态，否则所有失败都会被漏报。
- **SSH 批量执行泄漏**：使用 `paramiko` 批量连机器时，必须在 `finally` 块中执行 `ssh.close()`，否则短时间内会积累大量僵尸连接，导致目标机 SSH 拒绝服务。同时 `exec_command` 必须加 `timeout`。
- **代理环境干扰**：`requests` 默认会读取系统的 `HTTP_PROXY` 环境变量。内网监控脚本如果全报错，务必在代码中加 `trust_env=False` 或显式指定 `proxies={"http": None, "https": None}` 排除干扰。

---

## 模块八：K8s 监控与云原生排障（生产级基础）

> 本模块为速查版，完整版见 [C阶段（上）-K8s监控部署与云原生排障实战总结.md](../02-devops-journey/C阶段（上）-K8s监控部署与云原生排障实战总结.md)。

**核心目标**：在极其恶劣的国内网络环境下，用 Helm 部署全套 Prometheus 监控栈，并解决底层死锁。

### 核心避坑指南

- **镜像拉取灾难**：不要迷信 Docker 镜像代理。在 containerd 层面配置系统级 `HTTP_PROXY` 才是终极解法。**避坑**：`NO_PROXY` 必须包含 `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local`，否则 K8s 内部通信会被代理拦截，直接导致集群脑裂。
- **Helm 变量污染**：如果配置了全局 `global.imageRegistry`，Helm 会强制给所有子组件加前缀，导致拉取地址变成 `代理地址/原本正确的镜像地址` 引发 403。
- **PV 挂载权限死锁**：Prometheus 容器默认用 `65534` 用户运行，挂载宿主机 hostPath 时极易报 `Permission Denied`。必须在 values.yaml 里配置 `securityContext` 的 `fsGroup: 65534`。
- **Namespace 删不掉**：一直卡在 `Terminating` 是因为内部的 CRD 有 Finalizer 锁死。终极解法：导出 JSON，用 `sed` 清空 `finalizers` 数组，然后通过 `kubectl replace --raw` 强杀。