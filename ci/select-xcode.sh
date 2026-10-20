#!/usr/bin/env bash
# Select the newest Xcode 27.x on the runner (deployment target iOS 27; Foundation Models LanguageModel API).
set -euo pipefail

ls -d /Applications/Xcode*.app || true
XCODE=$(ls -d /Applications/Xcode_27*.app 2>/dev/null | sort -V | tail -n 1 || true)
if [[ -z "${XCODE}" ]]; then
  echo "::error::No Xcode 27.x found on this runner image"
  exit 1
fi
sudo xcode-select -s "${XCODE}/Contents/Developer"
xcodebuild -version
swift --version
xcrun simctl list runtimes || true
