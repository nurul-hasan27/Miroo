#!/bin/zsh
# Regression checks that run on one Mac with no phone: unit tests + the full real stack (encoder, FEC, pacing, UDP,
# decoder) against emulated bad Wi-Fi. Exits non-zero if a scenario regresses past its floor.
set -u
cd "$(dirname "$0")/.."
unit() { # label, filter
  local out; out=$(nice -n 10 swift test --jobs 2 --filter "$2" 2>&1); local rc=$?
  local n; n=$(echo "$out" | grep -E "^Test Case .* passed" | wc -l | tr -d ' ')
  printf "%-62s %s passed  %s\n" "$1" "$n" "$([ $rc -eq 0 ] && echo PASS || echo FAIL)"
  [ $rc -eq 0 ] || { echo "$out" | grep -E "error:" | head -5; fail=1; }
}
fail=0
unit "unit tests: wire format, FEC, assembler, sequencer, input" "MirooCoreTests"
unit "unit tests: pairing, AEAD packet + control encryption" "MirooNetTests"
unit "media loopback: real VideoToolbox encode/decode + loss injection" "MirooMediaTests"
echo "== building the self-test tool =="
nice -n 10 swift build -c release --jobs 2 --product miroo-selftest 2>&1 | grep -E "error:" && exit 1
BIN=.build/release/miroo-selftest
# name | selftest flags | minimum % of frames shown | maximum freeze (ms)
run() {
  local name=$1 flags=$2 minShown=$3 maxFreeze=$4
  local out; out=$($BIN --seconds 14 --busy --encrypt ${=flags} 2>&1)
  local shown; shown=$(echo "$out" | sed -n 's/.*(\([0-9]*\)%).*/\1/p' | tail -1)
  local freeze; freeze=$(echo "$out" | sed -n 's/FREEZE maxGap=\([0-9]*\)ms.*/\1/p' | tail -1)
  local verdict=PASS
  if [ "${shown:-0}" -lt "$minShown" ] || [ "${freeze:-9999}" -gt "$maxFreeze" ]; then verdict=FAIL; fail=1; fi
  printf "%-34s shown %3s%% (min %s%%)  worst freeze %4sms (max %sms)  %s\n" "$name" "${shown:-?}" "$minShown" "${freeze:-?}" "$maxFreeze" "$verdict"
}
echo "== emulated Wi-Fi (encrypted, 1792x828 busy content) =="
run "clean link"                       ""                                                       92 300
run "3% random loss + jitter"          "--loss 3 --delay 8 --jitter 3"                          88 350
run "60 ms outage every 1.5 s"         "--delay 5 --stall 60 --stallevery 1500"                 80 500
run "bursty loss"                      "--burst 1.5 --delay 5"                                  70 600
run "120 ms blackout every second"     "--delay 5 --stall 120 --stallevery 1000"                65 700
exit $fail
