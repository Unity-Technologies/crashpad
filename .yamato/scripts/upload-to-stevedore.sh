#!/usr/bin/env bash
#
# upload-to-stevedore.sh -- download the StevedoreUpload tool and push the
# packed archives to the Stevedore `testing` repo. Writes the resulting
# artifact IDs to out/dist/artifactids.txt for downstream consumption.
#
# Requires (from Yamato secret groups):
#   STEVEDORE_UPLOAD_TOOL_MAC_X64_URL  (stevedore-upload-v2)
#   STEVEDORE_UPLOAD_KEY               (project-specific upload key)
#
set -euxo pipefail

: "${STEVEDORE_UPLOAD_TOOL_MAC_X64_URL:?must be set via stevedore-upload-v2 group}"
: "${STEVEDORE_UPLOAD_KEY:?must be set via project secret group}"
STEVEDORE_REPO="${STEVEDORE_REPO:-testing}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST="$CRASHPAD_SRC/out/dist"

cd "$CRASHPAD_SRC"

curl -sSo StevedoreUpload "$STEVEDORE_UPLOAD_TOOL_MAC_X64_URL"
chmod +x StevedoreUpload

VERSION="$(git rev-parse HEAD)"

./StevedoreUpload \
    --repo="$STEVEDORE_REPO" \
    --version-len=12 \
    --version="$VERSION" \
    --append-manifest="$DIST/artifactids.txt" \
    "$DIST/crashpad-unity-mac-arm64.7z" \
    "$DIST/crashpad-unity-mac-x64.7z"

echo "==> Uploaded. Artifact IDs:"
cat "$DIST/artifactids.txt"

# Surface the artifact IDs in the Yamato Results tab. $YAMATO_REPORTING_SERVER
# is injected by Yamato into every job; absent when running this script
# locally, in which case we silently skip the post.
# Ref: yamato-fundamentals/docs/usage/result-reporting.md
if [[ -n "${YAMATO_REPORTING_SERVER:-}" && -s "$DIST/artifactids.txt" ]]; then
    python3 - "$DIST/artifactids.txt" "$YAMATO_REPORTING_SERVER/result" "$STEVEDORE_REPO" <<'PY'
import json, sys, urllib.request
ids_path, url, repo = sys.argv[1], sys.argv[2], sys.argv[3]
with open(ids_path) as f:
    ids = f.read().rstrip()
body = {
    "title": f"Stevedore artifact IDs ({repo})",
    "summary": f"Uploaded to Stevedore ({repo}):\n\n```\n{ids}\n```",
    "conclusion": "success",
    "resultType": "userFriendly",
    "tags": ["stevedore"],
}
req = urllib.request.Request(
    url,
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req) as resp:
    print(f"==> Posted Yamato result ({resp.status})")
PY
fi
