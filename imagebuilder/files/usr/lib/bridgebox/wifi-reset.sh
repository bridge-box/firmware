#!/bin/sh
# wifi-reset.sh — Сброс Wi-Fi и overlay
#
# Сбрасывает Wi-Fi настройки и overlay, возвращает коробку в setup mode.
# Юзер заново вводит Wi-Fi через CGI, overlay переприменяется автоматически.
#
# НЕ трогает: BOX_ID, Tailscale state, claim на backend, прошивку, boot state.

logger -t wifi-reset "Сброс Wi-Fi и overlay"

# --- 1. Остановить overlay сервисы (обратный порядок) ---

# DNS nfqueue rule
nft delete table inet bridgebox_dns 2>/dev/null || true

for svc in bridgebox-nfqdns bridgebox-zapret-fix zapret2 bridgebox-singbox bridgebox-rst-monitor; do
    if [ -f "/etc/init.d/$svc" ]; then
        /etc/init.d/$svc stop 2>/dev/null || true
        /etc/init.d/$svc disable 2>/dev/null || true
        logger -t wifi-reset "Остановлен: $svc"
    fi
done

killall nfqdns nfqws2 sing-box 2>/dev/null || true

# --- 2. Удалить overlay файлы ---

rm -rf /opt/zapret2
rm -rf /opt/singbox
rm -f /usr/bin/nfqdns
rm -rf /etc/nfqdns
rm -f /etc/init.d/zapret2
rm -f /etc/init.d/bridgebox-zapret-fix
rm -f /etc/init.d/bridgebox-nfqdns
rm -f /etc/init.d/bridgebox-singbox
rm -f /etc/init.d/bridgebox-rst-monitor
rm -f /etc/rc.d/*zapret2* /etc/rc.d/*bridgebox-zapret-fix*
rm -f /etc/rc.d/*bridgebox-nfqdns* /etc/rc.d/*bridgebox-singbox*
rm -f /etc/rc.d/*bridgebox-rst-monitor*
rm -rf /opt/bridgebox/bundle

# nft таблицы overlay
nft delete table inet zapret2 2>/dev/null || true
nft delete table inet nfqdns 2>/dev/null || true

# Overlay state
rm -f /etc/bridgebox/overlay-version
rm -f /etc/bridgebox/overlay-status
rm -f /etc/bridgebox/overlay-service

logger -t wifi-reset "Overlay удалён"

# --- 3. Разобрать bridge ---

ip link set eth0 nomaster 2>/dev/null || true
ip link set eth1 nomaster 2>/dev/null || true
ip link set br0 down 2>/dev/null || true
ip link delete br0 2>/dev/null || true

logger -t wifi-reset "Bridge разобран"

# --- 4. Сбросить Wi-Fi ---

rm -f /etc/bridgebox/wpa.conf
killall wpa_supplicant 2>/dev/null || true

# Опускаем wlan0
ip link set wlan0 down 2>/dev/null || true

echo "down" > /etc/bridgebox/wifi-mode
echo "setup" > /etc/bridgebox/state

logger -t wifi-reset "Wi-Fi сброшен, state=setup"

# --- 5. Перезапуск agent ---
# Agent стартует в setup mode: management через eth0 DHCP, bridge отложен

if [ -f /etc/init.d/bridgebox-agent ]; then
    /etc/init.d/bridgebox-agent restart 2>/dev/null || true
fi

logger -t wifi-reset "Сброс завершён — ожидание настройки Wi-Fi через CGI"
