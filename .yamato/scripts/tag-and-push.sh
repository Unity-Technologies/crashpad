#!/usr/bin/env bash
#
# tag-and-push.sh -- compute the unity-<upstream-short-hash>[-N] tag for the
# current unity/main, then push it to origin. Per tasks.md the tag is auto-
# computed from the local `main` branch (pure upstream mirror), with -N suffix
# on collisions.
#
# Requires: GH_PUSH_TOKEN env var with write access to the fork.
#
set -euxo pipefail

if [[ -z "${GH_PUSH_TOKEN:-}" ]]; then
    echo "ERROR: GH_PUSH_TOKEN is not set" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$CRASHPAD_SRC"

# Make sure we have the upstream-mirror branch locally so we can resolve its
# short hash. Yamato shallow-clones a single ref by default.
git fetch --no-tags origin main:refs/remotes/origin/main
UPSTREAM_HASH="$(git rev-parse --short origin/main)"

git fetch --no-tags --tags origin
EXISTING="$(git tag -l "unity-${UPSTREAM_HASH}*" | wc -l | tr -d ' ')"
if [[ "$EXISTING" -eq 0 ]]; then
    TAG="unity-${UPSTREAM_HASH}"
else
    TAG="unity-${UPSTREAM_HASH}-$((EXISTING + 1))"
fi

git tag "$TAG" HEAD
git -c "http.extraheader=Authorization: bearer $GH_PUSH_TOKEN" \
    push origin "refs/tags/$TAG"

echo "$TAG" > out/dist/tag.txt
echo "==> Pushed tag: $TAG"
