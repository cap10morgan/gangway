#!/bin/bash
# Decisive test: does CONSUMING gesture events damage the captured stream?
# Captures the same gestures twice - once listen-only, once consuming - then
# replays both and compares what actually gets delivered.
cd "$(dirname "$0")/Spikes/GestureSpike" || exit 1
D=/tmp/claude-501/-Users-wmorgan-dev-station
swift build 2>/dev/null | grep -E "error"

echo
echo "############ PASS 1 of 2: LISTEN-ONLY (nothing swallowed) ############"
echo " Screen WILL react. Do these for 12s:"
echo "   pinch in/out, rotate two fingers, three-finger swipe left/right"
echo "#####################################################################"
sleep 3
STATION_CAPTURE=$D/pass-listen.bin ./.build/debug/GestureSpike record 12 | tail -3

echo
echo "############ PASS 2 of 2: CONSUMING (gestures swallowed) #############"
echo " Screen should NOT react. Do THE SAME gestures for 12s:"
echo "   pinch in/out, rotate two fingers, three-finger swipe left/right"
echo "#####################################################################"
sleep 3
STATION_CAPTURE=$D/pass-consume.bin ./.build/debug/GestureSpike primary 12 | tail -4

echo
echo "################## COMPARING THE TWO CAPTURES ######################"
for mode in listen consume; do
  echo
  echo "--- $mode: composition ---"
  STATION_CAPTURE=$D/pass-$mode.bin ./.build/debug/GestureSpike analyze 2>/dev/null \
    | grep -vE "unrecognized type|^SAMPLE|^ +round-trip" \
    | grep -E "events by type|byte-identical|rehydrate" | head -6
  echo "--- $mode: does it replay? ---"
  STATION_CAPTURE=$D/pass-$mode.bin ./.build/debug/GestureProof 29,30 2>/dev/null \
    | grep -E "RECEIVER SAW|DELIVERED"
done
