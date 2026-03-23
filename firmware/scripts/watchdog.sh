#!/bin/sh
# watchdog.sh — Hardware + network watchdog
#
# Проверяет:
#   1. Bridge link status (eth0 + eth1 в br0)
#   2. Пинает hardware watchdog (/dev/watchdog)
#
# Если bridge мёртв — не пинаем watchdog, через timeout коробка ребутнется.
# Если bridge жив — пинаем watchdog, коробка продолжает работать.
#
# Запускается через init.d/bridgebox-watchdog каждые N секунд.

WATCHDOG_DEV="/dev/watchdog"
BRIDGE="br0"

# Проверка: оба порта в bridge и link up
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
            # Не фейлим — в боевой позиции один порт может быть без линка
            # при начальном подключении
        fi
    done

    return 0
}

# Пинаем hardware watchdog
kick_watchdog() {
    if [ -c "$WATCHDOG_DEV" ]; then
        echo "V" > "$WATCHDOG_DEV"
    fi
}

# --- Основная логика ---

if check_bridge; then
    kick_watchdog
else
    logger -t bridgebox-wd "Bridge проверка не пройдена, watchdog НЕ пнут — ребут через timeout"
    # Не пинаем watchdog — hardware watchdog ребутнет коробку
fi
