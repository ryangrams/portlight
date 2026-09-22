import AppKit

func field<T>(_ object: Any, _ name: String, as: T.Type = T.self) -> T? {
    Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

final class StreamTest: NSObject, NSApplicationDelegate {
    private var viewer: ViewerController!
    private var timer: Timer?
    private var began = Date()
    private var lastFrame = Date()
    private var maximumGap = 0.0
    private var frames = 0
    private var popupEvents: [(Bool, Int)] = []
    private var targetEvents: [[String]] = []
    private var canvasIDs: [String: ObjectIdentifier] = [:]
    private var surfaceIDs: [String: ObjectIdentifier] = [:]
    private var revision: Int?
    private var stages = Set<Int>()
    private var failures = Set<String>()
    private var samples = 0
    private var seconds = 120.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.count >= 4, let port = Int(args[1]) else { exit(2) }
        if args.count > 4 { seconds = Double(args[4]) ?? 120 }
        let password = readLine() ?? ""
        viewer = ViewerController()
        viewer.configureScreenshot(stage: "setup", appearance: "light", minimum: false, popover: nil)
        guard let transport: RemoteTransport = field(viewer!, "transport"),
              let host: NSTextField = field(viewer!, "hostField"),
              let portField: NSTextField = field(viewer!, "portField"),
              let passwordField: NSSecureTextField = field(viewer!, "passwordField") else { exit(3) }
        host.stringValue = "127.0.0.1"; portField.stringValue = String(port); passwordField.stringValue = password
        transport.testFingerprint = args[2]
        let handler = transport.onMessage
        transport.onMessage = { [weak self] object, data in
            guard let self else { return }
            handler?(object, data)
            if object["type"] as? String == "frame" {
                if self.frames > 0 { self.maximumGap = max(self.maximumGap, Date().timeIntervalSince(self.lastFrame)) }
                self.frames += 1; self.lastFrame = Date()
            }
            if object["type"] as? String == "popupMessageState", let active = object["active"] as? Bool {
                self.popupEvents.append((active, object["durationSeconds"] as? Int ?? -1))
                self.targetEvents.append(object["displayIDs"] as? [String] ?? [])
            }
        }
        began = Date()
        viewer.perform(NSSelectorFromString("connectAction"))
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick(report: args[3]) }
    }

    private var messageWindow: NSWindow? { NSApp.windows.first { $0.title == "Send message" } }
    private func button(_ title: String) -> NSButton? {
        messageWindow?.contentView.flatMap { descendants($0).compactMap { $0 as? NSButton }.first { $0.title == title } }
    }
    private func click(_ title: String) {
        guard let button = button(title), button.isEnabled else { failures.insert("Button unavailable: \(title)"); return }
        button.performClick(nil)
    }
    private func screen(_ id: String) -> NSButton? {
        messageWindow?.contentView.flatMap { descendants($0).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id } }
    }
    private func clickScreen(_ id: String) {
        guard let checkbox = screen(id), checkbox.isEnabled else { failures.insert("Message screen checkbox unavailable: \(id)"); return }
        checkbox.performClick(nil)
    }
    private func once(_ stage: Int, elapsed: Double, action: () -> Void) {
        if elapsed >= Double(stage), stages.insert(stage).inserted { action() }
    }
    private func tick(report: String) {
        let elapsed = Date().timeIntervalSince(began)
        once(1, elapsed: elapsed) {
            guard let map: DisplayMap = field(viewer!, "map") else { failures.insert("Display map is missing"); return }
            map.onToggle?("fixture-2"); map.onToggle?("fixture-3")
        }
        once(3, elapsed: elapsed) {
            viewer.perform(NSSelectorFromString("messageAction"))
            guard let editor = messageWindow?.contentView.flatMap({ descendants($0).compactMap { $0 as? NSTextView }.first }) else { failures.insert("Composer editor missing"); return }
            editor.textStorage?.setAttributedString(NSAttributedString(string: "Message while the picture keeps running", attributes: ViewerPopupText.attributes)); editor.didChangeText()
            click("Popup Message")
        }
        once(4, elapsed: elapsed) { clickScreen("fixture-2") }
        once(5, elapsed: elapsed) { clickScreen("fixture-1") }
        once(6, elapsed: elapsed) {
            clickScreen("fixture-2")
            if screen("fixture-2")?.state != .on { failures.insert("Last message screen could be unchecked") }
            if field(viewer!, "selected", as: Set<String>.self) != ["fixture-1"] { failures.insert("Message routing changed viewed screens") }
        }
        once(7, elapsed: elapsed) { click("Clear Message") }
        once(8, elapsed: elapsed) { click("Popup for 20s") }
        once(10, elapsed: elapsed) { messageWindow?.performClose(nil) }
        once(29, elapsed: elapsed) { viewer.perform(NSSelectorFromString("messageAction")) }
        once(30, elapsed: elapsed) { clickScreen("fixture-1") }
        once(31, elapsed: elapsed) { clickScreen("fixture-2") }
        once(32, elapsed: elapsed) { click("Popup Message") }
        once(34, elapsed: elapsed) { click("Clear Message") }
        once(36, elapsed: elapsed) { messageWindow?.performClose(nil) }
        if elapsed >= 2 {
            samples += 1
            if field(viewer!, "ready", as: Bool.self) != true { failures.insert("Stream disconnected") }
            let currentRevision: Int = field(viewer!, "revision") ?? -1
            if revision == nil { revision = currentRevision }
            if currentRevision != revision { failures.insert("Subscription changed without a display change") }
            let canvases: [String: MonitorCanvas] = field(viewer!, "canvases") ?? [:]
            if canvases.isEmpty { failures.insert("Canvas disappeared") }
            for (id, canvas) in canvases {
                let identity = ObjectIdentifier(canvas)
                if let previous = canvasIDs[id], previous != identity { failures.insert("Canvas was rebuilt") }
                canvasIDs[id] = identity
                if let context: CGContext = field(canvas, "surface") {
                    let surface = ObjectIdentifier(context)
                    if let previous = surfaceIDs[id], previous != surface { failures.insert("Image surface was reset") }
                    surfaceIDs[id] = surface
                } else { failures.insert("Image surface is missing") }
            }
            if field(viewer!, "rejectedFrames", as: Int.self) != 0 { failures.insert("Image decoding rejected a frame") }
        }
        guard elapsed >= seconds else { return }
        timer?.invalidate()
        if frames == 0 { failures.insert("No frames received") }
        maximumGap = max(maximumGap, Date().timeIntervalSince(lastFrame))
        if maximumGap > 5 { failures.insert("Frame gap exceeded five seconds") }
        if popupEvents.filter({ $0.0 && $0.1 == 0 }).count < 2 { failures.insert("Persistent popup did not arrive") }
        if !popupEvents.contains(where: { $0.0 && $0.1 == 20 }) { failures.insert("20-second popup did not arrive") }
        if popupEvents.filter({ !$0.0 }).count < 4 { failures.insert("Manual clear or timed expiry missing") }
        if !targetEvents.contains(where: { Set($0) == ["fixture-1", "fixture-2"] }) || !targetEvents.contains(where: { $0 == ["fixture-2"] }) { failures.insert("Native message screen choices did not reach the Host") }
        let result: [String: Any] = ["passed": failures.isEmpty, "failures": failures.sorted(), "durationSeconds": elapsed, "sampleCount": samples, "framePackets": frames, "decodedFrames": field(viewer!, "totalFrames", as: Int.self) ?? 0, "maximumFrameGapSeconds": maximumGap, "subscriptionRevision": revision ?? -1, "messageDisplayEvents": targetEvents, "viewedDisplays": Array(field(viewer!, "selected", as: Set<String>.self) ?? []).sorted(), "popupEvents": popupEvents.map { ["active": $0.0, "durationSeconds": $0.1] as [String: Any] }]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: report)) }
        viewer.prepareToQuit { exit(self.failures.isEmpty ? 0 : 1) }
    }
}

let app = NSApplication.shared
let delegate = StreamTest()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
