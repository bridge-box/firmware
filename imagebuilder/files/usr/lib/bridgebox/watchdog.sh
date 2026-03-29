#!/bin/sh
# watchdog.sh — Двухуровневый watchdog: management plane + data plane
#
# Management plane (wlan0 + Tailscale) — приоритет, неприкасаемый.
# Data plane (br0) — мост, может ломаться, чиним удалённо.
#
# Принцип: мост работает 24/7, НИКОГДА не ребутим.
# Если что-то сломалось — пробуем восстановить, логируем для оператора.
# Мост (data plane) продолжает работать даже если mgmt мёртв.
#
# Запускается через init.d/bridgebox-watchdog каждые 60 секунд.

BRIDGE="br0"
WLAN="wlan0"

# Счётчики (tmpfs — сбрасываются при reboot)
MGMT_FAIL_FILE="/tmp/bridgebox-wd-mgmt-fails"

# --- Проверки ---

check_mgmt() {
    # wlan0 существует и UP
    if ! ip link show "$WLAN" >/dev/null 2>&1; then
        logger -t bridgebox-wd "MGMT: $WLAN не существует"
        return 1
    fi

    state=$(cat /sys/class/net/"$WLAN"/operstate 2>/dev/null)
    if [ "$state" != "up" ]; then
        logger -t bridgebox-wd "MGMT: $WLAN operstate=$state"
        return 1
    fi

    # Есть IP-адрес
    if ! ip addr show "$WLAN" | grep -q "inet "; then
        logger -t bridgebox-wd "MGMT: $WLAN без IP"
        return 1
    fi

    return 0
}

check_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        return 1
    fi

    ts_status=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)
    if [ "$ts_status" = "Running" ]; then
        return 0
    fi

    logger -t bridgebox-wd "MGMT: Tailscale state=$ts_status"
    return 1
}

check_bridge() {
    # Bridge не настроен — пропускаем
    if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
        return 0
    fi

    # br0 UP
    state=$(cat /sys/class/net/"$BRIDGE"/operstate 2>/dev/null)
    if [ "$state" != "up" ]; then
        logger -t bridgebox-wd "DATA: $BRIDGE operstate=$state"
        return 1
    fi

    # Оба порта в bridge
    for port in eth0 eth1; do
        if [ ! -d /sys/class/net/"$BRIDGE"/brif/"$port" ]; then
            logger -t bridgebox-wd "DATA: $port не в $BRIDGE"
            return 1
        fi
    done

    return 0
}

# --- Восстановление wlan0 ---

recover_wlan() {
    logger -t bridgebox-wd "MGMT: попытка восстановить $WLAN через wifi-switch.sh"

    # Перезагрузка драйвера (может помочь при зависании USB)
    rmmod rtl8xxxu 2>/dev/null
    rmmod mt76x0u 2>/dev/null
    rmmod ath9k_htc 2>/dev/null
    sleep 2
    modprobe rtl8xxxu 2>/dev/null
    modprobe mt76x0u 2>/dev/null
    modprobe ath9k_htc 2>/dev/null
    sleep 3

    # Делегируем wifi-switch.sh — он сам решит AP или STA
    /usr/lib/bridgebox/wifi-switch.sh restore
}

# --- Основная логика ---

mgmt_ok=0
ts_ok=0
bridge_ok=0

# Проверяем наличие Wi-Fi адаптера вообще
wifi_hw_present=0
if [ -n "$(ls /sys/class/ieee80211/ 2>/dev/null)" ]; then
    wifi_hw_present=1
fi

check_mgmt && mgmt_ok=1
check_tailscale && ts_ok=1
check_bridge && bridge_ok=1

# Management plane
if [ "$mgmt_ok" = "1" ]; then
    # mgmt жив — сбрасываем счётчики
    echo "0" > "$MGMT_FAIL_FILE"

    if [ "$ts_ok" = "0" ]; then
        # wlan0 жив, но Tailscale упал — ensure-mesh (запросит auth key если не залогинен)
        logger -t bridgebox-wd "MGMT: wlan0 OK, Tailscale down — ensure-mesh"
        /usr/bin/bb-agent ensure-mesh 2>&1 | logger -t bridgebox-wd
    fi

    if [ "$bridge_ok" = "0" ]; then
        # mgmt жив, bridge мёртв — логируем, оператор починит через mesh
        logger -t bridgebox-wd "DATA: bridge down, mgmt OK — ждём оператора"
    fi
elif [ "$wifi_hw_present" = "0" ]; then
    # Wi-Fi адаптер отсутствует физически — бесполезно что-то делать
    # Логируем один раз в 10 минут (каждый 20-й вызов при 30с интервале)
    mgmt_fails=$(cat "$MGMT_FAIL_FILE" 2>/dev/null || echo "0")
    mgmt_fails=$((mgmt_fails + 1))
    echo "$mgmt_fails" > "$MGMT_FAIL_FILE"
    if [ "$((mgmt_fails % 20))" = "1" ]; then
        logger -t bridgebox-wd "MGMT: Wi-Fi адаптер не найден — мост работает, mgmt недоступен"
    fi
else
    # Wi-Fi адаптер есть, но mgmt мёртв — пробуем восстановить
    mgmt_fails=$(cat "$MGMT_FAIL_FILE" 2>/dev/null || echo "0")
    mgmt_fails=$((mgmt_fails + 1))
    echo "$mgmt_fails" > "$MGMT_FAIL_FILE"

    # Каждые 3 цикла пробуем восстановить wlan0 (не чаще раза в 90 сек)
    if [ "$((mgmt_fails % 3))" = "1" ]; then
        recover_wlan
    fi

    # Логируем раз в 10 минут
    if [ "$((mgmt_fails % 20))" = "1" ]; then
        logger -t bridgebox-wd "MGMT: wlan0 мёртв $mgmt_fails циклов — продолжаем попытки восстановления"
    fi
fi
