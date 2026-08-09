#!/usr/bin/env bash
set -e

# env 检查
if [ -z "$PASSWORD" ] || [ -z "$KEYS_DIR" ] || [ -z "$BIN_DIR" ] || [ -z "$BASE_DIR" ]; then
  echo "ERROR: 环境变量 PASSWORD / KEYS_DIR / BIN_DIR / BASE_DIR 必须设置"
  exit 1
fi

echo "开始首次初始化密钥..."

# 创建目录
mkdir -p "$KEYS_DIR"

# 写入密码文件
echo "$PASSWORD" > "$KEYS_DIR/password.txt"
chmod 600 "$KEYS_DIR/password.txt"

echo ">>> 生成 BLS 密钥"
mkdir -p "$KEYS_DIR/bls"
BLS_SCRIPT="${BASE_DIR}/bls_expect.sh"
if [ ! -f "${BLS_SCRIPT}" ]; then
  BLS_SCRIPT="${BIN_DIR}/scripts/bls_expect.sh"
fi
if [ ! -f "${BLS_SCRIPT}" ]; then
  echo "ERROR: 找不到 bls_expect.sh（${BASE_DIR} 或 ${BIN_DIR}/scripts）" >&2
  exit 1
fi
bash "${BLS_SCRIPT}" "$PASSWORD" "$KEYS_DIR/bls" "$BIN_DIR"

echo ">>> 生成验证者密钥"
mkdir -p "$KEYS_DIR/validator"
echo "$PASSWORD" | $BIN_DIR/geth account new \
  --datadir "$KEYS_DIR/validator" \
  --password "$KEYS_DIR/password.txt"
validator_keystore=$(ls "$KEYS_DIR/validator/keystore" | head -n1)
validator_address="0x${validator_keystore##*--}"
echo "Validator Address = $validator_address"

echo ">>> 生成节点 P2P 密钥"
node_key_file="${KEYS_DIR}/nodekey"
enode_file="${KEYS_DIR}/enode.txt"

$BIN_DIR/bootnode -genkey "${node_key_file}"

echo "=> Extracting validator pubkey..."
pubkey=$($BIN_DIR/bootnode -nodekey "${node_key_file}" -writeaddress)
echo "enode://${pubkey}@127.0.0.1:30303" > "${enode_file}"
echo "=> Enode saved to ${enode_file}"

echo "validator address: $validator_address"
echo "nodekey: $node_key_file"

echo ""
echo "密钥初始化完成！(仅首次运行)"
