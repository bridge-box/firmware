#!/bin/sh
# wifi-watchdog.sh — Проверяет Wi-Fi соединение, восстанавливает при обрыве
#
# Запускается из cron каждые 3 минуты.
# Если STA mode и Wi-Fi отвалился — пробуем переподключиться.
# Если 3 попытки подряд неудачны — откатываемся в AP mode.

WIFI_MODE=$(cat /etc/bridgebox/wifi-mode 2>/dev/null || echo "down")
FAIL_COUNT_FILE="/tmp/bridgebox-wifi-fail-count"
MAX_FAILS=3

# Только для STA mode
[ "$WIFI_MODE" = "sta" ] || exit 0

# Проверяем operstate
MGMT_IFACE="wlan0"
if [ -f /etc/bridgebox/mgmt-iface ]; then
    MGMT_IFACE=$(cat /etc/bridgebox/mgmt-iface)
fi
WLAN_STATE=$(cat /sys/class/net/$MGMT_IFACE/operstate 2>/dev/null || echo "down")

if [ "$WLAN_STATE" = "up" ]; then
    # Всё ок, сбрасываем счётчик
    rm -f "$FAIL_COUNT_FILE"
    exit 0
fi

# Wi-Fi упал — считаем попытки
FAILS=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
FAILS=$((FAILS + 1))
echo "$FAILS" > "$FAIL_COUNT_FILE"

logger -t bridgebox-wifi "Wi-Fi отвалился (попытка $FAILS/$MAX_FAILS)"

if [ "$FAILS" -ge "$MAX_FAILS" ]; then
    # Слишком много неудач — AP mode, юзер сможет переввести пароль
    logger -t bridgebox-wifi "Откат в AP mode после $MAX_FAILS неудачных попыток"
    rm -f "$FAIL_COUNT_FILE"
    /usr/lib/bridgebox/wifi-switch.sh ap
else
    # Пробуем восстановить
    /usr/lib/bridgebox/wifi-switch.sh restore
fi
