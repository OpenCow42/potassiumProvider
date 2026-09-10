import Foundation

/// Monotonic scenario budget. Operator pauses extend the deadline only on resume.
public struct StabilityDeadline: Sendable {
    private var deadline: ContinuousClock.Instant
    private var pausedAt: ContinuousClock.Instant?
    public init(budget: Duration, now: ContinuousClock.Instant = .now) { deadline = now.advanced(by: budget) }
    public mutating func pause(now: ContinuousClock.Instant = .now) {
        if pausedAt == nil { pausedAt = now }
    }
    public mutating func resume(now: ContinuousClock.Instant = .now) {
        if let pausedAt { deadline = deadline.advanced(by: pausedAt.duration(to: now)) }
        pausedAt = nil
    }
    public func remaining(now: ContinuousClock.Instant = .now) -> Duration {
        max(.zero, (pausedAt ?? now).duration(to: deadline))
    }
}

public enum StabilityDeadlineError: Error { case expired, waiterAlreadyInUse }

/// Bounds callback APIs that do not expose cancellation. A late system callback
/// is ignored after the waiter expires; it cannot resume the continuation twice.
public actor StabilityCallbackWaiter<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var timer: Task<Void, Never>?
    public init() {}

    public func wait(timeout: Duration = .seconds(90), register: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        guard continuation == nil else { throw StabilityDeadlineError.waiterAlreadyInUse }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result); return }
                self.continuation = continuation
                timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.finish(.failure(StabilityDeadlineError.expired))
                }
                register { value in Task { await self.finish(value) } }
            }
        } onCancel: {
            Task { await self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ value: Result<Value, Error>) {
        guard result == nil else { return }
        result = value
        timer?.cancel()
        timer = nil
        continuation?.resume(with: value)
        continuation = nil
    }
}
