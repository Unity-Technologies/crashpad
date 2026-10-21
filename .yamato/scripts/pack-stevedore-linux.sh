#!/usr/bin/env bash
#
# pack-stevedore-linux.sh -- assemble the Stevedore artifact for Unity's Linux
# Crashpad consumer. Produces crashpad-unity-linux-x64.7z.
#
# Archive layout:
#   LICENSE      (Crashpad Apache 2.0)
#   NOTICE       (Unity modifications + surfaced third-party licenses)
#   AUTHORS      (Crashpad authors)
#   README.txt   (minimal, points back to the fork)
#   include/     (headers only -- Crashpad + mini_chromium)
#   src/         (the .cc source files Unity compiles directly)
#   lib/linux/x64/*.a   (prebuilt static libraries)
#
# Usage:
#   pack-stevedore-linux.sh [OUTPUT_DIR]
#
# Environment overrides:
#   CRASHPAD_SRC     path to the fork checkout      (default: two levels above this script)
#   X64_BUILD        path to out/linux-x64-release  (default: $CRASHPAD_SRC/out/linux-x64-release)
#   FORK_URL         URL of the Unity Crashpad fork
#   VERSION          version string for filenames   (default: short git SHA of fork)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="${CRASHPAD_SRC:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
X64_BUILD="${X64_BUILD:-$CRASHPAD_SRC/out/linux-x64-release}"
OUTPUT_DIR="${1:-$CRASHPAD_SRC/out/dist}"
FORK_URL="${FORK_URL:-https://github.com/Unity-Technologies/crashpad}"

if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(cd "$CRASHPAD_SRC" && git rev-parse --short=12 HEAD 2>/dev/null || echo dev)"
fi

UPSTREAM_REF="${UPSTREAM_REF:-origin/main}"
UPSTREAM_BASE="$(cd "$CRASHPAD_SRC" && git merge-base HEAD "$UPSTREAM_REF" 2>/dev/null | cut -c 1-12 || true)"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# libcommon.a comes from client/; handler/libcommon.a is a separate internal lib.
LIB_MAP=(
    "libbase.a:obj/third_party/mini_chromium/mini_chromium/base/libbase.a"
    "libclient.a:obj/client/libclient.a"
    "libcommon.a:obj/client/libcommon.a"
    "libcompat.a:obj/compat/libcompat.a"
    "libcontext.a:obj/snapshot/libcontext.a"
    "libformat.a:obj/minidump/libformat.a"
    "libhandler.a:obj/handler/libhandler.a"
    "libminidump.a:obj/minidump/libminidump.a"
    "libnet.a:obj/util/libnet.a"
    "libsnapshot.a:obj/snapshot/libsnapshot.a"
    "libutil.a:obj/util/libutil.a"
)

# Crashpad sources a Unity Linux handler compiles instead of linking libhandler.a,
# plus the pthread_create interposer, which upstream builds as a source_set.
UNITY_SOURCES=(
    "handler/handler_main.cc"
    "handler/prune_crash_reports_thread.cc"
    "handler/crash_report_upload_rate_limit.cc"
    "handler/crash_report_upload_thread.cc"
    "handler/minidump_to_upload_parameters.cc"
    "handler/user_stream_data_source.cc"
    "handler/linux/capture_snapshot.cc"
    "handler/linux/crash_report_exception_handler.cc"
    "handler/linux/exception_handler_server.cc"
    "tools/tool_support.cc"
    "client/pthread_create_linux.cc"
)

# util/stream/zlib_output_stream.h includes this; it selects <zlib.h> via CRASHPAD_ZLIB_SOURCE_*.
EXTRA_HEADERS=(
    "third_party/zlib/zlib_crashpad.h"
)

HEADER_TREES_CRASHPAD=(
    "handler"
    "client"
    "util"
    "compat"
    "snapshot"
    "minidump"
    "tools"
    "build"
)
HEADER_TREES_MINICHROMIUM=(
    "base"
    "build"
)

copy_headers() {
    local from="$1"
    local to="$2"
    mkdir -p "$to"
    (cd "$from" && find . -name "*.h" -not -path "*/test/*" -not -name "*_test.h" -print0) \
        | (cd "$from" && tar --null -cf - --files-from=-) \
        | (cd "$to" && tar -xf -)
}

archive_name="crashpad-unity-linux-x64.7z"
build_dir="$X64_BUILD"

if [[ ! -d "$build_dir" ]]; then
    echo "ERROR: build dir not found: $build_dir" >&2
    exit 1
fi

gn_arg() {
    sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" "$build_dir/args.gn"
}
clang_path="$(gn_arg clang_path)"
COMPILER_VERSION="$("${clang_path:+$clang_path/bin/}clang" --version | head -1)"
sysroot="$(gn_arg target_sysroot)"
if [[ -n "$sysroot" ]]; then
    glibc_minor="$(sed -n 's/^#define[[:space:]]*__GLIBC_MINOR__[[:space:]]*\([0-9]*\).*/\1/p' "$sysroot/usr/include/features.h" 2>/dev/null || true)"
    SYSROOT_DESC="unity-linux-gnu-x86_64-sdk${glibc_minor:+ (glibc 2.$glibc_minor)}"
else
    SYSROOT_DESC="host (not linkable into the Unity Linux Editor)"
fi

stage="$(mktemp -d -t crashpad-stage-XXXXXX)"
trap "rm -rf '$stage'" EXIT

echo "==> Packing $archive_name (build: $build_dir)"

cp "$CRASHPAD_SRC/LICENSE" "$stage/LICENSE"
cp "$CRASHPAD_SRC/AUTHORS" "$stage/AUTHORS"

