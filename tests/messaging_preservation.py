#!/usr/bin/env python3
"""Keep the recognized 0.2.0.1 viewers and the handed-off Host intact.

Each approved hook is literal source text with an exact occurrence count. After
undoing only those hooks in memory, the entire file must match the release
commit byte for byte. This protects every original function, declaration,
toolbar coordinate, timer, paint path, and connection/input handler, including
code outside any hand-picked method list. No source files are rewritten.
"""

from __future__ import annotations

import difflib
import hashlib
import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
CLIENT_BASELINE = "32df59e0690d7315dcb5fc2cf000571769969299"
HOST_BASELINE = "45da224c734c80dd7fb94ad6d3aa6634c0e26186"
REMOVED_HOST_FILES = ("server-macos/Sources/Permissions.swift",)

# (Released text, approved replacement), including an original source anchor.
# Repeated, missing, or relocated hook text fails the gate.
HOOKS: dict[str, tuple[tuple[str, str], ...]] = {
    "server-macos/Sources/Server.swift": (
        ("    let packetWindow: Int\n", "    let packetWindow: Int\n"
             "    lazy var popupMessages = makePopupMessages()\n"
             "    var onPopupChange: (() -> Void)?\n"),
        ('"maxViewers":1]])',
         '"maxViewers":1,"popupMessages":PopupMessage.capability]])'),
        ("    }\n    func topologyChanged() {\n",
         "        send(server.popupMessages.state)\n    }\n    func topologyChanged() {\n"),
        ("        switch type {\n",
         "        if handlePopupMessage(object) { return }\n        switch type {\n"),
    ),
    "server-macos/Sources/main.swift": (
        ("            server.onConnection={ [weak self] in self?.refreshMenu() }\n",
         "            server.onConnection={ [weak self] in self?.refreshMenu() }\n"
         "            server.onPopupChange={ [weak self] in self?.refreshMenu() }\n"),
        ("    func applicationWillTerminate(_ notification: Notification) { server?.stop() }\n",
         "    func applicationWillTerminate(_ notification: Notification) { server?.popupMessages.clear();server?.stop() }\n"),
        ('        add(menu,"About Portlight",#selector(about))\n',
         '        add(menu,"About Portlight",#selector(about))\n'
         "        appendMessageMenu(to: menu)\n"),
        ('\\n\\nVersion 0.2.0 preview\\nOne viewer per computer.',
         '\\n\\nVersion 0.2.1-messages.1 preview\\nOne viewer per computer.'),
        ('if CommandLine.arguments.contains("--self-test") {\n', r'''if CommandLine.arguments.contains("--popup-self-test") {
    _ = NSApplication.shared
    do { try popupMessageSelfTest();exit(0) } catch { fputs("FAIL: \(error)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--message-visual-test"), index + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    do { try popupMessageVisualTest(outputDirectory:CommandLine.arguments[index+1]);exit(0) }
    catch { fputs("FAIL: \(error)\n",stderr);exit(1) }
}
if CommandLine.arguments.contains("--self-test") {
'''),
    ),
    "viewer-macos/Sources/Viewer.swift": (
        ("    private let transport = RemoteTransport()\n",
         "    private let transport = RemoteTransport()\n"
         "    private lazy var popupSession = ViewerPopupSession { [weak self] object in\n"
         "        guard let self, self.ready, !self.demo else { return }\n"
         "        self.transport.send(object)\n    }\n"),
        ('    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }\n',
         '    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) + (toolbar.identifier == "Portlight.ConnectionsToolbar" ? [] : [.init("message")]) }\n'),
        ('        switch id.rawValue {\n        case "identity":\n',
         '        switch id.rawValue {\n        case "message": _ = icon("Send message", "message", #selector(messageAction))\n        case "identity":\n'),
        ('            sessionNameLabel.widthAnchor.constraint(lessThanOrEqualTo:identity.widthAnchor).isActive = true\n',
         '            sessionNameLabel.widthAnchor.constraint(lessThanOrEqualTo:identity.widthAnchor).isActive = true\n'
         '            ViewerPopupSession.addLauncher(to: identity, button: toolbarButton("", symbol: "message", action: #selector(messageAction)))\n'),
        ('    @objc private func toolbarChoice(_ sender:NSMenuItem) {\n',
         '    @objc private func messageAction() {\n'
         '        releaseInput(); activePopover?.close()\n'
         '        popupSession.show(appearance:window?.appearance, defaults:testing || demo ? nil : .standard)\n'
         '    }\n    @objc private func toolbarChoice(_ sender:NSMenuItem) {\n'),
        ('    @objc private func overflowAction(_ sender:NSMenuItem) {\n        switch sender.representedObject as? String {\n',
         '    @objc private func overflowAction(_ sender:NSMenuItem) {\n        switch sender.representedObject as? String {\n'
         '        case "message": messageAction()\n'),
        ('    private func didDisconnect() {\n',
         '    private func didDisconnect() {\n        popupSession.disconnect()\n'),
        ('    private func receive(_ object:[String:Any],data:Data?) {\n        guard let type = object["type"] as? String else { return }\n',
         '    private func receive(_ object:[String:Any],data:Data?) {\n        guard let type = object["type"] as? String else { return }\n'
         '        if popupSession.receive(object) { return }\n'),
        ('        case "subscribed":\n',
         '            if type == "welcome" { popupSession.welcome(object) }\n        case "subscribed":\n'),
    ),
    "viewer-windows/main.cpp": (
        ('#include "ui.hpp"\n',
         'namespace portlight_popup {\nstatic void layoutLauncher();\n'
         'static bool drawIcon(HDC, int, RECT, COLORREF);\n}\n'
         '#include "ui.hpp"\n#include "popup_ui.hpp"\n'),
        ('  auto type = msg.value("type", "");\n',
         '  auto type = msg.value("type", "");\n  if (portlight_popup::receive(msg))\n    return;\n'),
        ('int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, LPWSTR arguments, int show) {\n',
         '#include "popup_tests.hpp"\nint WINAPI wWinMain(HINSTANCE instance, HINSTANCE, LPWSTR arguments, int show) {\n'),
        ('      arguments && std::wstring(arguments) == L"--integration-test";\n',
         '      arguments && std::wstring(arguments) == L"--integration-test";\n  portlight_popup::configureTests(arguments);\n'),
        ('  if (!mainWindow)\n    return 1;\n',
         '  if (!mainWindow)\n    return 1;\n  portlight_popup::install();\n'
         '  if (int result = portlight_popup::runTests(arguments); result >= 0)\n    return result;\n'),
        ('  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {\n',
         '  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {\n'
         '    if (portlight_popup::dialogMessage(msg))\n      continue;\n'),
    ),
    "viewer-windows/ui.hpp": (
        ('static void drawToolbarIcon(HDC dc, int id, RECT r, COLORREF color) {\n',
         'static void drawToolbarIcon(HDC dc, int id, RECT r, COLORREF color) {\n'
         '  if (portlight_popup::drawIcon(dc, id, r, color))\n    return;\n'),
        ('  InvalidateRect(mainWindow, nullptr, FALSE);\n}\nstatic void fitWindowToDisplays() {\n',
         '  InvalidateRect(mainWindow, nullptr, FALSE);\n  portlight_popup::layoutLauncher();\n}\nstatic void fitWindowToDisplays() {\n'),
    ),
    "server-macos/Info.plist": (
        ('<key>CFBundleShortVersionString</key><string>0.2.0</string>\n<key>CFBundleVersion</key><string>2</string>',
         '<key>CFBundleShortVersionString</key><string>0.2.1</string>\n<key>CFBundleVersion</key><string>3</string>'),
    ),
    "viewer-macos/Resources/Info.plist": (
        ('<key>CFBundleShortVersionString</key><string>0.2.0</string>\n<key>CFBundleVersion</key><string>2</string>',
         '<key>CFBundleShortVersionString</key><string>0.2.1</string>\n<key>CFBundleVersion</key><string>3</string>'),
    ),
    "viewer-windows/portlight.rc": (
        ('FILEVERSION 0,2,0,1\nPRODUCTVERSION 0,2,0,1\n',
         'FILEVERSION 0,2,1,0\nPRODUCTVERSION 0,2,1,0\n'),
    ),
    "package.sh": (
        ('VERSION="${SU_REMOTE_VERSION:-0.2.0-alpha.1}"\n',
         'VERSION="${SU_REMOTE_VERSION:-0.2.1-messages.1}"\n'),
        ('cp README.md LICENSE THIRD-PARTY.md VALIDATION.md "$MAC/"\n',
         'cp README.md LICENSE THIRD-PARTY.md VALIDATION.md MESSAGING.md "$MAC/"\n'),
        ('  cp README.md LICENSE THIRD-PARTY.md VALIDATION.md "$WIN/"\n',
         '  cp README.md LICENSE THIRD-PARTY.md VALIDATION.md MESSAGING.md "$WIN/"\n'),
    ),
    ".github/workflows/build.yml": (
        ('      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6\n        with:\n          persist-credentials: false\n      - uses: actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1 # v6\n        with:\n          python-version: \'3.12\'\n      - name: Build apps and run native Mac tests\n',
         '      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6\n        with:\n          persist-credentials: false\n          fetch-depth: 0\n      - uses: actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1 # v6\n        with:\n          python-version: \'3.12\'\n      - name: Build apps and run native Mac tests\n'),
        ('        run: ./build.sh\n',
         '        run: ./build.sh\n'
         '      - name: Verify the approved messaging-only changes\n'
         '        run: |\n'
         '          python3 tests/messaging_preservation.py\n'
         '          python3 tests/messaging_preservation.py --self-test\n'
         "          'server-macos/build/Portlight Host.app/Contents/MacOS/SURemoteServer' --popup-self-test\n"
         '          ./viewer-macos/test-popup.sh\n'),
        ('          .test-venv/bin/python viewer-macos/test-appearance.py\n',
         '          .test-venv/bin/python viewer-macos/test-appearance.py\n'
         '          .test-venv/bin/python tests/popup_stream_soak.py --seconds 120\n'
         '          .test-venv/bin/python viewer-macos/test-popup-stream.py --seconds 120\n'),
        ('          name: macos-design-review\n          path: viewer-macos/build/design-review/\n',
         '          name: macos-design-review\n          path: |\n'
         '            viewer-macos/build/design-review/\n'
         '            viewer-macos/build/popup-stream-report.json\n'
         '            viewer-macos/build/popup-composer.png\n'),
        ('          path: release/0.2.0-alpha.1/\n', '          path: release/0.2.1-messages.1/\n'),
        ('          if ($process.ExitCode -ne 0) { throw "Viewer tests failed: $($process.ExitCode)" }\n',
         '          if ($process.ExitCode -ne 0) { throw "Viewer tests failed: $($process.ExitCode)" }\n'
         "          $popup = Start-Process -FilePath $viewer -ArgumentList '--popup-self-test' -Wait -PassThru -RedirectStandardOutput popup-self-test.json -RedirectStandardError popup-self-test-errors.txt\n"
         '          Get-Content popup-self-test.json\n'
         '          Get-Content popup-self-test-errors.txt\n'
         '          if ($popup.ExitCode -ne 0) { throw "Message tests failed: $($popup.ExitCode)" }\n'),
        ("          if ($LASTEXITCODE -ne 0) { throw 'Native Windows integration failed' }\n",
         "          if ($LASTEXITCODE -ne 0) { throw 'Native Windows integration failed' }\n"
         '          python tests/windows_popup_integration.py "binaries/$env:TEST_ARCH/Portlight.exe"\n'
         "          if ($LASTEXITCODE -ne 0) { throw 'Native Windows messaging integration failed' }\n"),
        ('          if ($process.ExitCode -ne 0) { throw "Visual capture failed: $($process.ExitCode)" }\n',
         '          if ($process.ExitCode -ne 0) { throw "Visual capture failed: $($process.ExitCode)" }\n'
         "          $popup = Start-Process -FilePath $viewer -ArgumentList @('--popup-visual-test', $output) -PassThru\n"
         "          if (-not $popup.WaitForExit(30000)) { $popup.Kill(); throw 'Message visual capture timed out' }\n"
         '          $popup.Refresh()\n'
         '          if ($popup.ExitCode -ne 0) { throw "Message visual capture failed: $($popup.ExitCode)" }\n'),
        ('          name: windows-design-review-${{ matrix.arch }}\n          path: design-review/\n',
         '          name: windows-design-review-${{ matrix.arch }}\n          path: |\n'
         '            design-review/\n            *self-test*.json\n'
         '            *self-test-errors.txt\n            tests/windows-popup-report.json\n'),
    ),
}


