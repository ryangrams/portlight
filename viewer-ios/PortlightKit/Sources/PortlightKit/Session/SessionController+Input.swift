import Foundation

// Touch, keyboard, text and mouse controls. Everything runs on the main actor in call order: gesture
// effects → viewport (view points × contentScale) or ledger → `engine.send(input:)`.
extension SessionController {
    // MARK: Touches

    /// One raw touch event from the session surface (view points, event timestamp).
    public func touch(_ event: TouchEvent, at time: TimeInterval) {
        route(interpreter.handle(event, at: time, mapping: viewportModel))
        afterInput()
    }

    /// Display-link step: long-press and hold deadlines, trackpad motion start, scroll inertia.
    public func tick(at time: TimeInterval) {
        let effects = interpreter.tick(at: time, mapping: viewportModel)
        if !effects.isEmpty {
            route(effects)
            afterInput()
        }
        checkFreshRegion()
    }

    func route(_ effects: [InputEffect]) {
        var viewportMoved = false
        for effect in effects {
            switch effect {
            case .viewport(let change):
                let scale = viewportModel.contentScale
                switch change {
                case .pan(let dx, let dy):
                    viewportModel.pan(dx: dx * scale, dy: dy * scale)
                case .gesture(let from, let to, let factor):
                    viewportModel.gesture(from: DrawablePoint(x: from.x * scale, y: from.y * scale),
                                          to: DrawablePoint(x: to.x * scale, y: to.y * scale), factor: factor)
                }
                viewportMoved = true
            case .remote(let action):
                applyRemote(action)
            case .cursorMoved(let point):
                cursorStore.set(point)
            case .revealControls:
                controlsHidden = false
            case .feedback:
                break // haptics are the app's; nothing to decide here
            }
        }
        if viewportMoved { viewportDidChange() }
        publishLatches()
    }

    /// Gate, then ledger. Presses and scrolls also need valid pixels at their target: new or exposed
    /// regions (and a frozen frame after reconnecting) are not controllable until repainted.
    func applyRemote(_ action: RemoteAction) {
        switch action {
        case .press(_, let target), .scroll(let target, _, _):
            guard allowsRemoteInput,
                  dependencies.framebuffer.hasValidPixels(display: target.display, x: target.x, y: target.y) else {
                inputBlockedCount += 1
                // Nothing went down on the Mac, so end the drag or button latch that assumed it did: the UI must
                // never show a held button the host doesn't have.
                if case .press = action, interpreter.isDragging { interpreter.reset() }
                return
            }
        case .move:
            guard allowsRemoteInput else { return }
        case .release:
            break // the ledger sends nothing for a button the host isn't holding
        }
        send(ledger.apply(action, modifiers: &workingLatches))
    }

    /// Hands messages to the engine. Typed text still queued goes first, so the wire keeps the order in which the
    /// ledger produced everything; with input no longer allowed, that text is dropped instead.
    func send(_ messages: [OutboundMessage]) {
        guard !messages.isEmpty, connection != nil else { return }
        if !pendingTyping.isEmpty {
            if allowsRemoteInput { flushTyping() } else { cancelTyping() }
        }
        engine.send(input: messages)
    }

    /// Work that waits for released input runs as soon as nothing is held.
    func afterInput() {
        publishButtonLatch()
        if !ledger.isHoldingInput { runDeferredWork() }
    }

    /// A recovery resubscription and a deferred region refinement, at a safe input boundary.
    func runDeferredWork() {
        guard !ledger.isHoldingInput else { return }
        if pendingRecovery, phase == .connected {
            pendingRecovery = false
            submitDesired(force: true)
        }
        if scheduler.isDeferred, !interpreter.hasActiveTouches { evaluateRegions() }
    }

    // MARK: Keys and text

    /// A hardware key transition. Forward modifier keys (HID 0xE0–0xE7) as presses too; they are tracked
    /// as held hardware modifiers. `modifiers`, when given, are the event's modifier flags: a non-modifier
    /// key-down whose flags lack a modifier the ledger still holds means that modifier's key-up was lost
    /// (focus change), so everything is released before the key goes down.
    public func press(hidUsage: Int, characters: String, modifiers: Set<ModifierKey>? = nil, down: Bool) {
        guard let keysym = KeyMapping.keysym(forHIDUsage: hidUsage, charactersIgnoringModifiers: characters) else { return }
        if down {
            guard allowsRemoteInput else { inputBlockedCount += 1; return }
            if let modifiers, KeyMapping.modifierKey(forKeysym: keysym) == nil, !ledger.hardwareModifiers.isSubset(of: modifiers) {
                releaseInput()
            }
        }
        send(ledger.key(keysym: keysym, down: down, modifiers: &workingLatches))
        publishLatches()
        afterInput()
    }

