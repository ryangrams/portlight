import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system paste button (`UIPasteControl`) for Type Pasted Text. The pasteboard is read only when the person
/// taps it, so there is no paste prompt and no polling; the text goes to `onPaste`.
struct PasteTextControl: UIViewRepresentable {
    let onPaste: @MainActor (String) -> Void

    func makeUIView(context: Context) -> PasteControlContainer {
        PasteControlContainer(onPaste: onPaste)
    }

    func updateUIView(_ view: PasteControlContainer, context: Context) {
        view.onPaste = onPaste
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteControlContainer, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}

/// Holds the paste control and its target (the control keeps only a weak reference to the target).
final class PasteControlContainer: UIView {
    private let receiver = PasteTextReceiver()
    private let control: UIPasteControl

    var onPaste: @MainActor (String) -> Void {
        get { receiver.onPaste }
        set { receiver.onPaste = newValue }
    }

    init(onPaste: @escaping @MainActor (String) -> Void) {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        control = UIPasteControl(configuration: configuration)
        super.init(frame: .zero)
        receiver.onPaste = onPaste
        receiver.isHidden = true
        addSubview(receiver)
        control.target = receiver
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    /// The control reports no useful intrinsic size of its own; ask it to fit its icon and "Paste" label, with a
    /// fallback wide enough for both, and never less than a 44 pt target.
    override var intrinsicContentSize: CGSize {
        let fitted = control.sizeThatFits(CGSize(width: 320, height: 44))
        let width = fitted.width > 44 ? fitted.width : 108
        return CGSize(width: width, height: max(fitted.height, 44))
    }
}

/// The paste target: accepts plain text and hands it over on the main actor.
final class PasteTextReceiver: UIView {
    var onPaste: @MainActor (String) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.utf8PlainText.identifier,
                                                                               UTType.plainText.identifier])
    }

    required init?(coder: NSCoder) { return nil }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains { $0.canLoadObject(ofClass: String.self) }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return }
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
            guard let text, !text.isEmpty, let receiver = self else { return }
            Task { @MainActor in receiver.onPaste(text) }
        }
    }
}
