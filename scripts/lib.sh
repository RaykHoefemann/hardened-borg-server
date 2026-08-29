#!/bin/sh
#
# lib.sh
# ------
# The shell FUNCTIONS shared by the host scripts. Sourced by config.sh, which
# every script sources in turn — so nothing here has to be sourced directly,
# and nothing here is meant to be edited.
#
# It lives beside config.sh rather than inside it because the two are different
# kinds of file with different lifecycles. config.sh is shipped code *and*
# per-host configuration in one place: an operator edits HOST_REPO_BASE and
# IMAGE there, and an upgrade diffs it to carry those settings forward
# (DEPLOYMENT.md chapter 6.3, step 6). That diff is only useful while it shows
# settings; when the same file also carried 750 lines of helpers, a release
# that touched one of them buried the two lines the operator was looking for.
# This file is replaced wholesale by an upgrade and never diffed.
#
# shellcheck disable=SC2034
#
# Everything here is consumed by the scripts that source config.sh, never
# within these files themselves, which static analysis cannot see across.
#
# --- What is defined here, and what each half may do ------------------------
#
# READ (quota_*, clients_lines, volume_kib): who the clients are, what limit
# the kernel enforces for each of them, and how to render that. Pure, no
# privileges, safe in any script.
#
# WRITE (repo_*): the host-side half of provisioning a client — the repository
# directory, its ownership, its XFS project id, its hard limit. These need
# `podman unshare` and `sudo xfs_quota`, and the fact that neither exists
# inside the container is the reason borg-wrapper.sh and
# build_authorized_keys.sh report a missing repository directory rather than
# creating one (OPERATIONS.md chapter 9.12).
#
# Nothing in either half runs while sourcing: these are definitions, so a
# read-only script like 09-show-all-users.sh sources them and executes none.
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
# client data: the example line becomes a client, and a line count becomes the
# client total.
#
# Matches the container's own parser (build_authorized_keys.sh) and the count
# VERIFICATION.md test 3 performs by hand, so all three agree on who exists.
clients_lines() {
    grep -vE '^[[:space:]]*(#|$)' "$CONF" 2>/dev/null || true
}

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

# Blocks still writable in directory $1, in KiB (empty if unreadable). df's own
# Available column, not size minus used: a filesystem can reserve blocks that
# are counted as neither, and a project quota can be capped by the volume
# running out underneath it. What a client can still write is what df says.
quota_avail_kib() { df -kP "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

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

# <kib> as a whole-percent share of <volume-kib>, truncated. Computed in awk
# rather than $(( )): a quota of 99999999999G is 1.05e17 KiB, and multiplying
# that by 100 overflows the signed 64-bit arithmetic a shell does, which turns
# an absurd value negative and lets it pass a "> 99%" test.
#
# For a *share* — what a client was promised, what all of them jointly claim —
# truncation is right: half a volume should read as 50%, not 51%, and an
# overcommitment should not be printed larger than it is. A *fill level* is a
# different question and uses quota_fill_pct below.
quota_pct() {
    awk -v k="$1" -v v="$2" 'BEGIN { if (v <= 0) { print "?"; exit } printf "%d", (k * 100) / v }'
}

# <used-kib> as a whole-percent fill level of <used-kib> + <avail-kib>,
# rounded UP. This is df's own Capacity rule, and it is deliberate on both
# counts.
#
# Rounded up, because a fill level is a warning rather than a statistic: it has
# to be able to reach 100%, and truncation cannot — a volume with one block
# left reads as 99%, and so does one that is genuinely full. Anything non-empty
# reporting 1% rather than 0% errs the same way, which is the safe direction.
#
# Against used+avail rather than against the size, because that is what makes
# 100% mean "nothing more can be written". A filesystem that reserves blocks
# never reaches its own size — an ext4 root at 37.1 of 49.0 GiB is full for
# everyone but root — and a project quota can be capped by the volume filling
# up underneath it. Taking both figures from df means the host reports exactly
# what the kernel reports to the client through the info channel
# (borg-wrapper.sh), rather than a second opinion computed beside it.
quota_fill_pct() {
    awk -v u="$1" -v a="$2" 'BEGIN {
        t = u + a
        if (t <= 0) { print "?"; exit }
        p = (u * 100) / t
        printf "%d", (p == int(p) ? p : int(p) + 1)
    }'
}

