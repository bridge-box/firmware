# BridgeWRT Image Builder
#
# Сборка:
#   docker build -t bridgewrt-builder .
#
# Использование:
#   docker run --rm -v ./output:/output bridgewrt-builder \
#       PROFILE=friendlyarm_nanopi-r3s BOX_ID=BB-001

FROM debian:bookworm-slim

ARG OPENWRT_VERSION=25.12.0
ARG OPENWRT_TARGET=rockchip/armv8

ENV DEBIAN_FRONTEND=noninteractive

# Зависимости Image Builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gawk \
    libncurses-dev \
    zstd \
    unzip \
    file \
    wget \
    python3 \
    perl \
    ca-certificates \
    python3-setuptools \
    && rm -rf /var/lib/apt/lists/*

# Скачиваем и распаковываем Image Builder
WORKDIR /builder
RUN TARGET_SLUG=$(echo "$OPENWRT_TARGET" | tr '/' '-') && \
    IB_NAME="openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET_SLUG}.Linux-x86_64" && \
    wget -q "https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${IB_NAME}.tar.zst" \
        -O /tmp/ib.tar.zst && \
    tar -I zstd -xf /tmp/ib.tar.zst && \
    mv "$IB_NAME" imagebuilder && \
    rm /tmp/ib.tar.zst && \
    mkdir -p imagebuilder/staging_dir/host && \
    touch imagebuilder/staging_dir/host/.prereq-build

# Выходная директория
RUN mkdir -p /output

# Инвалидация кеша для наших файлов (слои выше кешируются)
ARG CACHEBUST=1

# Копируем overlay файлы и скрипты
COPY files/ /builder/files/
COPY scripts/inject-identity.sh /builder/scripts/inject-identity.sh
RUN chmod +x /builder/scripts/inject-identity.sh

# Точка входа — принимает аргументы make
COPY docker-entrypoint.sh /builder/docker-entrypoint.sh
RUN chmod +x /builder/docker-entrypoint.sh

ENTRYPOINT ["/builder/docker-entrypoint.sh"]
