import Foundation
import Synchronization

/// Owns work launched after a File Provider callback has been acknowledged.
/// `invalidate()` is synchronous because the system's instance invalidation
/// callback must cancel outstanding work before it returns. The mutex protects
/// task registration only; operations and cancellation handlers run outside it.
public final class FileProviderBackgroundWork: Sendable {
    private struct State {
        var invalidated = false
        var tasks: [UUID: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())

    public init() {}

    /// Returns false once this instance has been invalidated. A new provider
    /// instance must own a new scope even when it shares the same process.
    @discardableResult
    public func start(_ operation: @escaping @Sendable () async -> Void) -> Bool {
        state.withLock { state in
            guard !state.invalidated else { return false }
            let identifier = UUID()
            state.tasks[identifier] = Task {
                // Registration holds the same mutex, so an immediately
                // finishing task cannot remove itself before insertion.
                guard self.canBegin(identifier) else { return }
                defer { self.finished(identifier) }
                await operation()
            }
            return true
        }
    }

    public func invalidate() {
        let tasks = state.withLock { state in
            state.invalidated = true
            let tasks = Array(state.tasks.values)
            state.tasks.removeAll()
            return tasks
        }
        // Task cancellation can synchronously invoke a handler. Never call
        // it while holding the registration mutex.
        for task in tasks { task.cancel() }
    }

    var registeredTaskCount: Int { state.withLock { $0.tasks.count } }

    private func canBegin(_ identifier: UUID) -> Bool {
        state.withLock { !$0.invalidated && $0.tasks[identifier] != nil && !Task.isCancelled }
    }

    private func finished(_ identifier: UUID) {
        state.withLock { $0.tasks[identifier] = nil }
    }
}