# quota_disk_lines [indent]
#
# The physical state of the storage volume, as the two lines that end both
# 09-show-all-users.sh's listing and each block of the quota preview:
#
#   Disk usage:    100.0 GiB of 4000.0 GiB (3%)
#   Disk free:     3900.0 GiB
#
# One df call for all three figures, in one place, so the listing and the
# preview cannot state the same measurement differently — which they did:
# 09 printed df's Capacity column verbatim while the preview computed a
# truncated share of the volume size, and the two disagreed by a point on the
# same volume read twice in a row.
#
# The percentage is a fill level (quota_fill_pct), the size beside it is the
# volume (as in `Committed` and `% OF VOL`, which are shares and stay
# truncated). On a filesystem with reserved blocks those two denominators
# differ slightly, and the percentage follows the one that can reach 100%.
quota_disk_lines() {
    _qd_indent="${1:-}"

    # Marked, because every (!) means the same thing wherever it appears: this
    # needs attention, something is not right. A figure that could not be
    # measured qualifies — the volume these lines describe is the one the whole
    # installation stands on. Both branches below carry their explanation in
    # the line itself rather than in a paragraph underneath, because this
    # helper is printed inside three different reports.
    if [ -z "${HOST_REPO_BASE:-}" ] || [ ! -d "${HOST_REPO_BASE%/}" ]; then
        echo "${_qd_indent}Disk usage:    n/a (!) (HOST_REPO_BASE not set or not accessible)"
        echo "${_qd_indent}Disk free:     n/a (!) (HOST_REPO_BASE not set or not accessible)"
        return
    fi

    _qd_df=$(df -kP "${HOST_REPO_BASE%/}" 2>/dev/null | awk 'NR==2{print $2, $3, $4}')
    _qd_size=$(echo "$_qd_df" | cut -d' ' -f1)
    _qd_used=$(echo "$_qd_df" | cut -d' ' -f2)
    _qd_avail=$(echo "$_qd_df" | cut -d' ' -f3)
    case "$_qd_size"  in ''|*[!0-9]*) _qd_size=""  ;; esac
    case "$_qd_used"  in ''|*[!0-9]*) _qd_used=""  ;; esac
    case "$_qd_avail" in ''|*[!0-9]*) _qd_avail="" ;; esac

    _qd_bad=""
    if [ -n "$_qd_size" ] && [ -n "$_qd_used" ] && [ -n "$_qd_avail" ]; then
        echo "${_qd_indent}Disk usage:    $(quota_human "$_qd_used") of $(quota_human "$_qd_size") ($(quota_fill_pct "$_qd_used" "$_qd_avail")%)"
    else
        echo "${_qd_indent}Disk usage:    unreadable (!)"
        _qd_bad=1
    fi
    if [ -n "$_qd_avail" ]; then
        echo "${_qd_indent}Disk free:     $(quota_human "$_qd_avail")"
    else
        echo "${_qd_indent}Disk free:     unreadable (!)"
        _qd_bad=1
    fi
    # An `if` rather than a `&&` list: this is the last command of the
    # function, and a trailing test that comes out false would return non-zero
    # into callers that run under `set -e`.
    if [ -n "$_qd_bad" ]; then
        echo "${_qd_indent}(!) The volume's own figures could not be read. Check that the"
        echo "${_qd_indent}    storage volume is still mounted at"
        echo "${_qd_indent}        ${HOST_REPO_BASE%/}"
    fi
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
    while IFS=: read -r _qc_user _qc_repo _qc_quota; do
        [ -n "$_qc_user" ] || continue
        [ "$_qc_user" = "$_qc_skip" ] && continue
        _qc_dir="${HOST_REPO_BASE%/}/${_qc_user}"
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

