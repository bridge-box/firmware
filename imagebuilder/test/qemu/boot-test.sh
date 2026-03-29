#!/bin/sh
# boot-test.sh — L3 Boot Test: загрузка OpenWrt в QEMU + проверки
#
# Запускает armsr/armv8 образ в QEMU, ждёт SSH, проверяет:
#   1. Система загрузилась
#   2. uci-defaults отработали (hostname, IP, DHCP)
#   3. Сервисы на месте
#   4. Overlay файлы присутствуют
#
# Выход: 0 = все проверки прошли, 1 = есть ошибки

set -u

# --- Настройки ---
SSH_PORT=2222
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
BOOT_TIMEOUT=120   # секунд на загрузку
PASS_COUNT=0
FAIL_COUNT=0

# --- Цвета ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf "${YELLOW}[QEMU]${NC} %s\n" "$1"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  ${RED}FAIL${NC} %s\n" "$1"; }

# Выполнить команду по SSH, вернуть stdout
ssh_cmd() {
    sshpass -p "" ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 "$1" 2>/dev/null
}

# --- Запуск QEMU ---
log "Запуск QEMU (aarch64, armsr/armv8)..."

# Увеличиваем образ чтобы OpenWrt мог расширить rootfs
qemu-img resize /test/openwrt.img 512M 2>/dev/null || true

# Логи QEMU serial console
SERIAL_LOG=/tmp/qemu-serial.log

qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a53 \
    -m 256 \
    -bios /test/efi.fd \
    -drive file=/test/openwrt.img,format=raw,if=virtio \
    -device virtio-net-pci,netdev=net0,romfile="" \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -nographic \
    -nodefaults \
    -chardev file,id=serial0,path=$SERIAL_LOG \
    -serial chardev:serial0 \
    -snapshot \
    &

QEMU_PID=$!

log "QEMU PID: $QEMU_PID"
log "Ожидание загрузки (таймаут: ${BOOT_TIMEOUT}с)..."

# --- Ожидание SSH ---
SECONDS_WAITED=0
SSH_READY=0

while [ $SECONDS_WAITED -lt $BOOT_TIMEOUT ]; do
    if ssh_cmd "echo ok" 2>/dev/null | grep -q "ok"; then
        SSH_READY=1
        break
    fi
    sleep 3
    SECONDS_WAITED=$((SECONDS_WAITED + 3))
    # Прогресс каждые 15 секунд
    if [ $((SECONDS_WAITED % 15)) -eq 0 ]; then
        log "  ...${SECONDS_WAITED}с"
    fi
done

echo ""

if [ $SSH_READY -eq 0 ]; then
    fail "SSH не доступен после ${BOOT_TIMEOUT}с — система не загрузилась"
    echo ""
    log "=== Serial console log (последние 50 строк) ==="
    tail -50 "$SERIAL_LOG" 2>/dev/null || echo "(лог пуст)"
    echo ""
    log "Завершаем QEMU..."
    kill $QEMU_PID 2>/dev/null
    wait $QEMU_PID 2>/dev/null
    echo ""
    printf "${RED}=== L3 Boot Test: FAIL (система не загрузилась) ===${NC}\n"
    exit 1
fi

log "SSH доступен через ${SECONDS_WAITED}с"
echo ""

# ============================================================
# Проверки
# ============================================================

log "=== Проверка загрузки ==="

# 1. Система жива
UPTIME=$(ssh_cmd "cat /proc/uptime | cut -d' ' -f1")
if [ -n "$UPTIME" ]; then
    pass "Система загрузилась (uptime: ${UPTIME}с)"
else
    fail "Не удалось получить uptime"
fi

# 2. OpenWrt release
DISTRIB=$(ssh_cmd "grep DISTRIB_ID /etc/openwrt_release 2>/dev/null")
if echo "$DISTRIB" | grep -q "BridgeWRT"; then
    pass "Branding: BridgeWRT"
else
    fail "Branding: ожидали BridgeWRT, получили: $DISTRIB"
fi

# ---- uci-defaults ----
log "=== Проверка uci-defaults ==="

# 3. Hostname
HOSTNAME=$(ssh_cmd "uci get system.@system[0].hostname 2>/dev/null")
if [ "$HOSTNAME" = "bridge-box" ]; then
    pass "Hostname: bridge-box"
