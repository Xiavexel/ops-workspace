# Linux 生产环境实战：LVM 卷管理与在线扩容

生产环境里"磁盘满了"的处置，绝大多数最终落到 LVM 扩容上：先看池子里还剩多少 PE，再扩逻辑卷，最后让文件系统认领。本章覆盖三层结构的容量账本、在线扩容的两个阶段，以及"扩容成功但 df 不变"的三类根因——扩容类故障几乎都能归到这三类里。

> **返回总览**：[00-linux-ops-overview.md](00-linux-ops-overview.md)　文件级"磁盘爆满"处置见 [02-linux-service-log-disk-management.md](02-linux-service-log-disk-management.md)

---

## 1. PV / VG / LV 三层与容量账本

**核心目的**：把 `pvs / vgs / lvs` 三张表看成同一个存储池的三个视角，并能从标称容量算出"真正能切出多少 PE"。

### 常用命令

```bash
# 三层速查：盘 / 池 / 切片
sudo pvs
sudo vgs
sudo lvs -o lv_name,lv_size,devices

# 单个 PV 的 PE 明细（Total PE / Free PE 只在入池后才有值）
sudo pvdisplay /dev/sdb

# PE 级别映射：哪个 LV 落在哪块盘的哪一段
sudo pvdisplay -m /dev/sdb
sudo pvs --segments -o pv_name,pe_start,pe_count,lv_name

# 设备与挂载点的对应关系
lsblk -f
findmnt -no TARGET,SOURCE,FSTYPE <挂载点>
```

### 运行手段与操作规范

- **PE 是 VG 的计量单位，不是 PV 的属性**：PV 未入池时 `pvdisplay` 的 `Total PE / Free PE` 恒为 0；一旦 `vgcreate` / `vgextend`，同一块盘立刻出现 PE 计数。
- **每个 PV 开头固定预留 4MiB** 给 LVM 的 label/metadata（`pvdisplay` 中显示为 `PV Size 10.00 GiB / not usable 4.00 MiB`）。因此 `Total PE = (设备容量 − 4MiB) / PE Size`；默认 PE 为 4MiB 时，**10GiB 的盘只有 2559 个 PE，不是 2560**。
- **容量按 PE 算，不按字节算**：两块 10GiB 的 PV 组成 VG，`VSize` 显示 `19.99g`（2559×2 = 5118 PE = 19.992 GiB）。`pvs / vgs` 输出里数值前的 `<` 表示"取整显示、非精确值"，不是异常。
- **`lvs -o +devices` 的行数就是段数**：一个 LV 横跨几块 PV 就打印几行。`Start PE` 是 **LV 内部**的逻辑 PE 序号（从 0 累加），`Ranges` 与 `devices` 括号里的数字是 **该 PV 上**的物理 PE 区间——两套编号不能混用。
- **LV 的块设备节点是指向 `/dev/dm-N` 的软链**：任何"设备名 ↔ 挂载点"的比对都要先 `readlink -f` 归一化，否则扩容、迁移后 dm 号变化就会误判。
- **入池顺序**：`pvcreate`（做盘）→ `vgcreate`（建池）→ `lvcreate`（切片）→ `mkfs`（架文件系统）。`mkfs` 必须作用在 LV 上，不能作用在 PV 或整盘上。

### 故障解决方案（容量算不平）

- **现象**：`lvextend -l +100%FREE` 之后 `df` 显示的空间比标称少一截；`VSize` 比"两块 10G 相加"少 0.01g；新建的 1GiB LV，`df` 只有 `960M`。
- **原理**：三层损耗叠加——
  1. 每个 PV 预留 4MiB 元数据区，直接吃掉 1 个 PE；
  2. 文件系统自身开销：XFS 在 `mkfs` 时写入内部日志，1GiB 的 LV `blocks=262144`、`log=16384 blocks`（16384×4096B = 64MiB），故 `df` 显示 `960M`；
  3. 扩容时的元数据税：`xfs_growfs` 新扩出的空间要写新的分配组（AG），1GiB→1.5GiB 后"已用"从 `51M` 涨到 `70M`（本例）。
- **解决**：容量规划按 PE 计算并预留 5% 余量；报障与验收一律以 `df` 的"可用"列为准，不要用"大小"列减"已用"列去对账。

---

## 2. 在线扩容：块层与文件系统层是两个动作

**核心目的**：在不中断业务的前提下把可用空间变大，并清楚"哪一步只改了块设备、哪一步才改文件系统"。

### 常用命令

```bash
# 阶段一：扩块层（改 LV 长度，内核立刻生效）
sudo lvextend -L +2G /dev/<VG>/<LV>
# 或吃掉池内全部剩余 PE
sudo lvextend -l +100%FREE /dev/<VG>/<LV>

# 阶段二：让文件系统认领（XFS 的参数是挂载点，不是设备）
sudo xfs_growfs <挂载点>

# ext4 用 resize2fs（参数为设备或挂载点）
# sudo resize2fs /dev/<VG>/<LV>

# 两端核对：块设备长度 vs 文件系统容量
sudo blockdev --getsize64 /dev/<VG>/<LV>
df -h <挂载点>
```

