#!/bin/sh
#
# 09-show-all-users.sh
# -----------------
# Overview of all configured Borg clients — one flat table — showing each
# user's configured quota, the quota actually ENFORCED for it, and live
# storage usage.
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
# clients.conf as a phantom client.
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

# Any client whose enforced limit disagrees with clients.conf touches the first
# file; any client with no repository directory at all touches the second. The
# per-client loop below runs inside a pipeline, i.e. in a subshell on every
# POSIX shell, so a variable set there would not survive — a file is the one
# signal that does.
#
# Two markers rather than one because the two states need different advice:
# drift is corrected with 02-change-user-quota.sh, and a missing directory is
# precisely what that script refuses — it has nothing to set a limit on. That
# one goes to 03-provision-client.sh. One hint covering both would send half its
# readers to a script that cannot help them.
DRIFT_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$DRIFT_DIR"' EXIT INT TERM
DRIFT_MARKER="${DRIFT_DIR}/drift"
MISSING_MARKER="${DRIFT_DIR}/missing"
UNREADABLE_MARKER="${DRIFT_DIR}/unreadable"

# The four cells describing one client, pipe-separated:
# "<quota>|<% of volume>|<configured>|<used>". Short markers stand in for any
# of them that cannot be determined.
report_for() {
    user="$1"; want="$2"
    if [ -z "${HOST_REPO_BASE:-}" ]; then
        # Marked like the two states below — nothing here is measurable, which
        # is something being wrong rather than something being absent. No hint
        # under the listing for this one: the cell names its own cause, and the
        # condition is global, so every row would be repeating the same
        # sentence that the paragraph underneath would then repeat again.
        echo "n/a (!)|n/a|${want}|n/a (HOST_REPO_BASE not set)"
        return
    fi
    d="${HOST_REPO_BASE}/${user}"
    if [ ! -d "$d" ]; then
        # Marked, because this is the state OPERATIONS Chapter 9.5 describes a
        # (!) as meaning: intention and reality disagree for this client.
        # clients.conf records a quota, the filesystem holds nothing to apply it
        # to, and the client cannot connect at all — the wrapper refuses a
        # repository directory that is not there rather than creating one it
        # could not give a project id. The row said all of this in its USED cell
        # and left the marked columns clean, so a listing containing it read as
        # a pass to VERIFICATION check 5.5A, whose criterion reads those
        # columns (#30).
        #
        # 'n/a' rather than 'none': none (!) means a directory that is served
        # with no limit on it, which is a different and less obvious failure —
        # 5.5B's first shape. Nothing is served here at all.
        : > "$MISSING_MARKER"
        echo "n/a (!)|n/a|${want}|MISSING on host"
        return
    fi
    # Available as well as size and used: the USED percentage is a fill level
    # taken from df's own two figures, which is exactly what the client is told
    # through the info channel (borg-wrapper.sh). Deriving it from the limit
    # here instead would be a second opinion on the same measurement.
    #
    # A failure here is caught by the emptiness of $line, and only by that.
    # This used to carry a `|| { ...unreadable...; return; }` as well, which
    # could not fire: the exit status of a pipeline is the status of its last
    # command, and awk succeeds on empty input however badly df did. POSIX sh
    # has no pipefail to change that, so the guard below is the real one and
    # the redundant branch has been removed rather than left to look load-
    # bearing.
    line=$(df -kP "$d" 2>/dev/null | awk 'NR==2{print $2, $3, $4}')
    size_kib=$(echo "$line" | cut -d' ' -f1)
    used_kib=$(echo "$line" | cut -d' ' -f2)
    avail_kib=$(echo "$line" | cut -d' ' -f3)
    # Marked, for the same reason as MISSING above but on a weaker claim. The
    # directory is there — `-d` passed — and df still reported nothing for it.
    # statfs() needs search permission on every parent, not on the target, so
    # this is HOST_REPO_BASE the operator can no longer traverse, or a volume
    # that is no longer mounted. Where MISSING says "this client is broken",
    # this says "nothing is known about this client", and a check that reads
    # these columns must not call that a pass either.
    case "$size_kib" in
        ''|*[!0-9]*)
            : > "$UNREADABLE_MARKER"
            echo "n/a (!)|n/a|${want}|unreadable"
            return
            ;;
    esac
    case "$used_kib" in ''|*[!0-9]*) used_kib=0 ;; esac
    case "$avail_kib" in ''|*[!0-9]*) avail_kib="" ;; esac

    # From config.sh, which the quota preview in 00/02 uses too, so a client's
    # state reads identically wherever it is reported. A (!) in the CONFIGURED
    # cell is drift: clients.conf records one limit and the kernel applies
    # another, and the kernel is the one the client will hit.
    row=$(quota_row_fields "$size_kib" "$want" "$VOLUME_KIB" "$used_kib" "$avail_kib")
    case "$row" in
        *"(!)"*) : > "$DRIFT_MARKER" ;;
    esac
    echo "$row"
}

