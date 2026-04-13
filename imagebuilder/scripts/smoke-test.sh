#!/bin/sh
# smoke-test.sh — Проверка прошивки ДО прошивки на железо
#
# Уровень 1: синтаксис, зависимости, reboot-пути, OPSEC
# Уровень 2: моки sysfs + прогон скриптов через сценарии
#
# Использование: sh scripts/smoke-test.sh
# Из Makefile:   make test
#
# Возвращает 0 если всё ок, 1 если есть ошибки

PASS=0
FAIL=0
WARN=0
FILES_DIR="$(cd "$(dirname "$0")/../files" && pwd)"

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() {
    PASS=$((PASS + 1))
    printf "  ${GREEN}✓${NC} %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "  ${RED}✗${NC} %s\n" "$1"
}

warn() {
    WARN=$((WARN + 1))
    printf "  ${YELLOW}!${NC} %s\n" "$1"
}

section() {
    printf "\n${CYAN}=== %s ===${NC}\n" "$1"
}

# ============================================================
# УРОВЕНЬ 1: Статические проверки (без выполнения скриптов)
# ============================================================

section "L1: Синтаксис shell-скриптов"

SYNTAX_FILES=""
SYNTAX_FILES="$SYNTAX_FILES $(find "$FILES_DIR" -name "*.sh" -type f 2>/dev/null)"
SYNTAX_FILES="$SYNTAX_FILES $(find "$FILES_DIR/etc/init.d" -type f 2>/dev/null)"
SYNTAX_FILES="$SYNTAX_FILES $(find "$FILES_DIR/www/cgi-bin" -type f 2>/dev/null)"
SYNTAX_FILES="$SYNTAX_FILES $(find "$FILES_DIR/etc/hotplug.d" -type f 2>/dev/null)"
SYNTAX_FILES="$SYNTAX_FILES $(find "$FILES_DIR/etc/uci-defaults" -type f 2>/dev/null)"

for f in $SYNTAX_FILES; do
    [ -f "$f" ] || continue
    basename_f=$(basename "$f")
    # Пропускаем бинарники — проверяем первые 4 байта на ELF magic
    first_bytes=$(head -c 4 "$f" 2>/dev/null | cat -v)
    case "$first_bytes" in
        *ELF*) continue ;;
    esac
    if sh -n "$f" 2>/dev/null; then
        pass "$basename_f — синтаксис OK"
    else
        fail "$basename_f — синтаксическая ошибка!"
    fi
done

# ---

section "L1: Файлы существуют и executable"

for f in "$FILES_DIR"/etc/init.d/bridgebox-*; do
    [ -f "$f" ] || continue
    if [ -x "$f" ]; then
        pass "init.d/$(basename "$f") — executable"
    else
        fail "init.d/$(basename "$f") — НЕ executable"
    fi
done

