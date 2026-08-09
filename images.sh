#!/usr/bin/env bash
# 管理本项目用到的 Docker 镜像：列出 / 拉取 / 打包(save) / 加载(load)
# 离线包目录: <仓库>/images/
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="${IMAGES_DIR:-${ROOT_DIR}/images}"
HOST_ARCH="$(uname -m)"

usage() {
  cat <<EOF
用法: $(basename "$0") <命令> [选项]

命令:
  list              列出项目镜像及本地 / 离线包状态
  pull              从仓库拉取项目镜像
  save | pack       将本地镜像导出到 ${IMAGES_DIR}/
  load              从 ${IMAGES_DIR}/ 加载镜像到本机 Docker
  path              打印离线包目录路径

选项:
  --chain-only      仅链节点镜像（CHAIN_IMAGE）
  --blockscout-only 仅 Blockscout 相关镜像
  --both-chain      save/pull 时同时处理 mac + linux 两种 CHAIN_IMAGE（便于离线分发）
  -h, --help        帮助

说明:
  - 默认目录: ${IMAGES_DIR}
  - Apple Silicon 上部分 Blockscout 镜像需 linux/amd64，pull 时会自动加 --platform
  - Docker Desktop(containerd) 常把多架构镜像存成 index；直接 save 会因缺
    其它平台 digest 失败。本脚本会先解析目标平台单一清单再打包
  - 打包产物为 images/*.tar（已在 .gitignore）
EOF
}

SCOPE="all" # all | chain | blockscout
BOTH_CHAIN=0

parse_opts() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --chain-only) SCOPE="chain"; shift ;;
      --blockscout-only) SCOPE="blockscout"; shift ;;
      --both-chain) BOTH_CHAIN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
  done
}

source_env_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    # 去掉首尾引号
    val="${val%\"}"
    val="${val#\"}"
    val="${val%\'}"
    val="${val#\'}"
    export "${key}=${val}"
  done <"$f"
}

load_config() {
  source_env_file "${ROOT_DIR}/.env.example"
  source_env_file "${ROOT_DIR}/.env"
  source_env_file "${ROOT_DIR}/blockscout/.env.example"
  source_env_file "${ROOT_DIR}/blockscout/.env"
}

# 返回: 每行 "ref|platform"  platform 可为空或 linux/amd64
collect_images() {
  load_config

  local chain_mac="calmw/botchain-node-0809-mac:v1.0.0"
  local chain_linux="calmw/botchain-node-0809-linux:v1.0.0"
  local chain="${CHAIN_IMAGE:-}"

  if [[ "${SCOPE}" == "all" || "${SCOPE}" == "chain" ]]; then
    if [[ "${BOTH_CHAIN}" -eq 1 ]]; then
      echo "${chain_mac}|"
      echo "${chain_linux}|"
    elif [[ -n "${chain}" ]]; then
      echo "${chain}|"
    else
      if [[ "${HOST_ARCH}" == "arm64" || "${HOST_ARCH}" == "aarch64" ]]; then
        echo "${chain_mac}|"
      else
        echo "${chain_linux}|"
      fi
    fi
  fi

  if [[ "${SCOPE}" == "all" || "${SCOPE}" == "blockscout" ]]; then
    local bs_img="${BLOCKSCOUT_IMAGE:-ghcr.io/blockscout/blockscout@sha256:7659f168e4e2f6b73dd559ae5278fe96ba67bc2905ea01b57a814c68adf5a9dc}"
    local fe_img="${FRONTEND_IMAGE:-ghcr.io/blockscout/frontend@sha256:4b69f44148414b55c6b8550bc3270c63c9f99e923d54ef0b307e762af6bac90a}"
    local stats_tag="${STATS_DOCKER_TAG:-v2.17.0}"
    local vis_tag="${VISUALIZER_DOCKER_TAG:-v0.2.1}"
    local sig_tag="${SIG_PROVIDER_DOCKER_TAG:-v1.1.1}"
    local ver_tag="${SMART_CONTRACT_VERIFIER_DOCKER_TAG:-v1.10.6}"
    local uops_tag="${USER_OPS_INDEXER_DOCKER_TAG:-v1.4.3}"

    # Blockscout 若干镜像仅有 linux/amd64（compose 已钉 platform）
    echo "${bs_img}|linux/amd64"
    echo "${fe_img}|linux/amd64"
    echo "ghcr.io/blockscout/stats:${stats_tag}|linux/amd64"
    echo "ghcr.io/blockscout/visualizer:${vis_tag}|linux/amd64"
    echo "ghcr.io/blockscout/sig-provider:${sig_tag}|linux/amd64"
    echo "ghcr.io/blockscout/smart-contract-verifier:${ver_tag}|linux/amd64"
    echo "ghcr.io/blockscout/user-ops-indexer:${uops_tag}|linux/amd64"
    echo "postgres:17|"
    echo "redis:7.4-alpine|"
    echo "nginx:1.27.4-alpine|"
  fi
}

image_to_filename() {
  local ref="$1"
  # ghcr.io/foo/bar@sha256:abcd → ghcr.io_foo_bar_sha256_abcd.tar
  # repo:tag → repo_tag.tar （/ : @ 换成 _）
  local name
  name="$(echo "${ref}" | sed -e 's#/#_#g' -e 's/@/_/g' -e 's/:/_/g')"
  echo "${name}.tar"
}

image_local() {
  local ref="$1"
  docker image inspect "${ref}" >/dev/null 2>&1
}

# 去掉 :tag / @digest，得到仓库名（兼容 registry:port/name:tag）
image_repo() {
  local ref="$1"
  if [[ "${ref}" == *@* ]]; then
    echo "${ref%@*}"
    return
  fi
  local last="${ref##*/}"
  if [[ "${last}" == *:* ]]; then
    echo "${ref%:*}"
  else
    echo "${ref}"
  fi
}

