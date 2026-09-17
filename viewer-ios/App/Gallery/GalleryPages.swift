import SwiftUI
import PortlightKit

/// One gallery page per component, with realistic demo data and cheap interactivity (toggles work).
struct GalleryPageView: View {
    let page: GalleryPage

    var body: some View {
        switch page {
        case .connections:
            ConnectionsGalleryPage(empty: false)
        case .connectionsEmpty:
            ConnectionsGalleryPage(empty: true)
        case .detailNew:
            DetailGalleryPage(saved: false)
        case .detailSaved:
            DetailGalleryPage(saved: true)
        case .trustFirstUse:
            TrustGalleryPage(prompt: GalleryDemo.firstUsePrompt)
        case .trustChanged:
            TrustGalleryPage(prompt: GalleryDemo.changedPrompt)
        case .statusConnecting:
            CardGalleryPage(kind: .connecting)
        case .statusReconnecting:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(status: "Reconnecting"),
                                                         statusPhase: .reconnecting(attempt: 2, after: .networkLost)))
        case .failure:
            CardGalleryPage(kind: .failure(GalleryDemo.failure))
        case .failureLocalNetwork:
            CardGalleryPage(kind: .failure(.localNetworkDenied))
        case .sessionControl:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome()))
        case .sessionViewOnly:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(controlEnabled: false, inputMode: .direct),
                                                         zoomIntoFirstDisplay: true))
        case .sessionPaused:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(paused: true)))
        case .sessionHidden:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(hidden: true), zoomIntoFirstDisplay: true))
        case .sessionNotice:
            SessionGalleryPage(config: SessionPageConfig(
                chrome: GalleryDemo.chrome(notice: .resolutionLimited("Resolution limited to FHD by the selected displays."))))
        case .sessionEmpty:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(selected: 0), selection: []))
        case .sessionContrast:
            SessionGalleryPage(config: SessionPageConfig(
                chrome: GalleryDemo.chrome(keyboardVisible: true, audioEnabled: true),
                overrides: AccessibilityOverrides(reduceTransparency: true, increaseContrast: true)))
        case .displays:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(selected: 2),
                                                         selection: ["fixture-1", "fixture-3"], sheet: .displays))
        case .quality:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(), sheet: .quality))
        case .keyboard:
            KeyboardGalleryPage()
        case .keyboardLive:
            KeyboardLiveGalleryPage()
        case .gestures:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(), sheet: .gestures))
        case .diagnostics:
            SessionGalleryPage(config: SessionPageConfig(chrome: GalleryDemo.chrome(), sheet: .diagnostics))
        case .privacy:
            PrivacyCoverView()
        }
    }
}

/// The neutral backdrop the progress and failure cards sit on before any frame exists.
private struct GalleryBackdrop: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
    }
}

// MARK: - Connections

private struct ConnectionsGalleryPage: View {
    @State private var library: ProfileLibrary
    @State private var path: [ConnectionRoute] = []

    init(empty: Bool) {
        _library = State(initialValue: empty ? ProfileLibrary() : GalleryDemo.library)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ConnectionsListView(library: $library,
                                onConnect: { _ in },
                                onEdit: { path.append(.edit($0.id)) },
                                onDelete: { _ = library.delete(profileID: $0.id) },
                                onNewConnection: { path.append(.new(groupID: $0)) })
                .navigationDestination(for: ConnectionRoute.self) { route in
                    GalleryDetailDestination(route: route, library: $library)
                }
        }
    }
}

private struct GalleryDetailDestination: View {
    @Binding var library: ProfileLibrary
    @State private var draft: ConnectionDraft

    init(route: ConnectionRoute, library: Binding<ProfileLibrary>) {
        _library = library
        switch route {
        case .edit(let id):
            _draft = State(initialValue: library.wrappedValue.profile(id: id).map { ConnectionDraft(editing: $0) } ?? ConnectionDraft())
        case .new(let groupID):
            _draft = State(initialValue: ConnectionDraft(groupID: groupID))
        }
    }

    var body: some View {
        ConnectionDetailView(draft: $draft, onConnect: {}, onSave: {
            if let profile = draft.makeProfile() { library.add(profile) }
        }, onForgetPassword: {})
    }
}

private struct DetailGalleryPage: View {
    private let saved: Bool
    @State private var draft: ConnectionDraft

    init(saved: Bool) {
        self.saved = saved
        _draft = State(initialValue: saved ? ConnectionDraft(editing: GalleryDemo.savedProfile) : GalleryDemo.newDraft)
    }

    var body: some View {
        NavigationStack {
            ConnectionDetailView(draft: $draft, revealValidation: saved ? nil : .connect,
                                 onConnect: {}, onSave: {}, onForgetPassword: {})
        }
    }
}

// MARK: - Trust, progress and failure

private struct TrustGalleryPage: View {
    private let shown: TrustPrompt
    @State private var prompt: TrustPrompt?

    init(prompt: TrustPrompt) {
        shown = prompt
        _prompt = State(initialValue: prompt)
    }

