import SwiftUI
import PortlightKit

/// Session controls over the remote picture (UI-SPEC §5).
///
/// Portrait: a compact top bar (Disconnect, name and status, Control) and a bottom strip (Displays, Input,
/// Keyboard, Pause, Audio, More). Landscape: a leading rail with Disconnect, name and Control, and a trailing
/// rail with the strip's controls. Hidden: a grabber at the bottom edge. The chrome only reads
/// `SessionChromeState` and calls `SessionChromeActions`; its empty areas never take touches, so the canvas
/// stays reachable around it. It reports the safe-area edges it covers through `onInsetsChange`.
struct SessionChrome: View {
    let state: SessionChromeState
    let actions: SessionChromeActions
    private let noticeAutoDismiss: Duration?
    private let onInsetsChange: (@MainActor (ChromeInsets) -> Void)?

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var a11y = PortlightAccessibility()

    @State private var topBarHeight: CGFloat = 0
    @State private var bottomStripHeight: CGFloat = 0
    @State private var leadingRailWidth: CGFloat = 0
    @State private var trailingRailWidth: CGFloat = 0

    static let railWidth: CGFloat = 84
    /// The strip, rails and grabber sit over the remote picture, so they stop growing at the second accessibility
    /// size; by then the strip's items have dropped their captions (`iconOnly`) and show the large content viewer.
    /// The notice banner and the sheets aren't capped.
    private static let barTypeSizes = ...DynamicTypeSize.accessibility2

    /// - Parameter noticeAutoDismiss: how long a banner stays up; nil keeps it until dismissed.
    init(state: SessionChromeState, actions: SessionChromeActions, noticeAutoDismiss: Duration? = .seconds(6),
         onInsetsChange: (@MainActor (ChromeInsets) -> Void)? = nil) {
        self.state = state
        self.actions = actions
        self.noticeAutoDismiss = noticeAutoDismiss
        self.onInsetsChange = onInsetsChange
    }

