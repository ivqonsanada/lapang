#!/bin/zsh
# Runs the tests. With Xcode installed this is plain `swift test`. With only the
# Command Line Tools, Swift Testing lives outside the default search paths, so
# the framework, its macro plugin and its runtime library are named here.
# Extra arguments pass through, e.g. `scripts/test.sh --filter Deleter`.
set -euo pipefail
cd "${0:A:h}/.."

developer=$(xcode-select -p)
if [[ $developer == */CommandLineTools ]]; then
  lib=$developer/Library/Developer
  exec swift test \
    -Xswiftc -F -Xswiftc "$lib/Frameworks" \
    -Xswiftc -plugin-path -Xswiftc "$developer/usr/lib/swift/host/plugins/testing" \
    -Xlinker -rpath -Xlinker "$lib/Frameworks" \
    -Xlinker -rpath -Xlinker "$lib/usr/lib" \
    "$@"
fi
exec swift test "$@"
