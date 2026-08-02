#!/usr/bin/env bash
#
# tests/base-image-freshness.sh
# -----------------------------
# Reports when the digest-pinned base image in the Dockerfile has fallen behind
# the tag it was pinned from.
#
# Pinning by digest buys reproducibility — the image is fully determined by the
# commit — at the cost of no longer picking up Debian's security rebuilds on
# every build. That trade is only honest if somebody notices when a rebuild has
# happened, and nothing in the repository changes when Debian ships one. So,
# like tests/doc-image-tags.sh, this is wired to a schedule rather than to
# pushes: it watches something that moves without a commit.
#
# A stale pin is a maintenance signal, not a defect in whatever commit is being
# tested, which is why this does not run on pull requests — a red build on
# unrelated work teaches people to ignore red builds.
#
# Requires: bash, curl, python3.
# Usage:    tests/base-image-freshness.sh
#
set -uo pipefail

BASE_IMAGE="debian"
BASE_TAG="trixie-slim"
BASE_PATH="library/${BASE_IMAGE}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

echo "# base image pin vs. ${BASE_IMAGE}:${BASE_TAG}"
echo

PINNED="$(grep -oE "^FROM +${BASE_IMAGE}:${BASE_TAG}@sha256:[0-9a-f]+" Dockerfile 2>/dev/null \
    | grep -oE 'sha256:[0-9a-f]+' | head -1)"

if [ -z "$PINNED" ]; then
    echo "FAIL the Dockerfile does not pin ${BASE_IMAGE}:${BASE_TAG} by digest."
    echo "     Expected: FROM ${BASE_IMAGE}:${BASE_TAG}@sha256:<digest>"
    echo "     Without a digest this check has nothing to compare, and two"
    echo "     builds of the same commit can differ."
    exit 1
fi

TOKEN="$(curl -fsSL --max-time 30 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${BASE_PATH}:pull" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null)"

if [ -z "$TOKEN" ]; then
    echo "FAIL could not obtain a registry token — the pin was NOT checked."
    echo "     This is a registry-reachability failure, not a stale pin."
    exit 1
fi

# The manifest-list digest is what a multi-arch FROM refers to, so both Accept
# types are offered; asking for neither returns a single-architecture manifest
# whose digest would never match the pin.
CURRENT="$(curl -fsSLI --max-time 30 -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://registry-1.docker.io/v2/${BASE_PATH}/manifests/${BASE_TAG}" 2>/dev/null \
    | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}')"

if [ -z "$CURRENT" ]; then
    echo "FAIL could not read the current digest — the pin was NOT checked."
    echo "     This is a registry-reachability failure, not a stale pin."
    exit 1
fi

echo "pinned:  $PINNED"
echo "current: $CURRENT"
echo

if [ "$PINNED" = "$CURRENT" ]; then
    echo "ok   the pinned base image is current"
    exit 0
fi

cat <<EOF
STALE ${BASE_IMAGE}:${BASE_TAG} has been rebuilt since this pin was set.

Debian rebuilds this tag to ship security updates, and users of this project
receive them only through a new release. To act on it:

  1. Update the FROM line in the Dockerfile to:
       FROM ${BASE_IMAGE}:${BASE_TAG}@${CURRENT}
  2. Run the suites against the rebuilt image — in particular
     tests/wrapper-gating.sh with WRAPPER=/borg-wrapper.sh, which checks the
     wrapper against the borg version the image actually carries.
  3. Cut a release, since nothing reaches an operator otherwise.

If the rebuild also moved the bundled borg version, say so in the release
notes and update the version note at the top of borg-wrapper.sh.
EOF
exit 1
