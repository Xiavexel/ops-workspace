# Linux 生产环境实战：网络故障排查

在生产环境中，遇到“网站打不开、服务卡顿”时，网络排查是第一步。不要盲目重启，按照 OSI 模型或 TCP/IP 协议栈自上而下、或自下而上按层级排查。

> **返回总览**：[00-linux-ops-overview.md](00-linux-ops-overview.md)

---

## 1. DNS 解析排查

**核心目的**：确认域名能否正确解析出 IP 地址，以及解析速度是否正常。

### 常用命令

```bash
# 查看本机 DNS 配置
cat /etc/resolv.conf

# 基础解析测试
dig domain.com
nslookup domain.com

# 测试解析耗时
time dig domain.com

# 指定 DNS 服务器对比解析速度（如对比阿里云与谷歌）
dig @223.5.5.5 domain.com
dig @8.8.8.8 domain.com
```

### 运行手段与排查逻辑

- 检查本机配置时注意，Linux 系统的 libc 解析器默认最多只读取前三个 nameserver。
- 不要凭"国内 DNS 更快"的印象下结论：在本机把 `time dig @223.5.5.5 domain.com` 与 `time dig @8.8.8.8 domain.com` 各跑 3 次，用实际耗时对比后再判断（2026-11-24 未在本机复测，此条只给方法，不给结论）。

### 故障解决方案

- **解析超时**：说明 DNS 服务器不可达。检查 `/etc/resolv.conf` 配置，或排查服务器的外网出口防火墙。
- **解析结果错误**：可能是本地 DNS 缓存未刷新或遭遇劫持。尝试更换公共 DNS 测试，或检查本机 `/etc/hosts` 文件是否有误写。
- **`dig` 正常但应用报 `Could not resolve host`**：两者并不矛盾。`dig` 直接问 `/etc/resolv.conf` 里第一个 nameserver，**不读 `/etc/hosts`**；而应用走 libc/NSS，会先读 `/etc/hosts`。所以 `dig` 成功只证明 **DNS 服务器侧**没问题，第一落点是 `/etc/hosts`（旧记录错写最常见）。
- **什么时候才回头查 `/etc/resolv.conf`**：只有 `dig` 自己也超时/失败时。此时记住 libc **只读前三个 nameserver**，再用 `dig @223.5.5.5` / `dig @8.8.8.8` 对比，区分"服务器侧错"还是"客户端配置错"。
- **配了 4 个以上 nameserver 的后果**（推演，未在实机复现）：第 4 个起不参与解析；前三个全部不可用时，解析整体失败，写第 4 个也救不回来。

---

## 2. 连通性与路由追踪

**核心目的**：确认目标 IP 或域名能否走通网络，以及链路的延迟情况。

### 常用命令

```bash
# 测试连通性与丢包率
ping -c 4 domain.com

# 追踪路由路径
traceroute domain.com

# 看从哪块网卡、哪个源地址出去
ip route get 1.1.1.1

# 分族测试：判断到底是 IPv4 还是 IPv6 的问题
ping -4 -c 4 domain.com
ping -6 -c 4 domain.com

# MTU / 分片验证（-M do = 禁止分片；1472 数据 + 8 ICMP + 20 IP = 1500）
ping -M do -s 1472 <网关IP>
ping -M do -s 1473 <网关IP>
```

### 运行手段与排查逻辑

- 查看 `ping` 的丢包率。如果持续丢包，说明网络链路不稳定。
- 查看 `traceroute` 的每一跳延迟，定位网络在哪一跳变慢。
- **特殊现象**：`traceroute` 输出中出现了大量 `* * *`。这通常不是网络断了，而是中间的路由器/防火墙禁用了 ICMP 回显。只要最终目标能 `ping` 通，且最终跳有延迟数据，就属于正常现象。
- **双栈干扰（2026-11-21 实测）**：`ping` 优先走 AAAA 记录；`curl` 有 Happy Eyeballs，会自动回落到 IPv4。所以 **IPv6 路径断、IPv4 通时，`ping` 会 100% 丢包，而 `curl` 仍返回 200**。判据：先 `getent ahosts <域名>` 看有没有 AAAA，再用 `ping -4` / `ping -6`、`curl -4` / `curl -6` 分族看，**别拿单个 `ping` 下结论**。
- **选路验证（2026-11-24 实测）**：`ip route get 1.1.1.1` 输出 `1.1.1.1 via 192.168.2.1 dev eno1 src 192.168.2.22 uid 1000` —— `via` 是网关、`dev` 是出口网卡、`src` 是本机选用的源地址。配置里有路由但走错网卡时，这一条就能看出来。注意 `uid 1000` 表示以当前普通用户身份选路，root 下结果可能不同。
- **MTU 边界（2026-11-24 实测）**：`ping -M do -s 1472 <网关>` 通，回包 1480 字节（1472 数据 + 8 ICMP，加 20 字节 IP 头正好 1500）；改成 `-s 1473` 后**本机直接报 `ping: sendmsg: 消息过长`，100% 丢包**。要点：`-M do` 超过 MTU 时是**本机协议栈拒发**，包根本没出去，**不是中间设备丢的**——别去抓包找"丢包"。

