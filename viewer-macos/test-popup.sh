#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -swift-version 5 Sources/PopupComposer.swift Sources/PopupSession.swift tests/PopupComposerTests.swift tests/main.swift -framework AppKit -o build/popup-composer-tests
build/popup-composer-tests "$@"
