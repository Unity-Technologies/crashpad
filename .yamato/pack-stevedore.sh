#!/usr/bin/env bash
#
# pack-stevedore.sh — assemble the Stevedore artifact(s) for Unity's macOS
# Crashpad consumer. Produces crashpad-unity-mac-arm64.7z and crashpad-unity-mac-x64.7z
# matching the layout Unity's build code expects.
#
# Archive layout produced (per arch):
#   LICENSE      (Crashpad Apache 2.0)
#   NOTICE       (Unity modifications + surfaced third-party licenses)
#   AUTHORS      (Crashpad authors)
#   README.txt   (minimal, points back to the fork)
#   include/     (headers only — Crashpad + mini_chromium)
#   src/         (the .cc source files Unity compiles directly)
#   gen/         (MIG-generated headers and stubs)
#   lib/macos/<arch>/*.a   (prebuilt static libraries)
#
# Usage:
#   pack-stevedore.sh [OUTPUT_DIR]
#
# Environment overrides:
#   CRASHPAD_SRC     path to the fork checkout      (default: this script's grandparent)
#   ARM64_BUILD      path to out/arm64-release      (default: $CRASHPAD_SRC/out/arm64-release)
#   X64_BUILD        path to out/x64-release        (default: $CRASHPAD_SRC/out/x64-release)
#   FORK_URL         URL of the Unity Crashpad fork (default: placeholder)
#   VERSION          version string for filenames   (default: short git SHA of fork)
#   SKIP_X64=1       only build the arm64 archive
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="${CRASHPAD_SRC:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ARM64_BUILD="${ARM64_BUILD:-$CRASHPAD_SRC/out/arm64-release}"
X64_BUILD="${X64_BUILD:-$CRASHPAD_SRC/out/x64-release}"
OUTPUT_DIR="${1:-$CRASHPAD_SRC/out/dist}"
FORK_URL="${FORK_URL:-https://github.com/Unity-Technologies/crashpad}"

if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(cd "$CRASHPAD_SRC" && git rev-parse --short=12 HEAD 2>/dev/null || echo dev)"
fi

# Discover the upstream Crashpad commit this fork was rebased onto.
# Convention: $UPSTREAM_REF (default origin/main) mirrors upstream Crashpad
# pristine; Unity work lives on branches rebased on top. `git merge-base`
# finds the most recent common ancestor — the upstream baseline.
UPSTREAM_REF="${UPSTREAM_REF:-origin/main}"
UPSTREAM_BASE="$(cd "$CRASHPAD_SRC" && git merge-base HEAD "$UPSTREAM_REF" 2>/dev/null | cut -c 1-12 || true)"

mkdir -p "$OUTPUT_DIR"

# Static-library mapping: archive name -> ninja output relative to a build dir.
# The mapping reproduces the existing builds.zip lib naming.
# libcommon.a comes from client/ (verified via `ar t`); handler/libcommon.a is
# a separate internal lib that Unity does not link.
LIB_MAP=(
    "libbase.a:obj/third_party/mini_chromium/mini_chromium/base/libbase.a"
    "libclient.a:obj/client/libclient.a"
    "libcommon.a:obj/client/libcommon.a"
    "libcontext.a:obj/snapshot/libcontext.a"
    "libformat.a:obj/minidump/libformat.a"
    "libhandler.a:obj/handler/libhandler.a"
    "libmig_output.a:obj/util/libmig_output.a"
    "libminidump.a:obj/minidump/libminidump.a"
    "libnet.a:obj/util/libnet.a"
    "libsnapshot.a:obj/snapshot/libsnapshot.a"
    "libutil.a:obj/util/libutil.a"
)

# Crashpad source files Unity's build compiles directly (see
# UnityMacCrashHandler.jam.cs in the Unity repo). All paths are relative to
# $CRASHPAD_SRC and land under src/ in the archive.
UNITY_SOURCES=(
    "handler/handler_main.cc"
    "handler/prune_crash_reports_thread.cc"
    "handler/crash_report_upload_rate_limit.cc"
    "handler/crash_report_upload_thread.cc"
    "handler/minidump_to_upload_parameters.cc"
    "handler/user_stream_data_source.cc"
    "handler/mac/crash_report_exception_handler.cc"
    "handler/mac/exception_handler_server.cc"
    "handler/mac/file_limit_annotation.cc"
    "tools/tool_support.cc"
    "util/mach/notify_server.cc"
)

# Header trees (copy .h only into include/). Source-tree subdirs that contain
# headers Unity may transitively include. Paths relative to $CRASHPAD_SRC.
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

pack_one_arch() {
    local arch="$1"      # arm64 or x86_64
    local arch_tag="$2"  # arm64 or x64 (used in artifact name)
    local build_dir="$3"
    local archive_name="crashpad-unity-mac-${arch_tag}.7z"

    if [[ ! -d "$build_dir" ]]; then
        echo "ERROR: build dir not found: $build_dir" >&2
        return 1
    fi

    local stage; stage="$(mktemp -d -t crashpad-stage-XXXXXX)"
    trap "rm -rf '$stage'" RETURN

    echo "==> Packing $archive_name (build: $build_dir)"

    # --- Root-level legal/meta files (generated from source — no checked-in copies) ---
    cp "$CRASHPAD_SRC/LICENSE" "$stage/LICENSE"
    cp "$CRASHPAD_SRC/AUTHORS" "$stage/AUTHORS"

    # NOTICE = Unity modifications statement + verbatim third-party licenses
    # for code statically linked into the shipped .a libraries (mini_chromium
    # provides base/, which embeds ICU UTF code with its own license).
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
        printf '\n'
    } > "$stage/NOTICE"

    cat > "$stage/README.txt" <<EOF
