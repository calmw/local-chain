#!/usr/bin/env bash
set -e

BASE_DIR=${BASE_DIR:-"/data/chain"}
BIN_DIR=${BIN_DIR:-"/data/chain/bin"}
KEYS_DIR=${KEYS_DIR:-"/data/app/keys"}
DATA_DIR=${DATA_DIR:-"/data/app/node"}
HTTP_PORT=${HTTP_PORT:-8545}
WS_PORT=${WS_PORT:-8546}
DB_ENGINE=${DB_ENGINE:-leveldb}
GC_MODE=${GC_MODE:-full}
MINER_GAS_PRICE=${MINER_GAS_PRICE:-20000000000}
MINER_GAS_LIMIT=${MINER_GAS_LIMIT:-35000000}
RPC_URL=${RPC_URL:-"http://127.0.0.1:8545"}
HTTP_API=${HTTP_API:-"eth,net,web3,txpool"}
WS_API=${WS_API:-"eth,net,web3,txpool"}
SYNC_MODE=${SYNC_MODE:-full}
STATE_SCHEME=${STATE_SCHEME:-hash}
METRICS_PORT=${METRICS_PORT:-6060}
PPROF_PORT=${PPROF_PORT:-7060}
P2P_PORT=${P2P_PORT:-30303}
STAKE_AMOUNT=${STAKE_AMOUNT:-2001}
BOOTNODES=${BOOTNODES:-""}
# geth 日志级别：0=silent 1=error 2=warn 3=info 4=debug 5=detail（开发链默认 debug）
VERBOSITY=${VERBOSITY:-4}

# 显式设置 RPC gas cap，避免 config.toml 的 RPCGasCap=0 触发 eth_createAccessList 异常
RPC_GAS_CAP=${RPC_GAS_CAP:-50000000}
# 接口监听地址：validator 私钥解锁在内存，HTTP/WS/pprof 默认仅本机；
# 如果运维有外部访问需求，按需 export HTTP_ADDR=0.0.0.0
HTTP_ADDR=${HTTP_ADDR:-0.0.0.0}
WS_ADDR=${WS_ADDR:-0.0.0.0}
METRICS_ADDR=${METRICS_ADDR:-0.0.0.0}
PPROF_ADDR=${PPROF_ADDR:-127.0.0.1}      # 安全：pprof 不暴露公网，防止解锁的私钥被 heap dump 泄露
# 外部/Tailscale 访问：CORS 与 Virtual Host 默认放开（验证者勿对公网暴露）
HTTP_CORS_DOMAIN=${HTTP_CORS_DOMAIN:-*}
HTTP_VHOSTS=${HTTP_VHOSTS:-*}
WS_ORIGINS=${WS_ORIGINS:-"*"}
# IPC 路径放 datadir 下，避免 /tmp 共享/冲突
IPC_PATH=${IPC_PATH:-${DATA_DIR}/geth.ipc}


echo "=============================="
echo "  Validator Startup Script"
echo "=============================="

keys_ready() {
  [ -f "${KEYS_DIR}/nodekey" ] || return 1
  [ -f "${KEYS_DIR}/password.txt" ] || return 1
  [ -d "${KEYS_DIR}/bls/bls" ] || return 1
  ls "${KEYS_DIR}/validator/keystore/"* >/dev/null 2>&1 || return 1
  return 0
}

# 必须齐全 nodekey / password / bls / validator keystore；空目录或残缺不能跳过生成
if keys_ready; then
  echo "密钥已就绪：$KEYS_DIR"
  echo "跳过密钥生成。"
