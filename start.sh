#!/usr/bin/env bash
# 重启本地链全部节点 + Blockscout 浏览器
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

START_BLOCKSCOUT="${START_BLOCKSCOUT:-1}"
WAIT_RPC_TIMEOUT_SEC="${WAIT_RPC_TIMEOUT_SEC:-180}"
SKIP_STOP=0
NODES_ONLY=0
BS_ONLY=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

默认：先停止再启动四个链节点，并重启 Blockscout。

选项:
  --no-blockscout   只启链节点，不启浏览器
  --nodes-only      同 --no-blockscout
  --blockscout-only 只重启 Blockscout（需链 RPC 已可用）
  --no-stop         不先 stop，直接 up（滚动补齐）
  -h, --help        帮助

依赖: Docker Compose v2、仓库根目录 .env
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-blockscout|--nodes-only) START_BLOCKSCOUT=0; NODES_ONLY=1; shift ;;
    --blockscout-only) BS_ONLY=1; shift ;;
    --no-stop) SKIP_STOP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  echo "ERROR: 缺少 ${ROOT_DIR}/.env" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a
source "${ROOT_DIR}/.env"
set +a

START_BLOCKSCOUT="${START_BLOCKSCOUT:-1}"
WAIT_RPC_TIMEOUT_SEC="${WAIT_RPC_TIMEOUT_SEC:-180}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: 未找到 docker" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 需要 Docker Compose v2（docker compose）" >&2
  exit 1
fi

log() { echo "==> $*"; }

compose_chain() {
  docker compose --env-file "${ROOT_DIR}/.env" -f "${ROOT_DIR}/docker-compose.yaml" "$@"
}

