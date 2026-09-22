import AppKit

final class OverlayCheck: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var overlay: PopupMessagePanel!
    var report: [String: Any] = [:]
    let output = CommandLine.arguments[1]

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Portlight overlay click-through check"
        window.isReleasedWhenClosed = false
        let button = NSButton(title: "Click through the banner", target: self, action: #selector(clicked))
        button.frame = NSRect(x: 180, y: 288, width: 400, height: 64)
        button.bezelStyle = .rounded
        window.contentView!.addSubview(button)
        let label = NSTextField(wrappingLabelWithString: "Test window only. Click the center of the message banner. The button underneath should receive the click. This test closes after a successful click or after two minutes.")
        label.frame = NSRect(x: 80, y: 100, width: 600, height: 100)
        window.contentView!.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showOverlay() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { self.finish(false) }
    }

    func showOverlay() {
        let message = try! PopupMessage(["text": "Click here to test", "durationSeconds": 20])
        let layout = PopupMessageLayout.fit(message, screenSize: CGSize(width: 760, height: 600))
        let content = window.contentRect(forFrameRect: window.frame)
        let rect = NSRect(x: content.minX, y: content.minY + 275, width: 760, height: layout.size.height)
        overlay = PopupMessagePanel(rect: rect, message: message, layout: layout)
        overlay.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let overlayIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == self.overlay.windowNumber }
            let targetIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == self.window.windowNumber }
            self.report = ["ignoresMouseEvents": self.overlay.ignoresMouseEvents,
                           "keptKeyboardFocus": NSApp.keyWindow === self.window,
                           "cannotBecomeKey": !self.overlay.canBecomeKey,
                           "windowServerOrderCorrect": overlayIndex != nil && targetIndex != nil && overlayIndex! < targetIndex!,
                           "overlayLevel": self.overlay.level.rawValue]
            print("READY: click through the message banner in the test window")
            fflush(stdout)
        }
    }

    @objc func clicked() {
        report["underlyingButtonReceivedClick"] = true
        let passed = ["ignoresMouseEvents", "keptKeyboardFocus", "cannotBecomeKey", "windowServerOrderCorrect"]
            .allSatisfy { report[$0] as? Bool == true }
        finish(passed)
    }

    func finish(_ passed: Bool) {
        report["passed"] = passed
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output))
        }
        overlay?.close()
        window?.close()
        exit(passed ? 0 : 1)
    }
}

guard CommandLine.arguments.count == 2 else { fatalError("Provide a test report path.") }
let application = NSApplication.shared
let delegate = OverlayCheck()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
