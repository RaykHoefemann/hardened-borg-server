#!/bin/sh
#
# config.sh
# ---------
# Central configuration for all borg-server scripts AND for the systemd
# service (via the generated EnvironmentFile — see 50-service-install.sh).
# This file is the single source of truth: nothing below should be
# duplicated as a literal value anywhere else in the repo.
#
# Source this file at the beginning of each script:
#
#   . "$(dirname "$0")/config.sh"
#
# shellcheck disable=SC2034
#
# Every variable below is consumed by the scripts that SOURCE this file (and
# by the generated systemd EnvironmentFile), never within the file itself.
# Static analysis cannot see across that boundary and reports each one as
# unused, which is why the file-scoped suppression above exists. Real findings
# in this file are still reported.
#
# The last section adds shell FUNCTIONS rather than values: the quota helpers
# shared by 00/02/09. They live here for the same reason the values do — the
# definition of "the enforced quota" must exist exactly once, not once per
# script. They are pure, read-only, and never invoked while sourcing, so the
# generated EnvironmentFile is unaffected.

# Resolve the repository root relative to whichever script sourced this
# file (dirname "$0" is that script's own directory, e.g. ".../scripts"),
# not the caller's current working directory. This makes every path below
# correct regardless of where a script is invoked from.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The release this tree came from. Single source of truth for the version:
# the VERSION file is what SERVERINSTALL clones by tag, what IMAGE below is
# derived from, and what 99-container-status.sh reports — so host side and
# container side cannot drift apart by forgetting to bump one of them. A CI
# check enforces that VERSION, the git tag and the documented image tag agree.
# "unknown" means this tree was assembled by hand rather than installed from a
# release.
RELEASE_VERSION="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo unknown)"

# Where this software comes from. The image carries the same constant (see
# build_authorized_keys.sh, which reports it to clients through the info
# channel); a CI check enforces that the two agree, so an operator and a
# client are never pointed at different sources.
SOURCE_URL="https://github.com/RaykHoefemann/hardened-borg-server"

# --- Host-side paths -------------------------------------------------------

# Config and log storage: kept inside the repo checkout itself.
HOST_CONFIG_BASE="${REPO_ROOT}/config"
HOST_LOG_BASE="${REPO_ROOT}/log"

# Repository storage: MUST point at the XFS filesystem that has ENFORCING
# project quotas (prjquota) enabled — see README Chapter 1.1.3 /
# BEST_PRACTICES.md Chapter 1. ADJUST THIS to your actual storage volume.
# This is also the exact value used to bind-mount /repo in the generated
# systemd unit (see 50-service-install.sh) — so the container is
# guaranteed to mount the same directory that 00/02/09 operate on.
# A trailing slash is optional — every script normalizes this value itself,
# so either "/path/to/repo" or "/path/to/repo/" works the same.
HOST_REPO_BASE="/var/mnt/extern1/borg-server/"

# Container-side path prefix (as seen inside the container).
CONTAINER_REPO_BASE="/repo/"

# Scripts' view of config/keys (used by 00/01/02/09).
CONF="${HOST_CONFIG_BASE}/clients.conf"
KEYDIR="${HOST_CONFIG_BASE}/keys"

# Starting project id for auto-allocation (00-ssh-create-user.sh scans
# existing repo dirs and takes max+1, starting from this floor).
PROJID_BASE=1000

# --- Client roster ---------------------------------------------------------

# The client lines of clients.conf: everything that is neither a comment nor
# blank. There is exactly one place that decides what counts as a client, and
# this is it.
#
# clients.conf is not necessarily bare data. On a fresh installation the
# container's build_authorized_keys.sh creates it with a header explaining the
# format — which is the normal state of every installation whose container was
# started before its first client existed, i.e. the documented order in
# SERVERINSTALL.md. Reading the file without this filter parses that header as
# client data: the format legend becomes a group, the example line becomes a
# client, and a line count becomes the client total.
#
# Matches the container's own parser (build_authorized_keys.sh) and the count
# VERIFICATION.md test 3 performs by hand, so all three agree on who exists.
clients_lines() {
    grep -vE '^[[:space:]]*(#|$)' "$CONF" 2>/dev/null || true
}

# --- Container runtime -----------------------------------------------------

