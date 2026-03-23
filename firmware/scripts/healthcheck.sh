#!/bin/sh
# healthcheck.sh — Проверка состояния коробки
#
# Проверяет:
#   1. Bridge (br0): существует, UP, порты eth0/eth1
#   2. Tailscale: подключён, есть IP (если доступен)
#   3. Интернет: HTTP 204 (если доступен)
#
# Запуск: sh healthcheck.sh
# Возвращает exit code 0 если критические проверки пройдены.

PASS=0
FAIL=0
WARN=0

check() {
    name="$1"
    shift
    printf "  %-35s " "$name"
    if result=$("$@" 2>&1); then
        echo "[OK] $result"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $result"
        FAIL=$((FAIL + 1))
    fi
}

check_warn() {
    name="$1"
    shift
    printf "  %-35s " "$name"
    if result=$("$@" 2>&1); then
        echo "[OK] $result"
        PASS=$((PASS + 1))
    else
        echo "[WARN] $result"
        WARN=$((WARN + 1))
    fi
}

echo "=== BridgeBox: Health Check ==="
echo ""

# --- Bridge ---

echo "Bridge:"

check "br0 существует" \
    sh -c '[ -d /sys/class/net/br0 ] && echo "да" || { echo "нет"; false; }'

check "br0 состояние" \
    sh -c 'state=$(cat /sys/class/net/br0/operstate 2>/dev/null); [ "$state" = "up" ] && echo "$state" || { echo "${state:-unknown}"; false; }'

check "eth0 в br0" \
    sh -c '[ -d /sys/class/net/br0/brif/eth0 ] && echo "да" || { echo "нет"; false; }'

check "eth1 в br0" \
    sh -c '[ -d /sys/class/net/br0/brif/eth1 ] && echo "да" || { echo "нет"; false; }'

check_warn "eth0 carrier (линк)" \
    sh -c 'c=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo "0"); [ "$c" = "1" ] && echo "up" || { echo "down"; false; }'

check_warn "eth1 carrier (линк)" \
    sh -c 'c=$(cat /sys/class/net/eth1/carrier 2>/dev/null || echo "0"); [ "$c" = "1" ] && echo "up" || { echo "down"; false; }'

check_warn "br0 IP (management)" \
    sh -c 'ip=$(ip -4 addr show br0 2>/dev/null | grep -oP "inet \K[0-9.]+"); [ -n "$ip" ] && echo "$ip" || { echo "нет IP"; false; }'

echo ""

# --- Tailscale ---

echo "Tailscale:"

if command -v tailscale >/dev/null 2>&1; then
    check_warn "tailscale установлен" \
        sh -c 'echo "да"'

    check_warn "tailscale IP" \
        sh -c 'ip=$(tailscale ip -4 2>/dev/null); [ -n "$ip" ] && echo "$ip" || { echo "нет IP"; false; }'

    check_warn "tailscale статус" \
        sh -c 'status=$(tailscale status --json 2>/dev/null | jsonfilter -e "$.BackendState" 2>/dev/null || tailscale status 2>&1 | head -1); [ -n "$status" ] && echo "$status" || { echo "unknown"; false; }'

    check_warn "tailscale0 интерфейс" \
        sh -c '[ -d /sys/class/net/tailscale0 ] && echo "да" || { echo "нет"; false; }'
else
    echo "  tailscale не установлен              [SKIP]"
fi

echo ""

# --- Интернет ---

echo "Интернет:"

check_warn "HTTP 204 (Cloudflare)" \
    sh -c 'code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" http://cp.cloudflare.com/generate_204); [ "$code" = "204" ] && echo "$code" || { echo "$code"; false; }'

echo ""

# --- Watchdog ---

echo "Watchdog:"

check_warn "/dev/watchdog" \
    sh -c '[ -c /dev/watchdog ] && echo "доступен" || { echo "нет"; false; }'

check_warn "bridgebox-watchdog сервис" \
    sh -c 'if [ -f /etc/init.d/bridgebox-watchdog ]; then
        enabled=$(/etc/init.d/bridgebox-watchdog enabled && echo "да" || echo "нет")
        echo "установлен, enabled=$enabled"
    else
        echo "не установлен"; false
    fi'

echo ""

# --- Итог ---

echo "=== Результат: $PASS ok, $FAIL fail, $WARN warn ==="

# Критический фейл — только bridge проблемы
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
