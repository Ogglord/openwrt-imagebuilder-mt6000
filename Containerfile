# Slim runtime containing the pre-built ImageBuilder tarball.
# The tarball is built on the CI runner and copied into the build context
# before this Containerfile is evaluated.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    build-essential libncurses-dev \
    libssl-dev zlib1g-dev gawk git gettext unzip \
    file wget python3 python3-setuptools rsync zstd && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY *imagebuilder*.tar.* /tmp/
RUN mkdir -p /builder && \
    tar -xf /tmp/*imagebuilder*.tar.* -C /builder --strip-components=1 && \
    rm /tmp/*imagebuilder*.tar.*

WORKDIR /builder
