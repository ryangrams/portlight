import Foundation

/// Sticky ⌘ ⌥ ⇧ ⌃ state for the accessory strip: a real state machine, not four cosmetic toggles.
///
/// - Tap: Off → Latched immediately (no waiting to see whether a double tap follows).
/// - Tap again: Latched → Off, unless it comes within `lockInterval` of the latching tap → Locked.
/// - Tap while Locked → Off.
/// - `consumeAfterAction()` after a complete click/drag/key chord clears Latched, never Locked.
///
/// This is UI state; `InputLedger` decides when the host actually sees key-downs and key-ups.
public struct ModifierLatches: Equatable, Sendable {
    /// Second tap within this interval of the latching tap locks the modifier.
    public static let lockInterval: TimeInterval = 0.35

    private var states: [ModifierKey: ModifierLatch] = [:]
    private var latchedAt: [ModifierKey: TimeInterval] = [:]

    public init() {}

    public subscript(key: ModifierKey) -> ModifierLatch { states[key] ?? .off }

    public mutating func tap(_ key: ModifierKey, at time: TimeInterval) {
        switch self[key] {
        case .off:
            states[key] = .latched
            latchedAt[key] = time
        case .latched:
            if let first = latchedAt[key], time >= first, time - first <= Self.lockInterval {
                states[key] = .locked
            } else {
                states[key] = .off
            }
            latchedAt[key] = nil
        case .locked:
            states[key] = .off
            latchedAt[key] = nil
        }
    }

    /// A complete action used the latched modifiers: clear them. Locked ones remain.
    public mutating func consumeAfterAction() {
        for key in latched {
            states[key] = .off
            latchedAt[key] = nil
        }
    }

    /// Disconnect, background, mode change or Control Off: everything returns to Off.
    public mutating func clearAll() {
        states.removeAll()
        latchedAt.removeAll()
    }

    public var latched: Set<ModifierKey> { Set(states.filter { $0.value == .latched }.keys) }
    public var locked: Set<ModifierKey> { Set(states.filter { $0.value == .locked }.keys) }
    public var isEmpty: Bool { latched.isEmpty && locked.isEmpty }

    /// Modifiers that apply to the next action: a set union, never counters, so a sticky ⌘ and a held
    /// hardware ⌘ are one ⌘.
    public func effective(hardwareHeld: Set<ModifierKey> = []) -> Set<ModifierKey> {
        latched.union(locked).union(hardwareHeld)
    }
}