# quota_row_fields <limit-kib> <configured-quota> <volume-kib> <used-kib>
#                  <avail-kib>
#
# The four cells describing one client, pipe-separated, for 09-show-all-users
# and for the quota preview alike:
#
#   QUOTA        the limit the kernel really applies, or "none (!)" where
#                nothing does
#   % OF VOL     that limit as a share of the volume
#   CONFIGURED   what clients.conf records, marked (!) when the filesystem
#                says otherwise
#   USED         what the client has stored, against the limit that applies
#
# The real limit comes first and the configured one is the annotation, not the
# other way round. Only one of the two ever stops a client from writing, and
# it is not the file: clients.conf records an intention, which is worth seeing
# precisely when it turns out not to have taken effect.
quota_row_fields() {
    _qr_kib="$1"; _qr_conf="$2"; _qr_vol="$3"; _qr_used="$4"; _qr_avail="$5"

    _qr_want=$(quota_kib "$_qr_conf" 2>/dev/null) || _qr_want=""
    if [ -z "$_qr_kib" ] || [ "$_qr_kib" -eq 0 ] \
        || { [ -n "$_qr_vol" ] && [ "$_qr_kib" = "$_qr_vol" ]; }; then
        # No limit in effect: df reports the whole volume, so there is no
        # share to state and whatever clients.conf says is not happening.
        _qr_quota="none (!)"
        _qr_pct="n/a"
        _qr_conf_cell="${_qr_conf:-n/a} (!)"
    else
        _qr_quota="$(quota_human "$_qr_kib")"
        _qr_pct="$(quota_pct "$_qr_kib" "$_qr_vol")%"
        if [ "$_qr_kib" = "$_qr_want" ]; then
            _qr_conf_cell="${_qr_conf:-n/a}"
        else
            _qr_conf_cell="${_qr_conf:-n/a} (!)"
        fi
    fi

    printf '%s|%s|%s|%s' "$_qr_quota" "$_qr_pct" "$_qr_conf_cell" \
        "$(quota_usage_text "$_qr_used" "$_qr_kib" "$_qr_vol" "$_qr_avail")"
}

# quota_usage_text <used-kib> <limit-kib> <volume-kib> <avail-kib>
#
# What a client has stored, against the limit that applies to it — the USED
# column of 09-show-all-users.sh and of the quota preview, so both say it the
# same way. A limit of 0, or one equal to the volume, is no limit at all: there
# is no share to express the usage as, and reporting one would be a fiction.
#
# The percentage is a fill level and comes from df's own two figures
# (quota_fill_pct), which is precisely what borg-wrapper.sh shows the client
# through the info channel. Computing it here as used/limit instead would be a
# second opinion on the same measurement — and was one: the host truncated
# where the client rounded up, so the same client at 62.8% of its quota was
# told 63% and shown 62% by the operator's own listing.
#
# <avail-kib> is empty where nothing measured it — the preview's "after this
# change" block, whose figures are predictions — and then what the limit leaves
# free is used instead. Under an enforced project quota the kernel reports the
# same thing, so the two agree wherever both exist.
quota_usage_text() {
    case "$1" in ''|*[!0-9]*) set -- 0 "$2" "$3" "$4" ;; esac
    if [ -z "$2" ] || [ "$2" -eq 0 ] || [ "$2" = "$3" ]; then
        printf '%s (unlimited)' "$(quota_human "$1")"
    else
        _qu_avail="$4"
        case "$_qu_avail" in
            ''|*[!0-9]*)
                _qu_avail=$(( $2 - $1 ))
                [ "$_qu_avail" -lt 0 ] && _qu_avail=0
                ;;
        esac
        printf '%s of %s (%s%%)' "$(quota_human "$1")" "$(quota_human "$2")" \
            "$(quota_fill_pct "$1" "$_qu_avail")"
    fi
}

