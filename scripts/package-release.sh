#!/bin/bash
# Build and package an ad-hoc-signed universal macOS app for GitHub releases.
#
#   scripts/package-release.sh <version>   (for example: 0.1.0)
#
# Output: build/releases/SwiftPutty-v<version>-macos-universal.zip and .sha256

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <version> (MAJOR.MINOR.PATCH)" >&2
    exit 2
fi

"$ROOT/scripts/build-core.sh"

DERIVED_DATA="$ROOT/build/ReleaseDerivedData"
APP="$DERIVED_DATA/Build/Products/Release/SwiftPutty.app"
RELEASE_DIR="$ROOT/build/releases"
ZIP="$RELEASE_DIR/SwiftPutty-v$VERSION-macos-universal.zip"

xcodebuild \
    -quiet \
    -project "$ROOT/App/SwiftPutty.xcodeproj" \
    -scheme SwiftPutty \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    build

# lipo's input file is positional and must come before the command
# (-verify_arch), not after: `lipo -verify_arch arm64 <file>` makes lipo
# treat the file path as another arch_type argument to -verify_arch and
# error with no input file given.
lipo "$APP/Contents/MacOS/SwiftPutty" -verify_arch arm64
lipo "$APP/Contents/MacOS/SwiftPutty" -verify_arch x86_64
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if [[ "$SIGNATURE_INFO" != *"Signature=adhoc"* ]]; then
    echo "expected an ad-hoc code signature: $APP" >&2
    exit 1
fi

mkdir -p "$RELEASE_DIR"
rm -f "$ZIP" "$ZIP.sha256"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
(
    cd "$RELEASE_DIR"
    shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256"
)
echo "Packaged $ZIP"
echo "Checksum $ZIP.sha256"

