#!/usr/bin/env bash
# 停止本地链全部节点 + Blockscout
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

KEEP_NETWORK=0
NODES_ONLY=0
BS_ONLY=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

停止 Blockscout 与四个链节点容器。

选项:
  --nodes-only      只停链节点
  --blockscout-only 只停 Blockscout
  --keep-network    不停/不删 local-chain_net（供 start.sh 重启时复用）
  -h, --help        帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes-only) NODES_ONLY=1; shift ;;
    --blockscout-only) BS_ONLY=1; shift ;;
    --keep-network) KEEP_NETWORK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

log() { echo "==> $*"; }

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: 未找到 docker" >&2
  exit 1
fi

stop_blockscout() {
  local bs_dir="${ROOT_DIR}/blockscout"
  if [[ ! -f "${bs_dir}/docker-compose.yml" ]]; then
    log "未找到 Blockscout compose，跳过"
    return 0
  fi
  log "停止 Blockscout ..."
  (
    cd "${bs_dir}"
    if [[ -f .env ]]; then
      docker compose --env-file .env down --remove-orphans || true
    else
      docker compose down --remove-orphans || true
    fi
  )
}

stop_nodes() {
  if [[ ! -f "${ROOT_DIR}/docker-compose.yaml" ]]; then
    log "未找到 docker-compose.yaml，跳过链节点"
    return 0
  fi
  log "停止链节点 ..."
  local args=(down --remove-orphans)
  # 默认 down 会移除 compose 创建的网络；--keep-network 时改用 stop
  if [[ "${KEEP_NETWORK}" -eq 1 ]]; then
    if [[ -f "${ROOT_DIR}/.env" ]]; then
      docker compose --env-file "${ROOT_DIR}/.env" -f "${ROOT_DIR}/docker-compose.yaml" stop || true
    else
      docker compose -f "${ROOT_DIR}/docker-compose.yaml" stop || true
    fi
  else
    if [[ -f "${ROOT_DIR}/.env" ]]; then
      docker compose --env-file "${ROOT_DIR}/.env" -f "${ROOT_DIR}/docker-compose.yaml" "${args[@]}" || true
    else
      docker compose -f "${ROOT_DIR}/docker-compose.yaml" "${args[@]}" || true
    fi
  fi

  # 兼容旧容器名（若仍在跑）
  local name
  for name in validator_1 validator_2 full_node archive_node; do
    if docker ps -q -f "name=^${name}$" 2>/dev/null | grep -q .; then
      log "强制停止残留容器: ${name}"
      docker stop "${name}" >/dev/null || true
    fi
  done
}

echo "=============================="
echo "  local-chain stop"
echo "=============================="

if [[ "${BS_ONLY}" -eq 1 ]]; then
  stop_blockscout
  log "完成"
  exit 0
fi

if [[ "${NODES_ONLY}" -eq 0 ]]; then
  stop_blockscout
fi

if [[ "${BS_ONLY}" -eq 0 ]]; then
  stop_nodes
fi

log "完成"
