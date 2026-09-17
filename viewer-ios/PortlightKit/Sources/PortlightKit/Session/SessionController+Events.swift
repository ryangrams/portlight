import Foundation

// Engine callbacks and timers, applied on the main actor in the order they happened.
extension SessionController {
    var now: TimeInterval { dependencies.clock.now() }

    /// Applies every pending engine callback and timer, in order. Scheduled on the main queue whenever
    /// something is posted; tests call it directly after draining the engine. True when anything ran.
    @discardableResult
    func processPendingEvents() -> Bool {
        let events = inbox.takeAll()
        for event in events { handle(event) }
        return !events.isEmpty
    }

    func handle(_ event: SessionEvent) {
        switch event {
        case .timer(let timer, let token):
            guard claimTimer(timer, token: token) else { return }
            switch timer {
            case .settle: evaluateRegions()
            case .reconnect: reconnectTimerFired()
            case .typing: sendTypingBatch()
            }
        case .engine(let callback, let stamp):
            // Callbacks of a retired generation (an older stamp), or after the session ended, change nothing.
            guard stamp == epoch, connection != nil, !suspendedForBackground else { return }
            handleEngine(callback)
        }
    }

    private func handleEngine(_ callback: EngineCallback) {
        switch callback {
        case .phase(let next): enginePhaseChanged(next)
        case .welcome(let welcome, let topologyChange):
            if topologyChange { topologyChanged(welcome) } else { welcomed(welcome) }
        case .sent(let request): didSend(request)
        case .accepted(let ack, let request): didAccept(ack, for: request)
        case .hostReported(let error): hostReported(error)
        case .cursor(let cursor): hostCursor(cursor)
        case .stats: break // folded into the engine's diagnostics
        case .diagnostics(let snapshot):
            lastEngineDiagnostics = snapshot
            mergeDiagnostics(newEngineSample: true)
        case .recovery:
            pendingRecovery = true
            runDeferredWork()
        case .budgetExceeded(let ack): canvasBudgetExceeded(ack)
        }
    }

    // MARK: Phases and reconnect

    func enginePhaseChanged(_ next: ConnectionPhase) {
        guard var context = connection else { return }
        switch next {
        case .idle:
            return // only our own disconnect produces it, and that path has already set the phase
        case .connected:
            let first = !context.established
            context.established = true
            connection = context
            reconnect = nil
            cancelTimer(.reconnect)
            phase = .connected
            if first { recordConnected() }
        case .failed(let failure):
            engineFailed(failure)
        case .awaitingTrust(let prompt):
            // First use or a changed certificate: the user decides; nothing retries meanwhile.
            reconnect = nil
            cancelTimer(.reconnect)
            hostReleasedInput()
            phase = .awaitingTrust(prompt)
        case .connecting, .checkingIdentity, .authenticating, .loadingDisplays, .reconnecting:
            phase = reconnect.map { .reconnecting(attempt: $0.displayedAttempt, after: $0.lastFailure) } ?? next
        }
        syncDerivedState()
        runDeferredWork()
    }

    func engineFailed(_ failure: ConnectionFailure) {
        guard var context = connection else { return }
        hostReleasedInput()
        workingLatches.clearAll()
        publishLatches()
        if case .certificateChanged(let prompt) = failure {
            reconnect = nil
            cancelTimer(.reconnect)
            phase = .awaitingTrust(prompt)
            return
        }
        if case .authenticationRejected = failure {
            // Never retried, so the rejected password has no further use.
            context.password = nil
            connection = context
        }
        let lostSession = context.established || reconnect != nil
        guard lostSession else { phase = .failed(failure); return }
        let isBusy: Bool
        if case .busy = failure { isBusy = true } else { isBusy = false }
        guard isForeground else {
            // Retries run only in the foreground; becoming active starts over.
            if failure.allowsAutomaticRetry || isBusy {
                suspendedForBackground = true
                reconnect = nil
                phase = .reconnecting(attempt: 0, after: .networkLost)
            } else {
                phase = .failed(failure)
            }
            return
        }
        let time = now
        var state = reconnect ?? ReconnectState(displayedAttempt: 0, ladderAttempt: 0, firstFailureAt: time, lastFailure: failure)
        let ladder = isBusy ? max(1, state.ladderAttempt) : state.ladderAttempt + 1
        let decision = dependencies.reconnectPolicy.decision(after: failure, attempt: ladder, automatic: true,
                                                             elapsedSinceFirstFailure: time - state.firstFailureAt,
                                                             random: dependencies.random())
        switch decision {
        case .retry(let delay):
            state.displayedAttempt += 1
            if !isBusy { state.ladderAttempt = ladder }
            state.lastFailure = failure
            reconnect = state
            phase = .reconnecting(attempt: state.displayedAttempt, after: failure)
            schedule(.reconnect, after: delay)
        case .stop:
            reconnect = nil
            phase = .failed(failure)
        }
    }

