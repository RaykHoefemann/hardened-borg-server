#!/bin/bash
#
# borg-wrapper.sh — forced-command wrapper for the hardened borg backup server.
#
# Invoked from each client's authorized_keys entry as:
#     command="/borg-wrapper.sh /path/to/repo",restrict <client-key>
# The repo path is fixed per client; $SSH_ORIGINAL_COMMAND is never trusted for
# it. Client isolation = forced command + restrict + borg's --restrict-to-path.
#
# OPERATING REQUIREMENTS (all mandatory — see README):
#   * borg 1.2.x            Debian stable container; the segment format assumed
#                           by the encryption check below is the 1.2 format.
#   * python3               Pulled in automatically by the borgbackup package.
#   * XFS project quotas, mounted 'prjquota' (ENFORCING) with a per-repo project
#                           id and limit. Enforcement caps each client's storage
#                           AND surfaces usage to the unprivileged container via
#                           statvfs(); the 'info' channel relies on this.
#                           'pqnoenforce' (accounting-only) is NOT sufficient.
#   * Encryption policy: client-held keyfile only (keyfile / keyfile-blake2).
#                           repokey, authenticated and unencrypted repos are
#                           rejected at connection time (see Case 3).
#
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
        # Static per-repo notes (optional), maintained by the admin.
        [ -f "$REPO/info.txt" ] && cat "$REPO/info.txt"
        # Quota usage, read inside the container with no privileges: XFS surfaces
        # the enforcing project quota through statvfs(), so df on the repo path
        # reports the per-client size/used/percent (see requirements header).
        # Diagnostic: if this shows the whole disk, prjquota enforcement is off.
        if [ -d "$REPO" ]; then
            df -kP "$REPO" 2>/dev/null | awk '
                function h(k){ if (k>=1048576) return sprintf("%.1f GiB", k/1048576);
                               else if (k>=1024) return sprintf("%.1f MiB", k/1024);
                               else return sprintf("%d KiB", k) }
                NR==2 { printf "Used: %s of %s (%s)\n", h($3), h($2), $5 }'
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

# Case 3: normal operation – config present. POLICY: keyfile-only.
#
# This server accepts ONLY client-held keyfile encryption. The key material must
# never live on the server, so that a full server compromise still cannot decrypt
# any backup. That rules out repokey (key stored in the repo, only passphrase-
# wrapped -> offline-crackable if the server is breached) as well as plaintext and
# authenticated-only repos.
#
# Two independent, fail-closed checks that must BOTH pass:
#   (1) Manifest TYPE byte must be a keyfile type. borg does not record the mode
#       in $REPO/config; the leading TYPE byte of the manifest object is the only
#       server-side ground truth. It is read via borg's own segment reader, so it
#       stays correct across borg 1.2.x point releases.
#           ALLOW  0x00 KeyfileKey   0x04 Blake2KeyfileKey        (key on CLIENT)
#           DENY   0x03/0x05 RepoKey (key in REPO)   0x02 none    0x06/0x07 authenticated
#   (2) $REPO/config must contain NO "key =" line. keyfile repos never store key
#       material server-side; repokey/authenticated repos do. This is a cheap,
#       independent confirmation of (1).
#
# Any error, an undeterminable type, or disagreement between the checks -> DENY.
# Writes nothing to stdout (stdout belongs to the borg protocol after exec).
if ! python3 - "$REPO" >&2 <<'PYEOF'
import configparser, glob, os, sys
from borg.repository import LoggedIO

repo = sys.argv[1]
MANIFEST_ID = b"\x00" * 32
KEYFILE_TYPES = {0x00, 0x04}           # KeyfileKey, Blake2KeyfileKey (key held by client)

try:
    cfg = configparser.ConfigParser()
    cfg.read(os.path.join(repo, "config"))
    spd = cfg.getint("repository", "segments_per_dir", fallback=1000)
    mss = cfg.getint("repository", "max_segment_size", fallback=500 * 1024 * 1024)

    # Check (2): reject any repo that stores key material on the server.
    if cfg.has_option("repository", "key"):
        print("DENY: repo stores key material server-side (not keyfile mode)",
              file=sys.stderr)
        sys.exit(1)

    segments = sorted(
        (int(os.path.basename(p))
         for d in glob.glob(os.path.join(repo, "data", "*"))
         for p in glob.glob(os.path.join(d, "*"))
         if os.path.basename(p).isdigit()),
        reverse=True,                  # newest first: current manifest lives here
    )
    if not segments:
        print("DENY: no repository segments found", file=sys.stderr)
        sys.exit(1)

    # Check (1): manifest TYPE byte must be a keyfile type.
    io = LoggedIO(repo, limit=mss, segments_per_dir=spd)
    type_byte = None
    for seg in segments:
        for tag, key, offset, data in io.iter_objects(seg, include_data=True):
            if key == MANIFEST_ID and data:
                type_byte = data[0]
                break
        if type_byte is not None:
            break

    if type_byte is None:
        print("DENY: manifest not found (repo unreadable)", file=sys.stderr)
        sys.exit(1)
    if type_byte not in KEYFILE_TYPES:
        print(f"DENY: not a keyfile repository (key type 0x{type_byte:02x}); "
              f"only client-held keyfile encryption is permitted", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
except Exception as e:
    print(f"DENY: could not verify keyfile encryption: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
then
    exit 1
fi

exec borg serve --restrict-to-path "$REPO" --append-only
