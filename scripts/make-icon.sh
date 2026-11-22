#!/bin/zsh
# Draws the app icon (Sources/Lapang/Icon.swift) and packs it into
# Support/AppIcon.icns with iconutil (part of the Command Line Tools).
# Run it after changing the drawing; bundle-app.sh copies the .icns.
set -euo pipefail
cd "${0:A:h}/.."

swift build --product Lapang ${=SWIFT_BUILD_FLAGS:-}
out=build/icon
rm -rf "$out"
mkdir -p "$out"
# A debug build only: it writes the PNGs, then quits.
.build/debug/Lapang --write-icon="$PWD/$out"
iconutil -c icns -o Support/AppIcon.icns "$out/AppIcon.iconset"
print "make-icon.sh: wrote Support/AppIcon.icns (PNGs in $out/AppIcon.iconset)"