CONTAINER="borg-server"
SERVICE="container-borg-server.service"
# Derived from VERSION above, so a checkout of a release tag already points at
# the image built from that same commit — no editing needed to get a working
# pull. This used to default to ":latest", which does NOT exist during the beta
# phase (see .github/workflows/docker.yml: ":latest" is only published for tags
# without a "-" suffix), so a fresh install could not pull anything at all.
#
# Override this to pin a digest instead of a tag once you have verified the
# image — tags are mutable, digests are not. See docs/VERIFICATION.md, Test 0:
#   IMAGE="ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>"
IMAGE="ghcr.io/raykhoefemann/hardened-borg-server:${RELEASE_VERSION}"
SSH_PORT=2222

# UID/GID of the 'borg' user INSIDE the container. Baked into the image at
# build time (Dockerfile: useradd -u ${PUID} -g ${PGID} ... borg) and fixed
# from then on — entrypoint.sh never reads runtime PUID/PGID env vars, so
# the systemd unit does not pass any; only change this if the image is
# rebuilt with different values. Used exclusively by 00-ssh-create-user.sh
# to set correct host ownership on new repo directories via
# `podman unshare` (rootless Podman UID mapping).
BORG_UID=1111
BORG_GID=1111

# --- Quota helpers ---------------------------------------------------------
#
# Shared by 00 (set a quota), 02 (change a quota) and 09 (report quotas), so
# that "the enforced quota" has exactly one definition everywhere: the value
# the kernel reports through statvfs() on the client's repository directory.
# For a directory covered by an XFS project quota, statvfs() reports the
# project's hard limit as the filesystem size and the project's usage as the
# used blocks — which is also precisely what the client sees in the info
# channel (README Chapter 7). Reading it back this way therefore verifies the
# thing that actually matters (the limit the client will hit), not merely that
# the xfs_quota command exited 0.
#
# All of these are read-only and need no privileges.

# "<n>G" -> KiB. Prints nothing and fails for any other input.
quota_kib() {
    case "$1" in
        *G) ;;
        *) return 1 ;;
    esac
    _q_num="${1%G}"
    case "$_q_num" in
        ''|*[!0-9]*|0) return 1 ;;
    esac
    # A shell does signed 64-bit arithmetic, and 13 digits of GiB overflow it:
    # the product wraps and an absurd request comes back out as a small or
    # negative number that passes every check downstream, including the one
    # that refuses a quota larger than the volume. Nothing near this is a real
    # limit — 12 digits is already a zebibyte — so the value is rejected as
    # unusable rather than silently reinterpreted.
    [ "${#_q_num}" -le 12 ] || return 1
    echo $((_q_num * 1048576))
}

# KiB -> human readable. Mirrors the wrapper's info-channel formatting, so
# host and client never present the same number in two different shapes.
quota_human() {
    awk -v k="$1" 'BEGIN{
        if (k>=1048576) printf "%.1f GiB", k/1048576;
        else if (k>=1024) printf "%.1f MiB", k/1024;
        else printf "%d KiB", k; }'
}

# Hard limit currently enforced on directory $1, in KiB (empty if unreadable).
quota_enforced_kib() { df -kP "$1" 2>/dev/null | awk 'NR==2{print $2}'; }

# Blocks currently used by directory $1's project, in KiB (empty if unreadable).
quota_used_kib() { df -kP "$1" 2>/dev/null | awk 'NR==2{print $3}'; }

# --- Quotas as a share of the volume ---------------------------------------
#
# A bare "60G" says nothing about whether it is generous or reckless. What
# decides that is the volume, and the invariant OPERATIONS.md Chapter 10.2
# names: the sum of all *enforced* quotas must stay within the volume's
# capacity. 00 and 02 state both figures before applying anything, and 09
# reports the sum continuously.

# Size of the storage volume in KiB. HOST_REPO_BASE itself carries no project
# quota — only the client directories below it do — so df on it reports the
# filesystem's own size.
volume_kib() { quota_enforced_kib "${HOST_REPO_BASE%/}"; }

# Physical blocks used on that volume, in KiB — what is really on the disk,
# independent of what any client was promised.
volume_used_kib() { quota_used_kib "${HOST_REPO_BASE%/}"; }

