#!/bin/sh
# healthcheck.sh — Проверка состояния коробки
#
# Проверяет два слоя:
#   1. Management plane: wlan0, Tailscale
#   2. Data plane: bridge (br0), порты eth0/eth1
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

# --- Management Plane ---

echo "Management Plane:"

check_warn "wlan0 существует" \
    sh -c '[ -d /sys/class/net/wlan0 ] && echo "да" || { echo "нет"; false; }'

check_warn "wlan0 состояние" \
    sh -c 'state=$(cat /sys/class/net/wlan0/operstate 2>/dev/null); [ "$state" = "up" ] && echo "$state" || { echo "${state:-unknown}"; false; }'

check_warn "wlan0 IP" \
    sh -c 'ip=$(ip -4 addr show wlan0 2>/dev/null | awk "/inet /{split(\$2,a,\"/\"); print a[1]}"); [ -n "$ip" ] && echo "$ip" || { echo "нет IP"; false; }'

echo ""

echo "Tailscale:"

if command -v tailscale >/dev/null 2>&1; then
    check_warn "tailscale установлен" \
        sh -c 'echo "да"'

    check_warn "tailscale IP" \
        sh -c 'ip=$(tailscale ip -4 2>/dev/null); [ -n "$ip" ] && echo "$ip" || { echo "нет IP"; false; }'

    check_warn "tailscale статус" \
        sh -c 'status=$(tailscale status --json 2>/dev/null | jsonfilter -e "$.BackendState" 2>/dev/null || tailscale status 2>&1 | head -1); [ -n "$status" ] && echo "$status" || { echo "unknown"; false; }'
else
    echo "  tailscale не установлен              [SKIP]"
fi

echo ""

# --- Data Plane ---

echo "Data Plane:"

if [ -d /sys/class/net/br0 ]; then
    check "br0 существует" \
        sh -c 'echo "да"'

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
else
    echo "  br0 не настроен                      [SKIP]"
fi

echo ""

# --- Идентичность ---

echo "Система:"

check_warn "BOX_ID" \
    sh -c 'id=$(cat /etc/bridgebox/box-id 2>/dev/null); [ -n "$id" ] && [ "$id" != "TEMPLATE" ] && echo "$id" || { echo "${id:-не задан}"; false; }'

check_warn "Состояние" \
    sh -c 'state=$(cat /etc/bridgebox/state 2>/dev/null); [ -n "$state" ] && echo "$state" || { echo "не задано"; false; }'

check_warn "Safe mode" \
    sh -c '[ -f /etc/bridgebox/safe-mode ] && { echo "АКТИВЕН"; false; } || echo "нет"'

check_warn "Boot failures" \
    sh -c 'n=$(cat /etc/bridgebox/boot-failures 2>/dev/null || echo "0"); echo "$n"; [ "$n" -lt 3 ] || false'

echo ""

# --- Интернет ---

echo "Интернет:"

check_warn "HTTP 204 (Cloudflare)" \
    sh -c 'code=$(wget -q --spider -S -T 5 http://cp.cloudflare.com/generate_204 2>&1 | grep "HTTP/" | awk "{print \$2}"); [ "$code" = "204" ] && echo "$code" || { echo "${code:-timeout}"; false; }'

echo ""

# --- Итог ---

echo "=== Результат: $PASS ok, $FAIL fail, $WARN warn ==="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
