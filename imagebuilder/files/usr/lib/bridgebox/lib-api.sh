#!/bin/sh
# lib-api.sh — общие функции для API CGI-скриптов

# HTTP ответ JSON
# Использование: json_response '{"ok": true}'
json_response() {
    echo "Content-Type: application/json"
    echo ""
    echo "$1"
}

# HTTP ответ с ошибкой (405 Method Not Allowed)
method_not_allowed() {
    echo "Status: 405 Method Not Allowed"
    json_response '{"ok": false, "error": "method not allowed"}'
    exit 0
}

# Проверить что метод — POST, иначе 405
require_post() {
    if [ "$REQUEST_METHOD" != "POST" ]; then
        method_not_allowed
    fi
}

# Проверить что метод — GET, иначе 405
require_get() {
    if [ "$REQUEST_METHOD" != "GET" ]; then
        method_not_allowed
    fi
}

# Извлечь параметр из QUERY_STRING
# Использование: value=$(query_param "service")
query_param() {
    echo "$QUERY_STRING" | tr '&' '\n' | grep "^${1}=" | head -1 | cut -d= -f2-
}

# JSON-safe строка (экранирует кавычки и backslash)
json_escape() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
