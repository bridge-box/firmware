#!/bin/sh
# wifi-switch.sh — Переключение Wi-Fi между AP и STA режимами
#
# Использование:
#   wifi-switch.sh ap              — поднять точку доступа BridgeBox-XXXXXX
#   wifi-switch.sh sta SSID PASS   — подключиться к Wi-Fi, при неудаче вернуться в AP
#   wifi-switch.sh status          — текущий режим (ap / sta / down)
#
# Требует: wpad-basic-mbedtls (hostapd + wpa_supplicant), iw, dnsmasq

WLAN="wlan0"
WPA_CONF="/etc/bridgebox/wpa.conf"
HOSTAPD_CONF="/tmp/bridgebox-hostapd.conf"
DNSMASQ_WIFI_CONF="/tmp/dnsmasq-bridgebox.conf"
DNSMASQ_WIFI_PID="/tmp/dnsmasq-bridgebox.pid"
AP_IP="192.168.77.1"
AP_NET="192.168.77"
STATE_FILE="/etc/bridgebox/wifi-mode"
# Fallback DNS — используется до получения DNS от DHCP
FALLBACK_DNS="8.8.8.8"

# --- Общие утилиты ---
. /usr/lib/bridgebox/lib-common.sh

# --- Логгирование ---

log() {
    logger -t bridgebox-wifi "$*"
    echo "$*"
}

# --- Получение BOX_ID для SSID ---

get_box_id() {
    cat /etc/bridgebox/box-id 2>/dev/null || echo "SETUP"
}

# --- Убить все Wi-Fi процессы ---

wifi_cleanup() {
    # Останавливаем hostapd
    killall hostapd 2>/dev/null || true

    # Останавливаем wpa_supplicant
    killall wpa_supplicant 2>/dev/null || true

    # Останавливаем DHCP-клиент на wlan0
    kill "$(cat /tmp/udhcpc-wlan0.pid 2>/dev/null)" 2>/dev/null || true

    # Останавливаем dnsmasq для AP
    if [ -f "$DNSMASQ_WIFI_PID" ]; then
        kill "$(cat "$DNSMASQ_WIFI_PID")" 2>/dev/null || true
        rm -f "$DNSMASQ_WIFI_PID"
    fi

    # Убираем IP с wlan0
    ip addr flush dev "$WLAN" 2>/dev/null || true
    ip link set "$WLAN" down 2>/dev/null || true

    # Удаляем интерфейс (чтобы пересоздать в нужном mode)
    iw dev "$WLAN" del 2>/dev/null || true

    sleep 1
}

# --- Найти PHY ---