    func reconnectTimerFired() {
        guard let context = connection, reconnect != nil, isForeground, !suspendedForBackground else { return }
        startAttempt(previousSelection: context.established ? selection : context.attemptPreviousSelection)
    }

    // MARK: Welcome, topology and subscriptions

    func welcomed(_ welcome: WelcomeMessage) {
        guard let context = connection else { return }
        // A reconnect over the frozen frame: a selection the user chose while the attempt was on its way follows
        // revision 1 (which carries the selection the attempt started with) instead of being silently reverted.
        if let started = context.attemptPreviousSelection, started != selection { reapplySelection = selection }
        serverName = welcome.serverName
        capabilities = welcome.capabilities
        displays = welcome.displays
        // The engine already sent the planner's revision 1 with exactly this selection.
        selection = DefaultSubscriptionPlanner.initialSelection(displays: welcome.displays, previousSelection: context.attemptPreviousSelection)
        regions = [:]
        acceptedRegions = [:]
        displayBudgetExceeded = false
        scheduler.resetForConnection()
        applyLayout()
        recomputePresetAvailability()
        if settings.audioEnabled && !audioAvailable { post(.audioUnavailable) }
        syncDerivedState()
    }

    /// The host's arrangement changed (it already cleared its subscription and released input). The
    /// selection is intersected with the new displays; an empty result stays empty.
    func topologyChanged(_ welcome: WelcomeMessage) {
        releaseInput()
        hostReleasedInput()
        capabilities = welcome.capabilities
        displays = welcome.displays
        selection = DefaultSubscriptionPlanner.hostOrdered(selection, in: welcome.displays)
        regions = [:]
        resolutionCap = nil
        displayBudgetExceeded = false
        scheduler.cancel()
        applyLayout()
        recomputePresetAvailability()
        post(.displaysChanged)
        syncDerivedState()
        submitDesired()
    }

    func didSend(_ request: SubscriptionRequest) {
        scheduler.recordSent(at: now)
        guard request.revision == 1 else { return }
        // Revision 1 comes from the planner; it is authoritative for the selection.
        if request.displays != selection {
            selection = request.displays
            applyLayout()
            recomputePresetAvailability()
            syncDerivedState()
        }
        if let wanted = reapplySelection {
            reapplySelection = nil
            setSelection(wanted) // intersected with this host's displays
        }
    }

    func didAccept(_ ack: SubscribedMessage, for request: SubscriptionRequest) {
        guard var context = connection else { return }
        // No `hostDidReleaseInput` here. The host released what it held when it *processed* this subscribe, and
        // nothing was held then (`submitDesired` releases first). Anything held now was pressed after the subscribe
        // went out, so the host still holds it and must get its release.
        acceptedRegions = request.regions
        scheduler.accepted(regions: request.regions)
        let canvases = Dictionary(ack.canvases.map { ($0.display, $0.size) }, uniquingKeysWith: { first, _ in first })
        let total = ack.canvases.reduce(0) { $0 + $1.size.pixelCount }
        let allocated = total <= engine.configuration.maxTotalCanvasPixels
        effective = EffectiveState(revision: ack.revision, displays: request.displays, resolution: ack.resolution,
                                   canvases: allocated ? canvases : [:], paused: ack.paused, viewOnly: request.viewOnly,
                                   audioEnabled: ack.audio, audioCodec: ack.audioCodec, audioBitrate: ack.audioBitrate,
                                   regions: request.regions, hostNotice: ack.notice)
        if allocated && !canvases.isEmpty { hasRetainedFrame = true }
        if let notice = ack.notice, !notice.isEmpty { post(.resolutionLimited(notice)) }
        if context.fitOnFirstAccept {
            // A deliberate connection starts fitted to the whole selection.
            context.fitOnFirstAccept = false
            connection = context
            changeViewport { $0.fit() }
        }
        syncDerivedState()
        runDeferredWork()
    }

    func hostReported(_ error: HostErrorMessage) {
        switch error.code {
        case .capture:
            post(.captureFailed(error.message.isEmpty ? "Screen capture failed on the Mac. Check Screen Recording permission for Portlight Host." : error.message))
        case .subscription, .message:
            // The desired state stays; the previous revision keeps streaming.
            post(.settingsRejected(error.message.isEmpty ? "The Mac didn’t apply the change." : error.message))
        case .topology:
            post(.displaysChanged)
        case .authentication, .busy, .timeout, .other:
            break
        }
    }

