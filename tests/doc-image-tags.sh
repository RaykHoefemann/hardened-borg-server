#!/usr/bin/env bash
#
# tests/doc-image-tags.sh
# -----------------------
# Two checks over the release identifiers the documentation hands to an
# operator. They are separate because they fail for different reasons and
# belong to different triggers.
#
#   consistency  VERSION, the git tag cloned in SERVERINSTALL and the image tag
#                named in the docs all describe the same release, and SOURCE_URL
#                does not differ between host and image. Commit-local: it can
#                only break by editing the repository, so it runs on every push
#                and pull request.
#
#   registry     every image tag named in the documentation can actually be
#                pulled. Not commit-local: pre-release tags are deleted from
#                GHCR over time, and the documentation had accumulated
#                references to 0.1.0-beta.8 and beta.9 long after both were
#                gone. Those were not stale-but-usable — copying the README
#                quickstart produced a pull failure for a tag that did not
#                exist. Nothing in the repository changes when a tag is deleted,
#                which is why this half is wired to a schedule.
#
# The registry half does not run on pushes to main. A release commit and its
# git tag are pushed together, so the Tests workflow starts while the image for
# that very tag is still being built and published; the check then fails on a
# tag that is minutes away from existing. That is a red build which only ever
# means "wait", and those teach people to ignore red builds. Pull requests and
# the weekly schedule still run it, so a genuinely dead tag is still caught.
#
# `:latest` is reported but never fatal. During the beta phase it deliberately
# does not exist (see scripts/config.sh); once a stable release ships it will,
# and either state is correct at the time.
#
# Requires: bash, curl, python3.
# Usage:    tests/doc-image-tags.sh [consistency|registry]
#           With no argument, both halves run.
#
set -uo pipefail

IMAGE_REPO="raykhoefemann/hardened-borg-server"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

run_consistency=1
run_registry=1
case "${1-}" in
    consistency) run_registry=0 ;;
    registry)    run_consistency=0 ;;
    "")          ;;
    *)
        echo "usage: $0 [consistency|registry]" >&2
        exit 2
        ;;
esac

echo "# documented release identifiers vs. ghcr.io/${IMAGE_REPO}"
echo

# Collect documented references. The tag character class excludes '<', so
# placeholders such as ":<tag>" and digest pins "@sha256:<digest>" are not
# matched and need no special handling.
mapfile -t TAGS < <(
    grep -rhoE "ghcr\.io/${IMAGE_REPO}:[A-Za-z0-9._-]+" \
        --include='*.md' --include='*.sh' . 2>/dev/null \
    | sed 's|.*:||' | sort -u
)

if [ "${#TAGS[@]}" -eq 0 ]; then
    echo "no image references found in the documentation — nothing to check"
    exit 0
fi

consistency_fail=0
fail=0

# --- release consistency ----------------------------------------------------
#
# A release has two halves. The container comes from an image tag; the host
# scripts come from a git tag cloned in SERVERINSTALL step 1 — and the image
# does not carry them, so they cannot be versioned by it. Bumping one and
# forgetting the other yields a deployment nobody can name.

