# BridgeWRT Test Harness
# Эмулирует OpenWrt rootfs для прогона скриптов без железа
#
# Использование:
#   docker build -t bridgewrt-test test/
#   docker run --rm bridgewrt-test

FROM alpine:3.21

# Alpine ≈ OpenWrt (musl libc, busybox, ash)
RUN apk add --no-cache \
    busybox-extras \
    iproute2 \
    iw \
    bash \
    coreutils \
    procps \
    curl \
    grep

# Мокаем OpenWrt-специфичные утилиты
RUN mkdir -p /usr/lib/bridgebox /etc/bridgebox /www/cgi-bin /tmp

# Мок uci
COPY test/mock/uci /usr/bin/uci
# Мок logger
COPY test/mock/logger /usr/bin/mock-logger
# Мок wpa_supplicant
COPY test/mock/wpa_supplicant /usr/sbin/wpa_supplicant
# Мок hostapd
COPY test/mock/hostapd /usr/sbin/hostapd
# Мок dnsmasq
COPY test/mock/dnsmasq /usr/sbin/mock-dnsmasq
# Мок udhcpc
COPY test/mock/udhcpc /usr/bin/mock-udhcpc
# Мок tailscale
COPY test/mock/tailscale /usr/bin/tailscale
# Мок bb-agent
COPY test/mock/bb-agent /usr/bin/bb-agent
# Мок ip — заменяет реальный ip (который не может управлять виртуальными интерфейсами)
COPY test/mock/ip /usr/bin/mock-ip
RUN chmod +x /usr/bin/mock-ip && \
    mv /sbin/ip /sbin/ip.real 2>/dev/null || true && \
    ln -sf /usr/bin/mock-ip /sbin/ip && \
    ln -sf /usr/bin/mock-ip /usr/bin/ip 2>/dev/null || true

# Мок iw — заменяет реальный iw (который не может создать интерфейс без железа)
COPY test/mock/iw /usr/bin/mock-iw
RUN chmod +x /usr/bin/mock-iw && \
    mv /usr/sbin/iw /usr/sbin/iw.real 2>/dev/null || true && \
    ln -sf /usr/bin/mock-iw /usr/sbin/iw && \
    ln -sf /usr/bin/mock-iw /usr/bin/iw

# Копируем наши файлы
COPY files/usr/lib/bridgebox/ /usr/lib/bridgebox/
COPY files/etc/init.d/ /etc/init.d/
COPY files/etc/hotplug.d/ /etc/hotplug.d/
COPY files/www/cgi-bin/ /www/cgi-bin/
COPY files/etc/uci-defaults/ /etc/uci-defaults/
COPY files/etc/bridgebox/ /etc/bridgebox/
COPY files/etc/crontabs/ /etc/crontabs/

# Тестовый раннер
COPY test/run-tests.sh /run-tests.sh
RUN chmod +x /run-tests.sh

# Монтируем tmpfs поверх /sys/class для моков
# Реальный /sys read-only в Docker, подменяем на tmpfs
RUN mkdir -p /mock-sys/class/ieee80211 /mock-sys/class/net

ENTRYPOINT ["/run-tests.sh"]
