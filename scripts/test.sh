#!/bin/bash
# Runs unit tests. With only Command Line Tools installed, Swift Testing lives
# outside SwiftPM's default search path, so we pass it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${MD_BUILD_DIR:-$HOME/.cache/marimodesktop-build}"
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [ -d "$F/Testing.framework" ]; then
  exec swift test --scratch-path "$SCRATCH" -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
else
  exec swift test --scratch-path "$SCRATCH" "$@"
fi