check_consistency() {
    local GIT_TAG VERSION_FILE SRC_HOST SRC_IMAGE
    local -a VERSIONS

    GIT_TAG="$(grep -oE '^RELEASE=v[A-Za-z0-9._-]+' docs/SERVERINSTALL.md 2>/dev/null | head -1 | sed 's/^RELEASE=//')"
    VERSION_FILE="$(tr -d '[:space:]' < VERSION 2>/dev/null)"

    mapfile -t VERSIONS < <(printf '%s\n' "${TAGS[@]}" | grep -v '^latest$')

    if [ -z "$VERSION_FILE" ]; then
        echo "FAIL VERSION is missing or empty — scripts/config.sh derives IMAGE from it"
        consistency_fail=1
    elif [ -z "$GIT_TAG" ]; then
        echo "FAIL SERVERINSTALL.md no longer pins a release tag (expected a 'RELEASE=v...' line)"
        consistency_fail=1
    elif [ "${#VERSIONS[@]}" -eq 0 ]; then
        echo "note no concrete image version documented — only ':latest'"
    elif [ "${#VERSIONS[@]}" -gt 1 ]; then
        echo "FAIL documentation names more than one image version: ${VERSIONS[*]}"
        consistency_fail=1
    elif [ "${GIT_TAG#v}" != "$VERSION_FILE" ]; then
        echo "FAIL SERVERINSTALL clones ${GIT_TAG} but VERSION says ${VERSION_FILE}"
        consistency_fail=1
    elif [ "$VERSION_FILE" != "${VERSIONS[0]}" ]; then
        echo "FAIL VERSION says ${VERSION_FILE} but the docs pin image ${VERSIONS[0]}"
        consistency_fail=1
    else
        printf 'ok   VERSION, git tag %s and image tag %s all agree\n' "$GIT_TAG" "${VERSIONS[0]}"
    fi

    # The source URL exists twice by necessity: once on the host (config.sh,
    # shown by 99-container-status.sh) and once inside the image
    # (build_authorized_keys.sh, reported to clients through the info channel).
    # They must not drift, or an operator and a client would be pointed at
    # different repositories.
    SRC_HOST="$(grep -oE '^SOURCE_URL="[^"]+"' scripts/config.sh 2>/dev/null | head -1)"
    SRC_IMAGE="$(grep -oE '^SOURCE_URL="[^"]+"' build_authorized_keys.sh 2>/dev/null | head -1)"

    if [ -z "$SRC_HOST" ] || [ -z "$SRC_IMAGE" ]; then
        echo "FAIL SOURCE_URL missing from scripts/config.sh or build_authorized_keys.sh"
        consistency_fail=1
    elif [ "$SRC_HOST" != "$SRC_IMAGE" ]; then
        echo "FAIL SOURCE_URL differs between host and image:"
        echo "       host:  $SRC_HOST"
        echo "       image: $SRC_IMAGE"
        consistency_fail=1
    else
        printf 'ok   SOURCE_URL identical on host and in image\n'
    fi
    echo
}

# --- registry pullability ---------------------------------------------------

check_registry() {
    local TOKEN PUBLISHED PUBLISHED_REAL tag

    # Anonymous pull token; GHCR requires one even for public repositories.
    TOKEN="$(curl -fsSL --max-time 30 \
        "https://ghcr.io/token?scope=repository:${IMAGE_REPO}:pull&service=ghcr.io" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null)"

    if [ -z "$TOKEN" ]; then
        echo "FAIL could not obtain a registry token — the documented tags were NOT verified."
        echo "     This is a registry-reachability failure, not a documentation problem."
        exit 1
    fi

    PUBLISHED="$(curl -fsSL --max-time 30 -H "Authorization: Bearer $TOKEN" \
        "https://ghcr.io/v2/${IMAGE_REPO}/tags/list" \
        | python3 -c 'import json,sys; [print(t) for t in (json.load(sys.stdin).get("tags") or [])]' 2>/dev/null)"

    if [ -z "$PUBLISHED" ]; then
        echo "FAIL could not list registry tags — the documented tags were NOT verified."
        echo "     This is a registry-reachability failure, not a documentation problem."
        exit 1
    fi

    # "sha256-..." entries are attestation pseudo-tags, not releases.
    PUBLISHED_REAL="$(printf '%s\n' "$PUBLISHED" | grep -v '^sha256-' | sort)"
    echo "published: $(printf '%s ' $PUBLISHED_REAL)"
    echo

    for tag in "${TAGS[@]}"; do
        if printf '%s\n' "$PUBLISHED_REAL" | grep -qx -- "$tag"; then
            printf 'ok   %s\n' "$tag"
        elif [ "$tag" = "latest" ]; then
            printf 'note %s — absent, expected during the beta phase\n' "$tag"
        else
            fail=$((fail+1))
            printf 'FAIL %s — documented but not published\n' "$tag"
            grep -rln "ghcr\.io/${IMAGE_REPO}:${tag}" \
                --include='*.md' --include='*.sh' . 2>/dev/null | sed 's|^|       referenced in |'
        fi
    done
    echo
}

[ "$run_consistency" -eq 1 ] && check_consistency
[ "$run_registry" -eq 1 ] && check_registry

if [ "$fail" -ne 0 ] || [ "$consistency_fail" -ne 0 ]; then
    [ "$fail" -ne 0 ] && echo "$fail documented tag(s) cannot be pulled. Update them to a published tag."
    exit 1
fi
echo "all documented release identifiers check out"