find_phy() {
    local attempts=0
    local phy=""
    while [ $attempts -lt 10 ]; do
        phy=$(ls /sys/class/ieee80211/ 2>/dev/null | tail -1)
        [ -n "$phy" ] && echo "$phy" && return 0
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

# --- AP MODE ---

start_ap() {
    log "Запуск AP mode..."

    wifi_cleanup

    PHY=$(find_phy)
    if [ -z "$PHY" ]; then
        log "ОШИБКА: Wi-Fi адаптер не найден"
        safe_write "$STATE_FILE" "down"
        return 1
    fi

    # Создаём wlan0 в AP mode
    iw phy "$PHY" interface add "$WLAN" type __ap
    if [ $? -ne 0 ]; then
        log "ОШИБКА: не удалось создать $WLAN в AP mode на $PHY"
        safe_write "$STATE_FILE" "down"
        return 1
    fi

    ip link set "$WLAN" up
    ip addr add "${AP_IP}/24" dev "$WLAN"

    # Генерируем SSID
    local box_id
    box_id=$(get_box_id)
    local ssid="BridgeBox-${box_id}"

    # hostapd конфиг (открытая сеть для простоты setup)
    cat > "$HOSTAPD_CONF" <<HAPD
interface=${WLAN}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=6
wmm_enabled=0
auth_algs=1
wpa=0
HAPD

    hostapd -B "$HOSTAPD_CONF"
    if [ $? -ne 0 ]; then
        log "ОШИБКА: hostapd не запустился"
        wifi_cleanup
        safe_write "$STATE_FILE" "down"
        return 1
    fi

    # dnsmasq для DHCP + DNS hijack (captive portal)
    cat > "$DNSMASQ_WIFI_CONF" <<DNS
interface=${WLAN}
bind-interfaces
dhcp-range=${AP_NET}.100,${AP_NET}.250,255.255.255.0,1h
dhcp-option=6,${AP_IP}
address=/#/${AP_IP}
DNS

    dnsmasq -C "$DNSMASQ_WIFI_CONF" -x "$DNSMASQ_WIFI_PID" --no-resolv
    if [ $? -ne 0 ]; then
        log "ПРЕДУПРЕЖДЕНИЕ: dnsmasq не запустился, DHCP/DNS hijack не работает"
    fi

    safe_write "$STATE_FILE" "ap"
    log "AP mode: SSID='${ssid}', IP=${AP_IP}, DHCP=${AP_NET}.100-250"
    return 0
}

# --- STA MODE ---

start_sta() {
    local ssid="$1"
    local pass="$2"

    if [ -z "$ssid" ] || [ -z "$pass" ]; then
        log "ОШИБКА: SSID и пароль обязательны"
        return 1
    fi

    log "Переключение в STA mode: SSID='${ssid}'..."

    wifi_cleanup

    PHY=$(find_phy)
    if [ -z "$PHY" ]; then
        log "ОШИБКА: Wi-Fi адаптер не найден"
        start_ap
        return 1
    fi

    # Создаём wlan0 в managed (client) mode
    iw phy "$PHY" interface add "$WLAN" type managed
    if [ $? -ne 0 ]; then
        log "ОШИБКА: не удалось создать $WLAN в STA mode"
        start_ap
        return 1
    fi

    ip link set "$WLAN" up

    # Временный wpa_supplicant конфиг
    local tmp_wpa="/tmp/bridgebox-wpa-try.conf"
    cat > "$tmp_wpa" <<WPA
network={
    ssid="${ssid}"
    psk="${pass}"
    key_mgmt=WPA-PSK
    proto=RSN
}
WPA

    wpa_supplicant -B -i "$WLAN" -c "$tmp_wpa" -D nl80211
    if [ $? -ne 0 ]; then
        log "ОШИБКА: wpa_supplicant не запустился"
        rm -f "$tmp_wpa"
        start_ap
        return 1
    fi

    # Ждём ассоциации (30 сек)
    local attempt=0
    local connected=0
    while [ $attempt -lt 15 ]; do
        local state
        state=$(cat /sys/class/net/$WLAN/operstate 2>/dev/null)
        if [ "$state" = "up" ]; then
            connected=1
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    if [ "$connected" -ne 1 ]; then
        log "ОШИБКА: не удалось подключиться к '$ssid' за 30 сек"
        killall wpa_supplicant 2>/dev/null || true
        rm -f "$tmp_wpa"
        start_ap
        return 1
    fi

    # DHCP
    udhcpc -i "$WLAN" -q -t 10 -n -p /tmp/udhcpc-wlan0.pid 2>/dev/null
    if [ $? -ne 0 ]; then
        log "ОШИБКА: DHCP не получен на $WLAN"
        killall wpa_supplicant 2>/dev/null || true
        rm -f "$tmp_wpa"
        start_ap
        return 1
    fi

    # DNS: прокидываем upstream в dnsmasq
    mkdir -p /tmp/resolv.conf.d
    cat > /tmp/resolv.conf.d/resolv.conf.auto <<DNSEOF
nameserver $FALLBACK_DNS
nameserver 1.1.1.1
DNSEOF
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    log "DNS: upstream $FALLBACK_DNS, 1.1.1.1"

    # Проверяем интернет
    local dns_ok=0
    if ping -c 1 -W 5 "$FALLBACK_DNS" >/dev/null 2>&1; then
        dns_ok=1
    fi

    if [ "$dns_ok" -ne 1 ]; then
        log "ПРЕДУПРЕЖДЕНИЕ: нет интернета через Wi-Fi, но соединение есть"
    fi

    # Успех! Сохраняем конфиг навсегда
    cp "$tmp_wpa" "$WPA_CONF"
    rm -f "$tmp_wpa"

    local ip
    ip=$(ip -4 addr show "$WLAN" 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
    safe_write "$STATE_FILE" "sta"
    log "STA mode: подключён к '${ssid}', IP=${ip}"
    return 0
}

# --- Восстановление STA из сохранённого конфига ---

restore_sta() {
    if [ ! -f "$WPA_CONF" ]; then
        log "Нет сохранённого Wi-Fi конфига, запуск AP"
        start_ap
        return 1
    fi

    log "Восстановление STA из $WPA_CONF..."

    wifi_cleanup

    PHY=$(find_phy)
    if [ -z "$PHY" ]; then
        log "ОШИБКА: Wi-Fi адаптер не найден"
        safe_write "$STATE_FILE" "down"
        return 1
    fi

    iw phy "$PHY" interface add "$WLAN" type managed
    if [ $? -ne 0 ]; then
        log "ОШИБКА: не удалось создать $WLAN"
        start_ap
        return 1
    fi

    ip link set "$WLAN" up
    wpa_supplicant -B -i "$WLAN" -c "$WPA_CONF" -D nl80211
    if [ $? -ne 0 ]; then
        log "ОШИБКА: wpa_supplicant не запустился"
        start_ap
        return 1
    fi

    # Ждём ассоциации
    local attempt=0
    local connected=0
    while [ $attempt -lt 15 ]; do
        local state
        state=$(cat /sys/class/net/$WLAN/operstate 2>/dev/null)
        if [ "$state" = "up" ]; then
            connected=1
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    if [ "$connected" -ne 1 ]; then
        log "ОШИБКА: не удалось восстановить Wi-Fi, переход в AP"
        killall wpa_supplicant 2>/dev/null || true
        start_ap
        return 1
    fi

    udhcpc -i "$WLAN" -q -t 10 -n -p /tmp/udhcpc-wlan0.pid 2>/dev/null

    # DNS: прокидываем upstream в dnsmasq
    mkdir -p /tmp/resolv.conf.d
    cat > /tmp/resolv.conf.d/resolv.conf.auto <<DNSEOF
nameserver $FALLBACK_DNS
nameserver 1.1.1.1
DNSEOF
    /etc/init.d/dnsmasq restart 2>/dev/null || true

    local ip
    ip=$(ip -4 addr show "$WLAN" 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
    safe_write "$STATE_FILE" "sta"
    log "STA восстановлен, IP=${ip}"
    return 0
}

# --- STATUS ---

get_status() {
    cat "$STATE_FILE" 2>/dev/null || echo "down"
}

# --- MAIN ---

case "$1" in
    ap)
        start_ap
        ;;
    sta)
        start_sta "$2" "$3"
        ;;
    restore)
        restore_sta
        ;;
    status)
        get_status
        ;;
    *)
        echo "Использование: $0 {ap|sta SSID PASS|restore|status}"
        exit 1
        ;;
esac