# quota_state_block <label> <volume-kib> <user> <quota-label> <limit-kib>
#                   <used-kib> <avail-kib> <bounded-kib> <bounded-n>
#                   <unbounded-n>
#
# One state of the installation, in the shape 09-show-all-users.sh reports it:
# the client's own line, then the same Committed/Disk usage/Disk free summary.
# Printed twice by quota_preview — once for what is in effect, once for what
# the change would make of it — so the two blocks can be read against each
# other line by line, and the one line that moves is obvious.
#
# <limit-kib> empty means no limit could be read for this client: either it
# does not exist yet (00, where <configured-quota> is empty too) or the read
# failed. Both still get a row, so the two blocks stay structurally identical
# and the change is a line-by-line comparison rather than a search.
#
# A limit of 0, or one equal to the volume, is no limit at all.
#
# <avail-kib> is what df reports as still writable for this client, and is
# empty in the "after this change" block, where nothing has measured anything
# yet — quota_usage_text then derives it from the limit.
quota_state_block() {
    _qs_label="$1"; _qs_vol="$2"; _qs_user="$3"; _qs_quota="$4"; _qs_kib="$5"
    _qs_client_used="$6"; _qs_client_avail="$7"; _qs_bounded="$8"; _qs_n="$9"
    _qs_unbounded="${10}"
    _qs_unreadable=""

    echo "  --- ${_qs_label} ---"

    # The same four columns as 09-show-all-users.sh, from the same helper.
    # Under "after this change" they are what the change would make true —
    # usage included: the same bytes are a different fraction of a different
    # limit, which is the headroom being bought.
    printf '  %-24s %-12s %-9s %-12s %s\n' \
        "USERNAME" "QUOTA" "% OF VOL" "CONFIGURED" "USED"
    case "$_qs_kib" in
        ''|*[!0-9]*)
            if [ -z "$_qs_quota" ]; then
                # A client 00 is about to create. Nothing is wrong with a state
                # that has not been reached yet, so no marker.
                _qs_row="n/a|n/a|n/a|does not exist yet"
            else
                # A client that exists, whose enforced limit could not be read.
                # Marked and explained below the block, the same statement
                # 09-show-all-users.sh makes about the same condition.
                _qs_row="n/a (!)|n/a|${_qs_quota}|unreadable"
                _qs_unreadable=1
            fi
            ;;
        *)
            _qs_row=$(quota_row_fields "$_qs_kib" "$_qs_quota" "$_qs_vol" \
                "$_qs_client_used" "$_qs_client_avail")
            ;;
    esac
    IFS='|' read -r _qs_c1 _qs_c2 _qs_c3 _qs_c4 <<EOF
$_qs_row
EOF
    printf '  %-24s %-12s %-9s %-12s %s\n' \
        "$_qs_user" "$_qs_c1" "$_qs_c2" "$_qs_c3" "$_qs_c4"

    _qs_total=$(quota_committed_total "$_qs_bounded" "$_qs_unbounded" "$_qs_vol")
    _qs_mark=""
    quota_exceeds_pct "$_qs_total" "$_qs_vol" 99 && _qs_mark=" (!)"
    echo "  Committed:     $(quota_human "$_qs_total") of $(quota_human "$_qs_vol") volume ($(quota_pct "$_qs_total" "$_qs_vol")%)${_qs_mark} across $((_qs_n + _qs_unbounded)) client(s)"

    # Physical usage and free space are read fresh in each block and are the
    # same in both: a quota is a promise, and changing one moves no data. Shown
    # in both anyway, because the two blocks are meant to be diffed by eye —
    # and because "will this free up space?" is a question the repetition
    # answers without anyone having to ask it. From the same helper as the
    # listing's own pair, so the two cannot report one volume two ways.
    quota_disk_lines "  "

    if [ -n "$_qs_unreadable" ]; then
        echo "  (!) This client's enforced limit could not be read. The directory is"
        echo "      there and df reported nothing for it — check the permissions on"
        echo "      the path and that the volume is still mounted. Nothing below is"
        echo "      known to apply to it."
    fi

    if [ "$_qs_unbounded" -gt 0 ]; then
        echo "  ($_qs_unbounded client(s) with no limit in effect count as everything"
        echo "   the others have not claimed — see ./scripts/09-show-all-users.sh.)"
    fi
    echo ""
}

