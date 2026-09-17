# Portlight iPhone viewer — delivery

This is the DELIVERY-01 document: what was built, where it is, how to reproduce it, and what is still open.

`DELIVERY-MANIFEST.json` is the machine-readable inventory. It records:
- the source commit;
- a SHA-256 for every source and evidence file;
- the toolchains;
- the acceptance status;
- a check that every deliverable below exists.

Regenerate it with `python3 scripts/delivery-manifest.py`.

**Nothing was published.** There was no commit, push, upload, distribution signing, TestFlight upload or App Store submission. The new work is uncommitted in the Portlight checkout.

## Source

| What | Where |
|---|---|
| Portlight checkout | `app/` at git `bfa6c2c51a8e440b81268d892841d3fee7af4e32`. Pre-existing working-tree changes elsewhere are untouched. |
| iPhone viewer (new) | `app/viewer-ios/`: `Portlight.xcodeproj`, `App/`, `PortlightKit/` (the core Swift package), `AppTests/`, `UITests/`, `Config/`, `scripts/`, `docs/`. |
| Host 0.3 brief (new) | `app/docs/host-next/`: a prompt and evidence notes for a later Portlight Host version. No host code was changed. |
| Protocol and host | The Portlight v1 protocol (`wss://host:5920/remote`) and the existing macOS host, both unchanged. URC was a read-only source of ideas; none of its protocol, server or agent machinery is used. |

## Reproduce

Build and test on a Mac with Xcode 26.6 or later. From a Mac without Xcode, prefix each command with `scripts/studio` (see `docs/INSTALL.md`).

```sh
scripts/build-simulator            # the .app for the iOS Simulator
scripts/test-unit                  # PortlightKit on macOS, the iOS Simulator, and the hosted app tests
scripts/test-integration           # a real isolated fixture host plus the mock host, loopback only
scripts/test-ui                    # UI tests and the light/dark screenshot gallery
scripts/test-e2e                   # the app against an isolated fixture host: trust, three real displays, failures
python3 scripts/delivery-manifest.py
```

To run on a physical iPhone:
1. Build and install with development signing: `scripts/test-device --udid <udid>`. Use `--allow-provisioning` only with the account owner's go-ahead.
2. Follow `docs/DEVICE-TEST-SCRIPT.md`.

## Evidence

| Evidence | Where |
|---|---|
| Unit test logs | `evidence/swiftpm-unit-*.log` (macOS), `evidence/xcode-kit-ios.log` (iOS Simulator), `evidence/xcode-app-unit.log` (hosted app tests) |
| Real-host integration | `evidence/swiftpm-integration-*.log` |
| End to end | `evidence/e2e/`: the control transcripts (passwords redacted and checked absent), xcresult summaries, the fixture host log, and the saved connection lists |
| Screenshots | `evidence/e2e/screenshots/` (live sessions against the fixture host) and `evidence/ui-gallery/` (every screen, light and dark) |
| Host dither check | `evidence/quality02-check.json` |
| Result bundles | `evidence/*.xcresult`, with screen recordings |
| Accessibility audit | The `accessibility-audit.txt` attachment of the final UI run, under `evidence/attachments/`: no open issues, and every accepted issue listed with its rule |

Simulator screenshots of the connection states (`evidence/e2e/screenshots/`):
- the saved form;
- the trust sheet showing the exact fingerprint;
- "Password Not Accepted" and "Portlight Host Isn't Listening";
- "Another Viewer Is Connected", then the session after Try Again;
- "The Computer Didn't Answer" and "Can't Reach the Computer";
- the saved list and form after a relaunch.

Session-state screenshots:
- three displays, in portrait and in landscape;
- the gesture guide;
- Diagnostics;
- the Displays sheet, and one display hidden;
- the Quality sheet, and 256 colors;
- Paused;
- View Only;
- the app switcher showing the privacy cover, then the session reconnected after returning.

## Final evidence run (2026-09-11)

| Suite | Where | Result |
|---|---|---|
| PortlightKit (SwiftPM) | MacBook, Command Line Tools, macOS 15.7 | 724/724 |
| PortlightKit (SwiftPM) | RG Mac Studio, macOS 26.3 | 724/724 |
| Real-host and mock-host integration | MacBook | 22/22 |
| PortlightKit on the iOS Simulator | iPhone 17 Pro, iOS 26.5, Xcode 26.6 | 702 passed; 6 Keychain tests skipped (they need an app host and run in the hosted suite) |
| Hosted app tests | iPhone 17 Pro, iOS 26.5 | 36/36 |
| UI tests: gallery, accessibility audit, launch | iPhone 17 Pro, iOS 26.5 | 12 passed; the 7 fixture tests skip here and run under test-e2e |
| End to end against the isolated fixture host | iPhone 17 Pro, iOS 26.5 | 7/7, transcript checks passed, no password in any evidence file |

## Acceptance

Final status (`ACCEPTANCE.json`): **19 passed**, 10 in progress, 2 not started.
- **Passed:** every requirement that can pass on the simulator, plus DELIVERY-01.
- **In progress:** DISP-02, INPUT-01, INPUT-02, INPUT-03, INPUT-04, AUDIO-02, LIFE-01, UX-01, PASTE-01 and PRIV-01. Their simulator, unit and message-level parts pass; each still needs its physical-device check.
- **Not started:** PERF-01 and SOAK-01, which can only be measured on a physical iPhone.

No physical-device requirement is claimed from simulator evidence.

## Open items

- **Physical iPhone.** The paired iPhone ("StrangerAlps", iPhone 17 Pro) reports `unavailable`, so no on-device check has run. `docs/DEVICE-TEST-SCRIPT.md` lists each check, the acceptance item it records, and how to record the result.
- **Known limits.** `docs/KNOWN-LIMITS.md` separates what Portlight v1 and the current host impose from what this viewer doesn't do yet, and lists what hasn't been verified.
- **Host follow-ups.** `app/docs/host-next/` proposes host pings, same-device takeover and click counts; this viewer needs none of them. It also records a host crash found in review: an authenticated client that sends a non-finite ping time aborts Portlight Host (item 32). This viewer can't send one.