def baseline(path: str) -> str:
    return HOST_BASELINE if path.startswith("server-macos/") or path == "benchmarks/EncoderValidation.swift" else CLIENT_BASELINE


def released(path: str) -> bytes:
    return subprocess.check_output(
        ["git", "show", f"{baseline(path)}:{path}"], cwd=ROOT
    )


def baseline_paths() -> list[str]:
    output = subprocess.check_output(
        ["git", "ls-tree", "-rz", "--name-only", CLIENT_BASELINE], cwd=ROOT
    )
    return [path.decode() for path in output.split(b"\0")
            if path and path.decode() not in REMOVED_HOST_FILES]


def remove_hooks(path: str, current: bytes) -> bytes:
    for before, after in HOOKS.get(path, ()):
        old, new = before.encode(), after.encode()
        count = current.count(new)
        if count != 1:
            raise AssertionError(
                f"{path}: approved hook must occur exactly once, found {count}: "
                f"{after.splitlines()[0]}"
            )
        current = current.replace(new, old, 1)
    return current


def difference(path: str, expected: bytes, actual: bytes) -> str:
    try:
        before, after = expected.decode().splitlines(), actual.decode().splitlines()
    except UnicodeDecodeError:
        return (
            f"{path}: binary content changed; "
            f"expected SHA-256 {hashlib.sha256(expected).hexdigest()}, "
            f"got {hashlib.sha256(actual).hexdigest()}"
        )
    lines = difflib.unified_diff(
        before, after,
        fromfile=f"{baseline(path)[:7]}/{path}",
        tofile=f"working-tree/{path} (approved hooks removed)", lineterm="",
    )
    return "\n".join(list(lines)[:80])


