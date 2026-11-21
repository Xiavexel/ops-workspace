#!/usr/bin/env bash
# svc_health.sh - 多服务健康巡检
set -Eeuo pipefail
IFS=$'\n\t'
MAX_JOBS=5

readonly SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"

LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
VERBOSE=0
# 【任务1新增】静默模式开关
QUIET=0 
TIMEOUT=5
CONF_FILE=""
FAILS=0
TMP_DIR="$(mktemp -d)"

# ---------- 日志 ----------
log() {
  local level="$1"; shift
  local ts msg
  ts="$(date '+%F %T')"
  msg="[${ts}] [${level}] [${SCRIPT_NAME}] $*"

  # 【任务1新增】如果是静默模式，且级别不是 ERROR，直接返回，不打印到屏幕
  if [[ "${QUIET}" -eq 1 && "${level}" != "ERROR" ]]; then
    : # 空操作，占位
  else
    if [[ "${level}" == "ERROR" || "${level}" == "WARN" ]]; then
      printf '%s\n' "${msg}" >&2
    elif [[ "${VERBOSE}" -eq 1 || "${level}" == "INFO" ]]; then
      printf '%s\n' "${msg}"
    fi
  fi

  # 文件日志尽力而为，写失败不影响主流程（无论静默与否，都写文件）
  printf '%s\n' "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# ---------- 错误捕获与清理 ----------
on_error() {
  local exit_code=$?
  local line_no=$1
  log ERROR "执行失败: 第 ${line_no} 行, 退出码 ${exit_code}"
  exit "${exit_code}"
}
cleanup() { rm -rf "${TMP_DIR}"; }
trap 'on_error ${LINENO}' ERR
trap cleanup EXIT

# ---------- 用法 ----------
usage() {
  cat <<EOF
用法: ${SCRIPT_NAME} [选项]

选项:
  -c <配置文件>  必填。指定巡检配置文件路径。
  -p <并发数>    可选。最大并发任务数，默认为 5。
  -t <超时秒数>  可选。探测连接或 HTTP 的超时时间，默认为 5。
  -l <日志路径>  可选。指定日志写入文件，默认为 /var/log/${SCRIPT_NAME%.sh}.log。
  -v             可选。详细模式，输出所有 INFO 级别的终端日志。
  -q             可选。静默模式，仅在终端输出 ERROR 和 WARN 级别的日志。
  -h             可选。显示此帮助信息并退出。

配置文件格式 (每行以 | 分隔):
  <名称>|<类型>|<目标>
  
  支持的类型:
    proc  进程名       例: nginx|proc|nginx
    port  本地端口号   例: mysql_port|port|3306
    http  完整 URL     例: web|http|http://127.0.0.1/health

退出码:
  0  全部正常
  1  存在异常检查项
  2  用法错误或配置文件不可读
EOF
}

# ---------- 参数解析 ----------
# 【任务1新增】字符串里加了 q
while getopts ":c:t:l:p:vqh" opt; do
  case "${opt}" in
    c) CONF_FILE="${OPTARG}" ;;
    t) TIMEOUT="${OPTARG}" ;;
    l) LOG_FILE="${OPTARG}" ;;
    p) MAX_JOBS="${OPTARG}" ;; # 新增
    v) VERBOSE=1 ;;
    q) QUIET=1 ;; # 【任务1新增】
    h) usage; exit 0 ;;
    :) log ERROR "选项 -${OPTARG} 需要参数"; usage; exit 2 ;;
    \?) log ERROR "未知选项 -${OPTARG}"; usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# ---------- 检查函数 ----------
check_proc() {
  local name="$1" pattern="$2"
  if pgrep -x "${pattern}" >/dev/null 2>&1; then
    log INFO "PASS ${name}: 进程 ${pattern} 存活"; return 0
  fi
  log ERROR "FAIL ${name}: 进程 ${pattern} 不存在"; return 1
}