else
  if [ -d "$KEYS_DIR" ] && [ -n "$(ls -A "$KEYS_DIR" 2>/dev/null || true)" ]; then
    if [ ! -f "${KEYS_DIR}/nodekey" ] && [ ! -d "${KEYS_DIR}/validator/keystore" ]; then
      echo "密钥目录不完整（空/残缺），清理后重新生成：$KEYS_DIR"
      rm -rf "${KEYS_DIR:?}/"*
    else
      echo "ERROR: 密钥目录不完整（缺少 bls/bls 或 nodekey 或 validator/keystore）。" >&2
      echo "请删除 ${KEYS_DIR} 后重启容器，或执行: ./reset_validator.sh -y --wipe-keys" >&2
      exit 1
    fi
  else
    echo "密钥不存在或不完整，开始生成..."
  fi
  # shellcheck disable=SC1091
  source "${BASE_DIR}/node_generate_key.sh"
fi

datadir_has_rialto() {
  [ -f "${DATA_DIR}/init.log" ] || return 1
  grep -q "Successfully wrote genesis state" "${DATA_DIR}/init.log" 2>/dev/null
}

# 仅当 init.log 含 genesis hash 时视为已初始化。
# 注意：reset 后目录可能仍在（空目录或仅有 keystore 拷贝），不能只用 [ -d DATA_DIR ] 判断。
if datadir_has_rialto; then
    echo "初始化目录已存在，跳过 geth init：${DATA_DIR}"
else
    echo "开始初始化网络..."
    mkdir -p "${DATA_DIR}/geth"
    if [ -f "${KEYS_DIR}/nodekey" ]; then
      cp "${KEYS_DIR}/nodekey" "${DATA_DIR}/geth/nodekey"
    fi

    if [ ! -f "${BASE_DIR}/config/genesis.json" ]; then
      echo "ERROR: 缺少创世文件 ${BASE_DIR}/config/genesis.json" >&2
      exit 1
    fi

    "$BIN_DIR/geth" init \
    --datadir "${DATA_DIR}" \
    --state.scheme "${STATE_SCHEME}" \
    "${BASE_DIR}/config/genesis.json" > "$DATA_DIR/init.log" 2>&1 || true

    if ! datadir_has_rialto; then
      echo "ERROR: geth init 失败，无法从 ${DATA_DIR}/init.log 解析 RIALTO hash。日志：" >&2
      cat "${DATA_DIR}/init.log" >&2 || true
      exit 1
    fi
    echo "geth init 完成"
fi

# 每次启动同步密钥与配置到 datadir（keys 可能在 init 之后才生成）
mkdir -p "${DATA_DIR}/geth"
cp -f "${KEYS_DIR}/nodekey" "${DATA_DIR}/geth/nodekey"
cp -f "${KEYS_DIR}/password.txt" "${DATA_DIR}/"
rm -rf "${DATA_DIR}/bls" "${DATA_DIR}/keystore"
cp -R "${KEYS_DIR}/bls/bls" "${DATA_DIR}/bls"
cp -R "${KEYS_DIR}/validator/keystore" "${DATA_DIR}/keystore"
cp -f "${BASE_DIR}/config/config.toml" "${DATA_DIR}/"
cp -f "${BASE_DIR}/config/genesis.json" "${DATA_DIR}/"

geth_pid=""
start_geth_background() {
  # 仅用于注册前 RPC；参数与最终挖矿实例尽量一致（除 --mine/--vote/--miner.*）
  cd "${DATA_DIR}" || exit 1
  "$BIN_DIR/geth" "$@" &
  geth_pid=$!
  echo "geth (background) pid=$geth_pid"
}

stop_geth() {
  if [ -n "${geth_pid}" ] && kill -0 "${geth_pid}" 2>/dev/null; then
    echo "Stopping geth pid=${geth_pid} ..."
    kill -TERM "${geth_pid}"
    wait "${geth_pid}" || true
    geth_pid=""
  fi
}

