# A阶段-Shell工程化实战总结

本阶段目标：彻底摒弃“单行命令堆砌”的网管思维。掌握编写具备严格模式、结构化日志、参数解析、多进程并发以及系统级调度告警的生产级脚本能力。这是从传统运维向自动化、平台化进阶的第一道分水岭。

> **返回总览**：[00-linux-ops-overview.md](../01-linux-base/00-linux-ops-overview.md)

---

## 1. 生产级脚本骨架与容错底座

**核心目的**：让脚本在遇到未定义变量、管道中间环节报错、甚至意外中断时，能够立刻停下并清理现场，绝不带病运行。

### 核心代码

```bash
#!/usr/bin/env bash
# -E: 让 ERR trap 继承到函数和子 shell 中
# -e: 命令失败即退出
# -u: 未定义变量报错
# -o pipefail: 管道中任一环失败，整体视为失败
set -Eeuo pipefail
IFS=$'\n\t'

# 临时工作目录必须尽早创建，cleanup 中的 ${TMP_DIR} 依赖它
readonly TMP_DIR="$(mktemp -d /tmp/svc_health.XXXXXX)"

# 错误捕获与现场清理
on_error() {
  local exit_code=$? # 必须第一行保存，否则会被后续命令覆盖
  local line_no=$1
  log ERROR "执行失败: 第 ${line_no} 行, 退出码 ${exit_code}"
  exit "${exit_code}"
}
cleanup() { rm -rf "${TMP_DIR}"; }

trap 'on_error ${LINENO}' ERR
trap cleanup EXIT
```

### 运行手段与操作规范

- **`TMP_DIR` 的初始化时机**：必须在 `trap cleanup EXIT` 注册**之前**用 `mktemp -d` 创建并赋值。否则极端情况下 cleanup 先于赋值执行，在 `set -u` 下会直接报 `TMP_DIR: unbound variable`。
- **`-e` 的盲区**：在 `if cmd`、`cmd || true`、`&&` 等条件判断语句中，命令失败不会触发 `-e` 退出。这正是检查函数必须用 `if` 包裹的原因。
- **管道陷阱**：必须加 `-o pipefail`。否则 `curl xxx | grep yyy` 时，若 curl 挂掉，grep 没匹配到返回非 0，整个管道的返回值会骗过 `set -e`。
- **`IFS=$'\n\t'`**：收紧内部字段分隔符，防止文件路径或变量中包含空格导致意外分词。

---

## 2. 结构化日志、参数解析与配置读取

**核心目的**：日志要满足“人眼终端排障”与“落盘归档”双重需求；参数与配置和逻辑解耦，防止硬编码。

### 核心代码

```bash
# 1. 双写日志函数（终端分级输出 + 文件尽力而为落盘）
log() {
  local level="$1"; shift
  local ts msg
  ts="$(date '+%F %T')"
  msg="[${ts}] [${level}] [${SCRIPT_NAME}] $*"

  if [[ "${QUIET}" -eq 1 && "${level}" != "ERROR" ]]; then
    : # 静默模式，非 Error 直接忽略屏幕输出
  else
    if [[ "${level}" == "ERROR" || "${level}" == "WARN" ]]; then
      printf '%s\n' "${msg}" >&2
    elif [[ "${VERBOSE}" -eq 1 || "${level}" == "INFO" ]]; then
      printf '%s\n' "${msg}"
    fi
  fi
  # 文件写入尽力而为，防止目录不可写导致主流程崩溃
  printf '%s\n' "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# 2. getopts 参数解析（静默模式：optstring 以 : 开头，自己接管错误）
usage() {
  cat <<EOF
用法: ${SCRIPT_NAME} -c <配置文件> [-p 并发数] [-v] [-q] [-h]
  -c  服务清单配置文件（必填）
  -p  最大并发数（默认 10）
  -v  详细模式    -q  静默模式    -h  显示帮助
EOF
}

QUIET=0; VERBOSE=0; MAX_JOBS=10
while getopts ":c:p:vqh" opt; do
  case "${opt}" in
    c) CONF_FILE="${OPTARG}" ;;
    p) MAX_JOBS="${OPTARG}" ;;
    v) VERBOSE=1 ;;
    q) QUIET=1 ;;
    h) usage; exit 0 ;;
    :) log ERROR "选项 -${OPTARG} 缺少参数"; usage; exit 1 ;;  # 对应 :c:p:vqh 中的 c: p:
    *) log ERROR "未知选项 -${OPTARG}";       usage; exit 1 ;;
  esac
done

# 3. 安全读取配置文件
while IFS='|' read -r name type target rest || [[ -n "${name}" ]]; do
    name="${name%$'\r'}" # 防 Windows 的 CRLF 换行符
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    # 业务逻辑
done < "${CONF_FILE}"
```

### 运行手段与操作规范

- **getopts 静默模式**：参数字符串以 `:` 开头（如 `":c:t:p:vqh"`），遇到非法选项返回 `?`、缺参数返回 `:`，由自己在 `case` 中接管错误处理并打印 usage。
- **optstring 与 case 必须一一对应**：`:c:p:vqh` 里每个带 `:` 的选项（`c:`、`p:`）在 `case` 中都要有对应分支，漏写一个就是第 4 节“脚本瞬间退出”的第一大病因。
- **防丢数据**：`read` 遇到最后一行没有换行符会返回非零，必须用 `|| [[ -n "${name}" ]]` 兜底，防止最后一条配置被吞。

---

## 3. 多进程并发与安全结果汇聚