### 运行手段与操作规范

- **两阶段缺一不可**：`lvextend` 只改 dm 设备的长度（PE 表），`xfs_growfs` 才改写 XFS 超级块中的 `blocks` 字段。`df` 读的是后者，少一步就永远不变。
- 实测对照：`lvextend` 后 `blockdev --getsize64` 立刻是 `1610612736`（1.5GiB），同一时刻 `df` 仍显示 `960M`——两组数字同时成立，才是正常状态。
- **`xfs_growfs` 的输出只看最后一行**：`data blocks changed from X to Y` 是结果；前面的 header（含 `agcount`）是**扩容前**的超级块快照，用它判断成败会误判。
- **扩容是单向的**：XFS 不支持在线缩小。`lvreduce` 之前必须先处理文件系统，否则直接破坏元数据；缩容属于停机窗口操作，且要按"先文件系统、后 LV"的倒序执行。
- **三件事互相独立**：`vgextend` 只加盘不扩 LV，`lvextend` 只扩 LV 不动文件系统，`xfs_growfs` 只让文件系统认领已有空间。生产上按顺序一步一验。

### 故障解决方案（扩完 df 不变）

见第 3 节，按三类根因分开判定——这一节是本章的核心。

---

## 3. "扩容成功但 df 不变"的三类根因

**核心目的**：把"没生效"这句现象拆成三个可判定的类别，每类只用一两条命令就能定死，避免在生产上靠猜。

### 常用命令

```bash
# 判定前必须凑齐四组数字，缺任何一组都无法定类
sudo lvs -o lv_name,lv_size,devices <VG>
sudo blockdev --getsize64 /dev/<VG>/<LV>
df -h <挂载点>
findmnt -no TARGET,SOURCE,FSTYPE <挂载点>
```

### 运行手段与操作规范

按下表逐行排除，**顺序不能颠倒**：先验"对象是否一致"，再验"层次是否走完"。

| 类别 | 现象 | 判定命令与判据 | 原理 |
|---|---|---|---|
| A 层次没走完 | `lvs` 变大、`blockdev` 变大、`df` 不变 | `df` 的容量 ≠ `blockdev --getsize64` | 块设备已扩，XFS 超级块未改写 |
| B 对象错位 | 某个 LV 确实变大了，但目标路径 `df` 不变 | `findmnt -no SOURCE <路径>` 归一化后 ≠ 目标 LV | `df` 的数字来自**该挂载点所在文件系统**的超级块，与任何 LV 无直接关系 |
| C 挂载层级错 | 同一路径，`df` 前后数字莫名变化 | `findmnt <路径>` 的 SOURCE 与 `/proc/mounts` 中该路径的条目不一致 | `mount` 是**叠加**不是替换，后挂的遮住先挂的 |

### 故障解决方案（案例：挂载点被另一个 LV 覆盖）

- **现象**：对 `/mnt/lvm-lab` 执行扩容，`lvs` 显示目标 LV 已变为 `16.00g`，但 `df -h /mnt/lvm-lab` 仍是 `2.0G / 4%`，甚至看起来"根本不缺空间"。
- **原理**：`/mnt/lvm-lab` 在挂载表中指向的是 `decoy` 的 dm 设备（`/dev/mapper/labvg-decoy`）。`df` 通过 `statfs()` 读的是 **decoy 的 XFS 超级块**；而 `lvextend` 改的是另一个 LV 的长度。两条链路在"设备"这一层就分叉，decoy 的超级块一个字节都没动，所以数字纹丝不动。
- 换句话说：**`lvs` 回答"设备有多长"，`df` 回答"挂着的文件系统认为自己有多大"，两者只有在指向同一设备时才应该相等。**
- **解决**：

```bash
# 1. 先确认路径背后到底是谁
findmnt -no SOURCE /mnt/lvm-lab
# 2. 看两个 LV 指向的 dm 号是否不同
ls -l /dev/labvg/labvol /dev/labvg/decoy
# 3. 摘掉错误挂载
sudo umount /mnt/lvm-lab
# 4. 必须为空，确认摘干净（叠加挂载时可能需要摘两层）
findmnt -no SOURCE /mnt/lvm-lab
# 5. 挂回正确设备
sudo mount /dev/labvg/labvol /mnt/lvm-lab
# 6. 对象确认后才扩容
sudo lvextend -L +2G /dev/labvg/labvol
# 7. 参数用该路径
sudo xfs_growfs /mnt/lvm-lab
# 8. 同一路径验收
df -h /mnt/lvm-lab
```

---

## 4. 实验环境：用 loop 文件模拟一块盘

**核心目的**：在不买盘、不动现有 VG 的前提下，完整演练"加盘 → 进池 → 跨盘扩容"，且能一键拆干净。

### 常用命令

