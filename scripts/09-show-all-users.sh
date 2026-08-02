#!/bin/sh
#
# 09-show-all-users.sh
# -----------------
# Overview of all configured Borg clients, grouped by group (OWN/MIRROR),
# showing each user's configured quota and live storage usage.
#
# Live usage is read the same way the container's own 'info' SSH command
# does (see README Chapter 7): directly from the enforcing XFS project quota
# via 'df' on the client's host repository directory — no xfs_quota tooling
# needed, read-only, does not require root.
#
# If HOST_REPO_BASE is not reachable, or a client's repo directory does not
# exist yet (e.g. right after 00-ssh-create-user.sh before first quota setup,
# or clients.conf/filesystem drift), the usage column shows a clear marker
# instead of failing the whole listing.
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

if [ ! -s "$CONF" ]; then
    echo "clients.conf is empty — no users configured yet."
    exit 0
fi

# Normalize base path the same way 00/02 do, so path construction below stays
# correct regardless of whether config.sh has a trailing slash.
HOST_REPO_BASE="${HOST_REPO_BASE%/}"

fmt_bytes() { # KiB in -> human, mirrors the wrapper's info-channel formatting
    awk -v k="$1" 'BEGIN{
        if (k>=1048576) printf "%.1f GiB", k/1048576;
        else if (k>=1024) printf "%.1f MiB", k/1024;
        else printf "%d KiB", k; }'
}

# usage line for one client: "<used_human> of <quota_human> (<pct>%)", or a
# short marker if it cannot be determined.
usage_for() {
    grp="$1"; user="$2"
    if [ -z "${HOST_REPO_BASE:-}" ]; then
        echo "n/a (HOST_REPO_BASE not set)"
        return
    fi
    d="${HOST_REPO_BASE}/${grp}/${user}"
    if [ ! -d "$d" ]; then
        echo "MISSING on host"
        return
    fi
    line=$(df -kP "$d" 2>/dev/null | awk 'NR==2{print $2, $3}') || { echo "unreadable"; return; }
    size_kib=$(echo "$line" | cut -d' ' -f1)
    used_kib=$(echo "$line" | cut -d' ' -f2)
    case "$size_kib" in ''|*[!0-9]*) echo "unreadable"; return ;; esac
    if [ "$size_kib" -eq 0 ]; then
        echo "0 (no quota set)"
        return
    fi
    pct=$(( used_kib * 100 / size_kib ))
    printf '%s of %s (%s%%)' "$(fmt_bytes "$used_kib")" "$(fmt_bytes "$size_kib")" "$pct"
}

# Distinct groups, in the order they first appear in clients.conf.
#
# NOT named GROUPS: in bash that is a built-in array holding the current
# user's group IDs, and assignments to it are silently ignored. This script
# runs under /bin/sh, which is dash on Debian/Ubuntu (where the assignment
# would work) but bash on Fedora CoreOS — the platform this project requires.
# There, the loop would have iterated over the operator's numeric group IDs
# and listed no clients at all.
CLIENT_GROUPS=$(awk -F: '{print $2}' "$CONF" | awk '!seen[$0]++')

for GROUP in $CLIENT_GROUPS; do
    echo "=== ${GROUP} ==="
    printf '%-24s %-10s %s\n' "USERNAME" "QUOTA" "USED"
    awk -F: -v g="$GROUP" '$2==g {print $1, $4}' "$CONF" | sort | \
    while read -r USERNAME QUOTA; do
        [ -n "$USERNAME" ] || continue
        USAGE=$(usage_for "$GROUP" "$USERNAME")
        printf '%-24s %-10s %s\n' "$USERNAME" "$QUOTA" "$USAGE"
    done
    echo ""
done

TOTAL=$(wc -l < "$CONF" | tr -d ' ')
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
        echo "Disk usage:    $(fmt_bytes "$d_used") of $(fmt_bytes "$d_size") (${d_pct})"
    else
        echo "Disk usage:    unreadable"
    fi
else
    echo "Disk usage:    n/a (HOST_REPO_BASE not set or not accessible)"
fi