    /// iPhone landscape (compact height) moves the controls to rails.
    private var usesRails: Bool { verticalSizeClass == .compact }
    /// At accessibility text sizes the compact items drop their captions; the large content viewer shows them.
    private var iconOnly: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if usesRails { landscape } else { portrait }
        }
        .animation(a11y.animation, value: state.controlsHidden)
        .animation(a11y.animation, value: state.notice)
        .onAppear { onInsetsChange?(occupiedInsets) }
        .onChange(of: occupiedInsets) { _, insets in onInsetsChange?(insets) }
    }

    private var occupiedInsets: ChromeInsets {
        guard !state.controlsHidden else { return .zero }
        return usesRails ? ChromeInsets(leading: leadingRailWidth, trailing: trailingRailWidth)
                         : ChromeInsets(top: topBarHeight, bottom: bottomStripHeight)
    }

    // MARK: Layouts

    private var portrait: some View {
        VStack(spacing: 0) {
            if !state.controlsHidden {
                topBar
                    .measured { topBarHeight = $0.height }
                    .transition(a11y.transition(edge: .top))
            }
            noticeBanner
            Spacer(minLength: 0)
            if state.controlsHidden {
                grabber
                    .transition(.opacity)
            } else {
                bottomStrip
                    .measured { bottomStripHeight = $0.height }
                    .transition(a11y.transition(edge: .bottom))
            }
        }
    }

    private var landscape: some View {
        HStack(spacing: 0) {
            if !state.controlsHidden {
                leadingRail
                    .measured { leadingRailWidth = $0.width }
                    .transition(a11y.transition(edge: .leading))
            }
            VStack(spacing: 0) {
                noticeBanner
                Spacer(minLength: 0)
                if state.controlsHidden {
                    grabber
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            if !state.controlsHidden {
                trailingRail
                    .measured { trailingRailWidth = $0.width }
                    .transition(a11y.transition(edge: .trailing))
            }
        }
    }

    // MARK: Portrait parts

    private var topBar: some View {
        HStack(spacing: 8) {
            disconnectButton
            VStack(spacing: 1) {
                Text(state.computerName)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.statusLine)
                    .font(.caption)
                    .foregroundStyle(PortlightTheme.secondaryTextOnMaterial)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("chrome.title")
            ControlModeButton(isOn: state.controlEnabled, action: actions.toggleControl)
                .layoutPriority(1)
        }
        // Like a navigation bar, the top bar stops growing at the largest standard size; its items show the
        // large content viewer beyond that.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background { ChromeFill().ignoresSafeArea(edges: [.top, .horizontal]) }
        .overlay(alignment: .bottom) { hairline(horizontal: true) }
    }

    private var bottomStrip: some View {
        HStack(spacing: 2) {
            stripItems
        }
        .dynamicTypeSize(Self.barTypeSizes)
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background { ChromeFill().ignoresSafeArea(edges: [.bottom, .horizontal]) }
        .overlay(alignment: .top) { hairline(horizontal: true) }
    }

    // MARK: Landscape parts

    private var leadingRail: some View {
        VStack(spacing: 10) {
            disconnectButton
            VStack(spacing: 2) {
                Text(state.computerName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(state.statusLine)
                    .font(.caption2)
                    .foregroundStyle(PortlightTheme.secondaryTextOnMaterial)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chrome.title")
            ControlModeButton(isOn: state.controlEnabled, compact: true, action: actions.toggleControl)
            Spacer(minLength: 0)
        }
        .dynamicTypeSize(Self.barTypeSizes)
        .frame(width: Self.railWidth)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background { ChromeFill().ignoresSafeArea(edges: [.leading, .vertical]) }
        .overlay(alignment: .trailing) { hairline(horizontal: false) }
    }

    private var trailingRail: some View {
        VStack(spacing: 4) {
            stripItems
        }
        .dynamicTypeSize(Self.barTypeSizes)
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background { ChromeFill().ignoresSafeArea(edges: [.trailing, .vertical]) }
        .overlay(alignment: .leading) { hairline(horizontal: false) }
    }

    // MARK: Controls

    @ViewBuilder
    private var stripItems: some View {
        item("Displays", "display.2", id: "displays", badge: String(state.selectedDisplays),
             value: "\(state.selectedDisplays) of \(state.totalDisplays) shown", action: actions.showDisplays)
        inputMenu
        item("Keyboard", "keyboard", id: "keyboard", selected: state.keyboardVisible,
             value: state.keyboardVisible ? "Shown" : "Hidden", action: actions.toggleKeyboard)
        item(state.paused ? "Resume" : "Pause", state.paused ? "play.fill" : "pause.fill", id: "pause",
             action: actions.togglePause)
        item("Audio", state.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash", id: "audio",
             selected: state.audioEnabled, value: state.audioEnabled ? "On" : "Off", action: actions.toggleAudio)
            .disabled(state.audioUnavailableReason != nil)
            .accessibilityHint(state.audioUnavailableReason ?? "")
        moreMenu
    }

    private func item(_ title: String, _ symbol: String, id: String, badge: String? = nil, selected: Bool = false,
                      value: String? = nil, action: @escaping @MainActor () -> Void) -> some View {
        Button {
            action()
        } label: {
            ChromeItemLabel(title: title, systemImage: symbol, badge: badge, isSelected: selected, iconOnly: iconOnly)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
        .accessibilityIdentifier("chrome.\(id)")
    }

    /// Tap cycles Trackpad → Direct → Pan; touch and hold shows every mode.
    private var inputMenu: some View {
        let mode = state.inputMode
        return Menu {
            Picker("Input Mode", selection: Binding(get: { state.inputMode }, set: { actions.setInputMode($0) })) {
                ForEach(InputMode.allCases, id: \.self) { choice in
                    Label(choice.chromeTitle, systemImage: choice.chromeSymbol).tag(choice)
                }
            }
        } label: {
            ChromeItemLabel(title: mode.chromeTitle, systemImage: mode.chromeSymbol, iconOnly: iconOnly)
        } primaryAction: {
            actions.setInputMode(mode.nextChromeMode)
        }
        .accessibilityLabel("Input Mode")
        .accessibilityValue(mode.chromeTitle)
        .accessibilityHint("Switches to \(mode.nextChromeMode.chromeTitle). Touch and hold to choose a mode.")
        .accessibilityShowsLargeContentViewer { Label(mode.chromeTitle, systemImage: mode.chromeSymbol) }
        .accessibilityIdentifier("chrome.input")
    }

    private var moreMenu: some View {
        Menu {
            Button { actions.showQuality() } label: { Label("Quality…", systemImage: "slider.horizontal.3") }
            Section {
                Button { actions.fit() } label: { Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left") }
                Button {
                    actions.actualSize()
                } label: {
                    Label {
                        Text("Actual Size")
                        Text("One Mac point per iPhone point")
                    } icon: {
                        Image(systemName: "1.magnifyingglass")
                    }
                }
                Button { actions.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                Button { actions.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
            }
            Section {
                Button { actions.setControlsHidden(true) } label: { Label("Hide Controls", systemImage: "eye.slash") }
                Button { actions.showGestureGuide() } label: { Label("Gesture Guide", systemImage: "hand.point.up.left") }
                Button { actions.showDiagnostics() } label: { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            }
        } label: {
            ChromeItemLabel(title: "More", systemImage: "ellipsis.circle", iconOnly: iconOnly)
        }
        .accessibilityLabel("More")
        .accessibilityShowsLargeContentViewer { Label("More", systemImage: "ellipsis.circle") }
        .accessibilityIdentifier("chrome.more")
    }

    private var disconnectButton: some View {
        Button {
            actions.disconnect()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(PortlightTheme.idleFill, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Disconnect")
        .accessibilityShowsLargeContentViewer { Label("Disconnect", systemImage: "xmark") }
        .accessibilityIdentifier("chrome.disconnect")
    }

    /// The only control left while hidden. A canvas tap also reveals the controls, and never clicks the Mac.
    private var grabber: some View {
        Button {
            actions.setControlsHidden(false)
        } label: {
            Image(systemName: "chevron.compact.up")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 60, height: 26)
                .background { ChromeFill(Capsule()) }
                .frame(width: 64, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(Self.barTypeSizes)
        .accessibilityLabel("Show Controls")
        .accessibilityIdentifier("chrome.grabber")
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = state.notice {
            let resumes = notice == .audioInterrupted
            SessionNoticeBanner(notice: notice, actionTitle: resumes ? "Resume" : nil,
                                onAction: resumes ? actions.resumeAudio : nil,
                                autoDismissAfter: noticeAutoDismiss, onDismiss: actions.dismissNotice)
                .frame(maxWidth: 520)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(a11y.transition(edge: .top))
        }
    }

    private func hairline(horizontal: Bool) -> some View {
        let width = a11y.increaseContrast ? 1.0 : 0.5
        return Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: horizontal ? nil : width, height: horizontal ? width : nil)
    }
}

/// One chrome control: icon, optional count badge and a short caption.
private struct ChromeItemLabel: View {
    let title: String
    let systemImage: String
    var badge: String?
    var isSelected = false
    let iconOnly: Bool
    @Environment(\.isEnabled) var isEnabled
    var a11y = PortlightAccessibility()

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(minHeight: 26)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        CountBadge(text: badge)
                            .offset(x: 12, y: -6)
                    }
                }
            if !iconOnly {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        // Selected (keyboard shown, audio on) is a filled accent tile, like Control On: accent text on a 16% accent
        // tint measured under 4.5:1 on the chrome.
        .foregroundStyle(isSelected ? PortlightTheme.onAccent : Color.primary)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .overlay {
            if isSelected && a11y.increaseContrast {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: a11y.selectedOutline)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
    }
}

private struct CountBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(PortlightTheme.onAccent)
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .background(Color.accentColor, in: Capsule())
            .accessibilityHidden(true)
    }
}

private extension View {
    /// Reports this view's laid-out size (inside the safe area) whenever it changes.
    func measured(_ report: @escaping @MainActor (CGSize) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy.size) }
                    .onChange(of: proxy.size) { _, size in report(size) }
            }
        }
    }
}
