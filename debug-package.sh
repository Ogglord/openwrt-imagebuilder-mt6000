#!/usr/bin/env bash
set -euo pipefail

# Debug a specific OpenWrt package's download + compile with verbose output.
# Uses a separate Containerfile that stops at defconfig, leveraging layer cache
# from previous build attempts to avoid re-cloning/re-configuring.
#
# Usage: ./debug-package.sh [package-path] [branch]
# Example: ./debug-package.sh package/firmware/linux-firmware

PACKAGE="${1:-package/firmware/linux-firmware}"
DEFAULT_BRANCH="next-r4.8.0.rss.mtk-test6.18"
BRANCH="${2:-$DEFAULT_BRANCH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/debug-$(basename "${PACKAGE}")-$(date +%Y%m%d-%H%M%S).log"

echo "=== Debug build ==="
echo "Package: ${PACKAGE}"
echo "Branch:  ${BRANCH}"
echo "Log:     ${LOG_FILE}"
echo ""

# Build a debug image that stops just after defconfig (no full make).
# All layers up to defconfig will be reused from cache.
CONTAINERFILE=$(cat <<EOF
FROM debian:bookworm AS debug-env

RUN apt-get update && apt-get install -y \\
    build-essential clang flex bison g++ gawk gcc-multilib \\
    g++-multilib gettext git libncurses-dev libssl-dev \\
    python3-distutils python3-setuptools rsync swig unzip \\
    zlib1g-dev file wget curl python3-dev \\
    libelf-dev quilt zip zstd && \\
    apt-get clean && rm -rf /var/lib/apt/lists/*

ARG OPENWRT_BRANCH=main
RUN git clone --depth 1 -b "\${OPENWRT_BRANCH}" \\
    https://github.com/pesa1234/openwrt.git /openwrt

WORKDIR /openwrt

RUN echo "src-git luci-sso https://github.com/Ogglord/luci-sso-feed.git" >> feeds.conf && \
    ./scripts/feeds update -a && ./scripts/feeds install -a

RUN if echo "\${OPENWRT_BRANCH}" | grep -q "test6.18"; then \\
      CONFIG_URL="https://raw.githubusercontent.com/pesa1234/MT6000_cust_build/refs/heads/main/config_file/test6.18/.config"; \\
    else \\
      CONFIG_URL="https://raw.githubusercontent.com/pesa1234/MT6000_cust_build/refs/heads/main/config_file/.config"; \\
    fi && \\
    curl -fsSL "\${CONFIG_URL}" -o /openwrt/.config && \\
    echo "CONFIG_IB=y" >> /openwrt/.config && \\
    echo "CONFIG_IB_STANDALONE=y" >> /openwrt/.config

ENV FORCE_UNSAFE_CONFIGURE=1
ENV TAR_OPTIONS=--no-same-owner
ENV LC_ALL=C

RUN make defconfig
EOF
)

echo "Building debug environment (uses cache if available)..."
IMAGE_ID=$(echo "${CONTAINERFILE}" | podman build \
  --build-arg "OPENWRT_BRANCH=${BRANCH}" \
  --file - \
  --quiet \
  "${SCRIPT_DIR}")

echo "Image: ${IMAGE_ID}"
echo ""
echo "=== Running download + compile for ${PACKAGE} ==="
echo ""

podman run --rm \
  --network=host \
  -e FORCE_UNSAFE_CONFIGURE=1 \
  -e TAR_OPTIONS=--no-same-owner \
  -e LC_ALL=C \
  "${IMAGE_ID}" \
  bash -c "cd /openwrt && make ${PACKAGE}/download V=s -j1 && make ${PACKAGE}/compile V=s -j1" \
  2>&1 | tee "${LOG_FILE}"

EXIT_CODE=${PIPESTATUS[0]}

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  echo "=== Success ==="
else
  echo "=== Failed (exit code: ${EXIT_CODE}) ==="
  echo "Full log: ${LOG_FILE}"
fi

exit $EXIT_CODE