    /// A key from the accessory palette (down and up, wrapped in the sticky modifiers).
    public func pressSoftKey(_ key: SoftKey) {
        guard allowsRemoteInput else { inputBlockedCount += 1; return }
        send(ledger.pressKey(keysym: key.keysym, modifiers: &workingLatches))
        publishLatches()
        afterInput()
    }

    /// Sticky modifier chip: Off → Latched → (double tap) Locked → Off.
    public func tapModifier(_ key: ModifierKey) {
        workingLatches.tap(key, at: now)
        send(ledger.modifiersChanged(workingLatches))
        publishLatches()
    }

    /// Committed text from the soft keyboard (a single character with modifiers becomes a chord). At most
    /// `maxTypedCharacters` characters of one commit are typed; see `typePastedText`.
    public func insertText(_ text: String) {
        guard allowsRemoteInput else { inputBlockedCount += 1; return }
        enqueueTyping(ledger.typeCommitted(boundedTyping(text), modifiers: &workingLatches))
        publishLatches()
        afterInput()
    }

    public func deleteBackward() { pressSoftKey(.backspace) }

    /// "Type Pasted Text": the text the app obtained from a paste control, typed in UTF-8-safe chunks. Never reads
    /// the pasteboard itself and never applies modifiers. At most `maxTypedCharacters` characters are typed (an
    /// alert says so when the paste was longer), `typingBatchMessages` messages per engine turn.
    public func typePastedText(_ text: String) {
        guard allowsRemoteInput else { inputBlockedCount += 1; return }
        enqueueTyping(ledger.text(boundedTyping(text)))
        afterInput()
    }

    // MARK: Typing (bounded, paced)

    /// Characters one paste or one committed insertion types at most (EXECUTION-PLAN §2, "bounded committed
    /// text"). The rest is dropped with a `SessionAlert.textTruncated`.
    public nonisolated static let maxTypedCharacters = 4096
    /// Unicode scalars examined at most while bounding, so a pathological paste (one grapheme with thousands of
    /// combining marks) can't make the character walk scan more than this, however long it is.
    nonisolated static let maxTypedScalars = 4 * maxTypedCharacters
    /// Messages handed to the engine per turn while typing. A 4,096-character paste is about 205 `text` messages
    /// (20 UTF-16 units each), or up to 8,192 key messages when it is all line breaks; batches keep every engine
    /// turn short, so frame ACKs and inbound messages interleave with a long paste.
    nonisolated static let typingBatchMessages = 64
    nonisolated static let typingBatchInterval: TimeInterval = 1.0 / 60

    /// The first `maxTypedCharacters` characters of `text`, and whether anything was cut. The work is bounded by
    /// `maxTypedScalars`, whatever the length of `text`.
    nonisolated static func boundedText(_ text: String) -> (text: String, truncated: Bool) {
        let scalars = text.unicodeScalars
        let scalarEnd = scalars.index(scalars.startIndex, offsetBy: maxTypedScalars, limitedBy: scalars.endIndex) ?? scalars.endIndex
        let scalarCut = scalarEnd != scalars.endIndex
        let capped = scalarCut ? String(scalars[..<scalarEnd]) : text
        var head = capped.prefix(maxTypedCharacters)
        let characterCut = head.endIndex != capped.endIndex
        // A scalar cut can split the last grapheme (an accent, a flag): drop that partial character.
        if scalarCut && !characterCut && !head.isEmpty { head = head.dropLast() }
        return (String(head), scalarCut || characterCut)
    }

    /// `boundedText`, posting `.textTruncated` when text was cut.
    func boundedTyping(_ text: String) -> String {
        let (head, truncated) = Self.boundedText(text)
        if truncated { post(.textTruncated(typedCharacters: head.count)) }
        return head
    }

