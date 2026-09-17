import Foundation

/// Sole authority for remote input the host is holding: the button mask, the last pointer target, keys
/// down, and modifiers down. Every remote pointer/key/text message is produced here, so held state and
/// the wire can never disagree.
///
/// Rules:
/// - Pointer messages always carry the full current mask; each action becomes one message (never coalesced).
///   A scroll step larger than the host's ±100-line clamp becomes several wheel messages that sum to it.
/// - Effective modifiers (sticky latched ∪ locked ∪ hardware held) are pressed before the next pointer
///   activity (including the release that ends a drag) or key-down. When a click/drag (last button
///   released) or key chord (non-modifier key-up) completes, latched modifiers are consumed and released;
///   locked and hardware-held ones stay down.
/// - `text` never carries modifiers: every modifier goes up first and is re-asserted before the next action.
/// - After the host released input (`hostDidReleaseInput`), nothing is replayed; locked/held modifiers
///   are re-asserted lazily before the next action, and buttons/keys are never re-pressed.
///
/// Confinement: not thread-safe. Create and call on one serial queue — the session engine's queue (or
/// the main thread, if the session drives input there) — and send the returned messages in order on it.
public final class InputLedger {
    public private(set) var buttons: MouseButtons = []
    /// Where held buttons are released. Updated by every pointer or wheel message.
    public private(set) var lastTarget: PointerTarget?
    /// Non-modifier keysyms down on the host, in press order.
    public private(set) var keysDown: [UInt32] = []
    /// Modifiers down on the host, in press order, with the keysym that pressed each.
    private var hostModifiers: [(key: ModifierKey, keysym: UInt32)] = []
    /// Hardware modifier keysyms physically held (left and right tracked separately).
    private var physicalModifierKeys: [UInt32] = []

    /// Canonical press order for modifiers asserted together (⌃ ⌥ ⇧ ⌘).
    static let assertionOrder: [ModifierKey] = [.control, .option, .shift, .command]

    public init() {}

    /// Modifiers the host currently has down, in press order.
    public var modifiersDown: [ModifierKey] { hostModifiers.map { $0.key } }
    /// Modifiers held on a hardware keyboard (for the sticky strip's "held" indication).
    public var hardwareModifiers: Set<ModifierKey> { Set(physicalModifierKeys.compactMap(KeyMapping.modifierKey(forKeysym:))) }
    /// True while a button (any drag), a non-modifier key, or a hardware modifier is held. The
    /// subscription scheduler must not send while true: the host releases input on every subscription.
    public var isHoldingInput: Bool { !buttons.isEmpty || !keysDown.isEmpty || !physicalModifierKeys.isEmpty }

    // MARK: Pointer

