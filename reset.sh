#!/usr/bin/env bash
# 全量重置：down 节点+浏览器 → 清空链数据与 Blockscout 数据 → 再 start
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

# shellcheck source=scripts/reset_lib.sh
source "${ROOT_DIR}/scripts/reset_lib.sh"

WIPE_KEYS=0
NO_START=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

1) docker compose down 四个节点 + Blockscout
2) 删除各节点 app/node 与 Blockscout 数据目录
3) 调用 ./start.sh 重新拉起

选项:
  -y, --yes         跳过确认
  -n, --dry-run     只打印将执行的操作
      --wipe-keys   同时删除验证者 app/keys（默认保留）
      --no-start    只 down + 清数据，不自动重启
  -h, --help        显示帮助

将清理的目录:
  node_validator_1/app/node
  node_validator_2/app/node
  node_full/app/node
  node_archive/app/node
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
    --wipe-keys) WIPE_KEYS=1; shift ;;
    --no-start) NO_START=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

NODE_DATA_DIRS=(
  "${ROOT_DIR}/node_validator_1/app/node"
  "${ROOT_DIR}/node_validator_2/app/node"
  "${ROOT_DIR}/node_full/app/node"
  "${ROOT_DIR}/node_archive/app/node"
)

BS_DATA_DIRS=(
  "${ROOT_DIR}/blockscout/services/blockscout-db-data"
  "${ROOT_DIR}/blockscout/services/stats-db-data"
  "${ROOT_DIR}/blockscout/services/logs"
  "${ROOT_DIR}/blockscout/services/dets"
  "${ROOT_DIR}/blockscout/services/redis-data"
)

KEY_DIRS=(
  "${ROOT_DIR}/node_validator_1/app/keys"
  "${ROOT_DIR}/node_validator_2/app/keys"
)

echo "=============================="
echo "  local-chain FULL RESET"
echo "=============================="
echo "将: down 全部容器 → 清节点/浏览器数据 → $([ "${NO_START}" -eq 1 ] && echo '不重启' || echo './start.sh')"
echo "wipe keys: $([ "${WIPE_KEYS}" -eq 1 ] && echo yes || echo no)"
[[ "${RESET_DRY_RUN}" -eq 1 ]] && echo "模式: dry-run"
echo ""

confirm_msg="确认全量重置（会删除链数据与 Blockscout 索引）？"
[[ "${WIPE_KEYS}" -eq 1 ]] && confirm_msg="确认全量重置（含验证者密钥）？"
reset_confirm "${confirm_msg}"

# 1) down
log_down() { echo "==> $*"; }

if [[ "${RESET_DRY_RUN}" -eq 1 ]]; then
  log_down "[dry-run] ${ROOT_DIR}/stop.sh"
else
  log_down "停止节点与 Blockscout ..."
  "${ROOT_DIR}/stop.sh" || true
fi

# 2) wipe node + blockscout data
for d in "${NODE_DATA_DIRS[@]}"; do
  reset_wipe_dir "${d}" "节点数据"
done

for d in "${BS_DATA_DIRS[@]}"; do
  reset_wipe_dir "${d}" "Blockscout 数据"
done

if [[ "${WIPE_KEYS}" -eq 1 ]]; then
  for d in "${KEY_DIRS[@]}"; do
    reset_wipe_dir "${d}" "验证者密钥"
  done
fi

# 清掉 start.sh 写回的 BOOTNODES，避免指向已失效公钥
if [[ -f "${ROOT_DIR}/.env" ]]; then
  if grep -q '^BOOTNODES=' "${ROOT_DIR}/.env"; then
    echo "==> 重置 .env 中 BOOTNODES="
    if [[ "${RESET_DRY_RUN}" -eq 1 ]]; then
      echo "[dry-run] BOOTNODES="
    else
      tmp="$(mktemp)"
      awk '/^BOOTNODES=/{print "BOOTNODES="; next} {print}' "${ROOT_DIR}/.env" > "${tmp}"
      mv "${tmp}" "${ROOT_DIR}/.env"
    fi
  fi
fi

# 3) restart
if [[ "${NO_START}" -eq 1 ]]; then
  echo ""
  echo "==> 已清库（--no-start）。需要时执行: ./start.sh"
  exit 0
fi

if [[ "${RESET_DRY_RUN}" -eq 1 ]]; then
  echo "==> [dry-run] ${ROOT_DIR}/start.sh"
  exit 0
fi

echo ""
echo "==> 重新启动 ..."
exec "${ROOT_DIR}/start.sh"
