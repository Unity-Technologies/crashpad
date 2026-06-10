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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST="$CRASHPAD_SRC/out/dist"

cd "$CRASHPAD_SRC"

curl -sSo StevedoreUpload "$STEVEDORE_UPLOAD_TOOL_MAC_X64_URL"
chmod +x StevedoreUpload

VERSION="$(git rev-parse HEAD)"

./StevedoreUpload \
    --repo=testing \
    --version-len=12 \
    --version="$VERSION" \
    --append-manifest="$DIST/artifactids.txt" \
    "$DIST/crashpad-mac-arm64.7z" \
    "$DIST/crashpad-mac-x64.7z"

echo "==> Uploaded. Artifact IDs:"
cat "$DIST/artifactids.txt"
