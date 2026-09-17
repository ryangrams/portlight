#!/bin/sh
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for ARCH in x86 x64 arm64; do
  test -f "$BASE/dist/$ARCH/Portlight.exe"
  cp "$BASE/README.md" "$BASE/dist/$ARCH/README.md"
  cp "$BASE/../PROTOCOL.md" "$BASE/dist/$ARCH/PROTOCOL.md"
  ARCHIVE="$BASE/dist/Portlight-Windows-$ARCH.zip"
  rm -f "$ARCHIVE"
  (cd "$BASE/dist/$ARCH" && zip -q "$ARCHIVE" Portlight.exe su-zerotier.exe README.md PROTOCOL.md LICENSE.txt nlohmann-json-LICENSE.txt)
  echo "$ARCHIVE"
done
