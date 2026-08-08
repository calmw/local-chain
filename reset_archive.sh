#!/usr/bin/env bash
# 重置归档节点：停止相关容器并清空链数据（保留 config）
#
# 默认:
#   DATA_DIR  = <repo>/node_archive/app/node
#   CONTAINER = archive_node   （设为空字符串可跳过停容器）
#
# 用法:
#   ./reset_archive.sh
#   ./reset_archive.sh -y
#   ./reset_archive.sh -n
#   DATA_DIR=/data/app/node FORCE_OUTSIDE_REPO=1 ./reset_archive.sh -y

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/reset_lib.sh
source "${SCRIPT_DIR}/scripts/reset_lib.sh"

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

重置 archive 节点链数据，下次启动会重新 geth init。

选项:
  -y, --yes      跳过确认
  -n, --dry-run  只打印将执行的操作
  -h, --help     显示帮助

环境变量:
  DATA_DIR              链数据目录（默认: ${ROOT_DIR}/node_archive/app/node）
  CONTAINER             Docker 容器名（默认: archive_node；空=不停容器）
  FORCE_OUTSIDE_REPO=1  允许清理仓库外的 DATA_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) RESET_YES=1; shift ;;
    -n|--dry-run) RESET_DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

NODE_ROOT="${ROOT_DIR}/node_archive"

# 默认数据目录优先级:
# 1) 显式 DATA_DIR
# 2) node_archive/app/node（多节点布局）
# 3) 仓库根 app/node（根目录 docker-compose.yaml 的 ./app 挂载）
if [[ -z "${DATA_DIR:-}" ]]; then
  if [[ -d "${NODE_ROOT}/app" || -d "${NODE_ROOT}/app/node" ]]; then
    DATA_DIR="${NODE_ROOT}/app/node"
  elif [[ -d "${ROOT_DIR}/app" || -d "${ROOT_DIR}/app/node" ]]; then
    DATA_DIR="${ROOT_DIR}/app/node"
  else
    DATA_DIR="${NODE_ROOT}/app/node"
  fi
fi
CONTAINER="${CONTAINER-archive_node}"

echo "=============================="
echo "  Reset ARCHIVE node"
echo "=============================="
echo "DATA_DIR : ${DATA_DIR}"
echo "CONTAINER: ${CONTAINER:-"(skip)"}"
[[ "${RESET_DRY_RUN}" -eq 1 ]] && echo "模式    : dry-run"
echo ""

reset_confirm "确认清空 archive 链数据？"

if [[ -n "${CONTAINER}" ]]; then
  reset_stop_containers "${CONTAINER}"
fi
reset_wipe_dir "${DATA_DIR}" "archive 链数据"

echo ""
echo "==> archive 已重置。重新启动后会执行 geth init。"
echo "    示例: bash ${NODE_ROOT}/node_archive_start.sh"
