# Portlight iPhone — known limitations

This list is honest as of 2026-09-11. It separates what the Portlight v1 protocol and host impose, what
this viewer doesn't do yet, and what hasn't been verified. `docs/DEVICE-TEST-SCRIPT.md` covers the items
still open on a physical device.

## Protocol and host (not fixable in the viewer alone)

- **One viewer per Mac.** A second viewer gets "Another Viewer Is Connected". If a phone vanishes without
  closing its connection, the host can keep its session until a send fails. The viewer retries `busy`
  for 20 s during an automatic reconnect only. The Host 0.3 brief (`app/docs/host-next/`) proposes host
  pings and same-device takeover.
- **Changing settings restarts the stream.** Every accepted subscription (display, quality, pause,
  view-only, or visible-region change) restarts capture and releases held input on the Mac. The viewer
  never resubscribes while a button or key is held and waits until a gesture settles, but each change
  still costs a keyframe.
- **Audio shares the video's TCP connection.** A large image already in flight can delay audio. There
  are no media timestamps, so A/V sync is best-effort.
- **No clipboard sync.** "Type Pasted Text" types the phone's pasted text into the focused Mac field. It
  never reads or sets the Mac clipboard.
- **No discovery.** Computers are added by host name or IP address; there is no Bonjour yet.
- **16 displays per subscription.** A Mac with more than 16 displays requires choosing which to show.
- **"Native" resolution.** If any selected display is smaller than HD, the host streams every selected
  display at native size. The viewer pauses and asks for fewer displays when that exceeds the phone's
  memory budget.
- **Stale JPEG artifacts.** In Automatic quality, JPEG artifacts after motion can stay on a static screen
  until something changes there, because the host's lossless refresh waits for a new capture.
- **Double-click depends on the host.** Two quick taps send two clicks. Whether a Mac app sees a
  double-click depends on the host setting a click count, which it currently doesn't.
- **Keys the host can't map** are dropped by the viewer's keysym table rather than typed as garbage. The
  host itself still types some unmapped keysyms as text.
- **A malformed ping crashes the current host.** An authenticated client that sends a ping with a
  non-finite time (for example `-1e999`) makes Portlight Host abort. This viewer can't send one, because
  its encoder rejects non-finite numbers. The fix is item 32 of the Host 0.3 brief.

## Viewer scope (by design or not yet done)

- **Foreground only.** Going to the background closes the session gracefully and keeps the last frame in
  memory. Returning reconnects. There is no background streaming or audio.
- **iPhone first.** The app builds for iPad and adapts, but iPad multitasking, pointer/trackpad hover and
  external displays are not accepted yet.
- **Gestures.** Three-finger gestures are intentionally unused. Right-drag uses the explicit Hold Right
  control. Local pan has no momentum.
- **Untuned constants.** Every gesture threshold is a starting value until it is tuned on a device: tap
  slop, long press, double-tap window, pinch/scroll locks, trackpad gain, and inertia.
- **Memory.** The staging memory for decoded patches is a fixed 96 MiB. The total canvas pixels are capped
  by a device-memory budget (four FHD at 4 GiB or less, up to four UHD at over 6 GiB). Resolution buttons
  above the budget are disabled with a reason.
- **Slow links.** A 6 s read watchdog treats silence as a lost network (the host sends stats every
  second). On very slow links, a large keyframe in flight may trip it. This is still to be measured.
- **Local Network permission.** The first connection during the system's Local Network prompt may fail as
  "Allow Local Network Access". Try Again works once it is allowed.
- **Offline or no route.** URLSession reports an offline iPhone and an address it has no route to (such as a
  VPN-only address while the VPN is off) with the same error. The viewer tells them apart using the device's
  own network status, which it starts watching at launch. In the first moments after launch, before that
  status arrives, an address with no route reads as "No Network Connection".

## Not yet verified

- **Physical-device items** are pending, because the paired iPhone reports `unavailable`: real gestures and
  input, mixed-DPI placement on a real Mac, audio routes and interruptions, lifecycle/privacy cover,
  VoiceOver, the Local Network prompt, performance on named link profiles, and the 30-minute soak.
- **Simulator coverage.** Simulator evidence is real TLS and real decoded pixels from an isolated fixture
  host. The fixture never injects input and has no audio. Input and audio are verified at the message level
  against the mock host and by unit tests.
