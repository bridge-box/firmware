# BridgeBox QEMU Dev Sandbox
#
# Полная ��муляция боевой коробки с двумя TAP интерфейсами,
# L2 bridge, nfqdns, flowsense, bb-agent.
#
# Использование:
#   make qemu-dev
# или:
#   docker build -t bridgewrt-qemu-dev -f test/qemu-dev/Dockerfile .
#   docker run -it --rm --privileged \
#       -p 9999:9999 -p 2222:2222 \
#       bridgewrt-qemu-dev

# === Stage 1: Собираем OpenWrt образ ===
FROM debian:bookworm-slim AS builder

ARG OPENWRT_VERSION=25.12.0
ARG OPENWRT_TARGET=armsr/armv8

ENV DEBIAN_FRONTEND=noninteractive

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

WORKDIR /builder

# Скачиваем Image Builder
RUN TARGET_SLUG=$(echo "$OPENWRT_TARGET" | tr '/' '-') && \
    IB_NAME="openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET_SLUG}.Linux-x86_64" && \
    wget -q "https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${IB_NAME}.tar.zst" \
        -O /tmp/ib.tar.zst && \
    tar -I zstd -xf /tmp/ib.tar.zst && \
    mv "$IB_NAME" imagebuilder && \
    rm /tmp/ib.tar.zst && \
    mkdir -p imagebuilder/staging_dir/host && \
    touch imagebuilder/staging_dir/host/.prereq-build

# ��опируем firmware overlay
COPY files/ /builder/files/

# Инжектим BOX_ID
COPY scripts/inject-identity.sh /builder/scripts/inject-identity.sh
RUN chmod +x /builder/scripts/inject-identity.sh && \
    sh /builder/scripts/inject-identity.sh BB-QEMU-DEV

# Мержим QEMU dev overlay поверх
COPY test/qemu-dev/qemu-dev-overlay/ /builder/files/

# Копируем cross-compiled Rust б��нари
COPY test/qemu-dev/binaries/ /builder/files/usr/bin/

# Собираем образ
RUN make -C /builder/imagebuilder image \
        PROFILE="generic" \
        PACKAGES="tailscale wpad-basic-mbedtls -wpa-supplicant uhttpd dnsmasq microsocks" \
        FILES="/builder/files" \
        BIN_DIR="/builder/out" && \
    ls -la /builder/out/

# Распаковываем образ
RUN IMGFILE=$(ls /builder/out/*-squashfs-combined-efi.img.gz 2>/dev/null | head -1) && \
    if [ -z "$IMGFILE" ]; then \
        echo "ERROR: образ не найден" >&2; \
        ls -la /builder/out/ >&2; \
        exit 1; \
    fi && \
    gunzip -c "$IMGFILE" > /builder/openwrt.img && \
    echo "Image: $(du -h /builder/openwrt.img | cut -f1)"

# === Stage 2: Runtime ===
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-aarch64 \
    qemu-efi-aarch64 \
    qemu-system-data \
    qemu-utils \
    bridge-utils \
    iproute2 \
    iptables \
    dnsmasq \
    tinyproxy \
    socat \
    openssh-client \
    sshpass \
    procps \
    coreutils \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /test

COPY --from=builder /builder/openwrt.img /test/openwrt.img
RUN cp /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /test/efi.fd

COPY test/qemu-dev/entrypoint.sh /test/entrypoint.sh
RUN chmod +x /test/entrypoint.sh

EXPOSE 9999 2222

ENTRYPOINT ["/test/entrypoint.sh"]