# quota_preview <volume-kib> <username> <before-kib> <before-quota>
#               <after-kib> <after-quota> <used-kib> <avail-kib>
#
# What 00 and 02 print before touching anything: the installation as it stands,
# then the installation as this change would leave it, both in the same shape.
# <before-kib>/<before-quota> are empty for a client that does not exist yet,
# and so are <used-kib> and <avail-kib>, which are then nothing.
#
# <avail-kib> describes the client as it is now and is therefore passed only to
# the first block. The second one is a prediction: nothing has measured what a
# limit that does not exist yet leaves free, so quota_usage_text derives it from
# that limit.
quota_preview() {
    _qp_vol="$1"; _qp_user="$2"; _qp_before="$3"; _qp_before_q="$4"
    _qp_after="$5"; _qp_after_q="$6"; _qp_used="${7:-0}"; _qp_avail="${8:-}"

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
        "$_qp_before" "$_qp_used" "$_qp_avail" \
        "$_qp_now_bounded" "$_qp_now_n" "$_qp_now_unb"

    _qp_after_bounded=$(( _qp_other_kib + _qp_after ))
    quota_state_block "after this change" "$_qp_vol" "$_qp_user" "$_qp_after_q" \
        "$_qp_after" "$_qp_used" "" \
        "$_qp_after_bounded" "$(( _qp_other_n + 1 ))" "$_qp_other_unb"

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
    _qv_avail_kib=$(quota_avail_kib "$_qv_dir")
    case "$_qv_avail_kib" in
        ''|*[!0-9]*) _qv_avail_kib=$(( _qv_have_kib - _qv_used_kib )) ;;
    esac
    [ "$_qv_avail_kib" -lt 0 ] && _qv_avail_kib=0

    echo "[quota] Verified on host: hard limit $(quota_human "$_qv_have_kib") is in effect"
    echo "[quota] Used now: $(quota_human "$_qv_used_kib") of $(quota_human "$_qv_have_kib") ($(quota_fill_pct "$_qv_used_kib" "$_qv_avail_kib")%)"
}

# --- Repository directories: the host-side half of a client -----------------
#
# Everything above this line reads. Everything below it writes, and all of it
# is host-only by necessity rather than by preference: making a client's
# repository directory usable takes `podman unshare` for the ownership and
# `sudo xfs_quota` for the project id, and neither exists inside the container.
# That is why borg-wrapper.sh and build_authorized_keys.sh report a missing
# directory instead of creating one — a directory either of them made would
# carry the wrong owner and no quota at all.
#
# These functions were lifted out of 00-ssh-create-user.sh and
# 02-change-user-quota.sh, which had grown two copies of the mount lookup, the
# enforcement check and the project-id read, error messages included. The same
# reason config.sh already holds the quota_* reporting helpers applies to
# writing: a client's state must be produced the same way wherever it is
# produced, and there is no second implementation for one of them to drift
# from.
#
# **Convention:** a function whose stdout is a *value* writes its errors to
# stderr; a function whose stdout is prose writes them to stdout, as
# quota_verify and quota_reject_oversized do. stdout is one or the other and
# never both, or a caller capturing a value would capture an error message as
# one.

