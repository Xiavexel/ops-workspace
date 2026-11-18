# B阶段-Python运维开发实战总结

**核心定位**：接管 Shell 无法处理或处理起来极其痛苦的复杂逻辑。掌握 REST API 交互、JSON 数据处理、多线程并发、异常重试机制与 SSH 批量自动化，具备开发平台化“运维组件”的能力。

> **返回总览**：[00-linux-ops-overview.md](../01-linux-base/00-linux-ops-overview.md)

---

## 1. REST API 并发监控与探测

**核心目的**：监控 HTTP 服务不仅要看连通性，还要解析状态码、耗时、捕获特定的网络异常，并发执行以避免串行卡顿。

### 核心代码

```python
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

# 【升级版】返回 (url, ok, reason)，让主线程能区分“真挂了”还是“DNS 故障”
def check_service(url):
    try:
        resp = requests.get(url, timeout=2)
        if resp.status_code == 200:
            return url, True, "OK"
        return url, False, f"HTTP {resp.status_code}"
    except requests.exceptions.Timeout:
        return url, False, "Timeout"
    except requests.exceptions.RequestException as e:
        return url, False, str(e)  # 异常变量 e 在这里真正被用上

# 主线程必须配套修改：解包后再判断
with ThreadPoolExecutor(max_workers=10) as executor:
    future_to_url = {executor.submit(check_service, url): url for url in urls}
    fails = 0
    for future in as_completed(future_to_url):
        url, ok, reason = future.result()  # 解包，不能写成 if not future.result()
        if not ok:
            fails += 1
            logging.error(f"FAIL {url} | 原因: {reason}")  # 告警带出原因
```

### 运行手段与操作规范

- **精准捕获异常**：必须区分 `requests.exceptions.Timeout`（网络超时）和 `RequestException`（如 DNS 解析失败、连接拒绝），这比 Shell 的 curl 返回 `000` 精确得多。
- **返回值必须解包**：`(url, False, "Timeout")` 这样的元组在 Python 里**永远为真**——如果主线程沿用 `if not future.result():` 判断，元组恒为 `True`，所有失败都会被漏报。必须 `url, ok, reason = future.result()` 解包后再判断 `ok`。
- **避免阻塞**：`as_completed` 会优先返回最先执行完的线程结果，不要用 `executor.map`（会按提交顺序返回，可能导致部分结果被慢任务阻塞）。
- **资源控制**：通过 `max_workers` 限制最大并发数，防止瞬间打开过多文件句柄导致 `Too many open files`。

---

## 2. 重试机制与容错设计

**核心目的**：针对网络抖动或服务重启过程中的短暂 502/超时，不能立刻判死刑，需加入重试逻辑。

### 核心代码

```python
max_retries = 3
for attempt in range(max_retries):
    try:
        resp = requests.get(url, timeout=2)
        if resp.status_code == 200:
            return True  # 成功立刻退出循环
    except requests.exceptions.RequestException:
        pass

    if attempt < max_retries - 1:
        time.sleep(1)  # 最后一次失败不等待

return False  # 全挂了
```

### 运行手段与操作规范

- **重试次数不宜过多**（一般 2-3 次），重试间隔必须使用 `time.sleep()`，否则会变成 DDoS 攻击自己的服务。
- **最后一次循环失败后不应该再 sleep**，直接抛出最终错误。
- **生产级的标准答案是 tenacity**：手写循环用于教学，生产项目推荐 `@retry(stop=stop_after_attempt(3), wait=wait_exponential())` 装饰器，自带指数退避与异常白名单，比裸写 urllib3 的 HTTPAdapter 更符合主流工程实践。

---

## 3. 配置分离与参数解析（Argparse & JSON）

**核心目的**：将易变的业务数据（监控目标、主机列表）从代码中剥离，转为标准的 JSON 配置文件。

### 核心代码

```python
import argparse
import json
import sys  # 注意：sys.exit() 依赖它

parser = argparse.ArgumentParser(description="监控工具")
parser.add_argument("-f", "--file", default="targets.json", help="配置文件路径")
args = parser.parse_args()

try:
    with open(args.file, 'r', encoding='utf-8') as f:
        targets = json.load(f)
except FileNotFoundError:
    sys.exit(2)
```

### 运行手段与操作规范

- **必须在 `try...except` 中捕获 `FileNotFoundError` 和 `json.JSONDecodeError`**，否则用户传了一个乱码文件时，脚本会直接抛出丑陋的 Traceback 崩溃。
- **`with open(...)`** 是 Python 优雅读写的标准语法，自动处理文件关闭，防止文件句柄泄漏。

---

## 4. 并发 SSH 批量管理与结果格式化

**核心目的**：替代 ansible 的轻量级功能，针对几十台服务器批量执行命令并收集回显。

### 核心代码

```python
import paramiko

def run_ssh(host_info):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        ssh.connect(
            hostname=host_info["host"],
            username=host_info["user"],
            password=host_info["password"],
            timeout=3,
        )
        # 必须给 exec_command 加超时，防止远端命令 hang 死线程
        stdin, stdout, stderr = ssh.exec_command(host_info["command"], timeout=10)
        return stdout.read().decode('utf-8').strip()
    except paramiko.AuthenticationException:
        return "密码错误"
    except Exception as e:
        return str(e)
    finally:
        ssh.close() # 关键：释放连接
```

