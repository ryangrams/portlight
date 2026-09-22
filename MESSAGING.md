# Portlight messaging preview

Package version: `0.2.1-messages.1`.

The viewers use the Windows 0.2.0.1 source snapshot at `32df59e0690d7315dcb5fc2cf000571769969299`. The existing toolbar, video rendering, screen control, audio, connection, and subscription code are preserved, with isolated messaging hooks. The Host keeps the previously delivered messaging server foundation at `45da224c734c80dd7fb94ad6d3aa6634c0e26186`.

## Send a message

Click the chat bubble in the viewer. Write up to 250 Unicode characters, select any text you want to color or underline, and choose:

- **Popup Message** to keep the message visible until cleared, the Host quits, or three hours pass.
- **Popup for 20s** to show a timed message. Use the duration menu to change the time.
- **Clear Message** to remove the current message. Your draft stays in the composer.

The screen checkboxes in the composer choose which Host screens receive messages. This selection is separate from the screens you are viewing. At least one screen stays selected. Changing the target moves an active message without restarting its timer. The Host menu also has message screen controls and a clear command.

Messages use bold Helvetica, white text by default, and an 80% opaque black background. The banner spans the screen width and fits the text within 15% to 35% of its height. It stays above ordinary app windows, including full-screen apps, without taking keyboard focus or intercepting clicks. macOS protected screens can impose their own window ordering.

An older Host without messaging support keeps normal viewing and control available. A Host with the earlier messaging feature can still receive messages, but needs this update for the client screen picker.

## Validation

`tests/messaging_preservation.py` compares every tracked baseline file, allowing only exact approved hooks and packaging metadata changes. Separate tests cover parser limits, formatting, expiry, display selection, authenticated message commands, live video during messaging, and native composer controls. Native Windows checks run on the isolated review branch. Test success does not establish compatibility with every network, monitor arrangement, or macOS privacy configuration.

This preview does not change an installed app automatically. Keep the working copy available while checking it on your machines.
