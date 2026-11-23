# 08 主机暴露面收窄与 SSH 加固（firewalld 决策 · 服务绑定 · 密钥登录）

> **边界声明**：本文命令与输出均来自 Rocky Linux 10.2 单机 Lab 实测（2026-11-23），机器为 Xeon E2124 / 4 核 32G，同时跑 Docker、单节点 K8s、MySQL、Nginx、Cockpit。
> **未执行**：SSH 改端口、fail2ban、SELinux 恢复 `enforcing`、多节点场景下的端口策略。其中"改端口"与"fail2ban"是**刻意不做**（见第 7 节决策记录），不是遗漏。

## 1. 核心目的

回答三个具体问题，而不是背 firewalld 命令：

1. 这台机器**实际对外暴露了什么**——不是看配置文件，是看 `ss` 与 `nft` 的真实状态。
2. 在这台"K8s + Docker + 裸服务混跑"的机器上，**加 firewalld 是收益还是负担**。
3. 在不引入新组件的前提下，把攻击面收窄到可接受范围——**哪些靠改服务配置就能解决，哪些必须动 SSH**。

核心判断：**主机防火墙的价值取决于它能不能管住真正的流量路径**。管不住的规则越多，排障越乱。

## 2. 现状：从 `ss` 与 `nft` 读出真实暴露面

### 2.1 采集命令（只读）

```bash
# 防火墙状态（很多人以为装了就在跑）
sudo systemctl is-active firewalld ; sudo systemctl is-enabled firewalld
sudo firewall-cmd --state

# 底层规则（firewalld 没跑时，规则全在 nft 里）
sudo nft list ruleset | grep -E 'DOCKER|KUBE|FLANNEL'
sudo nft list chains

# 监听端口 + 归属进程
sudo ss -tulnp | sort -k4

# SSH 的真实生效值（不是看文件，是看 sshd 解析后的结果）
sudo sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|listenaddress)'

# SELinux 模式
getenforce ; sudo grep -E '^SELINUX=' /etc/selinux/config
```

### 2.2 实测结果

| 项 | 实测值 |
|---|---|
| 发行版 / 内核 | Rocky Linux 10.2（Red Quartz）/ `6.12.0-211.74.1.el10_2.x86_64` |
| firewalld | `inactive`、`disabled`、`--state` = `not running` |
| `INPUT` 链 | `type filter hook input priority filter; policy accept` |
| nft 里的 K8s 链 | `KUBE-SERVICES`、`KUBE-NODEPORTS`、`KUBE-FIREWALL`、`KUBE-PROXY-FIREWALL` |
| nft 里的 Docker 链 | `DOCKER`、`DOCKER-FORWARD`、`DOCKER-CT`、`DOCKER-INTERNAL`、`DOCKER-BRIDGE` |
| SELinux | `Permissive`，且 `/etc/selinux/config` 里写的也是 `SELINUX=permissive`（**永久**） |

端口与归属（`sudo ss -tulnp` 摘要）：

| 端口 | 绑定 | 归属 | 判断 |
|---|---|---|---|
| 22 | `0.0.0.0` + `[::]` | `sshd` | 必需 |
| 80 | `0.0.0.0` + `[::]` | `nginx` | 业务 |
| 3306 | `*` → **收紧后 `127.0.0.1`** | `mysqld` | **该收** |
| 33060 | `*` → **已消失** | `mysqld`(mysqlx) | **该收** |
| 8095 | `0.0.0.0` / `[::]` | `docker-proxy` | 容器发布端口 |
| 9090 | `*` | `systemd`(pid 1) | **Cockpit**（socket 激活，见 §4.2） |
| 9100 | `*` | `node_exporter` | 监控 |
| 6443 | `*` | `kube-apiserver` | K8s 控制面 |
| 10250 | `*` | `kubelet` | K8s 节点 |
| 10256 | `*` | `kube-proxy` | K8s 节点 |
| 8081 / 8472(udp) | `*` | `flanneld` | CNI |
| 2379 / 2380 | `192.168.2.22` | `etcd` | 仅该网卡 |
| 2379(127.0.0.1)、2381、10248、10249、10257、10259、44019 | `127.0.0.1` | 各组件 | 已正确只绑本地 |

### 2.3 关键判读：三套规则并存，`INPUT` 却全放行

