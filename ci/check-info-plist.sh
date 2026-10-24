#!/usr/bin/env bash
# Fails when the built app's Info.plist lacks keys the app relies on at run time.
# UIBackgroundModes=audio: meeting mode records while the phone is locked (an INFOPLIST_KEY_ build
# setting for it was silently ignored once).
set -euo pipefail

plist=$(find ~/Library/Developer/Xcode/DerivedData -path "*Build/Products/*/PocketAgent.app/Info.plist" | head -1)
if [ -z "$plist" ]; then
  echo "::error::PocketAgent.app/Info.plist not found"
  exit 1
fi
echo "Checking $plist"
if ! plutil -extract UIBackgroundModes json -o - "$plist" | grep -q '"audio"'; then
  echo "::error::UIBackgroundModes does not contain audio (locked-phone recording would stop)"
  exit 1
fi
echo "UIBackgroundModes contains audio"
