import Foundation

/// Runs long CPU-bound test work on a thread of its own and returns its result.
///
/// Swift Testing runs tests on the cooperative pool, which has one thread per core (3 on a CI runner). A test that
/// computes for tens of seconds there leaves the other tests without threads, so tests that bound wall-clock time
/// (cancellation, deadlines) fail for reasons that have nothing to do with the code they test. Assertions stay with
/// the caller: `#expect` needs the test's task context, which a plain thread doesn't have.
func onDedicatedThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.stackSize = 16 << 20
        thread.start()
    }
}
