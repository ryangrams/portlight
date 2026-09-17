#!/bin/bash
# Shared helpers for viewer-ios scripts. Source this file; do not execute it.
# macOS ships bash 3.2: no associative arrays, and empty arrays need the ${a[@]+"${a[@]}"} idiom.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ROOT="$(cd "$IOS_DIR/.." && pwd)"
EVIDENCE_DIR="${PORTLIGHT_EVIDENCE_DIR:-$IOS_DIR/evidence}"
DERIVED_DATA="${PORTLIGHT_DERIVED_DATA:-$IOS_DIR/build/DerivedData}"
CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
FIXTURE_BUILD_DIR="${PORTLIGHT_FIXTURE_BUILD_DIR:-$APP_ROOT/verification/iphone-host-build}"
FIXTURE_EXE="$FIXTURE_BUILD_DIR/Portlight Host.app/Contents/MacOS/SURemoteServer"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
have_xcode() { xcodebuild -version >/dev/null 2>&1; }
require_xcode() { have_xcode || die "Xcode is required. From a Mac without Xcode run: scripts/studio $(basename "$0") $*"; }

# The fixture host must never be built over, or confused with, a live Portlight Host.
case "$FIXTURE_BUILD_DIR" in
  */server-macos/build|*/server-macos/build/|*/server-macos/build-media*|/Applications*)
    die "refusing to use $FIXTURE_BUILD_DIR as the isolated fixture build directory";;
esac

# Command Line Tools ship Testing.framework outside SwiftPM's default search paths.
swift_test_flags() {
  if ! have_xcode && [[ -d "$CLT_FRAMEWORKS/Testing.framework" ]]; then
    printf '%s\n' -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" -Xlinker -F -Xlinker "$CLT_FRAMEWORKS" -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
  fi
}

# Executed-test count from a SwiftPM/XCTest log (Swift Testing summary + XCTest total).
test_count() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], errors="replace").read()
st = [int(n) for n in re.findall(r"Test run with (\d+) tests?", text)]
xc = [int(n) for n in re.findall(r"Executed (\d+) tests?", text)]
print((st[-1] if st else 0) + (xc[-1] if xc else 0))
PY
}

# swift test for PortlightKit on the host Mac. Usage: run_swiftpm_tests <label> [filter]
run_swiftpm_tests() {
  local label="$1" filter="${2:-}" log_file="$EVIDENCE_DIR/swiftpm-$1-$(hostname -s).log"
  local args=() flags=()
  [[ -n "$filter" ]] && args+=(--filter "$filter")
  while IFS= read -r line; do [[ -n "$line" ]] && flags+=("$line"); done < <(swift_test_flags)
  mkdir -p "$EVIDENCE_DIR"
  if ! (cd "$IOS_DIR/PortlightKit" && swift test ${args[@]+"${args[@]}"} ${flags[@]+"${flags[@]}"}) > "$log_file" 2>&1; then
    grep -E "error:|✘|failed|FAIL" "$log_file" | head -60 >&2 || tail -60 "$log_file" >&2
    die "swift test ($label) failed — $log_file"
  fi
  local count; count="$(test_count "$log_file")"
  [[ "$count" -gt 0 ]] || die "swift test ($label) executed zero tests — $log_file"
  log "SwiftPM $label: $count tests passed on $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m), $(swift --version 2>&1 | head -1) — $log_file"
}

# UDID of an available iPhone simulator; prefers $PORTLIGHT_SIM_NAME (default iPhone 17 Pro) on the newest iOS runtime.
pick_simulator() {
  if [[ -n "${PORTLIGHT_SIM_UDID:-}" ]]; then printf '%s\n' "$PORTLIGHT_SIM_UDID"; return; fi
  xcrun simctl list devices available -j | WANT="${PORTLIGHT_SIM_NAME:-iPhone 17 Pro}" python3 -c '
import json, os, sys
data = json.load(sys.stdin)["devices"]
want = os.environ["WANT"]
def version(runtime):
    return tuple(int(p) for p in runtime.rsplit("iOS-", 1)[-1].split("-") if p.isdigit())
runtimes = sorted((r for r in data if ".iOS-" in r), key=version, reverse=True)
for match in (lambda d: d["name"] == want, lambda d: d["name"].startswith("iPhone")):
    for runtime in runtimes:
        for device in data[runtime]:
            if device.get("isAvailable", True) and match(device):
                print(device["udid"]); sys.exit(0)
sys.exit("No available iPhone simulator")'
}