### 故障解决方案

- **完全无法 ping 通**：结合 `traceroute` 看是在哪一跳断掉的。
  - 如果是第一跳断：检查本机网关；
  - 如果是中间断：联系云厂商或运营商；
  - 如果是最后一跳断：**先别直接查防火墙**，按下一条的顺序走。
- **最后一跳无回显时的顺序（推演，未实机验证）**：
  1. 先用**端口层**证实目标是否可达：`curl -I http://<IP>:<端口>`，或在目标侧 `ss -tulnp | grep <端口>` 看有没有 `LISTEN`（`nc -zv <IP> <端口>` 是等价手段，本文件其他小节未涉及，属补充命令）；
  2. 只有端口也超时/拒绝，才去查目标 `firewalld` / `iptables` 是否拦了 ICMP 或该端口；
  3. 判据分层，别混着用：**ICMP 无回显 ≠ 端口不通 ≠ 服务挂了**，三者要各自证实一次。

---

## 3. 端口监听与服务排查

**核心目的**：确认服务是否真的在运行，并且监听了正确的网卡端口。

### 常用命令

```bash
# 查看所有监听端口及对应进程
ss -tulnp

# 查找特定端口（如 8080）
ss -tulnp | grep 8080

# 替代方案，查找占用端口的进程
lsof -i :8080

# 全局状态分布（不只看监听）
ss -s

# 内核层的重传 / 队列溢出 / 丢包计数
netstat -s | grep -Ei 'retrans|overflow|drop'
```

### 运行手段与排查逻辑

- **参数解释**：`-t` 代表 TCP，`-u` 代表 UDP，`-l` 代表监听状态（LISTEN），`-n` 代表不解析域名（显示数字 IP），`-p` 代表显示进程名和 PID。
- **注意看本地地址**：
  - `0.0.0.0:80` 代表监听所有网卡，允许外部访问；
  - `127.0.0.1:80` 代表仅允许本机访问；
  - `*:80` 代表 IPv4 和 IPv6 都监听。

### 故障解决方案

- **服务起不来，报错 `Address already in use`**：说明端口被别的程序占用了。
- **解决步骤**：
  1. 使用 `ss -tulnp | grep <端口号>` 找到占用的进程 PID，确认是否为僵尸进程或配置冲突；
  2. 确认后可执行 `kill -9 <PID>` 强制终止（**不可逆**，进程未落盘的数据直接丢），或修改新服务的配置文件使用其他端口。

### 连接状态与内核计数（2026-11-24 实测）

`ss -tulnp` 只看监听；要看**全局状态分布**用 `ss -s`，要看**内核层的重传/丢包**用 `netstat -s`。

本机实测（Rocky Linux 10.2，2026-11-24）：`TCP: 397 (estab 175, closed 200, orphaned 0, timewait 99)`；Transport 表为 `TCP 197 / IP 161 / IPv6 36`。

- `estab 175` = 已建立连接数；`timewait 99` = 主动关闭方残留；`orphaned 0` 正常，非 0 说明有 socket 已脱离进程。
- `netstat` 在本机存在（`/usr/bin/netstat`，2026-11-24 确认），但**计数未取**，本小节只写命令与看法，标「待取证」。
- **不确定项**：`TCP: 397` 与 Transport 表里 `TCP 197` 两处统计口径不同，我没能确认差异来源，**不要相加当总数用**。

### 端口耗尽与 conntrack 表满（原理推演，未复现）

单机 Homelab 造不出这两类压力，只写判据、不写内核参数调优。

- **本地端口耗尽**：客户端每发起一次连接就占一个本地端口，`TIME_WAIT` 堆积会吃掉可用端口；现象是**新连接直接报 `Cannot assign requested address`**。看 `ss -s` 的 `timewait` 数量，以及 `netstat -s | grep -i failed`。
- **conntrack 表满**：启用连接跟踪（`firewalld` / NAT / Docker 转发常见）时，表满会丢新连接，`dmesg` 出现 `nf_conntrack: table full, dropping packet`。看 `dmesg | grep -i nf_conntrack`，以及 `cat /proc/sys/net/netfilter/nf_conntrack_count` 与 `nf_conntrack_max`。
- 本机 `firewalld` 处于 stop/disable 状态，连接跟踪未必加载，**以上两条均未复现**，属推演。

---

## 4. HTTP 响应与耗时分析

**核心目的**：确认应用层（Nginx/API 等）响应是否正常，以及时间具体消耗在了哪个阶段。

### 常用命令