1. **firewalld 没启用** —— 它不是"装了就管"，`disabled` 状态下一条规则都没生效。
2. **K8s 与 Docker 各自往 nft 里写链** —— 但它们主要作用于 `FORWARD`/`NAT`（容器转发、NodePort DNAT）。
3. **面对外部连接的 `INPUT` 链是 `policy accept`** —— 所以任何监听在 `*` 或 `0.0.0.0` 的端口，同网段可直接连。

**结论：这台机器"有规则、但主机侧不设防"。** 真正挡住攻击面的只有各服务自身的认证（MySQL 密码、K8s 客户端证书、Cockpit 登录），而不是防火墙。

## 3. 决策：这台机器**不上 firewalld**

三条基于本机实证的理由：

| 理由 | 本机证据 |
|---|---|
| 已经是第三套规则 | `KUBE-*` 与 `DOCKER-*` 都在 nft 里，再加 firewalld 是第四套 |
| firewalld 管不到 Docker 发布的端口 | Docker 直接插 `DOCKER` 链，`firewall-cmd --add-port` 对已发布容器端口无效（会出现"规则加了仍不通/仍通"） |
| K8s 节点上 firewalld 是已知高冲突组合 | NodePort 走 DNAT，firewalld 改 `INPUT` 与之打架，排障成本高于收益 |

替代路径：**服务侧绑定收紧 + （必要时）nft 限源**。这样"谁管流量"只有两层：内核 nft 规则（K8s/Docker 自管）+ 服务自身绑定，不引入第三套语义。

## 4. 服务侧收紧：不碰 iptables 的做法

### 4.1 MySQL：从 `*` 收到 `127.0.0.1`

**改前**（实测）：`3306` 绑 `*`、`33060`(mysqlx) 也绑 `*`，且 `/etc/my.cnf` 与 `/etc/my.cnf.d/*.cnf` 中**没有任何 `bind-address`** —— 默认即全网卡。

```bash
# 1) 确认主配置有 includedir（决定能否用 drop-in）
cat /etc/my.cnf            # 应含 !includedir /etc/my.cnf.d
ls -l /etc/my.cnf.d/

# 2) 写 drop-in（zz- 前缀保证最后加载）
sudo tee /etc/my.cnf.d/zz-bind-local.cnf >/dev/null <<'EOF'
[mysqld]
bind-address = 127.0.0.1
mysqlx = OFF
EOF

sudo systemctl restart mysqld
sudo ss -tlnp | grep -E ':3306|:33060'
```

实测结果：只剩 `127.0.0.1:3306` 一行，`33060` 完全消失；业务侧 `curl 127.0.0.1:8095` 仍返回 `200`。

**回滚**（`/etc/my.cnf.d/zz-bind-local.cnf` 删除后 `systemctl restart mysqld`）：

```bash
sudo rm /etc/my.cnf.d/zz-bind-local.cnf && sudo systemctl restart mysqld
```

**坑**：`mysqlx = OFF` 若被拒（unknown variable），改用 `mysqlx = 0`；重启会让现有连接断一次。

### 4.2 识别 socket 激活：`9090` 不是 Prometheus

`ss` 里 `9090` 的归属显示为 `users:(("systemd",pid=1,fd=...))` —— **进程是 1 号 systemd**，这几乎只有一种解释：socket 激活。

```bash
systemctl list-units --type=socket --state=listening | grep -Ei '9090|cockpit'
sudo systemctl status cockpit.socket --no-pager | head -6
```

实测：`cockpit.socket  loaded active listening  Cockpit Web Service Socket`，且 `enabled`（开机自启）。

**判读方法**：`ss` 里端口 owner 是 `systemd(pid=1)` 时，去 `systemctl list-units --type=socket` 找同端口，而不是猜"是不是某个服务改名了"。

本机决策：**Cockpit 保留**（需要它做图形化管理），靠其自身登录认证兜底。若将来要限源，可用 nft 限 `192.168.2.0/24`，但注意该规则重启即失效，需另做持久化（本次未做）。

### 4.3 保留项与理由

| 保留 | 理由 |
|---|---|
| `6443` / `10250` / `10256` / `8081` / `8472` | K8s 单节点必需；`6443` 有客户端证书认证，`10250` 有 kubelet 认证；机器在 `192.168.2.0/24` 内网 |
| `9090` Cockpit | 日常管理要用 |
| `80` / `8095` | 业务与容器发布端口 |

明确记录：**若将来把该机暴露到公网，`6443`/`10250` 必须收到 `127.0.0.1` 或做限源**，这是硬要求，不是建议。

## 5. SSH 加固：顺序即安全

