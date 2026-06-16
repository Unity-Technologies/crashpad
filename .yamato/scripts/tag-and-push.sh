#!/usr/bin/env bash
#
# tag-and-push.sh -- create a <prefix>-YYYY.MM.DD-<upstream-12char>[-N] tag
# for the current HEAD and push it to the fork.
#
# Tag format:
#   <prefix>-YYYY.MM.DD-<upstream-12char>       first release on this upstream
#   <prefix>-YYYY.MM.DD-<upstream-12char>-N     Nth iteration on the same upstream
#
# <prefix> is TAG_PREFIX (default "unity"). publish_public uses "unity" to
# produce customer-facing release tags; publish_testing uses "staging" so its
# tags share no glob with production and cannot pollute the production counter.
#
# <upstream-12char> is the 12-char short SHA of origin/main (pure upstream
# mirror). The counter -N advances per (date, upstream) pair: the first tag
# of the day for a given upstream omits the suffix; same-day re-publishes
# on the same upstream get -2, -3, etc.
#
# Idempotent: if any <prefix>-* tag already points at HEAD, exit cleanly
# without pushing a duplicate. This lets the job be safely re-run after an
# upload failure.
#
# Required env: GH_PUSH_TOKEN -- GitHub token with repo:write on the fork.
#
# NOTE: -x is intentionally omitted to avoid leaking GH_PUSH_TOKEN into logs.
set -euo pipefail

TAG_PREFIX="${TAG_PREFIX:-unity}"

if [[ -z "${GH_PUSH_TOKEN:-}" ]]; then
    echo "ERROR: GH_PUSH_TOKEN is not set" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$CRASHPAD_SRC"

# URL-embedded Basic Auth, not http.extraheader Bearer: the bandwidth cache
# that fronts github.com on some agents 403s Bearer but accepts Basic.
# credential.helper= clears any inherited helper so git doesn't try to
# cache the embedded creds in the OS keychain.
FORK_URL_AUTHED="https://x-access-token:${GH_PUSH_TOKEN}@github.com/Unity-Technologies/crashpad"
GIT=(git -c credential.helper=)

# Yamato shallow-clones a single ref; bring in main + all tags.
"${GIT[@]}" fetch --no-tags "$FORK_URL_AUTHED" main:refs/remotes/origin/main
"${GIT[@]}" fetch --tags "$FORK_URL_AUTHED"

UPSTREAM_HASH="$(git rev-parse --short=12 origin/main)"
DATE="$(date -u +%Y.%m.%d)"

mkdir -p out/dist

# Idempotency: if a <prefix>-* tag already points at HEAD, exit cleanly.
EXISTING_AT_HEAD="$(git tag --points-at HEAD --list "${TAG_PREFIX}-*" | head -n1)"
if [[ -n "$EXISTING_AT_HEAD" ]]; then
    echo "==> Tag $EXISTING_AT_HEAD already at HEAD; nothing to do."
    echo "$EXISTING_AT_HEAD" > out/dist/tag.txt
    exit 0
fi

# Counter: scan tags for today's (date, upstream) pair, treating bare as N=1.
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
done < <(git tag -l "${TAG_PREFIX}-${DATE}-${UPSTREAM_HASH}" "${TAG_PREFIX}-${DATE}-${UPSTREAM_HASH}-*")

if (( MAX_N == 0 )); then
    TAG="${TAG_PREFIX}-${DATE}-${UPSTREAM_HASH}"
else
    TAG="${TAG_PREFIX}-${DATE}-${UPSTREAM_HASH}-$((MAX_N + 1))"
fi

git tag "$TAG" HEAD
"${GIT[@]}" push "$FORK_URL_AUTHED" "refs/tags/$TAG"

echo "$TAG" > out/dist/tag.txt
echo "==> Pushed tag: $TAG"
