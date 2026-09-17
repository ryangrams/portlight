import Foundation
import Observation

/// The single owner of one remote session: engine, framebuffer, audio, viewport, input and persistence.
///
/// SwiftUI observes only the low-frequency state below. The render loop reads the camera and cursor from
/// `transformStore` and `cursorStore` (locks, any thread), never from the view tree. Everything arriving
/// from other queues (engine callbacks, timers) passes through one ordered inbox drained on the main actor,
/// so the controller is a deterministic function of its inputs.
///
/// Rules it enforces:
/// - Frames have no path to the viewport; only gestures, geometry and explicit layout changes move it.
/// - Remote input is sent only while connected, with Control On, not paused, with a selection, and (for
///   presses and scrolls) over pixels that are valid for the current connection. Releases always go out.
/// - Nothing is held when a subscription goes out. The host releases all input when it *processes* a
///   subscribe (not when the phone reads `subscribed`), so input sent after one stays held there until it is
///   released. The controller therefore releases before every subscription it sends (control, selection, pause,
///   settings, topology, regions, recovery), and never assumes a release when `subscribed` arrives.
/// - The saved password is read from the Keychain only in `connect`, kept in memory for automatic reconnects,
///   and cleared by an explicit disconnect or cancel.
/// - No callback of a retired engine generation is ever applied (`issue`).
@MainActor @Observable
public final class SessionController {
    // MARK: Observable state (low frequency)

    public internal(set) var phase: ConnectionPhase = .idle
    public internal(set) var endpoint: HostEndpoint?
    public internal(set) var serverName: String?
    /// The host's displays in its arrangement (for the displays sheet map and list).
    public internal(set) var displays: [HostDisplay] = []
    /// Selected display IDs, in host order.
    public internal(set) var selection: [DisplayID] = []
    /// The desired state. Change it through the setters.
    public internal(set) var settings = SessionSettings()
    public internal(set) var capabilities: HostCapabilities?
    /// What the host applied for the accepted revision.
    public internal(set) var effective: EffectiveState?
    public internal(set) var presetAvailability: [PresetAvailability] = ResolutionPreset.allCases.map { PresetAvailability(preset: $0, isAvailable: true) }
    public internal(set) var audioState: SessionAudioState = .off
    /// A queue; the UI shows the first and calls `dismissNotice()`.
    public internal(set) var notices: [SessionNotice] = []
    /// Conditions Core's `SessionNotice` has no case for (an audio session that couldn't start, shortened text).
    /// A queue like `notices`: the UI shows the first and calls `dismissAlert()`.
    public internal(set) var alerts: [SessionAlert] = []
    public internal(set) var controlsHidden = false
    public internal(set) var keyboardRequested = false
    public internal(set) var latches: [ModifierKey: ModifierLatch] = SessionController.offLatches
    /// The held (Trackpad) or armed (Direct) button latch.
    public internal(set) var buttonLatch: MouseButtons?
    /// Merged at up to 2 Hz.
    public internal(set) var diagnostics = DiagnosticsSnapshot()
    /// Persistent Fit mode of the viewport (mirrors `viewport.isFit`).
    public internal(set) var isFit = true
    public internal(set) var isForeground = true
    public internal(set) var isSurfaceVisible = false
    /// The framebuffer holds pixels from this connection's computer (the frozen frame while reconnecting).
    public internal(set) var hasRetainedFrame = false
    /// The selected displays don't fit this device's memory even at HD: the stream is paused until the user
    /// chooses fewer displays (a notice explains it).
    public internal(set) var displayBudgetExceeded = false
    /// Why the last `connect` threw `SessionConnectError.passwordRequired` (nil after any other outcome).
    /// `.missingFromKeychain`: the profile says a password is saved for exactly this computer but the Keychain has
    /// none (for example after a restore to another iPhone) — clear the hint with
    /// `ProfileLibrary.recordSavedPassword(_:for: nil)` and save the library.
    public internal(set) var missingPassword: ConnectionCredentials.MissingPassword?

    // MARK: Derived state

