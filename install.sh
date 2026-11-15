#!/usr/bin/env bash
# Builds Blobshelf from this checkout and installs it into Applications.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "Blobshelf needs Apple's Command Line Tools. Install them with:"
  echo "  xcode-select --install"
  echo "then run ./install.sh again."
  exit 1
fi

scripts/build-app.sh

target=/Applications
[ -w "$target" ] || target="$HOME/Applications"
mkdir -p "$target"
pkill -x Blobshelf 2>/dev/null || true
rm -rf "$target/Blobshelf.app"
cp -R "build/Blobshelf.app" "$target/"
echo "Installed to $target/Blobshelf.app"
open "$target/Blobshelf.app"
