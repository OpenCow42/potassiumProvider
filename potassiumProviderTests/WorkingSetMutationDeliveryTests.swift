import Foundation
import PotassiumProviderCore
import Testing

struct WorkingSetMutationDeliveryTests {
    @Test func confirmedMutationIsDurableAndDeliveredWithoutAnotherRemoteCrawl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Snapshots.sqlite3")
        let store = try KDriveSnapshotSQLiteStore(databaseURL: url)
        let base = ConflictTestRemote.item(3, name: "Original.txt", parent: 1)
        let sibling = ConflictTestRemote.item(4, name: "Sibling.txt", parent: 1)
        let moved = ConflictTestRemote.item(3, name: "Original.txt", parent: 2, revision: 2, size: 15)
        let time = Date(timeIntervalSince1970: 100)
        let initial = try await store.commitWorkingSetPoll(domainIdentifier: "synthetic", containerSnapshotUpdates: [],
            items: [base, sibling], changes: KDriveSnapshotChangeSet(updatedItems: [base, sibling], deletedItemIDs: []), completedAt: time)
        #expect(try await store.publishKnownWorkingSetItem(moved, replacing: base, domainIdentifier: "synthetic", recordedAt: time.addingTimeInterval(1)))
        let reopened = try KDriveSnapshotSQLiteStore(databaseURL: url)
        let result = try await KDriveWorkingSetChangeDelivery.changes(domainIdentifier: "synthetic", from: initial.anchor, store: reopened) {
            Issue.record("Committed changes must not wait behind a remote crawl")
            throw URLError(.timedOut)
        }
        #expect(result?.changes.updatedItems == [moved])
        #expect(result?.changes.deletedItemIDs == [])
        #expect(try await reopened.workingSetSnapshot(domainIdentifier: "synthetic")?.items == [moved, sibling])
        #expect(try await reopened.lastSuccessfulWorkingSetPoll(domainIdentifier: "synthetic") == time)
        #expect(try await reopened.publishKnownWorkingSetItem(moved, replacing: base, domainIdentifier: "synthetic", recordedAt: time.addingTimeInterval(2)))
        #expect(try await reopened.workingSetSnapshot(domainIdentifier: "synthetic")?.anchor == result?.anchor)
        #expect(try await reopened.publishKnownWorkingSetItem(base, replacing: base, domainIdentifier: "synthetic", recordedAt: time.addingTimeInterval(3)) == false)
        #expect(try await reopened.workingSetSnapshot(domainIdentifier: "synthetic")?.items.first == moved)
    }

    @Test func pollPreparedBeforeMutationCannotOverwriteItOrAdvanceCursors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let base = ConflictTestRemote.item(3, name: "Original.txt", parent: 1)
        let moved = ConflictTestRemote.item(3, name: "Original.txt", parent: 2)
        let time = Date(timeIntervalSince1970: 100)
        let initial = try await store.commitWorkingSetPoll(domainIdentifier: "synthetic", containerSnapshotUpdates: [], items: [base],
            changes: KDriveSnapshotChangeSet(updatedItems: [base], deletedItemIDs: []), completedAt: time)
        #expect(try await store.publishKnownWorkingSetItem(moved, replacing: base, domainIdentifier: "synthetic", recordedAt: time))
        let container = KDriveSnapshot(anchor: "stale", serverCursor: "stale-cursor", isFullyEnumerated: true, usesAdvancedListing: true, items: [base])
        await #expect(throws: KDriveSnapshotStoreError.staleSnapshot(domainIdentifier: "synthetic", containerIdentifier: "working-set")) {
            try await store.commitWorkingSetPoll(domainIdentifier: "synthetic",
                containerSnapshotUpdates: [.init(containerIdentifier: "1", snapshot: container, condition: .missing)],
                items: [base], changes: KDriveSnapshotChangeSet(updatedItems: [base], deletedItemIDs: []),
                completedAt: time.addingTimeInterval(10), condition: .matchingAnchor(initial.anchor))
        }
        #expect(try await store.snapshot(domainIdentifier: "synthetic", containerIdentifier: "1") == nil)
        #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "synthetic") == time)
        #expect(try await store.workingSetChanges(domainIdentifier: "synthetic", from: initial.anchor)?.changes.updatedItems == [moved])
    }

    @Test func emptyJournalStillRefreshesAndExpiredAnchorDoesNotPass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        _ = try await store.claimWorkingSetPoll(domainIdentifier: "synthetic", now: Date(), minimumInterval: 0)
        let initial = try #require(await store.workingSetSnapshot(domainIdentifier: "synthetic"))
        let item = ConflictTestRemote.item(3, name: "New.txt", parent: 1)
        let calls = WorkingSetRefreshTestGate()
        let result = try await KDriveWorkingSetChangeDelivery.changes(domainIdentifier: "synthetic", from: initial.anchor, store: store) {
            await calls.recordCall()
            _ = try await store.publishKnownWorkingSetItem(item, replacing: nil, domainIdentifier: "synthetic", recordedAt: Date())
        }
        #expect(await calls.entered && result?.changes.updatedItems == [item])
        let expired = try await KDriveWorkingSetChangeDelivery.changes(domainIdentifier: "synthetic", from: "expired", store: store) {}
        #expect(expired == nil)
    }


}

private actor WorkingSetRefreshTestGate {
    private(set) var entered = false
    func recordCall() { entered = true }
}
