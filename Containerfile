# Slim runtime containing the pre-built ImageBuilder tarball.
# The tarball is built on the CI runner and copied into the build context
# before this Containerfile is evaluated.
FROM ubuntu:24.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential libncurses-dev \
    libssl-dev zlib1g-dev gawk git gettext unzip \
    file wget python3 python3-setuptools rsync zstd && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true && \
    groupadd -g 1000 buildbot && \
    useradd -u 1000 -g 1000 -m -d /builder -s /bin/bash -c "OpenWrt buildbot" buildbot

COPY *imagebuilder*.tar.* /tmp/
RUN mkdir -p /builder && \
    tar -xf /tmp/*imagebuilder*.tar.* -C /builder --strip-components=1 && \
    rm /tmp/*imagebuilder*.tar.* && \
    # This custom build uses openssl instead of mbedtls — patch all default references to match
    sed -i 's/apk-mbedtls/apk-openssl/g' /builder/include/default-packages.mk && \
    sed -i 's/libustream-mbedtls/libustream-openssl/g' /builder/include/target.mk && \
    sed -i 's/wpad-basic-mbedtls/wpad-openssl/g' /builder/target/linux/mediatek/filogic/target.mk && \
    sed -i \
      -e 's/CONFIG_DEFAULT_libustream-mbedtls=y/CONFIG_DEFAULT_libustream-openssl=y/' \
      -e 's/CONFIG_DEFAULT_wpad-basic-mbedtls=y/CONFIG_DEFAULT_wpad-openssl=y/' \
      /builder/.config

# Bake pesa's manifest into DEFAULT_PACKAGES so `make image` with no
# PACKAGES= argument produces pesa-parity firmware (LuCI + all kmods + the
# full default set). Without this, SNAPSHOT ImageBuilder ships near-bare
# rootfs and clients must enumerate every package explicitly. The CI's
# containerize job generates this file from the matching release's .manifest,
# so it is in lockstep with the config.buildinfo and package repo we ship.
COPY firmware-packages.txt /tmp/firmware-packages.txt
RUN if [ -s /tmp/firmware-packages.txt ]; then \
      PKGS=$(tr '\n' ' ' < /tmp/firmware-packages.txt); \
      printf '\n# --- pesa manifest baked in at container build time ---\nDEFAULT_PACKAGES += %s\n' "$PKGS" \
        >> /builder/include/default-packages.mk; \
      echo "Baked $(wc -l < /tmp/firmware-packages.txt) packages into DEFAULT_PACKAGES"; \
    else \
      echo "WARNING: firmware-packages.txt is empty — skipping DEFAULT_PACKAGES injection"; \
    fi && \
    rm -f /tmp/firmware-packages.txt && \
    chown -R buildbot:buildbot /builder

# Ship /etc/apk/repositories.d/distfeeds.list into the firmware as a
# rootfs overlay via /builder/files/. IB's `make image` applies files/
# on top of the installed rootfs (same mechanism the workflow uses for
# the APK signing key), so our list overrides whatever OpenWrt would
# otherwise auto-compose from CONFIG_VERSION_REPO.
#
# Layout: our mirror first (primary), OpenWrt snapshots as fallback so
# apk can resolve packages we don't mirror (bash, nano, git, ...).
ARG REPO_VERSION_URL=""
RUN if [ -n "${REPO_VERSION_URL}" ]; then \
      set -eu; \
      ARCH="aarch64_cortex-a53"; \
      TARGET="mediatek/filogic"; \
      DISTFEEDS="/builder/files/etc/apk/repositories.d/distfeeds.list"; \
      mkdir -p "$(dirname "${DISTFEEDS}")"; \
      { \
        echo "${REPO_VERSION_URL}/targets/${TARGET}/packages/packages.adb"; \
        for feed in base luci packages routing; do \
          echo "${REPO_VERSION_URL}/packages/${ARCH}/${feed}/packages.adb"; \
        done; \
        for feed in base luci packages routing telephony video; do \
          echo "https://downloads.openwrt.org/snapshots/packages/${ARCH}/${feed}/packages.adb"; \
        done; \
      } > "${DISTFEEDS}"; \
      chown -R buildbot:buildbot /builder/files; \
      echo "--- wrote ${DISTFEEDS} ---"; cat "${DISTFEEDS}"; \
    fi

# ASU runs `setup.sh` for snapshot builds. Upstream imagebuilders ship one
# that updates feeds; ours are fully pre-built so a no-op suffices.
RUN printf '#!/bin/sh\nexit 0\n' > /builder/setup.sh && chmod +x /builder/setup.sh

WORKDIR /builder
USER buildbot
