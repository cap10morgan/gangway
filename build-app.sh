#!/bin/bash
# Assembles Station.app from the SwiftPM build and signs it.
#
# Signing identity, in order of preference:
#   1. $STATION_SIGN_IDENTITY, if set
#   2. Developer ID Application  - required for distribution
#   3. Apple Development         - not distributable, but STABLE
#   4. ad-hoc                    - last resort
#
# Preferring any real certificate over ad-hoc matters for day-to-day work, because TCC
# keys permissions on the code signature's designated requirement:
#
#   ad-hoc              designated => cdhash H"aec77d..."
#   real certificate    designated => identifier "com.station.Station" and
#                                     anchor apple generic and certificate leaf[...]
#
# The ad-hoc requirement is the hash of the binary, so every rebuild looks like a
# different app and Accessibility and Input Monitoring must be granted again. A
# certificate-based requirement does not depend on the binary contents, so grants
# survive rebuilds and you approve Station once.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="build/Station.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product StationApp

BIN=$(swift build -c "$CONFIG" --product StationApp --show-bin-path)/StationApp

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StationApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -n "${STATION_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$STATION_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Station Development"; then
    IDENTITY="Station Development"
    echo "==> Using the local self-signed \"Station Development\" certificate."
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
fi

echo "==> Signing as: $IDENTITY"
codesign --force --deep --options runtime \
         --entitlements Resources/Station.entitlements \
         --sign "$IDENTITY" "$APP"

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built $APP"
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
    echo "across rebuilds. If Station stops being recognised, run ./reset-permissions.sh"
    echo "and grant again."
else
    echo "To notarize:"
    echo "  ditto -c -k --keepParent $APP build/Station.zip"
    echo "  xcrun notarytool submit build/Station.zip --keychain-profile <profile> --wait"
    echo "  xcrun stapler staple $APP"
fi
