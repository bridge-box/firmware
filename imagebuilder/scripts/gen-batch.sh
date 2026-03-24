#!/bin/sh
# gen-batch.sh — Сгенерировать пакет образов с последовательными BOX_ID
#
# Использование:
#   sh gen-batch.sh <START> <COUNT> <PROFILE> [VARIANT] [AUTH_KEY]
#
# Пример:
#   sh gen-batch.sh 1 100 friendlyarm_nanopi-r3s production
#   → BB-001, BB-002, ..., BB-100

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKEFILE_DIR="$SCRIPT_DIR/.."

START="${1:-1}"
COUNT="${2:-10}"
PROFILE="${3:-}"
VARIANT="${4:-production}"
AUTH_KEY="${5:-}"

if [ -z "$PROFILE" ]; then
    echo "Ошибка: PROFILE не задан" >&2
    echo "Использование: $0 <START> <COUNT> <PROFILE> [VARIANT] [AUTH_KEY]" >&2
    exit 1
fi

END=$((START + COUNT - 1))

echo "=== Batch сборка: BB-$(printf '%03d' $START) ... BB-$(printf '%03d' $END) ==="
echo "  Профиль: $PROFILE"
echo "  Вариант: $VARIANT"
echo "  Количество: $COUNT"
echo ""

BUILT=0
FAILED=0
STARTED_AT=$(date +%s)

i=$START
while [ "$i" -le "$END" ]; do
    BOX_ID="BB-$(printf '%03d' $i)"
    echo "--- [$((i - START + 1))/$COUNT] $BOX_ID ---"

    AUTH_KEY_ARG=""
    if [ -n "$AUTH_KEY" ]; then
        AUTH_KEY_ARG="AUTH_KEY=$AUTH_KEY"
    fi

    if make -C "$MAKEFILE_DIR" image \
        PROFILE="$PROFILE" \
        BOX_ID="$BOX_ID" \
        VARIANT="$VARIANT" \
        $AUTH_KEY_ARG; then
        BUILT=$((BUILT + 1))
    else
        echo "FAIL: $BOX_ID" >&2
        FAILED=$((FAILED + 1))
    fi

    echo ""
    i=$((i + 1))
done

ENDED_AT=$(date +%s)
ELAPSED=$((ENDED_AT - STARTED_AT))

echo "=== Batch завершён ==="
echo "  Собрано: $BUILT"
echo "  Ошибок:  $FAILED"
echo "  Время:   ${ELAPSED}с ($((ELAPSED / COUNT))с на образ)"
echo "  Выход:   $(ls "$MAKEFILE_DIR/output"/*.img.gz 2>/dev/null | wc -l) файлов"
