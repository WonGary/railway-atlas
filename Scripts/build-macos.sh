#!/bin/bash
set -euo pipefail
ATLAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ATLAS_ROOT"
strip_bundle_metadata() {
    local bundle="$1"
    xattr -dr com.apple.provenance "$bundle" 2>/dev/null || true
    xattr -dr com.apple.macl "$bundle" 2>/dev/null || true
    xattr -dr com.apple.ResourceFork "$bundle" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
}
ATLAS_CONFIGURATION="${1:-release}"
if [[ "$ATLAS_CONFIGURATION" != "release" && "$ATLAS_CONFIGURATION" != "debug" ]]; then
    printf 'Usage: bash Scripts/build-macos.sh [release|debug]\n' >&2
    exit 1
fi
ATLAS_SCRATCH_PATH="${ATLAS_SCRATCH_PATH:-$ATLAS_ROOT/.build}"
# A local source mirror avoids FileProvider stalls in cloud-backed projects.
# Packaging still uses this checkout's version, icon and bundled resources.
ATLAS_PACKAGE_PATH="${ATLAS_PACKAGE_PATH:-$ATLAS_ROOT}"
ATLAS_CACHE_PATH="$ATLAS_SCRATCH_PATH/compiler-cache"
mkdir -p "$ATLAS_CACHE_PATH/clang" "$ATLAS_CACHE_PATH/swift"
export CLANG_MODULE_CACHE_PATH="$ATLAS_CACHE_PATH/clang"
export SWIFT_MODULECACHE_PATH="$ATLAS_CACHE_PATH/swift"
swift build -c "$ATLAS_CONFIGURATION" --package-path "$ATLAS_PACKAGE_PATH" --scratch-path "$ATLAS_SCRATCH_PATH" --product RailwayAtlas
ATLAS_BIN="$(swift build -c "$ATLAS_CONFIGURATION" --package-path "$ATLAS_PACKAGE_PATH" --scratch-path "$ATLAS_SCRATCH_PATH" --show-bin-path)"
mkdir -p .build/icon-tools dist
swiftc Sources/RailwayAtlas/Design/RailwayAtlasMark.swift Scripts/RenderIcon.swift -o .build/icon-tools/render-icon
.build/icon-tools/render-icon "$ATLAS_ROOT"
iconutil -c icns Design/RailwayAtlas.iconset -o Design/RailwayAtlas.icns
# Cloud-synced project folders reattach Finder/FileProvider metadata to app
# bundles after signing. Keep the executable bundle on the local Applications
# volume and preserve the project's familiar launch path with a symlink.
ATLAS_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/railway-atlas-build.XXXXXX")"
ATLAS_APP="$ATLAS_STAGE/Railway Atlas.app"
ATLAS_INSTALLED="$HOME/Applications/Railway Atlas.app"
mkdir -p "$HOME/Applications"
# Never replace an unrelated application or a user-managed link.
if [[ -L "$ATLAS_INSTALLED" ]]; then
    printf 'Install target is a symbolic link; leaving it unchanged: %s\n' "$ATLAS_INSTALLED" >&2
    exit 1
fi
if [[ -L "$ATLAS_ROOT/dist/Railway Atlas.app"
      && "$(readlink "$ATLAS_ROOT/dist/Railway Atlas.app")" != "$ATLAS_INSTALLED" ]]; then
    printf 'Project launch link points elsewhere; leaving it unchanged.\n' >&2
    exit 1
fi
for ATLAS_EXISTING in "$ATLAS_INSTALLED" "$ATLAS_ROOT/dist/Railway Atlas.app"; do
    if [[ -e "$ATLAS_EXISTING" && ! -L "$ATLAS_EXISTING" ]]; then
        ATLAS_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ATLAS_EXISTING/Contents/Info.plist")
        if [[ "$ATLAS_IDENTIFIER" != "app.railwayatlas.mac" ]]; then
            printf 'Not a Railway Atlas installation; leaving unchanged: %s\n' "$ATLAS_EXISTING" >&2
            exit 1
        fi
    fi
done
mkdir -p "$ATLAS_APP/Contents/MacOS" "$ATLAS_APP/Contents/Resources"
cp "$ATLAS_BIN/RailwayAtlas" "$ATLAS_APP/Contents/MacOS/RailwayAtlas"
cp Config/Info.plist "$ATLAS_APP/Contents/Info.plist"
cp Design/RailwayAtlas.icns "$ATLAS_APP/Contents/Resources/RailwayAtlas.icns"
# App bundles read their resources directly, independent of the source checkout.
ditto --norsrc --noextattr Sources/RailwayAtlas/Resources "$ATLAS_APP/Contents/Resources/Resources"
cp Sources/RailwayCore/Resources/mainland-osm-mask.json "$ATLAS_APP/Contents/Resources/Resources/"
cp Sources/RailwayCore/Resources/metro-palette.json Sources/RailwayCore/Resources/METRO-PALETTE-LICENCE.txt "$ATLAS_APP/Contents/Resources/Resources/"
cp Sources/RailwayCore/Resources/metro-snapshot-*.json "$ATLAS_APP/Contents/Resources/Resources/"
cp Sources/RailwayCore/Resources/china-metro-overview.json Sources/RailwayCore/Resources/NATIONAL-METRO-LICENCE.txt "$ATLAS_APP/Contents/Resources/Resources/"
cp Sources/RailwayCore/Resources/railway-experience-*.json "$ATLAS_APP/Contents/Resources/Resources/"
cp Config/default-config.json "$ATLAS_APP/Contents/Resources/Resources/"
strip_bundle_metadata "$ATLAS_APP"
codesign --force --sign - "$ATLAS_APP"
codesign --verify --deep --strict "$ATLAS_APP"
if [[ -e "$ATLAS_INSTALLED" ]]; then
    ATLAS_BACKUP="$(mktemp -d "$HOME/Applications/.railway-atlas-previous.XXXXXX")"
    mv "$ATLAS_INSTALLED" "$ATLAS_BACKUP/"
fi
mv "$ATLAS_APP" "$ATLAS_INSTALLED"
if [[ -L "dist/Railway Atlas.app" ]]; then
    unlink "dist/Railway Atlas.app"
elif [[ -e "dist/Railway Atlas.app" ]]; then
    ATLAS_BACKUP="$(mktemp -d "$ATLAS_ROOT/dist/.previous.XXXXXX")"
    mv "dist/Railway Atlas.app" "$ATLAS_BACKUP/"
fi
ln -s "$ATLAS_INSTALLED" "dist/Railway Atlas.app"
codesign --verify --deep --strict "$ATLAS_INSTALLED"
rmdir "$ATLAS_STAGE"
printf 'Installed: %s\nLaunch link: %s/dist/Railway Atlas.app\n' "$ATLAS_INSTALLED" "$ATLAS_ROOT"
