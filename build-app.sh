#!/bin/bash
# Assembles Gangway.app from the SwiftPM build and signs it.
#
# Signing identity, in order of preference:
#   1. $GANGWAY_SIGN_IDENTITY, if set
#   2. Developer ID Application  - required for distribution
#   3. Apple Development         - not distributable, but STABLE
#   4. ad-hoc                    - last resort
#
# Preferring any real certificate over ad-hoc matters for day-to-day work, because TCC
# keys permissions on the code signature's designated requirement:
#
#   ad-hoc              designated => cdhash H"aec77d..."
#   real certificate    designated => identifier "com.timetraveltoaster.Gangway" and
#                                     anchor apple generic and certificate leaf[...]
#
# The ad-hoc requirement is the hash of the binary, so every rebuild looks like a
# different app and Accessibility and Input Monitoring must be granted again. A
# certificate-based requirement does not depend on the binary contents, so grants
# survive rebuilds and you approve Gangway once.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="build/Gangway.app"
INSTALL=false
[ "${1:-}" = "--install" ] && INSTALL=true

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product GangwayApp

BIN=$(swift build -c "$CONFIG" --product GangwayApp --show-bin-path)/GangwayApp

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GangwayApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -n "${GANGWAY_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$GANGWAY_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Gangway Development"; then
    IDENTITY="Gangway Development"
    echo "==> Using the local self-signed \"Gangway Development\" certificate."
    echo "    Stable, so permissions survive rebuilds. Not for distribution."
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
    echo "==> No Developer ID certificate; using Apple Development."
    echo "    Fine for local use, and stable, so permissions survive rebuilds."
    echo "    Distribution still requires a Developer ID (paid Apple Developer Program)."
else
    IDENTITY="-"
    echo "!!  No signing certificate found; signing ad-hoc."
    echo "!!  Every rebuild will look like a new app to macOS, so Accessibility and"
    echo "!!  Input Monitoring must be granted again each time."
    echo "!!"
    echo "!!  Fix this once with:  ./make-signing-cert.sh"
    echo "!!  It creates a stable self-signed identity so permissions persist."
    echo "!!"
    echo "!!  If you DO have a certificate, the keychain search list may be broken,"
    echo "!!  which looks identical to having none. Check with:"
    echo "!!      security list-keychains -d user"
    echo "!!  It should list login.keychain-db. Restore it with:"
    echo "!!      security list-keychains -d user -s ~/Library/Keychains/login.keychain-db"
fi

echo "==> Signing as: $IDENTITY"
codesign --force --deep --options runtime \
         --entitlements Resources/Gangway.entitlements \
         --sign "$IDENTITY" "$APP"

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built $APP"
if [ "$INSTALL" = true ]; then
    echo "==> Installing to /Applications"
    # Start at login registers the bundle at its current path, so an app left in a
    # build directory produces a login item that breaks on the next clean.
    pkill -x GangwayApp 2>/dev/null || true
    rm -rf /Applications/Gangway.app
    cp -R "$APP" /Applications/Gangway.app
    APP="/Applications/Gangway.app"
    echo "    installed at $APP"
fi

echo
echo "IMPORTANT: launch it with  open $APP"
echo "Running the binary directly from a terminal makes it inherit the terminal's"
echo "TCC grants, so it will believe it already has permission, never register with"
echo "the system, and never appear in System Settings."
echo
if [ "$IDENTITY" = "-" ]; then
    echo "Ad-hoc signed: permissions will need re-granting after every rebuild."
    echo "Run ./reset-permissions.sh first to clear stale entries."
elif [ "${IDENTITY#Apple Development}" != "$IDENTITY" ]; then
    echo "Signed with a stable identity, so permissions granted once should persist"
    echo "across rebuilds. If Gangway stops being recognised, run ./reset-permissions.sh"
    echo "and grant again."
else
    echo "To notarize:"
    echo "  ditto -c -k --keepParent $APP build/Gangway.zip"
    echo "  xcrun notarytool submit build/Gangway.zip --keychain-profile <profile> --wait"
    echo "  xcrun stapler staple $APP"
fi
