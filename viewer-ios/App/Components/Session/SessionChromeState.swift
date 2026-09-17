import SwiftUI
import PortlightKit

/// Everything the session chrome shows, as one small value. The session owner derives it from its observable
/// state at low frequency; the chrome never reads the session directly.
struct SessionChromeState: Equatable, Sendable {
    var computerName: String
    /// Secondary line under the name: the phase, or the effective resolution once connected.
    var statusLine: String
    /// false = View Only.
    var controlEnabled: Bool
    var inputMode: InputMode
    var selectedDisplays: Int
    var totalDisplays: Int
    var keyboardVisible: Bool
    var paused: Bool
    var audioEnabled: Bool
    /// nil when audio can be used; otherwise why the Audio button is disabled (its VoiceOver hint).
    var audioUnavailableReason: String?
    var controlsHidden: Bool
    /// The banner under the top bar; transient, dismissed by the owner.
    var notice: SessionNotice?

    init(computerName: String, statusLine: String, controlEnabled: Bool = true, inputMode: InputMode = .trackpad,
         selectedDisplays: Int = 0, totalDisplays: Int = 0, keyboardVisible: Bool = false, paused: Bool = false,
         audioEnabled: Bool = false, audioUnavailableReason: String? = nil, controlsHidden: Bool = false,
         notice: SessionNotice? = nil) {
        self.computerName = computerName
        self.statusLine = statusLine
        self.controlEnabled = controlEnabled
        self.inputMode = inputMode
        self.selectedDisplays = selectedDisplays
        self.totalDisplays = totalDisplays
        self.keyboardVisible = keyboardVisible
        self.paused = paused
        self.audioEnabled = audioEnabled
        self.audioUnavailableReason = audioUnavailableReason
        self.controlsHidden = controlsHidden
        self.notice = notice
    }
}

/// What the chrome's controls ask the session to do. Every action has a no-op default.
struct SessionChromeActions {
    var disconnect: @MainActor () -> Void = {}
    var toggleControl: @MainActor () -> Void = {}
    var showDisplays: @MainActor () -> Void = {}
    var setInputMode: @MainActor (InputMode) -> Void = { _ in }
    var toggleKeyboard: @MainActor () -> Void = {}
    var togglePause: @MainActor () -> Void = {}
    var toggleAudio: @MainActor () -> Void = {}
    var showQuality: @MainActor () -> Void = {}
    var fit: @MainActor () -> Void = {}
    var actualSize: @MainActor () -> Void = {}
    var zoomIn: @MainActor () -> Void = {}
    var zoomOut: @MainActor () -> Void = {}
    var setControlsHidden: @MainActor (Bool) -> Void = { _ in }
    var showGestureGuide: @MainActor () -> Void = {}
    var showDiagnostics: @MainActor () -> Void = {}
    var dismissNotice: @MainActor () -> Void = {}
    /// The banner's Resume action after the system paused audio output.
    var resumeAudio: @MainActor () -> Void = {}
}

/// Edges of the safe area the visible chrome covers, in points. The session subtracts them from the usable
/// rect, so Fit never places the picture under the bars; they are zero while the controls are hidden.
struct ChromeInsets: Equatable, Sendable {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    var bottom: CGFloat = 0
    var trailing: CGFloat = 0
    static let zero = ChromeInsets()
}
