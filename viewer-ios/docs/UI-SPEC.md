# Portlight iPhone — UI specification

This spec turns EXECUTION-PLAN §2 into concrete screens and components. The plan wins on any conflict.
Other inputs are URC's proven UX rules: honest bounded dial states, a status card derived from one state
machine, a button that explains why it's disabled, frozen-frame resume, and "the texture is the truth".

Principles:
- **The picture owns the screen.** Chrome is native, compact and reachable.
- **Every state is explicit.** Control On / View Only, input mode, paused and reconnecting are always visible.
- **Interaction never waits on the network.** Local zoom and pan stay live when paused, reconnecting, or when frames stop.
- **Native controls first.** Use SF Symbols and system materials. Colour only supplements an icon and a label.

## 1. Navigation

`PortlightApp` → `RootView` (a `NavigationStack`):

1. **Connections list** (root, title "Connections").
2. **Connection detail**, pushed. It edits a saved connection or a new draft.
3. **Session**, a `fullScreenCover` shown once a connection attempt starts and kept through connected and reconnecting.
   - It closes back to the detail view on disconnect, cancel, or a failure the user dismisses.
   - The connection progress card and the failure card are layered inside the session cover, so the frozen
     frame (if any) remains beneath them.

There is exactly one session owner. Views never start a connection as they appear.

## 2. Connections list

- **Grouping.** `List` with sections: ungrouped first, then one section per group. Tapping a group header
  collapses or expands it in one tap (a disclosure group).
- **Rows.** Title is `displayTitle`: the name, or "Saved Connection" when unnamed. The subtitle is
  `host:port` in the secondary text color; it wraps rather than being cut off. Minimum height 44 pt.
- **Tapping a row** selects it and pushes its detail. It does **not** connect and does **not** read the Keychain.
- **Context menu:** Connect, Edit, Move to Group, Delete. An explicit Connect here is allowed.
- **Toolbar.** A `plus` menu (New Connection, New Group) and `EditButton`. Edit mode supports reorder,
  delete (swipe), and moving rows between groups.
- **Empty state.** `ContentUnavailableView`: "No Saved Connections", with a "New Connection" button.
- **Branding.** A publisher footer "Portlight · by Studio Upgrade" in the list footer (from the branding README).
  It never appears over the remote picture.

## 3. Connection detail (form)

**Fields, in order:**

| Field | Setup | Return key |
|---|---|---|
| Name (optional) | Placeholder "Optional" | Next |
| Computer | `.URL` keyboard, no autocapitalization or autocorrection | Next |
| Password | `SecureField`; smart quotes, dashes and insert are off | Go (connects) |
| Port | Number pad; accessory "Done" | none |

- **Validation.** Inline messages under each field, from `ConnectionDraft` validation. They appear after the
  field is edited or Connect is pressed, not on first load. External-keyboard Tab and Shift-Tab move through
  the fields normally.
- **Password when a saved one exists.** The field shows "Saved in Keychain" as its placeholder, with a
  "Forget Saved Password" button. The Keychain is read only when Connect is pressed.
- **Primary action.** A prominent "Connect" button, `.borderedProminent`, full width.
  - When disabled, one footer sentence says why, and the same text is its `accessibilityHint`.
- **Secondary action.** "Save Connection" for a new draft, "Update Connection" for a saved one.
  - It stores the password in the Keychain only if the user types one and saves.
- **Connect always starts fresh:** all displays selected, and the profile's quality preferences applied.

## 4. Connection progress and trust

**Progress card**
- `.regularMaterial` rounded card, max width 420, centered, over the frozen frame or a neutral backdrop.
- Shows a spinner, the phase title (`ConnectionPhase.title`) and a detail line naming the target:
  "Connecting to host:port".
- After 3 s in `connecting` it adds "Not answering yet — check that the Mac is awake and on the same network."
- A **Cancel** button is always present.
- Accessibility: children combined; the title and detail change announcements.

**Failure card**
- `ConnectionFailure.title` and `message(for:)`.
- Buttons: **Try Again** (only when sensible) and **Edit Connection** / **Close**.
- `localNetworkDenied` adds an "Open Settings" button.

**Trust sheet** (`.sheet`, not dismissible by swipe while pending)
- **First use:** title "Trust This Computer?", icon `lock.shield`.
- **Changed certificate:** title "Computer Identity Changed", icon `exclamationmark.shield.fill`, a critical
  red tint, and a secondary explanation.
