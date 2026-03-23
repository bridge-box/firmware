#!/bin/sh
# bootstrap.sh — Сброс OpenWrt до заводских настроек
#
# Запускать на коробке (NanoPi R3S):
#   ssh root@bridge-box 'sh -s' < bootstrap.sh
#
# После ребута коробка доступна через роутер (br-lan включает оба порта).
# IP может измениться (DHCP) — проверить в роутере или nmap.
#
# Дальнейшие шаги:
#   1. Дождаться ребута (~60 сек)
#   2. ssh root@bridge-box (или новый IP) — добавить SSH-ключ
#   3. Залить и запустить setup-network.sh

set -e

echo "=== BridgeBox: Factory Reset ==="
echo "Коробка будет сброшена до заводских настроек и перезагружена."
echo "После ребута: пароль = пустой, SSH-ключ сброшен"
echo ""

printf "Продолжить? [y/N] "
read -r answer
case "$answer" in
  y|Y) ;;
  *) echo "Отменено."; exit 0 ;;
esac

echo ">>> firstboot && reboot"
firstboot && reboot
