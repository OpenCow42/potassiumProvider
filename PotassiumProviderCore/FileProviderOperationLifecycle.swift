import Foundation

/// Owns the task, cancellation, progress, and exactly-once completion of one
/// callback-based File Provider operation.
public final class FileProviderOperationLifecycle: @unchecked Sendable {
    public let progress: Progress

    private let lock = NSLock()
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
            self?.cancel()
        }
    }

    public func start(
        _ operation: @escaping @Sendable (FileProviderOperationLifecycle) async -> Void
    ) {
        let task = Task {
            await operation(self)
        }

        lock.lock()
        if isFinished {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
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

        lock.lock()
        guard isFinished == false else {
            lock.unlock()
            return false
        }
        isFinished = true
        task = nil
        lock.unlock()

        if markProgressComplete, progress.totalUnitCount > 0 {
            progress.completedUnitCount = progress.totalUnitCount
        }
        completion()
        return true
    }

    public func cancel() {
        let task: Task<Void, Never>?

        lock.lock()
        guard isFinished == false else {
            lock.unlock()
            return
        }
        isFinished = true
        task = self.task
        self.task = nil
        lock.unlock()

        if progress.isCancelled == false {
            progress.cancel()
        }
        task?.cancel()
        cancellationCompletion()
    }
}
