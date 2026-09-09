#!/bin/bash
set -euo pipefail
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$BENCH_DIR")"
mkdir -p "$BENCH_DIR/build"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 -framework AppKit -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework ImageIO -framework AVFoundation \
 "$APP_DIR/server-macos/Sources/Display.swift" "$APP_DIR/server-macos/Sources/Capture.swift" "$BENCH_DIR/BaselineTileEncoder.swift" "$BENCH_DIR/EncoderValidation.swift" -o "$BENCH_DIR/build/encoder-validation"
"$BENCH_DIR/build/encoder-validation" "$BENCH_DIR/results"
