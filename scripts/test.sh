#!/usr/bin/env bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode), swift test cannot
# find the Swift Testing framework on its own, so its location is passed explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
if ! xcode-select -p | grep -q Xcode.app; then
  frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
  libs="$(xcode-select -p)/Library/Developer/usr/lib"
  flags=(-Xswiftc -F"$frameworks"
         -Xlinker -F"$frameworks"
         -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libs")
fi
exec swift test "${flags[@]}" "$@"