```bash
# 造盘：稀疏文件，先不占真实空间
sudo truncate -s 10G /data/lvm-lab/lvm-lab.img
ls -l /data/lvm-lab/lvm-lab.img; du -sh /data/lvm-lab/lvm-lab.img   # 10G vs 几 MB

# 挂 loop（-fP：找空闲设备并扫描分区表；--show 打印设备名）
sudo losetup -f
LOOP=$(sudo losetup -fP --show /data/lvm-lab/lvm-lab.img); echo "$LOOP"

# 空镜像没有分区表，直接对整块 loop 做 PV
sudo pvcreate "$LOOP"
sudo vgcreate <VG名> "$LOOP"
sudo lvcreate -L 6G -n <LV名> <VG名>
sudo mkfs.xfs /dev/<VG名>/<LV名>
sudo mount /dev/<VG名>/<LV名> <挂载点>

# 加第二块盘（演练真实扩容）
sudo truncate -s 10G /data/lvm-lab/lvm-lab2.img
LOOP2=$(sudo losetup -fP --show /data/lvm-lab/lvm-lab2.img); echo "$LOOP2"
sudo pvcreate "$LOOP2"
sudo vgextend <VG名> "$LOOP2"

# 拆除（lvremove / vgremove / pvremove 均不可逆）
sudo umount <挂载点>
sudo lvremove -y /dev/<VG名>/<LV名>
sudo vgremove -y <VG名>
sudo pvremove "$LOOP" "$LOOP2"
sudo losetup -d "$LOOP" "$LOOP2"
sudo rm -f /data/lvm-lab/lvm-lab.img /data/lvm-lab/lvm-lab2.img
```

### 运行手段与操作规范

- **不要给 loop 分区**：空镜像没有分区表，`pvcreate /dev/loopNp1` 必然报 `Device ... not found`；整块 loop 直接做 PV。
- **稀疏 ≠ 免费**：`ls -l` 显示 10G、`du` 只有几 MB，但只要往里写数据，**实占的是宿主文件系统的空间**。实测：在 1.5GiB 的实验卷写 1.1GiB 数据后，宿主 `/data` 已用从 `8.1G` 涨到 `9.6G`。
- **loop 设备重启不持久**：重启后 `/dev/loopN` 消失，`lvs` 仍列出 LV、`mount` 失败——这是预期行为，不是数据损坏。需要持久化时把镜像路径与 `loop` 挂载选项写进 `/etc/fstab`，或开机脚本重建。
- **新段优先吃满旧盘尾部**：`vgextend` 之后 `lvextend`，相邻的连续空闲会被合并成一段，所以 `Start PE` 不会跳号；剩余部分才落到新盘。**行数由"段"决定，不是由"盘"决定。**

### 故障解决方案（loop 演练的两个坑）

- **现象**：`losetup -f` 报 `Could not find any free loop device`。
  **原理**：loop 设备数量有限（`max_loop`），旧设备未 detach 就被占满。
  **解决**：`sudo losetup -a` 查出占用者，`sudo losetup -d <dev>` 释放后再挂。
- **现象**：`pvdisplay -v | sed -n '/Physical extents/,+8p'` 一句输出都没有。
  **原理**：两个原因叠加——① 系统为中文 locale，实际输出是"物理扩展"；② PE 映射表要用 `pvdisplay -m`，`-v` 只给概要不含映射。
  **解决**：`LANG=C sudo pvdisplay -m /dev/loopN`，或直接用 `sudo pvs --segments -o pv_name,pe_start,pe_count,lv_name`。
- **现象**：`pvdisplay` 里 `PE Size 4.00 MiB / Total PE 2559`，但明明买的是 10GiB。
  **原理**：4MiB 被 LVM 元数据区占用（`not usable 4.00 MiB`），见第 1 节。
  **解决**：按 PE 规划，不按标称容量规划。

---

## 5. SRE 视角：扩容前断言与容量水位

- **扩容前先断言对象**：任何手动或脚本化扩容，第一步必须是"路径背后的设备 == 目标 LV"的比对，不一致立即退出，不进入写操作。参考实现：[`tools/shell/lvm-grow-safe.sh`](../../tools/shell/lvm-grow-safe.sh)（内含 `--dry-run`，落盘前先把计划打出来）。
- **容量规划按 PE 记、不按 GB 记**：每块 PV 扣 4MiB，每个 LV 扣文件系统开销（XFS 内部日志从 64MiB 起），扩容还要为新 AG 付元数据税。规划阶段直接按标称容量的 90% 估算可用量。
- **水位监控看"可用"不看"百分比"**：告警应以 `node_filesystem_avail_bytes`（或 `df --output=avail <挂载点>`）为准，使用率 80% 触发；使用率高但可用量绝对值仍大（大盘）时不该告警。
- **扩容是不可逆窗口操作**：`vgs` 无剩余 PE 时只能加盘（`pvcreate` + `vgextend`），不能靠 `pvresize` 凭空挤出空间；扩核心卷之前先在实验卷或 loop 上走一遍全流程，并保留 `vgcfgbackup` 产物。