    public var audioAvailable: Bool { capabilities?.supportsAudio ?? false }
    /// Reconnecting over the retained picture. It stays locally zoomable and is never controllable.
    public var isShowingFrozenFrame: Bool {
        guard hasRetainedFrame, case .reconnecting = phase else { return false }
        return true
    }
    /// Disable the idle timer only while a connected session is visible in the foreground.
    public var wantsIdleTimerDisabled: Bool { phase == .connected && isForeground && isSurfaceVisible }
    /// Remote input may be sent (presses and scrolls additionally need valid pixels at their target).
    public var allowsRemoteInput: Bool { phase == .connected && settings.allowsRemoteInput && !selection.isEmpty }
    /// The host advertises more displays than one subscription may carry (16).
    public var displayLimitExceeded: Bool { displays.count > PortlightProtocol.maxSubscribedDisplays }
    /// The local camera. Not observed: read it from `transformStore` in the render loop.
    public var viewport: ViewportModel { viewportModel }

    // MARK: Render-loop state (any thread)

    public nonisolated let transformStore = TransformStore()
    public nonisolated let cursorStore = CursorStore()

    // MARK: Machinery

    @ObservationIgnored let dependencies: SessionDependencies
    @ObservationIgnored let engine: SessionEngine
    @ObservationIgnored let inbox = SessionEventInbox()
    @ObservationIgnored let relay: SessionEngineRelay
    /// The engine's delegate queue and the queue controller timers fire on; both only post to `inbox`.
    @ObservationIgnored let eventQueue: DispatchQueue
    @ObservationIgnored let persistQueue = DispatchQueue(label: "studio.upgrade.portlight.session.persist", qos: .utility)
    @ObservationIgnored let interpreter: GestureInterpreter
    @ObservationIgnored let ledger = InputLedger()
    @ObservationIgnored let scheduler = RegionScheduler()
    @ObservationIgnored var workingLatches = ModifierLatches()
    @ObservationIgnored var viewportModel = ViewportModel()
    @ObservationIgnored var connection: ConnectionContext?
    @ObservationIgnored var reconnect: ReconnectState?
    /// Background closed the session; `.active` reconnects.
    @ObservationIgnored var suspendedForBackground = false
    /// Stamp of the latest engine command that started or ended a generation (see `issue`).
    @ObservationIgnored var epoch: UInt64 = 0
    @ObservationIgnored var timers: [SessionTimer: (token: UInt64, handle: Cancellable)] = [:]
    @ObservationIgnored var nextTimerToken: UInt64 = 0
    /// Desired regions (omitted = full). Reset to full by selection and topology changes.
    @ObservationIgnored var regions: [DisplayID: NormalizedRect] = [:]
    /// Regions of the accepted revision.
    @ObservationIgnored var acceptedRegions: [DisplayID: NormalizedRect] = [:]
    /// Lower resolution ceiling after the host's canvases exceeded the phone's budget.
    @ObservationIgnored var resolutionCap: ResolutionPreset?
    /// A recovery subscription waits for held input to be released.
    @ObservationIgnored var pendingRecovery = false
    /// A selection the user chose while a reconnect was on its way; it follows that attempt's revision 1.
    @ObservationIgnored var reapplySelection: [DisplayID]?
    /// Typed text not yet handed to the engine (paced in batches; see `enqueueTyping`).
    @ObservationIgnored var pendingTyping: [OutboundMessage] = []
    @ObservationIgnored var lastEngineDiagnostics: EngineDiagnostics?
    @ObservationIgnored var inputBlockedCount = 0
    @ObservationIgnored var audioControlEnabled: Bool?
    @ObservationIgnored var audioSessionState: AudioSessionState = .off
    /// The last non-Pan mode; Pan is never saved as a starting mode.
    @ObservationIgnored var lastNonPanMode: InputMode = .trackpad
    @ObservationIgnored var trustSaveFailures = 0
    /// Saves preference changes to the connected profile, off the main actor (nil without a profile store).
    @ObservationIgnored let preferenceWriter: SessionPreferenceWriter?

    static let offLatches: [ModifierKey: ModifierLatch] = Dictionary(uniqueKeysWithValues: ModifierKey.allCases.map { ($0, .off) })
    static let maxNotices = 4

