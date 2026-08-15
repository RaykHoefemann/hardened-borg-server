#!/bin/sh
#
# 09-show-all-users.sh
# -----------------
# Overview of all configured Borg clients, grouped by group (OWN/MIRROR),
# showing each user's configured quota, the quota actually ENFORCED for it,
# and live storage usage.
#
# Both the enforced limit and the live usage are read the same way the
# container's own 'info' SSH command does (see README Chapter 7): directly
# from the enforcing XFS project quota via 'df' on the client's host
# repository directory — no xfs_quota tooling needed, read-only, does not
# require root.
#
# The ENFORCED column exists because clients.conf only records what was
# requested. If the two disagree, the filesystem wins and the client is
# limited by something other than what the operator believes — so a
# disagreement is flagged with (!) rather than left to be noticed by
# comparing numbers.
#
# If HOST_REPO_BASE is not reachable, or a client's repo directory does not
# exist yet (e.g. right after 00-ssh-create-user.sh before first quota setup,
# or clients.conf/filesystem drift), the columns show a clear marker instead
# of failing the whole listing.
#
# Usage:
#   ./scripts/09-show-all-users.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

if [ ! -f "$CONF" ]; then
    echo "No clients.conf found at '$CONF' (no users configured yet)."
    exit 0
fi

# Read the roster once, through the shared filter (config.sh: clients_lines),
# and work from that everywhere below. Reading "$CONF" directly is what made
# this script report the format header the container writes into a fresh
# clients.conf as two clients and a phantom group.
#
# "Empty" is decided on client lines, not file size: a clients.conf that holds
# only that header is not an empty file, but it does describe no clients.
ROSTER=$(clients_lines)

if [ -z "$ROSTER" ]; then
    echo "clients.conf lists no clients — no users configured yet."
    exit 0
fi

# Normalize base path the same way 00/02 do, so path construction below stays
# correct regardless of whether config.sh has a trailing slash.
HOST_REPO_BASE="${HOST_REPO_BASE%/}"

# Size of the storage volume itself. A client directory whose df size equals
# this is not covered by a project quota at all — df then simply reports the
# whole filesystem, which must not be mistaken for a very large quota.
VOLUME_KIB=""
if [ -n "${HOST_REPO_BASE:-}" ] && [ -d "$HOST_REPO_BASE" ]; then
    VOLUME_KIB=$(quota_enforced_kib "$HOST_REPO_BASE")
fi

# Any client whose enforced limit disagrees with clients.conf touches this
# file. The per-client loop below runs inside a pipeline, i.e. in a subshell
# on every POSIX shell, so a variable set there would not survive — a file is
# the one signal that does.
DRIFT_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$DRIFT_DIR"' EXIT INT TERM
DRIFT_MARKER="${DRIFT_DIR}/drift"

# Enforced limit and usage for one client, as "<enforced>|<used>". Both are
# short markers when they cannot be determined.
report_for() {
    grp="$1"; user="$2"; want="$3"
    if [ -z "${HOST_REPO_BASE:-}" ]; then
        echo "n/a|n/a (HOST_REPO_BASE not set)"
        return
    fi
    d="${HOST_REPO_BASE}/${grp}/${user}"
    if [ ! -d "$d" ]; then
        echo "n/a|MISSING on host"
        return
    fi
    line=$(df -kP "$d" 2>/dev/null | awk 'NR==2{print $2, $3}') || { echo "n/a|unreadable"; return; }
    size_kib=$(echo "$line" | cut -d' ' -f1)
    used_kib=$(echo "$line" | cut -d' ' -f2)
    case "$size_kib" in ''|*[!0-9]*) echo "n/a|unreadable"; return ;; esac
    case "$used_kib" in ''|*[!0-9]*) used_kib=0 ;; esac

    # No quota in effect: either nothing is accounted at all, or df is
    # reporting the whole volume because the directory has no project limit.
    if [ "$size_kib" -eq 0 ] || { [ -n "$VOLUME_KIB" ] && [ "$size_kib" = "$VOLUME_KIB" ]; }; then
        : > "$DRIFT_MARKER"
        printf 'none (!)|%s (unlimited)' "$(quota_human "$used_kib")"
        return
    fi

    want_kib=$(quota_kib "$want" 2>/dev/null) || want_kib=""
    if [ "$size_kib" = "$want_kib" ]; then
        enforced="ok"
    else
        : > "$DRIFT_MARKER"
        enforced="$(quota_human "$size_kib") (!)"
    fi

    pct=$(( used_kib * 100 / size_kib ))
    printf '%s|%s of %s (%s%%)' \
        "$enforced" "$(quota_human "$used_kib")" "$(quota_human "$size_kib")" "$pct"
}

# Distinct groups, in the order they first appear in clients.conf.
#
# NOT named GROUPS: in bash that is a built-in array holding the current
# user's group IDs, and assignments to it are silently ignored. This script
# runs under /bin/sh, which is dash on Debian/Ubuntu (where the assignment
# would work) but bash on Fedora CoreOS — the platform this project requires.
# There, the loop would have iterated over the operator's numeric group IDs
# and listed no clients at all.
CLIENT_GROUPS=$(printf '%s\n' "$ROSTER" | awk -F: '{print $2}' | awk '!seen[$0]++')

for GROUP in $CLIENT_GROUPS; do
    echo "=== ${GROUP} ==="
    printf '%-24s %-10s %-14s %s\n' "USERNAME" "QUOTA" "ENFORCED" "USED"
    printf '%s\n' "$ROSTER" | awk -F: -v g="$GROUP" '$2==g {print $1, $4}' | sort | \
    while read -r USERNAME QUOTA; do
        [ -n "$USERNAME" ] || continue
        REPORT=$(report_for "$GROUP" "$USERNAME" "$QUOTA")
        printf '%-24s %-10s %-14s %s\n' \
            "$USERNAME" "$QUOTA" "${REPORT%%|*}" "${REPORT#*|}"
    done
    echo ""
done

if [ -e "$DRIFT_MARKER" ]; then
    echo "(!) The enforced limit does not match clients.conf for at least one"
    echo "    client — the filesystem is what actually applies. Re-apply the"
    echo "    intended value with ./scripts/02-change-user-quota.sh <user> <quota>."
    echo ""
fi

TOTAL=$(printf '%s\n' "$ROSTER" | wc -l | tr -d ' ')
echo "Total clients: $TOTAL"

# Real physical disk usage of the underlying filesystem (df on HOST_REPO_BASE
# itself, not a client subdirectory) — this is the actual disk fill level,
# independent of any individual client's quota.
if [ -n "${HOST_REPO_BASE:-}" ] && [ -d "$HOST_REPO_BASE" ]; then
    DISKLINE=$(df -kP "$HOST_REPO_BASE" 2>/dev/null | awk 'NR==2{print $2, $3, $5}')
    if [ -n "$DISKLINE" ]; then
        d_size=$(echo "$DISKLINE" | cut -d' ' -f1)
        d_used=$(echo "$DISKLINE" | cut -d' ' -f2)
        d_pct=$(echo "$DISKLINE" | cut -d' ' -f3)
        echo "Disk usage:    $(quota_human "$d_used") of $(quota_human "$d_size") (${d_pct})"
    else
        echo "Disk usage:    unreadable"
    fi
else
    echo "Disk usage:    n/a (HOST_REPO_BASE not set or not accessible)"
fi
