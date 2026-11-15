#!/usr/bin/env bash
# Builds a release binary and wraps it in "build/Blobshelf.app", ad-hoc signed with the
# hardened runtime and the App Sandbox entitlements in Support/. Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-0.1.0}"
swift build -c release --product Blobshelf
bin="$(swift build -c release --show-bin-path)/Blobshelf"

app="build/Blobshelf.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Blobshelf"

icons="$(mktemp -d)"
trap 'rm -rf "$icons"' EXIT
swift scripts/make-icon.swift "$icons/AppIcon.iconset"
iconutil -c icns "$icons/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.ilterkavlak.blobshelf</string>
  <key>CFBundleName</key><string>Blobshelf</string>
  <key>CFBundleDisplayName</key><string>Blobshelf</string>
  <key>CFBundleExecutable</key><string>Blobshelf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSFileQuarantineEnabled</key><true/>
</dict>
</plist>
PLIST
codesign --force --options runtime --entitlements Support/Blobshelf.entitlements --sign - "$app"
echo "Built $app"
