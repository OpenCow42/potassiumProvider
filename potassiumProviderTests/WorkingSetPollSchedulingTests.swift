import Foundation
import Testing
@testable import PotassiumProviderCore

@Suite("Working-set poll scheduling")
struct WorkingSetPollSchedulingTests {
    @Test(arguments: [false, true])
    func queuedMaterializationsShareOnlyASubsequentSuccessfulPoll(firstFails: Bool) async throws {
        let scheduler = WorkingSetPollScheduling(), work = ControlledPolls(failFirst: firstFails)
        let first = Task { try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() } }
        defer { first.cancel() }
        try await wait { await work.started == 1 }
        let queued = (0..<3).map { _ in Task {
            try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() }
        } }
        defer { queued.forEach { $0.cancel() } }
        try await wait { await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 4 }
        await work.allow(1)
        try await wait { await work.started == 2 }
        await work.allow(2)
        if firstFails { await #expect(throws: PollFailure.self) { try await first.value } }
        else { #expect(try await first.value.didPoll) }
        var performed = 0
        for task in queued { if try await task.value.didPoll { performed += 1 } }
        #expect(performed == 1)
        #expect(await work.started == 2)
        #expect(await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 0)
    }

    @Test func materializationArrivingDuringIORequiresAnotherPollAndCancellationDoesNotPoll() async throws {
        let scheduler = WorkingSetPollScheduling(), work = ControlledPolls()
        let first = Task { try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() } }
        defer { first.cancel() }
        try await wait { await work.started == 1 }
        let cancelled = Task { try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() } }
        try await wait { await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 2 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let later = Task { try await scheduler.withPermit(domainIdentifier: "fixture", coalescePending: true) { try await work.poll() } }
        defer { later.cancel() }
        try await wait { await scheduler.pendingRequestCount(domainIdentifier: "fixture") == 2 }
        await work.allow(1)
        #expect(try await first.value.didPoll)
        try await wait { await work.started == 2 }
        await work.allow(2)
        #expect(try await later.value.didPoll)
        #expect(await work.started == 2)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw StabilityDeadlineError.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum PollFailure: Error { case injected }
private actor ControlledPolls {
    let failFirst: Bool
    var started = 0
    var allowed: Set<Int> = []
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func allow(_ number: Int) { allowed.insert(number) }
    func poll() async throws -> KDriveWorkingSetPollOutcome {
        started += 1
        let number = started
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !allowed.contains(number) {
            guard ContinuousClock.now < deadline else { throw StabilityDeadlineError.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
        if failFirst && number == 1 { throw PollFailure.injected }
        return KDriveWorkingSetPollOutcome(didPoll: true,
            changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: []), snapshot: nil)
    }
}
