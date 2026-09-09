#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${SU_REMOTE_VERSION:-0.1.0-alpha.1}"
if [[ ! "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]]; then echo 'Invalid version.' >&2; exit 1; fi
OUT="$PWD/release/$VERSION"
mkdir -p "$OUT"
STAGING=$(mktemp -d /tmp/su-remote-package.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
MAC="$STAGING/SU Remote"
mkdir -p "$MAC"
ditto 'server-macos/build/SU Remote Server.app' "$MAC/SU Remote Server.app"
ditto 'viewer-macos/build/SU Remote Viewer.app' "$MAC/SU Remote Viewer.app"
cp README.md LICENSE THIRD-PARTY.md VALIDATION.md "$MAC/"
cp -R licenses "$MAC/"
ditto -c -k --keepParent "$MAC" "$OUT/SU-Remote-macOS-AppleSilicon-$VERSION.zip"
for ARCH in x86 x64 arm64; do
  WIN="$STAGING/SU Remote Windows $ARCH"
  mkdir -p "$WIN"
  cp "viewer-windows/dist/$ARCH/SU Remote Viewer.exe" "viewer-windows/dist/$ARCH/su-zerotier.exe" "$WIN/"
  cp README.md LICENSE THIRD-PARTY.md VALIDATION.md "$WIN/"
  cp -R licenses "$WIN/"
  ditto -c -k --keepParent "$WIN" "$OUT/SU-Remote-Windows-$ARCH-$VERSION.zip"
done
(cd "$OUT" && shasum -a 256 ./*.zip > SHA256SUMS.txt)
printf 'Packaged %s\n' "$OUT"
