#!/bin/bash
# Build SwiftPutty.app.
#
#   scripts/build-app.sh [Debug|Release]      (default: Release)
#
# Builds the C core first (scripts/build-core.sh), then the app with
# xcodebuild. Release builds target the generic macOS destination so the
# app is universal (arm64 + x86_64). Output:
#   build/DerivedData/Build/Products/<config>/SwiftPutty.app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"

"$ROOT/scripts/build-core.sh"

DESTINATION=()
if [[ "$CONFIG" == Release ]]; then
    DESTINATION=(-destination "generic/platform=macOS")
fi

xcodebuild \
    -project "$ROOT/App/SwiftPutty.xcodeproj" \
    -scheme SwiftPutty \
    -configuration "$CONFIG" \
    -derivedDataPath "$ROOT/build/DerivedData" \
    ${DESTINATION[@]+"${DESTINATION[@]}"} \
    build

APP="$ROOT/build/DerivedData/Build/Products/$CONFIG/SwiftPutty.app"
lipo -info "$APP/Contents/MacOS/SwiftPutty"
echo "Built $APP"
