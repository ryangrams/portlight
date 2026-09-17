import Foundation

// Inbound half of the engine: transport events, host messages, the frame/ACK pipeline and recovery.
// Everything here runs on the engine queue except `DecodeJob.run`, which runs on the decode queue.

extension SessionEngine {
    func handle(_ event: TransportEvent, generation: ConnectionGeneration) {
        // Stale generation, ended attempt, or one a later command retired: no phase change, no send, no ACK.
        guard let a = attempt, a.generation == generation, gate.isLive(generation) else { return }
        switch event {
        case .identityVerified(let fingerprint):
            // The transport checks the pin; hearing of any other identity is a transport bug, never a reason to go on.
            guard let pin = a.pin, fingerprint == pin else { fail(a, .tlsFailed("unexpected certificate")); return }
            record("· identity verified")
            a.cancelTimer(.patience)
            if case .connecting = phase { setPhase(.checkingIdentity) }
        case .trustRequired(let prompt):
            // The attempt is over and nothing was sent; approval pins and starts a new generation.
            record("· trust required")
            end(a, phase: .awaitingTrust(prompt), closeTransport: true)
        case .opened:
            guard !a.helloSent, let password = a.password else { return }
            // Without a pin the transport owed us a trust prompt; opening anyway would send the password unverified.
            guard a.pin != nil else { fail(a, .tlsFailed("certificate not verified")); return }
            a.cancelTimer(.patience)
            a.cancelTimer(.connectDeadline)
            // The only use of the password, exactly once, over the trusted socket.
            a.password = nil
            a.helloSent = true
            record("· opened")
            a.transport.send(.hello(password: password))
            record(EngineTranscript.line(.hello(password: "")))
            setPhase(.authenticating)
            schedule(.welcomeDeadline, after: configuration.welcomeDeadline, for: a)
        case .message(let message):
            a.lastInbound = clock.now()
            receive(message, on: a)
        case .closed(let failure):
            record("· closed \(Self.describe(failure))")
            end(a, phase: .failed(failure), closeTransport: false)
        }
    }

    func receive(_ message: InboundMessage, on a: EngineAttempt) {
        guard a.helloSent else { fail(a, .protocolViolation("message before the connection opened")); return }
        record(EngineTranscript.line(message))
        switch message {
        case .frame, .audio: diagnostics.binaryMessages += 1
        default: diagnostics.textMessages += 1
        }
        switch message {
        case .welcome(let welcome):
            didReceiveWelcome(welcome, on: a)
        case .displays(let welcome):
            didChangeTopology(welcome, on: a)
        case .subscribed(let ack):
            didReceiveSubscribed(ack, on: a)
        case .frame(let header, let payload):
            didReceiveFrame(header, payload: payload, on: a)
        case .audio(let header, let payload):
            // Never acknowledged; the sink owns epochs, so it judges the revision.
            diagnostics.bytesReceived += payload.count
            diagnostics.audioPackets += 1
            audio.submit(header, payload: payload)
        case .cursor(let cursor):
            notify { $0.engine($1, cursor: cursor) }
        case .stats(let stats):
            diagnostics.hostFPS = stats.fps
            diagnostics.hostInFlightFrames = stats.inFlightFrames
            diagnostics.hostPendingImageBytes = stats.pendingImageBytes
            notify { $0.engine($1, stats: stats) }
        case .pong(let time):
            let rtt = (clock.now() - time) * 1000
            if rtt.isFinite, rtt >= 0 { diagnostics.lastRTTMilliseconds = rtt }
        case .error(let error):
            didReceiveHostError(error, on: a)
        case .ignored:
            diagnostics.ignoredMessages += 1
        }
    }

    // MARK: Welcome and topology

    func didReceiveWelcome(_ welcome: WelcomeMessage, on a: EngineAttempt) {
        guard a.welcome == nil else { fail(a, .protocolViolation("unexpected welcome")); return }
        guard welcome.version == PortlightProtocol.version else {
            fail(a, .protocolViolation("unsupported protocol version \(welcome.version)")); return
        }
        a.welcome = welcome
        a.cancelTimer(.welcomeDeadline)
        setPhase(.loadingDisplays)
        notify { $0.engine($1, didReceiveWelcome: welcome, topologyChange: false) }
        // The host sends stats every second from here on, so silence now means a dead socket.
        schedule(.ping, after: configuration.pingInterval, for: a)
        schedule(.readDeadline, after: configuration.readDeadline, for: a)
        // Same engine turn as welcome: no main-thread round trip before revision 1.
        sendSubscription(a.planner.initialSubscription(for: welcome, previousSelection: a.previousSelection), force: true)
    }

    func didChangeTopology(_ welcome: WelcomeMessage, on a: EngineAttempt) {
        guard a.welcome != nil else { fail(a, .protocolViolation("displays before welcome")); return }
        a.welcome = welcome
        // The host dropped its subscription: an equivalent resubmission must still go out.
        a.lastSent = nil
        notify { $0.engine($1, didReceiveWelcome: welcome, topologyChange: true) }
    }

