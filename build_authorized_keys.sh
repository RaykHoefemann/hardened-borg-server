#!/bin/bash
#
# build_authorized_keys.sh
# ------------------------
# create the file /home/borg/.ssh/authorized_keys based on:
#   /config/clients.conf (Format: name:group:repo:quota)
#   /config/keys/<name>.pub (public ssh-key from user)
#
# Also renders one info text per client under /run/borg-info/, containing
# server contact info (from /config/server_info.conf) and client-specific
# info (user, quota). It is served by borg-wrapper.sh's 'info' channel — see
# $INFO_DIR below for why it lives there and not in the repository.
#
# A client list that is missing or empty is a normal state, not an error: it is
# what a server looks like before its first client is provisioned. Both ends of
# the script are written for it — clients.conf is created if absent, and an
# empty result is written rather than refused unless doing so would destroy an
# authorized_keys that already exists. See the comments at both places.
#
set -euo pipefail

CONF="/config/clients.conf"
KEYDIR="/config/keys"
OUT="/home/borg/.ssh/authorized_keys"
TMPOUT="${OUT}.tmp"
SERVER_INFO="/config/server_info.conf"

# Where each client's info text is rendered, one file per client, mirroring its
# repository path: /repo/OWN/clientA -> /run/borg-info/repo/OWN/clientA.txt.
#
# Under /run rather than in the repository itself, and that is not cosmetic:
# `borg init` refuses to initialize a directory that is not empty, so the
# server writing a file into a client's repository directory made the client's
# very first `borg init` fail — the one command every new client runs.
#
# Rendered here, at container start, rather than read from /config by the
# wrapper on demand: the wrapper runs unprivileged as 'borg' inside a client's
# own session, while clients.conf holds EVERY client's name, path and quota.
# Pre-rendering keeps the promise in DESIGN 2.2 structural — a session can only
# ever reach its own file — instead of making it depend on a parser.
#
# /run is runtime state: not a volume, gone when the container stops, rebuilt
# from clients.conf and server_info.conf on every start. A client removed from
# clients.conf leaves nothing behind (see the pruning pass after the loop).
INFO_DIR="/run/borg-info"

# Identity of the software itself, as opposed to the operator's deployment.
# Baked into the image at build time (Dockerfile), so it cannot be edited into
# something untrue by whoever runs the container. "unknown" means the image was
# built outside the release pipeline.
VERSION_FILE="/VERSION"
RELEASE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null)"
[ -n "$RELEASE_VERSION" ] || RELEASE_VERSION="unknown"
SOURCE_URL="https://github.com/RaykHoefemann/hardened-borg-server"
LOG="/log/build_authorized_keys.log"

# Log Function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG"
}

# sanity checks
#
# server_info.conf goes first, and deliberately so: it is the one file in
# /config that ships with the release and is never generated here, which makes
# it the canary for the mount itself. If it is present, /config is really the
# operator's config directory — and a missing clients.conf then genuinely means
# "no clients provisioned yet" rather than "the volume did not mount". Checking
# it after creating clients.conf below would write a client list into an empty
# or wrongly mounted /config and dress a mount failure up as a valid state.
if [ ! -f "$SERVER_INFO" ]; then
    log "[ERROR] Server info file $SERVER_INFO not found – aborting"
    exit 1
fi

if [ ! -d "$(dirname "$OUT")" ]; then
    log "[ERROR] Target directory $(dirname "$OUT") not found – aborting"
    exit 1
fi

# A fresh installation has no client list yet: config/ ships with
# server_info.conf alone, and 00-ssh-create-user.sh is what first writes
# clients.conf. Creating it empty here rather than aborting means a server can
# be started, verified and handed a host key before any client exists — see the
# empty-result handling at the end of this script for the other half of that.
if [ ! -f "$CONF" ]; then
    log "[INFO] $CONF not found – creating an empty client list"
    cat > "$CONF" <<'EOF'
# Client roster — one line per client:
#
#   name:group:repo:quota
#
# e.g.  user1-os1-pc1:OWN:/repo/OWN/user1-os1-pc1:50G
#
# group is OWN (your own devices) or MIRROR (external partners); quota is
# mandatory and has the form <digits>G. Written by scripts/00-ssh-create-user.sh
# — there is normally no reason to edit this file by hand.
EOF
fi

# Same reasoning: the key directory is populated per client, so on a fresh
# installation there is nothing to have created it yet.
mkdir -p "$KEYDIR"

# ---------------------------------------------------------
# Read server info (validated key=value pairs)
# ---------------------------------------------------------
SERVER_NAME=""
SERVER_LOCATION=""
SERVER_CONTACT=""