### 5.1 加固前的实测现状

```
port 22
permitrootlogin yes          ← 最大口子：root 可被密码爆破
passwordauthentication yes
pubkeyauthentication yes
```

### 5.2 四步，顺序不能反

**第 1 步｜客户端生成/复用密钥**（本机复用已有 `id_rsa`，未新建）

**第 2 步｜把公钥装到服务端**

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys <<'EOF'
<客户端公钥一行，完整粘贴或上传文件后 cat 追加>
EOF
chmod 600 ~/.ssh/authorized_keys

# 完整性校验：1 行、3 段、大小与客户端一致
wc -l ~/.ssh/authorized_keys ; awk '{print NF}' ~/.ssh/authorized_keys ; ls -l ~/.ssh/authorized_keys
```

实测做法：把客户端 `id_rsa.pub`（584 字节）经 SFTP 上传，先 `sha256sum` 与客户端比对（一致：`f90315d7…c194b`），再 `cat >>` 追加，`awk '{print NF}'` 得到 `3`。

**第 3 步｜用密钥登录验证（不做完绝不进第 4 步）**

命令行验证（`BatchMode=yes` 保证不会偷偷用密码）：

```bash
ssh -o BatchMode=yes -i ~/.ssh/id_rsa xia@192.168.2.22 "whoami; echo RC=\$?"
```

实测：`xia` / `RC=0`，零交互。

**第 4 步｜禁密码 + 禁 root**

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF

sudo sshd -t && echo "配置语法OK"      # 不通过就别 reload
sudo systemctl reload sshd              # reload 不断开现有连接
sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|pubkeyauthentication)'
```

实测（修正后）：`permitrootlogin no`、`passwordauthentication no`、`pubkeyauthentication yes`。

**独立验证**（比 `sshd -T` 更硬，证明运行时对客户端的实际响应）：

```bash
# 只给密码去试，应被拒且括号里没有 password
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=yes xia@192.168.2.22 true
```

实测输出：`Permission denied (publickey,gssapi-keyex,gssapi-with-mic)` —— **括号中无 `password`**，密码认证确实关闭。

**回滚**（现有会话或物理键盘）：

```bash
sudo rm /etc/ssh/sshd_config.d/99-hardening.conf && sudo systemctl reload sshd
```

## 6. 故障复盘（本次真实踩到的四个）

### 6.1 `PermitRootLogin no` 写了却不生效

- **现象**：`99-hardening.conf` 里明确写了 `PermitRootLogin no`，`sshd -T` 仍是 `yes`；但同一文件里的 `PasswordAuthentication no` 却生效了。
- **根因**：`sshd` 对同一关键字是**先匹配先赢**，不是后覆盖。`/etc/ssh/sshd_config.d/` 下还存在 `01-permitrootlogin.conf`（9月16日装系统时写入，`PermitRootLogin yes`），按字母序先于 `99-`，于是它说了算。`password` 只在 `99-` 里出现，所以能生效。
- **定位命令**：
  ```bash
  sudo grep -rn 'PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
  ```
- **解决**：改那处 `yes` 本身（备份后 `sed -i 's/^PermitRootLogin.*/PermitRootLogin no/'`），**不要用"把自己的文件改名成 `00-` 压过去"的办法** —— 那会让目录里同时留着互相矛盾的 `01: yes` 与 `00: no`，半年后没人看得懂哪个生效。
- **纪律**：一个配置项只留一个真相源；`sshd -T` 只告诉你结果，不告诉你出处，所以排查必须用 `grep -rn` 回到文件。

### 6.2 `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`

