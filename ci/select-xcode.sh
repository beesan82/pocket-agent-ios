#!/usr/bin/env bash
# Select Xcode 27 (deployment target iOS 27; Foundation Models LanguageModel API).
# Pinned to a release build: the xcode-27 image also carries 27.x RC / beta, and
# "newest" would pick a beta (27.2 beta 2 on image 20261012).
set -euo pipefail

XCODE_PIN="${XCODE_PIN:-27.0}"
ls -d /Applications/Xcode*.app || true
XCODE="/Applications/Xcode_${XCODE_PIN}.app"
if [[ ! -d "${XCODE}" ]]; then
  echo "::error::${XCODE} not found on this runner image (needs runs-on: xcode-27)"
  exit 1
fi
sudo xcode-select -s "${XCODE}/Contents/Developer"
xcodebuild -version
swift --version
xcrun simctl list runtimes || true
