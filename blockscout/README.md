# Blockscout（local-chain）

为本仓库本地测试链（Chain ID / Network ID = `100000`）提供区块浏览器。

- 编排基于 [blockscout/blockscout](https://github.com/blockscout/blockscout) **`v11.2.5`** 的 `docker-compose`（`geth` 变体）
- 使用 GHCR 预构建镜像（`ghcr.io/blockscout/*`，**已钉固定版本**，见 `.env.example`）
- 建议对接 **archive 节点** RPC，并开启 `debug` API，以便内部交易 / trace 索引
- Docker：业务网 `bot-local-chain-bs_net`（`172.30.89.0/24`），链网 external `bot-local-chain_net`；容器名带 `lcbs-` 前缀

## 前置条件

- Docker 20.10+、Docker Compose v2
- 本地链已出块，且 RPC 可从 Docker 访问宿主机：
  - macOS / Docker Desktop：`host.docker.internal`
  - Linux：节点需监听 `0.0.0.0`，compose 已配置 `host-gateway`

**容器内索引 RPC**（backend → 链，走 docker 网络）：

| 用途 | 默认 |
| --- | --- |
| HTTP / Trace | `http://archive_node:8545/` |
| WS | `ws://archive_node:8546/` |

**浏览器 / 外出访问**：在仓库根目录 `.env` 设置 `PUBLIC_HOST=<tailscale主机名>`，执行 `../start.sh` 会同步到本目录 `.env` 的 `NEXT_PUBLIC_*`。然后用 `http://<PUBLIC_HOST>/` 打开；钱包 RPC 用 `http://<PUBLIC_HOST>:8575`。

Archive 启动时建议增加 debug：

```bash
export HTTP_API="eth,net,web3,txpool,debug,trace"
export WS_API="eth,net,web3,txpool,debug"
```

若暂时没有 debug/trace，在 `.env` 设置：

```bash
INDEXER_DISABLE_INTERNAL_TRANSACTIONS_FETCHER=true
```

## 快速启动

```bash
cd blockscout
cp -n .env .env.local 2>/dev/null || true   # 可选：本地覆盖
./start.sh
```

浏览器打开：

| 地址 | 说明 |
| --- | --- |
| http://localhost/ | 浏览器 UI |
| http://localhost/api | Backend API |
| http://localhost:8080 | Stats |
| http://localhost:8081 | Visualizer（经 proxy） |

停止：

```bash
./stop.sh
# 同时删除数据卷（慎用）:
# docker compose --env-file .env down -v
```

查看日志：

```bash
docker compose --env-file .env logs -f backend
```

## 目录结构

```
blockscout/
├── docker-compose.yml    # 本地链编排（含 verifier）
├── .env                  # 镜像 tag、RPC、链参数
├── start.sh / stop.sh
├── envs/                 # Blockscout 官方环境变量模板（已改本地链默认值）
├── services/             # 各服务 compose 片段
└── proxy/                # nginx 模板
```

## 主要配置

编辑 `.env`：

| 变量 | 说明 |
| --- | --- |
| `CHAIN_ID` | 默认 `100000` |
| `RPC_HTTP_URL` / `RPC_TRACE_URL` / `RPC_WS_URL` | 指向本机节点 |
| `BLOCKSCOUT_IMAGE` / `FRONTEND_IMAGE` | backend/frontend 完整镜像引用（含 digest） |
| `STATS_DOCKER_TAG` 等 | 微服务 `vX.Y.Z` 标签 |
| `NETWORK_NAME` / `COIN` / `COIN_NAME` | 前端展示名与代币符号 |

更细的后端变量见 `envs/common-blockscout.env`，说明见 [Blockscout ENV docs](https://docs.blockscout.com/setup/env-variables)。

## 组件

| 服务 | 固定版本 |
| --- | --- |
| backend / nft_media_handler | digest（OCI label `v9.0.2`） |
| frontend | digest（OCI label `v2.3.5`） |
| stats | `v2.17.0` |
| visualizer | `v0.2.1` |
| sig-provider | `v1.1.1` |
| smart-contract-verifier | `v1.10.6` |
| user-ops-indexer | `v1.4.3` |
| db / stats-db | `postgres:17` |
| redis | `redis:7.4-alpine` |
| proxy | `nginx:1.27.4-alpine` |

## 注意

- 宿主机 **80 / 8080 / 8081** 端口需空闲
- **Apple Silicon (arm64)**：`visualizer` / `sig-provider` 等仅有 `linux/amd64` 镜像。compose 已设 `platform: linux/amd64`（走 Rosetta/QEMU）。手动 pull 需加平台，例如：
  ```bash
  docker pull --platform linux/amd64 ghcr.io/blockscout/visualizer:v0.2.1
  ```
- 修改 Chain ID 或换创世后，应清空 DB 卷再索引：`docker compose down -v` 后重新 `./start.sh`
- 仅用于本地/测试，勿直接暴露到公网
