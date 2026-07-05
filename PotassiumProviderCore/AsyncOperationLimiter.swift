import Foundation

public actor AsyncOperationLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrentOperations: Int
    private var activeOperationCount = 0
    private var waiters: [Waiter] = []

    public init(maxConcurrentOperations: Int) {
        precondition(maxConcurrentOperations > 0, "AsyncOperationLimiter requires at least one permit.")
        self.maximumConcurrentOperations = maxConcurrentOperations
    }

    public func withPermit<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquirePermit()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            releasePermit()
            return result
        } catch {
            releasePermit()
            throw error
        }
    }

    private func acquirePermit() async throws {
        try Task.checkCancellation()

        guard activeOperationCount >= maximumConcurrentOperations else {
            activeOperationCount += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func releasePermit() {
        guard waiters.isEmpty == false else {
            activeOperationCount -= 1
            return
        }

        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let waiterIndex = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }

        let waiter = waiters.remove(at: waiterIndex)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
