#!/usr/bin/env bash
#
# tests/package-pin-freshness.sh
# -------------------------------
# Reports when an exact-version apt pin in the Dockerfile has fallen behind
# the version Debian now offers for it in the pinned base image's own
# package pool.
#
# Pinning packages by exact version buys the same thing digest-pinning the
# base image buys: two builds of the same commit install the same bits. The
# trade is symmetric too — apt refuses to install a version that has aged
# out of the pool, so a stale pin does not decay silently; it fails the very
# next build (tests/wrapper-gating.sh's "wrapper suite inside the built
# image" job builds the image on every push and pull request, so that
# failure surfaces fast). This check exists to give operators the same
# advance, deliberate notice tests/base-image-freshness.sh gives for the base
# layer, instead of finding out only when an unrelated push's build goes red.
#
# A newer package in the pool is a maintenance signal, not a defect in
# whatever commit is being tested, which is why — like base-image-freshness
# — this does not run on pull requests.
#
# Requires: bash, docker.
# Usage:    tests/package-pin-freshness.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

echo "# apt version pins vs. the pinned base image's package pool"
echo

BASE_REF="$(grep -oE '^FROM +debian:trixie-slim@sha256:[0-9a-f]+' Dockerfile 2>/dev/null \
    | awk '{print $2}')"

if [ -z "$BASE_REF" ]; then
    echo "FAIL the Dockerfile does not pin the base image by digest — see"
    echo "     tests/base-image-freshness.sh; nothing to check pinned packages against."
    exit 1
fi

command -v docker >/dev/null || { echo "FAIL docker is required" >&2; exit 1; }

# One package per "name=version" token on the apt-get install line.
mapfile -t PINS < <(
    sed -n '/apt-get install -y/,/rm -rf \/var\/lib\/apt\/lists/p' Dockerfile \
        | grep -oE '^[[:space:]]*[A-Za-z0-9.+-]+=[A-Za-z0-9.:+~-]+[[:space:]]*\\?$' \
        | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\\?$//'
)

if [ "${#PINS[@]}" -eq 0 ]; then
    echo "FAIL no 'package=version' pins found on the apt-get install line in the Dockerfile."
    exit 1
fi

NAMES=()
for p in "${PINS[@]}"; do NAMES+=("${p%%=*}"); done

CANDIDATES="$(docker run --rm "$BASE_REF" bash -c '
    apt-get update -qq >/dev/null 2>&1
    for p in "$@"; do
        apt-cache policy "$p" | awk -v pkg="$p" "/Candidate:/ {print pkg\"=\"\$2}"
    done
' _ "${NAMES[@]}" 2>/dev/null)"

if [ -z "$CANDIDATES" ]; then
    echo "FAIL could not read candidate package versions from the pinned base image."
    echo "     This is a build/registry-reachability failure, not a stale pin."
    exit 1
fi

fail=0
for pin in "${PINS[@]}"; do
    name="${pin%%=*}"
    pinned_ver="${pin#*=}"
    candidate_ver="$(printf '%s\n' "$CANDIDATES" | grep "^${name}=" | head -1 | cut -d= -f2-)"

    if [ -z "$candidate_ver" ]; then
        echo "FAIL could not read the candidate version for '$name'."
        fail=1
        continue
    fi

    if [ "$pinned_ver" = "$candidate_ver" ]; then
        printf 'ok   %-15s pinned %s matches the current candidate\n' "$name" "$pinned_ver"
    else
        printf 'STALE %-14s pinned %s, pool now offers %s\n' "$name" "$pinned_ver" "$candidate_ver"
        fail=1
    fi
done
echo

if [ "$fail" -eq 0 ]; then
    echo "ok   all pinned package versions are current"
    exit 0
fi

cat <<EOF
Debian's package pool has moved past one or more pins above. To act on it:

  1. Update the affected "name=version" token(s) on the apt-get install line
     in the Dockerfile.
  2. If borgbackup moved, run tests/wrapper-gating.sh with
     WRAPPER=/borg-wrapper.sh against a rebuilt image — it checks the wrapper
     against the borg version the image actually carries.
  3. Cut a release, since nothing reaches an operator otherwise.
EOF
exit 1
