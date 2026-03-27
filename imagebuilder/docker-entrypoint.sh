#!/bin/sh
# docker-entrypoint.sh — Точка входа для Docker-сборки образов BridgeWRT
#
# Аргументы передаются как KEY=VALUE:
#   PROFILE=friendlyarm_nanopi-r3s BOX_ID=BB-001 VARIANT=dev

set -e

# Парсим аргументы
PROFILE=""
BOX_ID=""
VARIANT="production"

for arg in "$@"; do
    case "$arg" in
        PROFILE=*)    PROFILE="${arg#PROFILE=}" ;;
        BOX_ID=*)     BOX_ID="${arg#BOX_ID=}" ;;
        VARIANT=*)    VARIANT="${arg#VARIANT=}" ;;
        WIFI_SSID=*)  WIFI_SSID="${arg#WIFI_SSID=}" ;;
        WIFI_PASS=*)  WIFI_PASS="${arg#WIFI_PASS=}" ;;
    esac
done

if [ -z "$PROFILE" ]; then
    echo "Ошибка: PROFILE не задан" >&2
    echo "Использование: docker run --rm -v ./output:/output bridgewrt-builder PROFILE=friendlyarm_nanopi-r3s BOX_ID=BB-001" >&2
    exit 1
fi

# BOX_ID опционален — если не задан, генерируется на устройстве из MAC eth0
if [ -z "$BOX_ID" ]; then
    BOX_ID="TEMPLATE"
fi

# --- Пакеты ---

# Базовые пакеты: мост + management (Tailscale, Wi-Fi) + status page (uhttpd)
# Wi-Fi драйверы: несколько популярных USB чипов для универсальности
# wpad-basic-mbedtls = hostapd (AP mode) + wpa_supplicant (STA mode) в одном пакете
# dnsmasq нужен для DHCP + DNS hijack в AP mode (captive portal)
PACKAGES_BASE="tailscale wpad-basic-mbedtls -wpa-supplicant uhttpd dnsmasq kmod-rtl8xxxu rtl8188eu-firmware kmod-mt76x0u kmod-ath9k-htc"

if [ "$VARIANT" = "vanilla" ]; then
    # Эталон: чистая OpenWrt, идентичная скачанной с openwrt.org
    PACKAGES="luci"
    SKIP_FILES=1
elif [ "$VARIANT" = "dev" ]; then
    PACKAGES="$PACKAGES_BASE tcpdump -luci -luci-ssl"
else
    PACKAGES="$PACKAGES_BASE -luci -luci-ssl"
fi

# --- Инжектим BOX_ID ---

sh /builder/scripts/inject-identity.sh "$BOX_ID"

# --- Сборка ---

echo "=== BridgeWRT: сборка образа ==="
echo "  BOX_ID:   $BOX_ID"
echo "  PROFILE:  $PROFILE"
echo "  VARIANT:  $VARIANT"
echo ""

if [ "${SKIP_FILES:-0}" = "1" ]; then
    make -C /builder/imagebuilder image \
        PROFILE="$PROFILE" \
        PACKAGES="$PACKAGES" \
        BIN_DIR="/builder/out"
else
    make -C /builder/imagebuilder image \
        PROFILE="$PROFILE" \
        PACKAGES="$PACKAGES" \
        FILES="/builder/files" \
        BIN_DIR="/builder/out"
fi

# --- Переименовываем и копируем в /output ---

IMGFILE=$(ls /builder/out/*-"$PROFILE"-squashfs-sysupgrade.img.gz 2>/dev/null | head -1)

if [ -z "$IMGFILE" ]; then
    echo "Ошибка: образ не найден" >&2
    ls -la /builder/out/ >&2
    exit 1
fi

if [ "$BOX_ID" = "TEMPLATE" ]; then
    NEWNAME="bridgewrt-${VARIANT}-$(date +%Y%m%d).img.gz"
else
    NEWNAME="bridgewrt-${BOX_ID}-${VARIANT}-$(date +%Y%m%d).img.gz"
fi
cp "$IMGFILE" "/output/$NEWNAME"

echo ""
echo "=== Готово ==="
echo "  Образ:  /output/$NEWNAME"
echo "  Размер: $(du -h "/output/$NEWNAME" | cut -f1)"
if [ "$BOX_ID" != "TEMPLATE" ]; then
    echo "  BOX_ID: $BOX_ID"
else
    echo "  BOX_ID: генерируется на устройстве"
fi
