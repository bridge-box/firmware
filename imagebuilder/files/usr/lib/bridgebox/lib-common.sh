#!/bin/sh
# lib-common.sh — общие утилиты BridgeBox
# Подключение: . /usr/lib/bridgebox/lib-common.sh

# Атомарная запись: write to .tmp, then mv
# Использование: safe_write /path/to/file "content"
safe_write() {
    local file="$1"
    local content="$2"
    local tmp="${file}.tmp"
    echo "$content" > "$tmp" && mv "$tmp" "$file"
}