# What is still writable, in KiB. df's own Available column rather than size
# minus used: a filesystem can reserve blocks counted as neither, and what a
# client can still write is what df reports as available.
volume_avail_kib() { df -kP "${HOST_REPO_BASE%/}" 2>/dev/null | awk 'NR==2{print $4}'; }

# <kib> as a whole-percent share of <volume-kib>, truncated. Computed in awk
# rather than $(( )): a quota of 99999999999G is 1.05e17 KiB, and multiplying
# that by 100 overflows the signed 64-bit arithmetic a shell does, which turns
# an absurd value negative and lets it pass a "> 99%" test.
quota_pct() {
    awk -v k="$1" -v v="$2" 'BEGIN { if (v <= 0) { print "?"; exit } printf "%d", (k * 100) / v }'
}

# True when <kib> is more than <pct> percent of <volume-kib>. Decided on the
# exact value, not on the truncated percentage quota_pct prints.
quota_exceeds_pct() {
    awk -v k="$1" -v v="$2" -v p="$3" 'BEGIN { exit !(v > 0 && k > (v * p) / 100) }'
}

# quota_committed <volume-kib> [client-to-skip]
#
# The limits actually enforced across all clients, as
# "<kib> <clients-counted> <clients-unbounded>".
#
# Enforced, not configured — Chapter 10.2 is explicit that a client nothing
# limits contributes the whole remaining volume rather than its clients.conf
# figure. Such a client is therefore not summed but counted separately: the
# honest report is that the sum does not hold while it exists, not a smaller
# number. A client whose directory is missing on the host is skipped; 09 flags
# it as MISSING there.
#
# The loop reads from a heredoc rather than a pipe so it runs in this shell:
# the counters have to survive it.
quota_committed() {
    _qc_vol="$1"
    _qc_skip="${2:-}"
    _qc_sum=0
    _qc_n=0
    _qc_unbounded=0
    while IFS=: read -r _qc_user _qc_group _qc_repo _qc_quota; do
        [ -n "$_qc_user" ] || continue
        [ "$_qc_user" = "$_qc_skip" ] && continue
        _qc_dir="${HOST_REPO_BASE%/}/${_qc_group}/${_qc_user}"
        [ -d "$_qc_dir" ] || continue
        _qc_kib=$(quota_enforced_kib "$_qc_dir")
        case "$_qc_kib" in ''|*[!0-9]*) continue ;; esac
        if [ "$_qc_kib" -eq 0 ] || [ "$_qc_kib" = "$_qc_vol" ]; then
            _qc_unbounded=$((_qc_unbounded + 1))
            continue
        fi
        _qc_sum=$((_qc_sum + _qc_kib))
        _qc_n=$((_qc_n + 1))
    done <<EOF
$(clients_lines)
EOF
    echo "$_qc_sum $_qc_n $_qc_unbounded"
}

# quota_committed_total <bounded-kib> <unbounded-count> <volume-kib>
#
# What is actually committed, given that some clients may have no limit at all.
#
# Leaving an unbounded client out of the figure would make the number look
# *better* the more dangerous the installation gets — the opposite of what it
# is for. Chapter 10.2 says what such a client contributes: not its configured
# quota, but the whole remaining volume, because nothing stops it from taking
# it. So one unbounded client commits everything the bounded ones have not
# already claimed, and the total reaches the volume itself. A quota it was
# configured with is not part of this: no number in clients.conf constrains a
# client the filesystem does not constrain.
quota_committed_total() {
    if [ "$2" -gt 0 ] && [ "$1" -lt "$3" ]; then
        echo "$3"
    else
        echo "$1"
    fi
}

