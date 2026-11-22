#!/bin/zsh
# Builds build/Lapang.app from the Swift package with the Command Line Tools
# only (no Xcode), and signs it ad hoc with the Hardened Runtime on.
#
#   scripts/bundle-app.sh              release build, then the bundle
#   scripts/bundle-app.sh --no-build   bundle what .build/release already holds
#
# No App Sandbox: Lapang reads and cleans $TMPDIR, /private/tmp, ~/.ccs and
# ~/Library/Caches, which a sandboxed app cannot reach.
#
# SWIFT_BUILD_FLAGS  extra flags for `swift build`, e.g. "-j 1".
set -euo pipefail

root=${0:A:h:h}
cd "$root"

build=1
for argument in "$@"; do
  case $argument in
    --no-build) build=0 ;;
    *) print -u2 "bundle-app.sh: unknown option $argument"; exit 2 ;;
  esac
done

if (( build )); then
  swift build -c release --product Lapang ${=SWIFT_BUILD_FLAGS:-}
fi

binary=.build/release/Lapang
[[ -x $binary ]] || { print -u2 "bundle-app.sh: $binary is missing; build first"; exit 1; }
[[ -f Support/AppIcon.icns ]] || { print -u2 "bundle-app.sh: Support/AppIcon.icns is missing; run scripts/make-icon.sh"; exit 1; }

app=build/Lapang.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Lapang"
cp Support/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime "$app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
print "bundle-app.sh: built and signed $root/$app (version $version)"
