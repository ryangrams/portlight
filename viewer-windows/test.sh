#!/bin/sh
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_BIN=$(mktemp /tmp/su-viewer-protocol-test.XXXXXX)
trap 'rm -f "$TEST_BIN"' EXIT
clang++ -std=c++17 -fsanitize=address,undefined -g "$BASE/tests/protocol_validation.cpp" -o "$TEST_BIN"
"$TEST_BIN"
