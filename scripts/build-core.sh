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
        spb_terminal_test spb_link_closure_test
}

LIBS=()
for arch in "${ARCHS[@]}"; do
    echo "== Building core for $arch ($CONFIG)"
    configure_and_build "$BUILD/core-$arch" "$arch" "$CONFIG"
    LIBS+=("$BUILD/core-$arch/libSwiftPuttyCore.a")
done

echo "== Creating universal library and xcframework"
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
    echo "== C bridge tests ($HOST_ARCH)"
    (cd "$BUILD/core-$HOST_ARCH" && ctest --output-on-failure)
    for test in spb_bridge_test spb_session_test spb_terminal_test; do
        echo "== $test under leaks --atExit ($HOST_ARCH)"
        leaks --atExit -- "$BUILD/core-$HOST_ARCH/$test" \
            | grep -E "^Process [0-9]+: [0-9]+ leaks" \
            | tee /dev/stderr | grep -q ": 0 leaks"
    done
fi

if [[ $RUN_ASAN == 1 ]]; then
    echo "== C bridge tests with ASan+UBSan ($HOST_ARCH)"
    SAN_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined"
    configure_and_build "$BUILD/core-asan-$HOST_ARCH" "$HOST_ARCH" Debug \
        -DCMAKE_C_FLAGS="$SAN_FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined"
    (cd "$BUILD/core-asan-$HOST_ARCH" && ctest --output-on-failure)
fi

if [[ $RUN_TSAN == 1 ]]; then
    echo "== C bridge tests with TSan ($HOST_ARCH)"
    configure_and_build "$BUILD/core-tsan-$HOST_ARCH" "$HOST_ARCH" Debug \
        -DCMAKE_C_FLAGS="-fsanitize=thread -fno-omit-frame-pointer" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread"
    (cd "$BUILD/core-tsan-$HOST_ARCH" \
        && TSAN_OPTIONS=halt_on_error=1 ctest --output-on-failure)
fi
