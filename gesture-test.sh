#!/bin/bash
# Records 20s of trackpad gestures, then replays them to prove round-trip fidelity.
cd "$(dirname "$0")/Spikes/GestureSpike" || exit 1
swift build 2>/dev/null | grep -E "error" 
echo
echo "===================================================="
echo " RECORDING FOR 20 SECONDS - USE YOUR TRACKPAD NOW"
echo "   * pinch to zoom in/out"
echo "   * rotate with two fingers"
echo "   * two-finger scroll"
echo "   * three-finger swipe left/right"
echo "   * four-finger swipe up"
echo "===================================================="
sleep 1
./.build/debug/GestureSpike record 20