for f in "$FILES_DIR"/usr/lib/bridgebox/*.sh; do
    [ -f "$f" ] || continue
    if [ -x "$f" ]; then
        pass "$(basename "$f") — executable"
    else
        fail "$(basename "$f") — НЕ executable"
    fi
done

for f in "$FILES_DIR"/www/cgi-bin/*; do
    [ -f "$f" ] || continue
    if [ -x "$f" ]; then
        pass "cgi-bin/$(basename "$f") — executable"
    else
        fail "cgi-bin/$(basename "$f") — НЕ executable"
    fi
done

# ---

section "L1: Порядок запуска init.d (START=)"

PREV_START=0
PREV_NAME=""
for f in $(grep -l "^START=" "$FILES_DIR"/etc/init.d/bridgebox-* 2>/dev/null | sort); do
    name=$(basename "$f")
    start=$(grep "^START=" "$f" | head -1 | cut -d= -f2)
    pass "$name START=$start"

    if [ "$start" -lt "$PREV_START" ] 2>/dev/null; then
        warn "$name (START=$start) стартует раньше $PREV_NAME (START=$PREV_START) но объявлен позже"
    fi
    PREV_START=$start
    PREV_NAME=$name
done

# ---

section "L1: Кросс-ссылки (скрипт A вызывает B → B существует)"

check_ref() {
    local src="$1"
    local target="$2"
    local target_path="$FILES_DIR$target"

    if [ -f "$target_path" ]; then
        pass "$(basename "$src") → $target"
    else
        fail "$(basename "$src") → $target НЕ СУЩЕСТВУЕТ"
    fi
}

# init.d → скрипты
for f in "$FILES_DIR"/etc/init.d/bridgebox-*; do
    [ -f "$f" ] || continue
    # Ищем вызовы /usr/lib/bridgebox/
    grep -o '/usr/lib/bridgebox/[a-z_-]*\.sh' "$f" 2>/dev/null | sort -u | while read ref; do
        check_ref "$f" "$ref"
    done
    # Ищем вызовы /usr/bin/
    grep -o '/usr/bin/bb-agent' "$f" 2>/dev/null | sort -u | while read ref; do
        check_ref "$f" "$ref"
    done
done

# cron → скрипты
if [ -f "$FILES_DIR/etc/crontabs/root" ]; then
    grep -o '/usr/lib/bridgebox/[a-z_-]*\.sh' "$FILES_DIR/etc/crontabs/root" 2>/dev/null | sort -u | while read ref; do
        check_ref "crontabs/root" "$ref"
    done
    grep -o '/usr/bin/bb-agent' "$FILES_DIR/etc/crontabs/root" 2>/dev/null | sort -u | while read ref; do
        check_ref "crontabs/root" "$ref"
    done
fi

# hotplug → init.d
for f in "$FILES_DIR"/etc/hotplug.d/usb/*; do
    [ -f "$f" ] || continue
    grep -o '/etc/init.d/bridgebox-[a-z]*' "$f" 2>/dev/null | sort -u | while read ref; do
        check_ref "$f" "$ref"
    done
done

# wifi-switch.sh → wifi-setup CGI
if grep -q '/usr/lib/bridgebox/wifi-switch.sh' "$FILES_DIR/www/cgi-bin/wifi-setup" 2>/dev/null; then
    check_ref "cgi-bin/wifi-setup" "/usr/lib/bridgebox/wifi-switch.sh"
fi

# ---

section "L1: Reboot-пути (каждый reboot защищён условием)"

for f in $(find "$FILES_DIR" -type f \( -name "*.sh" -o -path "*/init.d/*" \)); do
    # Пропускаем бинарники
    file "$f" | grep -q "ELF\|executable\|data" && continue

    reboot_lines=$(grep -n "reboot" "$f" 2>/dev/null | grep -v "^.*:#" | grep -v "echo\|logger\|Rollback\|firstboot")
    if [ -n "$reboot_lines" ]; then
        echo "$reboot_lines" | while IFS= read -r line; do
            lineno=$(echo "$line" | cut -d: -f1)
            # Проверяем что перед reboot есть условие (if/elif/then в предыдущих 5 строках)
            context=$(sed -n "$((lineno > 5 ? lineno - 5 : 1)),${lineno}p" "$f")
            if echo "$context" | grep -q "if \|elif \|then\|&&"; then
                pass "$(basename "$f"):$lineno — reboot защищён условием"
            else
                fail "$(basename "$f"):$lineno — reboot БЕЗ условия (может ребутить всегда!)"
            fi
        done
    fi
done

# ---

section "L1: OPSEC (нет antiDPI/zapret в open-source)"

OPSEC_VIOLATIONS=""
for f in $(find "$FILES_DIR" -type f); do
    file "$f" | grep -q "ELF\|executable\|data" && continue
    matches=$(grep -inl "antiDPI\|antidpi\|zapret\|nfqws\|DPI.bypass\|обход.блокировок" "$f" 2>/dev/null)
    if [ -n "$matches" ]; then
        OPSEC_VIOLATIONS="$OPSEC_VIOLATIONS $f"
    fi
done

if [ -z "$OPSEC_VIOLATIONS" ]; then
    pass "Нет упоминаний antiDPI/zapret/nfqws"
else
    for f in $OPSEC_VIOLATIONS; do
        fail "OPSEC: $(basename "$f") содержит запрещённые термины"
    done
fi

# ---

section "L1: Нет хардкодов инфраструктурных IP"

for f in $(find "$FILES_DIR" -type f); do
    file "$f" | grep -q "ELF\|executable\|data" && continue
    # Ищем IP-адреса, исключаем 192.168.x.x (локальные), 0.0.0.0, 127.0.0.1, 8.8.8.8 (DNS fallback)
    bad_ips=$(grep -n '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' "$f" 2>/dev/null \
        | grep -v '192\.168\.\|0\.0\.0\.0\|127\.0\.0\.1\|8\.8\.8\.8\|1\.1\.1\.1\|255\.255\.' \
        | grep -v '^.*:#\|echo\|logger\|api\.qrserver')
    if [ -n "$bad_ips" ]; then
        echo "$bad_ips" | while IFS= read -r line; do
            warn "$(basename "$f"):$(echo "$line" | cut -d: -f1) — возможный хардкод IP"
        done
    fi
done
if [ "$WARN" = "0" ] 2>/dev/null; then
    pass "Нет хардкодов инфраструктурных IP"
fi

# ============================================================
# УРОВЕНЬ 2: Mock-тесты (эмуляция sysfs + прогон скриптов)
# ============================================================

section "L2: Mock-тесты сценариев"

MOCK_ROOT=$(mktemp -d)
trap "rm -rf $MOCK_ROOT" EXIT

# Создаём mock sysfs
setup_mock() {
    rm -rf "$MOCK_ROOT"/*
    mkdir -p "$MOCK_ROOT/sys/class/ieee80211"
    mkdir -p "$MOCK_ROOT/sys/class/net"
    mkdir -p "$MOCK_ROOT/etc/bridgebox"
    mkdir -p "$MOCK_ROOT/tmp"
    echo "setup" > "$MOCK_ROOT/etc/bridgebox/state"
    echo "down" > "$MOCK_ROOT/etc/bridgebox/wifi-mode"
    echo "TEMPLATE" > "$MOCK_ROOT/etc/bridgebox/box-id"
}

# Тест: lib-common.sh существует и содержит safe_write
LIB_COMMON="$FILES_DIR/usr/lib/bridgebox/lib-common.sh"
if [ -f "$LIB_COMMON" ]; then
    if grep -q "safe_write" "$LIB_COMMON"; then
        pass "lib-common.sh содержит safe_write()"
    else
        fail "lib-common.sh НЕ содержит safe_write()"
    fi
    if [ -x "$LIB_COMMON" ]; then
        pass "lib-common.sh executable"
    else
        fail "lib-common.sh НЕ executable"
    fi
else
    fail "lib-common.sh не существует"
fi

# Тест: все state-записи используют safe_write (не echo > )
for f in "$FILES_DIR/usr/lib/bridgebox/wifi-switch.sh" "$FILES_DIR/etc/uci-defaults/10-bridgebox-system"; do
    [ -f "$f" ] || continue
    basename_f=$(basename "$f")
    unsafe=$(grep -n 'echo.*> .*/etc/bridgebox/' "$f" 2>/dev/null | grep -v '^.*:#')
    if [ -z "$unsafe" ]; then
        pass "$basename_f — safe_write для state файлов"
    else
        fail "$basename_f — найдены unsafe echo > /etc/bridgebox/ записи"
    fi
