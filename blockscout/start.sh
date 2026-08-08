#!/usr/bin/env bash
# Start Blockscout for local-chain (prebuilt images, compose @ blockscout v11.2.5)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: missing ${ROOT_DIR}/.env" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a
source .env
set +a

echo "==> Blockscout (local-chain)"
echo "    CHAIN_ID=${CHAIN_ID:-100000}"
echo "    RPC HTTP=${RPC_HTTP_URL:-http://host.docker.internal:8545/}"
echo "    RPC TRACE=${RPC_TRACE_URL:-${RPC_HTTP_URL:-http://host.docker.internal:8545/}}"
echo "    RPC WS=${RPC_WS_URL:-ws://host.docker.internal:8546/}"
echo "    UI  http://localhost/"
echo ""

# Ensure volume dirs exist (paths relative to services/*.yml)
mkdir -p services/logs services/dets services/blockscout-db-data services/stats-db-data

docker compose --env-file .env up -d --pull missing "$@"

echo ""
echo "==> Started. Explorer: http://localhost/"
echo "    API via proxy:    http://localhost/api"
echo "    Stats:            http://localhost:8080"
echo "    Logs: docker compose -f ${ROOT_DIR}/docker-compose.yml logs -f backend"
