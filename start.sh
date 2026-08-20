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

# 固定内网 IP（与 docker-compose / .env 一致）；变更子网/网名时需重建网络
CHAIN_NETWORK="${CHAIN_NETWORK:-bot-local-chain_net}"
IP_VALIDATOR_1="${IP_VALIDATOR_1:-172.30.88.11}"
IP_VALIDATOR_2="${IP_VALIDATOR_2:-172.30.88.12}"
IP_FULL="${IP_FULL:-172.30.88.13}"
IP_ARCHIVE="${IP_ARCHIVE:-172.30.88.14}"
CHAIN_SUBNET="${CHAIN_SUBNET:-172.30.88.0/24}"

ensure_chain_net() {
  local net="${CHAIN_NETWORK}" current=""
  if ! docker network inspect "${net}" >/dev/null 2>&1; then
    return 0
  fi
  current="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "${net}" 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "${current}" && "${current}" != "${CHAIN_SUBNET}" ]]; then
    log "网络 ${net} 子网 ${current} ≠ ${CHAIN_SUBNET}，重建网络 ..."
    compose_chain down --remove-orphans || true
    # Blockscout 等外部容器可能仍挂在旧网上
    local cid
    for cid in $(docker ps -aq --filter network="${net}" 2>/dev/null); do
      docker network disconnect -f "${net}" "${cid}" 2>/dev/null || true
    done
    docker network rm "${net}" 2>/dev/null || true
  fi
}

# stop --keep-network 后若网络被重建，旧容器仍记着失效 NetworkID，up 会报 network ... not found
purge_stale_chain_containers() {
  local net="${CHAIN_NETWORK}" want_id="" name got
  want_id="$(docker network inspect -f '{{.Id}}' "${net}" 2>/dev/null | tr -d '\r\n' || true)"
  for name in validator_1 validator_2 full_node archive_node; do
    docker inspect "${name}" >/dev/null 2>&1 || continue
    got="$(docker inspect -f "{{with index .NetworkSettings.Networks \"${net}\"}}{{.NetworkID}}{{end}}" "${name}" 2>/dev/null | tr -d '\r\n' || true)"
    # 仍挂在旧网名 local-chain_net 上也视为过期
    if [[ -z "${got}" ]]; then
      got="$(docker inspect -f '{{with index .NetworkSettings.Networks "local-chain_net"}}{{.NetworkID}}{{end}}' "${name}" 2>/dev/null | tr -d '\r\n' || true)"
      if [[ -n "${got}" ]]; then
        log "容器 ${name} 仍在旧网络 local-chain_net，移除以便迁到 ${net}"
        docker rm -f "${name}" >/dev/null 2>&1 || true
        continue
      fi
    fi
    if [[ -z "${want_id}" ]]; then
      if [[ -n "${got}" ]]; then
        log "网络 ${net} 已不存在，移除残留容器 ${name}"
        docker rm -f "${name}" >/dev/null 2>&1 || true
      fi
      continue
    fi
    if [[ -n "${got}" && "${got}" != "${want_id}" ]]; then
      log "容器 ${name} 挂在旧网络 ${got:0:12}…，移除以便挂到当前 ${net}"
      docker rm -f "${name}" >/dev/null 2>&1 || true
    fi
  done
}

resolve_bootnodes() {
  local nodekey="${ROOT_DIR}/node_validator_1/app/keys/nodekey"
  local pubkey="" ip="${IP_VALIDATOR_1}"

  wait_for_file "${nodekey}" 180

  # 优先用 compose 固定 IP；校验容器实际地址是否一致
  local actual
  actual="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${CHAIN_NETWORK}\").IPAddress}}" validator_1 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "${actual}" && "${actual}" != "${ip}" ]]; then
    log "警告: validator_1 实际 IP=${actual}，与配置 IP_VALIDATOR_1=${ip} 不一致，改用实际 IP"
    ip="${actual}"
  fi
  if [[ -z "${ip}" ]]; then
    echo "ERROR: 未配置 IP_VALIDATOR_1 且无法从容器读取 IP" >&2
    return 1
  fi

  if docker exec validator_1 test -x /data/chain/bin/bootnode 2>/dev/null; then
    pubkey="$(docker exec validator_1 /data/chain/bin/bootnode -nodekey /data/app/keys/nodekey -writeaddress 2>/dev/null | tr -d '\r\n' || true)"
  fi

  if [[ -z "${pubkey}" && -f "${ROOT_DIR}/node_validator_1/app/keys/enode.txt" ]]; then
    pubkey="$(sed -n 's|^enode://\([0-9a-fA-F]*\)@.*|\1|p' "${ROOT_DIR}/node_validator_1/app/keys/enode.txt" | head -n1)"
  fi

  if [[ -z "${pubkey}" ]]; then
    echo "ERROR: 无法解析 validator_1 公钥（nodekey / enode.txt）" >&2
    return 1
  fi

  # 仅连接本集群 validator_1（固定内网 IP），不写外部 bootnode
  BOOTNODES="enode://${pubkey}@${ip}:30303"
  export BOOTNODES
  log "BOOTNODES=${BOOTNODES}"
  log "内网: v1=${IP_VALIDATOR_1} v2=${IP_VALIDATOR_2} full=${IP_FULL} archive=${IP_ARCHIVE}"

  if grep -q '^BOOTNODES=' "${ROOT_DIR}/.env"; then
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

  ensure_chain_net
  purge_stale_chain_containers

  log "启动 validator_1 ..."
  compose_chain up -d validator_1

  log "解析 BOOTNODES ..."
  resolve_bootnodes

  log "启动 validator_2 / full_node / archive_node ..."
  compose_chain up -d validator_2 full_node archive_node

  local archive_http="${HOST_PORT_ARCHIVE_HTTP:-8575}"
  local v1_http="${HOST_PORT_V1_HTTP:-8545}"
  wait_rpc "http://127.0.0.1:${archive_http}" "${WAIT_RPC_TIMEOUT_SEC}" || \
    wait_rpc "http://127.0.0.1:${v1_http}" 60 || true

  log "链节点状态:"
  compose_chain ps
}

