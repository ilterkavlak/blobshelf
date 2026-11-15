#!/usr/bin/env bash
# Removes Blobshelf and everything it keeps on this Mac: the app, its settings and backup records,
# and the bucket tokens in the Keychain. Nothing in your buckets or backed-up folders is touched.
set -euo pipefail

bundle_id=io.github.ilterkavlak.blobshelf

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as yourself, not with sudo: the app's data lives in your own Library."
  exit 1
fi

echo "This removes Blobshelf, its settings and backup records, and the bucket tokens it saved in"
echo "your Keychain. Files in your buckets and on your Mac are not touched."
echo
echo "If you turned on Open at login, turn it off in Blobshelf's Settings before continuing."
read -r -p "Uninstall Blobshelf? [y/N] " answer
case "$answer" in
  [yY]*) ;;
  *) echo "Nothing was removed."; exit 0 ;;
esac

# The app must be gone before its container is deleted, or it may write to it again.
pkill -x -u "$(id -u)" Blobshelf 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x -u "$(id -u)" Blobshelf >/dev/null || break
  sleep 0.5
done
if pgrep -x -u "$(id -u)" Blobshelf >/dev/null; then
  echo "Blobshelf is still running. Quit it from its menu bar icon (gear → Quit) and run this again."
  exit 1
fi

failed=0
paths=(
  "/Applications/Blobshelf.app"
  "$HOME/Applications/Blobshelf.app"
  "$HOME/Library/Containers/$bundle_id"           # settings, backup records, preview cache
  "$HOME/Library/Application Scripts/$bundle_id"  # created by macOS for every sandboxed app
  "$HOME/Library/Application Support/Blobshelf"   # only from unsandboxed `swift run`
  "$HOME/Library/Caches/Blobshelf"                # only from unsandboxed `swift run`
)
for path in "${paths[@]}"; do
  [ -e "$path" ] || continue
  if rm -rf "$path"; then
    echo "Removed $path"
  else
    echo "Could not remove $path. Delete it in Finder, or allow Terminal to access data from other apps."
    failed=1
  fi
done
defaults delete Blobshelf >/dev/null 2>&1 || true  # only from unsandboxed `swift run`

# Each call deletes one saved token; there is one per bucket. Exit status 44 means none are left.
tokens=0
while :; do
  status=0
  security delete-generic-password -s "$bundle_id" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || break
  tokens=$((tokens + 1))
done
echo "Removed $tokens bucket token(s) from the Keychain."
if [ "$status" -ne 44 ]; then
  echo "Could not remove the remaining bucket tokens. Delete the items named $bundle_id in Keychain Access."
  failed=1
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "Blobshelf is partly uninstalled; see the messages above."
  exit 1
fi
echo "Blobshelf is uninstalled. If it still appears in System Settings → General → Login Items,"
echo "remove it there. You can delete this source folder too."
