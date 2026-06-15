#!/usr/bin/env bash
#
# tag-and-push.sh -- create a unity-YYYY.MM.DD-<upstream-12char>[-N] tag for
# the current HEAD and push it to the fork.
#
# Tag format:
#   unity-YYYY.MM.DD-<upstream-12char>       first release on this upstream
#   unity-YYYY.MM.DD-<upstream-12char>-N     Nth iteration on the same upstream
#
# <upstream-12char> is the 12-char short SHA of origin/main (pure upstream
# mirror). The counter -N advances per upstream baseline, independent of date;
# the first tag for a given upstream omits the suffix.
#
# Idempotent: if any unity-* tag already points at HEAD, exit cleanly without
# pushing a duplicate. This lets the job be safely re-run after an upload
# failure.
#
# Required env: GH_PUSH_TOKEN -- GitHub token with repo:write on the fork.
#
# NOTE: -x is intentionally omitted to avoid leaking GH_PUSH_TOKEN into logs.
set -euo pipefail

if [[ -z "${GH_PUSH_TOKEN:-}" ]]; then
    echo "ERROR: GH_PUSH_TOKEN is not set" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$CRASHPAD_SRC"

# Yamato shallow-clones a single ref; bring in main + all tags.
git fetch --no-tags origin main:refs/remotes/origin/main
git fetch --tags origin

UPSTREAM_HASH="$(git rev-parse --short=12 origin/main)"
DATE="$(date -u +%Y.%m.%d)"

mkdir -p out/dist

# Idempotency: if a unity-* tag already points at HEAD, exit cleanly.
EXISTING_AT_HEAD="$(git tag --points-at HEAD --list 'unity-*' | head -n1)"
if [[ -n "$EXISTING_AT_HEAD" ]]; then
    echo "==> Tag $EXISTING_AT_HEAD already at HEAD; nothing to do."
    echo "$EXISTING_AT_HEAD" > out/dist/tag.txt
    exit 0
fi

# Counter: scan all tags ending in our upstream SHA, treating bare as N=1.
# Uses max-of-existing (not count) so deleted tags don't produce duplicates.
MAX_N=0
while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    suffix="${t##*-${UPSTREAM_HASH}}"
    if [[ -z "$suffix" ]]; then
        n=1
    elif [[ "$suffix" =~ ^-([0-9]+)$ ]]; then
        n="${BASH_REMATCH[1]}"
    else
        continue  # malformed, skip
    fi
    if (( n > MAX_N )); then
        MAX_N=$n
    fi
done < <(git tag -l "unity-*-${UPSTREAM_HASH}" "unity-*-${UPSTREAM_HASH}-*")

if (( MAX_N == 0 )); then
    TAG="unity-${DATE}-${UPSTREAM_HASH}"
else
    TAG="unity-${DATE}-${UPSTREAM_HASH}-$((MAX_N + 1))"
fi

git tag "$TAG" HEAD
git -c "http.extraheader=Authorization: bearer $GH_PUSH_TOKEN" \
    push origin "refs/tags/$TAG"

echo "$TAG" > out/dist/tag.txt
echo "==> Pushed tag: $TAG"
