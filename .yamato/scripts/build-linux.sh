#!/usr/bin/env bash
#
# build-linux.sh -- bootstrap depot_tools, sync gclient deps and build crashpad
# for Linux x64 into out/linux-x64-release.
#
# Requires clang, binutils, python3, zlib1g-dev and libcurl4-openssl-dev
# (see .yamato/README.md).
#
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"

for tool in clang clang++ ar python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: $tool not found on PATH" >&2
        exit 1
    fi
done

if ! command -v gn >/dev/null 2>&1; then
    DEPOT_TOOLS="${DEPOT_TOOLS:-$HOME/depot_tools}"
    if [[ ! -d "$DEPOT_TOOLS" ]]; then
        git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"
    fi
    export PATH="$DEPOT_TOOLS:$PATH"
fi

# DEPS paths are relative to the .gclient directory, so the checkout must be named "crashpad".
if [[ "$(basename "$CRASHPAD_SRC")" != "crashpad" ]]; then
    echo "ERROR: checkout directory must be named 'crashpad' (got $CRASHPAD_SRC)" >&2
    exit 1
fi

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

# pack-stevedore-linux.sh needs origin/main for the upstream baseline in NOTICE.
(
    cd "$CRASHPAD_SRC"
    git fetch --no-tags --unshallow 2>/dev/null || true
    git fetch --no-tags origin main:refs/remotes/origin/main 2>/dev/null || true
)

cd "$CRASHPAD_SRC"

gn gen out/linux-x64-release --args='is_debug=false target_cpu="x64"'
ninja -C out/linux-x64-release
