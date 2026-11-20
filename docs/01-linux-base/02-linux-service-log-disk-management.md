# Linux 生产环境实战：系统服务、日志与磁盘管理

生产环境中，保障业务持续运行的核心是“服务自动化托管”、“日志可追溯”以及“存储不爆满”。本章总结系统级守护与存储危机的处理标准。

> **返回总览**：[00-linux-ops-overview.md](00-linux-ops-overview.md)

---

## 1. Systemd 服务托管与管理

**核心目的**：让自研脚本或应用（如 Python/Java 程序）像系统原生服务一样，支持开机自启、崩溃自愈、资源限制，并在后台稳定运行。

### 常用命令

```bash
# 重载配置（修改或新建 .service 文件后必须执行）
sudo systemctl daemon-reload

# 启动、停止、重启、查看状态
sudo systemctl start demo-app
sudo systemctl stop demo-app
sudo systemctl restart demo-app
sudo systemctl status demo-app

# 设置/取消 开机自启
sudo systemctl enable demo-app
sudo systemctl disable demo-app

# 查看服务的最终合并配置（含覆盖片段）
systemctl cat demo-app
```

### 运行手段与操作规范

- **编写配置文件**：统一放置在 `/etc/systemd/system/` 目录下，后缀为 `.service`。
- **覆盖修改（Drop-in）**：生产环境绝对不要直接修改原始配置文件（避免升级时被覆盖）。使用 `sudo systemctl edit <服务名>` 会自动生成覆盖片段（`override.conf`），只将修改项写入其中。
- **核心字段配置**：
  - `[Unit]` 区块：`After=network.target` 表示在网络就绪后再启动。
  - `[Service]` 区块：`Type=simple` 适用于前台运行的常驻进程。
  - `[Service]` 区块：`User=appuser` 严禁使用 root 运行。
  - `[Service]` 区块：`Restart=always` 与 `RestartSec=5` 配合，实现崩溃后 5 秒自动拉起。
  - `[Service]` 区块：`MemoryMax=1G` 与 `CPUQuota=50%` 限制资源，防止单个服务拖死整台机器。
  - `[Install]` 区块：`WantedBy=multi-user.target` 决定开机自启级别（多用户命令行）。

### 故障解决方案

- **服务启动失败**：优先执行 `systemctl status <服务名>`，查看输出底部的报错提示。
- **修改配置不生效**：忘记执行 `sudo systemctl daemon-reload`，导致系统未加载新配置。
- **频繁重启导致服务被锁定**：如果配置了 `Restart=always`，但服务连续失败，Systemd 会将其置为 `failed` 并停止重试。需先修复程序报错，再执行 `sudo systemctl reset-failed <服务名>` 清除失败计数后重启。

---

## 2. 日志排查与切割管理

**核心目的**：快速定位服务运行错误，并防止纯文本日志无限增大导致磁盘被撑爆。

### 常用命令

```bash
# 追踪指定服务的系统日志
sudo journalctl -u demo-app

# 实时滚动查看（类似 tail -f）
sudo journalctl -u demo-app -f

# 只看最近 5 条
sudo journalctl -u demo-app -n 5

# 只看某时间段或今天
sudo journalctl -u demo-app --since today

# 手动强制执行一次日志切割测试并显示详细过程
sudo logrotate -vf /etc/logrotate.d/myapp
```

### 运行手段与操作规范

- **Journald 限制**：系统自带的 `journalctl` 默认有大小限制（如占磁盘 10%），超限会自动删除最旧日志，无需人工干预。
- **Logrotate 配置**：传统应用日志（如 Nginx/MySQL）必须手动配置切割。在 `/etc/logrotate.d/` 目录下建立专属文件，不要直接改主配置文件。
- **切割策略**：
  - `size 100M`：文件超过指定大小立即切割。
  - `rotate 7`：保留 7 份历史文件，多余的删除。
  - `compress`：对历史文件进行 gzip 压缩，节省空间。
  - `create 0644 user group`：切割后自动新建空文件，并赋予正确的权限，防止应用写日志报错。

### 故障解决方案

- **日志文件过大且无法直接删除**：不能直接用 `rm` 删除正在写入的日志文件。正确做法是修改 logrotate 配置，执行强制切割；或者清空文件内容 `echo "" > /var/log/xxx.log`。
- **Logrotate 未按预期执行**：检查配置文件中 `daily` 与 `size` 是否**同时配置**——两者并存时 `size` 生效，时间周期条件被忽略（即“不到指定大小就不会切割”）。误以为按天切割、实际却迟迟不切的故障多源于此。

---

## 3. 磁盘爆满紧急恢复

**核心目的**：在服务器磁盘 100% 满载导致业务崩溃时，快速定位大文件并无损恢复业务。

### 常用命令

```bash
# 查看各分区的整体使用率
df -h

# 定位当前目录下体积最大的文件夹或文件
du -sh *

# 从指定目录开始查找大于 100M 的文件
sudo find /mnt/full-test -type f -size +100M -exec ls -lh {} \;

# 查找被删除但仍被进程占用的“幽灵文件”
sudo lsof | grep deleted
```

### 运行手段与操作规范

- **确认瓶颈**：先执行 `df -h` 找到使用率 100% 的挂载点。
- **定位元凶**：在该挂载点下使用 `find` 寻找超级大文件（如日志、临时备份）。
- **正常处理**：确认无用后直接 `rm -f` 删除，或将其压缩转移。
- **确认需扩容**：先用 `df -i` 排除 inode 耗尽、用 `lsof | grep deleted` 排除已删未释放，剩下的才是真缺容量。LVM 环境下扩容是两步：`sudo lvextend -L +<增量> /dev/<VG>/<LV>` 改变块设备长度，`sudo xfs_growfs <挂载点>` 才让文件系统认领；扩容前必须先 `findmnt -no SOURCE <挂载点>` 核验对象。完整流程与三类坑见 [06-lvm-and-filesystem-management.md](06-lvm-and-filesystem-management.md)。

### 故障解决方案（幽灵文件经典处理）

- **现象**：执行 `rm` 删除了几十 G 的日志文件，但 `df -h` 查看磁盘依然 100% 满载。
- **原理**：Linux 中，文件被进程打开（如应用正在写该日志）时，即使通过 `rm` 删除了目录索引，底层数据块依然被内核保留，直到进程释放该句柄。
- **解决步骤**：
  1. 执行 `sudo lsof | grep deleted` 找出该进程的 PID 和文件描述符（FD）编号；
  2. 获取该进程 FD 对应的虚拟路径（例如 `/proc/12345/fd/3`）；
  3. 使用具有 root 权限的 `tee` 命令强制清空该文件，立刻释放磁盘空间，且无需重启业务进程：

```bash
echo "" | sudo tee /proc/12477/fd/3 > /dev/null
```

---

## 4. SRE 视角：存储与日志防爆策略
- **Journald 持久化**：默认情况下，Systemd 日志存在内存中，重启即丢失。生产环境中需修改 `/etc/systemd/journald.conf`，设置 `Storage=persistent`，并限制 `SystemMaxUse=500M` 防止占满磁盘。
- **磁盘水位监控**：除了手动排查，必须在 `/data` 等核心分区配置 Prometheus 监控（如 Node Exporter 的 `node_filesystem_avail_bytes` 指标），在磁盘使用率达到 80% 时自动告警。
