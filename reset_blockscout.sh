#!/usr/bin/env bash
# 重置 Blockscout：down → 删除数据目录内容 → 再启动（不动链节点数据）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

# shellcheck source=scripts/reset_lib.sh
source "${ROOT_DIR}/scripts/reset_lib.sh"

NO_START=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

1) 停止 Blockscout
2) 删除下列数据目录内容（容器 root 权限时也会清干净）
3) 调用 ./start_blockscout.sh 重新拉起

不影响四个链节点与验证者密钥。

选项:
  -y, --yes       跳过确认
  -n, --dry-run   只打印将执行的操作
      --no-start  只 down + 清数据，不自动重启
  -h, --help      显示帮助

将清理的目录:
  blockscout/services/blockscout-db-data
  blockscout/services/stats-db-data
  blockscout/services/logs
  blockscout/services/dets
  blockscout/services/redis-data
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) RESET_YES=1; shift ;;
    -n|--dry-run) RESET_DRY_RUN=1; shift ;;
    --no-start) NO_START=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

# 浏览器持久化数据（与 compose volume 挂载一致）
BS_DATA_DIRS=(
  "${ROOT_DIR}/blockscout/services/blockscout-db-data"
  "${ROOT_DIR}/blockscout/services/stats-db-data"
  "${ROOT_DIR}/blockscout/services/logs"
  "${ROOT_DIR}/blockscout/services/dets"
  "${ROOT_DIR}/blockscout/services/redis-data"
)

echo "=============================="
echo "  Blockscout RESET"
echo "=============================="
echo "将: down 浏览器 → 删除数据目录 → $([ "${NO_START}" -eq 1 ] && echo '不重启' || echo './start_blockscout.sh')"
echo "数据目录:"
for d in "${BS_DATA_DIRS[@]}"; do
  echo "  - ${d#"${ROOT_DIR}/"}"
done
[[ "${RESET_DRY_RUN}" -eq 1 ]] && echo "模式: dry-run"
echo ""

reset_confirm "确认重置 Blockscout（会删除浏览器索引数据，链节点不受影响）？"

if [[ "${RESET_DRY_RUN}" -eq 1 ]]; then
  echo "==> [dry-run] ${ROOT_DIR}/stop_blockscout.sh"
else
  echo "==> 停止 Blockscout ..."
  "${ROOT_DIR}/stop_blockscout.sh" || true
fi

for d in "${BS_DATA_DIRS[@]}"; do
  reset_wipe_dir "${d}" "Blockscout 数据"
done

# 确保目录存在，供下次 compose 挂载
if [[ "${RESET_DRY_RUN}" -eq 0 ]]; then
  mkdir -p "${BS_DATA_DIRS[@]}"
fi

if [[ "${NO_START}" -eq 1 ]]; then
  echo ""
  echo "==> 已清库（--no-start）。需要时执行: ./start_blockscout.sh"
  exit 0
fi

if [[ "${RESET_DRY_RUN}" -eq 1 ]]; then
  echo "==> [dry-run] ${ROOT_DIR}/start_blockscout.sh"
  exit 0
fi

echo ""
echo "==> 重新启动 Blockscout ..."
exec "${ROOT_DIR}/start_blockscout.sh"
