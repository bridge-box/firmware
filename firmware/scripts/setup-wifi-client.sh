#!/bin/sh
# setup-wifi-client.sh — Подключение USB Wi-Fi к домашней сети (client/STA)
#
# [UNSTABLE] Скрипт экспериментальный. Проверен только с RTL8188EUS (0bda:8179).
# Другие чипсеты могут потребовать доработки.
#
# Зачем:
#   USB Wi-Fi даёт management-доступ к коробке в боевой позиции (inline bridge),
#   где br0 не имеет IP и SSH через мост недоступен.
#
# Что делает:
#   1. Ждёт появления Wi-Fi phy (любой USB Wi-Fi, определённый ядром)
#   2. Создаёт wlan0, подключается к указанной сети через wpa_supplicant
#   3. Получает IP по DHCP
#
# Использование:
#   sh setup-wifi-client.sh <ssid> <password>
#
# Требования:
#   - USB Wi-Fi адаптер с загруженным драйвером (kmod-rtl8xxxu, kmod-mt76u и т.д.)
#   - wpa-supplicant
#   - Прошивка для чипсета (rtl8188eu-firmware и т.д.)

set -e

SSID="${1:-}"
PASSWORD="${2:-}"
WLAN="wlan0"
WPA_CONF="/etc/bridgebox-wpa.conf"
PHY_WAIT=15

if [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    echo "Использование: $0 <ssid> <password>" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запускать от root" >&2
    exit 1
fi

if ! command -v wpa_supplicant >/dev/null 2>&1; then
    echo "Ошибка: wpa_supplicant не установлен (apk add wpa-supplicant)" >&2
    exit 1
fi

echo "=== BridgeBox: Wi-Fi client [UNSTABLE] ==="
echo ""

# --- Шаг 1: Найти Wi-Fi phy ---

echo "[1/4] Поиск Wi-Fi адаптера..."

PHY=""
waited=0
while [ $waited -lt $PHY_WAIT ]; do
    for p in /sys/class/ieee80211/phy*; do
        if [ -d "$p" ]; then
            PHY=$(basename "$p")
            break
        fi
    done
    [ -n "$PHY" ] && break
    sleep 1
    waited=$((waited + 1))
done

if [ -z "$PHY" ]; then
    echo "Ошибка: Wi-Fi адаптер не найден за ${PHY_WAIT}с" >&2
    echo "Проверьте: dmesg | grep -i wifi" >&2
    exit 1
fi

echo "  Найден: $PHY"

# --- Шаг 2: Создать интерфейс ---

echo "[2/4] Создание $WLAN..."

# Удалим старый, если есть
iw dev "$WLAN" del 2>/dev/null || true

iw phy "$PHY" interface add "$WLAN" type managed
ip link set "$WLAN" up

echo "  $WLAN создан на $PHY"

# --- Шаг 3: Подключение к Wi-Fi ---

echo "[3/4] Подключение к '$SSID'..."

# Убиваем старый wpa_supplicant, если висит
killall wpa_supplicant 2>/dev/null || true
sleep 1

printf 'network={\n    ssid="%s"\n    psk="%s"\n    key_mgmt=WPA-PSK\n}\n' "$SSID" "$PASSWORD" > "$WPA_CONF"
chmod 600 "$WPA_CONF"

wpa_supplicant -B -i "$WLAN" -c "$WPA_CONF"
sleep 5

if ! iw dev "$WLAN" link | grep -q "Connected"; then
    echo "Ошибка: не удалось подключиться к '$SSID'" >&2
    echo "Проверьте SSID/пароль и dmesg" >&2
    exit 1
fi

echo "  Подключено к '$SSID'"

# --- Шаг 4: DHCP ---

echo "[4/4] Получение IP..."

udhcpc -i "$WLAN" -q 2>/dev/null

WLAN_IP=$(ip -4 addr show "$WLAN" | grep -oE 'inet [0-9.]+' | awk '{print $2}')

if [ -z "$WLAN_IP" ]; then
    echo "Ошибка: не удалось получить IP по DHCP" >&2
    exit 1
fi

echo "  IP: $WLAN_IP"

# --- Итог ---

echo ""
echo "=== Wi-Fi client настроен [UNSTABLE] ==="
echo ""
echo "  Интерфейс: $WLAN"
echo "  SSID:      $SSID"
echo "  IP:        $WLAN_IP"
echo "  Phy:       $PHY"
echo ""
echo "Проверки:"
echo "  iw dev $WLAN link    — статус подключения"
echo "  ip addr show $WLAN   — IP-адрес"
echo ""
