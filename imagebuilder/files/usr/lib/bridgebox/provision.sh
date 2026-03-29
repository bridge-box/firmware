#!/bin/sh
# provision.sh — Полный provisioning коробки: Wi-Fi → register → unclaimed
#
# Оператор запускает один раз в мастерской.
# Wi-Fi credentials сохраняются — следующие коробки подхватят автоматически.
#
# Использование:
#   provision.sh --wifi "SSID" "PASSWORD"   — настроить Wi-Fi мастерской + provisioning
#   provision.sh                            — provisioning (Wi-Fi уже настроен)
#   provision.sh --check                    — проверка готовности

# НЕ используем set -e — явные проверки через err()

STATE_FILE="/etc/bridgebox/state"
BOX_ID_FILE="/etc/bridgebox/box-id"
WPA_CONF="/etc/bridgebox/wpa.conf"
BACKEND_URL_FILE="/etc/bridgebox/backend-url"

log() {
    echo "[provision] $*"
}

err() {
    echo "[provision] ОШИБКА: $*" >&2
    exit 1
}

# --- Wi-Fi ---

setup_wifi() {
    SSID="$1"
    PASS="$2"

    if [ -z "$SSID" ]; then
        err "SSID не задан"
    fi

    log "Настройка Wi-Fi: $SSID"

    cat > "$WPA_CONF" <<EOF
network={
    ssid="$SSID"
    psk="$PASS"
    key_mgmt=WPA-PSK
}
EOF

    # Полный сброс Wi-Fi: убиваем всё, пересоздаём чисто
    killall wpa_supplicant 2>/dev/null || true
    sleep 1

    # Удаляем wlan0 если уже существует (чистый старт)
    if [ -d "/sys/class/net/wlan0" ]; then
        ip link set wlan0 down 2>/dev/null || true
        iw dev wlan0 del 2>/dev/null || true
        sleep 1
    fi

    # Находим phy и создаём wlan0
    PHY=$(ls /sys/class/ieee80211/ 2>/dev/null | head -1)
    if [ -z "$PHY" ]; then
        err "Wi-Fi адаптер не найден (нет phy в /sys/class/ieee80211/)"
    fi
    log "Создаём wlan0 на $PHY..."
    iw phy "$PHY" interface add wlan0 type managed || err "Не удалось создать wlan0"
    ip link set wlan0 up || err "Не удалось поднять wlan0"

    # Подключаемся (nl80211 явно — без него rtl8xxxu уходит в deauth loop)
    wpa_supplicant -B -i wlan0 -c "$WPA_CONF" -D nl80211 || err "wpa_supplicant не запустился"
    log "wpa_supplicant запущен, ждём подключения..."

    # Ждём ассоциации (до 30 сек — rtl8xxxu может быть медленным)
    attempts=0
    while [ $attempts -lt 30 ]; do
        STATE=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)
        [ "$STATE" = "up" ] && break
        attempts=$((attempts + 1))
        sleep 1
    done

    if [ "$STATE" != "up" ]; then
        err "Не удалось подключиться к Wi-Fi '$SSID' (таймаут 30 сек)"
    fi

    # DHCP
    udhcpc -i wlan0 -q -t 5 -n 2>/dev/null
    WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)

    # DNS: прямой resolv.conf + upstream для dnsmasq
    echo "nameserver 8.8.8.8" > /tmp/resolv.conf
    mkdir -p /tmp/resolv.conf.d
    cat > /tmp/resolv.conf.d/resolv.conf.auto <<DNSEOF
nameserver 8.8.8.8
nameserver 1.1.1.1
DNSEOF
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    log "DNS: upstream 8.8.8.8, 1.1.1.1"

    if [ -z "$WLAN_IP" ]; then
        err "Wi-Fi подключён, но нет IP (DHCP не ответил)"
    fi

    log "Wi-Fi подключён: $SSID ($WLAN_IP)"
}

