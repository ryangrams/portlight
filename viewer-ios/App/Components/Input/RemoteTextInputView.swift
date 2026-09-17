import SwiftUI
import UIKit
import PortlightKit

/// A hardware key transition for the input ledger (`KeyMapping.keysym(forHIDUsage:charactersIgnoringModifiers:)`).
struct HardwareKeyEvent: Equatable, Sendable {
    /// `UIKeyboardHIDUsage` raw value.
    var hidUsage: Int
    var charactersIgnoringModifiers: String
    /// Modifiers held with the key (Command, Option, Shift, Control).
    var modifiers: Set<ModifierKey>
    var down: Bool
    /// A key-down repeated by this app while the key is held (iOS doesn't repeat `pressesBegan`).
    var isRepeat: Bool

    /// Left/right Control, Shift, Option and Command (HID 0xE0–0xE7): never repeated.
    var isModifierKey: Bool { (0xE0...0xE7).contains(hidUsage) }

    @MainActor
    init(key: UIKey, down: Bool, isRepeat: Bool = false) {
        hidUsage = key.keyCode.rawValue
        charactersIgnoringModifiers = key.charactersIgnoringModifiers
        modifiers = Self.modifiers(from: key.modifierFlags)
        self.down = down
        self.isRepeat = isRepeat
    }

    init(hidUsage: Int, charactersIgnoringModifiers: String, modifiers: Set<ModifierKey>, down: Bool, isRepeat: Bool = false) {
        self.hidUsage = hidUsage
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.down = down
        self.isRepeat = isRepeat
    }

    static func modifiers(from flags: UIKeyModifierFlags) -> Set<ModifierKey> {
        var result = Set<ModifierKey>()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

/// The hidden first responder behind the software keyboard and hardware keys (UI-SPEC §8).
///
/// Committed text arrives once through `insertText`; marked-text composition stays inside the keyboard because
/// this view adopts only `UIKeyInput`. Hardware keys come from `pressesBegan/Ended` as HID usage, unmodified
/// characters and modifiers, and are not also delivered as text. iOS doesn't repeat held hardware keys, so the
/// most recent non-modifier key repeats here until it goes up. Every text trait that could rewrite what was
/// typed (autocorrection, smart quotes, dashes and insert/delete, spell checking, predictions) is off: the Mac
/// does its own text processing.
final class RemoteTextInputView: UIView, UIKeyInput {
    static let repeatDelay: Duration = .milliseconds(400)
    static let repeatInterval: Duration = .milliseconds(80)

    var onInsertText: @MainActor (String) -> Void = { _ in }
    var onDeleteBackward: @MainActor () -> Void = {}
    var onKey: @MainActor (HardwareKeyEvent) -> Void = { _ in }
    /// The view became or stopped being first responder (the keyboard appeared or went away).
    var onFirstResponderChange: @MainActor (Bool) -> Void = { _ in }

    /// Shown above the software keyboard, or on its own at the bottom with a hardware keyboard.
    var accessory: UIView? {
        didSet { if isFirstResponder { reloadInputViews() } }
    }

    /// Whether the owner wants the keyboard up; applied once the view is in a window.
    var wantsFirstResponder = false {
        didSet {
            guard wantsFirstResponder != oldValue else { return }
            Task { @MainActor [weak self] in self?.applyFirstResponderWish() }
        }
    }

    // UITextInputTraits
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false

    private var repeatTask: Task<Void, Never>?
    private var repeatingEvent: HardwareKeyEvent?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        // No undo/redo/paste shortcut bar: those would act on this empty proxy, not on the Mac.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        NotificationCenter.default.addObserver(self, selector: #selector(stopRepeating),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override var inputAccessoryView: UIView? { accessory }
    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFirstResponderChange(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            stopRepeating()
            onFirstResponderChange(false)
        }
        return resigned
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopRepeating()
        } else {
            applyFirstResponderWish()
        }
    }

    private func applyFirstResponderWish() {
        guard window != nil else { return }
        if wantsFirstResponder, !isFirstResponder {
            _ = becomeFirstResponder()
        } else if !wantsFirstResponder, isFirstResponder {
            _ = resignFirstResponder()
        }
    }

    // MARK: UIKeyInput

    /// Always true so the keyboard's Delete stays active: the text being edited lives on the Mac.
    var hasText: Bool { true }

    func insertText(_ text: String) { onInsertText(text) }

    func deleteBackward() { onDeleteBackward() }

    // MARK: Hardware keys

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let down = HardwareKeyEvent(key: key, down: true)
            onKey(down)
            if !down.isModifierKey { startRepeating(down) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = release(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    /// A cancelled press still goes up, so nothing stays held on the Mac.
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = release(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let up = HardwareKeyEvent(key: key, down: false)
            if repeatingEvent?.hidUsage == up.hidUsage { stopRepeating() }
            onKey(up)
        }
        return unhandled
    }

    private func startRepeating(_ event: HardwareKeyEvent) {
        stopRepeating()
        var repeated = event
        repeated.isRepeat = true
        repeatingEvent = repeated
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: RemoteTextInputView.repeatDelay)
            while !Task.isCancelled {
                guard let self, let event = self.repeatingEvent else { return }
                self.onKey(event)
                try? await Task.sleep(for: RemoteTextInputView.repeatInterval)
            }
        }
    }

    @objc private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatingEvent = nil
    }
}

/// Places the hidden text responder in SwiftUI with `accessory` as its `inputAccessoryView`. `isActive` drives
/// first responder; when the system dismisses the keyboard it is set back to false.
struct RemoteTextInput<Accessory: View>: UIViewRepresentable {
    @Binding var isActive: Bool
    private let accessory: Accessory
    private let onInsertText: @MainActor (String) -> Void
    private let onDeleteBackward: @MainActor () -> Void
    private let onKey: @MainActor (HardwareKeyEvent) -> Void

    init(isActive: Binding<Bool>,
         onInsertText: @escaping @MainActor (String) -> Void,
         onDeleteBackward: @escaping @MainActor () -> Void,
         onKey: @escaping @MainActor (HardwareKeyEvent) -> Void,
         @ViewBuilder accessory: () -> Accessory) {
        _isActive = isActive
        self.accessory = accessory()
        self.onInsertText = onInsertText
        self.onDeleteBackward = onDeleteBackward
        self.onKey = onKey
    }

    func makeUIView(context: Context) -> RemoteTextInputView {
        let view = RemoteTextInputView(frame: .zero)
        view.accessory = KeyboardAccessoryHost(rootView: accessory)
        return view
    }

    func updateUIView(_ view: RemoteTextInputView, context: Context) {
        view.onInsertText = onInsertText
        view.onDeleteBackward = onDeleteBackward
        view.onKey = onKey
        let binding = $isActive
        view.onFirstResponderChange = { active in
            if binding.wrappedValue != active { binding.wrappedValue = active }
        }
        (view.accessory as? KeyboardAccessoryHost<Accessory>)?.update(rootView: accessory)
        view.wantsFirstResponder = isActive
    }
}

/// SwiftUI content as an `inputAccessoryView` that sizes itself to that content.
final class KeyboardAccessoryHost<Content: View>: UIInputView {
    private let host: UIHostingController<Content>

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 54), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleHeight
        host.sizingOptions = [.intrinsicContentSize]
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func update(rootView: Content) {
        host.rootView = rootView
        host.view.invalidateIntrinsicContentSize()
    }
}
