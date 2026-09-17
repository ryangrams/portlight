import Foundation

/// What remote audio is doing from the phone's point of view, for the UI.
public enum AudioSessionState: Equatable, Sendable {
    /// Audio is off; the session is inactive and other apps' audio may resume.
    case off
    /// The session is active; remote audio plays as it arrives.
    case active
    /// A call, alarm or another app took the audio hardware. Resumes if the system allows it.
    case interrupted
    /// Stopped until the user taps Resume.
    case paused(AudioPauseReason)
    /// Activating the session failed; Resume retries.
    case failed(String)
}

public enum AudioPauseReason: Equatable, Sendable {
    /// The output device went away (headphones unplugged, Bluetooth lost). Never switch to the speaker unasked.
    case outputDeviceRemoved
    /// An interruption ended without the system's permission to resume automatically.
    case interruptionEnded
}

/// Platform-neutral audio-session decisions. `AudioSessionController` feeds it AVAudioSession events on
/// iOS and performs the actions it returns; keeping the rules here makes them testable on macOS.
struct AudioSessionPolicy: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case enable, disable, userResume
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case outputDeviceRemoved
        case mediaServicesLost, mediaServicesReset
        case activationSucceeded
        case activationFailed(String)
    }

    enum Action: Equatable, Sendable {
        /// Stop device output now (the pipeline keeps its enabled state).
        case suspendOutput
        case resumeOutput
        /// Configure `.playback` and activate the session; report the result as an event.
        case activate
        /// Deactivate with `.notifyOthersOnDeactivation`, after output has stopped.
        case deactivate
    }

    private(set) var state: AudioSessionState = .off
    /// The user wants audio (independent of interruptions and route changes).
    private(set) var enabled = false
    /// An interruption began and its end hasn't been reported: the system may still own the hardware.
    private(set) var awaitingInterruptionEnd = false

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .enable:
            guard !enabled else { return [] }
            enabled = true
            return [.activate]
        case .disable:
            guard enabled else { return [] }
            enabled = false
            awaitingInterruptionEnd = false
            state = .off
            return [.suspendOutput, .deactivate]
        case .userResume:
            guard enabled else { return [] }
            switch state {
            // Apple doesn't guarantee that an interruption's end is ever reported (and a media-services reset
            // voids it), so Resume must also work while interrupted; the UI offers it in that state.
            case .paused, .failed, .interrupted: return [.activate]
            case .off, .active: return []
            }
        case .interruptionBegan:
            guard enabled, state == .active else { return [] }
            state = .interrupted
            awaitingInterruptionEnd = true
            return [.suspendOutput]
        case .interruptionEnded(let shouldResume):
            awaitingInterruptionEnd = false
            guard enabled, state == .interrupted else { return [] }
            if shouldResume { return [.activate] }
            state = .paused(.interruptionEnded)
            return []
        case .outputDeviceRemoved:
            guard enabled else { return [] }
            switch state {
            case .active:
                state = .paused(.outputDeviceRemoved)
                return [.suspendOutput]
            case .interrupted:
                // Output is already suspended; make sure the interruption's end can't resume on the speaker.
                state = .paused(.outputDeviceRemoved)
                return []
            case .off, .paused, .failed:
                return []
            }
        case .mediaServicesLost:
            guard enabled else { return [] }
            return [.suspendOutput]
        case .mediaServicesReset:
            // Every audio object is invalid: rebuild the device output and reconfigure the session.
            guard enabled else { return [] }
            return state == .active ? [.suspendOutput, .activate] : [.suspendOutput]
        case .activationSucceeded:
            guard enabled else { return [.deactivate] }
            awaitingInterruptionEnd = false
            state = .active
            return [.resumeOutput]
        case .activationFailed(let message):
            guard enabled else { return [] }
            // A Resume tried while the interruption is still going on (a call, say): keep waiting for its end,
            // which may resume automatically, rather than trading it for a failure that never auto-resumes.
            if state == .interrupted && awaitingInterruptionEnd { return [] }
            state = .failed(message)
            return []
        }
    }
}