# --- Проверки ---

check_state() {
    STATE=$(cat "$STATE_FILE" 2>/dev/null)
    if [ "$STATE" != "setup" ]; then
        err "коробка уже в состоянии '$STATE', provisioning не нужен"
    fi
}

check_box_id() {
    # BOX_ID генерируется автоматически при первом запуске bb-agent
    BOX_ID=$(cat "$BOX_ID_FILE" 2>/dev/null)
    if [ -n "$BOX_ID" ] && [ "$BOX_ID" != "TEMPLATE" ]; then
        log "BOX_ID: $BOX_ID"
    else
        log "BOX_ID будет сгенерирован автоматически из MAC eth0"
    fi
}

check_wifi() {
    WLAN_STATE=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)
    if [ "$WLAN_STATE" != "up" ]; then
        # Если есть wpa.conf — пробуем подключиться
        if [ -f "$WPA_CONF" ]; then
            log "Wi-Fi down, но wpa.conf есть — пробуем подключиться..."
            ip link set wlan0 up 2>/dev/null
            wpa_supplicant -B -i wlan0 -c "$WPA_CONF" 2>/dev/null
            sleep 5
            udhcpc -i wlan0 -q -t 5 -n 2>/dev/null
            WLAN_STATE=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)
        fi

        if [ "$WLAN_STATE" != "up" ]; then
            err "Wi-Fi не поднят. Запусти: provision.sh --wifi \"SSID\" \"PASSWORD\""
        fi
    fi

    WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
    if [ -z "$WLAN_IP" ]; then
        err "Wi-Fi без IP-адреса"
    fi
    log "Wi-Fi: up ($WLAN_IP)"
}

check_backend() {
    BASE=$(get_backend_url)
    if ! wget -q -O /dev/null --timeout=5 "$BASE/" 2>/dev/null; then
        err "бэкенд недоступен ($BASE)"
    fi
    log "Бэкенд: OK ($BASE)"
}

get_backend_url() {
    if [ -f "$BACKEND_URL_FILE" ]; then
        cat "$BACKEND_URL_FILE"
    elif [ -n "$BACKEND_URL" ]; then
        echo "$BACKEND_URL"
    else
        echo "http://localhost:8080"
    fi
}

check_agent() {
    if ! command -v bb-agent >/dev/null 2>&1; then
        err "bb-agent не найден в PATH"
    fi
}

# --- Аргументы ---

case "$1" in
    --wifi)
        setup_wifi "$2" "$3"
        # Продолжаем provisioning
        ;;
    --check)
        log "=== Проверка готовности ==="
        check_state
        check_box_id
        check_wifi
        check_backend
        check_agent
        log "=== Всё готово к provisioning ==="
        exit 0
        ;;
esac

# --- Provisioning ---

log "=== Начинаем provisioning ==="

check_state
check_box_id
check_wifi
check_backend
check_agent

# Регистрация на бэкенде + автоматический перевод в UNCLAIMED
log "Регистрация на бэкенде..."
if ! bb-agent register; then
    err "bb-agent register завершился с ошибкой"
fi

# Mesh — подключаемся к Tailscale сразу
log "Подключение к mesh-сети..."
if bb-agent ensure-mesh; then
    log "Mesh: подключён"
else
    log "ВНИМАНИЕ: mesh не подключился (Headscale недоступен?). Heartbeat подхватит позже."
fi

# Проверяем Tailscale — оператор должен видеть статус
if command -v tailscale >/dev/null 2>&1; then
    TS_STATUS=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)
    log "Tailscale: $TS_STATUS"
fi

# bb-agent register сам генерит ID, регистрирует и переводит в UNCLAIMED
BOX_ID=$(cat "$BOX_ID_FILE" 2>/dev/null)
log "=== Provisioning завершён ==="
log "Коробка $BOX_ID готова к отправке."
log "Status page: http://192.168.77.1/"