    /// The engine declined the host's canvases (nothing allocated) and resent the request paused. Lower the
    /// resolution when that helps; otherwise ask for fewer displays. Displays are never dropped silently.
    func canvasBudgetExceeded(_ ack: SubscribedMessage) {
        // The host applied the refused revision and then the engine's paused resend, releasing whatever was pressed
        // before either; release here too, so input pressed around them ends the same way on both sides (a mask
        // the host no longer has would otherwise come back as a phantom press).
        releaseInput()
        let budget = engine.configuration.maxTotalCanvasPixels
        let selected = DefaultSubscriptionPlanner.selectedDisplays(displays, selection)
        let refused = ack.canvases.reduce(0) { $0 + $1.size.pixelCount }
        var current = desiredRequest().resolution
        if case .preset(let applied)? = ack.resolution { current = min(current, applied) }
        let lower = ResolutionPreset.allCases.reversed().first { preset in
            guard preset < current else { return false }
            let predicted = RenderBudget.predictedPixels(displays: selected, preset: preset)
            return predicted <= budget && predicted < refused
        }
        if let lower {
            resolutionCap = lower
            let count = selected.count
            post(.resolutionLimited("Streaming at \(lower.title) so \(count == 1 ? "this display fits" : "\(count) displays fit") in this iPhone’s memory."))
            recomputePresetAvailability()
            submitDesired()
        } else {
            displayBudgetExceeded = true
            post(.resolutionLimited("These displays need more memory than this iPhone allows. Choose fewer displays."))
        }
    }

    func hostCursor(_ cursor: CursorMessage) {
        guard let rect = viewportModel.layout[cursor.display], cursor.x.isFinite, cursor.y.isFinite else { return }
        let point = LogicalPoint(x: rect.minX + min(max(cursor.x, 0), 1) * rect.width,
                                 y: rect.minY + min(max(cursor.y, 0), 1) * rect.height)
        route(interpreter.reconcileCursor(hostPoint: point, at: now))
    }

    // MARK: Diagnostics and audio

    /// Merges engine, framebuffer, renderer, audio and scheduler counters for the diagnostics view. The engine
    /// reports every 0.5 s; calling this in between refreshes the other counters and keeps the last receive rate.
    public func refreshDiagnostics() { mergeDiagnostics(newEngineSample: false) }

    func mergeDiagnostics(newEngineSample: Bool) {
        let inspector = dependencies.framebuffer as? FramebufferInspecting
        diagnostics = DiagnosticsSnapshot.merged(at: now, engine: lastEngineDiagnostics ?? EngineDiagnostics(), newEngineSample: newEngineSample,
                                                 previous: diagnostics, audio: dependencies.audioMetrics?(), framebuffer: inspector?.counters,
                                                 presentation: dependencies.presentation, regions: scheduler.snapshot(at: now),
                                                 requested: settings.resolution, effective: effective, inputBlocked: inputBlockedCount)
        checkFreshRegion()
        refreshAudioState()
    }

    func checkFreshRegion() {
        guard scheduler.awaitingFreshRegion, let inspector = dependencies.framebuffer as? FramebufferInspecting else { return }
        scheduler.checkFresh(at: now) { inspector.coverage(display: $0)?.isCovered }
    }

    func audioSessionStateChanged(_ state: AudioSessionState) {
        audioSessionState = state
        switch state {
        case .interrupted, .paused:
            alerts.removeAll { $0.offersResume }
            post(.audioInterrupted)
        case .failed(let detail):
            // Not a route change: say that audio couldn't start. Resume retries activation (an earlier
            // `.audioInterrupted` notice stays, and its Resume works here too).
            post(.audioFailed(detail))
        case .off, .active:
            // Audio is back (or turned off): a "Tap Resume" banner no longer applies.
            notices.removeAll { $0 == .audioInterrupted }
            alerts.removeAll { $0.offersResume }
        }
        refreshAudioState()
    }

    func refreshAudioState() {
        let wanted = settings.audioEnabled && !settings.paused && audioAvailable && phase == .connected
        let next: SessionAudioState
        switch audioSessionState {
        case .interrupted, .paused, .failed:
            next = wanted ? .interrupted : .off
        case .off, .active:
            if !wanted {
                next = .off
            } else if effective?.audioEnabled == true, dependencies.audioMetrics?().isPlaying ?? true {
                next = .playing
            } else {
                next = .starting
            }
        }
        if audioState != next { audioState = next }
    }

    /// The platform audio session is active only while audio is wanted, unpaused, in the foreground.
    func updateAudioControl() {
        let wanted = connection != nil && isForeground && !suspendedForBackground
            && settings.audioEnabled && !settings.paused && audioAvailable
        guard audioControlEnabled != wanted else { return }
        audioControlEnabled = wanted
        dependencies.audioControl?.setAudioEnabled(wanted)
    }
}