# 是否为「未物化」的多架构 index（Size 极小 / 无 Architecture，直接 save 会 NotFound）
image_is_broken_index() {
  local ref="$1"
  local mt arch size
  mt="$(docker image inspect "${ref}" --format '{{.Descriptor.mediaType}}' 2>/dev/null || true)"
  arch="$(docker image inspect "${ref}" --format '{{.Architecture}}' 2>/dev/null || true)"
  size="$(docker image inspect "${ref}" --format '{{.Size}}' 2>/dev/null || echo 0)"
  [[ "${mt}" == *index* ]] || return 1
  [[ -z "${arch}" || "${size}" -lt 100000 ]]
}

image_local_arch() {
  docker image inspect "$1" --format '{{.Architecture}}' 2>/dev/null || true
}

# list 用：本地是 index 还是单一 image
image_kind() {
  local ref="$1"
  local mt
  mt="$(docker image inspect "${ref}" --format '{{.Descriptor.mediaType}}' 2>/dev/null || true)"
  if [[ "${mt}" == *index* ]]; then
    if image_is_broken_index "${ref}"; then
      echo "index!"
    else
      echo "index"
    fi
  else
    echo "image"
  fi
}

# 解析 ref 在指定平台上的单一 manifest digest，输出 name@sha256:...；失败则原样输出 ref
resolve_platform_ref() {
  local ref="$1"
  local platform="${2:-linux/amd64}"
  local os="${platform%%/*}"
  local arch="${platform##*/}"
  local digest repo raw

  raw="$(docker buildx imagetools inspect "${ref}" --raw 2>/dev/null || true)"
  [[ -n "${raw}" ]] || { echo "${ref}"; return 0; }

  digest="$(
    printf '%s' "${raw}" | python3 -c '
import json, sys
want_os, want_arch = sys.argv[1], sys.argv[2]
doc = json.load(sys.stdin)
if "manifests" not in doc:
    sys.exit(0)
for m in doc.get("manifests", []):
    p = m.get("platform") or {}
    if p.get("os") == want_os and p.get("architecture") == want_arch:
        print(m.get("digest", ""))
        break
' "${os}" "${arch}" 2>/dev/null || true
  )"

  if [[ -z "${digest}" ]]; then
    echo "${ref}"
    return 0
  fi
  repo="$(image_repo "${ref}")"
  echo "${repo}@${digest}"
}

