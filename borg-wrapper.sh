#!/bin/bash
set -euo pipefail

REPO="$1"
CONFIG="$REPO/config"

if ! echo "$REPO" | grep -qE '^/[a-zA-Z0-9/_-]+$'; then
    echo "DENY: invalid repo path" >&2
    exit 1
fi

# ---------------------------------------------------------
# Non-borg commands (info channel)
# ---------------------------------------------------------
case "${SSH_ORIGINAL_COMMAND:-}" in
    info)
        if [ -f "$REPO/info.txt" ]; then
            cat "$REPO/info.txt"
        else
            echo "no info available yet"
        fi
        exit 0
        ;;
    "")
        # normal borg client connection, fall through below
        ;;
    *)
        echo "DENY: unknown command" >&2
        exit 1
        ;;
esac

# Case 1: directory does not exist or is completely empty
# -> never initialized yet, client is allowed to run "borg init"
if [ ! -e "$REPO" ] || [ -z "$(ls -A "$REPO" 2>/dev/null)" ]; then
    mkdir -p "$REPO"
    exec borg serve --restrict-to-path "$REPO" --append-only
fi

# Case 2: directory exists and has content, but config is missing
# -> suspicious (corruption, manual deletion, etc.), do NOT allow automatically
if [ ! -f "$CONFIG" ]; then
    echo "DENY: repo non-empty but config missing – needs manual admin review" >&2
    exit 1
fi

# Case 3: normal operation – config present, check encryption mode
MODE=$(grep "^encryption" "$CONFIG" | head -n1 | cut -d= -f2 | tr -d ' ')

case "$MODE" in
    repokey*|keyfile*) ;;
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
