#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
c++ -std=c++17 -O2 -Wall -Wextra -mmacosx-version-min=14.4 -I ../../third_party main.cpp -o build/su-zerotier
./build/su-zerotier --self-test
