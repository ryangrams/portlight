#if os(iOS)
import Foundation

/// `SessionAudioControl` over AVAudioSession: an `AudioSessionController` for the audio pipeline, with its
/// state changes forwarded to the session controller on the main actor.
///
/// Wiring: `let pipeline = AudioPipeline()`, then `SessionDependencies(audio: pipeline,
/// audioControl: SystemAudioSessionControl(output: pipeline), audioMetrics: { pipeline.metrics }, …)`.
@MainActor
public final class SystemAudioSessionControl: SessionAudioControl, AudioSessionControllerDelegate {
    public let controller: AudioSessionController
    public var onStateChange: ((AudioSessionState) -> Void)?

    /// The controller suspends `output` until audio is enabled and the session is active.
    public init(output: any AudioOutputSuspending) {
        controller = AudioSessionController(output: output)
        controller.delegate = self
    }

    public func setAudioEnabled(_ enabled: Bool) { controller.setAudioEnabled(enabled) }
    public func resume() { controller.resume() }
    public var state: AudioSessionState { controller.state }

    public func audioSessionController(_ controller: AudioSessionController, didChange state: AudioSessionState) {
        onStateChange?(state)
    }
}
#endif
