#!/usr/bin/env bash
#
# check-linux-artifact.sh -- verify that crashpad-unity-linux-x64.7z is usable
# the way Unity consumes it: build a minimal handler from src/ plus every
# library except libhandler.a, and a client that starts it and crashes.
#
# Checks:
#   1. libhandler.a carries the Unity hook and its Linux call site.
#   2. The handler and client compile and link against Unity's sysroot.
#   3. Neither binary needs a glibc newer than 2.35.
#   4. A crash produces a minidump and calls the hook with the crashed pid.
#
# Usage:
#   check-linux-artifact.sh [ARCHIVE]    (default: out/dist/crashpad-unity-linux-x64.7z)
#
# Environment:
#   UNITY_LINUX_SDK  unpacked unity-linux-gnu-x86_64-sdk Stevedore artifact (required)
#   UNITY_CLANG      unpacked llvm-linux-x64 (clang 15, what the Editor uses) or
#                    llvm-21-linux-x64 Stevedore artifact (default: clang++ from PATH)
#   CXX_STD          C++ standard for src/ (default: c++20)
#   KEEP_WORK=1      keep the work directory
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRASHPAD_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCHIVE="$(realpath "${1:-$CRASHPAD_SRC/out/dist/crashpad-unity-linux-x64.7z}")"
CXX_STD="${CXX_STD:-c++20}"

if [[ -z "${UNITY_LINUX_SDK:-}" ]]; then
    echo "ERROR: UNITY_LINUX_SDK is not set" >&2
    exit 1
fi
SDK="$(cd "$UNITY_LINUX_SDK" && pwd)"
SYSROOT="$SDK/x86_64-unity-linux-gnu/sysroot"
CXX="${UNITY_CLANG:+$UNITY_CLANG/bin/}clang++"

work="$(mktemp -d -t crashpad-check-XXXXXX)"
if [[ "${KEEP_WORK:-0}" != "1" ]]; then
    trap "rm -rf '$work'" EXIT
fi
echo "==> Work dir: $work"
echo "==> Compiler: $("$CXX" --version | head -1)"

mkdir "$work/artifact"
(cd "$work/artifact" && 7z x -bd "$ARCHIVE" >/dev/null)
A="$work/artifact"
LIBDIR="$A/lib/linux/x64"

echo "==> 1. Hook in libhandler.a"
hook_syms="$(nm -A -C "$LIBDIR/libhandler.a" | grep 'crashpad::UnityCrashpadPostMinidumpHook' || true)"
echo "$hook_syms" | sed 's/^/    /'
if ! grep -q 'crash_report_exception_handler.*\.o: *U ' <<<"$hook_syms" ||
    ! grep -q 'unity_post_minidump_hook.*\.o:[0-9a-f]* [BbDd] ' <<<"$hook_syms"; then
    echo "ERROR: libhandler.a lacks the hook definition or its call site" >&2
    exit 1
fi
echo "    OK"

FLAGS=(
    --target=x86_64-unity-linux-gnu "--gcc-toolchain=$SDK" "--sysroot=$SYSROOT"
    -stdlib=libstdc++ -m64 -pthread
)
CXXFLAGS=(
    "${FLAGS[@]}" "-std=$CXX_STD" -O2
    -DNDEBUG -DCRASHPAD_ZLIB_SOURCE_SYSTEM
    -I"$A/include" -I"$A/include/compat/linux" -I"$A/include/compat/non_win"
)
LIBS=()
for lib in client common minidump snapshot context format net util compat base; do
    LIBS+=("$LIBDIR/lib$lib.a")
done

cat > "$work/handler_main.cc" <<'EOF'
#include <stdio.h>

#include <string>

#include "handler/handler_main.h"
#include "handler/unity_post_minidump_hook.h"

namespace {

void LogHook(const base::FilePath& database_path,
             const crashpad::UUID& report_id,
             crashpad::UnityCrashedProcess crashed_process) {
  char state = '?';
  std::string stat_path = "/proc/" + std::to_string(crashed_process) + "/stat";
  if (FILE* stat = fopen(stat_path.c_str(), "r")) {
    if (fscanf(stat, "%*d (%*[^)]) %c", &state) != 1) {
      state = '?';
    }
    fclose(stat);
  }
  if (FILE* log = fopen(database_path.Append("hook.log").value().c_str(), "a")) {
    fprintf(log, "pid=%d state=%c report=%s\n", crashed_process, state,
            report_id.ToString().c_str());
    fclose(log);
  }
}

}  // namespace

