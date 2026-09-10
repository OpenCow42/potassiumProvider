#if STABILITY
import Foundation
import Testing
@testable import PotassiumProviderCore

@Suite("Live conflict scheduling barrier")
struct StabilityConflictBarrierTests {
    private func makeRun() throws -> StabilityRunHandle {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return StabilityRunHandle(runID: UUID(), directoryURL: directory)
    }

    @Test func oldAttemptCannotReleaseNextCaseAndWrongPointCannotArrive() async throws {
        let run = try makeRun(), correlation = UUID()
        defer { try? FileManager.default.removeItem(at: run.directoryURL) }
        let old = try StabilityConflictBarrier.arm(run: run, itemIdentifier: "fixture", correlationID: correlation, activeRunID: run.runID)
        try StabilityConflictBarrier.release(old, run: run, activeRunID: run.runID)
        let next = try StabilityConflictBarrier.arm(run: run, itemIdentifier: "fixture", correlationID: correlation,
            caseID: .renameRename, activeRunID: run.runID)
        #expect(old.attemptID != next.attemptID)
        #expect(throws: CancellationError.self) { try StabilityConflictBarrier.release(old, run: run, activeRunID: run.runID) }
        try await StabilityConflictBarrier.arriveIfArmed(itemIdentifier: "fixture", correlationID: correlation,
            point: .afterContentPreflight, activeRun: { run })
        #expect(!StabilityConflictBarrier.reached(next, run: run))
        #expect(throws: CancellationError.self) {
            try StabilityConflictBarrier.arm(run: run, itemIdentifier: "fixture", correlationID: correlation, activeRunID: run.runID)
        }
        try StabilityConflictBarrier.release(next, run: run, activeRunID: run.runID)
    }

    @Test func expiredAttemptDoesNotBlockTheNextCase() async throws {
        let run = try makeRun(), correlation = UUID()
        defer { try? FileManager.default.removeItem(at: run.directoryURL) }
        let first = try StabilityConflictBarrier.arm(run: run, itemIdentifier: "fixture", correlationID: correlation, activeRunID: run.runID)
        await #expect(throws: CancellationError.self) {
            try await StabilityConflictBarrier.arriveIfArmed(itemIdentifier: "fixture", correlationID: correlation,
                budget: .milliseconds(5), activeRun: { run })
        }
        await #expect(throws: CancellationError.self) {
            try await StabilityConflictBarrier.arriveIfArmed(itemIdentifier: "fixture", correlationID: correlation, activeRun: { run })
        }
        let second = try StabilityConflictBarrier.arm(run: run, itemIdentifier: "fixture", correlationID: correlation, activeRunID: run.runID)
        #expect(first.attemptID != second.attemptID)
        #expect(!StabilityConflictBarrier.reached(second, run: run))
    }

    @Test func unrelatedItemsAndCorrelationsNeverReachTheBarrier() async throws {
        let run = try makeRun(), correlation = UUID()
        defer { try? FileManager.default.removeItem(at: run.directoryURL) }
        try StabilityConflictBarrier.arm(run: run, itemIdentifier: "fixture", correlationID: correlation, activeRunID: run.runID)
        try await StabilityConflictBarrier.arriveIfArmed(itemIdentifier: "other", correlationID: correlation, activeRun: { run })
        try await StabilityConflictBarrier.arriveIfArmed(itemIdentifier: "fixture", correlationID: UUID(), activeRun: { run })
        #expect(!StabilityConflictBarrier.reached(run: run))
        #expect(throws: CancellationError.self) {
            try StabilityConflictBarrier.release(run: run, activeRunID: UUID())
        }
    }

    @Test(arguments: [false, true])
    func reachedBarrierCanBeReleasedOrCancelled(cancel: Bool) async throws {
        let run = try makeRun(), correlation = UUID()
        defer { try? FileManager.default.removeItem(at: run.directoryURL) }
        try StabilityConflictBarrier.arm(run: run, itemIdentifier: "fixture", correlationID: correlation, activeRunID: run.runID)
        let task = Task { try await StabilityConflictBarrier.arriveIfArmed(itemIdentifier: "fixture", correlationID: correlation, activeRun: { run }) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !StabilityConflictBarrier.reached(run: run), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(StabilityConflictBarrier.reached(run: run))
        if cancel {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            try StabilityConflictBarrier.release(run: run, activeRunID: run.runID)
            try await task.value
        }
    }

    @Test func anUnreleasedBarrierExpiresWithoutProceeding() async throws {
        let run = try makeRun(), correlation = UUID()
        defer { try? FileManager.default.removeItem(at: run.directoryURL) }
        try StabilityConflictBarrier.arm(run: run, itemIdentifier: "fixture", correlationID: correlation, activeRunID: run.runID)
        await #expect(throws: CancellationError.self) {
            try await StabilityConflictBarrier.arriveIfArmed(itemIdentifier: "fixture", correlationID: correlation,
                                                           budget: .milliseconds(20), activeRun: { run })
        }
        #expect(StabilityConflictBarrier.reached(run: run))
    }
}
#endif
