import Foundation

// App lifecycle: inactive releases input; background closes gracefully and keeps the picture; becoming
// active again reconnects with the current selection (missing displays are dropped by the planner).
extension SessionController {
    public func scenePhaseChanged(_ scene: SessionScenePhase) {
        switch scene {
        case .inactive: releaseInput()
        case .background: enterBackground()
        case .active: enterForeground()
        }
    }

    /// The session surface is on screen (drives `wantsIdleTimerDisabled`).
    public func setSurfaceVisible(_ visible: Bool) {
        isSurfaceVisible = visible
    }

    /// Resume after an audio interruption, a route change, or a session that failed to start.
    public func resumeAudio() {
        dependencies.audioControl?.resume()
    }

    func enterBackground() {
        guard isForeground else { return }
        isForeground = false
        releaseInput(clearingLatches: true)
        cancelTimer(.reconnect)
        cancelTimer(.settle)
        scheduler.cancel()
        let live: Bool
        switch phase {
        case .connected, .reconnecting, .connecting, .checkingIdentity, .authenticating, .loadingDisplays: live = connection != nil
        case .idle, .awaitingTrust, .failed: live = false
        }
        if live, let context = connection {
            suspendedForBackground = true
            reconnect = nil
            updateAudioControl()
            // Graceful close inside the background-task window; the engine stops audio, the pixels stay.
            issue { engine.disconnect() }
            hostReleasedInput()
            phase = context.established ? .reconnecting(attempt: 0, after: .networkLost) : .connecting(patient: false)
        }
        syncDerivedState()
    }

    func enterForeground() {
        guard !isForeground else { return }
        isForeground = true
        if suspendedForBackground, let context = connection {
            suspendedForBackground = false
            if context.established {
                reconnect = ReconnectState(displayedAttempt: 1, ladderAttempt: 0, firstFailureAt: now, lastFailure: .networkLost)
                startAttempt(previousSelection: selection)
            } else {
                startAttempt(previousSelection: context.attemptPreviousSelection)
            }
        }
        syncDerivedState()
    }
}
