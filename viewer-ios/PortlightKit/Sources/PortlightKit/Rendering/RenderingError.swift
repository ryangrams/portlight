import Foundation

/// Failures of the decode → framebuffer → GPU path. Every case is detected before a byte is written
/// into a surface, so a failure never leaves a half-applied patch behind.
public enum RenderingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The image's own pixel size differs from the frame header's rectangle. Checked before decoding or allocating.
    case sizeMismatch(expected: PixelSize, actual: PixelSize)
    /// The payload's container type (ImageIO UTI) is not the codec the header declared.
    case codecMismatch(expected: ImageCodec, actual: String)
    /// ImageIO could not read the payload, or it was truncated/corrupt.
    case decodeFailed(String)
    /// The staging-buffer budget could not provide `byteCount` bytes.
    case allocationFailed(byteCount: Int)
    /// No Metal device, or a pipeline/texture could not be created.
    case metalUnavailable(String)
    /// A GPU command buffer reported an error.
    case gpuFailure(String)

    public var description: String {
        switch self {
        case let .sizeMismatch(expected, actual): return "Image is \(actual) but the frame header says \(expected)."
        case let .codecMismatch(expected, actual): return "Frame header says \(expected.rawValue) but the payload is \(actual)."
        case let .decodeFailed(reason): return "Image could not be decoded: \(reason)."
        case let .allocationFailed(byteCount): return "No staging memory for a \(byteCount)-byte image."
        case let .metalUnavailable(reason): return "Metal is unavailable: \(reason)."
        case let .gpuFailure(reason): return "GPU work failed: \(reason)."
        }
    }
}
