# local-chain

本地 / 家庭机测试链：Parlia（BSC 风格）共识，四节点 + Blockscout，支持局域网与 Tailscale 远程访问。

| 项 | 值 |
| --- | --- |
| Chain ID / Network ID | `100000` |
| 共识 | Parlia（出块约 3s，epoch 200） |
| Gas Price | `20 Gwei`（`20000000000` Wei） |
| 状态方案 | `hash` |
| 浏览器 | Blockscout（compose 对齐 v11.2.5） |

架构细节见 [`docs/项目架构.md`](docs/项目架构.md)。

---

## 组件一览

| 组件 | 容器名 | 宿主机端口 | 作用 |
| --- | --- | --- | --- |
| 验证者 1 | `validator_1` | HTTP `8545` / WS `8546` / P2P `30303` | 首个出块与投票 |
| 验证者 2 | `validator_2` | `8555` / `8556` / `30304` | 第二验证者 |
| 全节点 | `full_node` | `8565` / `8566` / `30305` | 业务 RPC（`gcmode=full`） |
| 归档节点 | `archive_node` | `8575` / `8576` / `30306` | 历史状态 / Blockscout / debug |
| Blockscout | `proxy` 等 | `80` / `8080` / `8081` | 区块浏览器 |

Docker 网络：`local-chain_net`（Blockscout backend 直连 `archive_node:8545`）。

---

## 快速开始

```bash
# 1. 环境
cp -n .env.example .env
# 编辑 .env：PASSWORD、CHAIN_IMAGE、PUBLIC_HOST（外出访问必填 Tailscale 主机名）

# 2. 启停
./start.sh                 # 重启 4 节点 + Blockscout
./stop.sh                  # 全部停止
./start.sh --nodes-only
./start.sh --blockscout-only
```

首次验证者启动后，需向日志中的 `VALIDATOR_ADDR` 转入 ≥ **2005** 原生币，脚本才会完成 StakeHub 注册并持续出块。

### 自检

```bash
# chainId 应为 0x186a0 (100000)
curl -s -X POST http://127.0.0.1:8575 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'

./rpc_test/rpc_test_testnet.sh 127.0.0.1 8575 8576
```

浏览器：本机 `http://127.0.0.1/`；外出见下文 Tailscale。

---

## Tailscale / 外部访问

1. 部署机执行 `tailscale status`，记下 MagicDNS 或 `100.x` 地址  
2. 根目录 `.env` 设置：
   ```bash
   PUBLIC_HOST=homeserver.tail-xxxx.ts.net   # 不要带 http://
   BIND_ADDR=0.0.0.0
   ```
3. `./start.sh`（会把 `PUBLIC_HOST` 同步到 Blockscout 前端 `NEXT_PUBLIC_*`）

| 用途 | URL |
| --- | --- |
| Blockscout | `http://<PUBLIC_HOST>/` |
| Archive RPC（推荐） | `http://<PUBLIC_HOST>:8575` |
| Full RPC | `http://<PUBLIC_HOST>:8565` |

MetaMask：Chain ID `100000`，RPC `http://<PUBLIC_HOST>:8575`，符号可按需填 `LC`。

> 浏览器端不能写死 `localhost`，否则会打到你自己电脑。容器内索引仍走 `archive_node`，与 `PUBLIC_HOST` 无关。

---

## 目录与脚本

```
local-chain/
├── README.md / docs/项目架构.md
├── .env.example / docker-compose.yaml
├── start.sh / stop.sh
├── reset_archive.sh / reset_full.sh / reset_validator.sh
├── scripts/reset_lib.sh
├── rpc_test/rpc_test_testnet.sh
├── blockscout/                 # 浏览器（见 blockscout/README.md）
├── node_validator_1|2/         # 验证者
├── node_full/                  # 全节点
└── node_archive/               # 归档节点
```

每个节点目录：

| 路径 | 说明 |
| --- | --- |
| `config-src/genesis.json` | 创世（`chainId: 100000`） |
| `config-src/config.toml` | geth（`NetworkId = 100000`） |
| `app/node` / `app/keys` | 运行时数据 / 密钥（gitignore） |
| 主启动脚本 | 见下表 |

| 目录 | 主启动脚本 | `GC_MODE` |
| --- | --- | --- |
| `node_validator_*` | `node_validator_start.sh` | `full` |
| `node_full` | `node_full_start.sh` | `full` |
| `node_archive` | `node_archive_start.sh` | `archive` |

---

## 常用运维

```bash
# 清库（默认清仓库内 node_*/app/...；-y 跳过确认；-n dry-run）
./reset_archive.sh -y
./reset_full.sh -y
./reset_validator.sh -y              # 保留密钥
./reset_validator.sh -y --wipe-keys  # 连密钥一起清

# 改 Chain ID 后必须清数据并重 init；Blockscout 需：
#   cd blockscout && docker compose --env-file .env down -v
```

关键 `.env` 变量：

| 变量 | 说明 |
| --- | --- |
| `CHAIN_IMAGE` | 节点镜像 |
| `PASSWORD` | 验证者密钥密码 |
| `MINER_GAS_PRICE` | 出块 gas price（默认 20 Gwei） |
| `PUBLIC_HOST` | 对外主机名（Tailscale / 局域网） |
| `BIND_ADDR` | 端口绑定（默认 `0.0.0.0`） |
| `BOOTNODES` | 由 `start.sh` 自动写入 |

---

## 安全

- 仅用于测试；验证者带解锁私钥，勿对公网裸奔
- Tailscale 相对安全，仍建议仅信任设备接入
- `pprof` 默认本机；生产请收紧 `HTTP_VHOSTS` / `WS_ORIGINS` / API 模块

---

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/项目架构.md](docs/项目架构.md) | 拓扑、数据流、Compose、启动链路、挂载与网络 |
| [blockscout/README.md](blockscout/README.md) | 浏览器单独启停与 ENV |

---

## 常见问题

**验证者一直「等待充值」？**  
向日志中的 `VALIDATOR_ADDR` 转 ≥ 2005 原生币，并确认 `RPC_URL` 可达。

**外出打开 Blockscout 白屏 / API 打到 localhost？**  
设置 `PUBLIC_HOST` 后重新 `./start.sh`（或 `--blockscout-only`）。

**改 chainId 后节点对不上？**  
四节点 genesis / NetworkId / rpc_test / Blockscout 一并改，并清空 `app/node`（及按需密钥）后重启。

**full 与 archive？**  
都同步全量区块；archive 保留历史状态，供 Blockscout / 历史 `eth_call` / debug。