**核心目的**：将串行巡检升级为受控并发，大幅缩短海量节点/端口的扫描时间，同时保证父子进程间的数据不污染。

### 核心代码

```bash
local running_jobs=0
for target in "${TARGETS[@]}"; do
    # 控制并发数
    if (( running_jobs >= MAX_JOBS )); then
      wait -n # 等任意一个后台进程结束，腾出坑位
      running_jobs=$((running_jobs - 1))
    fi

    # 子 shell 后台并发执行；结果文件名用 target 的哈希，防止特殊字符
    local res_key
    res_key="$(printf '%s' "${target}" | md5sum | cut -d' ' -f1)"
    (
      if dispatch_check "${target}"; then
        echo "0" > "${TMP_DIR}/res_${res_key}"
      else
        echo "1" > "${TMP_DIR}/res_${res_key}"
      fi
    ) &
    running_jobs=$((running_jobs + 1))
done
wait # 等待剩余任务

# 结果汇总（读取临时文件）
FAILS=0
for res_file in "${TMP_DIR}"/res_*; do
    [[ -e "${res_file}" ]] || continue # 防止空目录 glob 展开出错
    if [[ "$(cat "${res_file}")" == "1" ]]; then
        FAILS=$((FAILS + 1))
    fi
done
```

### 运行手段与操作规范

- **进程隔离**：`( ) &` 产生的子 shell 无法修改父 shell 的全局变量（如 `FAILS`），必须通过往 `${TMP_DIR}` 写临时文件的方式进行通信。
- **结果文件命名要防注入**：`res_${target}` 在 target 含 `/`、空格时会写文件失败甚至路径穿越，统一改用 `md5sum` 哈希作为文件名，安全且定长。
- **兼容性提示**：`wait -n` 需要 **Bash 4.3+**（CentOS 7 默认 Bash 4.2 不支持）。在老系统上需降级为逐个 `wait` 或分批等待的方案。

---

## 4. 故障解决方案（Troubleshooting 复盘）

- **现象**：并发脚本瞬间退出（耗时 0.016s），无任何屏幕输出。
- **原因**：getopts 漏写了参数标识（如漏写 `p:`），被判定为非法参数且未妥善处理；或脚本最末尾忘了写 `main "$@"`。
- **解决**：检查 getopts 字符串与 case 分支的映射（对照第 2 节的 optstring 清单逐项核对）；确保脚本底层有入口调用。
- **现象**：测试“不可达 IP/未开放端口”时，预期会超时等待，结果却瞬间返回。
- **原因**：目标端口明确拒绝了连接（返回 RST 包），内核瞬间报错，不会触发 `--max-time` 设定的阻塞超时。
- **解决**：需使用本地挂起服务（如 `nc -lk` 或 Python socket）模拟真正的“黑洞超时”。

---

## 5. Systemd 调度与告警闭环

**核心目的**：抛弃脆弱的 crontab，利用 Systemd 原生能力实现精准定时，并在脚本失败时自动触发告警链路。

### 核心配置

```ini
# svc_health.service (关键配置)
[Service]
Type=oneshot
ExecStart=/home/xia/svc_health.sh -c /home/xia/services.conf -q
OnFailure=svc_health_alert.service  # 失败时触发告警

# svc_health.timer (关键配置)
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target  # 必须加上，否则 enable 无效
```

### 启用命令

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now svc_health.timer   # 立即启用并开机自启
systemctl list-timers | grep svc_health        # 验证定时器已被调度
```

---

## 6. 平台化 / GitOps 视角

- **配置即代码**：`services.conf` 不应只躺在本地，应作为代码推送到 Git 仓库管理。
- **调度平台化**：现在的 Systemd Timer，在未来 K8s 环境中将被 CronJob 资源对象直接替代。
- **告警闭环**：现在用 `OnFailure` 触发 wall 弹窗，未来将替换为 Prometheus + Alertmanager 的 Webhook 报警。脚本抛出的 `exit 1`，就是触发整个自动化告警链路的开关。

---

## 7. SRE 视角复盘与架构演进建议

从生产级运维的角度来看，Shell 脚本不仅仅是执行命令的集合，更是自动化体系的最小单元。

1. **效率量化与基准测试**：在编写大规模并发巡检脚本时，必须进行基准测试。串行巡检 100 个节点、单节点超时 2s 的最坏耗时为 200s；通过引入 `wait -n` 受控并发（并发度 20），最坏耗时压缩至 20s 以内，效率提升约 10 倍。
2. **失效隔离与容错**：在并发子进程中，必须将结果写入隔离的临时文件（避免父 shell 变量污染）。未来演进方向可将临时文件替换为写入消息队列（如 Redis），实现彻底的解耦。
3. **可观测性接入**：目前的告警依赖 Systemd `OnFailure` 触发本地脚本（wall 广播）。在生产环境中，应通过 Webhook 将失败事件推送至 Prometheus Alertmanager，统一纳入全站告警闭环。

---

## 8. 自测清单

- [ ] 能默写 `set -Eeuo pipefail` 并解释每个参数作用。
- [ ] 能独立写出带终端分级输出和落盘保护的 `log` 函数。
- [ ] 能熟练使用 getopts 解析带参数选项，并保证 optstring 与 case 分支一一对应。
- [ ] 能用子 shell `&` 配合 `wait -n` 和临时文件实现并发并汇聚结果，且知道 `wait -n` 的 Bash 版本要求。
- [ ] 知道如何复现“终端脚本瞬间退出”和“请求未真正超时”的坑并解决。
- [ ] 能独立编写一个 systemd timer（含 `[Install]` 段）结合 OnFailure 做告警触发。
