# BridgeBox Image Builder

Система сборки готовых образов OpenWrt для NanoPi R2S/R3S.

## Быстрый старт

```sh
# 1. Скачать OpenWrt Image Builder (один раз)
make download

# 2. Собрать образ для одной коробки
make image PROFILE=friendlyarm_nanopi-r3s BOX_ID=BB-001

# 3. Собрать пакет из 100 образов
make batch PROFILE=friendlyarm_nanopi-r3s START=1 COUNT=100
```

## Профили

| Профиль | Модель | RAM | Назначение |
|---------|--------|-----|------------|
| `friendlyarm_nanopi-r2s` | NanoPi R2S | 512MB | Lite (только мост) |
| `friendlyarm_nanopi-r3s` | NanoPi R3S | 2GB | Pro (мост + будущий роутер) |

## Варианты

| Вариант | LuCI | tcpdump | Описание |
|---------|------|---------|----------|
| `production` (по умолчанию) | нет | нет | Минимальный размер |
| `dev` | да | да | Для разработки |

```sh
make image PROFILE=friendlyarm_nanopi-r3s BOX_ID=BB-001 VARIANT=dev
```

## Параметры

| Параметр | Описание | Пример |
|----------|----------|--------|
| `PROFILE` | Профиль устройства | `friendlyarm_nanopi-r3s` |
| `BOX_ID` | Уникальный ID коробки | `BB-001` |
| `VARIANT` | production / dev | `production` |
| `AUTH_KEY` | Headscale auth key | `hskey-xxx` |
| `START` | Начальный номер (batch) | `1` |
| `COUNT` | Количество (batch) | `100` |

## Что в образе

- Прозрачный L2 мост (br0 = eth0 + eth1)
- Tailscale для удалённого администрирования
- USB Wi-Fi client (RTL8188EUS) для management
- Hardware watchdog + bridge health check
- SSH firewall (только через Tailscale)
- Уникальный BOX_ID для идентификации

## Прошивка

```sh
# SD-карта (первая прошивка)
gunzip -k output/bridgebox-BB-001-production-20260324.img.gz
dd if=output/bridgebox-BB-001-production-20260324.img of=/dev/sdX bs=4M status=progress

# OTA через mesh (sysupgrade)
scp output/bridgebox-BB-001-production-20260324.img.gz root@100.64.0.1:/tmp/
ssh root@100.64.0.1 'sysupgrade -v /tmp/bridgebox-BB-001-production-20260324.img.gz'
```

## Структура

```
imagebuilder/
├── Makefile                     # Оркестрация
├── profiles/                    # Профили устройств
├── files/                       # Overlay на rootfs
│   ├── etc/config/network       # Bridge конфиг
│   ├── etc/init.d/              # Сервисы
│   ├── etc/uci-defaults/        # First-boot скрипты
│   ├── etc/bridgebox/box-id     # ID коробки
│   └── usr/lib/bridgebox/       # Утилиты
├── scripts/                     # Скрипты сборки
└── output/                      # Готовые образы
```
