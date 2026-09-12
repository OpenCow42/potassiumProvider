import Foundation
import PotassiumProviderCore
@preconcurrency import SQLite
import Synchronization
import Testing

struct SnapshotWriteContentionTests {
    enum Mutation: CaseIterable, Sendable {
        case snapshotSave, pollClaim, pollCommit, mutationPublication
    }

    @Test(.timeLimit(.minutes(1)), arguments: Mutation.allCases)
    func temporaryWriterDoesNotFailReadThenWriteTransaction(mutation: Mutation) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Snapshots.sqlite3")
        let store = try KDriveSnapshotSQLiteStore(databaseURL: url)
        let base = ConflictTestRemote.item(3, name: "Original.txt", parent: 1)
        let changed = ConflictTestRemote.item(3, name: "Renamed.txt", parent: 1)
        let time = Date(timeIntervalSince1970: 100)
        let initial = KDriveSnapshot(anchor: "initial", items: [base])
        try await store.save(initial, domainIdentifier: "synthetic", containerIdentifier: "1")
        let workingSet = try await store.commitWorkingSetPoll(domainIdentifier: "synthetic",
            containerSnapshotUpdates: [], items: [base],
            changes: .init(updatedItems: [base], deletedItemIDs: []), completedAt: time)

        // WAL readers can proceed while this independent connection owns the
        // write lock. Upgrading a deferred read transaction then fails at once,
        // even with busy_timeout. A write reservation must precede those reads.
        let writer = try SnapshotTemporaryWriter(url: url)
        defer { writer.release() }
        // Release on a dedicated queue: SQLite's synchronous busy handler must
        // not block the cooperative executor needed to release its own fixture.
        DispatchQueue(label: "snapshot-write-contention-release").asyncAfter(deadline: .now() + .milliseconds(500)) {
            writer.release()
        }
        let next = time.addingTimeInterval(100)
        let updated = KDriveSnapshot(anchor: "updated", items: [changed])
        switch mutation {
        case .snapshotSave:
            try await store.save(updated, domainIdentifier: "synthetic", containerIdentifier: "1",
                condition: .matching(anchor: initial.anchor, serverCursor: nil))
            #expect(try await store.snapshot(domainIdentifier: "synthetic", containerIdentifier: "1") == updated)
        case .pollClaim:
            #expect(try await store.claimWorkingSetPoll(domainIdentifier: "synthetic", now: next, minimumInterval: 60))
            #expect(try await store.claimWorkingSetPoll(domainIdentifier: "synthetic", now: next, minimumInterval: 60) == false)
        case .pollCommit:
            let result = try await store.commitWorkingSetPoll(domainIdentifier: "synthetic",
                containerSnapshotUpdates: [.init(containerIdentifier: "1", snapshot: updated,
                    condition: .matching(anchor: initial.anchor, serverCursor: nil))],
                items: [changed], changes: .init(updatedItems: [changed], deletedItemIDs: []),
                completedAt: next, condition: .matchingAnchor(workingSet.anchor))
            #expect(result.items == [changed] && result.anchor != workingSet.anchor)
            #expect(try await store.snapshot(domainIdentifier: "synthetic", containerIdentifier: "1") == updated)
        case .mutationPublication:
            #expect(try await store.publishKnownWorkingSetItem(changed, replacing: base,
                domainIdentifier: "synthetic", recordedAt: next))
            #expect(try await store.workingSetChanges(domainIdentifier: "synthetic", from: workingSet.anchor)?.changes.updatedItems == [changed])
        }
        let expectedPollTime = mutation == .pollCommit ? next : time
        #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "synthetic") == expectedPollTime)
    }
}

private final class SnapshotTemporaryWriter: Sendable {
    private let database: Mutex<Connection?>

    init(url: URL) throws {
        let database = try Connection(url.path)
        try database.execute("BEGIN IMMEDIATE")
        self.database = Mutex(database)
    }

    func release() { database.withLock { $0 = nil } }
}
