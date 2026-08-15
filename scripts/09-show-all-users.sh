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

# The four cells describing one client, pipe-separated:
# "<quota>|<% of volume>|<configured>|<used>". Short markers stand in for any
# of them that cannot be determined.
report_for() {
    grp="$1"; user="$2"; want="$3"
    if [ -z "${HOST_REPO_BASE:-}" ]; then
        echo "n/a|n/a|${want}|n/a (HOST_REPO_BASE not set)"
        return
    fi
    d="${HOST_REPO_BASE}/${grp}/${user}"
    if [ ! -d "$d" ]; then
        echo "n/a|n/a|${want}|MISSING on host"
        return
    fi
    line=$(df -kP "$d" 2>/dev/null | awk 'NR==2{print $2, $3}') || { echo "n/a|n/a|${want}|unreadable"; return; }
    size_kib=$(echo "$line" | cut -d' ' -f1)
    used_kib=$(echo "$line" | cut -d' ' -f2)
    case "$size_kib" in ''|*[!0-9]*) echo "n/a|n/a|${want}|unreadable"; return ;; esac
    case "$used_kib" in ''|*[!0-9]*) used_kib=0 ;; esac

    # From config.sh, which the quota preview in 00/02 uses too, so a client's
    # state reads identically wherever it is reported. A (!) in the CONFIGURED
    # cell is drift: clients.conf records one limit and the kernel applies
    # another, and the kernel is the one the client will hit.
    row=$(quota_row_fields "$size_kib" "$want" "$VOLUME_KIB" "$used_kib")
    case "$row" in
        *"(!)"*) : > "$DRIFT_MARKER" ;;
    esac
    echo "$row"
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
    printf '%-24s %-12s %-9s %-12s %s\n' \
        "USERNAME" "QUOTA" "% OF VOL" "CONFIGURED" "USED"
    printf '%s\n' "$ROSTER" | awk -F: -v g="$GROUP" '$2==g {print $1, $4}' | sort | \
    while read -r USERNAME QUOTA; do
        [ -n "$USERNAME" ] || continue
        IFS='|' read -r C_QUOTA C_PCT C_CONF C_USED <<EOF
$(report_for "$GROUP" "$USERNAME" "$QUOTA")
EOF
        printf '%-24s %-12s %-9s %-12s %s\n' \
            "$USERNAME" "$C_QUOTA" "$C_PCT" "$C_CONF" "$C_USED"
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

# The invariant from OPERATIONS.md Chapter 10.2: the sum of all enforced
# quotas has to stay within the volume, or the quotas stop protecting it.
# Reported here continuously, because the chapter asks the operator to check
# the sum before raising a quota and nothing computed it for them.
if [ -n "$VOLUME_KIB" ]; then
    read -r COMMITTED_KIB COMMITTED_N COMMITTED_UNBOUNDED <<EOF
$(quota_committed "$VOLUME_KIB")
EOF
    COMMITTED_TOTAL=$(quota_committed_total "$COMMITTED_KIB" "$COMMITTED_UNBOUNDED" "$VOLUME_KIB")
    COMMITTED_MARK=""
    quota_exceeds_pct "$COMMITTED_TOTAL" "$VOLUME_KIB" 99 && COMMITTED_MARK=" (!)"
    echo "Committed:     $(quota_human "$COMMITTED_TOTAL") of $(quota_human "$VOLUME_KIB") volume ($(quota_pct "$COMMITTED_TOTAL" "$VOLUME_KIB")%)${COMMITTED_MARK} across $((COMMITTED_N + COMMITTED_UNBOUNDED)) client(s)"
    if [ "$COMMITTED_UNBOUNDED" -gt 0 ]; then
        if [ "$COMMITTED_UNBOUNDED" -eq 1 ]; then
            UNBOUNDED_PHRASE="1 of them has no limit in effect"
        else
            UNBOUNDED_PHRASE="${COMMITTED_UNBOUNDED} of them have no limit in effect"
        fi
        if [ "$COMMITTED_KIB" -lt "$VOLUME_KIB" ]; then
            REMAINING_KIB=$((VOLUME_KIB - COMMITTED_KIB))
            echo "               ${UNBOUNDED_PHRASE}, counted as the"
            echo "               $(quota_human "$REMAINING_KIB") the others have not claimed rather than as a"
            echo "               configured quota — nothing stops them taking it (Chapter 10.2)."
        else
            echo "               ${UNBOUNDED_PHRASE}, on a volume the limited"
            echo "               clients already claim in full (Chapter 10.2)."
        fi
    fi
fi

# Real physical disk usage of the underlying filesystem (df on HOST_REPO_BASE
# itself, not a client subdirectory) — this is the actual disk fill level,
# independent of any individual client's quota.
if [ -n "${HOST_REPO_BASE:-}" ] && [ -d "$HOST_REPO_BASE" ]; then
    DISKLINE=$(df -kP "$HOST_REPO_BASE" 2>/dev/null | awk 'NR==2{print $2, $3, $4, $5}')
    if [ -n "$DISKLINE" ]; then
        d_size=$(echo "$DISKLINE" | cut -d' ' -f1)
        d_used=$(echo "$DISKLINE" | cut -d' ' -f2)
        d_avail=$(echo "$DISKLINE" | cut -d' ' -f3)
        d_pct=$(echo "$DISKLINE" | cut -d' ' -f4)
        echo "Disk usage:    $(quota_human "$d_used") of $(quota_human "$d_size") (${d_pct})"
        # df's own Available figure, not size minus used: a filesystem can
        # reserve blocks that are counted as neither, and what a client can
        # still write is what df says is available.
        echo "Disk free:     $(quota_human "$d_avail")"
    else
        echo "Disk usage:    unreadable"
        echo "Disk free:     unreadable"
    fi
else
    echo "Disk usage:    n/a (HOST_REPO_BASE not set or not accessible)"
    echo "Disk free:     n/a (HOST_REPO_BASE not set or not accessible)"
fi
