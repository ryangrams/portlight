import SwiftUI
import PortlightKit

/// The keyboard bar's second row; one at a time, above the main row.
enum AccessoryPanel: String, CaseIterable, Sendable {
    case functionKeys, moreKeys, mouse
}

/// The keyboard accessory (UI-SPEC §8): sticky ⌘ ⌥ ⇧ ⌃, Esc, Tab, arrows, fn (F1–F12), More (Home, End,
/// Page Up/Down, Forward Delete and Type Pasted Text), and mouse buttons with Hold Left / Hold Right.
///
/// A view over values and closures: the session's `ModifierLatches` and input ledger decide what reaches the
/// Mac. It serves as the text responder's `inputAccessoryView` (see `RemoteTextInput`) and as a panel on its
/// own when a hardware keyboard is attached.
struct KeyboardAccessoryBar: View {
    let latches: ModifierLatches
    /// The Hold Left / Hold Right latch currently pressed, if any.
    let heldButton: MouseButtons?
    @Binding var panel: AccessoryPanel?
    private let usesBarBackground: Bool
    private let onModifier: @MainActor (ModifierKey) -> Void
    private let onKey: @MainActor (SoftKey) -> Void
    private let onClick: @MainActor (MouseButtons) -> Void
    private let onToggleHold: @MainActor (MouseButtons) -> Void
    private let onPasteText: @MainActor (String) -> Void

    /// - Parameter usesBarBackground: false inside a keyboard input view, which draws its own background.
    init(latches: ModifierLatches, heldButton: MouseButtons?, panel: Binding<AccessoryPanel?>,
         usesBarBackground: Bool = true,
         onModifier: @escaping @MainActor (ModifierKey) -> Void,
         onKey: @escaping @MainActor (SoftKey) -> Void,
         onClick: @escaping @MainActor (MouseButtons) -> Void,
         onToggleHold: @escaping @MainActor (MouseButtons) -> Void,
         onPasteText: @escaping @MainActor (String) -> Void) {
        self.latches = latches
        self.heldButton = heldButton
        _panel = panel
        self.usesBarBackground = usesBarBackground
        self.onModifier = onModifier
        self.onKey = onKey
        self.onClick = onClick
        self.onToggleHold = onToggleHold
        self.onPasteText = onPasteText
    }

