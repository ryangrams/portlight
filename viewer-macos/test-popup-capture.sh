#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
sources=()
for source in Sources/*.swift; do
  if [[ "$source" != Sources/main.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc -swift-version 5 -O "${sources[@]}" ../shared/AAC.swift tests/capture/main.swift -framework AppKit -framework Network -framework AVFoundation -framework CryptoKit -framework Security -o build/popup-native-capture
build/popup-native-capture "$PWD/build/popup-native-dark.png" --ui-check