# One flat table of every client. Groups were removed in 1.0.0 (DESIGN 1.2.3);
# separating trust levels is now a second instance of this project, each with
# its own 09-show-all-users.sh.
printf '%-24s %-12s %-9s %-12s %s\n' \
    "USERNAME" "QUOTA" "% OF VOL" "CONFIGURED" "USED"
printf '%s\n' "$ROSTER" | awk -F: '{print $1, $3}' | sort | \
while read -r USERNAME QUOTA; do
    [ -n "$USERNAME" ] || continue
    IFS='|' read -r C_QUOTA C_PCT C_CONF C_USED <<EOF
$(report_for "$USERNAME" "$QUOTA")
EOF
    printf '%-24s %-12s %-9s %-12s %s\n' \
        "$USERNAME" "$C_QUOTA" "$C_PCT" "$C_CONF" "$C_USED"
done
echo ""

# Printed before the drift hint: a client that cannot connect at all outranks
# one that connects under the wrong limit.
if [ -e "$MISSING_MARKER" ]; then
    echo "(!) At least one client in clients.conf has no repository directory on"
    echo "    the host. Nothing is enforced for it and nothing serves it: its next"
    echo "    connection is refused with 'DENY: repository directory missing'."
    echo "    Only the host can create one — the ownership needs 'podman unshare'"
    echo "    and the quota an XFS project id:"
    echo ""
    echo "        ./scripts/03-provision-client.sh <user>"
    echo ""
    echo "    A recreated directory is empty: it restores the client's access, not"
    echo "    its archives. Find out where the directory went before recreating it"
    echo "    (OPERATIONS.md chapter 9.4.1)."
    echo ""
fi

if [ -e "$DRIFT_MARKER" ]; then
    echo "(!) The enforced limit does not match clients.conf for at least one"
    echo "    client — the filesystem is what actually applies. Re-apply the"
    echo "    intended value with ./scripts/02-change-user-quota.sh <user> <quota>."
    echo ""
fi

# Last of the three: the other two name a fault, this one names a blind spot.
if [ -e "$UNREADABLE_MARKER" ]; then
    echo "(!) At least one client's quota could not be read. Its repository"
    echo "    directory exists, but df reported nothing for it — usually a"
    echo "    directory in the path that can no longer be traversed, or a storage"
    echo "    volume that is no longer mounted. Check the permissions on"
    echo ""
    echo "        ${HOST_REPO_BASE%/}"
    echo ""
    echo "    and that the volume is still mounted. Until then this listing is"
    echo "    incomplete: nothing is known about that client's limit in either"
    echo "    direction."
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
    quota_exceeds_pct "$COMMITTED_TOTAL" "$VOLUME_KIB" 99 && {
        COMMITTED_MARK=" (!)"
        OVERCOMMITTED=1
    }
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
# independent of any individual client's quota. From config.sh, because the
# quota preview in 00/02 ends on the same two lines and they have to be the
# same two lines.
quota_disk_lines

# Every (!) in this listing gets an explanation under it, and this one had
# none: the marker on the Committed line was printed bare while the drift
# marker in the columns has said what it means since it existed. An unexplained
# marker in the output of a tool whose other marker decides VERIFICATION test 5
# teaches the operator to wave both away (issue #17). 00 and 02 have printed
# this text on the same condition all along; the listing was the one place that
# stayed silent.
#
# Printed after the summary rather than inside it: Committed, Disk usage and
# Disk free are read as one block, and a three-line paragraph in the middle of
# them is a worse answer than one below.
if [ -n "${OVERCOMMITTED:-}" ]; then
    echo ""
    echo "(!) The quotas in effect jointly reach the volume. Each client is still held"
    echo "    to its own limit — but they cannot all be honoured at once: whoever fills"
    echo "    up first takes the space the others were promised (Chapter 10.2)."
fi