- **Body:**
  - the endpoint;
  - "SHA-256 certificate fingerprint" as 4 lines of 8 hex pairs, monospaced and selectable;
  - "Compare with Connection Details in Portlight Host on the Mac. Your password has not been sent."
- **Buttons:** "Trust and Connect" (prominent; destructive-styled when the certificate changed) and "Cancel".
- **Stale approvals.** Approving a stale prompt (a new attempt started) does nothing.

## 5. Session screen

**Surface**
- `SessionSurfaceView` is a `UIViewRepresentable` built once (empty `updateUIView`) around a `UIView` with a
  `CAMetalLayer`.
- It forwards raw touches to the `GestureInterpreter` and drives rendering from a `CAMetalDisplayLink`.
- It draws full-bleed under the safe areas. Fit uses the safe-area rect (minus visible chrome).

**Portrait chrome**
- **Top bar**, compact and native. `.ultraThinMaterial`, or solid when Reduce Transparency is on.
  - Leading: "Disconnect" (`xmark`).
  - Center: the computer name, plus a status line (phase, or the effective resolution) in secondary style.
  - Trailing: the Control button.
- **Control button.** A labeled toggle with a distinct icon and word for each state.
  - Control On: `cursorarrow.click.2` with "Control On" (`cursorarrow.rays` read as a loading spinner), filled, accent.
  - View Only: `eye` with "View Only", outlined.
  - Selected trait when on.
- **Bottom strip**, safe-area aware, 44 pt targets, icons with short labels. A button whose state is on is drawn
  as a filled accent tile, with a primary-color outline under Increase Contrast:

| Button | Icon | Label |
|---|---|---|
| Displays | `display.2` | "Displays" with a count badge "3" |
| Input | Trackpad `rectangle.and.hand.point.up.left`, Direct `hand.tap`, Pan `hand.draw` | Current mode name; tapping cycles, long-press shows a menu |
| Keyboard | `keyboard` | toggles the software keyboard and accessory bar |
| Pause | `pause.fill` / `play.fill` | "Pause" / "Resume" |
| Audio | `speaker.slash` / `speaker.wave.2` | disabled with a reason when the host has no audio |
| More | `ellipsis.circle` | Quality…, Fit, Actual Size, Zoom In/Out, Hide Controls, Gesture Guide, Diagnostics |

**Landscape.** The same controls move to a vertical trailing rail inside the safe area. The top bar condenses
to Disconnect, the name, and the Control button on the leading rail. Not every desktop setting goes in one row.

**Hide Controls**
- Chrome animates out; with Reduce Motion it fades.
- A small grabber remains at the bottom edge (`chevron.compact.up`, 44×44 hit area).
- While hidden, a tap on the canvas only reveals the controls. It is never also a click.

**Paused.** The retained image is dimmed, with a large `pause.circle.fill`, "Paused", and a Resume button.
Input is disabled; local zoom and pan still work. Resume restores the previous audio preference.

**Reconnecting.** The frozen frame is dimmed, with the progress card ("Reconnecting", attempt N, Cancel).
It is never controllable until connected.

**Empty selection** (None selected). The picture area shows "No Displays Selected", with a "Choose Displays"
button. No input is sent.

**Banners.** Transient `SessionNotice` banners slide in under the top bar and auto-dismiss (with a tap-to-dismiss).
They never permanently cover content.

**Alerts.** Two events need an answer, so they appear as system alerts, one at a time, rather than as banners:
- "Audio Couldn't Start": the system refused the audio session. Buttons: Resume and OK.
- "Text Shortened": a paste or typed text was over 4,096 characters, so only the first 4,096 were typed. Button: OK.

**Keeping the device awake.** The idle timer is disabled only while a connected session is visible in the
foreground, and restored otherwise.

## 6. Displays sheet

- A `.sheet` with `.medium` and `.large` detents on phone, and a popover on regular width.
- **Map.** Every host display in its real logical arrangement (`DesktopLayout.arrange(compact:false)`), scaled to fit.
  - Active displays are filled with the accent and show their number. Inactive ones are dimmed and outlined.
  - A map tile is a toggle only if it is at least 44×44 pt; otherwise the map is decorative (accessibility hidden).
- **List**, always present: a row per display with a leading checkmark toggle and "N · Name". The detail line
  shows the logical size in points and the stream size, plus a "Main" badge. Toggling applies immediately
  without reconnecting.