def check() -> int:
    failures = []
    paths = baseline_paths()
    for path in REMOVED_HOST_FILES:
        if (ROOT / path).exists():
            failures.append(f"{path}: absent from the preserved Host and must remain absent")
    for path in paths:
        try:
            expected = released(path)
            actual = remove_hooks(path, (ROOT / path).read_bytes())
            if actual != expected:
                failures.append(difference(path, expected, actual))
        except (AssertionError, OSError, subprocess.CalledProcessError) as error:
            failures.append(str(error))
    if failures:
        print("FAIL: messaging preservation gate")
        print("\n\n".join(failures))
        return 1
    print(
        f"PASS: {len(paths) - len(HOOKS)} complete tracked files byte-identical to their baseline; "
        f"{len(HOOKS)} hooked core files byte-identical after removing "
        f"{sum(map(len, HOOKS.values()))} exact approved messaging hooks."
    )
    return 0


def self_test() -> int:
    """Show that allowances cannot hide core edits or moved/duplicated hooks."""
    tested = 0
    relocated = 0
    for path, edits in HOOKS.items():
        original = released(path)
        current = (ROOT / path).read_bytes()
        assert remove_hooks(path, current) == original, path
        assert remove_hooks(path, current + b"\n") != original, path
        for before, after in edits:
            assert original.count(before.encode()) == 1, (path, before)
            try:
                remove_hooks(path, current + after.encode())
            except AssertionError:
                pass
            else:
                raise AssertionError(f"Duplicate hook escaped preservation: {path}")
            tested += 1
            if before in after:
                insertion = after.replace(before, "", 1).encode()
                moved = current.replace(after.encode(), before.encode(), 1) + insertion
                try:
                    normalized = remove_hooks(path, moved)
                except AssertionError:
                    pass
                else:
                    assert normalized != original, f"Relocated hook escaped: {path}"
                relocated += 1
    print(
        f"PASS: preservation gate rejects unapproved core edits, "
        f"{tested} duplicated hooks, and {relocated} relocated insertions"
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1:] != ["--self-test"]:
        raise SystemExit("Usage: messaging_preservation.py [--self-test]")
    raise SystemExit(self_test() if len(sys.argv) > 1 else check())
