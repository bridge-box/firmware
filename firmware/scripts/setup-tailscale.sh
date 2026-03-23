#!/bin/sh
# setup-tailscale.sh — Установка и подключение Tailscale к Headscale
#
# Коробка подключается к mesh-сети для удалённого администрирования.
# Tailscale используется ТОЛЬКО для management (SSH, обновления).
# Пользовательский трафик идёт через мост, не через Tailscale.
#
# Скрипт идемпотентный — безопасно запускать повторно.
#
# Использование:
#   sh setup-tailscale.sh <login-server-url> <auth-key>
#
# Пример:
#   sh setup-tailscale.sh https://headscale.example.com abc123
#
# Требования:
#   - Интернет (коробка подключена в LAN роутера)
#   - OpenWrt 25.12+ (apk)

set -e

# --- Параметры ---

LOGIN_SERVER="${1:-}"
AUTH_KEY="${2:-}"

if [ -z "$LOGIN_SERVER" ] || [ -z "$AUTH_KEY" ]; then
    echo "Использование: $0 <login-server-url> <auth-key>" >&2
    echo "" >&2
    echo "  login-server-url  URL Headscale сервера" >&2
    echo "  auth-key          Pre-authentication key" >&2
    exit 1
fi

# --- Проверки ---

if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запускать от root" >&2
    exit 1
fi

if ! command -v apk >/dev/null 2>&1; then
    echo "Ошибка: apk не найден, это не OpenWrt 25.12+?" >&2
    exit 1
fi

# Проверка интернета
echo "Проверка интернета..."
if ! curl -s --max-time 5 -o /dev/null http://cp.cloudflare.com/generate_204; then
    echo "Ошибка: нет интернета. Подключите коробку в LAN роутера." >&2
    exit 1
fi

echo "=== BridgeBox: установка Tailscale ==="
echo ""

# --- Шаг 1: Установка пакета ---

echo "[1/5] Установка tailscale..."

if command -v tailscale >/dev/null 2>&1; then
    echo "  tailscale уже установлен, пропускаем"
else
    apk update
    apk add tailscale
    echo "  tailscale установлен"
fi

# --- Шаг 2: Включение и запуск сервиса ---

echo "[2/5] Запуск сервиса tailscaled..."

if [ -f /etc/init.d/tailscale ]; then
    /etc/init.d/tailscale enable
    /etc/init.d/tailscale start 2>/dev/null || /etc/init.d/tailscale restart
    echo "  tailscale сервис включён и запущен"
else
    echo "Ошибка: /etc/init.d/tailscale не найден после установки" >&2
    exit 1
fi

# Даём tailscaled время подняться
sleep 2

# --- Шаг 3: Подключение к Headscale ---

echo "[3/5] Подключение к Headscale..."

tailscale up \
    --login-server="$LOGIN_SERVER" \
    --authkey="$AUTH_KEY" \
    --accept-routes=false \
    --advertise-routes="" \
    --ssh

echo "  Подключение инициировано"

# --- Шаг 4: Ожидание Tailscale IP ---

echo "[4/5] Ожидание Tailscale IP..."

MAX_WAIT=30
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    TS_IP=$(tailscale ip -4 2>/dev/null || true)
    if [ -n "$TS_IP" ]; then
        echo "  Tailscale IP: $TS_IP"
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ -z "$TS_IP" ]; then
    echo "Ошибка: не удалось получить Tailscale IP за ${MAX_WAIT}с" >&2
    echo "Проверьте: tailscale status" >&2
    exit 1
fi

# --- Шаг 5: Настройка firewall для SSH ---

echo "[5/5] Настройка firewall: SSH только через tailscale0..."

# nftables: разрешаем SSH только на tailscale0, блокируем на остальных
nft flush ruleset 2>/dev/null || true
nft -f - <<'NFTABLES'
table inet bridgebox_mgmt {
    chain input {
        type filter hook input priority 0; policy accept;

        # Разрешаем SSH на tailscale0
        iifname "tailscale0" tcp dport 22 accept

        # Блокируем SSH на всех остальных интерфейсах
        tcp dport 22 drop
    }
}
NFTABLES

echo "  SSH ограничен интерфейсом tailscale0"

# --- Итог ---

echo ""
echo "=== Tailscale настроен ==="
echo ""
echo "  Tailscale IP: $TS_IP"
echo "  Login server: $LOGIN_SERVER"
echo "  SSH:          только через tailscale0"
echo ""
echo "Проверки:"
echo "  tailscale status       — статус подключения"
echo "  tailscale ip -4        — Tailscale IP"
echo "  ssh root@$TS_IP        — подключение через mesh"
echo ""
echo "Следующий шаг:"
echo "  Установите init.d/bridgebox-management для автозапуска"
