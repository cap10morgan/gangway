#!/bin/bash
# Assembles Station.app from the SwiftPM build and signs it.
#
# Signing identity, in order of preference:
#   1. $STATION_SIGN_IDENTITY, if set
#   2. a "Developer ID Application" certificate (required for distribution)
#   3. ad-hoc, which runs locally but cannot be notarized or distributed
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
else
    IDENTITY="-"
    echo "!!  No Developer ID Application certificate found."
    echo "!!  Signing ad-hoc: this app will run on THIS Mac only."
    echo "!!  Distribution requires the paid Apple Developer Program."
fi

echo "==> Signing as: $IDENTITY"
codesign --force --deep --options runtime \
         --entitlements Resources/Station.entitlements \
         --sign "$IDENTITY" "$APP"

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built $APP"
echo
if [ "$IDENTITY" = "-" ]; then
    echo "Ad-hoc signed. Note that macOS ties Accessibility and Input Monitoring grants"
    echo "to the code signature, so re-signing or rebuilding may require re-granting"
    echo "permission in System Settings."
else
    echo "To notarize:"
    echo "  ditto -c -k --keepParent $APP build/Station.zip"
    echo "  xcrun notarytool submit build/Station.zip --keychain-profile <profile> --wait"
    echo "  xcrun stapler staple $APP"
fi
