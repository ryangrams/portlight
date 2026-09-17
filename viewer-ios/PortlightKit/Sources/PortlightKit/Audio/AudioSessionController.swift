#if os(iOS)
import AVFAudio
import Foundation
import os

/// Receives audio-session state changes on the main actor, e.g. to offer Resume after headphones are unplugged.
@MainActor
public protocol AudioSessionControllerDelegate: AnyObject {
    func audioSessionController(_ controller: AudioSessionController, didChange state: AudioSessionState)
}

/// Owns AVAudioSession for remote audio: category `.playback` (no microphone, no background mode),
/// active only while audio is on, deactivated with `.notifyOthersOnDeactivation` when it turns off, and
/// explicit handling of interruptions, route changes and media-services resets. The rules live in
/// `AudioSessionPolicy`; this class applies them. Session calls run on a private serial queue because
/// activation can block; delegate callbacks arrive on the main actor.
public final class AudioSessionController: @unchecked Sendable {
    // @unchecked Sendable: `policy` is confined to `queue`; `published` is a lock; `delegate` is
    // main-actor isolated; `observers` is written only during init and read in deinit; the rest is immutable.
    @MainActor public weak var delegate: (any AudioSessionControllerDelegate)?

    private let output: any AudioOutputSuspending
    private let session: AVAudioSession
    private let center: NotificationCenter
    private let queue = DispatchQueue(label: "Portlight.AudioSession", qos: .userInitiated)
    private var policy = AudioSessionPolicy()
    private let published = OSAllocatedUnfairLock(initialState: AudioSessionState.off)
    private var observers: [any NSObjectProtocol] = []

    /// Suspends `output` until audio is enabled and the session is active, so nothing plays under the
    /// default (silent-switch-muted) category.
    public init(output: any AudioOutputSuspending, session: AVAudioSession = .sharedInstance(),
                notificationCenter: NotificationCenter = .default) {
        self.output = output
        self.session = session
        self.center = notificationCenter
        output.setOutputSuspended(true)
        observers = [
            notificationCenter.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                guard let event = Self.interruptionEvent(note.userInfo) else { return }
                self?.post(event)
            },
            notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
                guard let event = Self.routeChangeEvent(note.userInfo) else { return }
                self?.post(event)
            },
            notificationCenter.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: session, queue: nil) { [weak self] _ in
                self?.post(.mediaServicesLost)
            },
            notificationCenter.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                self?.post(.mediaServicesReset)
            },
        ]
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    public var state: AudioSessionState { published.withLock { $0 } }

    /// Call when the user turns remote audio on or off (alongside the subscription change).
    public func setAudioEnabled(_ enabled: Bool) { post(enabled ? .enable : .disable) }

    /// The user tapped Resume after a route change, an interruption that didn't allow resuming, or a failure.
    public func resume() { post(.userResume) }

    // MARK: Session queue

    private func post(_ event: AudioSessionPolicy.Event) {
        queue.async { self.handle(event) }
    }

    private func handle(_ event: AudioSessionPolicy.Event) {
        var events = [event]
        while !events.isEmpty {
            let next = events.removeFirst()
            for action in policy.handle(next) {
                if let followUp = perform(action) { events.append(followUp) }
            }
        }
        publish()
    }

    private func perform(_ action: AudioSessionPolicy.Action) -> AudioSessionPolicy.Event? {
        switch action {
        case .suspendOutput:
            // Device I/O must stop before deactivation; bounded so a wedged audio queue can't hang the session queue.
            let stopped = DispatchSemaphore(value: 0)
            output.setOutputSuspended(true) { stopped.signal() }
            _ = stopped.wait(timeout: .now() + 1)
            return nil
        case .resumeOutput:
            output.setOutputSuspended(false)
            return nil
        case .activate:
            do {
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
                return .activationSucceeded
            } catch {
                return .activationFailed(error.localizedDescription)
            }
        case .deactivate:
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return nil
        }
    }

    private func publish() {
        let state = policy.state
        let changed = published.withLock { current -> Bool in
            defer { current = state }
            return current != state
        }
        guard changed else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.delegate?.audioSessionController(self, didChange: state) }
        }
    }

    // MARK: Notification parsing

    private static func interruptionEvent(_ info: [AnyHashable: Any]?) -> AudioSessionPolicy.Event? {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    private static func routeChangeEvent(_ info: [AnyHashable: Any]?) -> AudioSessionPolicy.Event? {
        guard let raw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return nil }
        return .outputDeviceRemoved
    }
}
#endif
