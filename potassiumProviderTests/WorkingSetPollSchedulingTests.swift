import Foundation
import Testing
@testable import PotassiumProviderCore

@Suite("Working-set poll scheduling")
struct WorkingSetPollSchedulingTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func queuedMaterializationsShareOnlyASubsequentSuccessfulPoll(firstFails: Bool) async throws {
        let scheduler = WorkingSetPollScheduling(), work = ControlledPolls(failFirst: firstFails)
        let first = Task { try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() } }
        defer { first.cancel() }
        try await work.waitForStarted(1)
        let queued = (0..<3).map { _ in Task {
            try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() }
        } }
        defer { queued.forEach { $0.cancel() } }
        try await wait { await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 4 }
        try await work.allow(1)
        try await work.waitForStarted(2)
        try await work.allow(2)
        if firstFails { await #expect(throws: PollFailure.self) { try await first.value } }
        else { #expect(try await first.value.didPoll) }
        var performed = 0
        for task in queued { if try await task.value.didPoll { performed += 1 } }
        #expect(performed == 1)
        #expect(await work.started == 2)
        #expect(await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 0)
    }

    @Test(.timeLimit(.minutes(1))) func materializationArrivingDuringIORequiresAnotherPollAndCancellationDoesNotPoll() async throws {
        let scheduler = WorkingSetPollScheduling(), work = ControlledPolls()
        let first = Task { try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() } }
        defer { first.cancel() }
        try await work.waitForStarted(1)
        let cancelled = Task { try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() } }
        defer { cancelled.cancel() }
        try await wait { await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 2 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let later = Task { try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() } }
        defer { later.cancel() }
        try await wait { await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 2 }
        try await work.allow(1)
        #expect(try await first.value.didPoll)
        try await work.waitForStarted(2)
        try await work.allow(2)
        #expect(try await later.value.didPoll)
        #expect(await work.started == 2)
        #expect(await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 0)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        // The enclosing test deadline bounds this observation. A loaded simulator
        // must not turn a scheduling-order assertion into a three-second race.
        while !(await condition()) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum PollFailure: Error { case injected }
private actor ControlledPolls {
    let failFirst: Bool
    private(set) var started = 0
    private let starts = AsyncStream<Int>.makeStream()
    private var releases: [Int: AsyncStream<Void>.Continuation] = [:]
    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func waitForStarted(_ count: Int) async throws {
        if started >= count { return }
        for await number in starts.stream {
            if number >= count { return }
        }
        throw CancellationError()
    }

    func allow(_ number: Int) throws {
        let release = try #require(releases[number])
        release.yield(())
        release.finish()
    }

    func poll() async throws -> KDriveWorkingSetPollOutcome {
        started += 1
        let number = started
        let release = AsyncStream<Void>.makeStream()
        releases[number] = release.continuation
        defer { releases[number] = nil }
        starts.continuation.yield(number)
        var iterator = release.stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
        if failFirst && number == 1 { throw PollFailure.injected }
        return KDriveWorkingSetPollOutcome(didPoll: true,
            changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: []), snapshot: nil)
    }
}
