#!/bin/bash
# Run every automated check for the current milestone.
#
#   scripts/test-all.sh [--clean]
#
#   --clean   remove build/ first (clean build, as required at the end of
#             each milestone)
#
# 1. C core for arm64 + x86_64, universal xcframework
# 2. C bridge tests (host arch): plain, under `leaks --atExit`, with
#    AddressSanitizer + UndefinedBehaviorSanitizer, and with
#    ThreadSanitizer
# 3. Swift package tests, plain, with AddressSanitizer and with
#    ThreadSanitizer
# 4. App: Debug build and universal Release build

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == --clean ]]; then
    rm -rf build .build
fi

echo "==== C core + bridge tests"
scripts/build-core.sh --test --asan --tsan

echo "==== Swift package tests"
swift test

echo "==== Swift package tests (AddressSanitizer)"
swift test --sanitize=address --scratch-path build/swiftpm-asan

echo "==== Swift package tests (ThreadSanitizer)"
swift test --sanitize=thread --scratch-path build/swiftpm-tsan

echo "==== App (Debug)"
xcodebuild -project App/SwiftPutty.xcodeproj -scheme SwiftPutty \
    -configuration Debug -derivedDataPath build/DerivedData build -quiet

echo "==== App (Release, universal)"
xcodebuild -project App/SwiftPutty.xcodeproj -scheme SwiftPutty \
    -configuration Release -derivedDataPath build/DerivedData \
    -destination "generic/platform=macOS" build -quiet
lipo -info build/DerivedData/Build/Products/Release/SwiftPutty.app/Contents/MacOS/SwiftPutty

echo "==== All checks passed"
