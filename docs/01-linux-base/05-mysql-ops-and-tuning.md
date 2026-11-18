# Linux 生产环境实战：MySQL 运维与调优

MySQL 是传统互联网业务的核心存储。在生产环境中，核心任务是：安全加固、权限隔离、数据备份以及性能排障。

> **返回总览**：[00-linux-ops-overview.md](00-linux-ops-overview.md)

---

## 1. 安全加固与初始化

**核心目的**：部署完成后，立即封堵默认的免密登录漏洞，清理测试数据，防止恶意攻击。

### 常用命令

```bash
# 执行官方安全配置向导
sudo mysql_secure_installation
```

### 运行手段与操作规范

- **验证密码强度**：开启 `VALIDATE PASSWORD` 组件，强制密码包含大小写、数字及特殊字符。
- **移除匿名用户**：防止任何人无需账号即可连入数据库。
- **禁止 root 远程登录**：确保 root 账号只能在数据库所在的本地服务器（localhost）上登录。
- **移除 test 库**：默认的测试库对所有人开放，必须删除。

---

## 2. 业务用户与最小权限

**核心目的**：遵循安全铁律，绝对不能给业务后端程序使用 root 账号。

### 常用命令

```bash
# 登录 MySQL 控制台
mysql -u root -p
```

### 运行手段与操作规范

- **创建库与用户**：为业务创建专属数据库和独立用户。

```sql
CREATE DATABASE appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'appuser'@'localhost' IDENTIFIED BY 'App@123456';
```

- **按需赋权**：只赋予该业务库的权限，绝不赋予全局管理权限。

```sql
GRANT ALL PRIVILEGES ON appdb.* TO 'appuser'@'localhost';
FLUSH PRIVILEGES;
```

---

## 3. 逻辑备份与灾难恢复

**核心目的**：防止误删数据或服务器宕机造成不可挽回的损失。

### 常用命令

```bash
# 备份指定数据库
mysqldump --no-tablespaces -u appuser -p appdb > /tmp/appdb_backup.sql

# 从备份文件恢复数据
mysql -u appuser -p appdb < /tmp/appdb_backup.sql
```

### 故障解决方案

- **现象**：使用普通业务账号执行 `mysqldump` 时报错 `Access denied; you need (at least one of) the PROCESS privilege(s)`。
- **原因**：MySQL 8.0 默认备份表空间需要全局 `PROCESS` 权限。
- **解决**：不要给业务账号乱加高权限。在备份命令中加上 `--no-tablespaces` 参数，跳过表空间元数据的备份即可。
- **现象**：Python/Docker 客户端连接 MySQL 8.0 报错缺少 `cryptography`。
- **原因**：MySQL 8.0 默认认证插件为 `caching_sha2_password`，需要客户端具备 SHA256 加密能力，旧版客户端依赖库不满足。
- **解决**：优先在客户端环境执行 `pip install cryptography` 补齐依赖；仅当客户端无法升级（如老旧镜像）时，才调整服务端认证插件：
  `ALTER USER 'appuser'@'%' IDENTIFIED WITH mysql_native_password BY 'App@123456';`

---

## 4. 慢查询日志排障

**核心目的**：当网站突然卡顿、CPU 飙升时，快速抓出导致数据库缓慢的“罪魁祸首”SQL。

### 常用命令

```bash
# 临时开启慢查询（生产环境需写入 my.cnf 永久生效）
mysql -u root -p -e "SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 1;"

# 查看慢查询日志内容
sudo cat /var/lib/mysql/<主机名>-slow.log
```

### 运行手段与排查逻辑

- **设置 `long_query_time` 为 1 秒**：超过 1 秒的查询会被记录。
- **日志解读**：在日志中查看 `Query_time`（总耗时）、`Lock_time`（锁等待时间）、`Rows_examined`（扫描行数）以及具体的 SQL 语句。扫描行数极大或耗时极长的 SQL 需交给开发优化索引。

---

## 5. SRE 视角：数据安全与高可用
- **二进制日志（Binlog）**：`mysqldump` 属于全量备份。在生产环境中，必须开启 MySQL 的 `binlog`，配合 `mysqlbinlog` 工具，实现“全量备份 + 增量日志 = 任意时间点恢复（PITR）”。
- **连接池监控**：业务端报“Too many connections”通常是因为连接泄漏。除了检查 `max_connections` 参数，更应关注业务代码的连接池配置（如 Python 的 SQLAlchemy pool_size）。
