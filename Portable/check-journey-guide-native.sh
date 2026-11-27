#!/bin/sh
# Run with sh Portable/check-journey-guide-native.sh from a macOS checkout.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
ride_qa=$(mktemp -d "$PWD/.build/journey-guide-QA.XXXXXX")
swift run --scratch-path .build/ride-guide RailwayAtlas --ui-smoke "$ride_qa" --journey-guide-check
if ! test -s "$ride_qa/journey-guide.txt"; then
    if test -f "$ride_qa/ui-smoke.txt"; then cat "$ride_qa/ui-smoke.txt" >&2; fi
    exit 1
fi
cat "$ride_qa/journey-guide.txt"
rg -qx PASS "$ride_qa/journey-guide.txt"
printf '%s\n' "$ride_qa/journey-guide.txt"
