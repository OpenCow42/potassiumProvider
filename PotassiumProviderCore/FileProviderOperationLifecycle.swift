import Foundation

/// Owns the task, cancellation, progress, and exactly-once completion of one
/// callback-based File Provider operation.
public actor FileProviderOperationLifecycle {
    public nonisolated let progress: Progress

    private let cancellationCompletion: @Sendable () -> Void
    private let diagnosticSpanTask: Task<ProviderDiagnosticSpan, Never>?
    private var task: Task<Void, Never>?
    private var isFinished = false

    public init(
        progress: Progress,
        diagnosticSource: ProviderDiagnosticSource = .fileProviderExtension,
        diagnosticOperation: ProviderDiagnosticOperation? = nil,
        diagnosticFieldShape: [ProviderDiagnosticField] = [],
        diagnosticItemIdentifier: String? = nil,
        diagnosticRecorder: (any ProviderDiagnosticRecording)? = nil,
        cancellationCompletion: @escaping @Sendable () -> Void
    ) {
        self.progress = progress
        self.cancellationCompletion = cancellationCompletion
        if let diagnosticOperation {
            self.diagnosticSpanTask = Task {
                await ProviderDiagnosticSpan.start(
                    itemIdentifier: diagnosticItemIdentifier,
                    source: diagnosticSource,
                    operation: diagnosticOperation,
                    fieldShape: diagnosticFieldShape,
                    recorder: diagnosticRecorder
                )
            }
        } else {
            self.diagnosticSpanTask = nil
        }
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
    ) async {
        guard isFinished == false else { return }
        guard progress.isCancelled == false else {
            await cancel()
            return
        }
        let diagnosticSpan = await diagnosticSpanTask?.value
        guard isFinished == false else { return }
        guard progress.isCancelled == false else {
            await cancel()
            return
        }
        task = Task {
            if let diagnosticSpan {
                await diagnosticSpan.withCorrelation {
                    await operation(self)
                }
            } else {
                await operation(self)
            }
        }
    }

    @discardableResult
    public func finish(
        markProgressComplete: Bool,
        diagnosticError: (any Error)? = nil,
        _ completion: @escaping @Sendable () -> Void
    ) async -> Bool {
        if progress.isCancelled {
            await cancel()
            return false
        }

        guard isFinished == false else { return false }
        isFinished = true
        task = nil

        if markProgressComplete, progress.totalUnitCount > 0 {
            progress.completedUnitCount = progress.totalUnitCount
        }
        if let diagnosticSpanTask {
            let diagnosticSpan = await diagnosticSpanTask.value
            if let diagnosticError {
                await diagnosticSpan.fail(error: diagnosticError)
            } else {
                await diagnosticSpan.complete(statusClass: .success)
            }
        }
        completion()
        return true
    }

    public func cancel() async {
        guard isFinished == false else { return }
        isFinished = true
        let task = task
        self.task = nil

        if progress.isCancelled == false {
            progress.cancel()
        }
        task?.cancel()
        if let diagnosticSpanTask {
            let diagnosticSpan = await diagnosticSpanTask.value
            await diagnosticSpan.cancel()
        }
        cancellationCompletion()
    }
}
