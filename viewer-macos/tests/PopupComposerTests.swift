import AppKit

func popupComposerSelfTest() throws {
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw ViewerPopupFailure(message: name) }
    }
    func rejects(_ text: String) throws {
        do { try ViewerPopupText.validate(text) }
        catch is ViewerPopupFailure { return }
        throw ViewerPopupFailure(message: "Accepted invalid message text")
    }
    try check(ViewerPopupText.normalized("A\r\nB\rC") == "A\nB\nC", "Normalize Windows and Mac line endings")
    for text in ["", " \t\n", "\u{200B}", String(repeating: "a", count: 251), String(repeating: "😀", count: 251), "A\u{202E}B", "A\0B"] { try rejects(text) }
    try ViewerPopupText.validate(String(repeating: "😀", count: 250))
    try ViewerPopupText.validate("e\u{301} 👩‍💻\n准备开始")
    let styled = NSMutableAttributedString(string: "A😀B", attributes: ViewerPopupText.attributes)
    styled.addAttributes([.foregroundColor: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.4), .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 1, length: 2))
    let payload = try ViewerPopupText.payload(styled, duration: 20)
    let runs = payload["runs"] as? [[String: Any]] ?? []
    try check(runs.count == 1 && runs[0]["start"] as? Int == 1 && runs[0]["length"] as? Int == 2, "UTF-16 scalar boundaries")
    try check(runs[0]["color"] as? String == "#FF8000" && runs[0]["underline"] as? Bool == true, "Selected color and underline")
    let restored = try ViewerPopupText.restore(payload)
    let restoredPayload = try ViewerPopupText.payload(restored, duration: 20)
    try check(NSDictionary(dictionary: payload).isEqual(to: restoredPayload), "Styled draft roundtrip")
    let plain = try ViewerPopupText.payload(styled, duration: 0, richText: false)
    try check((plain["runs"] as? [[String: Any]])?.isEmpty == true, "Host without rich-text support")
    let extended = NSColor(colorSpace: .extendedSRGB, components: [1.3, -0.2, 0.5, 1], count: 4)
    let extendedHex = ViewerPopupText.colorHex(extended)
    try check(extendedHex == "#FF0080" && ViewerPopupText.color(extendedHex) != nil, "Clamp extended picker colors")
    let split = NSMutableAttributedString(string: "😀", attributes: ViewerPopupText.attributes)
    split.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
    let splitRuns = try ViewerPopupText.payload(split, duration: 20)["runs"] as? [[String: Any]] ?? []
    try check(splitRuns.count == 1 && splitRuns[0]["length"] as? Int == 2, "Never split a surrogate pair in an outgoing run")
    do {
        _ = try ViewerPopupText.restore(["text": "😀", "runs": [["start": 0, "length": 1]]])
        throw ViewerPopupFailure(message: "Restored a split surrogate pair")
    } catch let error as ViewerPopupFailure {
        try check(error.message != "Restored a split surrogate pair", error.message)
    }
    let suite = "Portlight.PopupComposerTests." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { throw ViewerPopupFailure(message: "Could not create test preferences") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let saved = try ViewerPopupText.payload(styled, duration: 60)
    defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: "SU.Remote.PopupDraft.v1")
    let composer = PopupComposerController(defaults: defaults)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    guard let content = composer.window?.contentView,
          let clearButton = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Clear Message" }) else { throw ViewerPopupFailure(message: "Clear Message button is missing from the composer") }
    try check(composer.duration == 60 && composer.draft.string == "A😀B", "Restore text, styles, and chosen timer")
    composer.configure(connected: true, capability: nil)
    try check(!composer.sendingEnabled && composer.status.contains("Update Portlight Host"), "Older Host update explanation")
    composer.configure(connected: true, capability: ["maxCharacters": 250, "maxDurationSeconds": 10800, "richText": true])
    try check(composer.sendingEnabled, "Connected composer can send valid text")
    var outgoing: [[String: Any]] = []
    composer.onSend = { outgoing.append($0) }
    composer.send(duration: 0); composer.send(duration: 20)
    try check(outgoing.count == 2 && outgoing[0]["durationSeconds"] as? Int == 0 && outgoing[1]["durationSeconds"] as? Int == 20, "Persistent and timed sends")
    var clears = 0
    composer.onClear = { clears += 1 }
    clearButton.performClick(nil)
    try check(clears == 1 && composer.draft.string == "A😀B", "Clear Message button in composer preserves draft")
    composer.setDraft(NSAttributedString(string: "\u{200B}", attributes: ViewerPopupText.attributes))
    try check(!composer.sendingEnabled, "Invisible-only draft cannot send")
    composer.setDraft(styled)
    composer.configure(connected: false, capability: nil); composer.send(duration: 0)
    clearButton.performClick(nil)
    try check(clears == 1, "Disconnected Clear Message button is disabled")
    try check(outgoing.count == 2 && !composer.sendingEnabled, "Disconnect gates sends and retains draft")
    let reopened = PopupComposerController(defaults: defaults)
    try check(reopened.draft.string == styled.string && reopened.duration == 60, "Persist draft across composer instances")
    let formatting = PopupComposerController(defaults: nil)
    formatting.configure(connected: true, capability: ["maxCharacters": 250, "maxDurationSeconds": 10800, "richText": true])
    formatting.setDraft(NSAttributedString(string: "Selected words", attributes: ViewerPopupText.attributes))
    guard let formatContent = formatting.window?.contentView,
          let editor = descendants(formatContent).compactMap({ $0 as? NSTextView }).first,
          let color = descendants(formatContent).compactMap({ $0 as? NSColorWell }).first,
          let underline = descendants(formatContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Underline" }),
          let undo = editor.undoManager else { throw ViewerPopupFailure(message: "Formatting controls are missing") }
    editor.setSelectedRange(NSRange(location: 0, length: 8))
    undo.removeAllActions(); undo.beginUndoGrouping()
    color.color = .red
    NSApp.sendAction(color.action!, to: color.target, from: color)
    underline.performClick(nil)
    undo.endUndoGrouping()
    let formatted = try ViewerPopupText.payload(formatting.draft, duration: 0)
    let selectedRuns = formatted["runs"] as? [[String: Any]] ?? []
    try check(selectedRuns.count == 1 && selectedRuns[0]["length"] as? Int == 8 && selectedRuns[0]["color"] as? String == "#FF0000" && selectedRuns[0]["underline"] as? Bool == true, "Native color and underline controls style only the selection")
    guard let undoEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: formatting.window?.windowNumber ?? 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6) else { throw ViewerPopupFailure(message: "Could not create undo event") }
    try check(editor.performKeyEquivalent(with: undoEvent), "Composer handles its own undo shortcut")
    let undone = try ViewerPopupText.payload(formatting.draft, duration: 0)
    try check((undone["runs"] as? [[String: Any]])?.isEmpty == true, "Undo restores selected formatting")
    let targets = PopupComposerController(defaults: nil)
    targets.configure(connected: true, capability: ["maxCharacters": 250, "maxDurationSeconds": 10800, "richText": true, "targetDisplays": true])
    targets.setDraft(NSAttributedString(string: "Message targets", attributes: ViewerPopupText.attributes))
    targets.setDisplays([ViewerPopupDisplay(id: "one", name: "Main display", index: 1), ViewerPopupDisplay(id: "two", name: "Second display", index: 2)], selected: ["one"])
    guard let targetContent = targets.window?.contentView,
          let first = descendants(targetContent).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "one" }),
          let second = descendants(targetContent).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "two" }) else { throw ViewerPopupFailure(message: "Message screen checkboxes missing") }
    var routes: [[String]] = []
    targets.onTargetDisplays = { routes.append($0) }
    try check(first.state == .on && second.state == .off, "Host-selected default screen is checked")
    first.performClick(nil)
    try check(first.state == .on && routes.isEmpty, "Cannot uncheck the last message screen")
    second.performClick(nil)
    try check(routes == [["one", "two"]], "Both screens can be selected in the composer")
    first.performClick(nil)
    try check(routes.last == ["two"], "Second screen can be selected independently")
    second.performClick(nil)
    try check(routes.count == 2 && second.state == .on, "Last selected second screen stays checked")
    targets.configure(connected: true, capability: ["maxCharacters": 250, "maxDurationSeconds": 10800, "richText": true])
    try check(!first.isEnabled && !second.isEnabled && targets.sendingEnabled, "Older popup Host still sends with screen selection disabled")
    print("PASS popup composer text limits, rich text, saved draft, native sends, Clear Message, and independent screen selection")
}
