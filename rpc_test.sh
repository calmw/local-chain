#!/usr/bin/env bash
# =============================================================================
# local-chain RPC 健康检测（默认同时测 full + archive）
#
# 用法:
#   ./rpc_test.sh
#   ./rpc_test.sh --full-only
#   ./rpc_test.sh --archive-only
#   ./rpc_test.sh --quick          # 跳过出块等待
#   ./rpc_test.sh --host 127.0.0.1
#
# 默认端口（与 docker-compose.yaml 一致）:
#   full     HTTP 8565  WS 8566
#   archive  HTTP 8575  WS 8576
# =============================================================================
set -euo pipefail

EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-100000}"
# compose 默认 MINER_GAS_PRICE=20000000000 (20 Gwei)
EXPECTED_GAS_PRICE_WEI="${EXPECTED_GAS_PRICE_WEI:-20000000000}"
BLOCK_WAIT_SEC="${BLOCK_WAIT_SEC:-6}"
# 最新块时间戳距今超过该秒数则告警（本地区块应持续出）
BLOCK_STALE_SEC="${BLOCK_STALE_SEC:-30}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
RPC_HOST="${RPC_HOST:-127.0.0.1}"

FULL_HTTP_PORT="${FULL_HTTP_PORT:-8565}"
FULL_WS_PORT="${FULL_WS_PORT:-8566}"
ARCHIVE_HTTP_PORT="${ARCHIVE_HTTP_PORT:-8575}"
ARCHIVE_WS_PORT="${ARCHIVE_WS_PORT:-8576}"

CHECK_FULL=1
CHECK_ARCHIVE=1
QUICK=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

默认检测本机 full + archive RPC。

选项:
  --full-only       只测 full_node
  --archive-only    只测 archive_node
  --quick           跳过出块等待（更快）
  --host HOST       RPC 主机（默认 127.0.0.1）
  -h, --help        帮助

环境变量:
  EXPECTED_CHAIN_ID      默认 100000
  EXPECTED_GAS_PRICE_WEI 默认 20000000000 (20 Gwei)
  BLOCK_WAIT_SEC         出块等待秒数，默认 6
  BLOCK_STALE_SEC        最新块过期阈值，默认 30
  CURL_TIMEOUT           单次请求超时，默认 10
  FULL_HTTP_PORT / FULL_WS_PORT
  ARCHIVE_HTTP_PORT / ARCHIVE_WS_PORT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-only) CHECK_FULL=1; CHECK_ARCHIVE=0; shift ;;
    --archive-only) CHECK_FULL=0; CHECK_ARCHIVE=1; shift ;;
    --quick) QUICK=1; shift ;;
    --host) RPC_HOST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; WARN=$((WARN + 1)); }
info() { echo -e "  ${CYAN}·${NC} $1"; }

# 原始 JSON 响应（失败返回空）
rpc_raw() {
  local url="$1" method="$2" params="${3:-[]}"
  local payload
  payload=$(printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}' "$method" "$params")
  curl -sS --max-time "$CURL_TIMEOUT" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$url" 2>/dev/null || true
}

