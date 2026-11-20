import Foundation

/// Waiting for child processes without `Process.waitUntilExit()`.
///
/// `waitUntilExit()` spins the calling thread's run loop until it sees the termination. On a dispatch worker
/// thread that can miss a child that exits almost at once and wait forever: seen with `wineserver -w` when no
/// server was left, which froze an install after its installer had finished. A termination handler installed
/// before the process starts can't miss it.
extension Process {
    /// Starts the process; call the returned function to block until it has exited.
    func start() throws -> () -> Void {
        let done = DispatchSemaphore(value: 0)
        terminationHandler = { _ in done.signal() }
        try run()
        return { done.wait() }
    }

    /// Starts the process and blocks until it has exited.
    func runAndWait() throws {
        try start()()
    }

    /// Starts the process and suspends until it has exited.
    func runUntilExit() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            terminationHandler = { _ in done.resume() }
            do { try run() } catch {
                terminationHandler = nil
                done.resume(throwing: error)
            }
        }
    }
}
