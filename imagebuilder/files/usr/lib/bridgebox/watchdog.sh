#!/bin/sh
# watchdog.sh — Двухуровневый watchdog: management plane + data plane
#
# Management plane (wlan0 + Tailscale) — приоритет, неприкасаемый.
# Data plane (br0) — мост, может ломаться, чиним удалённо.
#
# Логика:
#   - Если mgmt жив, а bridge мёртв → НЕ ребутим, оператор починит через mesh
#   - Если mgmt мёртв → пробуем восстановить wlan0
#   - После N полных отказов → reboot
#   - После N неудачных загрузок → safe mode (только mgmt, без bridge)
#
# Запускается через init.d/bridgebox-watchdog каждые 60 секунд.

BRIDGE="br0"
WLAN="wlan0"

# Счётчики (tmpfs — сбрасываются при reboot)
MGMT_FAIL_FILE="/tmp/bridgebox-wd-mgmt-fails"
BRIDGE_FAIL_FILE="/tmp/bridgebox-wd-bridge-fails"
MAX_FAILS=3

# Счётчик неудачных загрузок (persistent — переживает reboot)
BOOT_FAIL_FILE="/etc/bridgebox/boot-failures"
MAX_BOOT_FAILS=3

# Safe mode: если файл существует — поднимаем только mgmt
SAFE_MODE_FILE="/etc/bridgebox/safe-mode"

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

# --- Safe mode ---

is_safe_mode() {
    [ -f "$SAFE_MODE_FILE" ]
}

check_boot_failures() {
    boots=$(cat "$BOOT_FAIL_FILE" 2>/dev/null || echo "0")
    if [ "$boots" -ge "$MAX_BOOT_FAILS" ]; then
        if ! is_safe_mode; then
            logger -t bridgebox-wd "SAFE MODE: $boots неудачных загрузок, включаем safe mode"
            touch "$SAFE_MODE_FILE"
        fi
    fi
}

# Вызывается при успешной загрузке (mgmt UP)
clear_boot_failures() {
    echo "0" > "$BOOT_FAIL_FILE" 2>/dev/null
    if is_safe_mode; then
        logger -t bridgebox-wd "SAFE MODE: mgmt восстановлен, выходим из safe mode"
        rm -f "$SAFE_MODE_FILE"
    fi
}

increment_boot_failures() {
    boots=$(cat "$BOOT_FAIL_FILE" 2>/dev/null || echo "0")
    boots=$((boots + 1))
    echo "$boots" > "$BOOT_FAIL_FILE" 2>/dev/null
}

# --- Основная логика ---

# Проверяем safe mode при старте
check_boot_failures

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
    clear_boot_failures

    if [ "$ts_ok" = "0" ]; then
        # wlan0 жив, но Tailscale упал — перезапускаем
        logger -t bridgebox-wd "MGMT: wlan0 OK, Tailscale down — перезапуск"
        /etc/init.d/tailscale restart 2>/dev/null
    fi

    if [ "$bridge_ok" = "0" ]; then
        # mgmt жив, bridge мёртв — НЕ ребутим, логируем
        logger -t bridgebox-wd "DATA: bridge down, mgmt OK — ждём оператора"
    fi
elif [ "$wifi_hw_present" = "0" ]; then
    # Wi-Fi адаптер отсутствует физически — НЕ ребутим, бесполезно
    # Логируем один раз в 10 минут (каждый 20-й вызов при 30с интервале)
    mgmt_fails=$(cat "$MGMT_FAIL_FILE" 2>/dev/null || echo "0")
    mgmt_fails=$((mgmt_fails + 1))
    echo "$mgmt_fails" > "$MGMT_FAIL_FILE"
    if [ "$((mgmt_fails % 20))" = "1" ]; then
        logger -t bridgebox-wd "MGMT: Wi-Fi адаптер не найден, ребут не поможет — ждём"
    fi
else
    # Wi-Fi адаптер есть, но mgmt мёртв — пробуем восстановить
    mgmt_fails=$(cat "$MGMT_FAIL_FILE" 2>/dev/null || echo "0")
    mgmt_fails=$((mgmt_fails + 1))
    echo "$mgmt_fails" > "$MGMT_FAIL_FILE"

    if [ "$mgmt_fails" -le 2 ]; then
        # Первые попытки — восстановить wlan0
        recover_wlan
    elif [ "$mgmt_fails" -ge "$MAX_FAILS" ]; then
        # Всё мертво — reboot
        logger -t bridgebox-wd "FULL FAIL: mgmt мёртв $mgmt_fails раз — reboot"
        increment_boot_failures
        reboot
    fi
fi
