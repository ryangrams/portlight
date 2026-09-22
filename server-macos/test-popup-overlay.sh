#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Portlight Overlay Test.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 Sources/Display.swift Sources/PopupMessage.swift tests/overlay/main.swift -framework AppKit -framework ScreenCaptureKit -o "$APP/Contents/MacOS/popup-overlay-test"
cp tests/overlay/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/popup-overlay-test" "$PWD/build/popup-overlay-report.json"
