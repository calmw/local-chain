#!/usr/bin/env bash
set -e

BASE_DIR=${BASE_DIR:-"/data/chain"}
BIN_DIR=${BIN_DIR:-"/data/chain/bin"}
DATA_DIR=${DATA_DIR:-"/data/app/node"}
HTTP_PORT=${HTTP_PORT:-8545}
WS_PORT=${WS_PORT:-8546}
DB_ENGINE=${DB_ENGINE:-leveldb}
GC_MODE=${GC_MODE:-archive}
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
# Archive 节点状态读多，建议较大缓存
CACHE_MB=${CACHE_MB:-8192}

if [ -d "$DATA_DIR" ] && [ $(ls -A "$DATA_DIR" | grep -v lost+found | wc -l) -ne 0 ]; then
    echo "初始化目录已存在，禁止重复初始化：$DATA_DIR"
else
    echo "开始初始化网络..."
    mkdir -p "${DATA_DIR}"
    cp -f "${BASE_DIR}/config-src/config.toml" "${DATA_DIR}/"
    cp -f "${BASE_DIR}/config-src/genesis.json" "${DATA_DIR}/"

    "$BIN_DIR/geth" init \
    --datadir "${DATA_DIR}" \
    --state.scheme "${STATE_SCHEME}" \
    "${DATA_DIR}/genesis.json" > "$DATA_DIR/init.log" 2>&1
fi

echo "==> Starting node (exec geth → docker logs / SIGTERM → geth)"
echo "HTTP: ${HTTP_PORT}, WS: ${WS_PORT}"
echo ""

cd "${DATA_DIR}" || exit 1

GETH_EXTRA=()
if [ -n "${BOOTNODES}" ]; then
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
    --log.rotate --log.maxsize 100 --log.maxage 7 \
    --log.format terminal