### 运行手段与操作规范

- **必须用 `finally` 释放连接**：不论执行成功还是异常，`ssh.close()` 必须执行，否则会在目标机积累僵尸进程耗尽 sshd。
- **`exec_command` 必须带超时**：不加 `timeout` 时远端一条卡死的命令会让对应线程永久阻塞、占住一个 worker。生产建议 10s 左右。
- **生产环境的安全姿势**：`AutoAddPolicy()` + 密码登录仅限内网受信测试场景。生产应改用密钥（`key_filename=...`）+ `RejectPolicy` 预置主机密钥；注意 `RejectPolicy` 下首次连新机器会**直接报错退出**，需先用 `ssh-keyscan <host> >> ~/.ssh/known_hosts` 预置指纹。
- **表格化输出**：使用 Python 的 f-string 进行宽度对齐，如 `f"{status:<6} | {host:<15}"`，这比 Shell 里的 awk 排版强大且易于维护。

---

## 5. 故障解决方案（Troubleshooting 复盘）

- **现象**：批量 SSH 执行一段时间后，本地报 `Too many open files` 或目标机 sshd 连接数暴涨。
  - **原因**：连接未释放——`ssh.close()` 漏写、漏写 `finally`，或异常路径直接退出导致句柄泄漏。
  - **解决**：检查所有分支是否都经过 `finally`；批量场景用线程池时务必限制 `max_workers`。
- **现象**：传入一个格式错误的配置文件，脚本直接崩溃并打印一大段 Traceback。
  - **原因**：只捕获了 `FileNotFoundError`，漏了 `json.JSONDecodeError`（JSON 语法错误）和 `UnicodeDecodeError`（编码错误）。
  - **解决**：按第 3 节的规范补齐异常捕获，并对用户给出“文件路径 + 错误原因”的可读提示，而不是裸抛栈。
- **现象**：监控结果全是“成功”，但业务明显有服务挂了（漏报）。
  - **原因**：主线程用 `if not future.result():` 判断三元组返回值——非空元组在 Python 中恒为 `True`，失败永远不会被计入。
  - **解决**：按第 1 节规范解包后判断 `ok` 字段，告警时必须带出 `reason`。
- **现象**：脚本自身运行正常，但在公司内网/代理环境全部探测失败。
  - **原因**：requests 默认读取 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量，流量被错误地发往代理。
  - **解决**：监控类脚本建议显式传 `proxies={"http": None, "https": None}` 或 `trust_env=False`，排除代理干扰。

---

## 6. 平台化 / GitOps 视角

- **脚本即组件**：`api_monitor.py` 和 `ssh_batch.py` 可以作为独立的健康探针，被未来的 CI/CD 流水线直接调用（例如：发布后跑一次 API 检测，全绿才算上线成功）。
- **从脚本到平台的进化**：这个 SSH 批量工具，其实就是未来自研“运维平台”的底层引擎；而配置驱动的 JSON 结构，可以平滑演变为数据库里的一条条巡检记录。

---

## 7. SRE 视角复盘与架构演进建议

本次 Python 自动化工具的开发，不仅是实现功能，更是对“用代码解决运维痛点”的工程化实践。从 SRE 与生产级 DevOps 的视角来看，本套工具库未来有以下演进方向：

1. **凭证与安全管理**：在 `hosts.json` 中明文存储 SSH 密码触碰了安全红线。生产环境应强制使用 SSH Key 进行免密认证；涉及敏感配置时，需结合环境变量或密钥管理服务（如 Vault、K8s Secrets）动态注入，严禁硬编码提交至 Git。
2. **异常隔离与退避重试**：手写 `for` 循环重试在复杂内网极易引发重试风暴。建议引入 `tenacity` 库实现指数退避，并结合 `requests` 的 `HTTPAdapter` 管理底层连接池，提升容错能力。
3. **并发资源控制**：使用 `ThreadPoolExecutor` 时不能盲目设置过大的 `max_workers`，否则会导致本地句柄耗尽或触发目标端安全限制。必须结合实际压测结果，实现“受控并发”。
4. **结果集标准化输出**：目前的终端表格仅适合肉眼阅读。为了让工具平滑接入企业监控大盘，巡检结果应封装为统一的 JSON 结构，以便后续对接 Prometheus Pushgateway 或 ELK 进行数据可视化。

---

## 8. 自测清单

- [ ] 能够用 requests 发送请求并处理 `Timeout` 和 `RequestException`。
- [ ] 熟练使用 `ThreadPoolExecutor` 实现并发 I/O，且知道元组返回值必须解包判断。
- [ ] 知道 retry 重试机制的代码实现和重试间隔控制，并了解生产级 tenacity 方案。
- [ ] 能使用 argparse 和 json 实现配置与代码分离（含 `import sys`）。
- [ ] 能用 paramiko 批量连 SSH，记得 `exec_command` 加超时、`finally` 里关闭连接，并了解密钥登录 + `RejectPolicy` 的生产姿势。
- [ ] 能用 f-string 对齐格式打印终端表格。
