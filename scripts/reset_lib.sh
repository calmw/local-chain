#!/usr/bin/env bash
# Shared helpers for reset_*.sh (sourced, not executed directly)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RESET_YES=0
RESET_DRY_RUN=0

reset_confirm() {
  local msg="$1"
  if [[ "${RESET_YES}" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "ERROR: 非交互环境请加 -y/--yes" >&2
    exit 1
  fi
  read -r -p "${msg} [y/N] " ans
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *) echo "已取消"; exit 0 ;;
  esac
}

reset_run() {
  if [[ "${RESET_DRY_RUN}" -eq 1 ]]; then
    echo "[dry-run] $*"
    return 0
  fi
  "$@"
}

# 停止容器（存在才停；不存在不报错）
reset_stop_containers() {
  local name
  if ! command -v docker >/dev/null 2>&1; then
    echo "==> 未安装 docker，跳过停容器"
    return 0
  fi
  for name in "$@"; do
    [[ -n "${name}" ]] || continue
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
      echo "==> 停止容器: ${name}"
      reset_run docker stop "${name}" >/dev/null || true
    else
      echo "==> 容器不存在，跳过: ${name}"
    fi
  done
}

# 清空目录内容，保留目录本身；含安全检查
# Docker 卷常为 root 权限：宿主机 rm 失败时用临时容器以 root 删除
reset_wipe_dir() {
  local dir="$1"
  local label="${2:-目录}"

  if [[ -z "${dir}" || "${dir}" == "/" || "${dir}" == "${HOME}" || "${dir}" == "${ROOT_DIR}" ]]; then
    echo "ERROR: 拒绝危险路径: '${dir}'" >&2
    exit 1
  fi

  # 默认只允许清仓库内路径，或显式 FORCE_OUTSIDE_REPO=1
  case "${dir}" in
    "${ROOT_DIR}"/*) ;;
    *)
      if [[ "${FORCE_OUTSIDE_REPO:-0}" != "1" ]]; then
        echo "ERROR: 路径不在仓库内: ${dir}" >&2
        echo "       若确需清理，请设置 FORCE_OUTSIDE_REPO=1" >&2
        exit 1
      fi
      ;;
  esac

  if [[ ! -e "${dir}" ]]; then
    echo "==> ${label}不存在，跳过: ${dir}"
    return 0
  fi

  if [[ ! -d "${dir}" ]]; then
    echo "ERROR: 不是目录: ${dir}" >&2
    exit 1
  fi

  echo "==> 清空${label}: ${dir}"
  if [[ "${RESET_DRY_RUN}" -eq 1 ]]; then
    echo "[dry-run] rm -rf ${dir}/* (含 docker root 回退)"
    return 0
  fi

  # 先尝试宿主机删除
  if find "${dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
    # 确认已空
    if [[ -z "$(find "${dir}" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]]; then
      return 0
    fi
  fi

  # Postgres 等目录多为容器 root 所有，用 alpine 以 root 清空
  if command -v docker >/dev/null 2>&1; then
    echo "==> ${label}权限受限，改用 docker 以 root 清空 ..."
    docker run --rm -v "${dir}:/wipe" alpine:3.20 \
      sh -c 'rm -rf /wipe/* /wipe/.[!.]* /wipe/..?* 2>/dev/null || true'
  else
    echo "ERROR: 无法清空 ${dir}（权限不足且无 docker）" >&2
    exit 1
  fi

  if [[ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]]; then
    echo "ERROR: 清空失败，仍有残留: ${dir}" >&2
    exit 1
  fi
}