    /// Queues typed messages behind any still waiting; the first batch goes out at once when none was scheduled.
    func enqueueTyping(_ messages: [OutboundMessage]) {
        guard !messages.isEmpty, connection != nil else { return }
        pendingTyping.append(contentsOf: messages)
        if timers[.typing] == nil { sendTypingBatch() }
    }

    /// One batch of typed text, while input is allowed (else the rest is dropped).
    func sendTypingBatch() {
        guard !pendingTyping.isEmpty else { return }
        guard allowsRemoteInput, connection != nil else { cancelTyping(); return }
        let end = Self.typingBatchEnd(pendingTyping, limit: Self.typingBatchMessages)
        let batch = Array(pendingTyping[..<end])
        pendingTyping.removeFirst(end)
        engine.send(input: batch)
        if !pendingTyping.isEmpty { schedule(.typing, after: Self.typingBatchInterval) }
    }

    /// Everything still queued, now (another input follows it).
    func flushTyping() {
        cancelTimer(.typing)
        let rest = pendingTyping
        pendingTyping = []
        if !rest.isEmpty { engine.send(input: rest) }
    }

    /// Drops typed text not yet sent (input turned off, session ended). It holds nothing on the Mac.
    func cancelTyping() {
        cancelTimer(.typing)
        pendingTyping = []
    }

    /// Where the next batch ends: after at least `limit` messages (or all of them), at a point where every key the
    /// batch pressed is up again. Dropping the rest can then never leave a key held on the Mac.
    nonisolated static func typingBatchEnd(_ messages: [OutboundMessage], limit: Int) -> Int {
        var held = Set<UInt32>()
        for (index, message) in messages.enumerated() {
            if case .key(let keysym, let down) = message {
                if down { held.insert(keysym) } else { held.remove(keysym) }
            }
            if index + 1 >= limit && held.isEmpty { return index + 1 }
        }
        return messages.count
    }

    // MARK: Mouse controls

    /// Explicit right/middle/left click at the cursor.
    public func click(_ button: MouseButtons) {
        route(interpreter.click(button, mapping: viewportModel))
        afterInput()
    }

    /// "Hold Left" / "Hold Right": press (Trackpad) or arm (Direct), or end the latch when active.
    public func toggleButtonLatch(_ button: MouseButtons) {
        let effects = buttonLatch != nil
            ? interpreter.releaseLatched(mapping: viewportModel)
            : interpreter.pressLatched(button, mapping: viewportModel)
        route(effects)
        afterInput()
    }

    // MARK: Release

    /// Releases every held button, key and modifier on the host (local UI takeover, inactive scene).
    public func releaseInput() { releaseInput(clearingLatches: false) }

    func releaseInput(clearingLatches: Bool) {
        send(ledger.releaseAll())
        interpreter.reset()
        if clearingLatches { workingLatches.clearAll() }
        publishLatches()
        publishButtonLatch()
    }

    /// The host released everything itself (the connection ended or is being replaced): forget without sending.
    func hostReleasedInput() {
        let held = ledger.isHoldingInput || !interpreter.latchedButtons.isEmpty
        ledger.hostDidReleaseInput()
        if held { interpreter.reset() }
        publishButtonLatch()
    }

    // MARK: Published input state

    func publishLatches() {
        var next = Self.offLatches
        for key in ModifierKey.allCases { next[key] = workingLatches[key] }
        if latches != next { latches = next }
    }

    func publishButtonLatch() {
        var next: MouseButtons?
        if !interpreter.latchedButtons.isEmpty {
            next = interpreter.latchedButtons
        } else if let armed = interpreter.armedButton {
            next = armed
        } else if case .drag(let drag) = interpreter.phase, drag.armed {
            next = drag.button
        }
        if buttonLatch != next { buttonLatch = next }
    }

    /// Remote input on only while allowed; turning it off releases the host first.
    func syncInterpreter() {
        let enabled = allowsRemoteInput
        if interpreter.remoteEnabled != enabled {
            if !enabled {
                cancelTyping() // text still queued isn't typed once input is off
                send(ledger.releaseAll())
            }
            interpreter.remoteEnabled = enabled
        }
        if interpreter.mode != settings.inputMode { interpreter.mode = settings.inputMode }
        publishButtonLatch()
    }
}