# repo_ns_uid_ok <base>
#
# Is this operator's user namespace the container's? `podman unshare` resolves
# the mapping of whoever runs it, and run by the wrong user it still succeeds —
# it just creates directories under a mapping the container does not share, and
# the failure surfaces much later as a client whose backups cannot be written.
# So the question is asked directly: inside this user's namespace, who owns the
# repository base?
#
#   BORG_UID  the container has taken ownership of it, i.e. the server has run
#             at least once, and this user's mapping is the container's
#   0         nobody has taken it yet — a fresh installation whose server has
#             not started, where the base is still plainly operator-owned
#
# Anything else means the base belongs to a mapping that is not this user's,
# and the most likely reason is that the container runs as somebody else.
repo_ns_uid_ok() {
    _rn_uid="$(podman unshare stat -c %u "$1" 2>/dev/null || true)"
    case "$_rn_uid" in
        0|"$BORG_UID") return 0 ;;
        ''|*[!0-9]*)
            echo "ERROR: could not read '$1' inside this user's container"
            echo "namespace. Check that rootless podman works for this user"
            echo "(podman info) and that the path is the one bind-mounted as /repo."
            return 1
            ;;
        *)
            echo "ERROR: inside this user's container namespace, '$1'"
            echo "belongs to uid $_rn_uid — neither this user (0) nor the"
            echo "container's borg user (${BORG_UID})."
            echo "Run this script as the same user that runs the container."
            return 1
            ;;
    esac
}

# repo_dir_create <dir>
#
# Created and owned inside the container's user namespace, not on the host.
#
# entrypoint.sh takes ownership of the bind-mounted repository base at every
# container start (chown borg:borg /repo). Under rootless podman that lands on
# the host as the mapped subuid — container 1111 becomes host 524288+1110 or
# whatever the operator's subuid range makes of it — so from the host side the
# base belongs to a user that does not exist, and a plain mkdir here fails with
# "Permission denied" on every installation that has ever started its server.
#
# `podman unshare` enters exactly that mapping, where this operator is root and
# BORG_UID/BORG_GID mean what they mean inside the container.
#
# The mode is deliberately left at the default (755, minus umask): the host
# scripts read these directories back — the project id with lsattr, the quota
# through df — and they run as the operator, who is not the owner. A tighter
# mode would make those reads fail silently.
repo_dir_create() {
    echo "[repo] Creating repository directory: $1"
    podman unshare mkdir -p "$1"
    echo "[repo] Setting container-side ownership: ${BORG_UID}:${BORG_GID}"
    podman unshare chown "${BORG_UID}:${BORG_GID}" "$1"
}

# repo_dir_remove <dir>
#
# Best-effort removal, for rollback paths only: it never removes anything with
# content, because rmdir does not. `|| true` because every caller is already on
# its way to a non-zero exit and reports its own reason — without it, `set -e`
# would abort on the failed rmdir and the caller's `exit 1` would never run,
# replacing a stated error with a bare status.
repo_dir_remove() {
    podman unshare rmdir "$1" 2>/dev/null || true
}

# repo_xfs_mount <dir>
#
# The filesystem mount point actually holding <dir>. Empty when it cannot be
# resolved, which every caller has to treat as fatal: the project id and the
# limit are both set against a mount, and guessing one would apply a quota
# somewhere other than where the client writes.
repo_xfs_mount() {
    df -P "$1" 2>/dev/null | awk 'NR==2 {print $6}'
}

# repo_quota_enforcing <mount>
#
# Project quotas must be on *and enforcing* before anything relies on them.
# `state -p` distinguishes the two: a volume can account without enforcing, and
# a limit set there stops nobody.
repo_quota_enforcing() {
    if sudo xfs_quota -x -c 'state -p' "$1" 2>/dev/null \
        | grep -qE '^[[:space:]]*Enforcement:[[:space:]]*ON'; then
        return 0
    fi
    echo "ERROR: '$1' does not have enforcing XFS project quotas (prjquota)."
    echo "This is a mandatory host requirement (see BEST_PRACTICES.md Chapter 1)."
    return 1
}

# repo_projid <dir>
#
# The XFS project id on <dir>, or empty if there is none or it cannot be read.
# Zero is reported as empty: it is XFS's "no project", not an id.
repo_projid() {
    _rp_id=$(lsattr -p -d "$1" 2>/dev/null | awk '{print $1}')
    case "$_rp_id" in
        ''|*[!0-9]*|0) return 1 ;;
    esac
    echo "$_rp_id"
}

