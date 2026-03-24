#!/bin/sh
# inject-identity.sh — Вшить BOX_ID (и опционально auth-key) в overlay
#
# Использование:
#   sh inject-identity.sh <BOX_ID> [AUTH_KEY]
#
# Пишет BOX_ID в files/etc/bridgebox/box-id
# Если AUTH_KEY задан — пишет в files/etc/bridgebox/auth-key

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/../files"

BOX_ID="${1:-}"
AUTH_KEY="${2:-}"

if [ -z "$BOX_ID" ]; then
    echo "Ошибка: BOX_ID не задан" >&2
    echo "Использование: $0 <BOX_ID> [AUTH_KEY]" >&2
    exit 1
fi

# Валидация BOX_ID: только буквы, цифры, дефис
if ! echo "$BOX_ID" | grep -qE '^[A-Za-z0-9-]+$'; then
    echo "Ошибка: BOX_ID содержит недопустимые символы (разрешены: A-Z, 0-9, -)" >&2
    exit 1
fi

# Пишем BOX_ID
mkdir -p "$FILES_DIR/etc/bridgebox"
echo "$BOX_ID" > "$FILES_DIR/etc/bridgebox/box-id"
echo "  BOX_ID: $BOX_ID"

# Auth key (опционально)
if [ -n "$AUTH_KEY" ]; then
    echo "$AUTH_KEY" > "$FILES_DIR/etc/bridgebox/auth-key"
    echo "  AUTH_KEY: задан"
else
    rm -f "$FILES_DIR/etc/bridgebox/auth-key"
fi
