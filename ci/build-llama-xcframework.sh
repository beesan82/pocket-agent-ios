#!/usr/bin/env bash
# Builds llama.xcframework (iOS device + simulator slices) from a pinned llama.cpp tag and places it
# at Vendor/llama.xcframework, where project.yml links it (ADR-051: PLaMo 3 Translate runtime).
# Idempotent: when the framework for this version is already there (e.g. restored from the CI or
# Codemagic cache), it exits without rebuilding.
set -euo pipefail

LLAMA_VERSION="b12224"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Vendor/llama.xcframework"
STAMP="$ROOT/Vendor/.llama-xcframework-version"
SCRATCH="$ROOT/.llama-build"

if [[ -d "$OUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$LLAMA_VERSION" ]]; then
  echo "llama.xcframework $LLAMA_VERSION already present"
  exit 0
fi

if ! command -v cmake >/dev/null 2>&1; then
  brew install cmake
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
git clone --depth 1 --branch "$LLAMA_VERSION" https://github.com/ggml-org/llama.cpp.git "$SCRATCH/llama.cpp"

# Upstream script; only the iOS device and simulator slices are needed.
(cd "$SCRATCH/llama.cpp" && ./build-xcframework.sh ios-device ios-sim)

mkdir -p "$ROOT/Vendor"
rm -rf "$OUT"
cp -R "$SCRATCH/llama.cpp/build-apple/llama.xcframework" "$OUT"
echo "$LLAMA_VERSION" > "$STAMP"

rm -rf "$SCRATCH"
echo "llama.xcframework $LLAMA_VERSION built at $OUT"