- **Buttons:** "All" and "None". A footnote: "This changes only what this iPhone shows. Your Mac's display
  arrangement stays the same."

## 7. Quality sheet

**Resolution.** A 2×2 grid of large buttons: HD, FHD, QHD, UHD.
- Each shows the N×N grid motif (2/3/4/5), the title, and the detail ("720p").
- Selected: filled accent background, 2 pt outline, white text, `.isSelected` trait.
- Unavailable: dimmed, `.disabled`, with the reason in the accessibility hint and a footnote.

**Color.** Three buttons:
- Full Color: a gradient swatch.
- 256 Colors: a 4×4 palette swatch.
- 16 Shades of Gray: four gray bars.

**Content.** A segmented control: Automatic, Text, Video.

**Smooth gradients.** A toggle, enabled only for Video with reduced color. Footnote: "Reduces banding in
video with fewer colors. Uses more data."

**Data rate**
- Video: Automatic or a manual limit in Mbps (0.1 to 100, stepper with common values).
- Audio quality: Mono 48, Stereo 96, Stereo 160, Stereo 320 kbps. Choosing one does not turn audio on.

**Status line** (requested versus effective), e.g. "Streaming FHD · limited by Display 2" or
"HD selected · FHD not possible with this iPhone's memory for 3 displays".

**No FPS control anywhere.**

## 8. Keyboard accessory and input controls

An `inputAccessoryView` attached to the hidden text-input responder. It is also available without the
software keyboard, as a panel from the Keyboard button when a hardware keyboard is attached.

**Row 1**
- Modifiers ⌘ ⌥ ⇧ ⌃, each with three states:

  | State | Look | VoiceOver value |
  |---|---|---|
  | Off | plain | "Off" |
  | Latched | filled accent | "Next action" |
  | Locked | filled accent, underline bar, `lock.fill` mini glyph | "Locked" |

- Esc, Tab, an arrows cluster, and "fn" (expands a second row with F1–F12).
- "More" expands Home, End, Page Up, Page Down, Forward Delete.

**Mouse controls:** Left/Right/Middle click, and "Hold Left" / "Hold Right" latches that show a pressed
state while held.

**Type Pasted Text:** a `UIPasteControl` labeled "Type Pasted Text". Explanatory caption: "Types into the
focused field on the Mac. It doesn't change the Mac's clipboard." There is no pasteboard polling.

## 9. Gesture guide

Shown once on first session start, and later from the More menu. It is a sheet with a segmented control
(Trackpad, Direct, Pan) and a table of gestures from the plan's gesture table. Each row has an SF Symbol and
a one-line description.

## 10. Diagnostics

A list sheet, read-only, updated at up to 2 Hz:
- receive Mbps and changed-image updates/s
- decoded, applied, rejected and stale rectangles
- presented and skipped draws
- decoder queue jobs and bytes
- frame age (time since the last applied patch)
- subscriptions sent per minute and time-to-fresh-region
- audio queued ms, underruns and drops
- requested versus effective resolution, and the canvas sizes

It has an "Export Diagnostics" action whose text contains no credentials, fingerprints, host names (unless
the user opts in), or pixels.

## 11. Accessibility and appearance

- **Appearance:** light and dark; system backgrounds; the accent from the asset catalog.
- **Dynamic Type everywhere.** Sheets scroll. The session chrome uses the large-content viewer
  (`accessibilityShowsLargeContentViewer`) for icon-only compact items at accessibility sizes.
- **VoiceOver.** Every control has a label, value and traits. The remote surface is one element: "Remote
  screen, Control On, Trackpad", with custom actions for Fit, Actual Size, Displays and Pause.
- **Contrast and transparency.** Increase Contrast gives thicker outlines on selected states. Reduce
  Transparency gives solid backgrounds instead of materials.
- **Reduce Motion** replaces slide and scale transitions with fades.
- **Hit targets:** 44×44 pt minimum.

## 12. Privacy and lifecycle

- **Inactive or background.** Release input, stop media, close gracefully, and keep the last frame in memory.
- **App switcher.** The snapshot shows a cover view (the app icon on a neutral background) instead of remote pixels.
- **Storage.** Remote images are never written to disk.
- **Foreground.** If a session was active, show "Reconnecting" over the frozen frame and restore the current
  selection (minus missing IDs). A deliberate new connection selects all displays.
