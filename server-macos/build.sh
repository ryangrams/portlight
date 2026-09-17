#!/bin/bash
set -euo pipefail
SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SU_REMOTE_BUILD_DIR:-$SERVER_DIR/build}"
APP="$BUILD_DIR/Portlight Host.app"
if [[ "${1:-}" == "--release" && "${SU_REMOTE_SIGN_IDENTITY:-}" != "Developer ID Application:"* ]]; then
  printf '%s\n' 'Release builds require SU_REMOTE_SIGN_IDENTITY="Developer ID Application: …". Ad-hoc signatures cannot preserve privacy identity across updates.' >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 \
  -framework AppKit -framework ScreenCaptureKit -framework Network -framework Security \
  -framework Accelerate -framework CoreMedia -framework CoreVideo -framework ImageIO -framework AVFoundation -framework ServiceManagement \
  "$SERVER_DIR"/Sources/*.swift "$SERVER_DIR/../shared/AAC.swift" -o "$APP/Contents/MacOS/SURemoteServer"
cp "$SERVER_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$SERVER_DIR/../branding/Portlight.icns" "$APP/Contents/Resources/Portlight.icns"
cp "$SERVER_DIR/README.md" "$APP/Contents/Resources/README.md"
if [[ -f "$SERVER_DIR/../LICENSE" ]]; then cp "$SERVER_DIR/../LICENSE" "$APP/Contents/Resources/LICENSE"; fi
if [[ "${1:-}" == "--release" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SU_REMOTE_SIGN_IDENTITY" "$APP"
else
  /usr/bin/codesign --force --sign "${SU_REMOTE_SIGN_IDENTITY:--}" "$APP"
fi
/usr/bin/codesign --verify --strict "$APP"
touch "$APP"
if [[ "${1:-}" == "--test" ]]; then "$APP/Contents/MacOS/SURemoteServer" --self-test; fi
printf 'Built %s\n' "$APP"