while IFS="=" read -r key value; do
    [ -z "$key" ] && continue
    case "$key" in \#*) continue ;; esac
    case "$key" in
        name)     SERVER_NAME="$value" ;;
        location) SERVER_LOCATION="$value" ;;
        contact)  SERVER_CONTACT="$value" ;;
        *)        log "[WARN] Unknown key in $SERVER_INFO: '$key' – ignoring" ;;
    esac
done < "$SERVER_INFO"

if [ -z "$SERVER_NAME" ] || [ -z "$SERVER_LOCATION" ] || [ -z "$SERVER_CONTACT" ]; then
    log "[ERROR] Server info incomplete (name/location/contact required) – aborting"
    exit 1
fi

# Header (write to tempfile, not directly to $OUT)
log "# Starting the build of authorized_keys..."
echo "# Auto-generated authorized_keys" > "$TMPOUT"
echo "# Do not edit manually" >> "$TMPOUT"
echo "" >> "$TMPOUT"

count=0

# Every info file written by this run. What is left over in $INFO_DIR
# afterwards belonged to a client that no longer exists (see below).
written_info=()

# read each line from clients.conf
while IFS=":" read -r name group repo quota; do
    [ -z "$name" ] && continue
    case "$name" in
        \#*) continue ;;
    esac

    # Validate name (used in file path). Must not be empty or start with '-'
    # (a leading dash could be read as an option flag downstream).
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_][a-zA-Z0-9_-]*$'; then
        log "[ERROR] Invalid name '$name' – skipping"
        continue
    fi

    # Validate group (same rule)
    if ! echo "$group" | grep -qE '^[a-zA-Z0-9_][a-zA-Z0-9_-]*$'; then
        log "[ERROR] Invalid group '$group' for '$name' – skipping"
        continue
    fi

    # Validate repo path (used in forced command). Each '/'-separated segment
    # must start with an alphanumeric or underscore, so no segment can be
    # read as an option.
    if ! echo "$repo" | grep -qE '^(/[a-zA-Z0-9_][a-zA-Z0-9_-]*)+$'; then
        log "[ERROR] Invalid repo path for '$name': '$repo' – skipping"
        continue
    fi

    # Validate quota (mandatory, format: <digits>G, e.g. 50G)
    if ! echo "$quota" | grep -qE '^[0-9]+G$'; then
        log "[ERROR] Invalid or missing quota for '$name': '$quota' (expected format: <number>G) – skipping"
        continue
    fi

    log "[INFO] Found user: '$name'"

    KEYFILE="${KEYDIR}/${name}.pub"

    if [ ! -f "$KEYFILE" ]; then
        log "[WARN] No public key found for '$name' – skipping"
        continue
    fi

    if [ ! -s "$KEYFILE" ]; then
        log "[WARN] Public key file for '$name' is empty – skipping"
        continue
    fi

    # Validate SSH key
    if ! ssh-keygen -l -f "$KEYFILE" > /dev/null 2>&1; then
        log "[ERROR] Invalid SSH key for '$name' – skipping"
        continue
    fi

    # Use only the first line – prevents multi-line key files
    # from injecting additional entries that bypass command= or restrict options
    key="$(head -n1 "$KEYFILE")"
    CMD="/borg-wrapper.sh $repo"
    echo "command=\"$CMD\",restrict $key" >> "$TMPOUT"
    log "[INFO] Added key for '$name' with repo '$repo' (quota: $quota)"
    count=$((count + 1))

    # A missing repository directory is reported, never created.
    #
    # This used to be a `mkdir -p "$repo"`, and it could not do the job: the
    # generator runs as root inside the container, so the directory it made was
    # root-owned — unwritable by the 'borg' user the client is served as — and
    # carried no XFS project id, so no quota applied to it. Creating a
    # repository directory correctly needs `podman unshare` for the ownership
    # and `sudo xfs_quota` for the project id, and neither exists in here. Only
    # the host can do it (00-ssh-create-user.sh does exactly those three steps).
    #
    # It also made the state unstable. A client whose directory had been deleted
    # showed up as MISSING on host until the next container start, at which
    # point this line quietly turned it into an unquotaed, root-owned directory
    # that looked like a different fault with a different cause. Reporting it
    # leaves one state with one repair.
    if [ ! -d "$repo" ]; then
        log "[WARN] Repository directory '$repo' is missing for '$name'."
        log "[WARN] This client cannot be served until the host recreates it —"
        log "[WARN] see docs/OPERATIONS.md chapter 9.5 (MISSING on host)."
    fi

    # ---------------------------------------------------------
    # Render this client's info text (see $INFO_DIR at the top)
    # ---------------------------------------------------------
    INFO_FILE="${INFO_DIR}${repo}.txt"
    mkdir -p "$(dirname "$INFO_FILE")"

    # Written atomically, like authorized_keys below. This script normally runs
    # at container start, before sshd exists — but it can also be run inside a
    # live container, where an 'info' request may read the file at the very
    # moment it is rewritten. A torn read would misreport an account.
    #
    # 'quota (configured)' is labelled, not bare. The wrapper prints a live
    # 'Used: X of Y' line straight after this text, and that Y is the limit the
    # filesystem actually enforces — read through statvfs() at query time. This
    # value is the one clients.conf recorded when the file was last rendered.
    # The two normally agree and can legitimately differ for a while (a quota
    # changed by 02-change-user-quota.sh takes effect immediately but this text
    # is only rewritten when the script runs again), so the client is told which
    # is which rather than being shown two unlabelled numbers claiming to be the
    # same thing. VERIFICATION 5.5B decides on the enforced one (#28).
    cat > "${INFO_FILE}.tmp" <<EOF
