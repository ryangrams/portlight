import AppKit
import CoreFoundation
import Darwin

private func popupContinuousTime() -> TimeInterval {
    var scale = mach_timebase_info_data_t()
    mach_timebase_info(&scale)
    return Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1_000_000_000
}

struct PopupMessageFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PopupMessageRun {
    let range: NSRange
    let color: String
    let underline: Bool
}

struct PopupMessage {
    static let maxCharacters = 250
    static let maxDuration = 3 * 60 * 60
    static let capability: [String: Any] = ["maxCharacters": maxCharacters, "maxDurationSeconds": maxDuration, "richText": true, "targetDisplays": true]
    let text: String
    let runs: [PopupMessageRun]
    let durationSeconds: Int

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let numberValue = number.doubleValue
        guard numberValue.isFinite, numberValue.rounded() == numberValue,
              numberValue >= 0, numberValue <= Double(Int32.max) else { return nil }
        return Int(numberValue)
    }

    init(_ object: [String: Any]) throws {
        guard let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= Self.maxCharacters, text.utf8.count <= 4000 else {
            throw PopupMessageFailure(message: "Write a message of 1 to 250 characters.")
        }
        guard !text.unicodeScalars.contains(where: { scalar in
            let n = scalar.value
            return (n < 32 && n != 9 && n != 10) || n == 127 || n == 0x061C ||
                n == 0x200E || n == 0x200F || (0x202A...0x202E).contains(n) || (0x2066...0x2069).contains(n)
        }) else { throw PopupMessageFailure(message: "This message contains unsupported control characters.") }
        guard let duration = Self.integer(object["durationSeconds"]), duration <= Self.maxDuration else {
            throw PopupMessageFailure(message: "Choose a message duration of up to three hours.")
        }
        let rawRuns: [[String: Any]]
        if let value = object["runs"] {
            guard let value = value as? [[String: Any]], value.count <= Self.maxCharacters else {
                throw PopupMessageFailure(message: "Message formatting is invalid.")
            }
            rawRuns = value
        } else { rawRuns = [] }
        let units = Array(text.utf16)
        func boundary(_ index: Int) -> Bool {
            index == 0 || index == units.count || !((0xD800...0xDBFF).contains(units[index - 1]) && (0xDC00...0xDFFF).contains(units[index]))
        }
        var runs: [PopupMessageRun] = []
        var previousEnd = 0
        for raw in rawRuns {
            guard let start = Self.integer(raw["start"]), let length = Self.integer(raw["length"]),
                  start >= previousEnd, start <= units.count, length > 0, length <= units.count - start,
                  boundary(start), boundary(start + length) else {
                throw PopupMessageFailure(message: "Message formatting must stay within the selected text.")
            }
            let color: String
            if let value = raw["color"] {
                guard let value = value as? String, value.utf8.count == 7, value.first == "#",
                      value.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                    throw PopupMessageFailure(message: "Choose a valid message text color.")
                }
                color = value.uppercased()
            } else { color = "#FFFFFF" }
            let underline: Bool
            if let value = raw["underline"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw PopupMessageFailure(message: "Message underline formatting is invalid.")
                }
                underline = number.boolValue
            } else { underline = false }
            runs.append(PopupMessageRun(range: NSRange(location: start, length: length), color: color, underline: underline))
            previousEnd = start + length
        }
        self.text = text
        self.runs = runs
        durationSeconds = duration
    }

    func attributedText(fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let font = NSFont(name: "Helvetica-Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        for run in runs {
            let rgb = UInt32(run.color.dropFirst(), radix: 16) ?? 0xFFFFFF
            let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
            attributed.addAttributes([.foregroundColor: color, .underlineStyle: run.underline ? NSUnderlineStyle.single.rawValue : 0], range: run.range)
        }
        return attributed
    }
}