# 解析 result：字符串 / 布尔 / 数字；对象结果返回 __object__
rpc_call() {
  local url="$1" method="$2" params="${3:-[]}"
  local resp result
  resp=$(rpc_raw "$url" "$method" "$params")
  [[ -n "$resp" ]] || { echo ""; return 1; }
  if echo "$resp" | grep -q '"error"'; then
    echo "$resp"
    return 2
  fi
  result=$(echo "$resp" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [[ -n "$result" ]]; then
    echo "$result"
    return 0
  fi
  if echo "$resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*\{'; then
    echo "__object__"
    return 0
  fi
  if echo "$resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*\['; then
    echo "__array__"
    return 0
  fi
  result=$(echo "$resp" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | head -1 | tr -d ' ')
  echo "$result"
  return 0
}

hex2dec() {
  local h="$1"
  h="${h//\"/}"; h="${h//\'/}"; h="${h// /}"
  h="${h//$'\r'/}"; h="${h//$'\n'/}"
  if [[ "$h" == 0x* || "$h" == 0X* ]]; then
    h="${h:2}"
  fi
  [[ -n "$h" && "$h" =~ ^[0-9A-Fa-f]+$ ]] || { echo "0"; return; }
  echo $((16#$h))
}

json_field() {
  # 从 JSON 对象里抠 "field":"value"
  local json="$1" field="$2"
  echo "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# 探测方法是否开放：ok | closed | error
probe_method() {
  local url="$1" method="$2" params="${3:-[]}"
  local resp err_msg
  resp=$(rpc_raw "$url" "$method" "$params")
  [[ -n "$resp" ]] || { echo "error"; return; }

  if echo "$resp" | grep -q '"result"'; then
    echo "ok"
    return
  fi
  err_msg=$(echo "$resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if echo "$err_msg" | grep -qiE 'not found|not available|does not exist|unknown method|disabled|unauthorized|forbidden'; then
    echo "closed"
    return
  fi
  if echo "$resp" | grep -q '"error"'; then
    echo "ok"
    return
  fi
  echo "error"
}

run_with_timeout() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
      my $secs = shift;
      my $pid = fork();
      die "fork: $!\n" unless defined $pid;
      if ($pid == 0) { exec @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", $pid; sleep 1; kill "KILL", $pid; exit 124; };
      alarm $secs;
      waitpid($pid, 0);
      my $ec = ($? >> 8);
      alarm 0;
      exit $ec;
    ' "$secs" "$@"
  else
    "$@"
  fi
}

check_http_rpc() {
  local name="$1" url="$2" expect_debug="$3" role="$4"
  local result chain_id_hex chain_id block_hex block_n
  local client_ver syncing peer_count peers gas_price gas_wei
  local net_ver listening genesis_resp genesis_hash latest_resp
  local latest_hash latest_ts now age zero_bal early_bal
  peers=0

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  [$name]${NC}  $url"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # 1. chainId
  result=$(rpc_call "$url" "eth_chainId") || true
  if [[ -z "$result" || "$result" == *"error"* ]]; then
    bad "连通性失败，无法获取 chainId"
    info "响应: ${result:-超时/无响应}"
    return 1
  fi
  chain_id_hex="$result"
  chain_id=$(hex2dec "$chain_id_hex")
  if (( chain_id == EXPECTED_CHAIN_ID )); then
    ok "链 ID = $chain_id  [$chain_id_hex]"
  else
    bad "链 ID = $chain_id (期望 $EXPECTED_CHAIN_ID)  [$chain_id_hex]"
  fi

  # 2. net_version（多数实现与 chainId 一致）
  net_ver=$(rpc_call "$url" "net_version") || true
  if [[ -n "$net_ver" && "$net_ver" != *"error"* ]]; then
    if [[ "$net_ver" == "$EXPECTED_CHAIN_ID" || "$net_ver" == "$chain_id_hex" ]]; then
      ok "net_version = $net_ver"
    else
      warn "net_version = ${net_ver} (与 chainId=${EXPECTED_CHAIN_ID} 不一致，请确认 NetworkId)"
    fi
  else
    warn "无法获取 net_version"
  fi

  # 3. client / listening
  client_ver=$(rpc_call "$url" "web3_clientVersion") || true
  if [[ -n "$client_ver" && "$client_ver" != *"error"* ]]; then
    ok "客户端: $client_ver"
  else
    warn "无法获取 web3_clientVersion"
  fi

  listening=$(rpc_call "$url" "net_listening") || true
  if [[ "$listening" == "true" ]]; then
    ok "net_listening = true"
  elif [[ "$listening" == "false" ]]; then
    warn "net_listening = false（未在监听 P2P）"
  else
    info "net_listening 不可用"
  fi

  # 4. 高度
  block_hex=$(rpc_call "$url" "eth_blockNumber") || true
  if [[ -z "$block_hex" || "$block_hex" == *"error"* ]]; then
    bad "无法获取区块高度"
    return 1
  fi
  block_n=$(hex2dec "$block_hex")
  ok "当前区块高度: $block_n  [$block_hex]"
  if (( block_n < 1 )); then
    warn "高度过低，链可能尚未真正出块"
  fi

  # 5. 同步 / peer
  syncing=$(rpc_call "$url" "eth_syncing") || true
  if [[ "$syncing" == "false" ]]; then
    ok "同步状态: 已同步"
  elif [[ -n "$syncing" && "$syncing" != *"error"* && "$syncing" != "__object__" ]]; then
    warn "同步状态: 正在同步 → $syncing"
  elif [[ "$syncing" == "__object__" ]]; then
    warn "同步状态: 正在同步（eth_syncing 返回对象）"
  else
    warn "无法获取 eth_syncing"
  fi

  peer_count=$(rpc_call "$url" "net_peerCount") || true
  if [[ -n "$peer_count" && "$peer_count" != *"error"* ]]; then
    peers=$(hex2dec "$peer_count")
    # 四节点集群：full/archive 通常应有 3 个 peer
    if (( peers >= 3 )); then
      ok "Peer 数量: ${peers}（期望 ≥3）"
    elif (( peers > 0 )); then
      warn "Peer 数量: ${peers}（期望 ≥3，四节点应互连）"
    else
      bad "Peer 数量: 0"
    fi
  else
    warn "无法获取 net_peerCount"
  fi

  # 6. gas price
  gas_price=$(rpc_call "$url" "eth_gasPrice") || true
  if [[ -n "$gas_price" && "$gas_price" != *"error"* ]]; then
    gas_wei=$(hex2dec "$gas_price")
    if (( gas_wei == EXPECTED_GAS_PRICE_WEI )); then
      ok "Gas Price = ${gas_wei} wei (20 Gwei)"
    else
      warn "Gas Price = ${gas_wei} wei（期望 ${EXPECTED_GAS_PRICE_WEI}）"
    fi
  else
    warn "无法获取 eth_gasPrice"
  fi

  # 7. 创世块
  genesis_resp=$(rpc_raw "$url" "eth_getBlockByNumber" '["0x0",false]')
  genesis_hash=$(json_field "$genesis_resp" "hash")
  if [[ -n "$genesis_hash" && "$genesis_hash" == 0x* ]]; then
    ok "创世块 hash: ${genesis_hash:0:18}…"
    case "$role" in
      full) FULL_GENESIS="$genesis_hash" ;;
      archive) ARCHIVE_GENESIS="$genesis_hash" ;;
    esac
  else
    bad "无法获取创世块 eth_getBlockByNumber(0x0)"
  fi

  # 8. 最新块：hash + 时间戳新鲜度
  latest_resp=$(rpc_raw "$url" "eth_getBlockByNumber" '["latest",false]')
  latest_hash=$(json_field "$latest_resp" "hash")
  latest_ts=$(json_field "$latest_resp" "timestamp")
  if [[ -n "$latest_hash" && "$latest_hash" == 0x* ]]; then
    ok "最新块 hash: ${latest_hash:0:18}…"
    case "$role" in
      full) FULL_LATEST_HASH="$latest_hash"; FULL_HEIGHT="$block_n" ;;
      archive) ARCHIVE_LATEST_HASH="$latest_hash"; ARCHIVE_HEIGHT="$block_n" ;;
    esac
  else
    bad "无法获取最新块 eth_getBlockByNumber(latest)"
  fi
  if [[ -n "$latest_ts" ]]; then
    now=$(date +%s)
    age=$(( now - $(hex2dec "$latest_ts") ))
    if (( age < 0 )); then age=0; fi
    if (( age <= BLOCK_STALE_SEC )); then
      ok "最新块时间戳新鲜（${age}s 前）"
    else
      bad "最新块过旧（${age}s 前，阈值 ${BLOCK_STALE_SEC}s）— 可能已停块"
    fi
  fi

  # 9. 状态读：余额 / call
  zero_bal=$(rpc_call "$url" "eth_getBalance" '["0x0000000000000000000000000000000000000000","latest"]') || true
  if [[ -n "$zero_bal" && "$zero_bal" != *"error"* && "$zero_bal" == 0x* ]]; then
    ok "eth_getBalance(0x0) = $zero_bal"
  else
    bad "eth_getBalance 失败"
  fi

  result=$(rpc_call "$url" "eth_call" '[{"to":"0x0000000000000000000000000000000000000000","data":"0x"},"latest"]') || true
  if [[ -n "$result" && "$result" != *"error"* ]]; then
    ok "eth_call 可用"
  else
    # 部分节点对空 call 可能 revert，但方法应存在
    local st
    st=$(probe_method "$url" "eth_call" '[{"to":"0x0000000000000000000000000000000000000000","data":"0x"},"latest"]')
    if [[ "$st" == "ok" || "$st" == "closed" ]]; then
      # closed 不应发生；ok 含执行错误也算开放
      if [[ "$st" == "ok" ]]; then
        ok "eth_call 方法可用"
      else
        bad "eth_call 未开放"
      fi
    else
      warn "eth_call 无明确响应"
    fi
  fi

  # 10. archive：历史状态可读（块 1）
  if [[ "$role" == "archive" ]] && (( block_n >= 1 )); then
    early_bal=$(rpc_call "$url" "eth_getBalance" '["0x0000000000000000000000000000000000000000","0x1"]') || true
    if [[ -n "$early_bal" && "$early_bal" != *"error"* && "$early_bal" == 0x* ]]; then
      ok "archive 历史状态: eth_getBalance(..., block=1) 可用"
    else
      bad "archive 历史状态不可读（GC/非 archive？）: ${early_bal:-empty}"
    fi
  fi

  # 11. API 模块
  echo ""
  info "API 模块探测..."
  local dbg_status txpool_status
  dbg_status=$(probe_method "$url" "debug_traceBlockByNumber" '["latest",{"tracer":"callTracer"}]')
  case "$dbg_status" in
    ok) ok "debug_traceBlockByNumber: 可用" ;;
    closed) info "debug_traceBlockByNumber: 未开放" ;;
    *) warn "debug_traceBlockByNumber: 无响应" ;;
  esac

  txpool_status=$(probe_method "$url" "txpool_status" '[]')
  case "$txpool_status" in
    ok) ok "txpool_status: 可用" ;;
    closed) info "txpool_status: 未开放" ;;
    *) info "txpool_status: 无响应" ;;
  esac

  if [[ "$dbg_status" == "ok" ]]; then
    if [[ "$expect_debug" == "yes" ]]; then
      ok "Debug 模块: 已开启（符合 archive 预期）"
    else
      warn "Debug 模块: 已开启（full 默认可不开放）"
    fi
  else
    if [[ "$expect_debug" == "yes" ]]; then
      bad "Debug 模块: 未开启（archive 预期应开放）"
    else
      ok "Debug 模块: 未开启（符合 full 预期）"
    fi
  fi
  return 0
}

