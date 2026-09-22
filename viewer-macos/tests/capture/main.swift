import AppKit

final class CaptureTest: NSObject, NSApplicationDelegate {
    private var viewer: ViewerController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count > 1 else { exit(2) }
        let controller = ViewerController(); viewer = controller
        controller.configureScreenshot(stage: "session", appearance: "dark", minimum: false, popover: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = controller.window else { exit(3) }
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), CommandLine.arguments[1]]
            do { try capture.run(); capture.waitUntilExit() } catch { fputs("Native window capture failed: \(error)\n", stderr); exit(4) }
            controller.prepareToQuit { exit(capture.terminationStatus) }
        }
    }
}

let app = NSApplication.shared
let delegate = CaptureTest(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
