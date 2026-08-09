#!/usr/bin/env bash
# 启动 / 重启 Blockscout 浏览器（需链 RPC 已可用，默认连 archive_node）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

启动（或重启）Blockscout。会同步根目录 .env 的 PUBLIC_HOST 到 blockscout/.env。

选项:
  -h, --help   帮助

等价于: ./start.sh --blockscout-only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

exec "${ROOT_DIR}/start.sh" --blockscout-only
