#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift branding/render-icon.swift branding
iconutil -c icns branding/Portlight.iconset -o branding/Portlight.icns
