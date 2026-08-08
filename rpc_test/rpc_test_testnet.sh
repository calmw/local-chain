#!/usr/bin/env bash
# =============================================================================
# BotChain 测试网本机 RPC 健康检测
# 用途：docker compose 拉起本机 archive RPC 后，对本机端口做健康检查
# 检测项：连通性、链 ID、出块、同步状态、debug 模块、WebSocket
#
# 用法:
#   ./rpc_test_testnet.sh
#   ./rpc_test_testnet.sh 127.0.0.1
#   ./rpc_test_testnet.sh 127.0.0.1 8545 8546
#   RPC_HOST=127.0.0.1 HTTP_PORT=8545 WS_PORT=8546 ./rpc_test_testnet.sh
# =============================================================================
set -euo pipefail

EXPECTED_CHAIN_ID=100000
BLOCK_WAIT_SEC=8
CURL_TIMEOUT=10

# 本机默认地址（与 docker-compose.yaml 端口映射一致）
RPC_HOST="${RPC_HOST:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-8545}"
WS_PORT="${WS_PORT:-8546}"
# docker-compose 默认 HTTP_API/WS_API 不含 debug，预期不开放
EXPECT_DEBUG="${EXPECT_DEBUG:-no}"

# 可选位置参数: [host] [http_port] [ws_port]
if [[ $# -ge 1 && "$1" != "-h" && "$1" != "--help" ]]; then
  RPC_HOST="$1"
fi
if [[ $# -ge 2 ]]; then
  HTTP_PORT="$2"
fi
if [[ $# -ge 3 ]]; then
  WS_PORT="$3"
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
用法: $0 [host] [http_port] [ws_port]

默认检测本机 RPC:
  HTTP  http://${RPC_HOST}:${HTTP_PORT}
  WS    ws://${RPC_HOST}:${WS_PORT}

环境变量:
  RPC_HOST       默认 127.0.0.1
  HTTP_PORT      默认 8545
  WS_PORT        默认 8546
  EXPECT_DEBUG   yes|no，默认 no（与 compose 默认 API 一致）
  BLOCK_WAIT_SEC 出块等待秒数，默认 8
  CURL_TIMEOUT   单次请求超时秒数，默认 10
EOF
  exit 0
fi

HTTP_URL="http://${RPC_HOST}:${HTTP_PORT}"
WS_URL="ws://${RPC_HOST}:${WS_PORT}"

# 颜色
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

# JSON-RPC 调用，返回 result 字段（失败返回空）
rpc_call() {
  local url="$1" method="$2" params="${3:-[]}"
  local payload resp result

  payload=$(printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}' "$method" "$params")
  resp=$(curl -sS --max-time "$CURL_TIMEOUT" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$url" 2>/dev/null) || { echo ""; return 1; }

  # 有 error 字段则失败
  if echo "$resp" | grep -q '"error"'; then
    echo "$resp"
    return 2
  fi

  # 优先取带引号的字符串 result
  result=$(echo "$resp" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [[ -z "$result" ]]; then
    # 非字符串 result（如 boolean）
    result=$(echo "$resp" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | head -1 | tr -d ' ')
  fi
  echo "$result"
  return 0
}

# 十六进制转十进制（兼容 0x / 0X、引号、空白）
hex2dec() {
  local h="$1"
  # 去掉引号与空白
  h="${h//\"/}"
  h="${h//\'/}"
  h="${h// /}"
  h="${h//$'\r'/}"
  h="${h//$'\n'/}"
  # 去掉 0x / 0X 前缀
  if [[ "$h" == 0x* || "$h" == 0X* ]]; then
    h="${h:2}"
  fi
  # 空或非十六进制
  [[ -n "$h" && "$h" =~ ^[0-9A-Fa-f]+$ ]] || { echo "0"; return; }
  # bash 原生转换，不依赖 bc
  echo $((16#$h))
}

# 检测单个 HTTP RPC
check_http_rpc() {
  local name="$1" url="$2" expect_debug="$3"
  local result chain_id_hex chain_id block1_hex block1 block2_hex block2
  local client_ver syncing peer_count gas_price

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  [$name]${NC}  $url"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # 1. 连通性 + 链 ID
  result=$(rpc_call "$url" "eth_chainId") || true
  if [[ -z "$result" || "$result" == *"error"* ]]; then
    bad "连通性失败，无法获取 chainId"
    info "响应: ${result:-超时/无响应}"
    return
  fi
  chain_id_hex="$result"
  chain_id=$(hex2dec "$chain_id_hex")
  if (( chain_id == EXPECTED_CHAIN_ID )); then
    ok "链 ID = $chain_id (期望 $EXPECTED_CHAIN_ID)  [$chain_id_hex]"
  else
    bad "链 ID = $chain_id (期望 $EXPECTED_CHAIN_ID)  [$chain_id_hex]"
  fi

  # 2. 客户端版本
  client_ver=$(rpc_call "$url" "web3_clientVersion") || true
  if [[ -n "$client_ver" && "$client_ver" != *"error"* ]]; then
    ok "客户端: $client_ver"
  else
    warn "无法获取 web3_clientVersion"
  fi

  # 3. 当前区块高度
  block1_hex=$(rpc_call "$url" "eth_blockNumber") || true
  if [[ -z "$block1_hex" || "$block1_hex" == *"error"* ]]; then
    bad "无法获取区块高度"
    return
  fi
  block1=$(hex2dec "$block1_hex")
  ok "当前区块高度: $block1  [$block1_hex]"

  # 4. 出块检测：等待后再次取高度
  info "等待 ${BLOCK_WAIT_SEC}s 检测是否出块..."
  sleep "$BLOCK_WAIT_SEC"
  block2_hex=$(rpc_call "$url" "eth_blockNumber") || true
  if [[ -z "$block2_hex" || "$block2_hex" == *"error"* ]]; then
    bad "二次获取区块高度失败"
  else
    block2=$(hex2dec "$block2_hex")
    if (( block2 > block1 )); then
      ok "出块正常: $block1 → $block2 (+$((block2 - block1)) 块 / ${BLOCK_WAIT_SEC}s)"
    elif (( block2 == block1 )); then
      bad "出块停滞: 高度仍为 $block2（${BLOCK_WAIT_SEC}s 内无新块）"
    else
      warn "区块高度回退: $block1 → $block2（可能节点切换/重组）"
    fi
  fi

  # 5. 同步状态
  syncing=$(rpc_call "$url" "eth_syncing") || true
  if [[ "$syncing" == "false" ]]; then
    ok "同步状态: 已同步 (eth_syncing=false)"
  elif [[ -n "$syncing" && "$syncing" != *"error"* ]]; then
    warn "同步状态: 正在同步 → $syncing"
  else
    warn "无法获取 eth_syncing"
  fi

  # 6. Peer 数量
  peer_count=$(rpc_call "$url" "net_peerCount") || true
  if [[ -n "$peer_count" && "$peer_count" != *"error"* ]]; then
    local peers
    peers=$(hex2dec "$peer_count")
    if (( peers > 0 )); then
      ok "Peer 数量: $peers"
    else
      warn "Peer 数量: 0（可能为归档/隔离节点）"
    fi
  else
    warn "无法获取 net_peerCount"
  fi

  # 7. Gas Price
  gas_price=$(rpc_call "$url" "eth_gasPrice") || true
  if [[ -n "$gas_price" && "$gas_price" != *"error"* ]]; then
    ok "Gas Price: $gas_price"
  else
    warn "无法获取 eth_gasPrice"
  fi

  # 8. Debug 模块检测
  echo ""
  info "检测 debug 模块..."
  local debug_ok=0 debug_fail=0
  local debug_methods=("debug_traceBlockByNumber" "debug_getRawBlock" "debug_metrics")

  # debug_traceBlockByNumber — 用 latest 试探是否开放
  local dbg_resp
  dbg_resp=$(curl -sS --max-time "$CURL_TIMEOUT" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"debug_traceBlockByNumber","params":["latest",{"tracer":"callTracer"}]}' \
    "$url" 2>/dev/null) || dbg_resp=""

  if echo "$dbg_resp" | grep -q '"result"'; then
    ok "debug_traceBlockByNumber: 可用"
    debug_ok=$((debug_ok + 1))
  elif echo "$dbg_resp" | grep -qiE 'method.*(not found|not available|does not exist)|unknown method|disabled'; then
    info "debug_traceBlockByNumber: 未开放"
    debug_fail=$((debug_fail + 1))
  elif echo "$dbg_resp" | grep -q '"error"'; then
    # 有 error 但不是 method not found，可能是参数/执行错误，说明方法存在
    local err_msg
    err_msg=$(echo "$dbg_resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if echo "$err_msg" | grep -qiE 'not found|not available|does not exist|unknown method|disabled|unauthorized|forbidden'; then
      info "debug_traceBlockByNumber: 未开放 ($err_msg)"
      debug_fail=$((debug_fail + 1))
    else
      ok "debug_traceBlockByNumber: 方法存在 (执行报错: ${err_msg:-unknown})"
      debug_ok=$((debug_ok + 1))
    fi
  else
    info "debug_traceBlockByNumber: 无响应/超时"
    debug_fail=$((debug_fail + 1))
  fi

  # debug_getRawBlock
  dbg_resp=$(curl -sS --max-time "$CURL_TIMEOUT" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"debug_getRawBlock","params":["latest"]}' \
    "$url" 2>/dev/null) || dbg_resp=""

  if echo "$dbg_resp" | grep -q '"result"'; then
    ok "debug_getRawBlock: 可用"
    debug_ok=$((debug_ok + 1))
  elif echo "$dbg_resp" | grep -q '"error"'; then
    err_msg=$(echo "$dbg_resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if echo "$err_msg" | grep -qiE 'not found|not available|does not exist|unknown method|disabled|unauthorized|forbidden'; then
      info "debug_getRawBlock: 未开放 ($err_msg)"
      debug_fail=$((debug_fail + 1))
    else
      ok "debug_getRawBlock: 方法存在 (执行报错: ${err_msg:-unknown})"
      debug_ok=$((debug_ok + 1))
    fi
  else
    info "debug_getRawBlock: 无响应/超时"
    debug_fail=$((debug_fail + 1))
  fi

  # txpool 也常与 debug 节点一起开放，额外探测
  dbg_resp=$(curl -sS --max-time "$CURL_TIMEOUT" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"txpool_status","params":[]}' \
    "$url" 2>/dev/null) || dbg_resp=""

  if echo "$dbg_resp" | grep -q '"result"'; then
    ok "txpool_status: 可用"
  elif echo "$dbg_resp" | grep -q '"error"'; then
    err_msg=$(echo "$dbg_resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    info "txpool_status: 未开放 (${err_msg:-error})"
  else
    info "txpool_status: 无响应"
  fi

  # 汇总 debug 期望
  if (( debug_ok > 0 )); then
    if [[ "$expect_debug" == "yes" ]]; then
      ok "Debug 模块: 已开启 (符合预期)"
    else
      warn "Debug 模块: 已开启 (该节点预期可能不开放 debug)"
    fi
  else
    if [[ "$expect_debug" == "yes" ]]; then
      bad "Debug 模块: 未开启 (预期应开放)"
    else
      ok "Debug 模块: 未开启 (符合预期)"
    fi
  fi
}

# 带超时执行（保留 stdin；优先 GNU timeout / gtimeout，否则 perl）
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

# 解析主机 DNS，便于判断内网/公网
resolve_host_ips() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' '
  elif command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' '
  else
    python3 -c "import socket; print(' '.join(sorted({i[4][0] for i in socket.getaddrinfo('$host', None, socket.AF_INET)})))" 2>/dev/null || true
  fi
}

is_private_ip() {
  local ip="$1"
  [[ "$ip" == 10.* || "$ip" == 192.168.* || "$ip" == 127.* ]] && return 0
  if [[ "$ip" =~ ^172\.([0-9]+)\. ]]; then
    local n="${BASH_REMATCH[1]}"
    (( n >= 16 && n <= 31 )) && return 0
  fi
  return 1
}

# 是否为本机/回环地址（本机检测场景，失败应提示检查本地服务）
is_local_host() {
  local host="$1"
  [[ "$host" == "127.0.0.1" || "$host" == "localhost" || "$host" == "::1" || "$host" == "0.0.0.0" ]]
}

# 检测 WebSocket（优先 websocat，其次 python）
check_ws_rpc() {
  local name="$1" url="$2"
  local result="" err="" chain_hex chain_id host ips ip private=0 local_target=0

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  [$name WebSocket]${NC}  $url"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  host=$(echo "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
  if is_local_host "$host"; then
    local_target=1
    info "目标为本机地址，跳过公网 DNS 判断"
  else
    ips=$(resolve_host_ips "$host")
    if [[ -n "$ips" ]]; then
      info "DNS: $host → $ips"
      for ip in $ips; do
        if is_private_ip "$ip"; then
          private=1
        fi
      done
      if (( private )); then
        info "DNS 指向内网 IP（若当前不在 VPN/内网，公网通常不可达）"
      fi
    fi
  fi

  if command -v websocat >/dev/null 2>&1; then
    # -n1 = --no-close + --one-message；不要再写 --one-message（会重复报错）
    result=$(printf '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}\n' \
      | run_with_timeout "$CURL_TIMEOUT" websocat -n1 --text "$url" 2>/tmp/rpc_ws_err.$$) || true
    err=$(tr '\n' ' ' </tmp/rpc_ws_err.$$ 2>/dev/null || true)
    rm -f /tmp/rpc_ws_err.$$
  elif command -v python3 >/dev/null 2>&1; then
    result=$(python3 - "$url" "$CURL_TIMEOUT" <<'PY' 2>/tmp/rpc_ws_err.$$
import sys, json, ssl, socket, base64, os, struct
from urllib.parse import urlparse

url = sys.argv[1]
timeout = float(sys.argv[2])

def try_websocket_client():
    import websocket
    ws = websocket.create_connection(url, timeout=timeout)
    ws.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}))
    print(ws.recv())
    ws.close()

def ws_mask(data: bytes) -> bytes:
    key = os.urandom(4)
    masked = bytes(b ^ key[i % 4] for i, b in enumerate(data))
    header = bytes([0x81, 0x80 | len(data)]) + key
    return header + masked

def try_stdlib():
    u = urlparse(url)
    host = u.hostname
    port = u.port or (443 if u.scheme == "wss" else 80)
    path = u.path or "/"
    if u.query:
        path += "?" + u.query
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=timeout) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as ssock:
            ssock.settimeout(timeout)
            key = base64.b64encode(os.urandom(16)).decode()
            req = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host}\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                f"Sec-WebSocket-Version: 13\r\n\r\n"
            )
            ssock.sendall(req.encode())
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = ssock.recv(4096)
                if not chunk:
                    break
                buf += chunk
            header, _, rest = buf.partition(b"\r\n\r\n")
            status = header.split(b"\r\n", 1)[0].decode(errors="replace")
            if "101" not in status:
                print(f"handshake_fail:{status}", file=sys.stderr)
                sys.exit(1)
            payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}).encode()
            ssock.sendall(ws_mask(payload))
            data = rest
            while len(data) < 2:
                data += ssock.recv(4096)
            ln = data[1] & 0x7F
            idx = 2
            if ln == 126:
                while len(data) < 4:
                    data += ssock.recv(4096)
                ln = struct.unpack("!H", data[2:4])[0]
                idx = 4
            elif ln == 127:
                while len(data) < 10:
                    data += ssock.recv(4096)
                ln = struct.unpack("!Q", data[2:10])[0]
                idx = 10
            while len(data) < idx + ln:
                data += ssock.recv(4096)
            print(data[idx:idx + ln].decode(errors="replace"))

try:
    try:
        try_websocket_client()
    except ImportError:
        try_stdlib()
except Exception as e:
    print(f"{type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(1)
PY
) || true
    err=$(tr '\n' ' ' </tmp/rpc_ws_err.$$ 2>/dev/null || true)
    rm -f /tmp/rpc_ws_err.$$
  else
    warn "未安装 websocat / python3，跳过 WebSocket 检测"
    return
  fi

  # 清理超时噪音
  err=$(echo "$err" | sed -E 's/.*Alarm clock[^ ]*[[:space:]]*//; s/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')

  if [[ -z "$result" ]]; then
    if (( local_target )); then
      bad "WebSocket 连通失败（请确认本机节点已启动且 ${WS_PORT} 已映射）${err:+: $err}"
    elif (( private )); then
      bad "WebSocket 连通失败（DNS 指向内网，公网不可达）"
    elif [[ "$err" == *timeout* ]]; then
      bad "WebSocket 连通超时 (${CURL_TIMEOUT}s)"
    else
      bad "WebSocket 连通失败${err:+: $err}"
    fi
    return
  fi

  chain_hex=$(echo "$result" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [[ -n "$chain_hex" ]]; then
    chain_id=$(hex2dec "$chain_hex")
    if (( chain_id == EXPECTED_CHAIN_ID )); then
      ok "WebSocket 正常, 链 ID = $chain_id  [$chain_hex]"
    else
      bad "WebSocket 可达, 但链 ID = $chain_id (期望 $EXPECTED_CHAIN_ID)  [$chain_hex]"
    fi
  elif echo "$result" | grep -q '"error"'; then
    warn "WebSocket 可达, 但返回 error: $result"
  else
    bad "WebSocket 响应异常: $result"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       BotChain 测试网本机 RPC 健康检测               ║${NC}"
echo -e "${BOLD}║       目标: ${RPC_HOST}:${HTTP_PORT} / WS:${WS_PORT}                      ║${NC}"
echo -e "${BOLD}║       期望链 ID: ${EXPECTED_CHAIN_ID}  |  出块等待: ${BLOCK_WAIT_SEC}s              ║${NC}"
echo -e "${BOLD}║       Debug 预期: ${EXPECT_DEBUG}  |  浏览器: scan.bohr.life       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

# 仅检测本机（或指定 host）上的 RPC / WS，不再请求公网域名
check_http_rpc "本机 HTTP RPC" "$HTTP_URL" "$EXPECT_DEBUG"
check_ws_rpc "本机 WebSocket" "$WS_URL"

# 汇总
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  检测汇总${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}通过: $PASS${NC}    ${RED}失败: $FAIL${NC}    ${YELLOW}警告: $WARN${NC}"
echo -e "  目标 HTTP: $HTTP_URL"
echo -e "  目标 WS:   $WS_URL"
echo ""

if (( FAIL > 0 )); then
  echo -e "${RED}结论: 存在失败项，请检查节点是否已启动、端口是否映射正确${NC}"
  exit 1
else
  echo -e "${GREEN}结论: 本机测试网 RPC 检测通过${NC}"
  exit 0
fi
