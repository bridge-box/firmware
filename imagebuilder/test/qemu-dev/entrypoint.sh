#!/bin/sh
set -e

echo ""
echo "=== BridgeBox Dev Sandbox ==="
echo ""

# Топология (как в бою, + management порт для SSH):
#
#   Docker eth0 (internet)
#       │
#   br-wan ──── tap-wan ──── eth0 (QEMU WAN)
#                                  │
#                              br0 = eth0 + eth1  ← nfqdns, flowsense
#                                  │
#   br-lan ──── tap-lan ──── eth1 (QEMU LAN)
#       │
#   tinyproxy :9999 ("браузер юзера")
#
#   br-mgmt ── tap-mgmt ── eth2 (QEMU management, SSH)
#

# --- WAN bridge (интернет через Docker) ---
ip link add br-wan type bridge
ip link set br-wan up

ip tuntap add tap-wan mode tap
ip link set tap-wan up
ip link set tap-wan master br-wan

ip addr add 10.0.0.1/24 dev br-wan
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward

# dnsmasq на WAN — DHCP для QEMU eth0 (static lease)
dnsmasq \
    --interface=br-wan \
    --bind-interfaces \
    --dhcp-range=10.0.0.100,10.0.0.200,255.255.255.0,12h \
    --dhcp-host=52:54:00:01:00:01,10.0.0.100 \
    --dhcp-option=6,8.8.8.8,8.8.4.4 \
    --no-resolv \
    --server=8.8.8.8 \
    --log-facility=/dev/null \
    --pid-file=/tmp/dnsmasq-wan.pid \
    --no-daemon &

# --- LAN bridge ("компьютер юзера") ---
ip link add br-lan type bridge
ip link set br-lan up

ip tuntap add tap-lan mode tap
ip link set tap-lan up
ip link set tap-lan master br-lan

ip addr add 172.16.0.1/24 dev br-lan

# --- Management bridge (SSH доступ к коробке) ---
ip link add br-mgmt type bridge
ip link set br-mgmt up

ip tuntap add tap-mgmt mode tap
ip link set tap-mgmt up
ip link set tap-mgmt master br-mgmt

ip addr add 192.168.88.1/24 dev br-mgmt

# dnsmasq на management — ТОЛЬКО DHCP (port=0 = не слушать DNS, иначе конфликт с WAN dnsmasq)
dnsmasq \
    --interface=br-mgmt \
    --bind-interfaces \
    --port=0 \
    --dhcp-range=192.168.88.100,192.168.88.200,255.255.255.0,12h \
    --dhcp-host=52:54:00:01:00:03,192.168.88.100 \
    --log-facility=/dev/null \
    --pid-file=/tmp/dnsmasq-mgmt.pid \
    --no-daemon &

QEMU_MGMT_IP=192.168.88.100

# --- tinyproxy (HTTP proxy на LAN стороне) ---
cat > /tmp/tinyproxy.conf << 'TINYEOF'
Port 9999
Listen 0.0.0.0
Timeout 600
MaxClients 100
Allow 0.0.0.0/0
DisableViaHeader Yes
LogLevel Error
TINYEOF

tinyproxy -c /tmp/tinyproxy.conf &
echo "tinyproxy started on :9999"

# --- SSH jump (host:2222 → QEMU management:22) ---
socat TCP-LISTEN:2222,fork,reuseaddr TCP:$QEMU_MGMT_IP:22 &

# --- Расширяем диск QEMU ---
qemu-img resize /test/openwrt.img 512M 2>/dev/null || true

# --- QEMU (3 TAP: wan + lan + management) ---
echo "Starting QEMU..."
qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a53 \
    -m 512M \
    -bios /test/efi.fd \
    -drive file=/test/openwrt.img,format=raw,if=virtio \
    -netdev tap,id=wan,ifname=tap-wan,script=no,downscript=no \
    -device virtio-net-pci,netdev=wan,mac=52:54:00:01:00:01,romfile="" \
    -netdev tap,id=lan,ifname=tap-lan,script=no,downscript=no \
    -device virtio-net-pci,netdev=lan,mac=52:54:00:01:00:02,romfile="" \
    -netdev tap,id=mgmt,ifname=tap-mgmt,script=no,downscript=no \
    -device virtio-net-pci,netdev=mgmt,mac=52:54:00:01:00:03,romfile="" \
    -nographic \
    -serial mon:stdio &

QEMU_PID=$!

# --- Ждём SSH ---
echo "Waiting for BridgeBox to boot..."
BOOTED=0
for i in $(seq 1 180); do
    if sshpass -p "" ssh -q \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=2 \
        root@$QEMU_MGMT_IP -p 22 \
        "echo ok" 2>/dev/null; then
        BOOTED=1
        break
    fi
    printf "."
    sleep 1
done

echo ""

if [ "$BOOTED" -eq 0 ]; then
    echo "ERROR: BridgeBox не загрузился за 180 секунд"
    kill $QEMU_PID 2>/dev/null
    exit 1
fi

echo ""
echo "==========================================="
echo "  BridgeBox Dev Sandbox Ready!"
echo "==========================================="
echo ""
echo "  HTTP Proxy:  localhost:9999"
echo "  SSH:         ssh root@localhost -p 2222"
echo ""
echo "  Прописал localhost:9999 в браузере — интернет через коробку."
echo ""
echo "  Ctrl+C для остановки."
echo "==========================================="
echo ""

wait $QEMU_PID