    var body: some View {
        VStack(spacing: 0) {
            if let panel {
                panelRow(panel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            mainRow
        }
        .background {
            if usesBarBackground {
                Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)
            }
        }
        // Like the session chrome it sits over the remote picture, so it stops growing at the largest standard size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
    }

    // MARK: Rows

    /// Modifiers and keys scroll (a phone is narrower than the row); fn, More and Mouse stay pinned at the
    /// trailing edge so the panels they open are always discoverable.
    private var mainRow: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ModifierKey.allCases, id: \.self) { key in
                        ModifierChip(key: key, latch: latches[key]) { onModifier(key) }
                    }
                    separator
                    Group {
                        keyCap(.escape)
                        keyCap(.tab)
                    }
                    separator
                    Group {
                        keyCap(.left)
                        keyCap(.up)
                        keyCap(.down)
                        keyCap(.right)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .padding(.vertical, 5)
            }
            // A fade at the trailing edge says the row continues.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                       .init(color: .black.opacity(0.15), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            separator
            HStack(spacing: 6) {
                panelToggle(.functionKeys, label: "Function Keys") {
                    Text(verbatim: "fn").font(.callout.weight(.semibold))
                }
                panelToggle(.moreKeys, label: "More Keys") {
                    Image(systemName: "ellipsis")
                }
                panelToggle(.mouse, label: "Mouse Buttons") {
                    Image(systemName: "computermouse")
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private func panelRow(_ panel: AccessoryPanel) -> some View {
        switch panel {
        case .functionKeys:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SoftKey.functionKeys, id: \.self) { key in
                        keyCap(key)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        case .moreKeys:
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach([SoftKey.home, .end, .pageUp, .pageDown, .forwardDelete], id: \.self) { key in
                            keyCap(key)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                PasteTextRow(onPaste: onPasteText)
                    .padding(.horizontal, 10)
            }
            .padding(.vertical, 5)
        case .mouse:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    clickButton(.left, title: "Left")
                    clickButton(.right, title: "Right")
                    clickButton(.middle, title: "Middle")
                    separator
                    holdButton(.left, title: "Hold Left", id: "left")
                    holdButton(.right, title: "Hold Right", id: "right")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
    }

    // MARK: Keys and buttons

    private func keyCap(_ key: SoftKey) -> some View {
        Button {
            onKey(key)
        } label: {
            Group {
                if key.showsSymbolOnCap, let symbol = key.systemImage {
                    Image(systemName: symbol)
                        .font(.body.weight(.medium))
                } else {
                    Text(key.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, key.label.count > 3 ? 8 : 0)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(KeyCapStyle())
        .buttonRepeatBehavior(key.repeatsWhileHeld ? .enabled : .disabled)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityAddTraits(.isKeyboardKey)
        .accessibilityIdentifier("key.\(key.rawValue)")
    }

    private func panelToggle<Face: View>(_ target: AccessoryPanel, label: String, @ViewBuilder face: () -> Face) -> some View {
        let isOpen = panel == target
        return Button {
            panel = isOpen ? nil : target
        } label: {
            face()
                .frame(width: 44, height: 44)
        }
        .buttonStyle(KeyCapStyle(isActive: isOpen))
        .accessibilityLabel(label)
        .accessibilityValue(isOpen ? "Shown" : "Hidden")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityIdentifier("accessory.\(target.rawValue)")
    }

    private func clickButton(_ button: MouseButtons, title: String) -> some View {
        Button {
            onClick(button)
        } label: {
            Label(title, systemImage: "cursorarrow.click")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
        }
        .buttonStyle(KeyCapStyle())
        .accessibilityLabel("\(title) Click")
        .accessibilityIdentifier("mouse.click.\(title.lowercased())")
    }

    /// A latch that shows a pressed state while the button is held on the Mac.
    private func holdButton(_ button: MouseButtons, title: String, id: String) -> some View {
        let held = heldButton == button
        return Button {
            onToggleHold(button)
        } label: {
            Label(title, systemImage: "cursorarrow.click.badge.clock")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
        }
        .buttonStyle(KeyCapStyle(isActive: held))
        .accessibilityLabel(title)
        .accessibilityValue(held ? "Held" : "Released")
        .accessibilityAddTraits(held ? .isSelected : [])
        .accessibilityHint(held ? "Releases the button." : "Holds the button down until you tap again, for long drags.")
        .accessibilityIdentifier("mouse.hold.\(id)")
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}

/// ⌘ ⌥ ⇧ ⌃ with three visible states: Off (a plain key), Latched (filled accent) and Locked (filled accent with
/// an underline bar and a lock glyph). VoiceOver reads "Off", "Next action" or "Locked".
private struct ModifierChip: View {
    let key: ModifierKey
    let latch: ModifierLatch
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Text(verbatim: key.symbol)
                .font(.title3.weight(.medium))
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if latch == .locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottom) {
                    if latch == .locked {
                        Capsule()
                            .frame(width: 18, height: 3)
                            .padding(.bottom, 5)
                    }
                }
        }
        .buttonStyle(KeyCapStyle(isActive: latch != .off))
        .accessibilityLabel(key.spokenName)
        .accessibilityValue(latch.voiceOverValue)
        .accessibilityAddTraits(latch == .off ? [.isKeyboardKey] : [.isKeyboardKey, .isSelected])
        .accessibilityHint("Applies to the next click or key. Tap twice quickly to lock it.")
        .accessibilityIdentifier("modifier.\(key.rawValue)")
    }
}

private struct PasteTextRow: View {
    let onPaste: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            PasteTextControl(onPaste: onPaste)
                .fixedSize()
                .accessibilityIdentifier("accessory.paste")
            VStack(alignment: .leading, spacing: 1) {
                Text("Type Pasted Text")
                    .font(.subheadline.weight(.semibold))
                Text("Types into the focused field on the Mac. It doesn’t change the Mac’s clipboard.")
                    .font(.caption2)
                    .foregroundStyle(PortlightTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct KeyCapStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        KeyCapFace(label: configuration.label, isActive: isActive, isPressed: configuration.isPressed)
    }
}

/// A keyboard-like key: white (dark gray in dark mode) with a bottom shadow, or filled accent when active.
private struct KeyCapFace<Content: View>: View {
    let label: Content
    let isActive: Bool
    let isPressed: Bool
    @Environment(\.isEnabled) var isEnabled
    var a11y = PortlightAccessibility()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        label
            .foregroundStyle(isActive ? PortlightTheme.onAccent : Color.primary)
            .background {
                shape
                    .fill(fill)
                    .shadow(color: .black.opacity(isActive ? 0 : 0.2), radius: 0, x: 0, y: 1)
            }
            .overlay {
                if a11y.increaseContrast {
                    shape.strokeBorder(isActive ? Color.primary : Color(uiColor: .separator),
                                       lineWidth: isActive ? a11y.selectedOutline : 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }

    private var fill: Color {
        if isActive { return isPressed ? Color.accentColor.opacity(0.75) : Color.accentColor }
        return isPressed ? Color(uiColor: .systemGray4) : Color(uiColor: .tertiarySystemBackground)
    }
}

private extension SoftKey {
    /// Arrows and delete keys read best as symbols; the rest as key-cap words ("esc", "tab", "F5").
    var showsSymbolOnCap: Bool {
        switch self {
        case .left, .right, .up, .down, .forwardDelete, .backspace: true
        default: false
        }
    }

    /// Holding these repeats them, like a hardware key.
    var repeatsWhileHeld: Bool {
        switch self {
        case .left, .right, .up, .down, .forwardDelete, .backspace, .pageUp, .pageDown: true
        default: false
        }
    }
}