    // MARK: Subscriptions

    func didReceiveSubscribed(_ ack: SubscribedMessage, on a: EngineAttempt) {
        guard let index = a.outstanding.firstIndex(where: { $0.revision == ack.revision }) else {
            diagnostics.subscriptionAcksIgnored += 1
            return
        }
        let request = a.outstanding[index]
        // The host answers in order, so older unanswered revisions were rejected or superseded.
        a.outstanding.removeFirst(index + 1)
        let ids = ack.canvases.map(\.display)
        guard ids.count == request.displays.count, Set(ids).count == ids.count, Set(ids) == Set(request.displays) else {
            fail(a, .protocolViolation("subscribed displays don't match the request")); return
        }
        let side = 1...configuration.maxCanvasSide
        guard ack.canvases.allSatisfy({ side.contains($0.size.width) && side.contains($0.size.height) }) else {
            fail(a, .protocolViolation("invalid canvas size")); return
        }
        let canvases = Dictionary(uniqueKeysWithValues: ack.canvases.map { ($0.display, $0.size) })
        let total = ack.canvases.reduce(0) { $0 + $1.size.pixelCount }
        guard total <= configuration.maxTotalCanvasPixels else {
            exceededCanvasBudget(ack, request: request, on: a); return
        }
        accept(ack, request: request, canvases: canvases, allocate: true, on: a)
    }

    func exceededCanvasBudget(_ ack: SubscribedMessage, request: SubscriptionRequest, on a: EngineAttempt) {
        if a.budgetFallbackRevision != ack.revision { notify { $0.engine($1, canvasBudgetExceeded: ack) } }
        guard request.paused else {
            // The host did apply this revision and streams its audio until the paused resend lands; the sink
            // must hear of every revision the host accepted before any of its packets.
            audio.audioConfigurationAcknowledged(audioConfiguration(for: ack, request: request), revision: ack.revision)
            // This revision's frames arrive as unexpected (ACKed, never decoded) until the paused resend lands.
            var paused = request
            paused.paused = true
            sendSubscription(paused, force: true)
            a.budgetFallbackRevision = a.lastSentRevision
            return
        }
        // Paused: the host produces no images, so the revision goes live without allocating surfaces.
        accept(ack, request: request, canvases: [:], allocate: false, on: a)
    }

    func accept(_ ack: SubscribedMessage, request: SubscriptionRequest, canvases: [DisplayID: PixelSize],
                allocate: Bool, on a: EngineAttempt) {
        // Frames of the new revision are only queued after this returns, so this precedes their commits. The
        // commit gate keeps a retired generation from recreating surfaces the controller already cleared.
        a.accepted = AcceptedRevision(request: request, canvases: canvases)
        if allocate {
            _ = gate.ifLive(a.generation) {
                framebuffer.acceptRevision(ack.revision, canvases: canvases, requestedRegions: request.regions)
            }
        }
        audio.audioConfigurationAcknowledged(audioConfiguration(for: ack, request: request), revision: ack.revision)
        if let burst = a.recoveryBurst, ack.revision > burst.afterRevision { a.recoveryBurst = nil }
        notify { $0.engine($1, didAccept: ack, for: request) }
        if phase == .loadingDisplays { setPhase(.connected) }
    }

    /// The audio the host acknowledged: codec and bitrate from `subscribed`, falling back to the request.
    func audioConfiguration(for ack: SubscribedMessage, request: SubscriptionRequest) -> AudioConfiguration? {
        guard ack.audio else { return nil }
        return AudioConfiguration(codec: ack.audioCodec ?? request.audioCodec, bitrate: ack.audioBitrate ?? request.audioBitrate.rawValue)
    }

    // MARK: Frames

