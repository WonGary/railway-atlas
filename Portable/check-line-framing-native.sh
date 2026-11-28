#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
mkdir -p .build/framing-{tmp,cache,config,security}
export TMPDIR="$root/.build/framing-tmp/"
export CLANG_MODULE_CACHE_PATH="$root/.build/framing-cache/clang"
export SWIFT_MODULECACHE_PATH="$root/.build/framing-cache/swift"
swift build --disable-sandbox --cache-path "$root/.build/framing-cache" --config-path "$root/.build/framing-config" \
    --security-path "$root/.build/framing-security" --jobs 5 --product RailwayAtlas
run=$(mktemp -d "$root/.build/framing-run.XXXXXX")
app="$run/Line Framing.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources" "$run/receipt"
cp .build/debug/RailwayAtlas "$app/MacOS/"
cp Config/Info.plist "$app/"
plutil -replace CFBundleIdentifier -string app.railwayatlas.check.line-framing "$app/Info.plist"
plutil -remove CFBundleURLTypes "$app/Info.plist"
ln -s "$root/Web/data/metro" "$app/Resources/metro"
ln -s "$root/Web/data/metro-index.json" "$app/Resources/"
ln -s "$root/Web/station-directory" "$app/Resources/"
ln -s "$root/Sources/RailwayAtlas/Resources" "$app/Resources/Resources"
printf 'Receipt directory: %s\n' "$run/receipt"
"$app/MacOS/RailwayAtlas" -ApplePersistenceIgnoreState YES --ui-smoke "$run/receipt" --v020-panel-layout-check --line-framing-check
grep -qx PASS "$run/receipt/line-framing.txt"
cat "$run/receipt/line-framing.txt"
