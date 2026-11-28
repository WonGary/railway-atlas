#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product RailwayAtlas --jobs 5
bin=$(swift build --show-bin-path)
run=$(mktemp -d "${TMPDIR:-/tmp}/railway-apple-panels.XXXXXX")
app="$run/PanelCheck.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Config/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.railway.panelscheck "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string PanelCheck "$app/Contents/Info.plist"
plutil -remove CFBundleURLTypes "$app/Contents/Info.plist"
for bundle in "$bin"/*.bundle; do ln -s "$bundle" "$app/Contents/Resources/"; done
swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -I "$bin/Modules" -I Sources/CSQLite Portable/ApplePanelsCheck.swift "$PWD/Checks/ConfigurationChecks.swift" \
  @"$bin/RailwayAtlas.product/Objects.LinkFileList" -lsqlite3 -o "$app/Contents/MacOS/PanelCheck"
echo "$run"
open -n -W "$app" --args --ui-smoke "$run" "$@" --config-template "$PWD/Config/default-config.json"
cat "$run/results.txt"
rg -qx PASS "$run/results.txt"