    var body: some View {
        ZStack {
            GalleryBackdrop()
            ConnectionStatusCard(phase: .awaitingTrust(shown), endpoint: shown.endpoint) {}
        }
        .sheet(item: $prompt) { prompt in
            TrustSheet(prompt: prompt, onTrust: { _ in }, onCancel: { _ in })
        }
    }
}

private struct CardGalleryPage: View {
    enum Kind { case connecting, failure(ConnectionFailure) }
    let kind: Kind

    var body: some View {
        ZStack {
            GalleryBackdrop()
            switch kind {
            case .connecting:
                ConnectionStatusCard(phase: .connecting(patient: true), endpoint: GalleryDemo.endpoint) {}
            case .failure(let failure):
                ConnectionFailureCard(failure: failure, endpoint: GalleryDemo.endpoint,
                                      onTryAgain: {}, onDismiss: {})
            }
        }
    }
}

// MARK: - Session

enum GallerySheet: String, Identifiable {
    case displays, quality, gestures, diagnostics
    var id: String { rawValue }
}

struct SessionPageConfig {
    var chrome: SessionChromeState
    var selection: [DisplayID] = GalleryDemo.displays.map(\.id)
    var cursor: LogicalPoint? = GalleryDemo.cursor
    var zoomIntoFirstDisplay = false
    /// A progress card over the dimmed frozen frame (reconnecting).
    var statusPhase: ConnectionPhase?
    var sheet: GallerySheet?
    var overrides: AccessibilityOverrides?
}

/// The session screen as the session owner will compose it: the Metal surface full-bleed, overlays, chrome and
/// sheets. Here the state is local and the picture is the demo scene.
private struct SessionGalleryPage: View {
    private let config: SessionPageConfig
    @State private var chrome: SessionChromeState
    @State private var selection: Set<DisplayID>
    @State private var sheet: GallerySheet?
    @State private var settings = GalleryDemo.qualitySettings
    @State private var surfaceReady = false
    @Environment(\.accessibilityOverrides) private var inheritedOverrides

    init(config: SessionPageConfig) {
        self.config = config
        _chrome = State(initialValue: config.chrome)
        _selection = State(initialValue: Set(config.selection))
        _sheet = State(initialValue: config.sheet)
    }

    private var scene: GalleryDemoScene { .shared }

    private var orderedSelection: [DisplayID] {
        GalleryDemo.displays.map(\.id).filter { selection.contains($0) }
    }

    var body: some View {
        ZStack {
            SessionSurfaceView(renderer: scene.renderer, sceneProvider: scene.sceneProvider,
                               onTouch: { _, _ in },
                               onGeometry: { scene.setSurface($0) },
                               onFirstFrame: { surfaceReady = true })
                .ignoresSafeArea()
                .remoteSurfaceAccessibility(controlEnabled: chrome.controlEnabled, inputMode: chrome.inputMode,
                                            paused: chrome.paused,
                                            identifier: surfaceReady ? "session.surface.ready" : "session.surface",
                                            fit: { scene.fit() }, actualSize: { scene.actualSize() },
                                            displays: { sheet = .displays }, togglePause: { setPaused(!chrome.paused) })
            if selection.isEmpty {
                EmptySelectionView { sheet = .displays }
            }
            if chrome.paused {
                PausedOverlay { setPaused(false) }
            }
            if let phase = config.statusPhase {
                ConnectionStatusCard(phase: phase, endpoint: GalleryDemo.endpoint) {}
            }
            SessionChrome(state: chrome, actions: actions, noticeAutoDismiss: nil,
                          onInsetsChange: { scene.setChromeInsets($0) })
        }
        .persistentSystemOverlays(chrome.controlsHidden ? .hidden : .automatic)
        .statusBarHidden(chrome.controlsHidden)
        .onAppear {
            scene.configure(selection: orderedSelection, cursor: config.cursor,
                            dimmed: chrome.paused || config.statusPhase != nil,
                            zoomIntoFirstDisplay: config.zoomIntoFirstDisplay)
        }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .environment(\.accessibilityOverrides, mergedOverrides)
    }

    private var mergedOverrides: AccessibilityOverrides {
        guard let forced = config.overrides else { return inheritedOverrides }
        return AccessibilityOverrides(reduceTransparency: forced.reduceTransparency || inheritedOverrides.reduceTransparency,
                                      reduceMotion: forced.reduceMotion || inheritedOverrides.reduceMotion,
                                      increaseContrast: forced.increaseContrast || inheritedOverrides.increaseContrast)
    }

    private var actions: SessionChromeActions {
        var actions = SessionChromeActions()
        actions.toggleControl = { chrome.controlEnabled.toggle() }
        actions.showDisplays = { sheet = .displays }
        actions.setInputMode = { chrome.inputMode = $0 }
        actions.toggleKeyboard = { chrome.keyboardVisible.toggle() }
        actions.togglePause = { setPaused(!chrome.paused) }
        actions.toggleAudio = { chrome.audioEnabled.toggle() }
        actions.showQuality = { sheet = .quality }
        actions.fit = { scene.fit() }
        actions.actualSize = { scene.actualSize() }
        actions.zoomIn = { scene.zoom(stepIn: true) }
        actions.zoomOut = { scene.zoom(stepIn: false) }
        actions.setControlsHidden = { chrome.controlsHidden = $0 }
        actions.showGestureGuide = { sheet = .gestures }
        actions.showDiagnostics = { sheet = .diagnostics }
        actions.dismissNotice = { chrome.notice = nil }
        return actions
    }