namespace crashpad {
void (*UnityCrashpadPostMinidumpHook)(const base::FilePath&,
                                      const UUID&,
                                      UnityCrashedProcess) = LogHook;
}  // namespace crashpad

int main(int argc, char* argv[]) {
  return crashpad::HandlerMain(argc, argv, nullptr);
}
EOF

cat > "$work/client_main.cc" <<'EOF'
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "client/crashpad_client.h"

namespace {

void* Crash(void*) {
  *static_cast<volatile int*>(nullptr) = 1;
  return nullptr;
}

}  // namespace

// client_main <handler> <database> [crash|crash-thread]
int main(int argc, char* argv[]) {
  crashpad::CrashpadClient client;
  if (!client.StartHandler(base::FilePath(argv[1]), base::FilePath(argv[2]),
                           base::FilePath(argv[2]), std::string(), {}, {},
                           false, false)) {
    fprintf(stderr, "StartHandler failed\n");
    return 1;
  }
  if (argc > 3 && strcmp(argv[3], "crash") == 0) {
    Crash(nullptr);
  }
  if (argc > 3 && strcmp(argv[3], "crash-thread") == 0) {
    pthread_t thread;
    pthread_create(&thread, nullptr, Crash, nullptr);
    pthread_join(thread, nullptr);
  }
  return 0;
}
EOF

echo "==> 2. Compile src/ and link without libhandler.a"
mkdir "$work/obj"
objs=()
while IFS= read -r -d '' cc; do
    rel="${cc#"$A/src/"}"
    obj="$work/obj/${rel//\//_}.o"
    "$CXX" "${CXXFLAGS[@]}" -c "$cc" -o "$obj"
    objs+=("$obj")
done < <(find "$A/src" -name '*.cc' -print0 | sort -z)

handler_objs=()
for obj in "${objs[@]}"; do
    [[ "$obj" == *pthread_create_linux* ]] || handler_objs+=("$obj")
done
"$CXX" "${CXXFLAGS[@]}" -c "$work/handler_main.cc" -o "$work/obj/handler_main.o"
"$CXX" "${CXXFLAGS[@]}" -c "$work/client_main.cc" -o "$work/obj/client_main.o"

link_binary() {
    local out="$1"; shift
    "$CXX" "${FLAGS[@]}" "$@" -Wl,--start-group "${LIBS[@]}" -Wl,--end-group \
        -lz -ldl -o "$out" -Wl,--trace > "$out.trace"
    grep -E '/libc\.so|/libstdc\+\+' "$out.trace" | sed 's/^/    /'
    if grep -E '/libc\.so' "$out.trace" | grep -qv "$SYSROOT"; then
        echo "ERROR: $out linked against a libc outside the sysroot" >&2
        exit 1
    fi
}
link_binary "$work/handler" "$work/obj/handler_main.o" "${handler_objs[@]}"
link_binary "$work/client" "$work/obj/client_main.o" "$work/obj/client_pthread_create_linux.cc.o"
echo "    OK"

echo "==> 3. glibc ceiling"
for bin in handler client; do
    max="$(objdump -T "$work/$bin" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
    echo "    $bin: $max"
    if [[ "$(printf '%s\nGLIBC_2.35\n' "$max" | sort -V | tail -1)" != "GLIBC_2.35" ]]; then
        echo "ERROR: $bin needs $max (> GLIBC_2.35)" >&2
        exit 1
    fi
done

echo "==> 4. Crash smoke test"
for mode in crash crash-thread; do
    db="$work/db-$mode"
    status=0
    "$work/client" "$work/handler" "$db" "$mode" || status=$?
    echo "    $mode: client exit status $status"
    dumps=("$db"/pending/*.dmp)
    if [[ ! -f "${dumps[0]}" ]]; then
        echo "ERROR: no minidump in $db/pending" >&2
        exit 1
    fi
    echo "    minidump: $(basename "${dumps[0]}") ($(stat -c %s "${dumps[0]}") bytes)"
    if [[ ! -f "$db/hook.log" ]]; then
        echo "ERROR: hook was not called ($db/hook.log missing)" >&2
        exit 1
    fi
    sed 's/^/    hook: /' "$db/hook.log"
done

echo "All checks passed."
