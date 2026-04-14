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

WORKDIR /builder
USER buildbot
