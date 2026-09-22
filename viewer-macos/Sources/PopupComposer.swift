import AppKit
import CoreFoundation

struct ViewerPopupDisplay: Equatable {
    let id: String
    let name: String
    let index: Int
    var label: String { "Screen \(index) · \(name)" }
}

struct ViewerPopupFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ViewerPopupText {
    static let font = NSFont(name: "Helvetica-Bold", size: 22) ?? .boldSystemFont(ofSize: 22)
    static let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    static let durations = [5, 10, 20, 30, 60, 120, 300, 600, 1800, 3600, 10800]
    static func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
    static func integer(_ object: Any?) -> Int? {
        guard let value = object as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue >= 0, value.doubleValue <= 10800 else { return nil }
        return value.intValue
    }
    static func validate(_ text: String, maximum: Int = 250, allowEmpty: Bool = false) throws {
        guard text.unicodeScalars.count <= maximum, text.utf8.count <= 4000,
              allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ViewerPopupFailure(message: "Write a message of 1 to \(maximum) characters.")
        }
        guard !text.unicodeScalars.contains(where: {
            let n = $0.value
            return (n < 32 && n != 9 && n != 10) || n == 127 || n == 0x061C || n == 0x200E || n == 0x200F ||
                (0x202A...0x202E).contains(n) || (0x2066...0x2069).contains(n)
        }) else { throw ViewerPopupFailure(message: "Remove unsupported control characters before sending.") }
    }
    static func colorHex(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return "#FFFFFF" }
        func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
    static func color(_ hex: String) -> NSColor? {
        guard hex.utf8.count == 7, hex.first == "#", hex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func payload(_ text: NSAttributedString, duration: Int, maximum: Int = 250, richText: Bool = true, allowEmpty: Bool = false) throws -> [String: Any] {
        try validate(text.string, maximum: maximum, allowEmpty: allowEmpty)
        guard (0...10800).contains(duration) else { throw ViewerPopupFailure(message: "Choose a duration of up to three hours.") }
        var runs: [[String: Any]] = []
        var offset = 0
        var currentStart = 0, currentLength = 0
        var currentColor = "#FFFFFF", currentUnderline = false
        func flush() {
            if currentLength > 0 && (currentColor != "#FFFFFF" || currentUnderline) {
                runs.append(["start": currentStart, "length": currentLength, "color": currentColor, "underline": currentUnderline])
            }
        }
        for scalar in text.string.unicodeScalars {
            let color = richText ? colorHex(text.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor) : "#FFFFFF"
            let underline = richText && ((text.attribute(.underlineStyle, at: offset, effectiveRange: nil) as? Int ?? 0) != 0)
            let length = scalar.value > 0xFFFF ? 2 : 1
            if currentLength > 0 && (color != currentColor || underline != currentUnderline) { flush(); currentLength = 0 }
            if currentLength == 0 { currentStart = offset; currentColor = color; currentUnderline = underline }
            currentLength += length; offset += length
        }
        flush()
        return ["type": "popupMessage", "text": text.string, "durationSeconds": duration, "runs": runs]
    }
    static func restore(_ object: [String: Any]) throws -> NSAttributedString {
        guard let text = object["text"] as? String, normalized(text) == text else { throw ViewerPopupFailure(message: "Saved message is invalid.") }
        try validate(text, allowEmpty: true)
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let units = Array(text.utf16)
        let runs = object["runs"] as? [[String: Any]] ?? []
        guard runs.count <= 250 else { throw ViewerPopupFailure(message: "Saved formatting is invalid.") }
        var previousEnd = 0
        func boundary(_ index: Int) -> Bool {
            index == 0 || index == units.count || !((0xD800...0xDBFF).contains(units[index - 1]) && (0xDC00...0xDFFF).contains(units[index]))
        }
        for run in runs {
            guard let start = integer(run["start"]), let length = integer(run["length"]), length > 0,
                  start >= previousEnd, start <= units.count, length <= units.count - start,
                  boundary(start), boundary(start + length), let color = color(run["color"] as? String ?? "#FFFFFF") else {
                throw ViewerPopupFailure(message: "Saved formatting is invalid.")
            }
            result.addAttributes([.foregroundColor: color, .underlineStyle: run["underline"] as? Bool == true ? NSUnderlineStyle.single.rawValue : 0], range: NSRange(location: start, length: length))
            previousEnd = start + length
        }
        return result
    }
    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

private final class PopupEditor: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        if event.charactersIgnoringModifiers?.lowercased() == "z", modifiers == .command || modifiers == [.command, .shift] {
            if modifiers.contains(.shift) {
                if undoManager?.canRedo == true { undoManager?.redo() }
            } else if undoManager?.canUndo == true { undoManager?.undo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class PopupComposerController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let editor = PopupEditor()
    private let countLabel = NSTextField(labelWithString: "0 / 250")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let persistentButton = NSButton(title: "Popup Message", target: nil, action: nil)
    private let timedButton = NSButton(title: "Popup for 20s", target: nil, action: nil)
    private let durationButton = NSButton(title: "", target: nil, action: nil)
    private let underlineButton = NSButton(title: "Underline", target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let clearButton = NSButton(title: "Clear Message", target: nil, action: nil)
    private let screenStack = NSStackView()
    private let screenHint = NSTextField(wrappingLabelWithString: "Connect to a Host to choose message screens.")
    private var screenButtons: [String: NSButton] = [:]
    private var displays: [ViewerPopupDisplay] = []
    private var selectedDisplays = Set<String>()
    private var targetDisplays = false
    private let defaults: UserDefaults?
    private let draftKey = "SU.Remote.PopupDraft.v1"
    private(set) var duration = 20
    private(set) var maximum = 250
    private var maxDuration = 10800
    private var richText = true
    private var available = false
    private var changingText = false
    var onSend: (([String: Any]) -> Void)?
    var onClear: (() -> Void)?
    var onTargetDisplays: (([String]) -> Void)?
    var draft: NSAttributedString { editor.attributedString() }
    var status: String { statusLabel.stringValue }
    var sendingEnabled: Bool { persistentButton.isEnabled && timedButton.isEnabled }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Send message"; window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        buildUI()
        if let data = defaults?.data(forKey: draftKey), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let restored = try? ViewerPopupText.restore(object) {
            editor.textStorage?.setAttributedString(restored)
            if let saved = ViewerPopupText.integer(object["durationSeconds"]), ViewerPopupText.durations.contains(saved) { duration = saved }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "Message on the Host’s screens")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "Select text to change its color or underline it.")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let scroll = NSScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        editor.isRichText = true; editor.importsGraphics = false; editor.allowsUndo = true
        editor.font = ViewerPopupText.font; editor.textColor = .white; editor.backgroundColor = NSColor(white: 0.12, alpha: 1)
        editor.textContainerInset = NSSize(width: 12, height: 12); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.typingAttributes = ViewerPopupText.attributes; editor.delegate = self
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityLabel("Popup message text, up to 250 characters")
        scroll.documentView = editor
        colorWell.color = .white; colorWell.target = self; colorWell.action = #selector(colorAction)
        colorWell.setAccessibilityLabel("Selected message text color"); colorWell.toolTip = "Text color"
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        underlineButton.target = self; underlineButton.action = #selector(underlineAction); underlineButton.bezelStyle = .rounded
        underlineButton.keyEquivalent = "u"; underlineButton.keyEquivalentModifierMask = [.command]
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); countLabel.textColor = .secondaryLabelColor
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let formatting = NSStackView(views: [colorWell, underlineButton, spacer, countLabel]); formatting.spacing = 8
        persistentButton.target = self; persistentButton.action = #selector(sendPersistent); persistentButton.bezelStyle = .rounded
        timedButton.target = self; timedButton.action = #selector(sendTimed); timedButton.bezelStyle = .rounded
        durationButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Message duration")
        durationButton.bezelStyle = .rounded; durationButton.target = self; durationButton.action = #selector(durationAction)
        durationButton.toolTip = "Choose message duration"; durationButton.setAccessibilityLabel("Choose message duration")
        clearButton.target = self; clearButton.action = #selector(clearAction); clearButton.bezelStyle = .rounded
        let timed = NSStackView(views: [timedButton, durationButton]); timed.spacing = 0
        let actionSpacer = NSView(); actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [clearButton, actionSpacer, persistentButton, timed]); actions.spacing = 8
        let screenHeading = NSTextField(labelWithString: "Show message on")
        screenHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        screenStack.orientation = .vertical; screenStack.alignment = .leading; screenStack.spacing = 4
        let screenScroll = NSScrollView(); screenScroll.hasVerticalScroller = true; screenScroll.drawsBackground = false
        screenStack.translatesAutoresizingMaskIntoConstraints = false; screenScroll.documentView = screenStack
        NSLayoutConstraint.activate([screenStack.leadingAnchor.constraint(equalTo: screenScroll.contentView.leadingAnchor), screenStack.topAnchor.constraint(equalTo: screenScroll.contentView.topAnchor), screenStack.widthAnchor.constraint(equalTo: screenScroll.widthAnchor), screenScroll.heightAnchor.constraint(equalToConstant: 56)])
        screenHint.font = .systemFont(ofSize: 11); screenHint.textColor = .secondaryLabelColor
        let screens = NSStackView(views: [screenHeading, screenScroll, screenHint]); screens.orientation = .vertical; screens.alignment = .leading; screens.spacing = 4
        screenScroll.widthAnchor.constraint(equalTo: screens.widthAnchor).isActive = true
        screenHint.widthAnchor.constraint(equalTo: screens.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor; statusLabel.maximumNumberOfLines = 2
        let stack = NSStackView(views: [heading, note, scroll, formatting, screens, statusLabel, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20), scroll.heightAnchor.constraint(equalToConstant: 158), statusLabel.heightAnchor.constraint(equalToConstant: 34)])
        for view in [note, scroll, formatting, screens, statusLabel, actions] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    func configure(connected: Bool, capability: [String: Any]?) {
        available = connected && capability != nil
        maximum = min(250, max(1, ViewerPopupText.integer(capability?["maxCharacters"]) ?? 250))
        maxDuration = min(10800, max(1, ViewerPopupText.integer(capability?["maxDurationSeconds"]) ?? 10800))
        richText = capability?["richText"] as? Bool == true
        targetDisplays = capability?["targetDisplays"] as? Bool == true
        screenHint.stringValue = !connected ? "Connect to a Host to choose message screens." : (targetDisplays ? "Keep at least one screen checked. These choices are separate from the screens you view." : "This Host uses its saved message screens. Update the Host to choose them here.")
        if duration > maxDuration { duration = min(20, maxDuration) }
        statusLabel.stringValue = !connected ? "Connect to a Portlight Host to send a message." : (available ? "Messages clear after three hours at the latest." : "Update Portlight Host to use popup messages.")
        refresh()
    }
    func setDisplays(_ available: [ViewerPopupDisplay], selected: Set<String>) {
        selectedDisplays = selected.intersection(Set(available.map(\.id)))
        if displays != available {
            displays = available
            for view in screenStack.arrangedSubviews { screenStack.removeArrangedSubview(view); view.removeFromSuperview() }
            screenButtons.removeAll()
            for display in displays {
                let checkbox = NSButton(checkboxWithTitle: display.label, target: self, action: #selector(screenAction(_:)))
                checkbox.identifier = NSUserInterfaceItemIdentifier(display.id)
                checkbox.setAccessibilityLabel("Show message on \(display.label)")
                screenStack.addArrangedSubview(checkbox); screenButtons[display.id] = checkbox
            }
        }
        refreshScreenButtons()
    }
    private func refreshScreenButtons() {
        for (id, checkbox) in screenButtons { checkbox.state = selectedDisplays.contains(id) ? .on : .off; checkbox.isEnabled = available && targetDisplays }
    }
    @objc private func screenAction(_ checkbox: NSButton) {
        guard available, targetDisplays, let id = checkbox.identifier?.rawValue else { return }
        var selected = selectedDisplays
        if checkbox.state == .on { selected.insert(id) } else { selected.remove(id) }
        guard !selected.isEmpty else { checkbox.state = .on; screenHint.stringValue = "Keep at least one screen checked."; return }
        selectedDisplays = selected; refreshScreenButtons()
        screenHint.stringValue = "Keep at least one screen checked. These choices are separate from the screens you view."
        onTargetDisplays?(displays.map(\.id).filter { selected.contains($0) })
    }
    override func showWindow(_ sender: Any?) { super.showWindow(sender); window?.makeKeyAndOrderFront(sender); window?.makeFirstResponder(editor) }
    func setDraft(_ text: NSAttributedString) { editor.textStorage?.setAttributedString(text); refresh(); save() }
    func setStatus(_ text: String, error: Bool = false) { statusLabel.stringValue = text; statusLabel.textColor = error ? .systemRed : .secondaryLabelColor }
    func receivedState(active: Bool, duration: Int) { setStatus(active ? (duration == 0 ? "Message displayed. It stays until cleared, up to three hours." : "Message displayed for \(ViewerPopupText.durationLabel(duration)).") : "Message cleared.") }
    private func refresh() {
        let count = editor.string.unicodeScalars.count
        countLabel.stringValue = "\(count) / \(maximum)"
        let valid = (try? ViewerPopupText.validate(editor.string, maximum: maximum)) != nil
        persistentButton.isEnabled = available && valid; timedButton.isEnabled = available && valid
        clearButton.isEnabled = available; durationButton.isEnabled = available
        colorWell.isEnabled = richText; underlineButton.isEnabled = richText
        timedButton.title = "Popup for \(ViewerPopupText.durationLabel(duration))"
        refreshScreenButtons()
    }
    private func save() {
        guard let defaults, let payload = try? ViewerPopupText.payload(draft, duration: duration, allowEmpty: true),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        defaults.set(data, forKey: draftKey)
    }
    func windowWillClose(_ notification: Notification) { colorWell.deactivate(); save() }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !changingText, let replacementString else { return true }
        let normalized = ViewerPopupText.normalized(replacementString)
        let proposed = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: normalized)
        do { try ViewerPopupText.validate(proposed, maximum: maximum, allowEmpty: true) }
        catch { setStatus(error.localizedDescription, error: true); NSSound.beep(); return false }
        if normalized != replacementString { textView.insertText(normalized, replacementRange: affectedCharRange); return false }
        return true
    }
    func textDidChange(_ notification: Notification) {
        guard !changingText else { return }
        changingText = true
        if let storage = editor.textStorage, storage.length > 0 {
            storage.addAttribute(.font, value: ViewerPopupText.font, range: NSRange(location: 0, length: storage.length))
        }
        changingText = false; refresh(); save()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        let selection = editor.selectedRange()
        if selection.location < (editor.textStorage?.length ?? 0), let storage = editor.textStorage {
            colorWell.color = storage.attribute(.foregroundColor, at: selection.location, effectiveRange: nil) as? NSColor ?? .white
            underlineButton.state = (storage.attribute(.underlineStyle, at: selection.location, effectiveRange: nil) as? Int ?? 0) != 0 ? .on : .off
        }
    }
    private func apply(_ attributes: [NSAttributedString.Key: Any]) {
        let range = editor.selectedRange()
        if range.length > 0, let storage = editor.textStorage {
            let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            replacement.addAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
            replaceFormatting(replacement, range: range)
        }
        else { editor.typingAttributes.merge(attributes) { _, new in new } }
        window?.makeFirstResponder(editor); refresh(); save()
    }
    private func replaceFormatting(_ replacement: NSAttributedString, range: NSRange) {
        guard let storage = editor.textStorage, range.location >= 0, NSMaxRange(range) <= storage.length else { return }
        let previous = storage.attributedSubstring(from: range)
        editor.undoManager?.registerUndo(withTarget: self) { target in target.replaceFormatting(previous, range: range) }
        editor.undoManager?.setActionName("Message formatting")
        storage.replaceCharacters(in: range, with: replacement)
        editor.setSelectedRange(range); editor.didChangeText()
    }
    @objc private func colorAction() { apply([.foregroundColor: colorWell.color.withAlphaComponent(1)]) }
    @objc private func underlineAction() {
        let range = editor.selectedRange()
        let value = range.location < (editor.textStorage?.length ?? 0) ? (editor.textStorage?.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) : (editor.typingAttributes[.underlineStyle] as? Int ?? 0)
        apply([.underlineStyle: value == 0 ? NSUnderlineStyle.single.rawValue : 0]); underlineButton.state = value == 0 ? .on : .off
    }
    @objc private func durationAction() {
        let menu = NSMenu()
        for seconds in ViewerPopupText.durations where seconds <= maxDuration {
            let item = NSMenuItem(title: ViewerPopupText.durationLabel(seconds), action: #selector(selectDuration(_:)), keyEquivalent: "")
            item.target = self; item.tag = seconds; item.state = duration == seconds ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: durationButton.bounds.minY - 4), in: durationButton)
    }
    @objc private func selectDuration(_ item: NSMenuItem) { duration = item.tag; refresh(); save() }
    @objc private func clearAction() { if available { onClear?() } }
    @objc private func sendPersistent() { send(duration: 0) }
    @objc private func sendTimed() { send(duration: duration) }
    func send(duration: Int) {
        guard available else { return }
        do {
            let payload = try ViewerPopupText.payload(draft, duration: duration, maximum: maximum, richText: richText)
            guard duration <= maxDuration else { throw ViewerPopupFailure(message: "This Host supports shorter message durations.") }
            save(); setStatus("Sending message…"); onSend?(payload)
        } catch { setStatus(error.localizedDescription, error: true) }
    }
}
