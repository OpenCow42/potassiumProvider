import Foundation

/// Owns the task, cancellation, progress, and exactly-once completion of one
/// callback-based File Provider operation.
public actor FileProviderOperationLifecycle {
    public nonisolated let progress: Progress

    private let cancellationCompletion: @Sendable () -> Void
    private var task: Task<Void, Never>?
    private var isFinished = false

    public init(
        progress: Progress,
        cancellationCompletion: @escaping @Sendable () -> Void
    ) {
        self.progress = progress
        self.cancellationCompletion = cancellationCompletion
        progress.isCancellable = true
        progress.isPausable = false
        progress.cancellationHandler = { [weak self] in
            Task {
                await self?.cancel()
            }
        }
    }

    public nonisolated func start(
        _ operation: @escaping @Sendable (FileProviderOperationLifecycle) async -> Void
    ) {
        Task {
            await begin(operation)
        }
    }

    private func begin(
        _ operation: @escaping @Sendable (FileProviderOperationLifecycle) async -> Void
    ) {
        guard isFinished == false else { return }
        guard progress.isCancelled == false else {
            cancel()
            return
        }
        task = Task {
            await operation(self)
        }
    }

    @discardableResult
    public func finish(
        markProgressComplete: Bool,
        _ completion: @escaping @Sendable () -> Void
    ) -> Bool {
        if progress.isCancelled {
            cancel()
            return false
        }

        guard isFinished == false else { return false }
        isFinished = true
        task = nil

        if markProgressComplete, progress.totalUnitCount > 0 {
            progress.completedUnitCount = progress.totalUnitCount
        }
        completion()
        return true
    }

    public func cancel() {
        guard isFinished == false else { return }
        isFinished = true
        let task = task
        self.task = nil

        if progress.isCancelled == false {
            progress.cancel()
        }
        task?.cancel()
        cancellationCompletion()
    }
}
