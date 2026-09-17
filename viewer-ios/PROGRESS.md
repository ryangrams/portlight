# Portlight iPhone viewer — progress

**Current state: delivered for the simulator scope.** Everything that can be verified on the iOS Simulator is done and recorded. The real app runs end to end against the real Portlight fixture host. Physical-device checks are pending because no iPhone is available. See `DELIVERY.md`.

## Source identity

- **Portlight checkout** `app/`: git `bfa6c2c51a8e440b81268d892841d3fee7af4e32`, plus pre-existing working-tree changes (untouched). The handoff snapshot is byte-identical (BASE-01).
- **New work** lives only in `app/viewer-ios/` (untracked), plus the host brief in `app/docs/host-next/`.
- **URC reference:** RG Mac Studio `~/SUDev/Ultimate Remote Connect` @ `4172609`, read-only.
- **Environment.**
  - This MacBook has Command Line Tools only (SwiftPM tests).
  - RG Mac Studio (Xcode 26.6, iOS 26.5 simulators) is driven by `scripts/studio`, with a single mirror at `~/SUDev/portlight-ios-work/app`.
  - The Studio disk is nearly full (about 7 GiB free). `scripts/studio` stops below 4 GiB and deletes remote result bundles after copying them back.

## Status (2026-09-11 ~07:35)

| Area | State |
|---|---|
| PortlightKit | All modules integrated: Core, Protocol, Viewport, Input, Rendering, Audio, Persistence, Engine, Transport, Session. Every module, and the mock host, has had an adversarial review and fix. |
| Session review | Fixed three stuck-input defects: input pressed after a subscribe lost its release when the host acknowledged; a canvas-budget refusal left a phantom press; a Locked modifier was lost after a region refinement. Also bounded Type Pasted Text (4,096 characters, paced) and added session alerts, serialized profile saves and a precise missing-password reason. The app adopts all four. |
| App | Composed: connections, trust sheet, live session, sheets, keyboard, notices and alerts, privacy cover, lifecycle. It is wired to `SessionController`, `WebSocketTransport` and `MetalRenderer`. |
| Accessibility | Xcode's audit runs on all 24 gallery pages. It went from 180 issues to none open; 61 are accepted under documented rules. The fixes: opaque cards and banner, stronger secondary text, label-colored secondary buttons, Dynamic Type caps only on the dense bars, and wrapping instead of truncation. |
| Final evidence | macOS SwiftPM 724/724 on both Macs. Integration 22/22 (real fixture and mock hosts, including the viewer's own input and AAC and μ-law audio). iOS kit 702 passed + 6 unhosted Keychain skips. Hosted app 36/36. UI 12 passed + 7 fixture skips (gallery rerun 11/11 after the address-wrap fix). E2E 7/7. |
| Network failures | A probe showed no-route misreported as "No Network Connection": URLSession gives a bare -1009, while the kernel says EHOSTUNREACH. Fixed by classifying with the device's own network status (`DeviceNetworkMonitor`, started at launch); see DECISIONS.md "Local network rule". |
| Host finding | The mock review showed that an authenticated client can crash the current Portlight Host with a non-finite ping time. The viewer can't send one. The fix is item 32 of the Host 0.3 brief. |
| Delivery | `DELIVERY.md` and `DELIVERY-MANIFEST.json`; regenerate the manifest with `python3 scripts/delivery-manifest.py`. |
| Docs | `DECISIONS.md`, `DELIVERY.md`, `docs/UI-SPEC.md`, `docs/SESSION-CONTROLLER-SPEC.md`, `docs/DEVICE-TEST-SCRIPT.md`, `docs/KNOWN-LIMITS.md`, `docs/INSTALL.md`, `CLAUDE.md` |

**Acceptance** (`ACCEPTANCE.json`): **19 passed**, 10 in progress, 2 not started.
- **Passed:** BASE-01, BASE-02, NET-01, NET-02, NET-03, NET-04, WIRE-01, DISP-01, RENDER-01, RENDER-02, RENDER-03, VIEW-01, VIEW-02, QUALITY-01, QUALITY-02, REGION-01, AUDIO-01, SAVE-01, DELIVERY-01.
- **In progress:** DISP-02, INPUT-01, INPUT-02, INPUT-03, INPUT-04, AUDIO-02, LIFE-01, UX-01, PASTE-01, PRIV-01. Their simulator, unit and message-level parts pass; the physical-device checks are pending.
- **Not started:** PERF-01 and SOAK-01, which can only be measured on a physical iPhone.

## Known gaps / blockers

- **Physical iPhone.** "StrangerAlps" (iPhone 17 Pro) is paired to the Studio but `unavailable`. Every physical-device check is pending (`docs/DEVICE-TEST-SCRIPT.md`). `scripts/test-device` is ready; `--allow-provisioning` needs the owner's go-ahead.
- **Fixture limits.** The fixture ignores input and has no audio. Input and audio are verified at message level against the mock host and by unit tests. Physical results need a consented test Mac.
- **To measure on a device:**
  - the 20-UTF-16-unit text cap and the paste pacing;
  - double-click behavior;
  - gesture thresholds;
  - the 6 s read watchdog on slow links;
  - the fixed 96 MiB staging budget.

## Next steps (for whoever continues)

1. **Physical iPhone.** When one is available, run `docs/DEVICE-TEST-SCRIPT.md` and record each result in `ACCEPTANCE.json`. The first install of this App ID needs `--allow-provisioning`, with the account owner's go-ahead.
2. **Portlight Host 0.3** (a separate project). Start with item 32, the crash; the brief is in `app/docs/host-next/`.
3. **Distribution.** TestFlight and the App Store were out of scope here. The owner decides signing and distribution.
