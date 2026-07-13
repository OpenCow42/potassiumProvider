import Foundation
import PotassiumProviderCore
@preconcurrency import SQLite
import Testing

@Suite(.serialized)
struct SnapshotGenerationPagingTests {
    @Test func ordinaryNumericIdentifierRequiresDirectoryMetadata() throws {
        let document = item(id: 42)
        #expect(throws: KDriveContainerValidationError.notAContainer(fileID: 42)) {
            try KDriveContainerValidator.validate(document, expectedFileID: 42)
        }

        let directory = KDriveRemoteItem(
            id: 42,
            name: "Folder",
            type: "dir",
            status: "ok",
            driveID: 1,
            parentID: 1,
            path: "/Folder",
            size: nil,
            mimeType: nil,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try KDriveContainerValidator.validate(directory, expectedFileID: 42)
    }

    @Test func migratesLegacySnapshotWithoutChangingItsContents() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Snapshots.sqlite3")
        let database = try Connection(databaseURL.path)
        try database.execute("""
            CREATE TABLE container_snapshots(
                domainIdentifier TEXT NOT NULL,
                containerIdentifier TEXT NOT NULL,
                anchor TEXT NOT NULL,
                serverCursor TEXT,
                isFullyEnumerated INTEGER NOT NULL,
                usesAdvancedListing INTEGER NOT NULL,
                updatedAt REAL NOT NULL,
                PRIMARY KEY(domainIdentifier, containerIdentifier)
            );
            CREATE TABLE snapshot_items(
                domainIdentifier TEXT NOT NULL,
                containerIdentifier TEXT NOT NULL,
                position INTEGER NOT NULL,
                itemID INTEGER NOT NULL,
                name TEXT NOT NULL,
                type TEXT,
                status TEXT NOT NULL,
                driveID INTEGER NOT NULL,
                parentID INTEGER NOT NULL,
                path TEXT,
                size INTEGER,
                mimeType TEXT,
                createdAt REAL,
                modifiedAt REAL NOT NULL,
                itemUpdatedAt REAL NOT NULL,
                PRIMARY KEY(domainIdentifier, containerIdentifier, itemID)
            );
            CREATE TABLE materialized_items(
                domainIdentifier TEXT NOT NULL,
                fileID INTEGER NOT NULL,
                isContainer INTEGER NOT NULL,
                PRIMARY KEY(domainIdentifier, fileID)
            );
            INSERT INTO container_snapshots VALUES
                ('domain', '42', 'legacy-anchor', 'legacy-cursor', 1, 1, 1000);
            INSERT INTO snapshot_items VALUES
                ('domain', '42', 0, 7, 'Legacy.txt', 'file', 'ok', 1, 42,
                 '/Legacy.txt', 12, 'text/plain', 900, 950, 975);
            INSERT INTO materialized_items VALUES ('domain', 42, 1);
            """)

