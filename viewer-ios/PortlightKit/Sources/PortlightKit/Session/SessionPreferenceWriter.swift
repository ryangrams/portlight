import Foundation

/// Applies small changes to one saved profile (preferences, last connection) off the main actor.
///
/// Each change is a read-modify-write of the current file: load, change only the given fields of the stored
/// profile, save. Changes made elsewhere in between (renames, moves, other profiles) are never reverted, and
/// a file that couldn't be loaded is never replaced (`ProfileStore` refuses). A profile that isn't saved
/// (a new, unsaved connection) is simply skipped.
///
/// Other writers of the same file serialize with these changes through `serialized(_:)`: a load → merge → save
/// run inside it can neither miss a change queued before it nor overwrite one queued after it.
final class SessionPreferenceWriter: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `store`, `queue` and `queueKey` are immutable; `failures` is only
    // touched while holding `lock`.
    private let store: ProfileStore
    private let queue = DispatchQueue(label: "studio.upgrade.portlight.session.preferences", qos: .utility)
    /// Marks `queue`, so a nested `serialized` call runs its body in place instead of deadlocking.
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var failures = 0

    init(store: ProfileStore) {
        self.store = store
        queue.setSpecific(key: queueKey, value: true)
    }

    func update(profile id: UUID, _ change: @escaping @Sendable (inout ConnectionProfile) -> Void) {
        queue.async { [store] in
            let loaded = store.load()
            guard loaded.outcome == .loaded, var profile = loaded.library.profile(id: id) else { return }
            change(&profile)
            var library = loaded.library
            library.update(profile)
            do {
                try store.save(library)
            } catch {
                self.lock.withLock { self.failures += 1 }
            }
        }
    }

    /// Runs `body` on the calling thread while holding this writer's queue: after every change queued so far has
    /// been written, and before any change queued later. Called from inside `body` (or a change), runs in place.
    func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    var failureCount: Int { lock.withLock { failures } }

    /// Returns once every queued change has been written (tests and orderly teardown).
    func waitUntilIdle() { queue.sync {} }
}
