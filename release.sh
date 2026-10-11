#!/bin/bash
# Cuts a release: version bump, signed build, zip, appcast, GitHub release.
#
#   ./release.sh 0.2.0            publish
#   ./release.sh 0.2.0 --dry-run  build and sign, change nothing outside build/
#
# NOT YET DISTRIBUTABLE TO OTHER MACS. Releases are signed with whatever certificate
# build-app.sh finds, and without a Developer ID certificate plus notarization, macOS
# quarantines anything downloaded from the internet: the app is refused on arrival and
# Sparkle's updates are refused the same way. The hole is marked below. Everything
# else -- versioning, signatures, feed, upload -- is real.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true

if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh <version> [--dry-run]     e.g. ./release.sh 0.2.0"
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version must look like 1.2.3"; exit 1
fi
if [ -n "$(git status --porcelain)" ] && [ "$DRY_RUN" = false ]; then
    echo "working tree is not clean; commit or stash first"; exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "tag v$VERSION already exists"; exit 1
fi

PLIST=Resources/Info.plist
RELEASES=build/releases
REPO=cap10morgan/gangway
SPARKLE_BIN=$(find .build -type d -path "*artifacts/sparkle/Sparkle/bin" | head -1)
[ -z "$SPARKLE_BIN" ] && { echo "Sparkle tools missing; run: swift build"; exit 1; }

# Two numbers, two jobs. CFBundleShortVersionString is what people read;
# CFBundleVersion is what Sparkle compares, so it only ever increments.
OLD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
OLD_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
BUILD_NUMBER=$(( OLD_BUILD + 1 ))
echo "==> Version $VERSION (build $BUILD_NUMBER)"
# Put back the two fields this script changes, and only those. Restoring the whole
# file from git would also discard any uncommitted edit to it -- which is exactly
# what the first dry run did to the Sparkle keys. Armed until the release commit, so
# a failed build does not leave the bump behind either.
restore_version() {
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OLD_VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $OLD_BUILD" "$PLIST"
}
trap restore_version EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

CONFIG=release ./build-app.sh

# ---------------------------------------------------------------------------
# TODO: notarization. Once a Developer ID Application certificate exists:
#   xcrun notarytool submit "$ZIP" --keychain-profile gangway --wait
#   xcrun stapler staple build/Gangway.app
#   (then re-zip, because stapling changes the app after it was zipped)
# Until then the zip below installs only on Macs willing to bypass Gatekeeper.
# ---------------------------------------------------------------------------

# One archive, freshly emptied. generate_appcast signs every archive in the directory
# and writes one <item> per archive, all sharing a single download prefix -- and each
# GitHub release has its own URL, so a directory holding several versions would be
# given the wrong URLs for all but one. Sparkle only needs the newest version to offer
# an update, so the feed carries exactly that.
rm -rf "$RELEASES"
mkdir -p "$RELEASES"
ZIP="$RELEASES/Gangway-$VERSION.zip"
# ditto, not zip: a .app is a tree with symlinks and extended attributes, and zip(1)
# flattens both, producing an archive that unpacks into a broken signature.
ditto -c -k --sequesterRsrc --keepParent build/Gangway.app "$ZIP"
echo "==> Archived $(du -h "$ZIP" | cut -f1) to $ZIP"

echo "==> Signing the update and writing appcast.xml"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    -o appcast.xml "$RELEASES"

if [ "$DRY_RUN" = true ]; then
    echo
    echo "Dry run: nothing committed, tagged, pushed or published."
    echo "Built    $ZIP"
    echo "Feed     appcast.xml"
    exit 0
fi

echo "==> Committing, tagging and publishing"
git add "$PLIST" appcast.xml
git commit -m "Release v$VERSION"
trap - EXIT
git tag "v$VERSION"
git push origin HEAD "v$VERSION"

gh release create "v$VERSION" "$ZIP" \
    --repo "$REPO" \
    --title "Gangway $VERSION" \
    --generate-notes

echo
echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
echo "Sparkle reads the feed from main, which now has this version."
