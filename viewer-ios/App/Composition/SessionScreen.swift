import SwiftUI
import UIKit
import Combine
import PortlightKit

enum SessionSheet: String, Identifiable {
    case displays, quality, gestures, diagnostics
    var id: String { rawValue }
}

/// The session (UI-SPEC §5), bound to the one `SessionController`: the Metal surface full-bleed, the progress,
/// trust and failure UI for the attempt, the paused and empty overlays, the chrome and its sheets, the hidden text
/// responder with the keyboard bar, and the privacy cover whenever the scene isn't active.
///
/// High-frequency state never passes through here: the surface reads the controller's transform and cursor
/// stores on each display-link tick, and forwards raw touches and ticks straight to the controller.
struct SessionScreen: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: SessionSheet?
    @State private var surface: SurfaceGeometry?
    @State private var chromeInsets = ChromeInsets.zero
    /// The keyboard's top edge in surface points; nil while no keyboard is shown.
    @State private var keyboardTop: CGFloat?
    @State private var surfaceReady = false
    @State private var accessoryPanel: AccessoryPanel?
    @State private var idleTimerBefore: Bool?

    static let gestureGuideSeenKey = "studio.upgrade.portlight.gestureGuideShown"

    private var controller: SessionController { model.controller }
    private var settings: SessionSettings { controller.settings }
    private var showsChrome: Bool {
        SessionPresentation.showsChrome(phase: controller.phase, isShowingFrozenFrame: controller.isShowingFrozenFrame)
    }

    var body: some View {
        ZStack {
            surfaceLayer
            backdrop
            attemptLayer
            if showsChrome {
                SessionChrome(state: chromeState, actions: chromeActions, onInsetsChange: { insets in
                    chromeInsets = insets
                    pushGeometry()
                })
            }
            if controller.phase == .connected {
                textInput
            }
            if scenePhase != .active {
                PrivacyCoverView()
            }
        }
        .persistentSystemOverlays(controller.controlsHidden && showsChrome ? .hidden : .automatic)
        .statusBarHidden(controller.controlsHidden && showsChrome)
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        // "Audio Couldn't Start" and "Text Shortened": one at a time, each dismissed by any button.
        .alert(controller.alerts.first?.title ?? "",
               isPresented: Binding(get: { !controller.alerts.isEmpty }, set: { if !$0 { controller.dismissAlert() } }),
               presenting: controller.alerts.first) { alert in
            if alert.offersResume {
                Button("Resume") { controller.resumeAudio() }
            }
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .onAppear(perform: appeared)
        .onDisappear(perform: disappeared)
        .onChange(of: controller.wantsIdleTimerDisabled) { _, wants in
            UIApplication.shared.isIdleTimerDisabled = wants || (idleTimerBefore ?? false)
        }
        .onChange(of: controller.phase == .connected) { _, connected in
            if connected { showGestureGuideOnce() }
        }
        .onChange(of: showsChrome) { pushGeometry() }
        .onChange(of: controller.controlsHidden) { pushGeometry() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            keyboardTop = frame.map { $0.minY }
            pushGeometry()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardTop = nil
            pushGeometry()
        }
    }

    // MARK: Layers

    private var surfaceLayer: some View {
        let transforms = controller.transformStore
        let cursor = controller.cursorStore
        return SessionSurfaceView(renderer: model.environment.renderer,
                                  sceneProvider: { transforms.scene(cursor: cursor) },
                                  onTouch: { event, time in controller.touch(event, at: time) },
                                  onGeometry: { geometry in
                                      surface = geometry
                                      pushGeometry()
                                  },
                                  onFirstFrame: { surfaceReady = true },
                                  onTick: { time in controller.tick(at: time) })
            .ignoresSafeArea()
            .remoteSurfaceAccessibility(controlEnabled: settings.controlEnabled, inputMode: settings.inputMode,
                                        paused: settings.paused,
                                        identifier: surfaceReady ? "session.surface.ready" : "session.surface",
                                        fit: { controller.fit() }, actualSize: { controller.actualSize() },
                                        displays: { sheet = .displays },
                                        togglePause: { controller.setPaused(!settings.paused) })
    }

    /// Before any picture of this computer exists the cards sit on a neutral backdrop, not the black letterbox.
    @ViewBuilder
    private var backdrop: some View {
        if controller.phase != .connected && !controller.hasRetainedFrame {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var attemptLayer: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .connected:
            if controller.selection.isEmpty {
                EmptySelectionView { sheet = .displays }
            } else if settings.paused {
                PausedOverlay { controller.setPaused(false) }
            }
        case .failed(let failure):
            ConnectionFailureCard(failure: failure, endpoint: controller.endpoint, dismissTitle: "Edit Connection",
                                  onTryAgain: { model.retry() }, onDismiss: { controller.cancel() })
        case .connecting, .checkingIdentity, .awaitingTrust, .authenticating, .loadingDisplays, .reconnecting:
            ConnectionStatusCard(phase: controller.phase, endpoint: controller.endpoint) { controller.cancel() }
                .sheet(item: Binding(get: { trustPrompt }, set: { _ in })) { prompt in
                    TrustSheet(prompt: prompt,
                               onTrust: { controller.approveTrust($0) },
                               onCancel: { controller.declineTrust($0) })
                }
        }
    }

    private var trustPrompt: TrustPrompt? {
        if case .awaitingTrust(let prompt) = controller.phase { return prompt }
        return nil
    }

    /// The hidden text responder: software-keyboard text, Backspace and hardware keys go to the controller, and
    /// the keyboard bar rides on it as the input accessory.
    private var textInput: some View {
        RemoteTextInput(isActive: Binding(get: { controller.keyboardRequested }, set: { controller.setKeyboardRequested($0) }),
                        onInsertText: { controller.insertText($0) },
                        onDeleteBackward: { controller.deleteBackward() },
                        onKey: { event in
                            controller.press(hidUsage: event.hidUsage, characters: event.charactersIgnoringModifiers,
                                             modifiers: event.modifiers, down: event.down)
                        }) {
            KeyboardAccessoryBar(latches: ModifierLatches(displaying: controller.latches), heldButton: controller.buttonLatch,
                                 panel: $accessoryPanel, usesBarBackground: false,
                                 onModifier: { controller.tapModifier($0) },
                                 onKey: { controller.pressSoftKey($0) },
                                 onClick: { controller.click($0) },
                                 onToggleHold: { controller.toggleButtonLatch($0) },
                                 onPasteText: { controller.typePastedText($0) })
        }
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
    }

    // MARK: Chrome

    private var chromeState: SessionChromeState {
        SessionChromeState(computerName: model.sessionTitle,
                           statusLine: SessionPresentation.statusLine(phase: controller.phase, paused: settings.paused,
                                                                      effective: controller.effective?.resolution),
                           controlEnabled: settings.controlEnabled, inputMode: settings.inputMode,
                           selectedDisplays: controller.selection.count, totalDisplays: controller.displays.count,
                           keyboardVisible: controller.keyboardRequested, paused: settings.paused,
                           audioEnabled: settings.audioEnabled,
                           audioUnavailableReason: SessionPresentation.audioUnavailableReason(capabilities: controller.capabilities),
                           controlsHidden: controller.controlsHidden, notice: controller.notices.first)
    }

    private var chromeActions: SessionChromeActions {
        var actions = SessionChromeActions()
        actions.disconnect = { controller.disconnect() }
        actions.toggleControl = { controller.setControlEnabled(!controller.settings.controlEnabled) }
        actions.showDisplays = { sheet = .displays }
        actions.setInputMode = { controller.setInputMode($0) }
        actions.toggleKeyboard = { controller.setKeyboardRequested(!controller.keyboardRequested) }
        actions.togglePause = { controller.setPaused(!controller.settings.paused) }
        actions.toggleAudio = { controller.setAudioEnabled(!controller.settings.audioEnabled) }
        actions.showQuality = { sheet = .quality }
        actions.fit = { controller.fit() }
        actions.actualSize = { controller.actualSize() }
        actions.zoomIn = { controller.zoom(in: true) }
        actions.zoomOut = { controller.zoom(in: false) }
        actions.setControlsHidden = { controller.setControlsHidden($0) }
        actions.showGestureGuide = { sheet = .gestures }
        actions.showDiagnostics = {
            controller.refreshDiagnostics()
            sheet = .diagnostics
        }
        actions.dismissNotice = { controller.dismissNotice() }
        actions.resumeAudio = { controller.resumeAudio() }
        return actions
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: SessionSheet) -> some View {
        switch sheet {
        case .displays:
            DisplaysSheet(displays: controller.displays, selection: Set(controller.selection),
                          streamSizes: controller.effective?.canvases ?? [:],
                          onToggle: { controller.toggleDisplay($0) },
                          onSelectAll: { controller.selectAll() },
                          onSelectNone: { controller.selectNone() })
        case .quality:
            QualitySheet(settings: qualityBinding, availability: controller.presetAvailability,
                         status: SessionPresentation.qualityStatus(settings: settings, effective: controller.effective,
                                                                   budgetExceeded: controller.displayBudgetExceeded),
                         audioUnavailableReason: SessionPresentation.audioUnavailableReason(capabilities: controller.capabilities))
        case .gestures:
            GestureGuideView(mode: settings.inputMode)
        case .diagnostics:
            DiagnosticsView(report: SessionPresentation.diagnosticsReport(controller.diagnostics, displays: controller.displays,
                                                                          requested: settings.resolution,
                                                                          computerName: model.sessionTitle))
        }
    }

    /// The sheet edits a copy of the settings; each changed field goes to its controller setter (which saves it to
    /// the profile and resubscribes).
    private var qualityBinding: Binding<SessionSettings> {
        Binding(get: { controller.settings }, set: { edited in
            let current = controller.settings
            if edited.resolution != current.resolution { controller.setResolution(edited.resolution) }
            if edited.color != current.color { controller.setColor(edited.color) }
            if edited.quality != current.quality { controller.setQuality(edited.quality) }
            if edited.smoothGradients != current.smoothGradients { controller.setSmoothGradients(edited.smoothGradients) }
            if edited.bandwidthKbps != current.bandwidthKbps { controller.setBandwidth(kbps: edited.bandwidthKbps) }
            if edited.audioQuality != current.audioQuality { controller.setAudioQuality(edited.audioQuality) }
        })
    }

    // MARK: Lifecycle and geometry

    private func appeared() {
        controller.setSurfaceVisible(true)
        let before = UIApplication.shared.isIdleTimerDisabled
        idleTimerBefore = before
        UIApplication.shared.isIdleTimerDisabled = controller.wantsIdleTimerDisabled || before
    }

    private func disappeared() {
        controller.setSurfaceVisible(false)
        controller.setKeyboardRequested(false)
        UIApplication.shared.isIdleTimerDisabled = idleTimerBefore ?? false
    }

    /// Shown automatically the first time a session connects; later from More.
    private func showGestureGuideOnce() {
        let defaults = model.environment.defaults
        guard !defaults.bool(forKey: Self.gestureGuideSeenKey) else { return }
        defaults.set(true, forKey: Self.gestureGuideSeenKey)
        if sheet == nil { sheet = .gestures }
    }

    /// Fit uses the safe area minus the visible chrome and keyboard, so nothing it places is hidden.
    private func pushGeometry() {
        guard let surface else { return }
        let insets = showsChrome ? chromeInsets : .zero
        let overlap = SessionPresentation.keyboardOverlap(keyboardTop: keyboardTop, surface: surface)
        let usable = SessionPresentation.usableRect(safe: surface.usableRect, contentScale: surface.contentScale,
                                                    chrome: insets, keyboardOverlap: overlap)
        controller.surfaceGeometryChanged(drawableSize: surface.drawableSize, usableRect: usable, contentScale: surface.contentScale)
    }

    static func sessionPhase(_ phase: ScenePhase) -> SessionScenePhase {
        switch phase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }
}