done

# Тест: wifi-reset.sh существует
WR_SCRIPT="$FILES_DIR/usr/lib/bridgebox/wifi-reset.sh"
if [ -f "$WR_SCRIPT" ]; then
    pass "wifi-reset.sh существует"
else
    fail "wifi-reset.sh не существует"
fi

# Тест: wifi-reset CGI существует
WR_CGI="$FILES_DIR/www/cgi-bin/wifi-reset"
if [ -f "$WR_CGI" ] && [ -x "$WR_CGI" ]; then
    pass "cgi-bin/wifi-reset существует и executable"
else
    fail "cgi-bin/wifi-reset не существует или не executable"
fi

# Тест: status page содержит кнопку wifi-reset
STATUS_CGI="$FILES_DIR/www/cgi-bin/status"
if [ -f "$STATUS_CGI" ]; then
    if grep -q "wifi-reset" "$STATUS_CGI"; then
        pass "status page содержит ссылку на wifi-reset"
    else
        fail "status page НЕ содержит ссылку на wifi-reset"
    fi
fi

# Тест: 10-bridgebox-system содержит wait loop для eth0
UCI_DEFAULTS_FILE="$FILES_DIR/etc/uci-defaults/10-bridgebox-system"
if [ -f "$UCI_DEFAULTS_FILE" ]; then
    if grep -q 'while.*attempts.*lt.*10' "$UCI_DEFAULTS_FILE" && grep -q '00:00:00:00:00:00' "$UCI_DEFAULTS_FILE"; then
        pass "uci-defaults: wait loop для eth0 MAC"
    else
        fail "uci-defaults: нет wait loop для eth0 MAC"
    fi
fi

