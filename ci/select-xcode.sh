#!/usr/bin/env bash
# Select the newest Xcode 26.x on the runner (AgentRunKit 6.1.0 requires Xcode 26+).
set -euo pipefail

ls -d /Applications/Xcode*.app || true
XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -n 1 || true)
if [[ -z "${XCODE}" ]]; then
  echo "::error::No Xcode 26.x found on this runner image"
  exit 1
fi
sudo xcode-select -s "${XCODE}/Contents/Developer"
xcodebuild -version
swift --version
