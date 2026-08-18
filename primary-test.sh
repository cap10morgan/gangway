#!/bin/bash
# Interactive test: does a consuming tap suppress PHYSICAL gestures locally,
# and do three/four-finger swipes reach the tap at all?
cd "$(dirname "$0")/Spikes/GestureSpike" || exit 1
swift build 2>/dev/null | grep -E "error"
echo
echo "======================================================="
echo " Scroll + gesture events will be SWALLOWED for 12s."
echo " Keyboard and clicks keep working - you stay in control."
echo
echo " Try, and watch whether the screen reacts:"
echo "   * two-finger scroll   * pinch to zoom   * rotate"
echo "   * THREE-finger swipe left/right"
echo "   * FOUR-finger swipe up (Mission Control)"
echo "======================================================="
sleep 2
./.build/debug/GestureSpike primary 12
