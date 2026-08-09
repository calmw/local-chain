#!/usr/bin/env bash
# 停止 Blockscout 浏览器（不影响四个链节点）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

只停止 Blockscout 相关容器，不停止链节点。

选项:
  -h, --help   帮助

等价于: ./stop_node.sh --blockscout-only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

exec "${ROOT_DIR}/stop_node.sh" --blockscout-only
