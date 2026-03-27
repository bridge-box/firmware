# BridgeWRT L3 Boot Test — QEMU
#
# Собирает образ armsr/armv8 (официальный QEMU-таргет OpenWrt)
# с нашим overlay, загружает в QEMU, проверяет что всё поднялось.
#
# Использование:
#   docker build -t bridgewrt-qemu-test -f test/qemu/Dockerfile .
#   docker run --rm --privileged bridgewrt-qemu-test
#
# --privileged нужен для /dev/kvm (аппаратная виртуализация)

FROM debian:bookworm-slim AS builder

ARG OPENWRT_VERSION=25.12.0
ARG OPENWRT_TARGET=armsr/armv8

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

# Скачиваем armsr/armv8 Image Builder (QEMU-совместимый таргет)
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

# Копируем overlay и скрипты
COPY files/ /builder/files/
COPY scripts/inject-identity.sh /builder/scripts/inject-identity.sh
RUN chmod +x /builder/scripts/inject-identity.sh

# Инжектим тестовый BOX_ID
RUN sh /builder/scripts/inject-identity.sh BB-QEMU-TEST

# Мержим QEMU-специфичный overlay поверх основных файлов
COPY test/qemu/qemu-overlay/ /builder/files/

# Собираем образ для QEMU (armsr/armv8, generic profile)
# Пакеты: те же что на реальном железе, минус USB Wi-Fi драйверы (в QEMU нет USB Wi-Fi)
# Добавляем: qemu-ga для гостевого взаимодействия (опционально)
RUN make -C /builder/imagebuilder image \
        PROFILE="generic" \
        PACKAGES="tailscale wpad-basic-mbedtls -wpa-supplicant uhttpd dnsmasq" \
        FILES="/builder/files" \
        BIN_DIR="/builder/out" && \
    ls -la /builder/out/

# Находим собранный образ
RUN IMGFILE=$(ls /builder/out/*-squashfs-combined-efi.img.gz 2>/dev/null | head -1) && \
    if [ -z "$IMGFILE" ]; then \
        echo "Ошибка: образ не найден. Файлы в out/:" >&2; \
        ls -la /builder/out/ >&2; \
        exit 1; \
    fi && \
    gunzip -c "$IMGFILE" > /builder/openwrt.img && \
    echo "Образ: $(du -h /builder/openwrt.img | cut -f1)"

# --- Runtime stage ---
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-aarch64 \
    qemu-efi-aarch64 \
    qemu-system-data \
    iputils-ping \
    openssh-client \
    sshpass \
    procps \
    coreutils \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /test

# Копируем образ из builder stage
COPY --from=builder /builder/openwrt.img /test/openwrt.img

# EFI firmware для aarch64
RUN cp /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /test/efi.fd

# Тестовый скрипт
COPY test/qemu/boot-test.sh /test/boot-test.sh
RUN chmod +x /test/boot-test.sh

ENTRYPOINT ["/test/boot-test.sh"]