# quota_state_block <label> <volume-kib> <user> <quota-label> <limit-kib>
#                   <bounded-kib> <bounded-n> <unbounded-n>
#
# One state of the installation, in the shape 09-show-all-users.sh reports it:
# the client's own line, then the same Committed/Disk usage/Disk free summary.
# Printed twice by quota_preview — once for what is in effect, once for what
# the change would make of it — so the two blocks can be read against each
# other line by line, and the one line that moves is obvious.
#
# <limit-kib> empty means this client has no row in this state (00, before the
# client exists). A limit of 0, or one equal to the volume, is no limit at all.
quota_state_block() {
    _qs_label="$1"; _qs_vol="$2"; _qs_user="$3"; _qs_quota="$4"; _qs_kib="$5"
    _qs_bounded="$6"; _qs_n="$7"; _qs_unbounded="$8"

    echo "  --- ${_qs_label} ---"

    case "$_qs_kib" in
        ''|*[!0-9]*) ;;
        *)
            printf '  %-24s %-10s %-9s %s\n' "USERNAME" "QUOTA" "% OF VOL" "ENFORCED"
            if [ "$_qs_kib" -eq 0 ] || [ "$_qs_kib" = "$_qs_vol" ]; then
                printf '  %-24s %-10s %-9s %s\n' \
                    "$_qs_user" "$_qs_quota" "$(quota_pct "$_qs_kib" "$_qs_vol")%" "none (!)"
            else
                printf '  %-24s %-10s %-9s %s\n' \
                    "$_qs_user" "$_qs_quota" "$(quota_pct "$_qs_kib" "$_qs_vol")%" \
                    "$(quota_human "$_qs_kib")"
            fi
            ;;
    esac

    _qs_total=$(quota_committed_total "$_qs_bounded" "$_qs_unbounded" "$_qs_vol")
    _qs_mark=""
    quota_exceeds_pct "$_qs_total" "$_qs_vol" 99 && _qs_mark=" (!)"
    echo "  Committed:     $(quota_human "$_qs_total") of $(quota_human "$_qs_vol") volume ($(quota_pct "$_qs_total" "$_qs_vol")%)${_qs_mark} across $((_qs_n + _qs_unbounded)) client(s)"

    # Physical usage and free space are read fresh in each block and are the
    # same in both: a quota is a promise, and changing one moves no data. Shown
    # in both anyway, because the two blocks are meant to be diffed by eye —
    # and because "will this free up space?" is a question the repetition
    # answers without anyone having to ask it.
    _qs_used=$(volume_used_kib)
    _qs_avail=$(volume_avail_kib)
    case "$_qs_used" in
        ''|*[!0-9]*) echo "  Disk usage:    unreadable" ;;
        *) echo "  Disk usage:    $(quota_human "$_qs_used") of $(quota_human "$_qs_vol") ($(quota_pct "$_qs_used" "$_qs_vol")%)" ;;
    esac
    case "$_qs_avail" in
        ''|*[!0-9]*) echo "  Disk free:     unreadable" ;;
        *) echo "  Disk free:     $(quota_human "$_qs_avail")" ;;
    esac

    if [ "$_qs_unbounded" -gt 0 ]; then
        echo "  ($_qs_unbounded client(s) with no limit in effect count as everything"
        echo "   the others have not claimed — see ./scripts/09-show-all-users.sh.)"
    fi
    echo ""
}

# quota_preview <volume-kib> <username> <before-kib> <before-quota>
#               <after-kib> <after-quota>
#
# What 00 and 02 print before touching anything: the installation as it stands,
# then the installation as this change would leave it, both in the same shape.
# <before-kib>/<before-quota> are empty for a client that does not exist yet.
quota_preview() {
    _qp_vol="$1"; _qp_user="$2"; _qp_before="$3"; _qp_before_q="$4"
    _qp_after="$5"; _qp_after_q="$6"

    echo "[quota] Volume ${HOST_REPO_BASE%/} — $(quota_human "$_qp_vol")"
    echo ""

    # Everyone except this client, whose own contribution differs between the
    # two blocks. Read through a heredoc rather than `set --`: the three fields
    # land in named variables in this shell, without splitting a command
    # substitution or overwriting the caller's positional parameters.
    read -r _qp_other_kib _qp_other_n _qp_other_unb <<EOF
$(quota_committed "$_qp_vol" "$_qp_user")
EOF

    # This client's present contribution. Unreadable or absent means it has
    # none; a limit of 0 or one equal to the volume means it is bounded by
    # nothing, which counts as the whole remainder rather than as a number.
    _qp_now_bounded="$_qp_other_kib"
    _qp_now_n="$_qp_other_n"
    _qp_now_unb="$_qp_other_unb"
    case "$_qp_before" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_qp_before" -eq 0 ] || [ "$_qp_before" = "$_qp_vol" ]; then
                _qp_now_unb=$(( _qp_other_unb + 1 ))
            else
                _qp_now_bounded=$(( _qp_other_kib + _qp_before ))
                _qp_now_n=$(( _qp_other_n + 1 ))
            fi
            ;;
    esac

    quota_state_block "current state" "$_qp_vol" "$_qp_user" "$_qp_before_q" \
        "$_qp_before" "$_qp_now_bounded" "$_qp_now_n" "$_qp_now_unb"

    _qp_after_bounded=$(( _qp_other_kib + _qp_after ))
    quota_state_block "after this change" "$_qp_vol" "$_qp_user" "$_qp_after_q" \
        "$_qp_after" "$_qp_after_bounded" "$(( _qp_other_n + 1 ))" "$_qp_other_unb"

    # Said once, under the block it applies to, rather than in both.
    if quota_exceeds_pct \
        "$(quota_committed_total "$_qp_after_bounded" "$_qp_other_unb" "$_qp_vol")" \
        "$_qp_vol" 99; then
        echo "  (!) Quotas that jointly reach the volume stop protecting it: a client"
        echo "      that fills its own limit can then take space another was promised"
        echo "      (OPERATIONS.md Chapter 10.2)."
        echo ""
    fi
}