wait_for_file() {
  local path="$1" timeout="${2:-120}" elapsed=0
  while [[ ! -f "${path}" ]]; do
    if (( elapsed >= timeout )); then
      echo "ERROR: 等待文件超时 (${timeout}s): ${path}" >&2
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

wait_rpc() {
  local url="$1" timeout="${2:-180}" elapsed=0
  log "等待 RPC 可用: ${url}"
  while true; do
    if curl -sS --max-time 3 -X POST "${url}" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
      | grep -q 'result'; then
      log "RPC 已就绪"
      return 0
    fi
    if (( elapsed >= timeout )); then
      echo "ERROR: RPC 等待超时 (${timeout}s): ${url}" >&2
      return 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
}

resolve_bootnodes() {
  local nodekey="${ROOT_DIR}/node_validator_1/app/keys/nodekey"
  local pubkey=""

  wait_for_file "${nodekey}" 180

  if docker exec validator_1 test -x /data/chain/bin/bootnode 2>/dev/null; then
    pubkey="$(docker exec validator_1 /data/chain/bin/bootnode -nodekey /data/app/keys/nodekey -writeaddress 2>/dev/null | tr -d '\r\n' || true)"
  fi

  if [[ -z "${pubkey}" && -f "${ROOT_DIR}/node_validator_1/app/keys/enode.txt" ]]; then
    # enode://<pubkey>@host:port
    pubkey="$(sed -n 's|^enode://\([0-9a-fA-F]*\)@.*|\1|p' "${ROOT_DIR}/node_validator_1/app/keys/enode.txt" | head -n1)"
  fi

  if [[ -z "${pubkey}" ]]; then
    echo "ERROR: 无法解析 validator_1 公钥（nodekey / enode.txt）" >&2
    return 1
  fi

  BOOTNODES="enode://${pubkey}@validator_1:30303"
  export BOOTNODES
  log "BOOTNODES=${BOOTNODES}"

  # 写回 .env 中的 BOOTNODES= 行，便于下次与 docker compose 直接使用
  if grep -q '^BOOTNODES=' "${ROOT_DIR}/.env"; then
    # shellcheck disable=SC2094
    local tmp
    tmp="$(mktemp)"
    awk -v v="${BOOTNODES}" 'BEGIN{done=0} /^BOOTNODES=/{print "BOOTNODES=" v; done=1; next} {print} END{if(!done) print "BOOTNODES=" v}' \
      "${ROOT_DIR}/.env" > "${tmp}"
    mv "${tmp}" "${ROOT_DIR}/.env"
  else
    echo "BOOTNODES=${BOOTNODES}" >> "${ROOT_DIR}/.env"
  fi
}

start_nodes() {
  mkdir -p \
    "${ROOT_DIR}/node_validator_1/app/node" "${ROOT_DIR}/node_validator_1/app/keys" \
    "${ROOT_DIR}/node_validator_2/app/node" "${ROOT_DIR}/node_validator_2/app/keys" \
    "${ROOT_DIR}/node_full/app/node" \
    "${ROOT_DIR}/node_archive/app/node"

  log "启动 validator_1 ..."
  compose_chain up -d validator_1

  log "解析 BOOTNODES ..."
  resolve_bootnodes

  log "启动 validator_2 / full_node / archive_node ..."
  compose_chain up -d validator_2 full_node archive_node

  wait_rpc "http://127.0.0.1:8575" "${WAIT_RPC_TIMEOUT_SEC}" || \
    wait_rpc "http://127.0.0.1:8545" 60 || true

  log "链节点状态:"
  compose_chain ps
}

# 把根目录 PUBLIC_HOST 同步到 blockscout/.env（浏览器侧必须用可从客户端访问的主机名）
sync_public_host_to_blockscout() {
  local bs_env="${ROOT_DIR}/blockscout/.env"
  local host="${PUBLIC_HOST:-localhost}"
  local proto="${NEXT_PUBLIC_APP_PROTOCOL:-http}"
  local bind="${BIND_ADDR:-0.0.0.0}"

  # 去掉误填的协议前缀
  host="${host#http://}"
  host="${host#https://}"
  host="${host%%/*}"

  if [[ ! -f "${bs_env}" ]]; then
    echo "ERROR: 缺少 ${bs_env}" >&2
    return 1
  fi

  log "同步对外访问主机 PUBLIC_HOST=${host}"

  local tmp
  tmp="$(mktemp)"
  awk -v host="${host}" -v proto="${proto}" -v bind="${bind}" '
    function set(k, v) { print k "=" v; seen[k]=1; next }
    /^PUBLIC_HOST=/ { set("PUBLIC_HOST", host) }
    /^BIND_ADDR=/ { set("BIND_ADDR", bind) }
    /^NEXT_PUBLIC_API_HOST=/ { set("NEXT_PUBLIC_API_HOST", host) }
    /^NEXT_PUBLIC_APP_HOST=/ { set("NEXT_PUBLIC_APP_HOST", host) }
    /^NEXT_PUBLIC_API_PROTOCOL=/ { set("NEXT_PUBLIC_API_PROTOCOL", proto) }
    /^NEXT_PUBLIC_APP_PROTOCOL=/ { set("NEXT_PUBLIC_APP_PROTOCOL", proto) }
    /^NEXT_PUBLIC_STATS_API_HOST=/ { set("NEXT_PUBLIC_STATS_API_HOST", proto "://" host ":8080") }
    /^NEXT_PUBLIC_VISUALIZE_API_HOST=/ { set("NEXT_PUBLIC_VISUALIZE_API_HOST", proto "://" host ":8081") }
    /^NEXT_PUBLIC_NETWORK_RPC_URL=/ { set("NEXT_PUBLIC_NETWORK_RPC_URL", proto "://" host ":8575") }
    { print }
    END {
      if (!seen["PUBLIC_HOST"]) print "PUBLIC_HOST=" host
      if (!seen["BIND_ADDR"]) print "BIND_ADDR=" bind
      if (!seen["NEXT_PUBLIC_API_HOST"]) print "NEXT_PUBLIC_API_HOST=" host
      if (!seen["NEXT_PUBLIC_APP_HOST"]) print "NEXT_PUBLIC_APP_HOST=" host
      if (!seen["NEXT_PUBLIC_STATS_API_HOST"]) print "NEXT_PUBLIC_STATS_API_HOST=" proto "://" host ":8080"
      if (!seen["NEXT_PUBLIC_VISUALIZE_API_HOST"]) print "NEXT_PUBLIC_VISUALIZE_API_HOST=" proto "://" host ":8081"
      if (!seen["NEXT_PUBLIC_NETWORK_RPC_URL"]) print "NEXT_PUBLIC_NETWORK_RPC_URL=" proto "://" host ":8575"
    }
  ' "${bs_env}" > "${tmp}"
  mv "${tmp}" "${bs_env}"
}

start_blockscout() {
  local bs_dir="${ROOT_DIR}/blockscout"
  local host="${PUBLIC_HOST:-localhost}"
  host="${host#http://}"; host="${host#https://}"; host="${host%%/*}"

  if [[ ! -f "${bs_dir}/docker-compose.yml" ]]; then
    echo "ERROR: 未找到 ${bs_dir}/docker-compose.yml" >&2
    return 1
  fi

  sync_public_host_to_blockscout

  # 确保链网络存在，供 Blockscout backend 直连 archive_node
  docker network inspect local-chain_net >/dev/null 2>&1 || compose_chain up -d --no-start validator_1

  log "重启 Blockscout ..."
  (
    cd "${bs_dir}"
    mkdir -p services/logs services/dets services/blockscout-db-data services/stats-db-data
    docker compose --env-file .env down --remove-orphans >/dev/null 2>&1 || true
    docker compose --env-file .env up -d --pull missing
  )
  log "Explorer: http://${host}/"
}

echo "=============================="
echo "  local-chain start"
echo "=============================="

if [[ "${BS_ONLY}" -eq 1 ]]; then
  start_blockscout
  exit 0
fi

if [[ "${SKIP_STOP}" -eq 0 ]]; then
  log "先停止现有服务 ..."
  "${ROOT_DIR}/stop.sh" --keep-network || true
fi

start_nodes

if [[ "${START_BLOCKSCOUT}" == "1" && "${NODES_ONLY}" -eq 0 ]]; then
  start_blockscout
else
  log "已跳过 Blockscout"
fi

host="${PUBLIC_HOST:-localhost}"
host="${host#http://}"; host="${host#https://}"; host="${host%%/*}"

echo ""
log "完成"
echo "  本机:"
echo "    validator_1 RPC : http://127.0.0.1:8545"
echo "    validator_2 RPC : http://127.0.0.1:8555"
echo "    full RPC        : http://127.0.0.1:8565"
echo "    archive RPC     : http://127.0.0.1:8575"
if [[ "${START_BLOCKSCOUT}" == "1" && "${NODES_ONLY}" -eq 0 ]]; then
  echo "    Blockscout      : http://127.0.0.1/"
fi
echo "  外部/Tailscale (PUBLIC_HOST=${host}):"
echo "    archive RPC     : http://${host}:8575"
echo "    full RPC        : http://${host}:8565"
echo "    validator_1 RPC : http://${host}:8545"
if [[ "${START_BLOCKSCOUT}" == "1" && "${NODES_ONLY}" -eq 0 ]]; then
  echo "    Blockscout      : http://${host}/"
fi
echo ""
echo "提示: 外出访问请把根目录 .env 的 PUBLIC_HOST 设为 Tailscale MagicDNS 或 100.x，然后重新 ./start.sh"
echo "提示: 验证者首次启动需向 VALIDATOR_ADDR 充值后完成 StakeHub 注册。"