pull_ref() {
  local ref="$1"
  local platform="${2:-}"
  if [[ -n "${platform}" ]]; then
    docker pull --platform "${platform}" "${ref}"
  else
    docker pull "${ref}"
  fi
}

# 是否需要按平台拆成单一清单再 save
needs_platform_resolve() {
  local ref="$1"
  local platform="${2:-}"
  local arch want_arch

  if image_is_broken_index "${ref}"; then
    return 0
  fi
  if [[ -n "${platform}" ]]; then
    want_arch="${platform##*/}"
    arch="$(image_local_arch "${ref}")"
    # 本地架构与目标不一致（例如要 amd64 但只有 arm64）
    if [[ -n "${arch}" && "${arch}" != "${want_arch}" ]]; then
      return 0
    fi
  fi
  return 1
}

# 确保本地是可 docker save 的单一平台镜像（必要时按平台 digest 重拉并回写 tag）
ensure_saveable_image() {
  local ref="$1"
  local platform="${2:-}"
  local plat="${platform:-}"
  local pref save_ref

  if ! image_local "${ref}"; then
    echo "==> 本地无镜像，先 pull: ${ref}${plat:+ (${plat})}"
    pull_ref "${ref}" "${plat}" || return 1
  fi

  if ! needs_platform_resolve "${ref}" "${plat}"; then
    return 0
  fi

  plat="${plat:-linux/amd64}"
  pref="$(resolve_platform_ref "${ref}" "${plat}")"
  if [[ "${pref}" == "${ref}" ]]; then
    echo "WARN: 无法解析 ${ref} 的 ${plat} digest，仍尝试 save" >&2
    return 0
  fi

  echo "==> 多架构 index → 拉取单一清单: ${pref}"
  pull_ref "${pref}" "${plat}" || return 1

  # tag 引用：打回原 tag；digest 引用：导出平台清单（cmd_save 写 .ref 记录原 ref）
  if [[ "${ref}" != *@sha256:* ]]; then
    docker tag "${pref}" "${ref}" || return 1
    export _IMAGES_SAVE_REF=""
  else
    export _IMAGES_SAVE_REF="${pref}"
  fi
}

cmd_list() {
  mkdir -p "${IMAGES_DIR}"
  printf '%-72s %-8s %-8s %-8s %s\n' "IMAGE" "LOCAL" "SAVED" "KIND" "PLATFORM"
  printf '%s\n' "------------------------------------------------------------------------------------------------------------------------"
  while IFS='|' read -r ref platform; do
    [[ -n "${ref}" ]] || continue
    local local_s="no" saved_s="no" kind="-"
    if image_local "${ref}"; then
      local_s="yes"
      kind="$(image_kind "${ref}")"
    fi
    local tar="${IMAGES_DIR}/$(image_to_filename "${ref}")"
    [[ -f "${tar}" ]] && saved_s="yes"
    printf '%-72s %-8s %-8s %-8s %s\n' "${ref}" "${local_s}" "${saved_s}" "${kind}" "${platform:-default}"
  done < <(collect_images | awk -F'|' '!seen[$1]++')
  echo ""
  echo "离线目录: ${IMAGES_DIR}"
  echo "提示: KIND=index! 表示本地 index 未物化，./images.sh save 会自动按平台拆清单"
}

cmd_pull() {
  local failed=0
  while IFS='|' read -r ref platform; do
    [[ -n "${ref}" ]] || continue
    echo "==> pull ${ref}${platform:+ (platform=${platform})}"
    if ! ensure_saveable_image "${ref}" "${platform}"; then
      failed=1
      continue
    fi
  done < <(collect_images | awk -F'|' '!seen[$1]++')
  [[ "${failed}" -eq 0 ]] || { echo "ERROR: 部分镜像拉取失败" >&2; exit 1; }
  echo "==> pull 完成"
}