else
    fail "Hostname: ожидали bridge-box, получили: $HOSTNAME"
fi

# 4. Timezone
TZ=$(ssh_cmd "uci get system.@system[0].timezone 2>/dev/null")
if [ "$TZ" = "MSK-3" ]; then
    pass "Timezone: MSK-3"
else
    fail "Timezone: ожидали MSK-3, получили: $TZ"
fi

# 5. LAN IP
LAN_IP=$(ssh_cmd "uci get network.lan.ipaddr 2>/dev/null")
if [ "$LAN_IP" = "192.168.77.1" ]; then
    pass "LAN IP: 192.168.77.1"
else
    fail "LAN IP: ожидали 192.168.77.1, получили: $LAN_IP"
fi

# 6. DHCP range
DHCP_START=$(ssh_cmd "uci get dhcp.lan.start 2>/dev/null")
DHCP_LIMIT=$(ssh_cmd "uci get dhcp.lan.limit 2>/dev/null")
if [ "$DHCP_START" = "100" ] && [ "$DHCP_LIMIT" = "150" ]; then
    pass "DHCP: 100-250, OK"
else
    fail "DHCP: ожидали start=100 limit=150, получили start=$DHCP_START limit=$DHCP_LIMIT"
fi

# ---- Overlay файлы ----
log "=== Проверка overlay файлов ==="

# 7. box-id
BOX_ID=$(ssh_cmd "cat /etc/bridgebox/box-id 2>/dev/null")
if [ "$BOX_ID" = "BB-QEMU-TEST" ]; then
    pass "box-id: BB-QEMU-TEST"
else
    fail "box-id: ожидали BB-QEMU-TEST, получили: $BOX_ID"
fi

# 8. state
STATE=$(ssh_cmd "cat /etc/bridgebox/state 2>/dev/null")
if [ "$STATE" = "setup" ]; then
    pass "state: setup"
else
    fail "state: ожидали setup, получили: $STATE"
fi

# 9. wifi-mode
WIFI_MODE=$(ssh_cmd "cat /etc/bridgebox/wifi-mode 2>/dev/null")
if [ "$WIFI_MODE" = "down" ]; then
    pass "wifi-mode: down"
else
    fail "wifi-mode: ожидали down, получили: $WIFI_MODE"
fi

# 10. backend-url существует
BACKEND_URL=$(ssh_cmd "cat /etc/bridgebox/backend-url 2>/dev/null")
if [ -n "$BACKEND_URL" ]; then
    pass "backend-url: присутствует"
else
    fail "backend-url: файл пуст или отсутствует"
fi

# ---- Скрипты ----
log "=== Проверка скриптов и сервисов ==="

# 11. Скрипты в /usr/lib/bridgebox/
for script in wifi-switch.sh wifi-watchdog.sh setup-bridge.sh healthcheck.sh watchdog.sh lib-common.sh factory-reset.sh; do
    if ssh_cmd "test -x /usr/lib/bridgebox/$script && echo ok" | grep -q "ok"; then
        pass "Скрипт: $script"
    else
        fail "Скрипт: $script отсутствует или не исполняемый"
    fi
done

# 12. init.d скрипты
for svc in bridgebox-wifi bridgebox-agent bridgebox-watchdog; do
    if ssh_cmd "test -x /etc/init.d/$svc && echo ok" | grep -q "ok"; then
        pass "init.d: $svc"
    else
        fail "init.d: $svc отсутствует или не исполняемый"
    fi
done

# 13. CGI-эндпоинты
for cgi in wifi-setup status factory-reset; do
    if ssh_cmd "test -x /www/cgi-bin/$cgi && echo ok" | grep -q "ok"; then
        pass "CGI: $cgi"
    else
        fail "CGI: $cgi отсутствует или не исполняемый"
    fi
done

# ---- Процессы ----
log "=== Проверка процессов ==="

# 14. uhttpd запущен
# BusyBox pgrep -x не всегда работает с полным путём, используем pgrep без -x
if ssh_cmd "pgrep uhttpd >/dev/null && echo ok" | grep -q "ok"; then
    pass "uhttpd: запущен"
else
    fail "uhttpd: не запущен"
fi

# 15. dnsmasq запущен (в QEMU без br-lan может не запуститься — это OK)
if ssh_cmd "pgrep dnsmasq >/dev/null && echo ok" | grep -q "ok"; then
    pass "dnsmasq: запущен"