Crashpad libraries and patched sources for Unity macOS crash handler.

This is a Unity-modified version of Crashpad.
Upstream: https://chromium.googlesource.com/crashpad/crashpad
Unity fork: $FORK_URL

License: Apache 2.0 (see LICENSE). Third-party notices: see NOTICE.

Layout:
  include/       Headers (Crashpad + mini_chromium)
  src/           Crashpad source files compiled directly by Unity's build
  gen/           MIG-generated mach interface stubs (build artifacts)
  lib/macos/${arch}/  Static libraries (.a) linked into Unity
EOF

    # --- include/  (headers only) ---
    mkdir -p "$stage/include"
    # Root-level Crashpad headers (e.g. package.h)
    for f in "$CRASHPAD_SRC"/*.h; do
        [[ -f "$f" ]] && cp "$f" "$stage/include/"
    done
    for sub in "${HEADER_TREES_CRASHPAD[@]}"; do
        if [[ -d "$CRASHPAD_SRC/$sub" ]]; then
            mkdir -p "$stage/include/$sub"
            (cd "$CRASHPAD_SRC/$sub" && find . -name "*.h" -not -path "*/test/*" -not -name "*_test.h" -print0) \
                | (cd "$CRASHPAD_SRC/$sub" && tar --null -cf - --files-from=-) \
                | (cd "$stage/include/$sub" && tar -xf -)
        fi
    done
    for sub in "${HEADER_TREES_MINICHROMIUM[@]}"; do
        local src="$CRASHPAD_SRC/third_party/mini_chromium/mini_chromium/$sub"
        if [[ -d "$src" ]]; then
            mkdir -p "$stage/include/$sub"
            (cd "$src" && find . -name "*.h" -not -path "*/test/*" -not -name "*_test.h" -print0) \
                | (cd "$src" && tar --null -cf - --files-from=-) \
                | (cd "$stage/include/$sub" && tar -xf -)
        fi
    done

    # --- src/  (only the .cc files Unity compiles) ---
    for relsrc in "${UNITY_SOURCES[@]}"; do
        local from="$CRASHPAD_SRC/$relsrc"
        local to="$stage/src/$relsrc"
        if [[ ! -f "$from" ]]; then
            echo "ERROR: missing source: $from" >&2
            return 1
        fi
        mkdir -p "$(dirname "$to")"
        cp "$from" "$to"
    done

    # --- gen/  (generated headers + MIG stubs) ---
    if [[ -d "$build_dir/gen" ]]; then
        mkdir -p "$stage/gen"
        (cd "$build_dir/gen" && find . -type f \( -name "*.h" -o -name "*.c" \) -print0) \
            | (cd "$build_dir/gen" && tar --null -cf - --files-from=-) \
            | (cd "$stage/gen" && tar -xf -)
    fi

    # --- lib/macos/<arch>/  (static libraries) ---
    mkdir -p "$stage/lib/macos/$arch"
    for entry in "${LIB_MAP[@]}"; do
        local libname="${entry%%:*}"
        local relpath="${entry##*:}"
        local from="$build_dir/$relpath"
        local to="$stage/lib/macos/$arch/$libname"
        if [[ ! -f "$from" ]]; then
            echo "ERROR: missing lib: $from" >&2
            return 1
        fi
        cp "$from" "$to"
    done

    # --- Pack ---
    rm -f "$OUTPUT_DIR/$archive_name"
    # -mtm/-mtc/-mta=off strip mtime/ctime/atime from archive entries so two
    # packs of the same build outputs produce byte-identical .7z files. Without
    # this, Stevedore content-hashes drift on every re-run because cp/tar stamp
    # fresh mtimes into the staging tree.
    (cd "$stage" && 7z a -bd -mtm=off -mtc=off -mta=off -xr'!.DS_Store' "$OUTPUT_DIR/$archive_name" -r LICENSE NOTICE AUTHORS README.txt include src gen lib >/dev/null)
    echo "    wrote $OUTPUT_DIR/$archive_name ($(du -h "$OUTPUT_DIR/$archive_name" | cut -f1))"

    # --- Stevedore-style artifact ID (informational) ---
    local sha; sha="$(shasum -a 256 "$OUTPUT_DIR/$archive_name" | awk '{print $1}')"
    echo "    artifact id: crashpad-unity-mac-${arch_tag}/${VERSION}_${sha}.7z"
}

pack_one_arch arm64 arm64 "$ARM64_BUILD"
if [[ "${SKIP_X64:-0}" != "1" ]]; then
    pack_one_arch x86_64 x64 "$X64_BUILD"
fi

echo "Done. Output in: $OUTPUT_DIR"
