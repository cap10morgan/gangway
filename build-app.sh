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

# Sparkle ships as a framework that has to live inside the bundle. SwiftPM links
# against it where it built it, which is a path that will not exist on anyone else's
# Mac, so copy it in and teach the executable to look beside itself.
SPARKLE_SRC=$(find .build -type d -name "Sparkle.framework" -path "*Products*" | head -1)
if [ -z "$SPARKLE_SRC" ]; then
    echo "!!  Sparkle.framework not found under .build; run: swift build -c $CONFIG"
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
# ditto rather than cp -R: a framework is a tree of symlinks, and copying it with the
# links resolved produces a bundle that is valid until you try to sign it.
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
                  "$APP/Contents/MacOS/GangwayApp" 2>/dev/null || true

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

# A secure timestamp needs Apple's timestamp server and a real certificate; a
# self-signed one cannot use it, and asking anyway fails the whole signature.
case "$IDENTITY" in
    "Developer ID Application"*) TS=(--timestamp) ;;
    *)                           TS=(--timestamp=none) ;;
esac

# Inside out, and without --deep. --deep re-signs nested code with the *outer*
# entitlements, which is wrong for Sparkle's helpers: the installer and downloader
# are separate programs with their own requirements, and Apple has deprecated it for
# exactly this reason. Order matters -- a container cannot be sealed before what it
# contains.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for nested in "$SPARKLE/Versions/B/XPCServices/"*.xpc \
              "$SPARKLE/Versions/B/Updater.app" \
              "$SPARKLE/Versions/B/Autoupdate"; do
    [ -e "$nested" ] || continue
    codesign --force --options runtime "${TS[@]}" --sign "$IDENTITY" "$nested"
done
codesign --force --options runtime "${TS[@]}" --sign "$IDENTITY" "$SPARKLE"

codesign --force --options runtime "${TS[@]}" \
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
