# Stage 1: Build the ImageBuilder from pesa1234/openwrt source
FROM debian:bookworm AS builder

RUN apt-get update && apt-get install -y \
    build-essential clang flex bison g++ gawk gcc-multilib \
    g++-multilib gettext git libncurses-dev libssl-dev \
    python3-distutils python3-setuptools rsync swig unzip \
    zlib1g-dev file wget curl python3-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ARG OPENWRT_BRANCH=main
RUN git clone --depth 1 -b "${OPENWRT_BRANCH}" \
    https://github.com/pesa1234/openwrt.git /openwrt

WORKDIR /openwrt

RUN ./scripts/feeds update -a && ./scripts/feeds install -a

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
    echo "CONFIG_IB_STANDALONE=y" >> /openwrt/.config

ENV FORCE_UNSAFE_CONFIGURE=1

RUN make defconfig
RUN make -j"$(nproc)" download
RUN make -j"$(nproc)" || make -j1 V=s

# Stage 2: Slim runtime containing only the ImageBuilder
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    build-essential libncurses-dev libncursesw-dev \
    libssl-dev zlib1g-dev gawk git gettext unzip \
    file wget python3 python3-distutils rsync && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /openwrt/bin/targets/mediatek/filogic/*imagebuilder*.tar.* /tmp/
RUN mkdir -p /builder && \
    tar -xf /tmp/*imagebuilder*.tar.* -C /builder --strip-components=1 && \
    rm /tmp/*imagebuilder*.tar.*

WORKDIR /builder