struct PopupTextLayout {
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer
    let bounds: CGRect
    init(message: PopupMessage, fontSize: CGFloat, width: CGFloat) {
        storage = NSTextStorage(attributedString: message.attributedText(fontSize: fontSize))
        manager = NSLayoutManager()
        container = NSTextContainer(size: NSSize(width: max(1, width), height: 1_000_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        bounds = manager.extraLineFragmentTextContainer == container ? used.union(manager.extraLineFragmentUsedRect) : used
    }
}

struct PopupMessageLayout {
    let size: CGSize
    let fontSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let textHeight: CGFloat

    static func fit(_ message: PopupMessage, screenSize: CGSize) -> PopupMessageLayout {
        let width = max(1, screenSize.width)
        let screenHeight = max(1, screenSize.height)
        let xPadding = min(width * 0.035, 72)
        let yPadding = screenHeight * 0.015
        let minHeight = screenHeight * 0.15
        let maxHeight = screenHeight * 0.35
        let referenceMessage = try! PopupMessage(["text": "Ag", "durationSeconds": 0])
        var referenceSize: CGFloat = 0.1
        var referenceHigh = screenHeight
        for _ in 0..<22 {
            let size = (referenceSize + referenceHigh) / 2
            let line = PopupTextLayout(message: referenceMessage, fontSize: size, width: 1_000_000)
            if line.bounds.height <= minHeight - yPadding * 2 { referenceSize = size }
            else { referenceHigh = size }
        }
        let innerWidth = max(1, width - xPadding * 2)
        let reference = PopupTextLayout(message: message, fontSize: referenceSize, width: innerWidth)
        let height = min(maxHeight, max(minHeight, ceil(reference.bounds.height + yPadding * 2)))
        let innerHeight = height - yPadding * 2
        var low: CGFloat = 0.1
        var high = screenHeight
        for _ in 0..<22 {
            let size = (low + high) / 2
            let candidate = PopupTextLayout(message: message, fontSize: size, width: innerWidth)
            if candidate.bounds.height <= innerHeight && candidate.bounds.width <= innerWidth + 0.01 { low = size }
            else { high = size }
        }
        let measured = PopupTextLayout(message: message, fontSize: low, width: innerWidth)
        return PopupMessageLayout(size: CGSize(width: width, height: height), fontSize: low, horizontalPadding: xPadding, verticalPadding: yPadding, textHeight: measured.bounds.height)
    }
}

final class PopupMessageView: NSView {
    let message: PopupMessage
    let layout: PopupMessageLayout
    override var isFlipped: Bool { true }
    init(message: PopupMessage, layout: PopupMessageLayout) {
        self.message = message
        self.layout = layout
        super.init(frame: CGRect(origin: .zero, size: layout.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(message.text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.8).setFill()
        bounds.fill()
        let text = PopupTextLayout(message: message, fontSize: layout.fontSize, width: bounds.width - layout.horizontalPadding * 2)
        let origin = CGPoint(x: layout.horizontalPadding, y: (bounds.height - text.bounds.height) / 2 - text.bounds.minY)
        let glyphs = text.manager.glyphRange(for: text.container)
        text.manager.drawBackground(forGlyphRange: glyphs, at: origin)
        text.manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}

final class PopupMessagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(rect: NSRect, message: PopupMessage, layout: PopupMessageLayout) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = PopupMessageView(message: message, layout: layout)
    }
}

final class PopupMessageController {
    private let fixture: Bool
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let continuousNow: () -> TimeInterval
    private var continuousDeadline: TimeInterval?
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var panels: [String: PopupMessagePanel] = [:]
    private(set) var displays: [DisplayInfo] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var message: PopupMessage?
    private(set) var expiresAt: Date?
    var onChange: (() -> Void)?
    var active: Bool { message != nil }
    var state: [String: Any] {
        ["type": "popupMessageState", "active": active, "expiresAt": expiresAt?.timeIntervalSince1970 ?? 0.0,
         "durationSeconds": message?.durationSeconds ?? 0, "displayIDs": displays.filter { selectedIDs.contains($0.id) }.map(\.id),
         "availableDisplays": displays.map { ["id": $0.id, "name": $0.name, "index": $0.index] as [String: Any] }]
    }

    init(fixture: Bool, defaults: UserDefaults? = .standard, now: @escaping () -> Date = Date.init,
         continuousNow: @escaping () -> TimeInterval = popupContinuousTime) {
        self.fixture = fixture
        self.defaults = fixture ? nil : defaults
        self.now = now
        self.continuousNow = continuousNow
        selectedIDs = Set(self.defaults?.stringArray(forKey: "popupMessageDisplays") ?? [])
        refreshDisplays()
        if !fixture {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.expireIfNeeded() }
        }
    }
    deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    func refreshDisplays(_ available: [DisplayInfo]? = nil) {
        let updated = available ?? availableDisplays(fixture: fixture)
        let signature: (DisplayInfo) -> String = { "\($0.id):\($0.cgID):\($0.name):\($0.width)x\($0.height):\($0.bounds)" }
        guard updated.map(signature) != displays.map(signature) else { return }
        displays = updated
        selectedIDs.formIntersection(Set(displays.map(\.id)))
        let preferred = fixture && available == nil ? displays.first : (displays.first(where: { $0.cgID == CGMainDisplayID() }) ?? displays.first)
        if selectedIDs.isEmpty, let preferred { selectedIDs.insert(preferred.id) }
        saveSelection()
        render()
        onChange?()
    }
    @discardableResult func toggleDisplay(_ id: String) -> Bool {
        guard displays.contains(where: { $0.id == id }) else { return false }
        if selectedIDs.contains(id) {
            guard selectedIDs.count > 1 else { return false }
            selectedIDs.remove(id)
        } else { selectedIDs.insert(id) }
        saveSelection()
        render()
        onChange?()
        return true
    }
    @discardableResult func selectDisplays(_ ids: [String]) throws -> Bool {
        let selection = Set(ids)
        guard !ids.isEmpty, ids.count <= 32, selection.count == ids.count,
              selection.isSubset(of: Set(displays.map(\.id))) else {
            throw PopupMessageFailure(message: "Select at least one available message screen.")
        }
        guard selection != selectedIDs else { return false }
        selectedIDs = selection
        saveSelection()
        render()
        onChange?()
        return true
    }
    private func saveSelection() { defaults?.set(displays.filter { selectedIDs.contains($0.id) }.map(\.id), forKey: "popupMessageDisplays") }
    func show(_ newMessage: PopupMessage) {
        timer?.invalidate()
        message = newMessage
        let lifetime = newMessage.durationSeconds == 0 ? PopupMessage.maxDuration : newMessage.durationSeconds
        expiresAt = now().addingTimeInterval(TimeInterval(lifetime))
        continuousDeadline = continuousNow() + TimeInterval(lifetime)
        let timer = Timer(timeInterval: min(1, TimeInterval(lifetime)), repeats: true) { [weak self] _ in self?.expireIfNeeded() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        render()
        onChange?()
    }
    func expireIfNeeded() {
        if let expiresAt, let continuousDeadline, now() >= expiresAt || continuousNow() >= continuousDeadline { clear() }
    }
    func clear() {
        timer?.invalidate()
        timer = nil
        message = nil
        expiresAt = nil
        continuousDeadline = nil
        closePanels()
        onChange?()
    }
    private func closePanels() { panels.values.forEach { $0.orderOut(nil); $0.close() }; panels.removeAll() }
    private func render() {
        guard !fixture, let message else { closePanels(); return }
        if let expiresAt, let continuousDeadline, now() >= expiresAt || continuousNow() >= continuousDeadline { clear(); return }
        var rendered = Set<String>()
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  selectedIDs.contains(displayID(id)) else { continue }
            let key = displayID(id)
            rendered.insert(key)
            let layout = PopupMessageLayout.fit(message, screenSize: screen.frame.size)
            let rect = NSRect(x: screen.frame.minX, y: screen.frame.maxY - layout.size.height, width: screen.frame.width, height: layout.size.height)
            let panel = panels[key] ?? PopupMessagePanel(rect: rect, message: message, layout: layout)
            if panels[key] != nil {
                panel.setFrame(rect, display: false)
                panel.contentView = PopupMessageView(message: message, layout: layout)
            }
            panel.orderFrontRegardless()
            panels[key] = panel
        }
        for id in Set(panels.keys).subtracting(rendered) {
            panels[id]?.orderOut(nil)
            panels[id]?.close()
            panels.removeValue(forKey: id)
        }
    }
}
