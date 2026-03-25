# bb-agent (Kotlin/Native) — UNSTABLE

## Проблема

Kotlin/Native генерирует динамически слинкованный бинарник с glibc (`/lib/ld-linux-aarch64.so.1`).
OpenWrt 25.12 использует musl libc (`/lib/ld-musl-aarch64.so.1`).

Бинарник не запускается на коробке: `ash: /usr/bin/bb-agent: not found`.

## Статус

Код рабочий, компилируется, E2E с бэкендом проходит на x64.
На ARM64 (NanoPi R3S, OpenWrt) — не запускается из-за несовместимости libc.

## Замена

Используется shell-версия `/usr/bin/bb-agent` (POSIX sh + curl/wget).
Покрывает: register, heartbeat, status.

## Когда вернуться

Kotlin/Native агент понадобится когда появится:
- persistent WebSocket к бэкенду
- сложная state machine на коробке
- push стратегий через mesh

Варианты починки:
- cross-compile с musl (Kotlin/Native пока не поддерживает)
- статическая линковка (не поддерживается K/N)
- Alpine Docker для сборки (нужен musl toolchain)
- GraalVM Native Image с musl (альтернатива K/N)
