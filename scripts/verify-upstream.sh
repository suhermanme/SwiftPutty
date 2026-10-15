#!/bin/bash
# Check that Vendor/putty is exactly PuTTY's signed release archive.
#
#   scripts/verify-upstream.sh [version]        (default: 0.85)
#
# Downloads the release archive, its signature and PuTTY's keys into a
# temporary directory, with a keyring of its own (your ~/.gnupg is not
# used). Checks that the signature is good and made by the pinned
# release key, that the pinned master key certifies that release key,
# and that the previous master key certifies the master key; then that
# the archive's contents are identical to Vendor/putty. Needs curl and
# gpg (Homebrew: gnupg).
#
# The fingerprints below are PuTTY's own (keys.html). When PuTTY
# rotates its keys, check the new ones against that page and the
# previous master key's certification before changing them here.

set -euo pipefail

VERSION="${1:-0.85}"
RELEASE_KEY=1A07DAC0F220CF12248EA7195C67D0F88BC3E5B5   # PuTTY Releases (2026)
MASTER_KEY=371C662B855F318FF63AD091D732471F094D5FB5    # PuTTY Master Key (2026)
PREVIOUS_MASTER=28D47C4655E765A6D827AC66B15D9EFC216B06A1  # Master Key (2023)
KEYS_URL=https://www.chiark.greenend.org.uk/~sgtatham/putty/keys
RELEASE_URL="https://the.earth.li/~sgtatham/putty/$VERSION"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spb-verify-upstream.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"

fetch() { curl -sSfL --retry 5 --retry-all-errors -o "$WORK/$1" "$2"; }

echo "== Downloading PuTTY $VERSION and keys"
fetch archive.tar.gz "$RELEASE_URL/putty-$VERSION.tar.gz"
fetch archive.tar.gz.gpg "$RELEASE_URL/putty-$VERSION.tar.gz.gpg"
for key in release-2026 master-2026 master-2023; do
    fetch "$key.asc" "$KEYS_URL/$key.asc"
    gpg -q --import "$WORK/$key.asc" 2>/dev/null
done

# A certification of key $1 by key $2 that gpg checked ("sig!").
certifies() {
    gpg --with-colons --check-sigs "$1" 2>/dev/null \
        | awk -F: -v k="${2: -16}" '$1 == "sig" && $2 == "!" && $5 == k { found = 1 }
                                    END { exit !found }'
}

echo "== Checking the key chain"
certifies "$MASTER_KEY" "$PREVIOUS_MASTER" \
    || { echo "error: the 2023 master key does not certify the 2026 one" >&2; exit 1; }
certifies "$RELEASE_KEY" "$MASTER_KEY" \
    || { echo "error: the master key does not certify the release key" >&2; exit 1; }

echo "== Checking the signature"
status="$(gpg --status-fd 1 --verify "$WORK/archive.tar.gz.gpg" "$WORK/archive.tar.gz" 2>/dev/null)"
grep -q "^\[GNUPG:\] VALIDSIG $RELEASE_KEY " <<<"$status" \
    || { echo "error: no good signature by the release key" >&2; exit 1; }
echo "   good signature by $RELEASE_KEY"
shasum -a 256 "$WORK/archive.tar.gz" | awk '{ print "   archive SHA-256 " $1 }'

echo "== Comparing with Vendor/putty"
mkdir "$WORK/x"
tar -xzf "$WORK/archive.tar.gz" -C "$WORK/x"
if ! diff -r "$WORK/x/putty-$VERSION" "$ROOT/Vendor/putty" > "$WORK/diff.txt"; then
    head -20 "$WORK/diff.txt" >&2
    echo "error: Vendor/putty differs from the signed archive" >&2
    exit 1
fi
echo "   identical"
echo "==== Vendor/putty is PuTTY $VERSION as signed by the PuTTY team"
