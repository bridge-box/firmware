#!/bin/sh
# setup-bridge.sh — Настройка прозрачного L2 моста на OpenWrt 25.12
#
# Превращает NanoPi R2S/R3S в прозрачный мост между eth0 (WAN) и eth1 (LAN).
# Коробка пропускает весь трафик на L2, для сети невидима.
# Management IP получает по DHCP на br0.
#
# Скрипт идемпотентный — безопасно запускать повторно.
# Работает на чистой OpenWrt 25.12 с дефолтной конфигурацией.
#
# ВНИМАНИЕ: после применения SSH-сессия оборвётся.
# Переподключаться по IP, который коробка получит по DHCP
# (смотреть в роутере или nmap -sn <подсеть>).
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
echo "ВНИМАНИЕ: SSH-сессия оборвётся после применения!"
echo "Переподключайтесь по новому IP (DHCP от вышестоящего роутера)."
echo ""

# --- Шаг 1: Очистка существующих интерфейсов ---

echo "[1/6] Очистка существующих интерфейсов..."

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

echo "[2/6] Очистка device-секций..."

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

echo "[3/6] Создание bridge device br0 (eth0 + eth1)..."

uci set network.br0=device
uci set network.br0.name='br0'
uci set network.br0.type='bridge'
uci add_list network.br0.ports='eth0'
uci add_list network.br0.ports='eth1'
# STP выключен — мост между двумя портами, петель нет
uci set network.br0.stp='0'

# --- Шаг 4: Создание интерфейса bridge с DHCP (management) ---

echo "[4/6] Создание интерфейса bridge (DHCP для management)..."

uci set network.bridge=interface
uci set network.bridge.device='br0'
uci set network.bridge.proto='dhcp'

# --- Шаг 5: Отключение ненужных служб ---

echo "[5/6] Отключение ненужных служб..."

# dnsmasq — коробка не раздаёт DNS/DHCP, всё транзитом через мост
if [ -f /etc/init.d/dnsmasq ]; then
    /etc/init.d/dnsmasq stop 2>/dev/null || true
    /etc/init.d/dnsmasq disable 2>/dev/null || true
    echo "  dnsmasq: остановлен и отключён"
fi

# firewall — трафик идёт транзитом на L2, файрвол не нужен
if [ -f /etc/init.d/firewall ]; then
    /etc/init.d/firewall stop 2>/dev/null || true
    /etc/init.d/firewall disable 2>/dev/null || true
    echo "  firewall: остановлен и отключён"
fi

# odhcpd — IPv6 DHCP/RA сервер, не нужен на мосту
if [ -f /etc/init.d/odhcpd ]; then
    /etc/init.d/odhcpd stop 2>/dev/null || true
    /etc/init.d/odhcpd disable 2>/dev/null || true
    echo "  odhcpd: остановлен и отключён"
fi

# Очистка nftables (файрвол мог оставить правила)
nft flush ruleset 2>/dev/null || true

# --- Шаг 6: Применение ---

echo "[6/6] Применение конфигурации..."

uci commit network

echo ""
echo "=== Конфигурация сохранена ==="
echo ""

# Выводим итоговый конфиг для контроля
echo "Итоговая конфигурация:"
uci show network | grep -v '^network.loopback' | grep -v '^network.globals'
echo ""

echo "Перезагрузка сети..."
echo "SSH-сессия сейчас оборвётся."
echo ""
echo "После перезагрузки:"
echo "  1. Подключите eth0 к провайдеру/роутеру, eth1 к домашнему роутеру"
echo "  2. Найдите новый IP коробки в DHCP-таблице роутера"
echo "  3. Или: nmap -sn <подсеть вашего роутера>"
echo "  4. SSH root@<новый_IP>"
echo ""
echo "Проверки:"
echo "  bridge link              — eth0 и eth1 в br0"
echo "  ip addr show br0         — management IP"
echo ""
echo "Rollback: firstboot && reboot"
echo ""

# Перезагрузка сети
/etc/init.d/network restart
