#!/usr/bin/env bash
# lvm-grow-safe.sh - LVM 在线扩容（带前置断言，专治"扩完 df 不变"）
#
# 用途：
#   把"扩容"这一步从手工命令变成带断言的动作。执行前先证明
#   "挂载点背后的设备 == 要扩的那块 LV"，不一致直接退出，绝不进入写操作。
#
# 用法：
#   ./lvm-grow-safe.sh --dry-run <挂载点> <目标LV> <增量>
#   ./lvm-grow-safe.sh            <挂载点> <目标LV> <增量>
#
# 示例：
#   sudo ./lvm-grow-safe.sh --dry-run /data /dev/rlm/data +2G
#   sudo ./lvm-grow-safe.sh /data /dev/rlm/data +100%FREE
#
# 设计约束：
#   1. 只处理 XFS。其他文件系统一律拒绝，避免 resize2fs / xfs_growfs 混用。
#   2. 断言失败即 exit 1，不留"半扩"状态；--dry-run 只打印计划，不落盘。
#   3. 增量参数原样透传给 lvextend -L，支持 +2G / +100%FREE 写法。
#
# 注意：本脚本尚未在实验机上实跑（静态推演），首次使用请先 --dry-run。
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "${0}")"
DRY_RUN=0

log() {
  local level="$1"; shift
  printf '[%s] [%s] [%s] %s\n' "$(date '+%F %T')" "${level}" "${SCRIPT_NAME}" "$*" >&2
}

usage() {
  cat >&2 <<'EOF'
用法: lvm-grow-safe.sh [--dry-run] <挂载点> <目标LV> <增量>
示例: lvm-grow-safe.sh --dry-run /data /dev/rlm/data +2G
EOF
  exit 2
}

on_error() {
  local exit_code=$?
  log ERROR "执行失败: 第 ${1} 行, 退出码 ${exit_code}"
}

trap 'on_error ${LINENO}' ERR

# ---------- 参数 ----------
[[ $# -ge 3 ]] || usage
if [[ "${1}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi
[[ $# -eq 3 ]] || usage

readonly TARGET_PATH="${1}"
readonly TARGET_LV="${2}"
readonly DELTA="${3}"

[[ "${EUID}" -eq 0 ]] || { log ERROR "需要 root 权限（lvs/lvextend/xfs_growfs）"; exit 1; }

# ---------- 断言 1：路径确实是一个挂载点 ----------
mountpoint -q -- "${TARGET_PATH}" \
  || { log ERROR "${TARGET_PATH} 不是挂载点（或未挂载），拒绝继续"; exit 1; }

# ---------- 断言 2：文件系统类型必须是 XFS ----------
fstype="$(findmnt -no FSTYPE -- "${TARGET_PATH}")"
[[ "${fstype}" == "xfs" ]] \
  || { log ERROR "${TARGET_PATH} 的文件系统是 ${fstype}，本脚本只处理 xfs"; exit 1; }

# ---------- 断言 3：挂载点背后的设备 == 目标 LV ----------
# findmnt 的 SOURCE 可能带 "[/subvol]" 后缀（bind/subvolume），先剥掉
src="$(findmnt -no SOURCE -- "${TARGET_PATH}")"
src="${src%%\[*}"

src_real="$(readlink -f -- "${src}" 2>/dev/null || true)"
lv_real="$(readlink -f -- "${TARGET_LV}" 2>/dev/null || true)"

if [[ -z "${src_real}" || -z "${lv_real}" ]]; then
  log ERROR "设备解析失败: src='${src}' lv='${TARGET_LV}'"
  exit 1
fi

if [[ "${src_real}" != "${lv_real}" ]]; then
  log ERROR "挂载点与目标 LV 不一致，拒绝扩容:"
  log ERROR "  ${TARGET_PATH} -> ${src} (${src_real})"
  log ERROR "  期望 LV    -> ${TARGET_LV} (${lv_real})"
  exit 1
fi

# ---------- 断言 4：目标 LV 是否存在、VG 是否有足够 PE ----------
lvs --noheadings -o vg_name "${TARGET_LV}" >/dev/null
vg_name="$(lvs --noheadings -o vg_name "${TARGET_LV}" | tr -d '[:space:]')"
vfree="$(vgs --noheadings -o vg_free --units g "${vg_name}" | tr -d '[:space:]')"

# ---------- 计划 ----------
log INFO "断言全部通过，准备扩容:"
log INFO "  挂载点      : ${TARGET_PATH} (${fstype})"
log INFO "  目标 LV     : ${TARGET_LV} -> ${src_real}"
log INFO "  增量        : ${DELTA}"
log INFO "  VG 空闲     : ${vg_name} ${vfree}"
log INFO "  当前块设备  : $(blockdev --getsize64 "${TARGET_LV}") 字节"
log INFO "  当前 df     : $(df -h --output=size,avail "${TARGET_PATH}" | tail -n 1 | tr -s ' ')"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log INFO "dry-run 结束，未做任何改动"
  exit 0
fi

# ---------- 执行：块层 → 文件系统层 → 同路径验收 ----------
lvextend -L "${DELTA}" "${TARGET_LV}"
xfs_growfs "${TARGET_PATH}"

log INFO "扩容后块设备: $(blockdev --getsize64 "${TARGET_LV}") 字节"
log INFO "扩容后 df   : $(df -h --output=size,avail "${TARGET_PATH}" | tail -n 1 | tr -s ' ')"
log INFO "完成。请用 df -h ${TARGET_PATH} 做最终人工复核"
