#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Portlight.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.4" Sources/*.swift ../shared/AAC.swift -framework AppKit -framework Network -framework AVFoundation -framework CryptoKit -framework Security -o "$APP/Contents/MacOS/su-remote-viewer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for asset in Portlight.png Portlight.icns; do
  cp "../branding/$asset" "$APP/Contents/Resources/$asset"
done
cp README.md ../LICENSE ../THIRD-PARTY.md "$APP/Contents/Resources/"
cp -R ../licenses "$APP/Contents/Resources/"
if [ -x ../integrations/zerotier/build/su-zerotier ]; then
  cp ../integrations/zerotier/build/su-zerotier "$APP/Contents/MacOS/su-zerotier"
fi
codesign --force --deep --sign "${SU_REMOTE_SIGN_IDENTITY:--}" "$APP" >/dev/null
touch "$APP"
"$APP/Contents/MacOS/su-remote-viewer" --self-test
printf '%s\n' "$APP"
