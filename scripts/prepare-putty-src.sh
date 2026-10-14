#!/bin/bash
# Produce a build copy of the vendored PuTTY source with patches/ applied.
#
#   scripts/prepare-putty-src.sh <output-dir>
#
# Vendor/putty is never modified. The output directory is recreated
# whenever the vendored tree or any patch changes (tracked by a stamp
# containing a hash of the inputs).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/putty"
PATCHES="$ROOT/patches"
OUT="${1:?usage: prepare-putty-src.sh <output-dir>}"

inputs_hash() {
    {
        (cd "$VENDOR" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
        if compgen -G "$PATCHES/*.patch" > /dev/null; then
            shasum -a 256 "$PATCHES"/*.patch
        fi
    } | shasum -a 256 | cut -d' ' -f1
}

HASH="$(inputs_hash)"
STAMP="$OUT/.swiftputty-prepared"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" ]]; then
    exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$VENDOR"/. "$OUT"/

shopt -s nullglob
for patch in "$PATCHES"/*.patch; do
    echo "Applying $(basename "$patch")"
    if ! (cd "$OUT" && patch -p1 --forward --silent --dry-run < "$patch" > /dev/null); then
        echo "error: $(basename "$patch") does not apply cleanly to Vendor/putty" >&2
        exit 1
    fi
    (cd "$OUT" && patch -p1 --forward --silent < "$patch")
done

echo "$HASH" > "$STAMP"