    public init(dependencies: SessionDependencies) {
        self.dependencies = dependencies
        var configuration = dependencies.engineConfiguration
        configuration.maxTotalCanvasPixels = min(configuration.maxTotalCanvasPixels, max(1, dependencies.pixelBudget))
        let eventQueue = DispatchQueue(label: "studio.upgrade.portlight.session.events", qos: .userInitiated)
        let relay = SessionEngineRelay(inbox: inbox)
        let engine = SessionEngine(transportFactory: dependencies.transportFactory, clock: dependencies.clock,
                                   framebuffer: dependencies.framebuffer, audio: dependencies.audio, decoder: dependencies.decoder,
                                   configuration: configuration, delegateQueue: eventQueue, transcript: dependencies.transcript)
        eventQueue.sync { engine.delegate = relay }
        self.eventQueue = eventQueue
        self.relay = relay
        self.engine = engine
        interpreter = GestureInterpreter(configuration: dependencies.gestureConfiguration, mode: .trackpad, remoteEnabled: false)
        preferenceWriter = dependencies.profiles.map { SessionPreferenceWriter(store: $0) }
        inbox.setWake { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { _ = self?.processPendingEvents() }
            }
        }
        dependencies.audioControl?.onStateChange = { [weak self] state in self?.audioSessionStateChanged(state) }
        recomputePresetAvailability()
    }

    // MARK: Connection

    /// Starts a deliberate connection: the profile's preferences, the password (typed, else the saved one —
    /// the only Keychain read), the saved pin, and every display selected on revision 1.
    ///
    /// Throws `SessionConnectError` and then starts nothing; after `.passwordRequired`, `missingPassword` says why.
    public func connect(profile: ConnectionProfile, typedPassword: String = "") throws {
        missingPassword = nil
        guard let target = profile.endpoint else { throw SessionConnectError.invalidAddress }
        let resolution: ConnectionCredentials.PasswordResolution
        do {
            resolution = try ConnectionCredentials.resolvePassword(profile: profile, typedPassword: typedPassword,
                                                                   store: dependencies.secrets, connectingTo: target)
        } catch let error as SecretStoreError {
            throw SessionConnectError.keychain(error.errorDescription ?? "The saved password couldn’t be read.")
        } catch {
            throw SessionConnectError.keychain(error.localizedDescription)
        }
        guard let password = resolution.password else {
            if case .needsPassword(let reason) = resolution { missingPassword = reason }
            throw SessionConnectError.passwordRequired
        }

        releaseInput(clearingLatches: true)
        cancelAllTimers()
        settings = Self.settings(from: profile.preferences)
        lastNonPanMode = settings.inputMode
        resetSessionState()
        endpoint = target
        connection = ConnectionContext(profile: profile, endpoint: target, password: password,
                                       pin: dependencies.trust.pinnedFingerprint(for: target))
        startAttempt(previousSelection: nil)
        // A deliberate connection never shows another computer's (or an older) picture. Cleared only now: starting
        // the attempt retired the previous generation on this thread, so nothing of it can land after this. The new
        // attempt can't paint before its host has answered.
        dependencies.framebuffer.removeAll()
    }

    /// Pins the prompt's certificate and reconnects with it (a new generation). A stale prompt is ignored.
    public func approveTrust(_ prompt: TrustPrompt) {
        guard case .awaitingTrust(let current) = phase, current.id == prompt.id, var context = connection,
              prompt.endpoint.canonicalKey == context.endpoint.canonicalKey else { return }
        do {
            try dependencies.trust.pin(prompt.fingerprint, for: prompt.endpoint)
        } catch {
            // The approved pin still protects this attempt; it just won't be remembered.
            trustSaveFailures += 1
        }
        context.pin = prompt.fingerprint
        connection = context
        reconnect = nil
        startAttempt(previousSelection: context.attemptPreviousSelection)
    }

    /// The user refused the certificate: nothing was sent, and nothing retries.
    public func declineTrust(_ prompt: TrustPrompt) {
        guard case .awaitingTrust(let current) = phase, current.id == prompt.id else { return }
        reconnect = nil
        cancelTimer(.reconnect)
        phase = .failed(.trustDeclined)
        syncDerivedState()
    }

    /// Try Again after a failure, with the same computer, password and pin. False when a password is needed
    /// again (after it was rejected) or there is nothing to retry.
    @discardableResult
    public func retry() -> Bool {
        guard let context = connection, case .failed = phase, context.password != nil else { return false }
        reconnect = nil
        startAttempt(previousSelection: context.established ? selection : nil)
        return true
    }

    /// Ends an attempt in progress (or the session) and returns to `.idle`.
    public func cancel() { endExplicitly(cancel: true) }

    /// Explicit disconnect: releases input, stops audio, closes gracefully, forgets the password and pixels.
    public func disconnect() { endExplicitly(cancel: false) }

    public func dismissNotice() {
        if !notices.isEmpty { notices.removeFirst() }
    }

    public func dismissAlert() {
        if !alerts.isEmpty { alerts.removeFirst() }
    }

    // MARK: Saved connections

    /// Serializes the app's own writes of the saved-connections file with the session's writes of `preferences` and
    /// `lastConnectedAt` (read-modify-write, off the main actor). `body` runs on the calling thread after every
    /// session write queued so far and before any queued later, so a load → merge → save inside it can neither miss
    /// nor overwrite one. Returns what `body` returns and rethrows its error.
    ///
    /// Call on the main actor; the caller waits for earlier session writes (small files). `body` must not wait on
    /// the controller; a nested call runs in place. Without a profile store it simply runs `body`.
    public func withProfileWritesSerialized<T>(_ body: () throws -> T) rethrows -> T {
        guard let writer = preferenceWriter else { return try body() }
        return try writer.serialized(body)
    }

    // MARK: Shared helpers

    func endExplicitly(cancel: Bool) {
        releaseInput(clearingLatches: true)
        cancelAllTimers()
        reconnect = nil
        suspendedForBackground = false
        connection = nil
        updateAudioControl()
        dependencies.audio.stopAudio()
        issue { if cancel { engine.cancel() } else { engine.disconnect() } }
        // After the retire above, so no patch or revision of the session can recreate a surface.
        dependencies.framebuffer.removeAll()
        resetSessionState()
        phase = .idle
        syncDerivedState()
    }

    /// Per-connection state back to its initial values (settings stay).
    func resetSessionState() {
        hasRetainedFrame = false
        effective = nil
        notices.removeAll()
        alerts.removeAll()
        displays = []
        selection = []
        capabilities = nil
        serverName = nil
        endpoint = nil
        regions = [:]
        acceptedRegions = [:]
        resolutionCap = nil
        pendingRecovery = false
        reapplySelection = nil
        cancelTyping()
        lastEngineDiagnostics = nil
        scheduler.resetForConnection()
        viewportModel.setLayout([:], hostScales: [:])
        interpreter.setCursor(nil)
        cursorStore.set(nil)
        recomputePresetAvailability()
    }

    /// One engine attempt with the current context (a new generation; see `issue`).
    func startAttempt(previousSelection: [DisplayID]?) {
        guard var context = connection else { return }
        context.attemptPreviousSelection = previousSelection
        context.fitOnFirstAccept = previousSelection == nil
        connection = context
        cancelTimer(.reconnect)
        suspendedForBackground = false
        // Work that was waiting for the old connection means nothing to the new one: it starts with a fresh
        // complete subscription.
        pendingRecovery = false
        reapplySelection = nil
        hostReleasedInput()
        phase = reconnect.map { .reconnecting(attempt: $0.displayedAttempt, after: $0.lastFailure) } ?? .connecting(patient: false)
        let planner = DefaultSubscriptionPlanner(settings: settings, pixelBudget: dependencies.pixelBudget, resolutionCap: resolutionCap)
        let request = ConnectRequest(endpoint: context.endpoint, pin: context.pin, password: context.password ?? "",
                                     planner: planner, previousSelection: previousSelection)
        issue { engine.connect(request) }
        syncDerivedState()
    }

    /// Runs an engine command that starts or ends a generation (connect, disconnect, cancel) so that no callback
    /// of an older generation is ever applied.
    ///
    /// The engine retires the old generation on the calling thread and drops its callbacks from then on. Two kinds
    /// can still reach the controller, though: callbacks the engine already delivered (waiting in `inbox` for the
    /// main-actor drain), and one being delivered on the event queue at this very moment (it passed the engine's
    /// check just before the retire). So the command runs while this thread holds the event queue — the engine's
    /// delegate queue — and the relay's stamp moves in the same block: every callback delivered before carries an
    /// older stamp and is ignored; every later one belongs to this command. Only the engine's public contract is
    /// relied on (no engine-internal queue). Nothing on the event queue ever waits for the main thread, so this
    /// can't deadlock.
    func issue(_ command: () -> Void) {
        epoch &+= 1
        let stamp = epoch, relay = self.relay
        eventQueue.sync {
            command()
            relay.stamp = stamp
        }
    }

    /// Sends the complete desired state (the engine drops one equivalent to the last it sent, unless forced).
    func submitDesired(force: Bool = false) {
        guard connection != nil, !suspendedForBackground else { return }
        // Nothing may be held when a subscription goes out: the host releases all input when it processes the
        // subscribe (Server.swift applySubscription), so the ledger must not keep believing it's down. Callers that
        // change control state released already; what can still be down here is a Locked sticky modifier (region
        // refinement, recovery). It goes up first and is re-asserted before the next action.
        send(ledger.releaseAll())
        engine.submit(desiredRequest(), force: force)
    }

    func desiredRequest() -> SubscriptionRequest {
        DefaultSubscriptionPlanner.request(displays: displays, selection: selection, settings: settings, capabilities: capabilities,
                                           pixelBudget: dependencies.pixelBudget, resolutionCap: resolutionCap, regions: regions)
    }

    func post(_ notice: SessionNotice) {
        guard !notices.contains(notice) else { return }
        notices.append(notice)
        if notices.count > Self.maxNotices { notices.removeFirst(notices.count - Self.maxNotices) }
    }

    func post(_ alert: SessionAlert) {
        guard !alerts.contains(alert) else { return }
        alerts.append(alert)
        if alerts.count > Self.maxNotices { alerts.removeFirst(alerts.count - Self.maxNotices) }
    }

    // MARK: Timers (injected clock; firing posts to the inbox)

    func schedule(_ timer: SessionTimer, after delay: TimeInterval) {
        cancelTimer(timer)
        nextTimerToken &+= 1
        let token = nextTimerToken, inbox = self.inbox
        let handle = dependencies.clock.schedule(after: max(0, delay), on: eventQueue) { inbox.post(.timer(timer, token: token)) }
        timers[timer] = (token, handle)
    }

    func cancelTimer(_ timer: SessionTimer) {
        timers.removeValue(forKey: timer)?.handle.cancel()
    }

    func cancelAllTimers() {
        for timer in timers.values { timer.handle.cancel() }
        timers.removeAll()
    }

    /// True when this firing is the live one for its timer (and consumes it).
    func claimTimer(_ timer: SessionTimer, token: UInt64) -> Bool {
        guard timers[timer]?.token == token else { return false }
        timers[timer] = nil
        return true
    }

    // MARK: Derived-state sync

    /// Re-derives interpreter enablement, cursor visibility, audio and the published camera after any change.
    func syncDerivedState() {
        syncInterpreter()
        cursorStore.setVisible(phase == .connected && !selection.isEmpty && settings.inputMode != .pan)
        updateAudioControl()
        refreshAudioState()
        publishViewport()
    }

    func publishViewport() {
        transformStore.publish(viewportModel, dimmed: settings.paused || isShowingFrozenFrame)
        if isFit != viewportModel.isFit { isFit = viewportModel.isFit }
    }

    static func settings(from preferences: ViewerPreferences) -> SessionSettings {
        SessionSettings(resolution: preferences.resolution, color: preferences.color, quality: preferences.quality,
                        smoothGradients: preferences.smoothGradients, bandwidthKbps: preferences.bandwidthKbps,
                        audioEnabled: false, audioQuality: preferences.audioQuality, controlEnabled: true, paused: false,
                        inputMode: preferences.inputMode == .pan ? .trackpad : preferences.inputMode)
    }
}

/// The computer and credentials of the current session. The password lives only here, only in memory.
struct ConnectionContext {
    let profile: ConnectionProfile
    let endpoint: HostEndpoint
    var password: String?
    var pin: CertificateFingerprint?
    /// Reached `.connected` at least once: later losses reconnect automatically with the selection.
    var established = false
    var attemptPreviousSelection: [DisplayID]?
    var fitOnFirstAccept = true
}

/// An automatic reconnect in progress (foreground only).
struct ReconnectState {
    /// Shown as "attempt N"; counts every try, busy retries included.
    var displayedAttempt: Int
    /// Position on the policy's ladder; busy retries don't advance it.
    var ladderAttempt: Int
    var firstFailureAt: TimeInterval
    var lastFailure: ConnectionFailure
}