# repo_projid_next [dir-to-skip]
#
# Allocate the next free project id: scan existing repo dirs under
# HOST_REPO_BASE for their current projid and take max+1, starting from
# PROJID_BASE. This needs no separate id registry or database.
#
# A directory whose id cannot be read is an ERROR, not something to skip: the
# scan would then hand out an id that is already in use, and two clients would
# share one quota — each seeing the other's consumption, neither limited to
# what it was promised. Silence is the wrong answer to "I could not read the
# thing this decision depends on". These directories belong to the container's
# mapped uid, so the operator reads them by mode, not ownership; anything that
# tightens that mode surfaces here rather than in a quota that quietly stops
# separating clients.
#
# [dir-to-skip] is a directory that was created moments ago and has no id of
# its own yet — it inherits the parent's, which says nothing about what is in
# use. It is the one entry whose unreadability would mean nothing, so it is not
# consulted.
repo_projid_next() {
    _rpn_skip="${1:-}"
    _rpn_max=$((${PROJID_BASE:-1000} - 1))
    for _rpn_d in "$HOST_REPO_BASE"/*; do
        [ -d "$_rpn_d" ] || continue
        [ "$_rpn_d" = "$_rpn_skip" ] && continue
        _rpn_id=$(lsattr -p -d "$_rpn_d" 2>/dev/null | awk '{print $1}')
        case "$_rpn_id" in
            ''|*[!0-9]*)
                echo "ERROR: cannot read the XFS project id of '$_rpn_d'." >&2
                echo "Allocating an id without it risks reusing one that is already in" >&2
                echo "use, which would put two clients under a single shared quota." >&2
                echo "Check that the directory is readable (mode 755) and on the XFS mount." >&2
                return 1
                ;;
        esac
        [ "$_rpn_id" -gt "$_rpn_max" ] && _rpn_max="$_rpn_id"
    done
    echo $((_rpn_max + 1))
}

# repo_projid_assign <mount> <dir> <projid>
#
# Put <dir> and everything under it into project <projid>. Setting a limit is a
# separate step, and the limit belongs to the id rather than to the directory.
repo_projid_assign() {
    sudo xfs_quota -x -c "project -s -p $2 $3" "$1" >/dev/null
}

# repo_limit_apply <mount> <projid> <limit>
#
# <limit> is passed to xfs_quota verbatim and therefore needs its unit: '50G'
# as clients.conf records it, or '<n>k' when restoring a figure read back in
# KiB. A bare number would be read as filesystem blocks, which is not what any
# caller here means. Whether it reached the directory is quota_verify's
# question, not this one's — xfs_quota reports success for a limit set on an id
# that governs nothing.
repo_limit_apply() {
    sudo xfs_quota -x -c "limit -p bhard=$3 $2" "$1"
}

# repo_limit_clear <mount> <projid>
#
# bhard=0 is XFS for "no limit", which is what a freshly allocated id had
# before anything was set on it. Used when a create is rolled back: the id is
# handed out again by the next create, and leaving a limit on it would make
# that client inherit a number nobody chose for it.
repo_limit_clear() {
    sudo xfs_quota -x -c "limit -p bhard=0 $2" "$1"
}

# repo_limit_current <mount> <projid>
#
# The hard limit currently on <projid>, in KiB, read from xfs_quota rather than
# from df: df reports the volume size when no limit applies, so a rollback
# restoring what df says would write a limit in volume size and make permanent
# the very state these scripts exist to prevent. Empty when it cannot be read,
# which callers must treat as "do not guess".
repo_limit_current() {
    _rlc_kib=$(sudo xfs_quota -x -c "report -p -N -b" "$1" 2>/dev/null \
        | awk -v p="#$2" '$1 == p { print $4; exit }')
    case "$_rlc_kib" in
        ''|*[!0-9]*) return 1 ;;
    esac
    echo "$_rlc_kib"
}
