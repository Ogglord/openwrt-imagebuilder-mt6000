#!/usr/bin/env bash
set -euo pipefail

REGISTRY="localhost"
IMAGE_NAME="openwrt-imagebuilder"
DEFAULT_BRANCH="next-r4.8.0.rss.mtk-test6.18"

BRANCH="${1:-$DEFAULT_BRANCH}"
TAG="mediatek-filogic-${BRANCH}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

echo "=== Building ImageBuilder container ==="
echo "Branch: ${BRANCH}"
echo "Image:  ${FULL_IMAGE}"
echo ""

podman build \
  --build-arg "OPENWRT_BRANCH=${BRANCH}" \
  -t "${FULL_IMAGE}" \
  "$(dirname "$0")"

echo ""
echo "=== Build complete ==="
echo "Image: ${FULL_IMAGE}"
echo ""
echo "Verify with:"
echo "  podman run --rm ${FULL_IMAGE} make -C /builder info"
