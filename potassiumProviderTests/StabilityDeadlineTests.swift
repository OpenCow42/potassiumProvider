import Foundation
import Testing
import PotassiumProviderCore

@Suite("Stability deadlines")
struct StabilityDeadlineTests {
    @Test func operatorPausePreservesBudgetAndRepeatedResumeDoesNotExtendIt() {
        let start = ContinuousClock.now
        var deadline = StabilityDeadline(budget: .seconds(90), now: start)
        deadline.pause(now: start.advanced(by: .seconds(10)))
        deadline.pause(now: start.advanced(by: .seconds(20)))
        #expect(deadline.remaining(now: start.advanced(by: .seconds(800))) == .seconds(80))
        deadline.resume(now: start.advanced(by: .seconds(800)))
        deadline.resume(now: start.advanced(by: .seconds(801)))
        #expect(deadline.remaining(now: start.advanced(by: .seconds(801))) == .seconds(79))
        #expect(deadline.remaining(now: start.advanced(by: .seconds(900))) == .zero)
    }

    @Test func callbackTimeoutAndLateCompletionAreTerminalOnce() async {
        let waiter = StabilityCallbackWaiter<Int>()
        await #expect(throws: StabilityDeadlineError.expired) {
            try await waiter.wait(timeout: .milliseconds(10)) { completion in
                Task {
                    try? await Task.sleep(for: .milliseconds(30))
                    completion(.success(1))
                    completion(.success(2))
                }
            }
        }
    }

    @Test func callbackSuccessCancelsTimerAndDuplicateCompletionIsIgnored() async throws {
        let waiter = StabilityCallbackWaiter<Int>()
        let result = try await waiter.wait(timeout: .seconds(1)) { completion in
            completion(.success(42))
            completion(.success(43))
        }
        #expect([42, 43].contains(result))
    }

    @Test func concurrentWaitCannotReplaceTheFirstContinuation() async throws {
        let waiter = StabilityCallbackWaiter<Int>()
        let registered = AsyncStream<Void>.makeStream()
        let first = Task {
            try await waiter.wait(timeout: .seconds(5)) { _ in registered.continuation.yield(()) }
        }
        for await _ in registered.stream { break }
        await #expect(throws: StabilityDeadlineError.waiterAlreadyInUse) {
            try await waiter.wait { _ in Issue.record("Second callback must not be registered") }
        }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        registered.continuation.finish()
    }
}