check_port() {
  local name="$1" port="$2"
  if timeout "${TIMEOUT}" bash -c "echo > /dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    log INFO "PASS ${name}: 端口 ${port} 可连接"; return 0
  fi
  log ERROR "FAIL ${name}: 端口 ${port} 不可达"; return 1
}

check_http() {
  local name="$1" url="$2" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" "${url}" 2>/dev/null)" || code="000"
  if [[ "${code}" =~ ^[23] ]]; then
    log INFO "PASS ${name}: HTTP ${code} ${url}"; return 0
  fi
  log ERROR "FAIL ${name}: HTTP ${code} ${url}"; return 1
}

# 【任务2新增】统一调度函数
dispatch_check() {
  local name="$1" type="$2" target="$3"
  case "${type}" in
    proc) check_proc "${name}" "${target}" ;;
    port) check_port "${name}" "${target}" ;;
    http) check_http "${name}" "${target}" ;;
    *)    log WARN "跳过未知类型: ${name}|${type}" ; return 0 ;;
  esac
}

# ---------- 主流程 ----------
main() {
  mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
  log INFO "==== 开始巡检 (conf=${CONF_FILE:-none}, timeout=${TIMEOUT}s, jobs=${MAX_JOBS}) ===="

  [[ -n "${CONF_FILE}" ]] || { log ERROR "缺少 -c 参数"; usage; exit 2; }
  [[ -r "${CONF_FILE}" ]] || { log ERROR "配置文件不可读: ${CONF_FILE}"; exit 2; }

  local name type target rest
  local running_jobs=0
  local lineno=0   # 配置行号：结果文件名要带上它，否则同名两项会互相覆盖

  while IFS='|' read -r name type target rest || [[ -n "${name}" ]]; do
    name="${name%$'\r'}"
    [[ -z "${name}" || "${name}" == \#* ]] && continue

    # 【并发控制核心】：如果当前后台任务数达到了上限，就等其中一个结束
    # wait -n 是 bash 4.3+ 的特性，CentOS/Rocky 8+ 完全支持
    if (( running_jobs >= MAX_JOBS )); then
      wait -n
      running_jobs=$((running_jobs - 1))
    fi

    # 【后台并发执行】：把检查任务扔到后台
    lineno=$((lineno + 1))
    (
      # 【修复·命名】结果文件名不能直接拼 ${name}：
      #   1) name 里带 / 或空格 → 重定向直接失败（No such file or directory），该项永远统计不到；
      #   2) 两项同名 → 后写的覆盖先写的，失败项被漏统计。
      # 改用 "行号 + name 的 sha1 前 8 位"：任意字符都安全，同名靠行号区分。
      # dispatch_check 成功返回 0，失败返回 1
      label="$(printf '%s' "${name}" | sha1sum | cut -c1-8)"
      if dispatch_check "${name}" "${type}" "${target}"; then
        echo "0" > "${TMP_DIR}/res_${lineno}_${label}"
      else
        echo "1" > "${TMP_DIR}/res_${lineno}_${label}"
      fi
    ) &
    
    running_jobs=$((running_jobs + 1))
  done < "${CONF_FILE}"

  # 等待剩下的后台任务全部执行完毕
  log INFO "所有检查任务已分发完毕，等待结果汇聚..."
  wait

  # 【结果收集】：遍历临时目录里的小文件，统计失败数
  local res_file
  for res_file in "${TMP_DIR}"/res_*; do
    # 如果目录为空，glob 会返回字面量，需要判断文件是否存在
    [[ -e "${res_file}" ]] || continue
    
    if [[ "$(cat "${res_file}")" == "1" ]]; then
      FAILS=$((FAILS + 1))
    fi
  done

  if (( FAILS > 0 )); then
    log ERROR "==== 巡检结束: ${FAILS} 项异常 ===="
    exit 1
  fi
  log INFO "==== 巡检结束: 全部正常 ===="
  exit 0
}
main "$@"