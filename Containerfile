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
    # Refuse to run against an IB tarball that still has pesa's RELEASE_DIR
    # segment in its distfeeds template — step 1 of our CI is supposed to strip
    # it from include/feeds.mk before make world so $(TOPDIR)/repositories (also
    # baked at step 1) gets the clean URL. This check catches tarballs built
    # without that patch.
    if grep -q '$(DATE)_$(VERSION_CODE)_$(BRANCH)/targets' /builder/include/feeds.mk; then \
      echo "ERROR: IB tarball still has pesa RELEASE_DIR template in include/feeds.mk — rebuild with build-imagebuilder.yml's feeds.mk sed in place" >&2; \
      exit 1; \
    fi

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

# ASU runs `setup.sh` for snapshot builds. Upstream imagebuilders ship one
# that updates feeds; ours are fully pre-built so a no-op suffices.
RUN printf '#!/bin/sh\nexit 0\n' > /builder/setup.sh && chmod +x /builder/setup.sh

WORKDIR /builder
USER buildbot