    /// Converts one gesture action into wire messages, pressing/releasing modifiers around it.
    /// `modifiers` is the sticky state; latched entries are consumed when the action completes.
    public func apply(_ action: RemoteAction, modifiers: inout ModifierLatches) -> [OutboundMessage] {
        var out: [OutboundMessage] = []
        let effective = modifiers.effective(hardwareHeld: hardwareModifiers)
        switch action {
        case .move(let target):
            reconcile(effective, into: &out)
            lastTarget = target
            out.append(pointer(target))
        case .press(let pressed, let target):
            reconcile(effective, into: &out)
            buttons.formUnion(pressed)
            lastTarget = target
            out.append(pointer(target))
        case .release(let released, let target):
            let releasing = buttons.intersection(released)
            guard !releasing.isEmpty else { return [] } // not held on the host: no transition to send
            // This completion consumes the latched modifiers, so one latched while the button was held goes
            // down before the button comes up (a ⌥-drop) instead of being discarded unused.
            reconcile(effective, into: &out)
            buttons.subtract(releasing)
            lastTarget = target
            out.append(pointer(target))
            if buttons.isEmpty && keysDown.isEmpty { complete(&modifiers, into: &out) }
        case .scroll(let target, let dx, let dy):
            guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return [] }
            reconcile(effective, into: &out)
            lastTarget = target
            out += wheel(target, dx: dx, dy: dy)
        }
        return out
    }

    /// Lines one wheel message can carry: the host (Server.swift) and the encoder clamp each to ±100.
    static let maxWheelLinesPerMessage = PortlightWire.Limits.maxWheelLines
    /// Messages one scroll step may become. Only a runaway value needs more, and the clamp then applies.
    static let maxWheelMessagesPerStep = 16

    /// One scroll step as wheel messages within the clamp. A larger step is split evenly and the pieces sum
    /// exactly to it, so the content keeps following the fingers at any zoom or tick gap.
    private func wheel(_ target: PointerTarget, dx: Double, dy: Double) -> [OutboundMessage] {
        let needed = (max(abs(dx), abs(dy)) / Self.maxWheelLinesPerMessage).rounded(.up)
        let count = Int(min(Double(Self.maxWheelMessagesPerStep), max(1, needed)))
        var out: [OutboundMessage] = []
        var sentX = 0.0, sentY = 0.0
        for index in 0..<count {
            let last = index == count - 1
            let stepX = last ? dx - sentX : dx / Double(count)
            let stepY = last ? dy - sentY : dy / Double(count)
            sentX += stepX
            sentY += stepY
            out.append(.wheel(display: target.display, x: unit(target.x), y: unit(target.y), dx: stepX, dy: stepY))
        }
        return out
    }

    // MARK: Keys

    /// A hardware or soft key transition. Modifier keysyms (either hand) are tracked as held hardware
    /// modifiers; other keys are wrapped in the effective modifiers.
    public func key(keysym: UInt32, down: Bool, modifiers: inout ModifierLatches) -> [OutboundMessage] {
        var out: [OutboundMessage] = []
        if let modifier = KeyMapping.modifierKey(forKeysym: keysym) {
            if down {
                if !physicalModifierKeys.contains(keysym) { physicalModifierKeys.append(keysym) }
                if !hostModifiers.contains(where: { $0.key == modifier }) {
                    hostModifiers.append((modifier, keysym))
                    out.append(.key(keysym: keysym, down: true))
                }
            } else {
                guard let index = physicalModifierKeys.firstIndex(of: keysym) else { return [] }
                physicalModifierKeys.remove(at: index)
                releaseModifiers(notIn: modifiers.effective(hardwareHeld: hardwareModifiers), into: &out)
            }
            return out
        }
        let effective = modifiers.effective(hardwareHeld: hardwareModifiers)
        if down {
            reconcile(effective, into: &out)
            if !keysDown.contains(keysym) { keysDown.append(keysym) }
            out.append(.key(keysym: keysym, down: true)) // a repeated down is the app's key repeat
        } else {
            guard let index = keysDown.firstIndex(of: keysym) else { return [] }
            keysDown.remove(at: index)
            out.append(.key(keysym: keysym, down: false))
            if keysDown.isEmpty && buttons.isEmpty { complete(&modifiers, into: &out) }
        }
        return out
    }

    /// Down + up with modifier wrapping, for the soft key palette and soft-keyboard Backspace.
    public func pressKey(keysym: UInt32, modifiers: inout ModifierLatches) -> [OutboundMessage] {
        let down = key(keysym: keysym, down: true, modifiers: &modifiers)
        return down + key(keysym: keysym, down: false, modifiers: &modifiers)
    }

    /// The sticky strip changed (a modifier toggled off) or a hardware modifier was released elsewhere:
    /// release host modifiers that are no longer effective. Key-downs stay lazy.
    public func modifiersChanged(_ modifiers: ModifierLatches) -> [OutboundMessage] {
        var out: [OutboundMessage] = []
        releaseModifiers(notIn: modifiers.effective(hardwareHeld: hardwareModifiers), into: &out)
        return out
    }

    // MARK: Text

    /// Committed Unicode, chunked at grapheme boundaries; line breaks/tabs become key presses. No
    /// modifier applies to text, so any modifier the host holds is released first.
    public func text(_ text: String) -> [OutboundMessage] {
        let pieces = TextInput.pieces(for: text)
        guard !pieces.isEmpty else { return [] }
        var out: [OutboundMessage] = []
        releaseModifiers(notIn: [], into: &out)
        for piece in pieces {
            switch piece {
            case .text(let chunk): out.append(.text(chunk))
            case .key(let keysym): out += [.key(keysym: keysym, down: true), .key(keysym: keysym, down: false)]
            }
        }
        return out
    }

    /// Soft-keyboard commit: with modifiers in effect, one character becomes a chord (⌘ + "c") through
    /// the key path; otherwise it is typed as text. Composition stays local; call only with committed text.
    public func typeCommitted(_ text: String, modifiers: inout ModifierLatches) -> [OutboundMessage] {
        if !modifiers.effective(hardwareHeld: hardwareModifiers).isEmpty, let keysym = TextInput.chordKeysym(for: text) {
            return pressKey(keysym: keysym, modifiers: &modifiers)
        }
        return self.text(text)
    }

    // MARK: Release

    /// Releases everything the host holds: buttons at the last target, non-modifier keys, then modifiers
    /// in reverse order. For Control Off, pause, mode switch, background, topology loss, disconnect,
    /// cancellation and local UI takeover. Send before any subscription that changes control state.
    /// Sticky latches are the caller's to clear (`ModifierLatches.clearAll`).
    public func releaseAll() -> [OutboundMessage] {
        var out: [OutboundMessage] = []
        if !buttons.isEmpty, let target = lastTarget {
            out.append(.pointer(display: target.display, x: unit(target.x), y: unit(target.y), buttons: []))
        }
        for keysym in keysDown.reversed() { out.append(.key(keysym: keysym, down: false)) }
        for modifier in hostModifiers.reversed() { out.append(.key(keysym: modifier.keysym, down: false)) }
        buttons = []
        keysDown = []
        hostModifiers = []
        physicalModifierKeys = []
        lastTarget = nil
        return out
    }

    /// The host released all input itself (accepted subscription, session end). Forget what it held
    /// without sending anything; physically held modifiers are re-asserted before the next action.
    public func hostDidReleaseInput() {
        buttons = []
        keysDown = []
        hostModifiers = []
    }

    // MARK: Helpers

    private func pointer(_ target: PointerTarget) -> OutboundMessage {
        .pointer(display: target.display, x: unit(target.x), y: unit(target.y), buttons: buttons)
    }

    /// Wire contract is the half-open [0, 1); geometry should already guarantee it.
    private func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 0.999_999) : 0
    }

    /// Releases modifiers no longer effective, then presses effective ones not yet down.
    private func reconcile(_ effective: Set<ModifierKey>, into out: inout [OutboundMessage]) {
        releaseModifiers(notIn: effective, into: &out)
        for modifier in Self.assertionOrder where effective.contains(modifier) && !hostModifiers.contains(where: { $0.key == modifier }) {
            let keysym = physicalModifierKeys.first { KeyMapping.modifierKey(forKeysym: $0) == modifier } ?? modifier.keysym
            hostModifiers.append((modifier, keysym))
            out.append(.key(keysym: keysym, down: true))
        }
    }

    private func releaseModifiers(notIn keep: Set<ModifierKey>, into out: inout [OutboundMessage]) {
        for index in hostModifiers.indices.reversed() where !keep.contains(hostModifiers[index].key) {
            out.append(.key(keysym: hostModifiers[index].keysym, down: false))
            hostModifiers.remove(at: index)
        }
    }

    /// A click/drag/key chord finished: consume latched modifiers and release what is no longer effective.
    private func complete(_ modifiers: inout ModifierLatches, into out: inout [OutboundMessage]) {
        modifiers.consumeAfterAction()
        releaseModifiers(notIn: modifiers.effective(hardwareHeld: hardwareModifiers), into: &out)
    }
}