# quota_confirm <prompt>
#
# Anything other than an explicit y is a no. Read from stdin, the way
# 01-ssh-set-user-key.sh asks before overwriting a key.
quota_confirm() {
    printf '%s [y/N] ' "$1"
    read -r _qcf_answer || _qcf_answer=""
    case "$_qcf_answer" in
        y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

# quota_reject_oversized <quota> <kib> <volume-kib>
#
# A limit at or above the volume cannot be enforced: statvfs() then reports the
# whole volume to the client, which is indistinguishable from no quota at all —
# for the client's info channel, for 09's ENFORCED column, and for
# quota_verify, which would read the volume size back and abort *after* the
# limit was already on the filesystem. Refused before anything is applied, and
# before sudo is even reached.
quota_reject_oversized() {
    if ! quota_exceeds_pct "$2" "$3" 99; then
        return 0
    fi
    echo "ERROR: $1 is $(quota_pct "$2" "$3")% of the volume ($(quota_human "$3"))."
    echo "       Quotas above 99% of the volume are refused: a limit at or above"
    echo "       the volume size cannot be enforced. The filesystem reports the"
    echo "       whole volume to the client instead, which is indistinguishable"
    echo "       from no quota at all (VERIFICATION.md test 5)."
    return 1
}

# quota_verify <repo-dir> <quota>
#
# Confirm that <quota> is really the hard limit the kernel now enforces on
# <repo-dir>, and print what is in effect. Returns non-zero with an
# explanation if it is not — a limit that was accepted by xfs_quota but does
# not reach the directory (wrong project id, missing inheritance, quotas not
# enforcing) would otherwise look like success while the client stays
# effectively unlimited until the volume itself runs full.
quota_verify() {
    _qv_dir="$1"
    _qv_want_kib=$(quota_kib "$2") || {
        echo "ERROR: internal: quota_verify called with invalid quota '$2'."
        return 1
    }

    _qv_have_kib=$(quota_enforced_kib "$_qv_dir")
    case "$_qv_have_kib" in
        ''|*[!0-9]*)
            echo "ERROR: could not read back the enforced quota for '$_qv_dir'."
            return 1
            ;;
    esac

    if [ "$_qv_have_kib" -ne "$_qv_want_kib" ]; then
        echo "ERROR: the quota is NOT enforced as requested on '$_qv_dir'."
        echo "       requested: $2 ($(quota_human "$_qv_want_kib"))"
        echo "       enforced:  $(quota_human "$_qv_have_kib")"
        echo "       If the enforced value matches the size of the whole volume,"
        echo "       no project quota applies to this directory at all."
        return 1
    fi

    _qv_used_kib=$(quota_used_kib "$_qv_dir")
    case "$_qv_used_kib" in
        ''|*[!0-9]*) _qv_used_kib=0 ;;
    esac

    echo "[quota] Verified on host: hard limit $(quota_human "$_qv_have_kib") is in effect"
    echo "[quota] Used now: $(quota_human "$_qv_used_kib") of $(quota_human "$_qv_have_kib") ($((_qv_used_kib * 100 / _qv_have_kib))%)"
}
