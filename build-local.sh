#!/usr/bin/env bash
set -euo pipefail

REGISTRY="localhost"
IMAGE_NAME="openwrt-imagebuilder"
DEFAULT_BRANCH="next-r4.8.0.rss.mtk-test6.18"

BRANCH="${1:-$DEFAULT_BRANCH}"
TAG="mediatek-filogic-${BRANCH}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/build-${BRANCH}-$(date +%Y%m%d-%H%M%S).log"

echo "=== Building ImageBuilder container ==="
echo "Branch:  ${BRANCH}"
echo "Image:   ${FULL_IMAGE}"
echo "Log:     ${LOG_FILE}"
echo ""

# Build with output to both terminal and log file
podman build \
  --build-arg "OPENWRT_BRANCH=${BRANCH}" \
  -t "${FULL_IMAGE}" \
  "${SCRIPT_DIR}" 2>&1 | tee "${LOG_FILE}"

EXIT_CODE=${PIPESTATUS[0]}

if [[ $EXIT_CODE -eq 0 ]]; then
  echo "" | tee -a "${LOG_FILE}"
  echo "=== Build complete ===" | tee -a "${LOG_FILE}"
  echo "Image: ${FULL_IMAGE}" | tee -a "${LOG_FILE}"
  echo "" | tee -a "${LOG_FILE}"
  echo "Verify with:" | tee -a "${LOG_FILE}"
  echo "  podman run --rm ${FULL_IMAGE} make -C /builder info" | tee -a "${LOG_FILE}"
else
  echo "" | tee -a "${LOG_FILE}"
  echo "=== Build FAILED (exit code: ${EXIT_CODE}) ===" | tee -a "${LOG_FILE}"
  echo "Full log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
fi

exit $EXIT_CODE
