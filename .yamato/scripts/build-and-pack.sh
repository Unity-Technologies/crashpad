#!/usr/bin/env bash
#
# build-and-pack.sh -- bootstrap depot_tools, sync gclient deps, build crashpad
# for macOS arm64 and x64, then run pack-stevedore.sh.
#
# Intended for Yamato (clean macOS Bokken agent) but runnable locally too.
#
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- 7zip (required by pack-stevedore.sh) ---
if ! command -v 7z >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install p7zip
fi

# --- depot_tools (gn, ninja, gclient) ---
if ! command -v gn >/dev/null 2>&1; then
    DEPOT_TOOLS="$HOME/depot_tools"
    if [[ ! -d "$DEPOT_TOOLS" ]]; then
        git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"
    fi
    export PATH="$DEPOT_TOOLS:$PATH"
fi

# --- gclient config + sync ---
# Crashpad's .gclient must live one level above the checkout.
GCLIENT_PARENT="$(cd "$CRASHPAD_SRC/.." && pwd)"
if [[ ! -f "$GCLIENT_PARENT/.gclient" ]]; then
    cat > "$GCLIENT_PARENT/.gclient" <<EOF
solutions = [
  {
    "name": "crashpad",
    "url": "https://chromium.googlesource.com/crashpad/crashpad.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
EOF
fi

(cd "$GCLIENT_PARENT" && gclient sync --no-history)

# --- Ensure origin/main is available for upstream-baseline detection ---
# Yamato typically does a shallow / branch-only clone. pack-stevedore.sh
# runs `git merge-base HEAD origin/main` to compute the upstream baseline
# embedded in NOTICE; both refs need enough shared history visible locally.
# Unshallow first (no-op on full clones), then fetch the upstream-mirror ref.
(
    cd "$CRASHPAD_SRC"
    git fetch --no-tags --unshallow 2>/dev/null || true
    git fetch --no-tags origin main:refs/remotes/origin/main 2>/dev/null || true
)

# --- Build both architectures ---
cd "$CRASHPAD_SRC"

gn gen out/arm64-release --args='is_debug=false target_cpu="arm64" mac_deployment_target="12.0"'
ninja -C out/arm64-release

gn gen out/x64-release --args='is_debug=false target_cpu="x64" mac_deployment_target="12.0"'
ninja -C out/x64-release

# --- Pack ---
export FORK_URL="https://github.com/Unity-Technologies/crashpad"
"$SCRIPT_DIR/../pack-stevedore.sh"

# --- TEMP: preview Yamato Results-tab rendering with dummy IDs ---
# Remove once we like the look; then move the real post into the proper place.
if [[ -n "${YAMATO_REPORTING_SERVER:-}" ]]; then
    python3 - "$YAMATO_REPORTING_SERVER/result" <<'PY'
import json, sys, urllib.request
url = sys.argv[1]
body = {
    "title": "Stevedore artifact IDs (preview)",
    "summary": (
        "Uploaded to Stevedore `testing`:\n\n"
        "```\n"
        "crashpad-unity-mac-arm64/abc123def456_1111111111111111111111111111111111111111111111111111111111111111.7z\n"
        "crashpad-unity-mac-x64/abc123def456_2222222222222222222222222222222222222222222222222222222222222222.7z\n"
        "```\n"
    ),
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
    print(f"==> Posted Yamato result preview ({resp.status})")
PY
fi
