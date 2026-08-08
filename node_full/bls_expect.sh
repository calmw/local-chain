#!/usr/bin/env bash
set -e

PASSWORD="$1"
KEYS_DIR="$2"
BIN_DIR="$3"

if [ -z "$PASSWORD" ] || [ -z "$KEYS_DIR" ] || [ -z "$BIN_DIR" ]; then
  echo "用法: $0 <密码> <密钥目录> <二进制目录>"
  exit 1
fi

mkdir -p "$KEYS_DIR"

# 方法1: 将密码写入临时文件
PASSWORD_FILE=$(mktemp)
echo "$PASSWORD" > "$PASSWORD_FILE"

# 方法2: 使用标准输入（如果 geth 支持）
echo -e "$PASSWORD\n$PASSWORD" | "$BIN_DIR/geth" bls account new --datadir "$KEYS_DIR" 2>&1

# 清理
rm -f "$PASSWORD_FILE"

# 检查是否成功
if [ $? -eq 0 ]; then
  echo "BLS账户创建成功"
else
  echo "BLS账户创建失败"
  exit 1
fi