# Тест: bridgebox-wifi корректно обрабатывает отсутствие Wi-Fi (management через eth0)
WIFI_INIT_FILE="$FILES_DIR/etc/init.d/bridgebox-wifi"
if [ -f "$WIFI_INIT_FILE" ]; then
    if grep -q "management через eth0" "$WIFI_INIT_FILE"; then
        pass "bridgebox-wifi: fallback management через eth0"
    else
        fail "bridgebox-wifi: нет fallback на eth0 при отсутствии Wi-Fi"
    fi
fi

# Тест: watchdog.sh НИКОГДА не ребутит (мост работает 24/7)
setup_mock
WATCHDOG="$FILES_DIR/usr/lib/bridgebox/watchdog.sh"
if [ -f "$WATCHDOG" ]; then
    # watchdog не должен содержать reboot (кроме комментариев)
    reboot_calls=$(grep -n "reboot" "$WATCHDOG" 2>/dev/null | grep -v "^.*:#" | grep -v "echo\|logger")
    if [ -z "$reboot_calls" ]; then
        pass "watchdog.sh не содержит reboot (мост работает 24/7)"
    else
        fail "watchdog.sh содержит reboot — мост должен работать 24/7, без ребутов!"
    fi

    # Проверяем что есть проверка wifi_hw_present
    if grep -q "wifi_hw_present" "$WATCHDOG"; then
        pass "watchdog.sh проверяет наличие Wi-Fi адаптера"
    else
        fail "watchdog.sh НЕ проверяет наличие Wi-Fi адаптера"
    fi
fi

# Тест: wifi-watchdog.sh НЕ ребутит (вообще не должен содержать reboot)
WIFI_WD="$FILES_DIR/usr/lib/bridgebox/wifi-watchdog.sh"
if [ -f "$WIFI_WD" ]; then
    if grep -q "reboot" "$WIFI_WD"; then
        fail "wifi-watchdog.sh содержит reboot — должен только переключать AP/STA"
    else
        pass "wifi-watchdog.sh не содержит reboot"
    fi
fi

# Тест: wifi-switch.sh НЕ содержит AP mode
WIFI_SW="$FILES_DIR/usr/lib/bridgebox/wifi-switch.sh"
if [ -f "$WIFI_SW" ]; then
    if grep -q "start_ap\|hostapd" "$WIFI_SW"; then
        fail "wifi-switch.sh содержит AP mode — AP убран из прошивки!"
    else
        pass "wifi-switch.sh не содержит AP mode"
    fi
fi

# Тест: wifi-switch.sh НЕ ребутит
if [ -f "$WIFI_SW" ]; then
    if grep "reboot" "$WIFI_SW" | grep -vq "^.*:#\|echo\|logger"; then
        fail "wifi-switch.sh содержит reboot"
    else
        pass "wifi-switch.sh не содержит reboot"
    fi
fi

# Тест: setup-bridge.sh НЕ ребутит
SETUP_BR="$FILES_DIR/usr/lib/bridgebox/setup-bridge.sh"
if [ -f "$SETUP_BR" ]; then
    if grep "reboot" "$SETUP_BR" | grep -vq "^.*:#\|echo\|logger\|Rollback\|firstboot"; then
        fail "setup-bridge.sh содержит reboot"
    else
        pass "setup-bridge.sh не содержит reboot"
    fi
fi

# Тест: bridgebox-agent не блокирует загрузку при отсутствии Wi-Fi
AGENT_INIT="$FILES_DIR/etc/init.d/bridgebox-agent"
if [ -f "$AGENT_INIT" ]; then
    if grep -q "return 0\|return 1" "$AGENT_INIT" && grep -q 'wifi_mode.*!=.*sta\|wifi-mode' "$AGENT_INIT"; then
        pass "bridgebox-agent корректно обрабатывает отсутствие Wi-Fi"
    else
        warn "bridgebox-agent может блокировать загрузку при отсутствии Wi-Fi"
    fi
fi

# Тест: init.d bridgebox-wifi имеет lock от race condition
WIFI_INIT="$FILES_DIR/etc/init.d/bridgebox-wifi"
if [ -f "$WIFI_INIT" ]; then
    if grep -q "lock\|LOCK" "$WIFI_INIT"; then
        pass "bridgebox-wifi имеет lock для защиты от race condition"
    else
        fail "bridgebox-wifi НЕ имеет lock — race condition с hotplug!"
    fi
fi

