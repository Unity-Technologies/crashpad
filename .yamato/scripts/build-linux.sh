#!/usr/bin/env bash
#
# build-linux.sh -- bootstrap depot_tools, sync gclient deps and build crashpad
# for Linux x64 into out/linux-x64-release.
#
# Requires clang, binutils, python3, zlib1g-dev and libcurl4-openssl-dev
# (see .yamato/README.md).
#
# Environment:
#   UNITY_LINUX_SDK  unpacked unity-linux-gnu-x86_64-sdk Stevedore artifact. When set,
#                    builds against Unity's glibc 2.35 sysroot (required for libraries
#                    the Unity Linux Editor can link). Unset = host sysroot.
#   CURL_INCLUDE     directory containing curl/curl.h, used with UNITY_LINUX_SDK
#                    (default: copied from the libcurl4-openssl-dev package)
#   DEPOT_TOOLS      depot_tools location if gn is not on PATH (default: ~/depot_tools)
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

GN_ARGS='is_debug=false target_cpu="x64"'

if [[ -n "${UNITY_LINUX_SDK:-}" ]]; then
    UNITY_LINUX_SDK="$(cd "$UNITY_LINUX_SDK" && pwd)"
    SYSROOT="$UNITY_LINUX_SDK/x86_64-unity-linux-gnu/sysroot"
    if [[ ! -d "$SYSROOT" ]]; then
        echo "ERROR: sysroot not found: $SYSROOT" >&2
        exit 1
    fi

    # The SDK sysroot has no libcurl headers; crashpad only needs them to compile (libcurl is dlopen()ed).
    if [[ -z "${CURL_INCLUDE:-}" ]]; then
        CURL_H="$(dpkg -L libcurl4-openssl-dev | grep '/curl/curl.h$')"
        CURL_INCLUDE="$CRASHPAD_SRC/out/curl-include"
        rm -rf "$CURL_INCLUDE"
        mkdir -p "$CURL_INCLUDE"
        cp -r "$(dirname "$CURL_H")" "$CURL_INCLUDE/"
    fi
    if [[ ! -f "$CURL_INCLUDE/curl/curl.h" ]]; then
        echo "ERROR: curl/curl.h not found under $CURL_INCLUDE" >&2
        exit 1
    fi

    TARGET_FLAGS="--target=x86_64-unity-linux-gnu --gcc-toolchain=$UNITY_LINUX_SDK"
    # The sysroot's kernel headers (3.14) predate memfd_create (3.17); 319 is its x86_64 syscall number.
    GN_ARGS+=" target_sysroot=\"$SYSROOT\""
    GN_ARGS+=" extra_cflags=\"$TARGET_FLAGS -DSYS_memfd_create=319 -isystem $CURL_INCLUDE\""
    GN_ARGS+=" extra_ldflags=\"$TARGET_FLAGS\""
else
    echo "WARNING: UNITY_LINUX_SDK not set; building against the host sysroot." >&2
    echo "         The resulting libraries may not link into the Unity Linux Editor." >&2
fi

gn gen out/linux-x64-release --args="$GN_ARGS"
ninja -C out/linux-x64-release

if [[ -n "${UNITY_LINUX_SDK:-}" ]] && nm -u out/linux-x64-release/obj/util/libutil.a | grep __isoc23_ >/dev/null; then
    echo "ERROR: libutil.a references glibc 2.38+ __isoc23_* symbols; the Unity sysroot was not used" >&2
    exit 1
fi