# 把根目录 PUBLIC_HOST 同步到 blockscout/.env（浏览器侧必须用可从客户端访问的主机名）
sync_public_host_to_blockscout() {
  local bs_env="${ROOT_DIR}/blockscout/.env"
  local host="${PUBLIC_HOST:-localhost}"
  local proto="${NEXT_PUBLIC_APP_PROTOCOL:-http}"
  local bind="${BIND_ADDR:-0.0.0.0}"
  local archive_http="${HOST_PORT_ARCHIVE_HTTP:-8575}"

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
  # awk 函数内不能使用 next，故在规则里直接改写
  awk -v host="${host}" -v proto="${proto}" -v bind="${bind}" -v archive_http="${archive_http}" '
    /^PUBLIC_HOST=/ { print "PUBLIC_HOST=" host; seen["PUBLIC_HOST"]=1; next }
    /^BIND_ADDR=/ { print "BIND_ADDR=" bind; seen["BIND_ADDR"]=1; next }
    /^NEXT_PUBLIC_API_HOST=/ { print "NEXT_PUBLIC_API_HOST=" host; seen["NEXT_PUBLIC_API_HOST"]=1; next }
    /^NEXT_PUBLIC_APP_HOST=/ { print "NEXT_PUBLIC_APP_HOST=" host; seen["NEXT_PUBLIC_APP_HOST"]=1; next }
    /^NEXT_PUBLIC_API_PROTOCOL=/ { print "NEXT_PUBLIC_API_PROTOCOL=" proto; seen["NEXT_PUBLIC_API_PROTOCOL"]=1; next }
    /^NEXT_PUBLIC_APP_PROTOCOL=/ { print "NEXT_PUBLIC_APP_PROTOCOL=" proto; seen["NEXT_PUBLIC_APP_PROTOCOL"]=1; next }
    /^NEXT_PUBLIC_STATS_API_HOST=/ { print "NEXT_PUBLIC_STATS_API_HOST=" proto "://" host ":8080"; seen["NEXT_PUBLIC_STATS_API_HOST"]=1; next }
    /^NEXT_PUBLIC_VISUALIZE_API_HOST=/ { print "NEXT_PUBLIC_VISUALIZE_API_HOST=" proto "://" host ":8081"; seen["NEXT_PUBLIC_VISUALIZE_API_HOST"]=1; next }
    /^NEXT_PUBLIC_NETWORK_RPC_URL=/ { print "NEXT_PUBLIC_NETWORK_RPC_URL=" proto "://" host ":" archive_http; seen["NEXT_PUBLIC_NETWORK_RPC_URL"]=1; next }
    { print }
    END {
      if (!seen["PUBLIC_HOST"]) print "PUBLIC_HOST=" host
      if (!seen["BIND_ADDR"]) print "BIND_ADDR=" bind
      if (!seen["NEXT_PUBLIC_API_HOST"]) print "NEXT_PUBLIC_API_HOST=" host
      if (!seen["NEXT_PUBLIC_APP_HOST"]) print "NEXT_PUBLIC_APP_HOST=" host
      if (!seen["NEXT_PUBLIC_API_PROTOCOL"]) print "NEXT_PUBLIC_API_PROTOCOL=" proto
      if (!seen["NEXT_PUBLIC_APP_PROTOCOL"]) print "NEXT_PUBLIC_APP_PROTOCOL=" proto
      if (!seen["NEXT_PUBLIC_STATS_API_HOST"]) print "NEXT_PUBLIC_STATS_API_HOST=" proto "://" host ":8080"
      if (!seen["NEXT_PUBLIC_VISUALIZE_API_HOST"]) print "NEXT_PUBLIC_VISUALIZE_API_HOST=" proto "://" host ":8081"
      if (!seen["NEXT_PUBLIC_NETWORK_RPC_URL"]) print "NEXT_PUBLIC_NETWORK_RPC_URL=" proto "://" host ":" archive_http
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
  docker network inspect "${CHAIN_NETWORK}" >/dev/null 2>&1 || compose_chain up -d --no-start validator_1

  log "重启 Blockscout ..."
  (
    cd "${bs_dir}"
    mkdir -p services/logs services/dets services/blockscout-db-data services/stats-db-data
    # 同步网名到 blockscout/.env（chain external + 业务网固定子网）
    upsert_bs_env_var() {
      local key="$1" val="$2" tmp
      if ! grep -q "^${key}=" .env 2>/dev/null; then
        echo "${key}=${val}" >> .env
      else
        tmp="$(mktemp)"
        awk -v k="${key}" -v v="${val}" 'BEGIN{done=0} index($0,k"=")==1{print k"="v; done=1; next} {print} END{if(!done) print k"="v}' .env >"${tmp}"
        mv "${tmp}" .env
      fi
    }
    upsert_bs_env_var CHAIN_NETWORK "${CHAIN_NETWORK}"
    upsert_bs_env_var BLOCKSCOUT_NETWORK "${BLOCKSCOUT_NETWORK:-bot-local-chain-bs_net}"
    upsert_bs_env_var BLOCKSCOUT_SUBNET "${BLOCKSCOUT_SUBNET:-172.30.89.0/24}"
    upsert_bs_env_var BLOCKSCOUT_GATEWAY "${BLOCKSCOUT_GATEWAY:-172.30.89.1}"
    docker compose --env-file .env down --remove-orphans >/dev/null 2>&1 || true
    # 旧 compose 项目名 / 通用容器名残留清理（改名前的 backend、db、proxy 等）
    docker compose -p local-chain-blockscout --env-file .env down --remove-orphans >/dev/null 2>&1 || true
    local old
    for old in backend frontend proxy db redis-db stats stats-db visualizer sig-provider smart-contract-verifier user-ops-indexer nft_media_handler; do
      docker rm -f "${old}" >/dev/null 2>&1 || true
    done
    docker network rm local-chain-blockscout_default >/dev/null 2>&1 || true
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
v1_http="${HOST_PORT_V1_HTTP:-8545}"
v2_http="${HOST_PORT_V2_HTTP:-8555}"
full_http="${HOST_PORT_FULL_HTTP:-8565}"
archive_http="${HOST_PORT_ARCHIVE_HTTP:-8575}"

echo ""
log "完成"
echo "  本机:"
echo "    validator_1 RPC : http://127.0.0.1:${v1_http}"
echo "    validator_2 RPC : http://127.0.0.1:${v2_http}"
echo "    full RPC        : http://127.0.0.1:${full_http}"
echo "    archive RPC     : http://127.0.0.1:${archive_http}"
if [[ "${START_BLOCKSCOUT}" == "1" && "${NODES_ONLY}" -eq 0 ]]; then
  echo "    Blockscout      : http://127.0.0.1/"
fi
echo "  外部/Tailscale (PUBLIC_HOST=${host}):"
echo "    archive RPC     : http://${host}:${archive_http}"
echo "    full RPC        : http://${host}:${full_http}"
echo "    validator_1 RPC : http://${host}:${v1_http}"
if [[ "${START_BLOCKSCOUT}" == "1" && "${NODES_ONLY}" -eq 0 ]]; then
  echo "    Blockscout      : http://${host}/"
fi
echo ""
echo "提示: 外出访问请把根目录 .env 的 PUBLIC_HOST 设为 Tailscale MagicDNS 或 100.x，然后重新 ./start.sh"
echo "提示: 验证者首次启动需向 VALIDATOR_ADDR 充值后完成 StakeHub 注册。"