        let store = try KDriveSnapshotSQLiteStore(databaseURL: databaseURL)
        let snapshot = try #require(try await store.snapshot(
            domainIdentifier: "domain",
            containerIdentifier: "42"
        ))
        #expect(snapshot.anchor == "legacy-anchor")
        #expect(snapshot.serverCursor == "legacy-cursor")
        #expect(snapshot.items.map(\.id) == [7])
        #expect(snapshot.items.first?.name == "Legacy.txt")

        let page = try #require(try await store.snapshotPage(
            domainIdentifier: "domain",
            containerIdentifier: "42",
            after: nil,
            limit: 1
        ))
        #expect(page.generation == 1)
        #expect(page.items == snapshot.items)
        #expect(try await store.materializedItems(domainIdentifier: "domain") == [
            KDriveMaterializedItem(fileID: 42, isContainer: true),
        ])
    }

    @Test func cachedPagesRemainStableWhileANewerGenerationCommits() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(
            snapshot(anchor: "one", ids: [1, 2, 3, 4, 5]),
            domainIdentifier: "domain",
            containerIdentifier: "42"
        )
        let first = try #require(try await store.snapshotPage(
            domainIdentifier: "domain",
            containerIdentifier: "42",
            after: nil,
            limit: 2
        ))
        #expect(first.items.map(\.id) == [1, 2])
        let token = try #require(first.nextToken)

        try await store.save(
            snapshot(anchor: "two", ids: [10, 11]),
            domainIdentifier: "domain",
            containerIdentifier: "42"
        )

        let second = try #require(try await store.snapshotPage(
            domainIdentifier: "domain",
            containerIdentifier: "42",
            after: token,
            limit: 2
        ))
        #expect(second.generation == first.generation)
        #expect(second.items.map(\.id) == [3, 4])
        let secondToken = try #require(second.nextToken)
        let third = try #require(try await store.snapshotPage(
            domainIdentifier: "domain",
            containerIdentifier: "42",
            after: secondToken,
            limit: 2
        ))
        #expect(third.items.map(\.id) == [5])
        #expect(third.nextToken == nil)
    }

    @Test func expiresItemPageAfterThreeNewerGenerations() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(snapshot(anchor: "one", ids: [1, 2]), domainIdentifier: "domain", containerIdentifier: "42")
        let first = try #require(try await store.snapshotPage(
            domainIdentifier: "domain",
            containerIdentifier: "42",
            after: nil,
            limit: 1
        ))
        let oldToken = try #require(first.nextToken)

        for generation in 2...4 {
            try await store.save(
                snapshot(anchor: "anchor-\(generation)", ids: [generation]),
                domainIdentifier: "domain",
                containerIdentifier: "42"
            )
        }

        await #expect(throws: KDriveSnapshotStoreError.expiredGeneration(
            domainIdentifier: "domain",
            containerIdentifier: "42"
        )) {
            _ = try await store.snapshotPage(
                domainIdentifier: "domain",
                containerIdentifier: "42",
                after: oldToken,
                limit: 1
            )
        }
    }

    @Test func changePagesAreBoundedAndStableAcrossUpdatesAndDeletes() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = KDriveSnapshot(
            anchor: "initial",
            isFullyEnumerated: true,
            items: [item(id: 1), item(id: 2), item(id: 3)]
        )
        try await store.save(initial, domainIdentifier: "domain", containerIdentifier: "root")
        let updated = KDriveSnapshot(
            anchor: "updated",
            isFullyEnumerated: true,
            items: [item(id: 1, name: "Renamed-1"), item(id: 3), item(id: 4)]
        )
        try await store.save(updated, domainIdentifier: "domain", containerIdentifier: "root")

        var token: String?
        var updates: [KDriveRemoteItem] = []
        var deletions: [Int] = []
        repeat {
            let page = try #require(try await store.snapshotChangePage(
                domainIdentifier: "domain",
                containerIdentifier: "root",
                from: "initial",
                after: token,
                limit: 1
            ))
            #expect(page.changes.updatedItems.count + page.changes.deletedItemIDs.count <= 1)
            #expect(page.targetAnchor == "updated")
            updates.append(contentsOf: page.changes.updatedItems)
            deletions.append(contentsOf: page.changes.deletedItemIDs)
            token = page.nextToken
        } while token != nil

        #expect(updates.map(\.id).sorted() == [1, 4])
        #expect(deletions == [2])
    }

    @Test func failedGenerationCommitRollsBackHeadAndItems() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = snapshot(anchor: "initial", ids: [1, 2, 3])
        try await store.save(initial, domainIdentifier: "domain", containerIdentifier: "42")
        let firstPage = try #require(try await store.snapshotPage(
            domainIdentifier: "domain",
            containerIdentifier: "42",
            after: nil,
            limit: 1
        ))

        let duplicate = KDriveSnapshot(
            anchor: "broken",
            isFullyEnumerated: true,
            items: [item(id: 9), item(id: 9, name: "Duplicate")]
        )
        await #expect(throws: (any Error).self) {
            try await store.save(duplicate, domainIdentifier: "domain", containerIdentifier: "42")
        }

        #expect(try await store.snapshot(domainIdentifier: "domain", containerIdentifier: "42") == initial)
        let continuationToken = try #require(firstPage.nextToken)
        let continued = try #require(try await store.snapshotPage(
            domainIdentifier: "domain",
            containerIdentifier: "42",
            after: continuationToken,
            limit: 10
        ))
        #expect(continued.items.map(\.id) == [2, 3])
    }

    @Test func largeSnapshotReadsOnlyRequestedPageShape() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(
            snapshot(anchor: "large", ids: Array(1...2_000)),
            domainIdentifier: "domain",
            containerIdentifier: "42"
        )
        let page = try #require(try await store.snapshotPage(
            domainIdentifier: "domain",
            containerIdentifier: "42",
            after: nil,
            limit: 50
        ))
        #expect(page.items.count == 50)
        #expect(page.nextToken != nil)
    }

    private func makeStore() throws -> (KDriveSnapshotSQLiteStore, URL) {
        let directory = temporaryDirectory()
        return (
            try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3")),
            directory
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-generation-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snapshot(anchor: String, ids: [Int]) -> KDriveSnapshot {
        KDriveSnapshot(
            anchor: anchor,
            serverCursor: "cursor-\(anchor)",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: ids.map { item(id: $0) }
        )
    }

    private func item(id: Int, name: String? = nil) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name ?? "Item-\(id)",
            type: "file",
            status: "ok",
            driveID: 1,
            parentID: 42,
            path: "/Item-\(id)",
            size: id,
            mimeType: "text/plain",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(id)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(id))
        )
    }
}