check_ws_rpc() {
  local name="$1" url="$2"
  local result="" err="" chain_hex chain_id errfile

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  [$name WebSocket]${NC}  $url"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  errfile=$(mktemp)

  if command -v websocat >/dev/null 2>&1; then
    result=$(printf '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}\n' \
      | run_with_timeout "$CURL_TIMEOUT" websocat -n1 --text "$url" 2>"$errfile") || true
  elif command -v python3 >/dev/null 2>&1; then
    result=$(python3 - "$url" "$CURL_TIMEOUT" <<'PY' 2>"$errfile"
import sys, json, socket, base64, os, struct
from urllib.parse import urlparse

url, timeout = sys.argv[1], float(sys.argv[2])

def ws_mask(data: bytes) -> bytes:
    key = os.urandom(4)
    masked = bytes(b ^ key[i % 4] for i, b in enumerate(data))
    return bytes([0x81, 0x80 | len(data)]) + key + masked

u = urlparse(url)
host, port = u.hostname, u.port or 80
path = u.path or "/"
if u.query:
    path += "?" + u.query
with socket.create_connection((host, port), timeout=timeout) as sock:
    sock.settimeout(timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    header, _, rest = buf.partition(b"\r\n\r\n")
    if b"101" not in header.split(b"\r\n", 1)[0]:
        print("handshake_fail", file=sys.stderr)
        sys.exit(1)
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}).encode()
    sock.sendall(ws_mask(payload))
    data = rest
    while len(data) < 2:
        data += sock.recv(4096)
    ln, idx = data[1] & 0x7F, 2
    if ln == 126:
        while len(data) < 4:
            data += sock.recv(4096)
        ln = struct.unpack("!H", data[2:4])[0]
        idx = 4
    while len(data) < idx + ln:
        data += sock.recv(4096)
    print(data[idx:idx + ln].decode(errors="replace"))
PY
) || true
  else
    warn "未安装 websocat / python3，跳过 WebSocket 检测"
    rm -f "$errfile"
    return
  fi

  err=$(tr '\n' ' ' <"$errfile" 2>/dev/null || true)
  rm -f "$errfile"
  err=$(echo "$err" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')

  if [[ -z "$result" ]]; then
    bad "WebSocket 连通失败${err:+: $err}"
    return
  fi

  chain_hex=$(echo "$result" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [[ -n "$chain_hex" ]]; then
    chain_id=$(hex2dec "$chain_hex")
    if (( chain_id == EXPECTED_CHAIN_ID )); then
      ok "WebSocket 正常, 链 ID = $chain_id"
    else
      bad "WebSocket 可达, 链 ID = $chain_id (期望 $EXPECTED_CHAIN_ID)"
    fi
  else
    bad "WebSocket 响应异常: $result"
  fi
}

check_block_progress() {
  local url="$1" label="$2"
  local h1_hex h1 h2_hex h2

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  出块检测 (${label})${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  h1_hex=$(rpc_call "$url" "eth_blockNumber") || true
  if [[ -z "$h1_hex" || "$h1_hex" == *"error"* ]]; then
    bad "出块检测：无法读取高度"
    return
  fi
  h1=$(hex2dec "$h1_hex")
  info "等待 ${BLOCK_WAIT_SEC}s ... (起点高度 ${h1})"
  sleep "$BLOCK_WAIT_SEC"
  h2_hex=$(rpc_call "$url" "eth_blockNumber") || true
  if [[ -z "$h2_hex" || "$h2_hex" == *"error"* ]]; then
    bad "出块检测：二次读取失败"
    return
  fi
  h2=$(hex2dec "$h2_hex")
  if (( h2 > h1 )); then
    ok "出块正常: $h1 → $h2 (+$((h2 - h1)) 块 / ${BLOCK_WAIT_SEC}s)"
  elif (( h2 == h1 )); then
    bad "出块停滞: 高度仍为 $h2"
  else
    warn "区块高度回退: $h1 → $h2"
  fi
}

compare_nodes() {
  local full_url="http://${RPC_HOST}:${FULL_HTTP_PORT}"
  local arch_url="http://${RPC_HOST}:${ARCHIVE_HTTP_PORT}"
  local fh_hex ah_hex fh ah delta common_hex
  local full_blk arch_blk full_hash arch_hash

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  full ↔ archive 一致性${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [[ -n "${FULL_GENESIS:-}" && -n "${ARCHIVE_GENESIS:-}" ]]; then
    if [[ "$FULL_GENESIS" == "$ARCHIVE_GENESIS" ]]; then
      ok "创世块一致: ${FULL_GENESIS:0:18}…"
    else
      bad "创世块不一致（fork / 不同链）"
      info "full=${FULL_GENESIS}"
      info "archive=${ARCHIVE_GENESIS}"
    fi
  fi

  fh_hex=$(rpc_call "$full_url" "eth_blockNumber") || true
  ah_hex=$(rpc_call "$arch_url" "eth_blockNumber") || true
  if [[ -z "$fh_hex" || "$fh_hex" == *"error"* || -z "$ah_hex" || "$ah_hex" == *"error"* ]]; then
    warn "无法同时读取高度，跳过对比"
    return
  fi
  fh=$(hex2dec "$fh_hex")
  ah=$(hex2dec "$ah_hex")
  info "full=${fh}  archive=${ah}"
  delta=$(( fh - ah ))
  if (( delta < 0 )); then delta=$(( -delta )); fi
  if (( delta <= 2 )); then
    ok "高度基本一致（差 ${delta} 块）"
  elif (( delta <= 20 )); then
    warn "高度偏差 ${delta} 块（可能仍在追赶）"
  else
    bad "高度偏差过大: ${delta} 块"
  fi

  # 取双方都已有的高度，比对同一块 hash
  if (( fh <= ah )); then
    common_hex=$(printf '0x%x' "$fh")
  else
    common_hex=$(printf '0x%x' "$ah")
  fi
  full_blk=$(rpc_raw "$full_url" "eth_getBlockByNumber" "[\"${common_hex}\",false]")
  arch_blk=$(rpc_raw "$arch_url" "eth_getBlockByNumber" "[\"${common_hex}\",false]")
  full_hash=$(json_field "$full_blk" "hash")
  arch_hash=$(json_field "$arch_blk" "hash")
  if [[ -n "$full_hash" && -n "$arch_hash" ]]; then
    if [[ "$full_hash" == "$arch_hash" ]]; then
      ok "同高度块 hash 一致 (${common_hex}): ${full_hash:0:18}…"
    else
      bad "同高度块 hash 不一致 (${common_hex}) — 可能分叉"
      info "full=${full_hash}"
      info "archive=${arch_hash}"
    fi
  else
    warn "无法比对同高度块 hash"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
FULL_GENESIS=""
ARCHIVE_GENESIS=""
FULL_LATEST_HASH=""
ARCHIVE_LATEST_HASH=""
FULL_HEIGHT=""
ARCHIVE_HEIGHT=""

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         local-chain RPC 健康检测                     ║${NC}"
echo -e "${BOLD}║  host=${RPC_HOST}  chainId=${EXPECTED_CHAIN_ID}  wait=${BLOCK_WAIT_SEC}s           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

# 先测 HTTP（不出块等待），再统一出块，再测 WS / 对比
if [[ "${CHECK_FULL}" -eq 1 ]]; then
  check_http_rpc "full_node HTTP" \
    "http://${RPC_HOST}:${FULL_HTTP_PORT}" "no" "full" || true
fi
if [[ "${CHECK_ARCHIVE}" -eq 1 ]]; then
  check_http_rpc "archive_node HTTP" \
    "http://${RPC_HOST}:${ARCHIVE_HTTP_PORT}" "yes" "archive" || true
fi

# 只等待一次出块（用优先 archive，否则 full）
if [[ "${QUICK}" -eq 0 ]]; then
  if [[ "${CHECK_ARCHIVE}" -eq 1 ]]; then
    check_block_progress "http://${RPC_HOST}:${ARCHIVE_HTTP_PORT}" "archive"
  elif [[ "${CHECK_FULL}" -eq 1 ]]; then
    check_block_progress "http://${RPC_HOST}:${FULL_HTTP_PORT}" "full"
  fi
else
  info "已跳过出块等待 (--quick)"
fi

if [[ "${CHECK_FULL}" -eq 1 ]]; then
  check_ws_rpc "full_node" "ws://${RPC_HOST}:${FULL_WS_PORT}"
fi
if [[ "${CHECK_ARCHIVE}" -eq 1 ]]; then
  check_ws_rpc "archive_node" "ws://${RPC_HOST}:${ARCHIVE_WS_PORT}"
fi

if [[ "${CHECK_FULL}" -eq 1 && "${CHECK_ARCHIVE}" -eq 1 ]]; then
  compare_nodes
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  检测汇总${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}通过: $PASS${NC}    ${RED}失败: $FAIL${NC}    ${YELLOW}警告: $WARN${NC}"
if [[ "${CHECK_FULL}" -eq 1 ]]; then
  echo -e "  full:    http://${RPC_HOST}:${FULL_HTTP_PORT}  ws://${RPC_HOST}:${FULL_WS_PORT}"
fi
if [[ "${CHECK_ARCHIVE}" -eq 1 ]]; then
  echo -e "  archive: http://${RPC_HOST}:${ARCHIVE_HTTP_PORT}  ws://${RPC_HOST}:${ARCHIVE_WS_PORT}"
fi
echo ""

if (( FAIL > 0 )); then
  echo -e "${RED}结论: 存在失败项，请检查节点是否已启动、端口是否映射正确${NC}"
  exit 1
fi
echo -e "${GREEN}结论: RPC 检测通过${NC}"
exit 0
