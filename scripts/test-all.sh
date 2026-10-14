#!/bin/bash
# Run every automated check for the current milestone.
#
#   scripts/test-all.sh [--clean] [--stage <stage>]...
#
#   --clean   remove build/ first (clean build, as required at the end of
#             each milestone)
#   --stage   run only the named stage(s), in this order (default: all):
#
#   core        C core for arm64 + x86_64, universal xcframework; C bridge
#               tests (host arch): plain, under `leaks --atExit`, with
#               AddressSanitizer + UndefinedBehaviorSanitizer, and with
#               ThreadSanitizer
#   swift-build Swift package and tests, built only (part of `swift`)
#   swift       Swift package tests
#   swift-asan  Swift package tests with AddressSanitizer
#   swift-tsan  Swift package tests with ThreadSanitizer
#   app         App: Debug build and universal Release build
#
# The stages after `core` need its output (build/SwiftPuttyCore.xcframework
# and the SSH test fixture). CI runs each stage as its own step.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ALL_STAGES=(core swift swift-asan swift-tsan app)
STAGES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) rm -rf build .build; shift ;;
        --stage) STAGES+=("$2"); shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ ${#STAGES[@]} -eq 0 ]] && STAGES=("${ALL_STAGES[@]}")

for stage in "${STAGES[@]}"; do
    case "$stage" in
      core)
        echo "==== C core + bridge tests"
        scripts/build-core.sh --test --asan --tsan
        ;;
      swift-build)
        echo "==== Swift package build"
        swift build --build-tests
        ;;
      swift)
        echo "==== Swift package tests"
        swift test
        ;;
      swift-asan)
        echo "==== Swift package tests (AddressSanitizer)"
        swift test --sanitize=address --scratch-path build/swiftpm-asan
        ;;
      swift-tsan)
        echo "==== Swift package tests (ThreadSanitizer)"
        swift test --sanitize=thread --scratch-path build/swiftpm-tsan
        ;;
      app)
        echo "==== App (Debug)"
        xcodebuild -project App/SwiftPutty.xcodeproj -scheme SwiftPutty \
            -configuration Debug -derivedDataPath build/DerivedData build -quiet
        echo "==== App (Release, universal)"
        xcodebuild -project App/SwiftPutty.xcodeproj -scheme SwiftPutty \
            -configuration Release -derivedDataPath build/DerivedData \
            -destination "generic/platform=macOS" build -quiet
        lipo -info build/DerivedData/Build/Products/Release/SwiftPutty.app/Contents/MacOS/SwiftPutty
        ;;
      *)
        echo "unknown stage: $stage" >&2
        exit 2
        ;;
    esac
done

echo "==== All checks passed"