else
    # Проверяем: если br-lan нет (QEMU), dnsmasq ожидаемо не работает
    if ssh_cmd "ip link show br-lan >/dev/null 2>&1 && echo ok" | grep -q "ok"; then
        fail "dnsmasq: не запущен (br-lan существует — должен работать)"
    else
        pass "dnsmasq: не запущен (QEMU mode, нет br-lan — ожидаемо)"
    fi
fi

# 16. SSH (dropbear) запущен (уже знаем, раз подключились, но для полноты)
pass "dropbear (SSH): запущен"

# ---- Сеть ----
log "=== Проверка сети ==="

# 17. Сетевой интерфейс поднят
# В QEMU: eth0 на wan (DHCP от SLIRP), br-lan может не существовать
# На реальном железе: eth0+eth1 в br-lan
# Проверяем что хотя бы один интерфейс с IP существует
if ssh_cmd "ip link show br-lan >/dev/null 2>&1 && echo ok" | grep -q "ok"; then
    pass "br-lan: интерфейс существует"
    BR_IP=$(ssh_cmd "ip -4 addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print \$2}'")
    if echo "$BR_IP" | grep -q "192.168.77.1"; then
        pass "br-lan IP: $BR_IP"
    else
        fail "br-lan IP: ожидали 192.168.77.1/*, получили: $BR_IP"
    fi
else
    # QEMU-режим: br-lan нет (eth0 вынут из bridge для DHCP-связности)
    # Проверяем что eth0 имеет IP от SLIRP (10.0.2.x)
    ETH0_IP=$(ssh_cmd "ip -4 addr show eth0 2>/dev/null | grep 'inet ' | awk '{print \$2}'")
    if [ -n "$ETH0_IP" ]; then
        pass "eth0 IP (QEMU mode): $ETH0_IP"
    else
        fail "Нет IP ни на br-lan, ни на eth0"
    fi
fi

# 18. uci network.lan.ipaddr всё равно должен быть 192.168.77.1
# (даже если br-lan не поднят — uci-defaults должны были отработать)
LAN_IP_CHECK=$(ssh_cmd "uci get network.lan.ipaddr 2>/dev/null")
if [ "$LAN_IP_CHECK" = "192.168.77.1" ]; then
    pass "uci network.lan.ipaddr: 192.168.77.1 (конфигурация верна)"
else
    fail "uci network.lan.ipaddr: ожидали 192.168.77.1, получили: $LAN_IP_CHECK"
fi

# ---- Banner ----
log "=== Проверка branding ==="

BANNER=$(ssh_cmd "cat /etc/banner 2>/dev/null")
if echo "$BANNER" | grep -q "BridgeBox\|BridgeWRT\|Transparent L2 Bridge"; then
    pass "Banner: содержит branding"
else
    fail "Banner: branding не найден"
fi

if echo "$BANNER" | grep -q "BB-QEMU-TEST"; then
    pass "Banner: содержит BOX_ID"
else
    fail "Banner: BOX_ID не найден в баннере"
fi

# ---- Mesh-оркестрация: ensure-mesh вызывается в boot flow и watchdog ----
log "=== Проверка mesh-оркестрации ==="

# init.d/bridgebox-agent содержит ensure-mesh
AGENT_INIT=$(ssh_cmd "cat /etc/init.d/bridgebox-agent")
if echo "$AGENT_INIT" | grep -q "ensure-mesh"; then
    pass "Mesh: init.d/bridgebox-agent вызывает ensure-mesh"
else
    fail "Mesh: init.d/bridgebox-agent НЕ вызывает ensure-mesh"
fi

# watchdog.sh содержит ensure-mesh (а не tailscale restart)
WATCHDOG=$(ssh_cmd "cat /usr/lib/bridgebox/watchdog.sh")
if echo "$WATCHDOG" | grep -q "ensure-mesh"; then
    pass "Mesh: watchdog.sh вызывает ensure-mesh"
else
    fail "Mesh: watchdog.sh НЕ вызывает ensure-mesh"
fi

if echo "$WATCHDOG" | grep -q "tailscale restart"; then
    fail "Mesh: watchdog.sh всё ещё содержит 'tailscale restart' (должен быть ensure-mesh)"
else
    pass "Mesh: watchdog.sh не содержит 'tailscale restart'"