```bash
# 查看 HTTP 响应头
curl -I http://domain.com

# 测试并输出各阶段耗时（需自行换行以方便阅读）
curl -w "\nDNS: %{time_namelookup}s\nTCP: %{time_connect}s\n首字节: %{time_starttransfer}s\n总耗时: %{time_total}s\n" \
     -o /dev/null -s http://domain.com
```

### 运行手段与排查逻辑

解析 `curl -w` 的输出：

- **`time_namelookup` 大**：说明卡在 DNS 解析阶段。
- **`time_connect` 大**：说明卡在 TCP 握手阶段，通常是网络延迟高或防火墙拦截。
- **`time_starttransfer` 大**：说明 TCP 连接已建立，但服务端处理很慢（如后端代码卡死或数据库慢查询）。

### 故障解决方案

- **返回 502 Bad Gateway**：Nginx 能连通，但后端服务挂了或拒绝连接。检查后端服务进程是否存活，以及后端端口是否正常监听。
- **返回 504 Gateway Timeout**：Nginx 连上了后端，但后端处理超时。检查后端程序日志、数据库慢查询或第三方接口调用是否卡死。

### curl -I 的边界：它证明了什么、不能证明什么（2026-11-24 实测）

- **`-I` 发的是 HEAD**，只要响应头。`Content-Length: 0` 是 HEAD 的正常表现（不返回 body），**不代表页面是空的**，别拿它当"服务异常"。
- **HEAD 与 GET 可能不一致**（待验证）：部分应用/网关对 HEAD 返回 405/501 或不同状态码。要拿业务真实状态码，用 GET 复核：`curl -o /dev/null -s -w "%{http_code}\n" <URL>`。本次实测该目标 HEAD=200、GET=200，两者一致。
- **`-L` 的作用是跟跳转**：不加只看第一跳，遇 301/302 会停在那一跳；加了才跟到最终状态。本次实测 `curl -I -L http://www.baidu.com` 直接返回 200（该目标 http 未跳转），**所以"跟跳"这个行为在你这次回显里没被真正验证**，只验证了命令可用。
- **分层判据（待验证）**：`curl -I https://…` 报证书错误 → **TCP 已通、卡在 TLS**，不是网络不通；`-k` 只能用于定位，不能当结论。本次实测 https 直接 200，无证书问题。
- **拿它当"非 ICMP 的可达性证据"**：`ping` 100% 丢包而 `curl -I` 返回 200，网络层即被排除；要判族就配 `-4` / `-6`，结论按第 2 节的"双栈干扰"读。本次实测 `-4` 与 `-6` **都返回 200**，说明当前 IPv4/IPv6 两条路径都通（与 2026-11-21 那次 IPv6 断、`ping` 100% 丢包的情况不同）。

---

## 5. TCP 抓包与分析（终极排查手段）

**核心目的**：当应用层日志看不出问题时，直接抓取底层数据包，确认数据是否到达服务器，服务器是否响应。

### 常用命令

```bash
# 后台抓取指定端口的 100 个数据包并保存
sudo tcpdump -i any -c 100 -w /tmp/capture.pcap port 80

# 读取抓包文件，仅过滤出 TCP 三次握手相关的包
sudo tcpdump -r /tmp/capture.pcap 'tcp[tcpflags] & (tcp-syn|tcp-ack) != 0'
```

### 运行手段与排查逻辑

- `[S]` 代表 SYN（客户端发起连接请求）。
- `[S.]` 代表 SYN-ACK（服务端同意并返回确认）。
- `[.]` 代表 ACK（确认）。完整的 `[S]` → `[S.]` → `[.]` 代表三次握手成功。
- `[F.]` 代表 FIN，表示请求断开连接。
- `[R]` 代表 RST，表示连接被强制重置。

### 故障解决方案

- **客户端一直连不上**：如果在抓包中只看到客户端发出的 `[S]`，没有看到服务端回复的 `[S.]`，说明请求到达了服务器网卡，但被防火墙拦截，或者后端程序根本没有监听该端口。
- **频繁断连**：如果在抓包中看到大量红色的 `[R]`（RST 重置包），通常是因为服务端的 TCP 半连接队列或全连接队列满了（如并发太高，Nginx 配置的 backlog 不够），触发了内核的自我保护机制。

---

## 6. 生产视角推演：网络架构防护
- **DNS 高可用**：生产环境的 `/etc/resolv.conf` 不应只依赖单一 DNS，建议配置主备两个（如阿里云 + 腾讯云）。在内网架构中，应自建 CoreDNS 或 BIND 提供内部域名解析。
- **TIME_WAIT 堆积**：高并发 Web 服务器（如 Nginx）经常会积累大量 TIME_WAIT 状态。需在 `/etc/sysctl.conf` 中调优 `net.ipv4.tcp_tw_reuse = 1` 和 `net.ipv4.tcp_max_tw_buckets`。
