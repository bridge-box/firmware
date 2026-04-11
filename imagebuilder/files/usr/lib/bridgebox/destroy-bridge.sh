#!/bin/sh
# destroy-bridge.sh — Откат bridge к setup mode
#
# Разбирает br0, возвращает eth1 как standalone LAN management.
# Идемпотентный — безопасно запускать повторно.

echo "=== BridgeBox: откат bridge ==="

# Удаляем bridge интерфейс
if uci -q get network.bridge >/dev/null 2>&1; then
    uci delete network.bridge
    echo "  Удалён интерфейс: bridge"
fi

# Удаляем bridge device
if uci -q get network.br0 >/dev/null 2>&1; then
    uci delete network.br0
    echo "  Удалён device: br0"
fi

# Восстанавливаем LAN (eth1 = management)
uci set network.lan=interface
uci set network.lan.device='eth1'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.77.1'
uci set network.lan.netmask='255.255.255.0'

# Восстанавливаем WAN (eth0 = proto none)
uci set network.wan=interface
uci set network.wan.device='eth0'
uci set network.wan.proto='none'

uci commit network

# LAN LED — выключаем (нет bridge)
if uci -q get system.led_lan >/dev/null 2>&1; then
    uci set system.led_lan.trigger='none'
    uci set system.led_lan.default='0'
    uci commit system
    /etc/init.d/led restart 2>/dev/null || true
fi

# State
echo 'setup' > /etc/bridgebox/state

echo "  Перезагрузка сети..."
/etc/init.d/network restart

echo "=== Bridge откачен ==="