cmd_save() {
  mkdir -p "${IMAGES_DIR}"
  local failed=0
  while IFS='|' read -r ref platform; do
    [[ -n "${ref}" ]] || continue
    local tar="${IMAGES_DIR}/$(image_to_filename "${ref}")"
    local save_ref="${ref}"
    _IMAGES_SAVE_REF=""
    if ! ensure_saveable_image "${ref}" "${platform}"; then
      failed=1
      continue
    fi
    # digest 且已拆成平台清单时，保存平台清单（并记录原 ref 便于 load 后对照）
    if [[ -n "${_IMAGES_SAVE_REF:-}" ]]; then
      save_ref="${_IMAGES_SAVE_REF}"
    fi
    echo "==> save ${ref} -> ${tar}"
    if [[ "${save_ref}" != "${ref}" ]]; then
      echo "    (实际导出 ${save_ref})"
    fi
    if docker save -o "${tar}" "${save_ref}"; then
      printf '%s\n' "${ref}" >"${tar}.ref"
      continue
    fi
    echo "==> save 失败，尝试按平台清单修复后重试 ..."
    local plat="${platform:-linux/amd64}"
    local pref
    pref="$(resolve_platform_ref "${ref}" "${plat}")"
    if [[ "${pref}" != "${ref}" ]] && pull_ref "${pref}" "${plat}"; then
      if [[ "${ref}" != *@sha256:* ]]; then
        docker tag "${pref}" "${ref}" || true
        save_ref="${ref}"
      else
        save_ref="${pref}"
      fi
      if docker save -o "${tar}" "${save_ref}"; then
        printf '%s\n' "${ref}" >"${tar}.ref"
        echo "==> 重试成功: ${tar}"
        continue
      fi
    fi
    rm -f "${tar}" "${tar}.ref"
    failed=1
  done < <(collect_images | awk -F'|' '!seen[$1]++')
  [[ "${failed}" -eq 0 ]] || { echo "ERROR: 部分镜像打包失败" >&2; exit 1; }
  echo "==> 已打包到 ${IMAGES_DIR}"
  ls -lh "${IMAGES_DIR}"/*.tar 2>/dev/null || true
}

cmd_load() {
  if [[ ! -d "${IMAGES_DIR}" ]]; then
    echo "ERROR: 目录不存在: ${IMAGES_DIR}" >&2
    exit 1
  fi
  local found=0 failed=0
  shopt -s nullglob
  local tars=("${IMAGES_DIR}"/*.tar "${IMAGES_DIR}"/*.tar.gz)
  shopt -u nullglob
  if [[ ${#tars[@]} -eq 0 ]]; then
    echo "ERROR: ${IMAGES_DIR} 下没有 .tar / .tar.gz" >&2
    exit 1
  fi
  for tar in "${tars[@]}"; do
    found=1
    echo "==> load ${tar}"
    if [[ "${tar}" == *.tar.gz ]]; then
      gunzip -c "${tar}" | docker load || failed=1
    else
      docker load -i "${tar}" || failed=1
    fi
  done
  [[ "${found}" -eq 1 ]] || { echo "ERROR: 未找到可加载文件" >&2; exit 1; }
  [[ "${failed}" -eq 0 ]] || { echo "ERROR: 部分镜像加载失败" >&2; exit 1; }
  echo "==> load 完成"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi
  local cmd="$1"
  shift
  parse_opts "$@"

  case "${cmd}" in
    list) cmd_list ;;
    pull) cmd_pull ;;
    save|pack) cmd_save ;;
    load) cmd_load ;;
    path) echo "${IMAGES_DIR}" ;;
    -h|--help|help) usage ;;
    *) echo "未知命令: ${cmd}" >&2; usage; exit 1 ;;
  esac
}

main "$@"
