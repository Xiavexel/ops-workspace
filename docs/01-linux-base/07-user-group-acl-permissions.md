# Linux 生产环境实战：用户、组与权限（umask / ACL / mask）

"权限不对"是生产环境里最高频的求助之一，而绝大多数误判来自三个概念没分清：**默认权限是 umask 算出来的、目录能不能进看 `x` 位、ACL 到底生效没生效看 `mask` 与 `#effective`**。本章用一轮可复现的实机实验把这三条钉死，并把"我给了权限却没生效"这类现场归成可复算的判据。

> **返回总览**：[00-linux-ops-overview.md](00-linux-ops-overview.md)　空间不足的处置见 [02-linux-service-log-disk-management.md](02-linux-service-log-disk-management.md)
> **边界声明**：本章 1–4 节的命令与输出为 Rocky Linux 10.2 单机 Lab 实测，唯一例外是第 3 节"有 x 无 r"一条（已标推演并附验证命令）；第 5 节标注"推演"的部分未落地；**SUID / SGID / Sticky 三连本次未执行**，只在第 5 节讲原理。

---

## 1. 用户与组：主组、附加组与 GID 的真实关系

**核心目的**：能用一条 `id` 分清"主组"与"附加组"，并解释 UID 与 GID 编号不相等是正常现象。

### 常用命令

```bash
# 建组、建用户并加入附加组（-m 建家目录，-G 指定附加组）
sudo groupadd ops
sudo useradd -m -G ops alice
sudo useradd -m -G ops bob

# 看用户的全部组身份：主组在前、附加组在后
id alice
id bob

# 反过来看组里都有谁（第四列是成员列表）
getent group ops
```

### 运行手段与操作规范

- **`useradd -m` 会同时建一个与用户同名的私有组**：所以账号从来不是孤立的，而是"账号 + 私有组"。
- **主组与附加组是两种身份**：主组（GID）是"新建文件的默认属组"的来源；附加组只是"额外能访问的组"。
- **UID 与 GID 编号不需要相等**：两者由同一个递增分配器依次发号，先建的组会先占号，撞不上也不要求撞上。
- **`-G` 只加附加组，不改主组**；要改主组得用 `usermod -g`（本实验未执行）。
- **`id` 的输出格式本身就是判据**：`gid=` 后面必须是与用户名同名的私有组，`组=` 后面才是主组 + 附加组的完整列表。

### 故障解决方案（编号对不上，以为建错了）

- **现象**：`id alice` 显示 `uid=1001(alice) gid=1002(alice) 组=1002(alice),1001(ops)`——UID 是 1001、主组 GID 却是 1002，第一反应是"建错了"。
- **原理**：`groupadd ops` 先执行，占走 **GID 1001**；随后 `useradd` 自动创建的私有组 `alice` 只能拿 **1002**。两个编号互不干扰。
- **解决**：不需要解决。判据是"`gid=` 后必须是**与用户名同名**的私有组"，编号是多少无关。
- **实测回显**：
  ```
  uid=1001(alice) gid=1002(alice) 组=1002(alice),1001(ops)
  uid=1002(bob)   gid=1003(bob)   组=1003(bob),1001(ops)
  ops:x:1001:alice,bob
  ```

---

## 2. umask：默认权限是算出来的，不是写死的

**核心目的**：能从 `umask` 值直接算出新建文件/目录的权限，并解释"新文件属组为什么不是父目录的属组"。

### 常用命令

```bash
# 看当前 umask（四位输出，首位是特殊位，通常 0）
umask

# 在指定 umask 下创建文件与目录（放在子 shell 里改，不影响当前会话）
sudo -u alice bash -c 'umask 022; cd /tmp/perm-lab; touch f-022; mkdir d-022'
sudo -u alice bash -c 'umask 077; cd /tmp/perm-lab; touch f-077; mkdir d-077'

# 批量核对：八进制权限 + 属主:属组 + 名字，一行一个
stat -c '%a %U:%G %n' /tmp/perm-lab/*
```

### 运行手段与操作规范

- **umask 是"屏蔽位"，不是"权限值"**：新建文件的基础值是 `666`、目录是 `777`，umask 中为 1 的位被清掉，即 `文件 = 666 & ~umask`、`目录 = 777 & ~umask`。
- **两组必须背下来的换算**：
  - `umask 022` → 文件 `644`、目录 `755`
  - `umask 077` → 文件 `600`、目录 `700`
- **目录天生比文件多一个 `x`**：同一 umask 下，目录永远比文件多 `x`，因为基础值 `777` 比 `666` 多一个 `x`。
- **umask 是进程属性**：只对"该进程创建的文件"生效，不追溯已存在文件；验证时用子 shell（`bash -c 'umask ...; ...'`），别改当前会话的 umask。
- **新文件的属组 = 创建进程的有效组（egid）**，不是父目录的属组。

### 故障解决方案（以为是"组权限没继承"）

