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
      /builder/.config && \
    chown -R buildbot:buildbot /builder

# Patch APK repositories to point to our signed package feed so firmware
# built by ASU uses our repo instead of pesa1234's for post-flash installs.
ARG PACKAGES_BASE_URL=""
RUN if [ -n "${PACKAGES_BASE_URL}" ]; then \
      REPOS_FILE=$(find /builder -maxdepth 1 -name "repositories.conf" -o -name "repositories" 2>/dev/null | head -1); \
      if [ -n "${REPOS_FILE}" ]; then \
        echo "Patching ${REPOS_FILE} with ${PACKAGES_BASE_URL}"; \
        cat "${REPOS_FILE}"; \
        echo "---"; \
        sed -i "s|https://raw.githubusercontent.com/pesa1234/MT6000_cust_build[^ ]*|${PACKAGES_BASE_URL}|g" \
          "${REPOS_FILE}" && \
        cat "${REPOS_FILE}"; \
      else \
        echo "WARNING: No repositories config found in /builder — listing candidates:"; \
        find /builder -maxdepth 3 -name "repositories*" -o -name "distfeeds*" 2>/dev/null || true; \
      fi; \
    fi

# ASU runs `setup.sh` for snapshot builds. Upstream imagebuilders ship one
# that updates feeds; ours are fully pre-built so a no-op suffices.
RUN printf '#!/bin/sh\nexit 0\n' > /builder/setup.sh && chmod +x /builder/setup.sh

WORKDIR /builder
USER buildbot
