import Foundation

/// The generation shared by command callers, the engine queue, the decode queue and the delegate queue.
///
/// `issued` is the newest generation handed out (`SessionEngine.currentGeneration`). `connect`, `disconnect`
/// and `cancel` bump it on the caller's thread, so an older generation is retired the moment such a call
/// returns: its delegate callbacks are dropped on delivery even when already queued. `live` is the generation
/// whose patches may still reach the framebuffer. Commits and revision acceptances run under `commitLock`, and
/// every change of `live` takes it too, so once a generation stops being live nothing of it can land, even a
/// patch whose decode was already running (a coincidentally equal revision on the next host must not win).
final class GenerationGate: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `issuedValue` and `live` are only touched while holding `stateLock`.
    // Lock order is always commitLock → stateLock. Plain reads take only `stateLock`, so the delegate queue's
    // freshness check never waits behind a commit.
    private let commitLock = NSLock()
    private let stateLock = NSLock()
    private var issuedValue = ConnectionGeneration.none
    private var live = ConnectionGeneration.none

    var issued: ConnectionGeneration { stateLock.withLock { issuedValue } }

    /// A command, on the caller's thread: the next generation, with nothing live until the engine queue opens
    /// it. Waits out a commit in progress, so no patch of the retired generation lands after this returns.
    func reserve() -> ConnectionGeneration {
        commitLock.withLock { stateLock.withLock { issuedValue = issuedValue.next(); live = .none; return issuedValue } }
    }
    /// The engine queue starts `generation`'s attempt; false when a later command already retired it.
    func open(_ generation: ConnectionGeneration) -> Bool {
        commitLock.withLock {
            stateLock.withLock {
                guard generation != .none, generation == issuedValue else { return false }
                live = generation
                return true
            }
        }
    }
    /// The attempt ended (failure, trust prompt, disconnect); nothing of it may commit any more.
    func close() { commitLock.withLock { stateLock.withLock { live = .none } } }
    func isLive(_ generation: ConnectionGeneration) -> Bool {
        stateLock.withLock { generation != .none && live == generation }
    }
    /// False once a later connect, disconnect or cancel has been called.
    func isCurrent(_ generation: ConnectionGeneration) -> Bool { stateLock.withLock { generation == issuedValue } }
    /// Runs `body` only while `generation` is live, holding the commit lock so the attempt can't end mid-commit.
    func ifLive<T>(_ generation: ConnectionGeneration, _ body: () throws -> T) rethrows -> T? {
        commitLock.lock(); defer { commitLock.unlock() }
        guard isLive(generation) else { return nil }
        return try body()
    }
}

/// Result of one decode job, handed back to the engine queue (the patch itself never leaves the decode queue).
enum DecodeOutcome: Equatable, Sendable {
    case committed
    /// Decoded, but the framebuffer no longer wanted it (a newer revision replaced the canvas, or a local loss
    /// the engine tells apart by checking its own accepted revision).
    case stale
    case failed(String)
    /// The attempt ended before the patch could be committed.
    case abandoned
}

enum DecodeJob {
    /// Decode into framebuffer staging memory and commit in arrival order. Runs on the serial decode queue.
    static func run(_ header: FrameHeader, payload: Data, generation: ConnectionGeneration, gate: GenerationGate,
                     decoder: TileDecoding, framebuffer: FramebufferSink) -> DecodeOutcome {
        guard gate.isLive(generation) else { return .abandoned }
        var bufferUnavailable = false
        let patch: DecodedPatch
        do {
            patch = try decoder.decode(header, payload: payload) { byteCount in
                let buffer = framebuffer.makePatchBuffer(byteCount: byteCount)
                if buffer == nil { bufferUnavailable = true }
                return buffer
            }
        } catch {
            return .failed(bufferUnavailable ? "patch buffer unavailable" : "image decode failed")
        }
        // A decoder bug must not become an out-of-bounds read in the framebuffer (whose rows are whole pixels).
        let rowBytes = header.rect.width.multipliedReportingOverflow(by: 4)
        let needed = patch.bytesPerRow.multipliedReportingOverflow(by: header.rect.height)
        guard patch.header == header, !rowBytes.overflow, patch.bytesPerRow >= rowBytes.partialValue, patch.bytesPerRow % 4 == 0,
              !needed.overflow, patch.buffer.byteCount >= needed.partialValue else {
            return .failed("decoded patch doesn't match its header")
        }
        guard let result = gate.ifLive(generation, { framebuffer.commit(patch) }) else { return .abandoned }
        switch result {
        case .committed: return .committed
        case .stale: return .stale
        case .failed: return .failed("framebuffer could not commit the patch")
        }
    }
}
