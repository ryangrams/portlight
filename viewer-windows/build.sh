#!/bin/sh
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LLVM_MINGW=${LLVM_MINGW:-/tmp/su-llvm-mingw}
if [ ! -x "$LLVM_MINGW/bin/x86_64-w64-mingw32-g++" ]; then
  ARCHIVE=$(mktemp /tmp/su-llvm-mingw.XXXXXX)
  curl -fL https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/llvm-mingw-20260908-ucrt-macos-universal.tar.xz -o "$ARCHIVE"
  ACTUAL_SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
  if [ "$ACTUAL_SHA" != "d1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149" ]; then
    rm "$ARCHIVE"
    echo "LLVM-MinGW archive checksum mismatch" >&2
    exit 1
  fi
  mkdir -p "$LLVM_MINGW"
  tar -xJf "$ARCHIVE" -C "$LLVM_MINGW" --strip-components=1
  rm "$ARCHIVE"
fi
mkdir -p "$BASE/dist"
for PAIR in i686:x86 x86_64:x64 aarch64:arm64; do
  TARGET=${PAIR%:*}
  LABEL=${PAIR#*:}
  "$LLVM_MINGW/bin/$TARGET-w64-mingw32-windres" -I "$BASE" "$BASE/portlight.rc" -o "$BASE/dist/portlight-$LABEL.res.o"
  "$LLVM_MINGW/bin/$TARGET-w64-mingw32-g++" -std=c++17 -O2 -DNDEBUG -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -municode -mwindows -static -static-libgcc -static-libstdc++ -Wall -Wextra "$BASE/main.cpp" "$BASE/dist/portlight-$LABEL.res.o" -o "$BASE/dist/Portlight-$LABEL.exe" -lwinhttp -lwindowscodecs -lole32 -lcomctl32 -lshlwapi -lshell32 -lcrypt32 -lbcrypt -lws2_32 -lwinmm -luuid -ladvapi32
  "$LLVM_MINGW/bin/llvm-strip" "$BASE/dist/Portlight-$LABEL.exe"
  mkdir -p "$BASE/dist/$LABEL"
  rm -f "$BASE/dist/$LABEL/SU Remote Viewer.exe" "$BASE/dist/SU-Remote-Viewer-$LABEL.exe"
  cp "$BASE/dist/Portlight-$LABEL.exe" "$BASE/dist/$LABEL/Portlight.exe"
  "$LLVM_MINGW/bin/$TARGET-w64-mingw32-g++" -std=c++17 -O2 -DNDEBUG -D_WIN32_WINNT=0x0A00 -static -static-libgcc -static-libstdc++ -I "$BASE/../third_party" "$BASE/../integrations/zerotier/main.cpp" -o "$BASE/dist/$LABEL/su-zerotier.exe" -lws2_32
  "$LLVM_MINGW/bin/llvm-strip" "$BASE/dist/$LABEL/su-zerotier.exe"
  cp "$BASE/README.md" "$BASE/dist/$LABEL/README.md"
  cp "$BASE/../LICENSE" "$BASE/dist/$LABEL/LICENSE.txt"
  cp "$BASE/../third_party/nlohmann/LICENSE.MIT" "$BASE/dist/$LABEL/nlohmann-json-LICENSE.txt"
  echo "Built $LABEL"
done
