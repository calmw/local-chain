#!/usr/bin/env bash
# 重置两个验证节点（validator_1 + validator_2）
# 默认只清链数据；加 --wipe-keys 同时清密钥（下次启动会重新生成）
#
# 默认路径:
#   node_validator_1/app/{node,keys}
#   node_validator_2/app/{node,keys}
#
# 用法:
#   ./reset_validator.sh
#   ./reset_validator.sh -y
#   ./reset_validator.sh -y --wipe-keys
#   ./reset_validator.sh -n

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/reset_lib.sh
source "${SCRIPT_DIR}/scripts/reset_lib.sh"

WIPE_KEYS=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

同时重置 node_validator_1 与 node_validator_2。

选项:
  -y, --yes         跳过确认
  -n, --dry-run     只打印将执行的操作
      --wipe-keys   同时删除密钥目录（默认保留 keys，仅清链数据）
  -h, --help        显示帮助

环境变量（可选覆盖单个节点路径）:
  V1_DATA_DIR / V1_KEYS_DIR / V1_CONTAINER   （默认容器名: validator_1）
  V2_DATA_DIR / V2_KEYS_DIR / V2_CONTAINER   （默认容器名: validator_2）
  FORCE_OUTSIDE_REPO=1                       允许清理仓库外路径

说明:
  - 清 DATA_DIR 后下次启动会重新 geth init，并重新走 StakeHub 注册流程
  - 不加 --wipe-keys 时保留验证者 / BLS / nodekey，身份不变
  - 加 --wipe-keys 后需重新生成密钥并给新地址充值
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) RESET_YES=1; shift ;;
    -n|--dry-run) RESET_DRY_RUN=1; shift ;;
    --wipe-keys) WIPE_KEYS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

V1_ROOT="${ROOT_DIR}/node_validator_1"
V2_ROOT="${ROOT_DIR}/node_validator_2"

V1_DATA_DIR="${V1_DATA_DIR:-${V1_ROOT}/app/node}"
V1_KEYS_DIR="${V1_KEYS_DIR:-${V1_ROOT}/app/keys}"
V1_CONTAINER="${V1_CONTAINER-validator_1}"

V2_DATA_DIR="${V2_DATA_DIR:-${V2_ROOT}/app/node}"
V2_KEYS_DIR="${V2_KEYS_DIR:-${V2_ROOT}/app/keys}"
V2_CONTAINER="${V2_CONTAINER-validator_2}"

echo "=============================="
echo "  Reset VALIDATOR nodes (1+2)"
echo "=============================="
echo "validator_1:"
echo "  DATA_DIR : ${V1_DATA_DIR}"
echo "  KEYS_DIR : ${V1_KEYS_DIR}"
echo "  CONTAINER: ${V1_CONTAINER:-"(skip)"}"
echo "validator_2:"
echo "  DATA_DIR : ${V2_DATA_DIR}"
echo "  KEYS_DIR : ${V2_KEYS_DIR}"
echo "  CONTAINER: ${V2_CONTAINER:-"(skip)"}"
echo "wipe keys  : $([[ "${WIPE_KEYS}" -eq 1 ]] && echo yes || echo no)"
[[ "${RESET_DRY_RUN}" -eq 1 ]] && echo "模式      : dry-run"
echo ""

confirm_msg="确认重置两个验证节点的链数据？"
[[ "${WIPE_KEYS}" -eq 1 ]] && confirm_msg="确认重置两个验证节点的链数据 + 密钥？"
reset_confirm "${confirm_msg}"

containers=()
[[ -n "${V1_CONTAINER}" ]] && containers+=("${V1_CONTAINER}")
[[ -n "${V2_CONTAINER}" ]] && containers+=("${V2_CONTAINER}")
if [[ ${#containers[@]} -gt 0 ]]; then
  reset_stop_containers "${containers[@]}"
fi

reset_wipe_dir "${V1_DATA_DIR}" "validator_1 链数据"
reset_wipe_dir "${V2_DATA_DIR}" "validator_2 链数据"

if [[ "${WIPE_KEYS}" -eq 1 ]]; then
  reset_wipe_dir "${V1_KEYS_DIR}" "validator_1 密钥"
  reset_wipe_dir "${V2_KEYS_DIR}" "validator_2 密钥"
fi

echo ""
echo "==> 两个验证节点已重置。"
if [[ "${WIPE_KEYS}" -eq 1 ]]; then
  echo "    密钥已删除：下次启动会重新生成，需向新 VALIDATOR_ADDR 充值后再注册。"
else
  echo "    密钥已保留：下次启动会用原身份重新 init / 注册。"
fi
echo "    示例:"
echo "      VALIDATOR_INDEX=001 bash ${V1_ROOT}/node_validator_start.sh"
echo "      VALIDATOR_INDEX=002 bash ${V2_ROOT}/node_validator_start.sh"
