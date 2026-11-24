#!/usr/bin/env bash
# 本地构建（与 GitHub Actions 相同的参数与 tag），用于在有 docker 的宿主上调试。
# 用法：./scripts/build-local.sh [额外 tag...]
# 环境变量：NODE_IMAGE 可换基座（如 docker.io 被限流时用已有镜像兜底：
#   NODE_IMAGE=ghcr.io/xylz0928/dsh-docker:1.0.0-dsh0.2.2-rc.5 ./scripts/build-local.sh）
set -euo pipefail
cd "$(dirname "$0")/.."

PACK="$(tr -d '[:space:]' < VERSION)"
DSHV="$(tr -d '[:space:]' < dsh-version)"
REV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
TAG="ghcr.io/xylz0928/dsh-docker:${PACK}-dsh${DSHV}"

EXTRA=()
[[ -n "${NODE_IMAGE:-}" ]] && EXTRA+=(--build-arg "NODE_IMAGE=${NODE_IMAGE}")

docker build \
  "${EXTRA[@]+"${EXTRA[@]}"}" \
  --build-arg "DSH_VERSION=${DSHV}" \
  --build-arg "DSH_IMAGE_VERSION=${PACK}" \
  --build-arg "DSH_GIT_REV=${REV}" \
  -t "$TAG" \
  -t "ghcr.io/xylz0928/dsh-docker:latest" \
  "$@" \
  .
echo "built: $TAG (pack=${PACK} dsh=${DSHV} rev=${REV})"
