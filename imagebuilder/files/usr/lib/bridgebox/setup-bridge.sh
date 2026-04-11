#!/bin/sh
# setup-bridge.sh — Настройка прозрачного L2 моста на OpenWrt 25.12
#
# Превращает NanoPi R2S/R3S в прозрачный мост между eth0 (WAN) и eth1 (LAN).
# Коробка пропускает весь трафик на L2, для сети невидима.
#
# Management — ТОЛЬКО через Wi-Fi (wlan0) → Tailscale mesh.
# br0 без IP (proto=none) — полностью стерильный мост.
# Wi-Fi (bridgebox-wifi) НЕ затрагивается этим скриптом.
#
# Скрипт идемпотентный — безопасно запускать повторно.
#
# Использование: sh setup-bridge.sh
# Rollback:      firstboot && reboot

# --- Проверки ---

if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запускать от root" >&2
    exit 1
fi

if ! command -v uci >/dev/null 2>&1; then
    echo "Ошибка: uci не найден, это не OpenWrt?" >&2
    exit 1
fi

echo "=== BridgeBox: настройка прозрачного моста ==="
echo ""
echo "Bridge: eth0 + eth1 (L2, без IP)"
echo "Management: wlan0 → Tailscale (не затрагивается)"
echo ""

# --- Шаг 1: Очистка существующих интерфейсов ---

echo "[1/8] Очистка существующих интерфейсов..."

# Удаляем именованные интерфейсы (wan, wan6, lan и т.д.)
for iface in wan wan6 lan lan6; do
    if uci -q get network."$iface" >/dev/null 2>&1; then
        uci delete network."$iface"
        echo "  Удалён интерфейс: $iface"
    fi
done

# Удаляем интерфейс bridge (если скрипт запускается повторно)
if uci -q get network.bridge >/dev/null 2>&1; then
    uci delete network.bridge
    echo "  Удалён интерфейс: bridge (от предыдущего запуска)"
fi

# --- Шаг 2: Очистка device-секций ---

echo "[2/8] Очистка device-секций..."

# Удаляем именованную секцию br0 (если скрипт запускается повторно)
if uci -q get network.br0 >/dev/null 2>&1; then
    uci delete network.br0
    echo "  Удалён device: br0 (от предыдущего запуска)"
fi

# Удаляем все безымянные device-секции (@device[0], @device[1], ...)
# OpenWrt 25.12 создаёт их по умолчанию для br-lan, eth0, eth1
while uci -q get network.@device[0] >/dev/null 2>&1; do
    devname=$(uci -q get network.@device[0].name 2>/dev/null || echo "unknown")
    uci delete network.@device[0]
    echo "  Удалён device: $devname"
done

# --- Шаг 3: Создание bridge device ---

echo "[3/8] Создание bridge device br0 (eth0 + eth1)..."

uci set network.br0=device
uci set network.br0.name='br0'
uci set network.br0.type='bridge'
uci add_list network.br0.ports='eth0'
uci add_list network.br0.ports='eth1'
# STP выключен — мост между двумя портами, петель нет
uci set network.br0.stp='0'

# --- Шаг 4: Создание интерфейса bridge БЕЗ IP (стерильный мост) ---

echo "[4/8] Создание интерфейса bridge (proto=none, без IP)..."

uci set network.bridge=interface
uci set network.bridge.device='br0'
uci set network.bridge.proto='none'

# --- Шаг 5: Отключение ненужных служб ---

echo "[5/8] Отключение ненужных служб..."

# odhcpd — IPv6 DHCP/RA сервер, не нужен на мосту
if [ -f /etc/init.d/odhcpd ]; then
    /etc/init.d/odhcpd stop 2>/dev/null || true
    /etc/init.d/odhcpd disable 2>/dev/null || true
    echo "  odhcpd: остановлен и отключён"
fi

# НЕ трогаем dnsmasq — он нужен для Wi-Fi AP mode (captive portal)
echo "  dnsmasq: не трогаем (используется Wi-Fi AP mode)"

# Перезагружаем nftables правила (QUIC drop, flow offload, nfqdns)
/etc/init.d/bridgebox-nftables reload 2>/dev/null || true
echo "  nftables: правила перезагружены"

# --- Шаг 6: Применение ---

echo "[6/8] Применение конфигурации..."

uci commit network

echo ""
echo "=== Конфигурация сохранена ==="
echo ""

# Выводим итоговый конфиг для контроля
echo "Итоговая конфигурация:"
uci show network | grep -v '^network.loopback' | grep -v '^network.globals'
echo ""

# --- Шаг 7: LAN LED → bridge activity ---

echo "[7/8] Настройка LAN LED на bridge activity..."

if uci -q get system.led_lan >/dev/null 2>&1; then
    uci set system.led_lan.trigger='netdev'
    uci set system.led_lan.dev='br0'
    uci set system.led_lan.mode='link tx rx'
    uci commit system
    /etc/init.d/led restart 2>/dev/null || true
    echo "  LAN LED: br0 link+activity"
else
    echo "  LAN LED: не настроен (нет led_lan в uci)"
fi

# --- Шаг 8: Включение сервисов ---

echo "[8/8] Активация боевого режима..."

# Включаем bridgebox-сервисы
for svc in bridgebox-wifi bridgebox-agent; do
    if [ -f "/etc/init.d/$svc" ]; then
        /etc/init.d/$svc enable
        echo "  $svc: включён"
    fi
done

echo ""
echo "Перезагрузка сети..."
echo ""
echo "После перезагрузки:"
echo "  - Мост: eth0 ↔ eth1 (прозрачный, без IP)"
echo "  - Management: wlan0 → Tailscale"
echo "  - Статус: http://192.168.77.1/ (через Wi-Fi AP)"
echo ""
echo "Проверки:"
echo "  bridge link              — eth0 и eth1 в br0"
echo "  ip addr show wlan0       — management IP (Wi-Fi)"
echo "  wifi-switch.sh status    — режим Wi-Fi (ap/sta)"
echo ""
echo "Rollback: firstboot && reboot"
echo ""

# Перезагрузка сети (только ethernet, Wi-Fi не затрагивается)
/etc/init.d/network restart
