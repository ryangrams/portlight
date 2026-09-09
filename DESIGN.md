# Portlight interface

Portlight is the viewer; Portlight Host shares a computer. The publisher is Studio Upgrade. The app icon is an original window/light mark in the Studio Upgrade sunflower, fire, and plum palette. Brand color lives in the mark and small accents; the operating system controls interface appearance and accessibility settings.

## Two spaces

**Connections** contains saved computers and the new connection form. Lead with a compact icon, Portlight, and “Your screens, closer.” Use Computer (name or IP address), Password, and a single primary Connect button. Advanced contains Port and ZeroTier. Connecting and errors are inline, with Cancel available. Do not move into the viewing window until authentication succeeds.

**Viewing** is the remote picture and one compact top toolbar: computer name/status, Displays, zoom/Fit, Audio, and Settings. Use native fullscreen conventions. Put display selection in an anchored menu/popover; put picture and interaction settings in a grouped popover/panel. Keep connection forms, instructions, debugging metrics, network policy, and branding banners out of the viewing area. Disconnect returns to Connections. Persist settings through the existing storage keys and keep protocol identities unchanged.

## Visual and interaction rules

- Apply the Apple Design skill's hierarchy, restraint, native familiarity, direct response, reversible transitions, materials, semantic appearance, and accessibility principles to the native apps.
- macOS uses AppKit's system font, unified toolbar, standard window controls, semantic NSColor and NSVisualEffectView. Production appearance is inherited, never forced to Aqua or Dark Aqua.
- Windows follows the same composition and spacing, with Segoe UI and native window controls. Respond to the user's light/dark and high-contrast settings, including changes while running. Do not distribute Apple's fonts or imitate traffic-light title-bar controls.
- Base spacing is 8 points; use 16/24/32 for groups and margins. Connection forms have a restrained readable width and clear focus order. Controls have comfortable hit targets and explicit accessibility labels/tooltips.
- Respond immediately on press; avoid delays on input. Keep popovers anchored to their triggers. Native scroll/zoom follows the pointer directly. Respect reduced motion and reduced transparency. Avoid ornamental motion on remote pictures.
- Display chrome, empty states, connection forms, popovers, and fields must all work in light and dark appearances. Remote pixels are not recolored by the viewer's theme.
- Every existing capability remains reachable, but infrequent choices are one level deeper. Connection details and ZeroTier stay in Connections; session settings affect the live session without reconnecting.

## Shared terminology

| Previous wording | Visible wording | Meaning / protocol |
| --- | --- | --- |
| SU Remote Viewer | Portlight | Viewer app; existing identifiers remain stable |
| SU Remote Server | Portlight Host | Computer sharing app |
| Server / host | Computer | Connection address; advanced Port |
| Preset | Saved connection | Keeps existing preset keys and OSC addresses |
| Monitors | Displays | Monitor checkbox/menu selection |
| Size | Resolution | HD · 720p, FHD · 1080p, QHD · 1440p, UHD · 2160p |
| Adaptive | Automatic | `quality:auto` |
| Desktop | Text & controls | `quality:desktop` |
| Motion | Video | `quality:motion` |
| Color / Gray16 | Color mode / Grayscale · 16 shades | `gray16`; not “16 colors” |
| 256 colors | 256 colors | `color256` |
| RGB565 | 16-bit color | `rgb565` |
| Full | Full color | `full` |
| CAP kbps | Bandwidth limit | User-facing Mbps with Automatic; wire remains kbit/s |
| FPS | Frame rate | Value in frames per second |
| View only | Allow control | Invert existing `viewOnly` flag; default remains control allowed |
| Follow pointer / manual | Panning: Follow pointer / Scroll | Local viewer movement |
| Fit all | Fit displays | Fits selected displays in the viewing window |
| ZeroTier managed IDs | Networks to pause | Explicit network policy selection |
| Forget transaction | Keep current networks | Recovery action clears the saved restoration record |

Technical labels such as certificate fingerprint are kept when they explain a security decision. Protocol codecs, queue counters, revision numbers, token paths, and internal identifiers are not everyday interface copy.

## Acceptance

Review actual native app screenshots for Connections and Viewing in both appearances, at normal and minimum window sizes. Confirm the session has no connection form or permanent settings sidebar. Exercise connection success/failure/disconnect, saved connection recall, every toolbar menu, keyboard focus, fullscreen, theme changes, and existing native integration tests. Compare grayscale and color performance using identical source frames/settings and record the benchmark conditions; do not infer speed from palette size alone.
