#!/bin/bash
set -euo pipefail

REPO="$1"
CONFIG="$REPO/config"

if ! echo "$REPO" | grep -qE '^/[a-zA-Z0-9/_-]+$'; then
    echo "DENY: invalid repo path" >&2
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "DENY: missing repo config" >&2
    exit 1
fi

MODE=$(grep "^encryption" "$CONFIG" | head -n1 | cut -d= -f2 | tr -d ' ')

case "$MODE" in
    repokey*|keyfile*)
        # allowed
        ;;
    none|"")
        echo "DENY: unencrypted repository" >&2
        exit 1
        ;;
    *)
        echo "DENY: unknown encryption mode: $MODE" >&2
        exit 1
        ;;
esac

exec borg serve --restrict-to-path "$REPO" --append-only
