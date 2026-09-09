#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'The combined preview build requires an Apple Silicon Mac.' >&2
  exit 1
fi
./branding/build.sh
./integrations/zerotier/build.sh
./server-macos/build.sh --test
./viewer-macos/build.sh
./viewer-windows/build.sh
