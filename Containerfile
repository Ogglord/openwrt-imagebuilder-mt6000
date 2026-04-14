# Stage 1: Build the ImageBuilder from pesa1234/openwrt source
FROM debian:bookworm AS builder

RUN apt-get update && apt-get install -y \
    build-essential clang flex bison g++ gawk gcc-multilib \
    g++-multilib gettext git libncurses-dev libssl-dev \
    python3-distutils python3-setuptools rsync swig unzip \
    zlib1g-dev file wget curl python3-dev \
    libelf-dev quilt zip zstd && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ARG OPENWRT_BRANCH=main
RUN git clone --depth 1 -b "${OPENWRT_BRANCH}" \
    https://github.com/pesa1234/openwrt.git /openwrt

WORKDIR /openwrt

RUN ./scripts/feeds update -a && ./scripts/feeds install -a && ./scripts/feeds install -a

# Download pesa's recommended .config for this branch.
# Branches containing "test6.18" use config_file/test6.18/.config,
# all others use config_file/.config.
RUN if echo "${OPENWRT_BRANCH}" | grep -q "test6.18"; then \
      CONFIG_URL="https://raw.githubusercontent.com/pesa1234/MT6000_cust_build/refs/heads/main/config_file/test6.18/.config"; \
    else \
      CONFIG_URL="https://raw.githubusercontent.com/pesa1234/MT6000_cust_build/refs/heads/main/config_file/.config"; \
    fi && \
    echo "Fetching config from: ${CONFIG_URL}" && \
    curl -fsSL "${CONFIG_URL}" -o /openwrt/.config && \
    echo "CONFIG_IB=y" >> /openwrt/.config && \
    echo "CONFIG_IB_STANDALONE=y" >> /openwrt/.config && \
    echo "CONFIG_PACKAGE_nordvpnlite=n" >> /openwrt/.config && \
    echo "CONFIG_PACKAGE_onionshare-cli=n" >> /openwrt/.config

ENV FORCE_UNSAFE_CONFIGURE=1
ENV TAR_OPTIONS=--no-same-owner
ENV LC_ALL=C

RUN make defconfig
RUN make -j"$(nproc)" download IGNORE_ERRORS=m
RUN make -j"$(nproc)" || make -j1 V=s

# Stage the imagebuilder tarball at a known path regardless of dated output dir,
# then wipe the build tree to free disk space on the runner before the next stage
RUN mkdir -p /output && \
    find /openwrt/bin -name "*imagebuilder*.tar.*" | head -1 | xargs -I{} cp {} /output/ && \
    ls -lh /output/ && \
    rm -rf /openwrt/build_dir /openwrt/staging_dir /openwrt/dl /openwrt/.git

# Stage 2: Slim runtime containing only the ImageBuilder
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    build-essential libncurses-dev \
    libssl-dev zlib1g-dev gawk git gettext unzip \
    file wget python3 python3-distutils rsync zstd && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /output/ /tmp/
RUN mkdir -p /builder && \
    tar -xf /tmp/*imagebuilder*.tar.* -C /builder --strip-components=1 && \
    rm /tmp/*imagebuilder*.tar.*

WORKDIR /builder