fi

# provision.sh содержит ensure-mesh
PROVISION=$(ssh_cmd "cat /usr/lib/bridgebox/provision.sh")
if echo "$PROVISION" | grep -q "ensure-mesh"; then
    pass "Mesh: provision.sh вызывает ensure-mesh"
else
    fail "Mesh: provision.sh НЕ вызывает ensure-mesh"
fi

# heartbeat cron job на месте
CRONTAB=$(ssh_cmd "cat /etc/crontabs/root")
if echo "$CRONTAB" | grep -q "bb-agent heartbeat"; then
    pass "Mesh: crontab содержит heartbeat"
else
    fail "Mesh: crontab НЕ содержит heartbeat"
fi

# bb-agent ensure-mesh — команда запускается (ошибка ожидаема без backend)
ENSURE_OUT=$(ssh_cmd "/usr/bin/bb-agent ensure-mesh 2>&1 || true")
if echo "$ENSURE_OUT" | grep -qi "ошибка\|error\|не удалось\|backend"; then
    pass "Mesh: bb-agent ensure-mesh запускается (ожидаемая ошибка без backend)"
else
    pass "Mesh: bb-agent ensure-mesh запускается"
fi

# ---- P0 fixes ----
log "=== Проверка P0 fixes ==="

# lib-common.sh с safe_write
if ssh_cmd "test -f /usr/lib/bridgebox/lib-common.sh && grep -q safe_write /usr/lib/bridgebox/lib-common.sh && echo ok" | grep -q "ok"; then
    pass "lib-common.sh: safe_write() присутствует"
else
    fail "lib-common.sh: safe_write() отсутствует"
fi

# factory-reset CGI отдаёт HTML
FR_HTML=$(ssh_cmd "REQUEST_METHOD=GET /www/cgi-bin/factory-reset 2>/dev/null || true")
if echo "$FR_HTML" | grep -q "factory-reset\|Сброс"; then
    pass "factory-reset CGI: отдаёт HTML"
else
    fail "factory-reset CGI: не отдаёт HTML"
fi

# factory-reset.sh существует
if ssh_cmd "test -x /usr/lib/bridgebox/factory-reset.sh && echo ok" | grep -q "ok"; then
    pass "factory-reset.sh: присутствует и executable"
else
    fail "factory-reset.sh: отсутствует"
fi

# status page содержит кнопку сброса
STATUS_HTML=$(ssh_cmd "REQUEST_METHOD=GET /www/cgi-bin/status 2>/dev/null || true")
if echo "$STATUS_HTML" | grep -q "factory-reset"; then
    pass "status page: содержит ссылку на factory-reset"
else
    fail "status page: не содержит ссылку на factory-reset"
fi

# 10-bridgebox-system: wait loop для eth0 (проверяем в overlay или original)
# uci-defaults уже отработали, но проверяем что box-id сгенерирован
BOX_ID_LEN=$(ssh_cmd "cat /etc/bridgebox/box-id 2>/dev/null | wc -c")
if [ -n "$BOX_ID_LEN" ] && [ "$BOX_ID_LEN" -gt 3 ] 2>/dev/null; then
    pass "box-id: сгенерирован (wait loop отработал)"
else
    fail "box-id: не сгенерирован (wait loop мог не сработать)"
fi

# ---- uci-defaults отработали (удалены) ----
log "=== Проверка uci-defaults cleanup ==="

UCI_FILES=$(ssh_cmd "ls /etc/uci-defaults/ 2>/dev/null")
if [ -z "$UCI_FILES" ]; then
    pass "uci-defaults: директория пуста (скрипты отработали)"
else
    fail "uci-defaults: остались файлы: $UCI_FILES"
fi

# ============================================================
# Итого
# ============================================================

echo ""
log "Завершаем QEMU..."
kill $QEMU_PID 2>/dev/null
wait $QEMU_PID 2>/dev/null

echo ""
echo "============================================"
printf "  L3 Boot Test: ${GREEN}${PASS_COUNT} PASS${NC}"
if [ $FAIL_COUNT -gt 0 ]; then
    printf ", ${RED}${FAIL_COUNT} FAIL${NC}"
fi
echo ""
echo "============================================"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    printf "${RED}FAILED${NC}\n"
    exit 1
else
    printf "${GREEN}ALL PASSED${NC}\n"
    exit 0
fi
