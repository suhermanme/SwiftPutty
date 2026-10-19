#!/bin/bash
# Build the SwiftPutty C core (PuTTY + bridge) as a universal static
# library packaged in build/SwiftPuttyCore.xcframework.
#
#   scripts/build-core.sh [--config <CMake build type>] [--test] [--asan]
#                         [--tsan]
#
#   --config   CMake build type (default: RelWithDebInfo)
#   --test     also run the C bridge tests for the host architecture,
#              including `leaks --atExit` passes
#   --asan     also build and run the C bridge tests with
#              AddressSanitizer + UndefinedBehaviorSanitizer (host arch)
#   --tsan     also build and run the C bridge tests with
#              ThreadSanitizer (host arch)
#
# Each architecture is configured separately and the results combined
# with lipo: a single multi-arch configure makes upstream's CPU-feature
# probes fail and silently drops hardware crypto (docs/DECISIONS.md D-006).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
CONFIG=RelWithDebInfo
RUN_TESTS=0
RUN_ASAN=0
RUN_TSAN=0
ARCHS=(arm64 x86_64)
DEPLOYMENT_TARGET=14.0
HOST_ARCH="$(uname -m)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2 ;;
        --test) RUN_TESTS=1; shift ;;
        --asan) RUN_ASAN=1; shift ;;
        --tsan) RUN_TSAN=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# Section headings. Under GitHub Actions each also becomes a notice
# annotation, which is recorded as it is printed, so the last section
# reached is known even if the runner dies.
section() {
    echo "== $*"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        echo "::notice title=build-core::$*"
    fi
}

"$ROOT/scripts/prepare-putty-src.sh" "$BUILD/putty-src"

configure_and_build() {
    local dir="$1" arch="$2" config="$3"; shift 3
    cmake -S "$BUILD/putty-src" -B "$dir" -G Ninja \
        -DCMAKE_BUILD_TYPE="$config" \
        -DPUTTY_GTK_VERSION=NONE \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_PROJECT_putty_INCLUDE="$ROOT/Core/cmake/SwiftPuttyCore.cmake" \
        -DSWIFTPUTTY_ROOT="$ROOT" \
        "$@" > "$dir.configure.log" 2>&1 \
        || { cat "$dir.configure.log" >&2; return 1; }
    cmake --build "$dir" --target swiftputty-core spb_bridge_test spb_session_test \
        spb_terminal_test spb_ssh_test spb_ssh_fixture uppity \
        spb_backends_test spb_link_closure_test spb_fuzz_terminal spb_fuzz_parsers
}

LIBS=()
for arch in "${ARCHS[@]}"; do
    section "Building core for $arch ($CONFIG)"
    configure_and_build "$BUILD/core-$arch" "$arch" "$CONFIG"
    LIBS+=("$BUILD/core-$arch/libSwiftPuttyCore.a")
done

section "Creating universal library and xcframework"
UNIVERSAL="$BUILD/universal"
rm -rf "$UNIVERSAL" "$BUILD/SwiftPuttyCore.xcframework"
mkdir -p "$UNIVERSAL/Headers"
lipo -create "${LIBS[@]}" -output "$UNIVERSAL/libSwiftPuttyCore.a"
cp "$ROOT/Core/include/PuTTYBridge.h" "$ROOT/Core/include/module.modulemap" \
   "$UNIVERSAL/Headers/"
xcodebuild -create-xcframework \
    -library "$UNIVERSAL/libSwiftPuttyCore.a" -headers "$UNIVERSAL/Headers" \
    -output "$BUILD/SwiftPuttyCore.xcframework" > /dev/null
lipo -info "$UNIVERSAL/libSwiftPuttyCore.a"

if [[ $RUN_TESTS == 1 ]]; then

    section "C bridge tests ($HOST_ARCH)"
    if ! (cd "$BUILD/core-$HOST_ARCH" && ctest --output-on-failure --timeout 600); then
        if [[ "$HOST_ARCH" == "x86_64" ]]; then
            section "Re-running spb_ssh_test under lldb for crash diagnostics"
            lldb_log="$BUILD/spb_ssh_test-lldb.log"
            (cd "$BUILD/core-$HOST_ARCH" \
                && lldb --batch -o run -o "thread backtrace all" -- ./spb_ssh_test) \
                > "$lldb_log" 2>&1 || true
            backtrace="$(awk '/thread #[0-9]+|frame #[0-9]+:|stop reason =/ {
                gsub(/%/, "%25"); gsub(/\r/, "%0D");
                printf "%s%%0A", $0
            }' "$lldb_log")"
            echo "::error title=spb_ssh_test crash backtrace::$backtrace"
        fi
        exit 1
    fi
    for test in spb_bridge_test spb_session_test spb_terminal_test \
                spb_ssh_test spb_backends_test; do
        section "$test under leaks --atExit ($HOST_ARCH)"
        # Apple's Heimdal leaks inside krb5_get_credentials (a Kerberos
        # credential the Mac holds, e.g. its local KDC's) and
        # _krb5_build_authenticator (every GSSAPI context it builds);
        # not ours, so excluded (D-043, D-044). leaks still counts
        # excluded blocks in its total: every leak must be one.
        out="$(MallocStackLogging=1 leaks --atExit --exclude krb5_get_credentials \
               --exclude _krb5_build_authenticator \
               -- "$BUILD/core-$HOST_ARCH/$test" 2>/dev/null)" || true
        total="$(sed -nE 's/^Process [0-9]+: ([0-9]+) leaks.*/\1/p' <<<"$out")"
        excluded="$(sed -nE 's/^([0-9]+) leaks? excluded.*/\1/p' <<<"$out")"
        echo "  $test: ${total:-?} leaks, ${excluded:-0} excluded (Heimdal)" >&2
        [[ -n "$total" && "$total" -eq "${excluded:-0}" ]]
    done
fi

if [[ $RUN_ASAN == 1 ]]; then
    section "C bridge tests with ASan+UBSan ($HOST_ARCH)"
    SAN_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined"
    configure_and_build "$BUILD/core-asan-$HOST_ARCH" "$HOST_ARCH" Debug \
        -DCMAKE_C_FLAGS="$SAN_FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined"
    # The SSH test server and relay run unsanitized (spb_ssh_test.c).
    (cd "$BUILD/core-asan-$HOST_ARCH" \
        && SPB_SSH_FIXTURE_DIR="$BUILD/core-$HOST_ARCH" \
           ctest --output-on-failure --timeout 600)
fi

if [[ $RUN_TSAN == 1 ]]; then
    section "C bridge tests with TSan ($HOST_ARCH)"
    configure_and_build "$BUILD/core-tsan-$HOST_ARCH" "$HOST_ARCH" Debug \
        -DCMAKE_C_FLAGS="-fsanitize=thread -fno-omit-frame-pointer" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread"
    (cd "$BUILD/core-tsan-$HOST_ARCH" \
        && SPB_SSH_FIXTURE_DIR="$BUILD/core-$HOST_ARCH" \
           TSAN_OPTIONS=halt_on_error=1 ctest --output-on-failure --timeout 600)
fi