{
    printf 'This artifact contains a Unity-modified version of Crashpad\n'
    printf '(https://chromium.googlesource.com/crashpad/crashpad).\n'
    printf 'Modifications maintained at: %s\n\n' "$FORK_URL"
    printf 'Build provenance:\n'
    printf '  Fork HEAD:         %s\n' "$VERSION"
    if [[ -n "$UPSTREAM_BASE" ]]; then
        printf '  Upstream baseline: %s\n' "$UPSTREAM_BASE"
        printf '  Modifications:     %s/compare/%s...%s\n\n' "$FORK_URL" "$UPSTREAM_BASE" "$VERSION"
    else
        printf '  Upstream baseline: <not available — upstream-mirror ref not found>\n\n'
    fi
    printf 'Crashpad is licensed under the Apache License, Version 2.0; see LICENSE.\n\n'
    printf -- '----------------------------------------------------------------------\n'
    printf 'Third-party components statically linked into shipped libraries:\n'
    printf -- '----------------------------------------------------------------------\n\n'
    printf '=== mini_chromium (base/ library) ===\n\n'
    cat "$CRASHPAD_SRC/third_party/mini_chromium/mini_chromium/LICENSE"
    printf '\n\n=== ICU (Unicode UTF code, compiled into libbase.a as icu_utf.o) ===\n\n'
    cat "$CRASHPAD_SRC/third_party/mini_chromium/mini_chromium/base/third_party/icu/LICENSE"
    printf '\n\n=== linux-syscall-support (header-only, compiled into Linux libraries) ===\n\n'
    cat "$CRASHPAD_SRC/third_party/lss/lss/LICENSE"
    printf '\n\n'
    printf -- '----------------------------------------------------------------------\n'
    printf 'Third-party components used but not bundled:\n'
    printf -- '----------------------------------------------------------------------\n\n'
    printf '  zlib     Linked by the consumer (-lz); not included in this artifact.\n'
    printf '  libcurl  Headers used at build time only; libcurl.so is loaded with\n'
    printf '           dlopen() at runtime if uploads are enabled.\n'
} > "$stage/NOTICE"

cat > "$stage/README.txt" <<EOF
Crashpad libraries and sources for Unity Linux crash handler.

This is a Unity-modified version of Crashpad.
Upstream: https://chromium.googlesource.com/crashpad/crashpad
Unity fork: $FORK_URL

License: Apache 2.0 (see LICENSE). Third-party notices: see NOTICE.

Layout:
  include/         Headers (Crashpad + mini_chromium)
  src/             Crashpad source files compiled directly by Unity's build
  lib/linux/x64/   Static libraries (.a) linked into Unity

Built with:
  Compiler:  $COMPILER_VERSION
  Sysroot:   $SYSROOT_DESC

Compiling src/:
  Include dirs:  include  include/compat/linux  include/compat/non_win
  Defines:       NDEBUG CRASHPAD_ZLIB_SOURCE_SYSTEM
  Unity compiles src/ instead of linking libhandler.a, and defines
  crashpad::UnityCrashpadPostMinidumpHook itself.
  src/client/pthread_create_linux.cc is optional: it interposes pthread_create
  so that every thread gets an alternate signal stack.

Linking: all libraries except libhandler.a, then -lz -ldl -pthread.
EOF

mkdir -p "$stage/include"
for f in "$CRASHPAD_SRC"/*.h; do
    if [[ -f "$f" ]]; then
        cp "$f" "$stage/include/"
    fi
done
for sub in "${HEADER_TREES_CRASHPAD[@]}"; do
    if [[ -d "$CRASHPAD_SRC/$sub" ]]; then
        copy_headers "$CRASHPAD_SRC/$sub" "$stage/include/$sub"
    fi
done
for rel in "${EXTRA_HEADERS[@]}"; do
    mkdir -p "$stage/include/$(dirname "$rel")"
    cp "$CRASHPAD_SRC/$rel" "$stage/include/$rel"
done
for sub in "${HEADER_TREES_MINICHROMIUM[@]}"; do
    src="$CRASHPAD_SRC/third_party/mini_chromium/mini_chromium/$sub"
    if [[ -d "$src" ]]; then
        copy_headers "$src" "$stage/include/$sub"
    fi
done

for rel in "${UNITY_SOURCES[@]}"; do
    from="$CRASHPAD_SRC/$rel"
    if [[ ! -f "$from" ]]; then
        echo "ERROR: missing source: $from" >&2
        exit 1
    fi
    mkdir -p "$stage/src/$(dirname "$rel")"
    cp "$from" "$stage/src/$rel"
done

mkdir -p "$stage/lib/linux/x64"
for entry in "${LIB_MAP[@]}"; do
    libname="${entry%%:*}"
    relpath="${entry##*:}"
    from="$build_dir/$relpath"
    if [[ ! -f "$from" ]]; then
        echo "ERROR: missing lib: $from" >&2
        exit 1
    fi
    cp "$from" "$stage/lib/linux/x64/$libname"
done

rm -f "$OUTPUT_DIR/$archive_name"
(cd "$stage" && 7z a -bd "$OUTPUT_DIR/$archive_name" -r LICENSE NOTICE AUTHORS README.txt include src lib >/dev/null)
echo "    wrote $OUTPUT_DIR/$archive_name ($(du -h "$OUTPUT_DIR/$archive_name" | cut -f1))"

sha="$(sha256sum "$OUTPUT_DIR/$archive_name" | awk '{print $1}')"
echo "    artifact id: crashpad-unity-linux-x64/${VERSION}_${sha}.7z"

echo "Done. Output in: $OUTPUT_DIR"
