#!/bin/sh
# build.sh — Скачать и распаковать OpenWrt Image Builder
#
# Использование:
#   sh build.sh download <version> <target>
#
# Пример:
#   sh build.sh download 25.12.0-rc1 rockchip/armv8

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IB_DIR="$SCRIPT_DIR/../openwrt-imagebuilder"

ACTION="${1:-}"
VERSION="${2:-25.12.0-rc1}"
TARGET="${3:-rockchip/armv8}"

# target slug для URL: rockchip/armv8 → rockchip-armv8
TARGET_SLUG=$(echo "$TARGET" | tr '/' '-')

# Имя архива и директории
IB_NAME="openwrt-imagebuilder-${VERSION}-${TARGET_SLUG}.Linux-x86_64"
IB_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${IB_NAME}.tar.zst"

case "$ACTION" in
    download)
        if [ -f "$IB_DIR/Makefile" ]; then
            echo "Image Builder уже скачан: $IB_DIR"
            exit 0
        fi

        echo "Скачивание: $IB_URL"

        # Проверяем зависимости
        for cmd in wget zstd tar; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo "Ошибка: $cmd не найден. Установите:" >&2
                echo "  apt install wget zstd" >&2
                exit 1
            fi
        done

        # Скачиваем
        TMPFILE="/tmp/openwrt-ib-$$.tar.zst"
        wget -O "$TMPFILE" "$IB_URL"

        # Распаковываем
        echo "Распаковка..."
        PARENT_DIR=$(dirname "$IB_DIR")
        tar -I zstd -xf "$TMPFILE" -C "$PARENT_DIR"

        # Переименовываем в простое имя
        if [ -d "$PARENT_DIR/$IB_NAME" ]; then
            mv "$PARENT_DIR/$IB_NAME" "$IB_DIR"
        fi

        rm -f "$TMPFILE"

        echo "Image Builder готов: $IB_DIR"
        echo "  $(du -sh "$IB_DIR" | cut -f1)"
        ;;

    *)
        echo "Использование: $0 download [version] [target]" >&2
        exit 1
        ;;
esac
