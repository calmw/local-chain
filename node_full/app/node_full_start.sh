#!/usr/bin/env bash
set -e

BASE_DIR=${BASE_DIR:-"/data/chain"}
BIN_DIR=${BIN_DIR:-"/data/chain/bin"}
DATA_DIR=${DATA_DIR:-"/data/app/node"}
HTTP_PORT=${HTTP_PORT:-8545}
WS_PORT=${WS_PORT:-8546}
DB_ENGINE=${DB_ENGINE:-leveldb}
GC_MODE=${GC_MODE:-full}
TX_FEE_CAP=${TX_FEE_CAP:-100}
HTTP_API=${HTTP_API:-"eth,net,web3,txpool"}
WS_API=${WS_API:-"eth,net,web3,txpool"}
SYNC_MODE=${SYNC_MODE:-full}
METRICS_PORT=${METRICS_PORT:-6060}
PPROF_PORT=${PPROF_PORT:-7060}
P2P_PORT=${P2P_PORT:-30303}
BOOTNODES=${BOOTNODES:-""}
STATE_SCHEME=${STATE_SCHEME:-hash}

# 显式设置 RPC gas cap，避免 config.toml 的 RPCGasCap=0 触发 eth_createAccessList 异常
RPC_GAS_CAP=${RPC_GAS_CAP:-50000000}
# 接口监听地址：archive 提供对外 RPC，HTTP/WS/metrics 可 0.0.0.0；pprof 必须本机
HTTP_ADDR=${HTTP_ADDR:-0.0.0.0}
WS_ADDR=${WS_ADDR:-0.0.0.0}
METRICS_ADDR=${METRICS_ADDR:-0.0.0.0}
PPROF_ADDR=${PPROF_ADDR:-127.0.0.1}      # 安全：pprof 不暴露公网，避免 heap/profile 泄露
# WS 跨域：默认 * 保持向后兼容；生产建议显式白名单 export WS_ORIGINS="https://your-app.example.com"
WS_ORIGINS=${WS_ORIGINS:-"*"}
# Full 节点状态读多，建议较大缓存
CACHE_MB=${CACHE_MB:-4096}
# geth 日志级别：0=silent 1=error 2=warn 3=info 4=debug 5=detail（开发链默认 debug）
VERBOSITY=${VERBOSITY:-4}

datadir_has_rialto() {
  [ -f "${DATA_DIR}/init.log" ] || return 1
  grep -q "Successfully wrote genesis state" "${DATA_DIR}/init.log" 2>/dev/null
}

# 仅当 init.log 含 genesis hash 时视为已初始化（空目录/残留文件不能跳过 init）
if datadir_has_rialto; then
    echo "初始化目录已存在，跳过 geth init：$DATA_DIR"
else
    echo "开始初始化网络..."
    mkdir -p "${DATA_DIR}"
    # 兼容 BASE_DIR 下 config-src 或 config
    GENESIS_SRC="${BASE_DIR}/config-src/genesis.json"
    CONFIG_SRC="${BASE_DIR}/config-src/config.toml"
    if [ ! -f "${GENESIS_SRC}" ]; then
      GENESIS_SRC="${BASE_DIR}/config/genesis.json"
      CONFIG_SRC="${BASE_DIR}/config/config.toml"
    fi
    if [ ! -f "${GENESIS_SRC}" ]; then
      echo "ERROR: 缺少创世文件（${BASE_DIR}/config-src 或 config）" >&2
      exit 1
    fi
    cp -f "${CONFIG_SRC}" "${DATA_DIR}/config.toml"
    cp -f "${GENESIS_SRC}" "${DATA_DIR}/genesis.json"

    "$BIN_DIR/geth" init \
    --datadir "${DATA_DIR}" \
    --state.scheme "${STATE_SCHEME}" \
    "${DATA_DIR}/genesis.json" > "$DATA_DIR/init.log" 2>&1 || true

    if ! datadir_has_rialto; then
      echo "ERROR: geth init 失败，无法从 ${DATA_DIR}/init.log 解析 RIALTO_HASH。日志：" >&2
      cat "${DATA_DIR}/init.log" >&2 || true
      exit 1
    fi
    echo "geth init 完成"
