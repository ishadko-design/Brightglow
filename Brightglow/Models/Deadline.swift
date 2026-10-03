import Foundation

/// Await `work`, but return `fallback` once `nanoseconds` have passed — and
/// actually return then.
///
/// The loader's caps used to be task-group races (`group.next()` then
/// `cancelAll()`). That never returns at the cap: a task group waits for every
/// child before it exits, and the children here don't stop when cancelled —
/// they await a `CheckedContinuation` (the GPS fix) or another task's `.value`
/// (enrichment, the price check), neither of which observes cancellation. So
/// each "3s cap" really waited for the slowest call to finish.
///
/// Here the work runs in its own task and keeps going after the deadline (its
/// result still lands in caches / state as before); only the caller stops
/// waiting for it.
func withDeadline<T: Sendable>(
    _ nanoseconds: UInt64,
    fallback: T,
    _ work: @escaping @Sendable () async -> T
) async -> T {
    let once = ResumeOnce()
    return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        Task {
            let value = await work()
            if once.claim() { cont.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            if once.claim() { cont.resume(returning: fallback) }
        }
    }
}

/// First caller wins; every later `claim()` returns false.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