- **现象**：客户端首次用密钥连接被直接拒绝（exit 255），提示主机密钥变更，`Offending ECDSA key in known_hosts:3`。
- **根因**：客户端 `known_hosts` 里的 `192.168.2.22` 是旧身份（记录于 10月25日，含 3 条不同密钥类型），而当前系统的主机密钥是 9月16日安装时生成的，两者不同。
- **正确处置（顺序不能省）**：
  1. 在**可信会话**里核对服务端自己的主机密钥指纹：`sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
     → 实测 `SHA256:7DfJMH47mRzRLno9x/Dt8fdIOTWawSYQwWQthElCNO4`
  2. 与客户端收到的指纹比对，**一致**才可认定是合法变更（此例一致）；
  3. 客户端清旧记录：`ssh-keygen -R 192.168.2.22`（自动备份为 `known_hosts.old`）；
  4. 重连。
- **绝对不要做的事**：用 `StrictHostKeyChecking=no` 或直接删 `known_hosts` 绕过。那恰好关掉了唯一能发现中间人的机制。`accept-new` 只接受"新主机"的首次密钥，对"存在但已变更"仍会拒绝——这正是它比 `no` 安全的地方。

### 6.3 客户端的"静默回退"会给你假成功

- **现象/风险**：服务端同时允许密码与公钥时，SSH 客户端（如 WindTerm）在密钥链路失败后会**自动退回密码登录**，界面上看起来"登录成功"，于是误判"密钥已生效"。
- **验证做法**：测试密钥时把客户端的"密码认证/键盘交互"**全部取消勾选**，只留公钥。此时登录成功只可能来自密钥。
- **为什么重要**：若跳过这步，后续执行 `PasswordAuthentication no` 就会把自己锁在外面，而所有"成功"的假象都发生在禁密码之前。

### 6.4 公钥粘贴被折行 / 权限不对 → sshd 静默忽略

- **现象**：公钥装上了但登录仍 `Permission denied (publickey)`，且服务端日志没有明显报错。
- **根因**：`authorized_keys` 中的公钥必须是**一整行**；被编辑器折成两行即失效。另外目录必须 `700`、文件必须 `600`，属主必须是登录用户——**权限不对时 sshd 直接忽略该文件且不提示**。
- **判据**：`awk '{print NF}' ~/.ssh/authorized_keys` 应为 `3`（类型 / 密钥串 / 注释）；`ls -l` 应为 `-rw-------` 且属主为登录用户。
- **更强判据**：上传后用 `sha256sum` 与客户端原文件比对，避免"看起来像、其实截断"。

## 7. 决策记录：刻意不做的三件事

| 不做 | 理由 |
|---|---|
| SSH 改端口（22 → 高位） | 收益低（扫描器同样扫高位），成本是客户端配置与排障；当前无自动化依赖 22 |
| 装 fail2ban | 内网 homelab，无公网暴露面；等真有对外端口再上 |
| SELinux 恢复 `enforcing` | 装 K8s 时按建议置为 `permissive`，贸然恢复会打断 kubelet/容器挂载，需专门排 AVC |

## 8. SELinux：现状是"技术债"，不是"最佳实践"

- 实测：`getenforce` = `Permissive`，且 `/etc/selinux/config` 里 `SELINUX=permissive` —— **永久**，不是临时。
- 含义：策略仍在运行、仍产生 AVC 记录，但**不阻断**。等于"有审计、无防护"。
- 代价测量：`sudo du -sh /var/log/audit` = **18M**；`ausearch -m avc -ts today | grep -c 'type=AVC'` = **0**。当前负载未触发策略，日志未膨胀。
- 生产视角：`permissive` 是安装期的降门槛手段，不能写进"安全基线"。正确形态是 `enforcing` + 正确的容器标签（`container-selinux`）。本项目暂不恢复，但把它登记为**已知技术债**。

## 9. 生产视角推演：攻击面收窄与运维入口

1. **暴露面清单应该是"表"，不是"印象"**：`ss -tulnp` 一行行过，每行回答"谁在听、听在哪、谁需要它"。本机从 20+ 个端口中筛掉了 2 个（`3306`/`33060`），这一步的收益比加十条防火墙规则更直接。
2. **防火墙的边界要事先讲清**：Docker 与 K8s 的规则不走 `INPUT`，`firewall-cmd --add-port` 对它们无效。任何"加了规则却没效果"的排障，第一步都是确认**流量走的是哪条链**，而不是继续加规则。
3. **SSH 加固的顺序就是安全本身**：先建新通道、验证、再关旧通道。反过来做，最坏结果是失去远程访问，只能靠物理/带外控制台。**没有带外通道的机器，做这类变更前必须确认物理可达**。
4. **配置优先级是隐形故障源**：`sshd` 的"先到先得"、`systemd` 的 drop-in 覆盖、`my.cnf` 的 `includedir` 顺序——它们的共同点是"生效值 ≠ 你改的那个文件"。所以判据永远取**生效值**（`sshd -T`、`systemctl show`、`ss`），而不是文件内容。
5. **服务器上的私钥是反模式**：本机 `~/.ssh/` 存在 `id_ed25519` 私钥（用途未确认）。私钥应只存在于客户端；服务器侧只放公钥。若某些工具确实需要服务端私钥（如拉取私有仓库），应使用**专用、最小权限**的部署密钥，而不是通用个人密钥。