fi

echo "==> Starting full node (exec geth → docker logs / SIGTERM → geth)"
echo "HTTP: ${HTTP_PORT}, WS: ${WS_PORT}"
echo ""

cd "${DATA_DIR}" || exit 1

# geth bootnode 必须是 IP，不能写 Docker 服务名（如 validator_1）
resolve_bootnodes_ips() {
  local input="${1:-}" out="" item host port key ip
  [ -n "${input}" ] || { echo ""; return 0; }
  local IFS=','
  # shellcheck disable=SC2206
  local items=(${input})
  for item in "${items[@]}"; do
    item="$(echo "${item}" | tr -d '[:space:]')"
    [ -n "${item}" ] || continue
    if [[ "${item}" =~ ^enode://([0-9a-fA-F]+)@([^:]+):([0-9]+) ]]; then
      key="${BASH_REMATCH[1]}"
      host="${BASH_REMATCH[2]}"
      port="${BASH_REMATCH[3]}"
      if [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip="${host}"
      else
        ip="$(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1; exit}')"
        [ -n "${ip}" ] || ip="$(getent hosts "${host}" 2>/dev/null | awk '{print $1; exit}')"
      fi
      if [ -z "${ip}" ]; then
        echo "ERROR: 无法将 bootnode 主机名解析为 IP: ${host}" >&2
        exit 1
      fi
      echo "==> bootnode ${host} -> ${ip}" >&2
      item="enode://${key}@${ip}:${port}"
    fi
    if [ -n "${out}" ]; then out="${out},${item}"; else out="${item}"; fi
  done
  echo "${out}"
}

GETH_EXTRA=()
if [ -n "${BOOTNODES}" ]; then
  BOOTNODES="$(resolve_bootnodes_ips "${BOOTNODES}")"
  echo "==> Using BOOTNODES=${BOOTNODES}"
  GETH_EXTRA+=(--bootnodes "${BOOTNODES}")
fi

# RIALTO_HASH 仅从 init.log 解析（geth init 写入），不使用环境变量。
if [ ! -f "${DATA_DIR}/init.log" ]; then
  echo "ERROR: ${DATA_DIR}/init.log 不存在，无法解析 RIALTO_HASH（请先在本 datadir 成功执行 geth init）。" >&2
  exit 1
fi
RIALTO_HASH=$(grep "Successfully wrote genesis state" "${DATA_DIR}/init.log" 2>/dev/null | awk -F"hash=" '{print $2}' | head -n1 | tr -d '\r\n[:space:]' || true)
if [ -z "${RIALTO_HASH}" ]; then
  echo "ERROR: 无法从 ${DATA_DIR}/init.log 解析 RIALTO_HASH（需含 Successfully wrote genesis state 且含 hash=）。" >&2
  exit 1
fi

exec "$BIN_DIR/geth" \
    "${GETH_EXTRA[@]}" \
    --config "${DATA_DIR}/config.toml" \
    --datadir "${DATA_DIR}" \
    --port "${P2P_PORT}" \
    --rialtohash "${RIALTO_HASH}" \
    --override.lorentz 0 \
    --override.maxwell 0 \
    --rpc.txfeecap "${TX_FEE_CAP}" \
    --rpc.gascap "${RPC_GAS_CAP}" \
    --cache "${CACHE_MB}" \
    --http --http.addr "${HTTP_ADDR}" --http.port "${HTTP_PORT}" --http.api "${HTTP_API}" \
    --ws --ws.addr "${WS_ADDR}" --ws.port "${WS_PORT}" --ws.api "${WS_API}" --ws.origins "${WS_ORIGINS}" \
    --metrics --metrics.addr "${METRICS_ADDR}" --metrics.port "${METRICS_PORT}" \
    --pprof --pprof.addr "${PPROF_ADDR}" --pprof.port "${PPROF_PORT}" \
    --rpc.allow-unprotected-txs=true \
    --syncmode "${SYNC_MODE}" \
    --gcmode "${GC_MODE}" \
    --db.engine "${DB_ENGINE}" \
    --verbosity "${VERBOSITY}" \
    --log.rotate --log.maxsize 100 --log.maxage 7 \
    --log.format terminal


