# Management Plane — архитектура отказоустойчивости

## Принцип

Коробка имеет два независимых сетевых слоя:

```
DATA PLANE:   eth0 ↔ br0 ↔ eth1   (мост, может перенастраиваться)
MGMT PLANE:   wlan0 → Tailscale    (неприкасаемый, всегда работает)
```

Management plane — это **инфраструктурный слой**, а не режим.
Он всегда активен, независимо от состояния data plane.

## Гарантии

1. **wlan0 не входит в br0** — отдельный интерфейс, свой IP через DHCP от домашнего Wi-Fi
2. **nftables не трогает wlan0** — все правила привязаны только к br0/eth0/eth1
3. **Tailscale работает через wlan0** — mesh-трафик идёт через Wi-Fi, минуя мост
4. **Watchdog мониторит через wlan0** — connectivity-проверки идут по management-каналу

## nftables — изоляция интерфейсов

```
# Все nft-правила привязаны только к bridge-интерфейсам
define wanif = { br0 }

# wlan0 НИКОГДА не попадает в nft-цепочки
# Трафик через wlan0 проходит стандартным путём без модификации
```

## Watchdog — логика fallback

### Проверки (каждые 60 секунд)

1. **wlan0 connectivity** — ping шлюза Wi-Fi сети
2. **Tailscale connectivity** — ping headscale/peer
3. **br0 status** — bridge device UP, оба порта присутствуют

### Таблица решений

| wlan0 | Tailscale | br0 | Действие |
|-------|-----------|-----|----------|
| ✓ | ✓ | ✓ | Всё ок |
| ✓ | ✓ | ✗ | Логируем, НЕ ребутим — оператор починит через mesh |
| ✓ | ✗ | ✓ | Перезапуск Tailscale |
| ✓ | ✗ | ✗ | Перезапуск Tailscale, логируем проблему bridge |
| ✗ | — | ✓ | Переподключение wlan0 (rmmod/modprobe, wpa_supplicant) |
| ✗ | — | ✗ | Попытка восстановить wlan0, после N неудач → reboot |

### Safe mode

Счётчик неудачных загрузок хранится в `/etc/bridgebox/boot-failures`.

- Каждая успешная загрузка (wlan0 + Tailscale UP) → счётчик = 0
- Каждый reboot из-за полного отказа → счётчик + 1
- **Счётчик >= 3** → safe mode:
  - Поднимаем ТОЛЬКО wlan0 + Tailscale
  - Bridge НЕ поднимаем
  - Доп. сервисы НЕ запускаем
  - Оператор подключается через mesh и диагностирует

## Wi-Fi credentials flow

1. Пользователь вводит SSID + пароль в Telegram-боте
2. Бэкенд пушит конфиг на коробку через Tailscale (mesh)
3. Коробка сохраняет `/etc/bridgebox/wpa.conf`
4. wlan0 подключается к домашнему Wi-Fi
5. Management plane поднят — с этого момента неприкасаемый

## Порядок запуска сервисов при загрузке

```
1. wlan0      — подключение к Wi-Fi (management)
2. tailscale  — подключение к mesh
3. watchdog   — мониторинг
4. bridge     — настройка br0 (data plane)
5. [private]  — доп. сервисы через mesh (после активации)
```

Management plane поднимается ПЕРВЫМ. Data plane — после.
Если management не поднялся — data plane всё равно стартует (чтобы не ломать интернет пользователю).
