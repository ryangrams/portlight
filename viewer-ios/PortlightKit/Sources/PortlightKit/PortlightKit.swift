import Foundation

/// Portlight v1 secure WebSocket protocol constants shared by every layer.
public enum PortlightProtocol {
    public static let version = 1
    public static let defaultPort = 5920
    public static let path = "/remote"
    public static let offeredCodecs = ["png", "jpeg"]
    /// Maximum UTF-8 bytes in a text control message (both directions).
    public static let maxControlBytes = 65_536
    /// Maximum JSON header bytes inside a binary envelope.
    public static let maxBinaryHeaderBytes = 65_536
    /// Maximum total bytes of one binary WebSocket message.
    public static let maxBinaryMessageBytes = 32 * 1024 * 1024
    /// Maximum distinct display IDs in one subscription.
    public static let maxSubscribedDisplays = 16
    /// Maximum UTF-8 bytes in one `text` input message.
    public static let maxTextInputBytes = 4096
}