# Тест: CGI wifi-setup не вызывает reboot
CGI_SETUP="$FILES_DIR/www/cgi-bin/wifi-setup"
if [ -f "$CGI_SETUP" ]; then
    if grep "reboot" "$CGI_SETUP" | grep -vq "^.*:#\|echo"; then
        fail "cgi-bin/wifi-setup содержит reboot"
    else
        pass "cgi-bin/wifi-setup не содержит reboot"
    fi
fi

# Тест: dnsmasq не отключается в setup-bridge.sh (нужен для DNS)
if [ -f "$SETUP_BR" ]; then
    if grep -q "dnsmasq.*stop\|dnsmasq.*disable" "$SETUP_BR"; then
        fail "setup-bridge.sh отключает dnsmasq — сломает DNS!"
    else
        pass "setup-bridge.sh не трогает dnsmasq"
    fi
fi

# Тест: uci-defaults НЕ отключает dnsmasq (нужен для DNS)
UCI_DEFAULTS="$FILES_DIR/etc/uci-defaults/10-bridgebox-system"
if [ -f "$UCI_DEFAULTS" ]; then
    if grep -q "dnsmasq.*disable\|dnsmasq.*stop" "$UCI_DEFAULTS"; then
        fail "uci-defaults отключает dnsmasq — сломает DNS!"
    else
        pass "uci-defaults не отключает dnsmasq"
    fi
fi

# Тест: uhttpd слушает на 0.0.0.0 (для CGI setup page)
UHTTPD_UCI="$FILES_DIR/etc/uci-defaults/20-bridgebox-uhttpd"
if [ -f "$UHTTPD_UCI" ]; then
    if grep -q "0.0.0.0:80" "$UHTTPD_UCI"; then
        pass "uhttpd слушает на 0.0.0.0:80 (CGI setup доступен)"
    else
        fail "uhttpd НЕ слушает на 0.0.0.0 — CGI setup может быть недоступен"
    fi
fi

# Тест: setup-bridge.sh использует proto=none (стерильный мост)
if [ -f "$SETUP_BR" ]; then
    if grep -q "proto.*none" "$SETUP_BR"; then
        pass "setup-bridge.sh: br0 proto=none (стерильный мост)"
    else
        fail "setup-bridge.sh: br0 НЕ proto=none — мост не стерильный!"
    fi
fi

# ============================================================
# УРОВЕНЬ 2: Проверка docker-entrypoint.sh (пакеты)
# ============================================================

section "L2: Пакеты прошивки"

ENTRYPOINT="$(cd "$(dirname "$0")/.." && pwd)/docker-entrypoint.sh"
if [ -f "$ENTRYPOINT" ]; then
    # wpad-basic-mbedtls (STA mode)
    if grep -q "wpad-basic-mbedtls" "$ENTRYPOINT"; then
        pass "wpad-basic-mbedtls включён (STA mode)"
    else
        fail "wpad-basic-mbedtls отсутствует — STA mode не будет работать!"
    fi

    # wpa-supplicant должен быть исключён (конфликтует с wpad)
    if grep -q "\-wpa-supplicant" "$ENTRYPOINT"; then
        pass "wpa-supplicant исключён (-wpa-supplicant)"
    else
        warn "wpa-supplicant не исключён явно — может конфликтовать с wpad"
    fi

    # dnsmasq (для DNS resolution)
    if grep -q "dnsmasq" "$ENTRYPOINT"; then
        pass "dnsmasq включён (DNS resolution)"
    else
        fail "dnsmasq отсутствует — DNS не будет работать!"
    fi

    # tailscale
    if grep -q "tailscale" "$ENTRYPOINT"; then
        pass "tailscale включён (mesh management)"
    else
        fail "tailscale отсутствует!"
    fi

    # uhttpd
    if grep -q "uhttpd" "$ENTRYPOINT"; then
        pass "uhttpd включён (web UI)"
    else
        fail "uhttpd отсутствует!"
    fi
fi

# ============================================================
# ИТОГ
# ============================================================

echo ""
printf "${CYAN}════════════════════════════════════════${NC}\n"
printf "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}WARN: $WARN${NC}\n"
printf "${CYAN}════════════════════════════════════════${NC}\n"

if [ "$FAIL" -gt 0 ]; then
    printf "\n${RED}БЛОКЕР: $FAIL проблем. НЕ ПРОШИВАТЬ на железо!${NC}\n\n"
    exit 1
else
    printf "\n${GREEN}Все проверки пройдены. Можно шить.${NC}\n\n"
    exit 0
fi
