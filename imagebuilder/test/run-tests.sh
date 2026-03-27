#!/bin/sh
# run-tests.sh — Интеграционные тесты прошивки в Docker
#
# Прогоняет реальные скрипты через мокнутое окружение.
# Каждый тест = сценарий из жизни коробки.

PASS=0
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() {
    PASS=$((PASS + 1))
    printf "  ${GREEN}✓${NC} %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "  ${RED}✗${NC} %s\n" "$1"
    # Показываем лог для дебага
    if [ -f /tmp/mock-syslog.log ]; then
        printf "    ${RED}Лог:${NC}\n"
        tail -5 /tmp/mock-syslog.log | sed 's/^/    /'
    fi
}

section() {
    printf "\n${CYAN}=== %s ===${NC}\n" "$1"
}

# /sys read-only в Docker — используем /mock-sys и симлинки
MOCK_SYS="/mock-sys"

# Подготовка окружения
setup() {
    rm -f /tmp/mock-syslog.log
    rm -f /tmp/mock-wifi-result
    rm -f /tmp/mock-hostapd-result
    rm -f /tmp/mock-tailscale-up
    rm -rf /tmp/uci-mock
    rm -f /tmp/uci-mock-device-count
    rm -rf /tmp/bridgebox-*
    rm -rf "$MOCK_SYS/class/ieee80211"/*
    rm -rf "$MOCK_SYS/class/net/wlan0"

    echo "setup" > /etc/bridgebox/state
    echo "down" > /etc/bridgebox/wifi-mode
    echo "TEMPLATE" > /etc/bridgebox/box-id

    # Подменяем утилиты на моки
    cp /usr/bin/mock-logger /usr/bin/logger 2>/dev/null || true
    cp /usr/sbin/mock-dnsmasq /usr/sbin/dnsmasq 2>/dev/null || true
    cp /usr/bin/mock-udhcpc /usr/bin/udhcpc 2>/dev/null || true
    cp /usr/bin/mock-iw /usr/bin/iw 2>/dev/null || true

    # Подменяем пути /sys → /mock-sys (sysfs read-only в Docker)
    for f in /usr/lib/bridgebox/*.sh; do
        sed -i 's|/sys/class/ieee80211|/mock-sys/class/ieee80211|g; s|/sys/class/net|/mock-sys/class/net|g' "$f" 2>/dev/null
    done
}

# Создаём фейковый Wi-Fi адаптер
mock_wifi_present() {
    mkdir -p "$MOCK_SYS/class/ieee80211/phy0"
}

mock_wifi_absent() {
    rm -rf "$MOCK_SYS/class/ieee80211"/*
    rm -rf "$MOCK_SYS/class/net/wlan0"
}

mock_wifi_connect_ok() {
    echo "ok" > /tmp/mock-wifi-result
}

mock_wifi_connect_fail() {
    echo "fail" > /tmp/mock-wifi-result
}

# ============================================================
# Сценарий 1: Первый запуск без Wi-Fi адаптера
# Ожидание: wifi-mode=down, НЕ ребутится
# ============================================================

section "Сценарий 1: Первый запуск без Wi-Fi адаптера"

setup
mock_wifi_absent

# watchdog.sh НЕ должен ребутить
sh /usr/lib/bridgebox/watchdog.sh 2>/dev/null

WIFI_MODE=$(cat /etc/bridgebox/wifi-mode)
if [ "$WIFI_MODE" = "down" ]; then
    pass "wifi-mode остался 'down'"
else
    fail "wifi-mode = '$WIFI_MODE', ожидали 'down'"
fi

# Проверяем что reboot НЕ вызывался (в логе нет FULL FAIL)
if grep -q "FULL FAIL" /tmp/mock-syslog.log 2>/dev/null; then
    fail "watchdog пытается ребутить без Wi-Fi адаптера!"
else
    pass "watchdog НЕ ребутит без Wi-Fi адаптера"
fi

# ============================================================
# Сценарий 2: Первый запуск С Wi-Fi адаптером, нет wpa.conf → AP mode
# ============================================================

section "Сценарий 2: Wi-Fi адаптер есть, нет wpa.conf → AP mode"

setup
mock_wifi_present
rm -f /etc/bridgebox/wpa.conf

sh /usr/lib/bridgebox/wifi-switch.sh ap 2>/dev/null

WIFI_MODE=$(cat /etc/bridgebox/wifi-mode)
if [ "$WIFI_MODE" = "ap" ]; then
    pass "wifi-mode = 'ap'"
else
    fail "wifi-mode = '$WIFI_MODE', ожидали 'ap'"
fi

if [ -d /sys/class/net/wlan0 ]; then
    pass "wlan0 создан"
else
    fail "wlan0 НЕ создан"
fi

# Проверяем hostapd конфиг
if [ -f /tmp/bridgebox-hostapd.conf ]; then
    pass "hostapd конфиг создан"
    if grep -q "BridgeBox-" /tmp/bridgebox-hostapd.conf; then
        pass "SSID содержит 'BridgeBox-'"
    else
        fail "SSID не содержит 'BridgeBox-'"
    fi
else
    fail "hostapd конфиг НЕ создан"
fi

# ============================================================
# Сценарий 3: Юзер вводит Wi-Fi → STA mode успех
# ============================================================

section "Сценарий 3: AP → STA (успешное подключение)"

setup
mock_wifi_present
mock_wifi_connect_ok

sh /usr/lib/bridgebox/wifi-switch.sh sta "TestNetwork" "TestPass123" 2>/dev/null

WIFI_MODE=$(cat /etc/bridgebox/wifi-mode)
if [ "$WIFI_MODE" = "sta" ]; then
    pass "wifi-mode = 'sta'"
else
    fail "wifi-mode = '$WIFI_MODE', ожидали 'sta'"
fi

if [ -f /etc/bridgebox/wpa.conf ]; then
    pass "wpa.conf сохранён"
    if grep -q "TestNetwork" /etc/bridgebox/wpa.conf; then
        pass "wpa.conf содержит SSID"
    else
        fail "wpa.conf не содержит SSID"
    fi
else
    fail "wpa.conf НЕ сохранён"
fi

# ============================================================
# Сценарий 4: Юзер вводит неправильный пароль → fallback в AP
# ============================================================

section "Сценарий 4: AP → STA (неправильный пароль) → fallback AP"

setup
mock_wifi_present
mock_wifi_connect_fail

sh /usr/lib/bridgebox/wifi-switch.sh sta "BadNetwork" "WrongPass" 2>/dev/null

WIFI_MODE=$(cat /etc/bridgebox/wifi-mode)
if [ "$WIFI_MODE" = "ap" ]; then
    pass "Fallback в AP mode после неудачного STA"
else
    fail "wifi-mode = '$WIFI_MODE', ожидали fallback в 'ap'"
fi

if [ ! -f /etc/bridgebox/wpa.conf ]; then
    pass "wpa.conf НЕ сохранён (правильно — не подключились)"
else
    fail "wpa.conf сохранён несмотря на неудачу!"
fi

# ============================================================
# Сценарий 5: Restore из сохранённого wpa.conf
# ============================================================

section "Сценарий 5: Restore STA из wpa.conf"

setup
mock_wifi_present
mock_wifi_connect_ok

# Создаём сохранённый конфиг
cat > /etc/bridgebox/wpa.conf <<WPA
network={
    ssid="SavedNetwork"
    psk="SavedPass"
    key_mgmt=WPA-PSK
}
WPA

sh /usr/lib/bridgebox/wifi-switch.sh restore 2>/dev/null

WIFI_MODE=$(cat /etc/bridgebox/wifi-mode)
if [ "$WIFI_MODE" = "sta" ]; then
    pass "Restore → STA mode"
else
    fail "wifi-mode = '$WIFI_MODE', ожидали 'sta'"
fi

# ============================================================
# Сценарий 6: Restore fail → fallback AP
# ============================================================

section "Сценарий 6: Restore fail → fallback AP"

setup
mock_wifi_present
mock_wifi_connect_fail

cat > /etc/bridgebox/wpa.conf <<WPA
network={
    ssid="DeadNetwork"
    psk="DeadPass"
    key_mgmt=WPA-PSK
}
WPA

sh /usr/lib/bridgebox/wifi-switch.sh restore 2>/dev/null

WIFI_MODE=$(cat /etc/bridgebox/wifi-mode)
if [ "$WIFI_MODE" = "ap" ]; then
    pass "Restore fail → fallback AP"
else
    fail "wifi-mode = '$WIFI_MODE', ожидали fallback 'ap'"
fi

# ============================================================
# Сценарий 7: wifi-watchdog при STA down → ретрай, потом AP
# ============================================================

section "Сценарий 7: Wi-Fi watchdog (STA отвалился)"

setup
mock_wifi_present
echo "sta" > /etc/bridgebox/wifi-mode
# wlan0 не существует = "отвалился"

sh /usr/lib/bridgebox/wifi-watchdog.sh 2>/dev/null
FAILS=$(cat /tmp/bridgebox-wifi-fail-count 2>/dev/null || echo "0")
if [ "$FAILS" = "1" ]; then
    pass "Первый fail = ретрай (счётчик=1)"
else
    fail "Счётчик = '$FAILS', ожидали '1'"
fi

# ============================================================
# Сценарий 8: watchdog с Wi-Fi адаптером, wlan0 down, 3 фейла → reboot
# ============================================================

section "Сценарий 8: Watchdog — mgmt мёртв 3 раза"

setup
mock_wifi_present
mock_wifi_connect_fail
echo "2" > /tmp/bridgebox-wd-mgmt-fails

# Подменяем reboot на запись в файл
echo '#!/bin/sh
echo "REBOOT_CALLED" > /tmp/mock-reboot-called' > /usr/sbin/reboot
chmod +x /usr/sbin/reboot

sh /usr/lib/bridgebox/watchdog.sh 2>/dev/null

if [ -f /tmp/mock-reboot-called ]; then
    pass "Watchdog ребутит после 3 неудач (с Wi-Fi адаптером)"
else
    fail "Watchdog НЕ ребутил после 3 неудач"
fi

# Убираем мок reboot
rm -f /usr/sbin/reboot /tmp/mock-reboot-called

# ============================================================
# Сценарий 9: watchdog БЕЗ Wi-Fi адаптера, много фейлов → НЕ ребутит
# ============================================================

section "Сценарий 9: Watchdog — нет адаптера, НЕ ребутит"

setup
mock_wifi_absent
echo "10" > /tmp/bridgebox-wd-mgmt-fails

echo '#!/bin/sh
echo "REBOOT_CALLED" > /tmp/mock-reboot-called' > /usr/sbin/reboot
chmod +x /usr/sbin/reboot

sh /usr/lib/bridgebox/watchdog.sh 2>/dev/null

if [ ! -f /tmp/mock-reboot-called ]; then
    pass "Watchdog НЕ ребутит без Wi-Fi адаптера (даже после 10 фейлов)"
else
    fail "Watchdog РЕБУТИЛ без Wi-Fi адаптера — ЭТО БАГ!"
fi

rm -f /usr/sbin/reboot /tmp/mock-reboot-called

# ============================================================
# Сценарий 10: CGI wifi-setup GET → HTML с формой
# ============================================================

section "Сценарий 10: CGI wifi-setup отдаёт HTML"

setup
export REQUEST_METHOD="GET"
export CONTENT_LENGTH="0"

OUTPUT=$(sh /www/cgi-bin/wifi-setup 2>/dev/null)

if echo "$OUTPUT" | grep -q "Content-Type: text/html"; then
    pass "CGI возвращает Content-Type: text/html"
else
    fail "CGI не возвращает правильный Content-Type"
fi

if echo "$OUTPUT" | grep -q '<form method="POST"'; then
    pass "CGI содержит форму"
else
    fail "CGI не содержит форму"
fi

if echo "$OUTPUT" | grep -q 'name="ssid"'; then
    pass "Форма содержит поле SSID"
else
    fail "Форма не содержит поле SSID"
fi

unset REQUEST_METHOD CONTENT_LENGTH

# ============================================================
# Сценарий 11: CGI status отдаёт HTML
# ============================================================

section "Сценарий 11: CGI status отдаёт HTML"

setup
OUTPUT=$(sh /www/cgi-bin/status 2>/dev/null)

if echo "$OUTPUT" | grep -q "Content-Type: text/html"; then
    pass "CGI status возвращает Content-Type: text/html"
else
    fail "CGI status не возвращает правильный Content-Type"
fi

if echo "$OUTPUT" | grep -q "BridgeBox"; then
    pass "CGI status содержит 'BridgeBox'"
else
    fail "CGI status не содержит 'BridgeBox'"
fi

# ============================================================
# Сценарий 12: setup-bridge.sh ставит proto=none
# ============================================================

section "Сценарий 12: setup-bridge.sh конфигурация"

setup
# Мокаем init.d скрипты чтобы stop/disable не падали
for svc in dnsmasq firewall odhcpd network; do
    mkdir -p /etc/init.d
    printf '#!/bin/sh\nexit 0\n' > "/etc/init.d/$svc"
    chmod +x "/etc/init.d/$svc"
done
# Мокаем nft
printf '#!/bin/sh\nexit 0\n' > /usr/bin/nft 2>/dev/null || printf '#!/bin/sh\nexit 0\n' > /usr/sbin/nft 2>/dev/null
chmod +x /usr/bin/nft 2>/dev/null || chmod +x /usr/sbin/nft 2>/dev/null

sh /usr/lib/bridgebox/setup-bridge.sh 2>/dev/null

PROTO=$(cat /tmp/uci-mock/network_bridge_proto 2>/dev/null | tr -d "'")
if [ "$PROTO" = "none" ]; then
    pass "br0 proto=none (стерильный мост)"
else
    fail "br0 proto='$PROTO', ожидали 'none'"
fi

# Проверяем что dnsmasq НЕ отключён
if [ ! -f /tmp/uci-mock/dnsmasq_disabled ]; then
    pass "dnsmasq не отключён"
else
    fail "dnsmasq отключён!"
fi

# ============================================================
# ИТОГ
# ============================================================

echo ""
printf "${CYAN}════════════════════════════════════════${NC}\n"
printf "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}\n"
printf "${CYAN}════════════════════════════════════════${NC}\n"

if [ "$FAIL" -gt 0 ]; then
    printf "\n${RED}FAIL: $FAIL тестов провалилось. НЕ ПРОШИВАТЬ!${NC}\n\n"
    exit 1
else
    printf "\n${GREEN}Все интеграционные тесты пройдены.${NC}\n\n"
    exit 0
fi