- **现象**：`/tmp/perm-lab` 已经 `chown alice:ops`，但 alice 在里面新建的文件属组是 `alice:alice`，不是 `alice:ops`。
- **原理**：新建文件的属组取自**进程 egid**（alice 的主组 `alice`），父目录属组不参与继承。要让"属组跟随父目录"，必须给父目录设 **SGID**（如 `chmod 2775`，首位 `2` 就是 SGID）——**本次未执行，待验证**。
- **解决**：要么接受现状（属主自己能读写，够用）；要么给共享目录设 SGID + 用 `umask 002` 让组内可写。
- **实测回显**：
  ```
  755 alice:alice /tmp/perm-lab/d-022
  700 alice:alice /tmp/perm-lab/d-077
  644 alice:alice /tmp/perm-lab/f-022
  600 alice:alice /tmp/perm-lab/f-077
  ```

---

## 3. 目录的 `x` 位，和"看权限"的正确姿势

**核心目的**：分清目录 `r` 与 `x` 各管什么；并用一条命令批量看权限，避开 `ls -l` 只看文件的坑。

### 常用命令

```bash
# 看目录本身（-d 不展开内容，这点最关键）
ls -ld /tmp/perm-lab
ls -la /tmp/perm-lab

# 批量看权限（`ls -l dir/*` 的最优替代）
stat -c '%a %U:%G %n' /tmp/perm-lab/*

# 看一个文件到底谁能用（ACL 完整视图）
getfacl -p /data/acl-lab/report.txt
```

### 运行手段与操作规范

- **目录三个位与文件完全不同**：
  - `r`：能列出目录里的**名字**；
  - `x`：能**穿越**——进去、访问里面的条目、对它做 `stat`；
  - `w`：能在里面**增删**条目。
- **只有 `r` 没有 `x` = 废的**：看得见名字却进不去，`cat` 报 `Permission denied`。反过来**只有 `x` 没有 `r`**：进得去、能读已知路径的文件，但 `ls` 列不出名字——**后半句为推演，本次未实测**。验证法：只给目录 `u:alice:x`、不给 `r`，再跑 `sudo -u alice ls /data/acl-lab` 应仍报权限不够，而 `cat /data/acl-lab/report.txt` 可成功。
- **`ls -l dir/*` 看不到目录自己**：shell 先把 `*` 展开成文件列表再交给 `ls`，`ls` 收到的全是文件参数，目录自身根本不在参数里。要看目录必须 `ls -ld`。
- **`stat -c` 是批量核对的正解**：一条命令同时给八进制权限、属主、属组、路径，比 `ls -l` 的 `rwx` 串更适合写进报告与脚本。

### 故障解决方案（自测题答错的那次）

- **现象**：想核对"目录与文件各自的权限"，执行 `sudo ls -l /tmp/perm-lab/*`，结果只打印 4 个文件，两个目录没出现。
- **原理**：同上——`*` 已展开，`ls` 无目录可列。不是权限问题，是命令用错。
- **解决**：`ls -ld /tmp/perm-lab/*`，或 `stat -c '%a %U:%G %n' /tmp/perm-lab/*`。
- **实测回显**（错误姿势）：
  ```
  -rw-r--r--. 1 alice alice 0 11月21日 15:25 /tmp/perm-lab/f-022
  -rw-------. 1 alice alice 0 11月21日 15:25 /tmp/perm-lab/f-077
  ```

---

## 4. ACL 与 mask：`#effective` 才是最终答案

**核心目的**：能解释"ACL 给了权限却不生效"，并知道 `mask` 是 named user / named group / `group::` 三类条目的**上限**。

### 常用命令

```bash
# 建实验目录：属主 root、权限 700，alice 起初完全进不去
sudo mkdir -p /data/acl-lab
sudo chown root:root /data/acl-lab
sudo chmod 700 /data/acl-lab
sudo bash -c 'echo "root-only report" > /data/acl-lab/report.txt'

# 非属主、非 root 查看别人的 ACL：直接报"权限不够"，必须 sudo
getfacl /data/acl-lab/report.txt

# 给目录加"穿越"，给文件加"读"
sudo setfacl -m u:alice:x /data/acl-lab
sudo setfacl -m u:alice:r /data/acl-lab/report.txt

# 查看（-p 保留绝对路径，默认会去掉前导 /）
sudo getfacl -p /data/acl-lab/report.txt
```

### 运行手段与操作规范

- **`getfacl` 的五类条目**：`user::`（属主）、`user:alice:`（named user）、`group::`、`mask::`、`other::`。`mask` 只约束 **named user / named group / `group::`**，**不约束**属主 `user::` 与 `other::`。
- **`#effective:` 是唯一判据**：条目实际生效权限 = 条目 ∩ mask。看到 `user:alice:rw-  #effective:---`，就说明"写了 rw 也白搭，mask 是空的"。
- **`setfacl -m` 默认会重算 `mask`**：把被约束条目的权限按位或起来写回 `mask::`。所以"先设 mask、再设条目"会被第二步冲掉——**要制造限制，顺序必须是"先条目、最后 `m::`"**。
- **`-n` 不是"制造限制"**，而是"别重算 mask"：只在"你已经手动定好 mask、且后续不想让它变"时才有意义；mask 本来就宽时，加不加 `-n` 结果一样。
- **文件有 ACL 时，`chmod` 的组三位改的是 `mask::`，不是 `group::`**——见下节现场三。
- **`u:alice:x` 只能让他"穿过去"**：实测 `cat` 已知路径文件成功（读到 `root-only report`）；"`ls` 仍列不出名字"这半句为**推演**，因为列名字要目录的 `r`，本次没在"只给 x 不给 r"的条件下再跑一次 `ls`。

### 故障解决方案（三次"与预期不符"的现场）

**现场一：想拦住写，反而放开了**

- **现象**：先 `setfacl -m m::r`（把 mask 压到只读），紧接着 `setfacl -m u:alice:rw`，结果 `getfacl` 里 `mask::` 又变回 `rw-`，alice 写入成功。
- **原理**：`setfacl -m` 每执行一次都会**重算 mask**（取被约束条目的并集）。`u:alice:rw` 一进来，并集就变成 `rw`，先前压下去的 `m::r` 被覆盖。
- **解决（确定性序列，可复现）**：**所有条目先设完，最后一步单独设 `m::`**：
  ```bash
  sudo setfacl -m m::r  /data/acl-lab/report.txt   # 期望：写失败
  sudo -u alice bash -c 'echo hack >> /data/acl-lab/report.txt'; echo "退出码=$?"
  sudo setfacl -m m::rw /data/acl-lab/report.txt   # 期望：写成功
  ```

**现场二：以为 `-n` 能把权限锁死**

- **现象**：执行 `setfacl -n -m u:alice:rw`，期望"不重算 mask、从而拒绝写入"，结果 alice 照样写成功。
- **原理**：`-n` 只禁止"重算 mask"，不会把 mask 改小。mask 已经是 `rw-` 时，条目拿全额生效，`-n` 与不加完全等价。
- **解决**：要做对照实验，必须**显式**改 `mask`（`setfacl -m m::r`），不能指望 `-n` 制造限制。

**现场三：`chmod 600` 之后连读都不行了**

- **现象**：只想"顺手收紧"，`sudo chmod 600 report.txt`，结果 alice 连 `cat` 都失败，且 `group::r--` 也显示 `#effective:---`。
- **原理**：文件存在 ACL 时，`chmod` 的组三位写入的是 **`mask::`**。`600` 的中间位是 `0`，于是 `mask::---`，所有被 mask 约束的条目（含 `group::r--`、`user:alice:rw-`）全部被裁为 0。
- **实测回显**：
  ```
  user:alice:rw-                  #effective:---
  group::r--                      #effective:---
  mask::---
  other::---
  ```
- **解决**：有 ACL 的文件，用 `setfacl` 精确改条目或 `m::`，**别用 `chmod` 的组位**；非改不可时，改完立刻 `getfacl` 复核 `#effective`。
- **一条纪律**：本次实验中同一组命令出现过"先成功、后失败"的不一致回显，我没能逐条复现出唯一根因——`setfacl -m` 的重算与 `-n` 的不重算混在一起时，光看 `mask::` 那一行推不出真实状态。**结论：不要从 `mask::` 那一行推结论，每次改完都用 `getfacl` 看 `#effective`，并且只信"最后一次改动之后"的状态。**

---

## 5. 生产视角推演：最小授权与权限审计

- **不要用 `chmod 777` 解决"访问不了"**：它同时放开属组与 other，把"一个人需要访问"变成"全机可写"。正确手法是 ACL 精确授权。
- **共享目录的正确组合是 `SGID + umask 002`**：`chmod 2775` 让新建文件继承属组，`umask 002` 让组内可写。只给 `chmod 775` 时，新建文件仍是"属主私有"（本次未执行，待验证）。
- **权限基线**：新文件 `640`（配置/数据）或 `664`（共享），新目录 `750`/`755`。出现 `777`、`o+w`、来源不明的 `SUID` 二进制，都应当作缺陷上报。
- **特殊位三连（SUID / SGID / Sticky，本次未执行，只讲原理）**：`SUID` 让执行者以**文件属主**身份运行（`/usr/bin/passwd` 就是）；`SGID` 在目录上表示"新建文件继承属组"、在文件上表示"以属组身份运行"；`Sticky`（目录 `1777`）限制"只有属主能删自己的文件"（`/tmp` 就是）。
- **ACL 要跟备份一起走**（推演，未落地）：`getfacl -R /data > acl.bak` 备份、`setfacl --restore=acl.bak` 恢复。**迁移/恢复时 ACL 不跟着走，就是"恢复完权限全丢"的经典事故**。
- **审计判据**：`find /data -type f -perm -o+w` 找 other 可写；`getfacl -R` 批量导出后 grep `mask` 与 `#effective` 找被裁掉的条目。
- **权限问题的排查顺序**（本次实验验证过有效）：先 `ls -ld` / `stat -c` 定语主与八进制位 → 再 `getfacl` 看是否有 ACL → 最后**只看 `#effective`** 判能不能用。三层跳错一层，结论就会错。
