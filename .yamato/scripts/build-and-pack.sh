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

# --- Build both architectures ---
cd "$CRASHPAD_SRC"

gn gen out/arm64-release --args='is_debug=false target_cpu="arm64" mac_deployment_target="12.0"'
ninja -C out/arm64-release

gn gen out/x64-release --args='is_debug=false target_cpu="x64" mac_deployment_target="12.0"'
ninja -C out/x64-release

# --- Pack ---
export FORK_URL="https://github.com/Unity-Technologies/crashpad"
"$SCRIPT_DIR/../pack-stevedore.sh"