    private func setPaused(_ paused: Bool) {
        chrome.paused = paused
        chrome.statusLine = paused ? "Paused" : "Connected · HD"
        scene.setDimmed(paused)
    }

    private func setSelection(_ ids: Set<DisplayID>) {
        selection = ids
        chrome.selectedDisplays = ids.count
        scene.setSelection(orderedSelection)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: GallerySheet) -> some View {
        switch sheet {
        case .displays:
            DisplaysSheet(displays: GalleryDemo.displays, selection: selection,
                          streamSizes: GalleryDemo.streamSizes.filter { selection.contains($0.key) }, startsExpanded: true,
                          onToggle: { id in setSelection(selection.symmetricDifference([id])) },
                          onSelectAll: { setSelection(Set(GalleryDemo.displays.map(\.id))) },
                          onSelectNone: { setSelection([]) })
        case .quality:
            QualitySheet(settings: $settings, availability: GalleryDemo.availability,
                         status: GalleryDemo.qualityStatus(for: settings), startsExpanded: true)
        case .gestures:
            GestureGuideView(mode: chrome.inputMode, startsExpanded: true)
        case .diagnostics:
            DiagnosticsView(report: GalleryDemo.diagnostics, startsExpanded: true)
        }
    }
}

// MARK: - Keyboard

/// The accessory bar in its four states, stacked for review: modifiers, fn, More (with Type Pasted Text) and
/// mouse buttons with Hold Left pressed. All four share one `ModifierLatches` value.
private struct KeyboardGalleryPage: View {
    @State private var latches = GalleryDemo.latches
    @State private var held: MouseButtons? = .left
    @State private var panels: [AccessoryPanel?] = [nil, .functionKeys, .moreKeys, .mouse]
    @State private var log = "Tap a key or modifier."

    private static let captions = [
        "⌘ latched for the next action · ⇧ locked",
        "fn shows F1–F12",
        "More: Home, End, Page Up/Down, Forward Delete, Type Pasted Text",
        "Mouse buttons · Hold Left is pressed",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(0..<4, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Self.captions[index])
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(PortlightTheme.secondaryText)
                                .padding(.horizontal, 16)
                            bar(index)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(.horizontal, 8)
                        }
                    }
                    Text(log)
                        .font(.footnote.monospaced())
                        .foregroundStyle(PortlightTheme.secondaryText)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("keyboard.log")
                }
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Keyboard Bar")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func bar(_ index: Int) -> some View {
        KeyboardAccessoryBar(latches: latches, heldButton: held, panel: $panels[index],
                             onModifier: { latches.tap($0, at: ProcessInfo.processInfo.systemUptime) },
                             onKey: { log = "Key: \($0.accessibilityLabel)" },
                             onClick: { _ in log = "Click" },
                             onToggleHold: { button in held = held == button ? nil : button },
                             onPasteText: { log = "Typed \($0.count) pasted characters" })
    }
}

/// The real `inputAccessoryView` on the hidden text responder: above the software keyboard, or alone at the
/// bottom when the simulator has a hardware keyboard connected.
private struct KeyboardLiveGalleryPage: View {
    @State private var active = true
    @State private var latches = GalleryDemo.latches
    @State private var held: MouseButtons?
    @State private var panel: AccessoryPanel?
    @State private var typed = ""

    var body: some View {
        ZStack {
            GalleryBackdrop()
            VStack(spacing: 12) {
                Text("Hidden text responder")
                    .font(.headline)
                Text(typed.isEmpty ? "Typed text goes to onInsertText." : typed)
                    .font(.body.monospaced())
                    .foregroundStyle(PortlightTheme.secondaryText)
                Button(active ? "Hide Keyboard" : "Show Keyboard") { active.toggle() }
                    .secondaryActionStyle()
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
            // Above the keyboard at large text sizes there's little room: the page scrolls instead of clipping.
            .scrollsWhenTaller()
            RemoteTextInput(isActive: $active,
                            onInsertText: { typed += $0 },
                            onDeleteBackward: { if !typed.isEmpty { typed.removeLast() } },
                            onKey: { event in if event.down, !event.isRepeat { typed += "⌨︎" } }) {
                KeyboardAccessoryBar(latches: latches, heldButton: held, panel: $panel, usesBarBackground: false,
                                     onModifier: { latches.tap($0, at: ProcessInfo.processInfo.systemUptime) },
                                     onKey: { _ in },
                                     onClick: { _ in },
                                     onToggleHold: { button in held = held == button ? nil : button },
                                     onPasteText: { typed += $0 })
            }
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
    }
}