run_geth_exec() {
  cd "${DATA_DIR}" || exit 1
  trap - INT TERM
  exec "$BIN_DIR/geth" \
    "${GETH_BOOTNODE_ARGS[@]}" \
    --config "${DATA_DIR}/config.toml" \
    --datadir "${DATA_DIR}" \
    --port "${P2P_PORT}" \
    --nodekey "${DATA_DIR}/geth/nodekey" \
    --password "${DATA_DIR}/password.txt" \
    --unlock "${VALIDATOR_ADDR}" \
    --blspassword "${DATA_DIR}/password.txt" \
    --mine --miner.etherbase "${VALIDATOR_ADDR}" --vote \
    --db.engine "${DB_ENGINE}" \
    --gcmode "${GC_MODE}" \
    --syncmode "${SYNC_MODE}" \
    --miner.gasprice "${MINER_GAS_PRICE}" \
    --miner.gaslimit "${MINER_GAS_LIMIT}" \
    --rpc.gascap "${RPC_GAS_CAP}" \
    --http --http.addr "${HTTP_ADDR}" --http.port "${HTTP_PORT}" --http.api "${HTTP_API}" \
    --http.corsdomain "${HTTP_CORS_DOMAIN}" --http.vhosts "${HTTP_VHOSTS}" \
    --ws --ws.addr "${WS_ADDR}" --ws.port "${WS_PORT}" --ws.api "${WS_API}" --ws.origins "${WS_ORIGINS}" \
    --metrics --metrics.addr "${METRICS_ADDR}" --metrics.port "${METRICS_PORT}" \
    --pprof --pprof.addr "${PPROF_ADDR}" --pprof.port "${PPROF_PORT}" \
    --rialtohash "${RIALTO_HASH}" \
    --rpc.allow-unprotected-txs=true \
    --override.lorentz 0 \
    --override.maxwell 0 \
    --ipcpath "${IPC_PATH}" \
    --verbosity "${VERBOSITY}" \
    --log.rotate \
    --log.maxsize 100 \
    --log.maxage 7 \
    --log.format terminal
}

trap 'stop_geth; exit 130' INT
trap 'stop_geth; exit 143' TERM

