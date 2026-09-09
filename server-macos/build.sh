#!/bin/bash
set -euo pipefail
SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SU_REMOTE_BUILD_DIR:-$SERVER_DIR/build}"
APP="$BUILD_DIR/Portlight Host.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 \
  -framework AppKit -framework ScreenCaptureKit -framework Network -framework Security \
  -framework Accelerate -framework CoreMedia -framework CoreVideo -framework ImageIO -framework AVFoundation -framework ServiceManagement \
  "$SERVER_DIR"/Sources/*.swift -o "$APP/Contents/MacOS/SURemoteServer"
cp "$SERVER_DIR/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$SERVER_DIR/../branding/Portlight.icns" ]]; then cp "$SERVER_DIR/../branding/Portlight.icns" "$APP/Contents/Resources/Portlight.icns"; fi
cp "$SERVER_DIR/README.md" "$APP/Contents/Resources/README.md"
if [[ -f "$SERVER_DIR/../LICENSE" ]]; then cp "$SERVER_DIR/../LICENSE" "$APP/Contents/Resources/LICENSE"; fi
/usr/bin/codesign --force --sign "${SU_REMOTE_SIGN_IDENTITY:--}" "$APP"
/usr/bin/codesign --verify --strict "$APP"
if [[ "${1:-}" == "--test" ]]; then "$APP/Contents/MacOS/SURemoteServer" --self-test; fi
printf 'Built %s\n' "$APP"
