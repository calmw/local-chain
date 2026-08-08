#!/usr/bin/env bash
# Stop Blockscout stack for local-chain
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

docker compose --env-file .env down "$@"
echo "==> Blockscout stopped"