boot_simulator() {
  xcrun simctl boot "$1" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$1" -b >/dev/null 2>&1 || true
}

sim_name() {
  xcrun simctl list devices -j | UDID="$1" python3 -c '
import json, os, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["udid"] == os.environ["UDID"]:
            print(d["name"] + " / " + runtime.rsplit(".", 1)[-1]); sys.exit(0)
print("unknown device")'
}

# xcodebuild test into a fresh .xcresult; fails on test failure or zero executed tests.
# Usage: run_xcode_tests <label> <scheme> [extra xcodebuild args, e.g. -only-testing:PortlightTests]
# Scheme "PortlightKit" is Xcode's generated scheme for the local package's own tests.
run_xcode_tests() {
  require_xcode
  local label="$1" scheme="$2"; shift 2
  local udid; udid="$(pick_simulator)"
  mkdir -p "$EVIDENCE_DIR"
  local result="$EVIDENCE_DIR/xcode-$label-$(date +%Y%m%d-%H%M%S).xcresult" log_file="$EVIDENCE_DIR/xcode-$label.log"
  LAST_XCRESULT="$result"
  local status=0 dir="$IOS_DIR" derived="$DERIVED_DATA" container=(-project "$IOS_DIR/Portlight.xcodeproj")
  # The local package's tests only run from its own directory (its generated scheme has a test action there).
  if [[ "$scheme" == PortlightKit ]]; then dir="$IOS_DIR/PortlightKit"; derived="$DERIVED_DATA-kit"; container=(); fi
  boot_simulator "$udid"
  local attempt
  for attempt in 1 2; do
    status=0
    rm -rf "$result"
    (cd "$dir" && xcodebuild test ${container[@]+"${container[@]}"} -scheme "$scheme" -destination "id=$udid" \
      -derivedDataPath "$derived" -resultBundlePath "$result" "$@") > "$log_file" 2>&1 || status=$?
    # SpringBoard can refuse a runner launch right after boot ("Busy"/"failed preflight checks"). Retry that once;
    # never retry genuine test failures.
    if [[ "$status" -ne 0 && "$attempt" -eq 1 ]] && grep -qE "failed preflight checks|Failed to install or launch the test runner" "$log_file"; then
      log "Simulator refused the test runner launch; waiting and retrying once"
      sleep 5; boot_simulator "$udid"; continue
    fi
    break
  done
  local counts; counts="$(xcrun xcresulttool get test-results summary --path "$result" --compact 2>/dev/null \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("totalTestCount",0), d.get("failedTests",0), d.get("passedTests",0), d.get("skippedTests",0))' || echo "0 0 0 0")"
  local total failed passed skipped; read -r total failed passed skipped <<<"$counts"
  log "Xcode $label on $(sim_name "$udid") [$udid], $(xcodebuild -version | head -1): total=$total passed=$passed failed=$failed skipped=$skipped exit=$status — $result"
  if [[ "$status" -ne 0 ]]; then
    grep -E "error:|failed|Failing|✘" "$log_file" | head -60 >&2 || tail -60 "$log_file" >&2
    # Failure evidence (e.g. UI screenshots) matters most when a run fails.
    if [[ -n "${XCODE_FAILURE_HOOK:-}" ]]; then "$XCODE_FAILURE_HOOK" || true; fi
    die "xcodebuild test ($label) failed — $log_file"
  fi
  [[ "$total" -gt 0 ]] || die "xcodebuild test ($label) executed zero tests — $result"
}

# Build (if stale) the fixture host into the isolated directory and print its executable path.
ensure_fixture_host() {
  if [[ ! -x "$FIXTURE_EXE" ]] || [[ -n "$(find "$APP_ROOT/server-macos/Sources" "$APP_ROOT/shared" -name '*.swift' -newer "$FIXTURE_EXE" -print 2>/dev/null | head -1)" ]]; then
    log "Building isolated fixture host into $FIXTURE_BUILD_DIR"
    SU_REMOTE_BUILD_DIR="$FIXTURE_BUILD_DIR" bash "$APP_ROOT/server-macos/build.sh" >&2
  fi
  printf '%s\n' "$FIXTURE_EXE"
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
