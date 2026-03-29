#!/bin/sh
# factory-reset.sh — Сброс коробки к заводским настройкам
# Очищает state, сбрасывает overlay, перезагружает

logger -t bridgebox "Factory reset запущен"

# Очищаем state файлы BridgeBox
rm -f /etc/bridgebox/state
rm -f /etc/bridgebox/wifi-mode
rm -f /etc/bridgebox/wpa.conf
rm -f /etc/bridgebox/claim-token

# Сброс overlay к squashfs (стандартный OpenWrt factory reset)
firstboot -y 2>/dev/null

logger -t bridgebox "Factory reset завершён, перезагрузка..."
reboot
