#!/bin/bash
# Clears Gangway's TCC entries so the next launch re-requests them from scratch.
#
# Grants themselves cannot be scripted. tccutil only resets; there is no supported API
# to approve a permission on the user's behalf, and writing TCC.db directly requires
# disabling SIP and breaks across macOS updates. Approving in System Settings is
# unavoidable, by design.
#
# You should not need this often. Permissions only go stale when the code signature's
# designated requirement changes, which happens on every rebuild ONLY for ad-hoc signed
# builds. build-app.sh prefers a real certificate precisely to avoid that.
set -uo pipefail

BUNDLE_ID="${1:-com.timetraveltoaster.Gangway}"

echo "Resetting TCC entries for $BUNDLE_ID"
echo

# PostEvent gates CGEventPost and shows up as Accessibility in System Settings.
# ListenEvent is Input Monitoring. Accessibility is reset too because older builds
# requested it via the AX API. LocalNetwork covers Bonjour discovery.
for service in Accessibility PostEvent ListenEvent; do
    if output=$(tccutil reset "$service" "$BUNDLE_ID" 2>&1); then
        printf "  %-14s reset\n" "$service"
    else
        # No entry yet is normal on a first run, not a failure worth shouting about.
        printf "  %-14s %s\n" "$service" "$(echo "$output" | tail -1)"
    fi
done

# Local Network cannot reliably be reset per-bundle; macOS often refuses it even when an
# entry exists. Only mention it when discovery is actually misbehaving, since resetting
# it for every app is a blunt instrument.
if ! tccutil reset LocalNetwork "$BUNDLE_ID" >/dev/null 2>&1; then
    printf "  %-14s not resettable per-app on this macOS (usually harmless)\n" "LocalNetwork"
fi

echo
echo "Quit Gangway if it is running, then launch it with:"
echo "    open build/Gangway.app"
echo
echo "It will re-request both permissions on launch and reappear in"
echo "System Settings > Privacy & Security."
echo
echo "If peer discovery stops working, revoke Local Network for Gangway in"
echo "System Settings > Privacy & Security > Local Network and relaunch."
