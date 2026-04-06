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

# --- InitState ADT ---
# FirstBoot:            маркер не существует → return 0
# AlreadyInitialized:   маркер с валидным timestamp → return 1
# CorruptedMarker:      маркер есть, но содержимое невалидно → return 1 (conservative)
BB_INIT_MARKER="/etc/bridgebox/.initialized"

is_first_boot() {
    if [ ! -f "$BB_INIT_MARKER" ]; then
        # InitState::FirstBoot
        return 0
    fi

    local content
    content="$(cat "$BB_INIT_MARKER" 2>/dev/null)"

    if [ -z "$content" ]; then
        # InitState::CorruptedMarker — пустой файл
        logger -t bridgebox -p user.warn \
            "Init marker exists but empty — treating as AlreadyInitialized (conservative)"
        return 1
    fi

    # Проверка что содержимое — валидный unix timestamp (только цифры)
    case "$content" in
        *[!0-9]*)
            # InitState::CorruptedMarker — не число
            logger -t bridgebox -p user.warn \
                "Init marker contains invalid data '$content' — treating as AlreadyInitialized (conservative)"
            return 1
            ;;
        *)
            # InitState::AlreadyInitialized(timestamp)
            return 1
            ;;
    esac
}

mark_initialized() {
    mkdir -p "$(dirname "$BB_INIT_MARKER")"
    safe_write "$BB_INIT_MARKER" "$(date +%s)"
}

# Guard: выполнить команду только при FirstBoot
first_boot_only() {
    if is_first_boot; then
        "$@"
    fi
}
