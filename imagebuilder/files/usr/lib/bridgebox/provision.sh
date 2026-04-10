#!/bin/sh
# provision.sh — Полный provisioning коробки: Wi-Fi → bb-agent → register → mesh
#
# Оператор запускает один раз в мастерской.
# Wi-Fi credentials сохраняются — следующие коробки подхватят автоматически.
#
# Принцип: bb-agent — единственный оркестратор. provision.sh только
# готовит среду (Wi-Fi) и ждёт пока agent сам зарегистрируется и поднимет mesh.
#
# Использование:
#   provision.sh --wifi "SSID" "PASSWORD"   — настроить Wi-Fi мастерской + provisioning
#   provision.sh                            — provisioning (Wi-Fi уже настроен)
#   provision.sh --check                    — проверка готовности

# НЕ используем set -e — явные проверки через err()

. /usr/lib/bridgebox/lib-common.sh

STATE_FILE="/etc/bridgebox/state"
BOX_ID_FILE="/etc/bridgebox/box-id"
WPA_CONF="/etc/bridgebox/wpa.conf"
BACKEND_URL_FILE="/etc/bridgebox/backend-url"

# Таймауты (секунды)
REGISTER_TIMEOUT=60
MESH_TIMEOUT=90

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

check_agent_binary() {
    if ! command -v bb-agent >/dev/null 2>&1; then
        err "bb-agent не найден в PATH"
    fi
}

# --- Ожидание событий от agent ---

# Ждём пока bb-agent зарегистрируется на backend.
# Проверяем через логи agent (journalctl/logread).
wait_for_registration() {
    log "Ожидание регистрации на backend (до ${REGISTER_TIMEOUT}с)..."
    elapsed=0
    while [ $elapsed -lt $REGISTER_TIMEOUT ]; do
        # Проверяем лог agent на успешную регистрацию
        if logread 2>/dev/null | grep -q "Registered with backend"; then
            log "Регистрация: OK"
            return 0
        fi
        # Или проверяем что BOX_ID появился (agent генерирует при старте)
        BOX_ID=$(cat "$BOX_ID_FILE" 2>/dev/null)
        if [ -n "$BOX_ID" ] && [ "$BOX_ID" != "TEMPLATE" ]; then
            # BOX_ID есть — проверяем что agent запущен и логи есть
            if logread 2>/dev/null | grep -q "bb-agent.*запущен"; then
                # Agent запустился, подождём регистрацию чуть дольше
                :
            fi
        fi
        elapsed=$((elapsed + 2))
        sleep 2
    done
    log "ВНИМАНИЕ: регистрация не подтверждена за ${REGISTER_TIMEOUT}с (agent повторит при следующем heartbeat)"
    return 1
}

# Ждём пока Tailscale подключится к mesh.
wait_for_mesh() {
    log "Ожидание mesh-подключения (до ${MESH_TIMEOUT}с)..."
    elapsed=0
    while [ $elapsed -lt $MESH_TIMEOUT ]; do
        # Проверяем наличие tailscale0 интерфейса с IP
        TS_IP=$(ip -4 addr show tailscale0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
        if [ -n "$TS_IP" ]; then
            log "Mesh: подключён ($TS_IP)"
            return 0
        fi
        elapsed=$((elapsed + 3))
        sleep 3
    done
    log "ВНИМАНИЕ: mesh не подключился за ${MESH_TIMEOUT}с (agent повторит автоматически)"
    return 1
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
        check_agent_binary
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
check_agent_binary

# Перезапускаем bb-agent — он сам определит management interface,
# зарегистрируется на backend и подключится к mesh.
log "Перезапуск bb-agent..."
if [ -f /etc/init.d/bridgebox-agent ]; then
    /etc/init.d/bridgebox-agent restart
else
    # Fallback: запуск напрямую (dev-режим)
    killall bb-agent 2>/dev/null || true
    sleep 1
    bb-agent &
fi

# Даём agent время на инициализацию
sleep 3

# Ждём регистрацию
REGISTERED=false
if wait_for_registration; then
    REGISTERED=true
fi

# Ждём mesh (даже если регистрация не подтверждена — agent пробует mesh в любом случае)
MESH_OK=false
if wait_for_mesh; then
    MESH_OK=true
fi

# Обновляем state если всё прошло
BOX_ID=$(cat "$BOX_ID_FILE" 2>/dev/null)

log "=== Provisioning завершён ==="
log "  BOX_ID:       ${BOX_ID:-не сгенерирован}"

if [ "$REGISTERED" = "true" ]; then
    log "  Регистрация:  OK"
else
    log "  Регистрация:  ожидается (agent повторит автоматически)"
fi

if [ "$MESH_OK" = "true" ]; then
    TS_IP=$(ip -4 addr show tailscale0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
    log "  Mesh:         OK ($TS_IP)"
else
    log "  Mesh:         ожидается (agent повторит автоматически)"
fi

if [ "$REGISTERED" = "true" ] && [ "$MESH_OK" = "true" ]; then
    safe_write "$STATE_FILE" "provisioned"
    log ""
    log "Коробка $BOX_ID готова к отправке."
else
    log ""
    log "Коробка частично провиженена. Проверь:"
    if [ "$REGISTERED" != "true" ]; then
        log "  - Логи agent: logread | grep bb-agent"
        log "  - Backend доступен? wget -q -O- $(get_backend_url)/"
    fi
    if [ "$MESH_OK" != "true" ]; then
        log "  - Tailscale: tailscale status"
        log "  - Headscale доступен? wget -q -O- $(cat /etc/bridgebox/headscale-url 2>/dev/null)/"
    fi
fi

log "Status page: http://bridge-box/"