[server]
name: ${SERVER_NAME}
location: ${SERVER_LOCATION}
contact: ${SERVER_CONTACT}

[software]
version: ${RELEASE_VERSION}
source: ${SOURCE_URL}

[client]
user: ${name}
quota (configured): ${quota}
EOF

    chown borg:borg "${INFO_FILE}.tmp"
    chmod 600 "${INFO_FILE}.tmp"
    mv "${INFO_FILE}.tmp" "$INFO_FILE"
    written_info+=("$INFO_FILE")
    log "[INFO] Rendered info text for '$name' at $INFO_FILE"

    # Migration: the same text used to be written into the client's repository
    # directory, where it now blocks the client's first `borg init`. Remove the
    # leftover. This only ever deletes a file this script itself wrote — it has
    # always overwritten $repo/info.txt unconditionally, so it was never a
    # place where operator content could survive.
    if [ -f "${repo}/info.txt" ]; then
        rm -f "${repo}/info.txt"
        log "[INFO] Removed legacy ${repo}/info.txt (now rendered at $INFO_FILE)"
    fi
done < "$CONF"

# Info texts of clients that no longer exist.
#
# At container start there is nothing to prune: /run is empty on a fresh
# container. This matters when the script is re-run inside a live container
# after a client was removed from clients.conf — its key is gone from
# authorized_keys by then, and its info text must not outlive it either.
if [ -d "$INFO_DIR" ]; then
    while IFS= read -r stale; do
        keep=0
        for f in ${written_info[@]+"${written_info[@]}"}; do
            [ "$f" = "$stale" ] && { keep=1; break; }
        done
        [ "$keep" -eq 1 ] && continue
        rm -f "$stale"
        log "[INFO] Removed info text of a client no longer configured: $stale"
    done < <(find "$INFO_DIR" -type f)
fi

# Nothing to write.
#
# The danger this guards against is replacing a working authorized_keys with an
# empty one: that locks out every client at once, and a truncated clients.conf
# must never be able to cause it. So the question asked is the direct one —
# does a file exist that would be destroyed? — rather than a proxy for it.
#
# At container start the answer is always no: /home/borg/.ssh is not a volume
# and the unit runs with --rm, so every start begins on a fresh filesystem.
# Writing the empty file there is what lets a server come up before its first
# client exists, and it is not a weaker position than refusing to: sshd holds
# the line either way, because a key that is not in the file cannot authenticate
# and no other method is enabled. Refusing only prevents the server from being
# started, reachable and verifiable — it grants no access it would otherwise
# deny.
#
# A file that does exist and grants access means this ran inside a live
# container, where clients are connecting against it right now. There the
# original refusal stands. An existing file that authorizes nobody is not in
# that category — there is nothing in it to destroy, and refusing on account of
# it would make a second run of this script fail where the first succeeded.
if [ "$count" -eq 0 ]; then
    if [ -f "$OUT" ] && grep -q '^command=' "$OUT"; then
        log "[ERROR] No valid keys were added – keeping the existing $OUT."
        rm -f "$TMPOUT"
        exit 1
    fi
    log "[WARN] No client keys configured – writing an empty authorized_keys."
    log "[WARN] The server will start and reject every connection until a client"
    log "[WARN] is provisioned (scripts/00-ssh-create-user.sh, 01-ssh-set-user-key.sh)."
fi

# Atomic swap: replace authorized_keys only on success
mv "$TMPOUT" "$OUT"

# set permissions
chown borg:borg "$OUT"
chmod 600 "$OUT"
log "[INFO] Permissions set for $OUT"
log "[INFO] $count key(s) written to authorized_keys"

log "done"