    func didReceiveFrame(_ header: FrameHeader, payload: Data, on a: EngineAttempt) {
        diagnostics.bytesReceived += payload.count
        diagnostics.framesReceived += 1
        guard let accepted = a.accepted, header.revision <= accepted.revision else {
            // A revision we haven't accepted (or refused for budget): free the host's window, never decode.
            diagnostics.framesUnexpected += 1
            acknowledge(header.sequence, on: a); return
        }
        guard header.revision == accepted.revision else {
            // Old revision: discard and still ACK, so the host's in-flight capacity is released.
            diagnostics.framesStale += 1
            acknowledge(header.sequence, on: a); return
        }
        guard let canvas = accepted.canvases[header.display], canvas == header.canvas, header.rect.fits(in: canvas) else {
            diagnostics.framesRejected += 1
            acknowledge(header.sequence, on: a)
            imageFailed("frame doesn't match the accepted canvas", on: a); return
        }
        let bytes = payload.count
        guard a.decodeJobs < configuration.maxDecodeJobs, bytes <= configuration.maxDecodeBytes - a.decodeBytes else {
            // Dropping a cumulative patch would corrupt the picture; stop rather than pretend.
            fail(a, .protocolViolation("decoder backlog")); return
        }
        a.decodeJobs += 1
        a.decodeBytes += bytes
        diagnostics.decodeJobsInFlight = a.decodeJobs
        diagnostics.decodeBytesInFlight = a.decodeBytes
        diagnostics.decodeJobsPeak = max(diagnostics.decodeJobsPeak, a.decodeJobs)
        diagnostics.decodeBytesPeak = max(diagnostics.decodeBytesPeak, a.decodeBytes)
        let generation = a.generation, gate = self.gate, decoder = self.decoder, framebuffer = self.framebuffer
        decodeQueue.async { [weak self] in
            let outcome = DecodeJob.run(header, payload: payload, generation: generation, gate: gate,
                                        decoder: decoder, framebuffer: framebuffer)
            guard let self else { return }
            self.queue.async { self.decodeFinished(header, bytes: bytes, outcome: outcome, generation: generation) }
        }
    }

    func decodeFinished(_ header: FrameHeader, bytes: Int, outcome: DecodeOutcome, generation: ConnectionGeneration) {
        // A completion from an ended, replaced or retired attempt must not ACK on anyone's socket.
        guard let a = attempt, a.generation == generation, gate.isLive(generation) else { return }
        a.decodeJobs -= 1
        a.decodeBytes -= bytes
        diagnostics.decodeJobsInFlight = a.decodeJobs
        diagnostics.decodeBytesInFlight = a.decodeBytes
        var failure: String?
        switch outcome {
        case .committed:
            diagnostics.framesDecoded += 1
            diagnostics.framesCommitted += 1
            lastCommitTime = clock.now()
        case .stale:
            diagnostics.framesDecoded += 1
            if isCurrent(header, on: a) {
                // Nothing here replaced this patch's revision or canvas, so "stale" can only be a local loss
                // (no surface, GPU resource, malformed patch): the picture is incomplete, so recover.
                diagnostics.framesRejected += 1
                failure = "framebuffer discarded a current patch"
            } else {
                diagnostics.framesStale += 1
            }
        case .abandoned:
            diagnostics.framesStale += 1
        case .failed(let reason):
            diagnostics.framesRejected += 1
            failure = reason
        }
        // Only now: the patch is committed or deliberately discarded.
        acknowledge(header.sequence, on: a)
        if let failure { imageFailed(failure, on: a) }
    }

    /// True while `header` matches the revision and canvas this attempt accepted (and handed to the framebuffer).
    func isCurrent(_ header: FrameHeader, on a: EngineAttempt) -> Bool {
        guard let accepted = a.accepted else { return false }
        return accepted.revision == header.revision && accepted.canvases[header.display] == header.canvas
    }

    func acknowledge(_ sequence: Int, on a: EngineAttempt) {
        a.transport.send(.frameAck(sequence: sequence))
        diagnostics.acksSent += 1
        record(EngineTranscript.line(.frameAck(sequence: sequence)))
    }

    /// One `needsRecoverySubscription` per failure burst; one burst more than `recoveryLimit` within
    /// `recoveryWindow` fails the session instead of concealing a broken picture. A burst ends when a
    /// revision sent after it started is accepted (or when it is older than the window).
    func imageFailed(_ reason: String, on a: EngineAttempt) {
        let now = clock.now()
        if let burst = a.recoveryBurst, now - burst.startedAt < configuration.recoveryWindow { return }
        a.recoveryStarts.removeAll { now - $0 >= configuration.recoveryWindow }
        guard a.recoveryStarts.count < configuration.recoveryLimit else {
            fail(a, .protocolViolation("repeated image failures")); return
        }
        a.recoveryStarts.append(now)
        a.recoveryBurst = (afterRevision: a.lastSentRevision, startedAt: now)
        diagnostics.recoveries += 1
        notify { $0.engine($1, needsRecoverySubscription: reason) }
    }

    // MARK: Host errors

    func didReceiveHostError(_ error: HostErrorMessage, on a: EngineAttempt) {
        switch error.code {
        // The host closes right after these; ending first keeps the specific reason over a generic close.
        case .authentication: fail(a, .authenticationRejected(error.message))
        case .busy: fail(a, .busy(error.message))
        case .timeout: fail(a, .hostTimeout(error.message))
        case .subscription:
            // The host answers each subscribe in order with `subscribed` or this error, so the oldest outstanding
            // request is the refused one. The accepted revision, and its frames, keep running.
            if !a.outstanding.isEmpty { a.outstanding.removeFirst() }
            notify { $0.engine($1, hostReported: error) }
        case .topology, .capture, .message, .other:
            // Non-fatal.
            notify { $0.engine($1, hostReported: error) }
        }
    }
}
