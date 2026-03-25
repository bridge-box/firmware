#!/bin/sh
# watchdog.sh — Network watchdog (проверка bridge)
#
# Проверяет:
#   1. Bridge link status (eth0 + eth1 в br0)
#
# Если bridge мёртв — ребут через reboot.
# Hardware watchdog управляется системным watchdogd (OpenWrt),
# мы не трогаем /dev/watchdog напрямую.
#
# Запускается через init.d/bridgebox-watchdog каждые N секунд.

BRIDGE="br0"
FAIL_FILE="/tmp/bridgebox-wd-fails"
MAX_FAILS=3

# В setup mode bridge ещё не настроен — не проверяем, не ребутим
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    exit 0
fi

# Проверка: bridge существует и UP, оба порта присутствуют
check_bridge() {
    # Проверяем что br0 существует
    if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
        logger -t bridgebox-wd "FAIL: $BRIDGE не существует"
        return 1
    fi

    # Проверяем что br0 в состоянии UP
    state=$(cat /sys/class/net/"$BRIDGE"/operstate 2>/dev/null)
    if [ "$state" != "up" ]; then
        logger -t bridgebox-wd "FAIL: $BRIDGE operstate=$state"
        return 1
    fi

    # Проверяем что оба порта присутствуют
    for port in eth0 eth1; do
        if [ ! -d /sys/class/net/"$BRIDGE"/brif/"$port" ]; then
            logger -t bridgebox-wd "FAIL: $port не в $BRIDGE"
            return 1
        fi

        # Проверяем carrier (физический линк)
        carrier=$(cat /sys/class/net/"$port"/carrier 2>/dev/null || echo "0")
        if [ "$carrier" != "1" ]; then
            logger -t bridgebox-wd "WARN: $port carrier=$carrier (кабель не подключён?)"
            # Не фейлим — при начальном подключении один порт может быть без линка
        fi
    done

    return 0
}

# --- Основная логика ---

if check_bridge; then
    # Сброс счётчика фейлов
    echo "0" > "$FAIL_FILE"
else
    fails=$(cat "$FAIL_FILE" 2>/dev/null || echo "0")
    fails=$((fails + 1))
    echo "$fails" > "$FAIL_FILE"

    if [ "$fails" -ge "$MAX_FAILS" ]; then
        logger -t bridgebox-wd "Bridge мёртв $fails раз подряд — ребут"
        reboot
    else
        logger -t bridgebox-wd "Bridge проверка не пройдена ($fails/$MAX_FAILS)"
    fi
fi