# 比较 hex Wei 余额是否 >= 阈值（避免 bash 整数溢出）
hex_wei_ge() {
  local balance_hex="${1#0x}"
  local min_hex="${2#0x}"
  balance_hex="$(echo "$balance_hex" | tr 'A-F' 'a-f')"
  min_hex="$(echo "$min_hex" | tr 'A-F' 'a-f')"
  balance_hex="${balance_hex##0}"
  balance_hex="${balance_hex:-0}"
  min_hex="${min_hex##0}"
  min_hex="${min_hex:-0}"

  [ "$balance_hex" != "0" ] || return 1
  if [ ${#balance_hex} -gt ${#min_hex} ]; then
    return 0
  fi
  if [ ${#balance_hex} -lt ${#min_hex} ]; then
    return 1
  fi
  [ "$balance_hex" \> "$min_hex" ] || [ "$balance_hex" = "$min_hex" ]
}

function register_stakehub_single(){
   echo "==> Waiting for chain to be ready..."
  sleep 45  # 等待链启动 RPC ready
   DESC="Val${VALIDATOR_INDEX}"

   echo "==> Waiting for validator ${VALIDATOR_ADDR} to receive funds..."
   echo "    RPC URL: ${RPC_URL}"
   echo "    Description: $DESC"

   # 等待充值
   while true; do
       # 查询余额（返回 16 进制 Wei 单位）
       response=$(curl -s --max-time 10 -X POST ${RPC_URL} \
           -H "Content-Type: application/json" \
           -d '{
               "jsonrpc": "2.0",
               "method": "eth_getBalance",
               "params": ["'${VALIDATOR_ADDR}'", "latest"],
               "id": 1
           }' 2>/dev/null)

       # 检查 curl 是否成功
       if [ $? -ne 0 ]; then
           echo "$(date '+%Y-%m-%d %H:%M:%S') - RPC 连接失败，等待重试..."
           sleep 5
           continue
       fi
       # 检查响应是否有效
       if [ -z "$response" ]; then
           echo "$(date '+%Y-%m-%d %H:%M:%S') - 空的 RPC 响应"
           sleep 5
           continue
       fi
       # 提取 16 进制余额（使用 grep 和 cut）
       hex_balance=$(echo "$response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
       MIN_BALANCE_HEX="6c6b935b8bbc8000" # 2005 * 10^18 Wei
       if [ -n "$hex_balance" ] && [ "$hex_balance" != "0x0" ] && [ "$hex_balance" != "0x" ]; then
           if hex_wei_ge "$hex_balance" "$MIN_BALANCE_HEX"; then
               echo "检测到余额满足要求 (>= 2005)!"
               echo "余额 (十六进制): $hex_balance"
               # 跳出循环，继续执行注册逻辑
               break
           fi
       fi

       echo "$(date '+%Y-%m-%d %H:%M:%S') - 余额: ${hex_balance:-0x0}，继续等待..."
       sleep 15
   done
   sleep 5 # 余额到账后再等5秒，确保链稳定
   echo "==> Validator not registered. Registering and staking..."
   echo $RPC_URL
   echo $DESC
   echo $STAKE_AMOUNT
   TX=$(${BIN_DIR}/create-validator \
               --consensus-key-dir "${DATA_DIR}" \
               --vote-key-dir "${DATA_DIR}" \
               --password-path "${DATA_DIR}/password.txt" \
               --amount ${STAKE_AMOUNT} \
               --validator-desc "${DESC}" \
           --rpc-url $RPC_URL)
   echo "create-validator交易hash: $TX"
   echo "stakeHub registration and staking check complete."
}


#######################################
# 4. 检查是否已注册 StakeHub
#######################################
echo "==> Checking validator registration..."


CONS_ADDR_RAW=$($BIN_DIR/bootnode -nodekey ${KEYS_DIR}/nodekey -writeaddress)
CONS_ADDR="0x${CONS_ADDR_RAW: -40}"
echo "CONS_ADDR = $CONS_ADDR"

KEYFILE=$(ls $KEYS_DIR/validator/keystore | head -n1)
VALIDATOR_ADDR="0x${KEYFILE##*--}"
echo "VALIDATOR_ADDR = $VALIDATOR_ADDR"

#######################################
# 6. 启动验证节点
#######################################

# Start geth node but without registering immediately
echo "==> Starting validator node..."
#RIALTO_HASH=$(grep "Successfully wrote genesis state" ${DATA_DIR}/init.log | awk -F"hash=" '{print $2}')
RIALTO_HASH=$(grep "Successfully wrote genesis state" "${DATA_DIR}/init.log" 2>/dev/null | awk -F"hash=" '{print $2}' | head -n1 | tr -d '\r\n[:space:]' || true)
if [ -z "${RIALTO_HASH}" ]; then
  echo "ERROR: 无法从 ${DATA_DIR}/init.log 解析 RIALTO hash。" >&2
  echo "----- init.log -----" >&2
  cat "${DATA_DIR}/init.log" >&2 || echo "(文件不存在)" >&2
  echo "--------------------" >&2
  exit 1
fi

echo "Address: ${VALIDATOR_ADDR}"
echo "HTTP: ${HTTP_PORT}, WS: ${WS_PORT}"

# geth bootnode 必须是 IP（不能写 validator_1 这类主机名）
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

GETH_BOOTNODE_ARGS=()
if [ -n "${BOOTNODES}" ]; then
  BOOTNODES="$(resolve_bootnodes_ips "${BOOTNODES}")"
  echo "==> Using BOOTNODES=${BOOTNODES}"
  GETH_BOOTNODE_ARGS=(--bootnodes "${BOOTNODES}")
fi

# Check if registered
REGISTER_FLAG="${DATA_DIR}/stake_registered"
if [ -f "${REGISTER_FLAG}" ]; then
    echo "==> StakeHub 已注册，跳过"
    run_geth_exec
else
    echo "==> 首次启动，执行 register"
    if [ "$VALIDATOR_INDEX" == "001" ]; then
      echo "==> first：先起挖矿（后台）并提供RPC，等待充值 createValidator 再 exec 前台"
      start_geth_background \
        "${GETH_BOOTNODE_ARGS[@]}" \
        --config ${DATA_DIR}/config.toml \
        --datadir "${DATA_DIR}" \
        --port "${P2P_PORT}" \
        --nodekey ${DATA_DIR}/geth/nodekey \
        --password ${DATA_DIR}/password.txt \
        --unlock ${VALIDATOR_ADDR} \
        --blspassword ${DATA_DIR}/password.txt \
        --mine --miner.etherbase ${VALIDATOR_ADDR} --vote \
        --db.engine ${DB_ENGINE} \
        --gcmode ${GC_MODE} \
        --syncmode "${SYNC_MODE}" \
        --miner.gasprice ${MINER_GAS_PRICE} \
        --miner.gaslimit ${MINER_GAS_LIMIT} \
        --rpc.gascap "${RPC_GAS_CAP}" \
        --http --http.addr "${HTTP_ADDR}" --http.port ${HTTP_PORT} --http.api "${HTTP_API}" \
        --http.corsdomain "${HTTP_CORS_DOMAIN}" --http.vhosts "${HTTP_VHOSTS}" \
        --ws --ws.addr "${WS_ADDR}" --ws.port ${WS_PORT} --ws.api "${WS_API}" --ws.origins "${WS_ORIGINS}" \
        --metrics --metrics.addr "${METRICS_ADDR}" --metrics.port ${METRICS_PORT} \
        --pprof --pprof.addr "${PPROF_ADDR}" --pprof.port ${PPROF_PORT} \
        --rialtohash ${RIALTO_HASH} \
        --override.lorentz 0 \
        --override.maxwell 0 \
        --ipcpath "${IPC_PATH}" \
        --verbosity "${VERBOSITY}" \
        --log.format terminal \
        --log.rotate \
        --log.maxsize 100 \
        --log.maxage 7
    else
      echo "==> 非 001：先起无挖矿 geth（后台）供同步与注册，再 exec 挖矿前台"
      start_geth_background \
        "${GETH_BOOTNODE_ARGS[@]}" \
        --config ${DATA_DIR}/config.toml \
        --datadir "${DATA_DIR}" \
        --port "${P2P_PORT}" \
        --nodekey ${DATA_DIR}/geth/nodekey \
        --password ${DATA_DIR}/password.txt \
        --unlock ${VALIDATOR_ADDR} \
        --blspassword ${DATA_DIR}/password.txt \
        --db.engine ${DB_ENGINE} \
        --gcmode ${GC_MODE} \
        --syncmode "${SYNC_MODE}" \
        --miner.gasprice ${MINER_GAS_PRICE} \
        --miner.gaslimit ${MINER_GAS_LIMIT} \
        --rpc.gascap "${RPC_GAS_CAP}" \
        --http --http.addr "${HTTP_ADDR}" --http.port ${HTTP_PORT} --http.api "${HTTP_API}" \
        --http.corsdomain "${HTTP_CORS_DOMAIN}" --http.vhosts "${HTTP_VHOSTS}" \
        --ws --ws.addr "${WS_ADDR}" --ws.port ${WS_PORT} --ws.api "${WS_API}" --ws.origins "${WS_ORIGINS}" \
        --metrics --metrics.addr "${METRICS_ADDR}" --metrics.port ${METRICS_PORT} \
        --pprof --pprof.addr "${PPROF_ADDR}" --pprof.port ${PPROF_PORT} \
        --rialtohash ${RIALTO_HASH} \
        --override.lorentz 0 \
        --override.maxwell 0 \
        --ipcpath "${IPC_PATH}" \
        --verbosity "${VERBOSITY}" \
        --log.format terminal \
        --log.rotate \
        --log.maxsize 100 \
        --log.maxage 7
    fi;
    # Once geth is running, register the validator
    register_stakehub_single
    stop_geth
    # Mark as registered
    echo "registered:true" > "${REGISTER_FLAG}"
    echo "==> 已标记为已注册: ${REGISTER_FLAG}"
    run_geth_exec
fi





