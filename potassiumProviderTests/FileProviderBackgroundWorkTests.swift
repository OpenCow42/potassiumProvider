import Foundation
import Testing
@testable import PotassiumProviderCore

struct FileProviderBackgroundWorkTests {
    @Test func invalidationCancelsAcknowledgedWorkBeforeAnotherRequest() async throws {
        let scope = FileProviderBackgroundWork(), work = BackgroundRefreshProbe()
        defer { scope.invalidate() }
        let accepted = scope.start { await work.run() }
        #expect(accepted)
        try await wait { await work.started == 1 }
        scope.invalidate()
        scope.invalidate() // Repeated invalidation cannot duplicate a terminal.
        try await wait { await work.cancelled == 1 }
        await work.release()
        #expect(await work.requests == 1)
        #expect(await work.completed == 0)
        #expect(await work.cancelled == 1)
        #expect(scope.registeredTaskCount == 0)
        let acceptedAfterInvalidation = scope.start { await work.run() }
        #expect(!acceptedAfterInvalidation)
        #expect(await work.started == 1)
    }

    @Test func replacingOneInstanceDoesNotCancelAnotherInstancesWork() async throws {
        let original = FileProviderBackgroundWork(), replacement = FileProviderBackgroundWork()
        defer { original.invalidate(); replacement.invalidate() }
        let oldWork = BackgroundRefreshProbe(), newWork = BackgroundRefreshProbe()
        original.start { await oldWork.run() }
        replacement.start { await newWork.run() }
        try await wait {
            let oldStarted = await oldWork.started, newStarted = await newWork.started
            return oldStarted == 1 && newStarted == 1
        }
        original.invalidate()
        try await wait { await oldWork.cancelled == 1 }
        #expect(await newWork.cancelled == 0)
        await newWork.release()
        try await wait { await newWork.completed == 1 }
        #expect(await newWork.requests == 2)
        replacement.invalidate()
        #expect(await newWork.cancelled == 0)
    }

    @Test func immediateCompletionsCannotRemainRegistered() async throws {
        let scope = FileProviderBackgroundWork()
        defer { scope.invalidate() }
        for _ in 0..<100 {
            let accepted = scope.start {}
            #expect(accepted)
        }
        try await wait { scope.registeredTaskCount == 0 }
        scope.invalidate()
        let acceptedAfterInvalidation = scope.start {}
        #expect(!acceptedAfterInvalidation)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw StabilityDeadlineError.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor BackgroundRefreshProbe {
    var started = 0, requests = 0, completed = 0, cancelled = 0
    private var released = false
    func release() { released = true }
    func run() async {
        started += 1
        do {
            try Task.checkCancellation()
            requests += 1
            while !released { try await Task.sleep(for: .milliseconds(5)) }
            try Task.checkCancellation()
            requests += 1
            completed += 1
        } catch is CancellationError { cancelled += 1 }
        catch { Issue.record("Unexpected synthetic refresh error") }
    }
}
