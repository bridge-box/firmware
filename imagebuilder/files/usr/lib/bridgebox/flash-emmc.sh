#!/bin/sh
# flash-emmc.sh — Прошивка образа на eMMC
#
# Записывает образ на eMMC и сбрасывает overlay.
# Безопасно вызывать из-под загруженной с eMMC системы.
#
# Использование: sh flash-emmc.sh /tmp/image.img
# После прошивки — reboot вручную.

set -e

IMG="$1"

if [ -z "$IMG" ]; then
    echo "Использование: sh flash-emmc.sh /path/to/image.img" >&2
    exit 1
fi

if [ ! -f "$IMG" ]; then
    echo "Ошибка: файл $IMG не найден" >&2
    exit 1
fi

EMMC="/dev/mmcblk0"

if [ ! -b "$EMMC" ]; then
    echo "Ошибка: $EMMC не найден" >&2
    exit 1
fi

echo "=== BridgeBox: прошивка eMMC ==="
echo "  Образ: $IMG"
echo "  Диск:  $EMMC"
echo ""

# Записываем образ
echo "Записываем образ..."
dd if="$IMG" of="$EMMC" bs=4M conv=fsync 2>&1
sync

echo ""
echo "=== Готово ==="
echo "Перезагрузите коробку: reboot"
echo "После загрузки overlay будет чистый, uci-defaults выполнятся заново."
