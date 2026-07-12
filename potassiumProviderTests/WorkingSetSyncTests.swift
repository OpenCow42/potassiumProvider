import Foundation
import Testing
import PotassiumProviderCore

@Suite(.serialized)
struct WorkingSetSyncTests {
    @Test func sqliteStorePersistsMaterializationThrottleAndChainedChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-set-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let domain = "domain-1"
        let now = Date(timeIntervalSince1970: 10_000)

        try await store.replaceMaterializedItems([
            KDriveMaterializedItem(fileID: 10, isContainer: true),
            KDriveMaterializedItem(fileID: 20, isContainer: false),
        ], domainIdentifier: domain)
        #expect(try await store.materializedItems(domainIdentifier: domain) == [
            KDriveMaterializedItem(fileID: 10, isContainer: true),
            KDriveMaterializedItem(fileID: 20, isContainer: false),
        ])

        #expect(try await store.claimWorkingSetPoll(
            domainIdentifier: domain,
            now: now,
            minimumInterval: 60
        ))
        #expect(try await store.claimWorkingSetPoll(
            domainIdentifier: domain,
            now: now.addingTimeInterval(59),
            minimumInterval: 60
        ) == false)
        let initialAnchor = try #require(await store.workingSetSnapshot(domainIdentifier: domain)?.anchor)

        let firstItem = makeWorkingSetItem(id: 1, name: "First.txt", updatedAt: 10_001)
        let firstSnapshot = try await store.commitWorkingSetPoll(
            domainIdentifier: domain,
            items: [firstItem],
            changes: KDriveSnapshotChangeSet(updatedItems: [firstItem], deletedItemIDs: []),
            completedAt: now.addingTimeInterval(60)
        )
        let secondItem = makeWorkingSetItem(id: 2, name: "Second.txt", updatedAt: 10_002)
        let secondSnapshot = try await store.commitWorkingSetPoll(
            domainIdentifier: domain,
            items: [secondItem],
            changes: KDriveSnapshotChangeSet(updatedItems: [secondItem], deletedItemIDs: [1]),
            completedAt: now.addingTimeInterval(120)
        )

        #expect(firstSnapshot.anchor != initialAnchor)
        #expect(secondSnapshot.anchor != firstSnapshot.anchor)
        let accumulated = try #require(await store.workingSetChanges(
            domainIdentifier: domain,
            from: initialAnchor
        ))
        #expect(accumulated.anchor == secondSnapshot.anchor)
        #expect(accumulated.changes.updatedItems == [secondItem])
        #expect(accumulated.changes.deletedItemIDs == [1])
        #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: domain) == now.addingTimeInterval(120))
    }

    @Test func pollBuildsWorkingSetFromRelevantMaterializedAndPartialItems() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-set-poll-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        try await store.replaceMaterializedItems([
            KDriveMaterializedItem(fileID: 10, isContainer: true),
            KDriveMaterializedItem(fileID: 99, isContainer: false),
        ], domainIdentifier: "domain-1")

        let categoryItem = makeWorkingSetItem(id: 20, name: "Favorite.txt", parentID: 50, updatedAt: 2_000)
        let folderChild = makeWorkingSetItem(id: 30, name: "Child.txt", parentID: 10, updatedAt: 2_001)
        let materializedFile = makeWorkingSetItem(id: 99, name: "Pinned.txt", parentID: 60, updatedAt: 2_002)
        let remote = WorkingSetRemoteMock(
            relevantItems: [categoryItem],
            advancedResponses: [
                "<initial>": KDriveAdvancedItemPage(
                    items: [folderChild],
                    actions: [],
                    actionItems: [],
                    nextCursor: "cursor-1",
                    hasMore: false
                )
            ],
            itemByID: [:],
            partialResults: [
                KDrivePartialActivityResult(
                    fileID: materializedFile.id,
                    lastAction: "file_update",
                    lastActionAt: Date(timeIntervalSince1970: 2_002),
                    item: materializedFile
                )
            ]
        )
        let coordinator = makeCoordinator(remote: remote, store: store)
        let now = Date(timeIntervalSince1970: 3_000)

        let first = try await coordinator.poll(now: now)
        #expect(first.didPoll)
        #expect(Set(first.snapshot?.items.map(\.id) ?? []) == [20, 30, 99])
        #expect(Set(first.changes.updatedItems.map(\.id)) == [20, 30, 99])
        #expect(await remote.requestedPartialFileIDs() == [20, 30, 99])
        #expect(await remote.requestedPartialSince() == Date(timeIntervalSince1970: 0))

        let throttled = try await coordinator.poll(now: now.addingTimeInterval(30))
        #expect(throttled.didPoll == false)
        #expect(await remote.relevantRequestCount() == 1)
    }

    @Test func moveOutOfMaterializedFolderIsReportedAsUpdateNotDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-set-move-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let oldItem = makeWorkingSetItem(id: 5, name: "Moved.txt", parentID: 10, updatedAt: 4_000)
        let movedItem = makeWorkingSetItem(id: 5, name: "Moved.txt", parentID: 11, updatedAt: 4_001)
        try await store.replaceMaterializedItems(
            [KDriveMaterializedItem(fileID: 10, isContainer: true)],
            domainIdentifier: "domain-1"
        )
        try await store.save(
            KDriveSnapshot(
                anchor: "old-cursor",
                serverCursor: "old-cursor",
                isFullyEnumerated: true,
                usesAdvancedListing: true,
                items: [oldItem]
            ),
            domainIdentifier: "domain-1",
            containerIdentifier: "10"
        )
        let remote = WorkingSetRemoteMock(
            relevantItems: [],
            advancedResponses: [
                "old-cursor": KDriveAdvancedItemPage(
                    items: [],
                    actions: [KDriveRemoteFileAction(action: "file_move_out", fileID: 5, parentID: 10)],
                    actionItems: [],
                    nextCursor: "new-cursor",
                    hasMore: false
                )
            ],
            itemByID: [5: movedItem],
            partialResults: []
        )

        let result = try await makeCoordinator(remote: remote, store: store)
            .poll(now: Date(timeIntervalSince1970: 5_000))

        #expect(result.changes.updatedItems == [movedItem])
        #expect(result.changes.deletedItemIDs.isEmpty)
        #expect(result.snapshot?.items == [movedItem])
    }

    @Test func newestDeleteDoesNotRequireMetadataForSupersededUpdate() throws {
        let changes = try KDriveAdvancedActionReducer.changes(
            from: [
                KDriveRemoteFileAction(action: "file_delete", fileID: 1, parentID: 10),
                KDriveRemoteFileAction(action: "file_rename", fileID: 1, parentID: 10),
            ],
            actionItems: []
        )
        #expect(changes.updatedItems.isEmpty)
        #expect(changes.deletedItemIDs == [1])
    }

    private func makeCoordinator(
        remote: WorkingSetRemoteMock,
        store: KDriveSnapshotSQLiteStore
    ) -> KDriveWorkingSetPollCoordinator {
        KDriveWorkingSetPollCoordinator(
            domainIdentifier: "domain-1",
            driveID: 100,
            rootFileID: 1,
            remote: remote,
            workingSetRemote: remote,
            snapshotStore: store,
            stateStore: store
        )
    }
}

private actor WorkingSetRemoteMock: KDriveFileProviding, KDriveWorkingSetRemoteProviding {
    private let relevantItems: [KDriveRemoteItem]
    private let advancedResponses: [String: KDriveAdvancedItemPage]
    private let itemByID: [Int: KDriveRemoteItem]
    private let partialResults: [KDrivePartialActivityResult]
    private var relevantCalls = 0
    private var partialFileIDs: [Int] = []
    private var partialSince: Date?

    init(
        relevantItems: [KDriveRemoteItem],
        advancedResponses: [String: KDriveAdvancedItemPage],
        itemByID: [Int: KDriveRemoteItem],
        partialResults: [KDrivePartialActivityResult]
    ) {
        self.relevantItems = relevantItems
        self.advancedResponses = advancedResponses
        self.itemByID = itemByID
        self.partialResults = partialResults
    }

    func listWorkingSetRelevantItems(driveID: Int, latestLimit: Int) async throws -> [KDriveRemoteItem] {
        relevantCalls += 1
        return relevantItems
    }

    func listPartialActivities(driveID: Int, fileIDs: [Int], since: Date) async throws -> [KDrivePartialActivityResult] {
        partialFileIDs.append(contentsOf: fileIDs)
        partialSince = since
        return partialResults.filter { fileIDs.contains($0.fileID) }
    }

    func requestedPartialFileIDs() -> [Int] { partialFileIDs.sorted() }
    func requestedPartialSince() -> Date? { partialSince }
    func relevantRequestCount() -> Int { relevantCalls }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        guard let item = itemByID[fileID] else { throw WorkingSetRemoteMockError.unimplemented }
        return item
    }

    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage {
        guard let page = advancedResponses[cursor ?? "<initial>"] else {
            throw WorkingSetRemoteMockError.unimplemented
        }
        return page
    }

    func listDrives() async throws -> [KDriveDriveSummary] { throw WorkingSetRemoteMockError.unimplemented }
    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage { throw WorkingSetRemoteMockError.unimplemented }
    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage { throw WorkingSetRemoteMockError.unimplemented }
    func downloadFile(driveID: Int, fileID: Int) async throws -> Data { throw WorkingSetRemoteMockError.unimplemented }
    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data { throw WorkingSetRemoteMockError.unimplemented }
    func uploadFile(driveID: Int, parentID: Int, fileName: String, contents: Data, lastModifiedAt: Date?, conflictStrategy: KDriveUploadConflictStrategy) async throws -> KDriveRemoteItem { throw WorkingSetRemoteMockError.unimplemented }
    func replaceFile(driveID: Int, parentID: Int, fileName: String, contents: Data, lastModifiedAt: Date?) async throws -> KDriveRemoteItem { throw WorkingSetRemoteMockError.unimplemented }
    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem { throw WorkingSetRemoteMockError.unimplemented }
    func renameItem(driveID: Int, fileID: Int, name: String) async throws { throw WorkingSetRemoteMockError.unimplemented }
    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws { throw WorkingSetRemoteMockError.unimplemented }
    func trashItem(driveID: Int, fileID: Int) async throws { throw WorkingSetRemoteMockError.unimplemented }
    func deleteTrashedItem(driveID: Int, fileID: Int) async throws { throw WorkingSetRemoteMockError.unimplemented }
}

private enum WorkingSetRemoteMockError: Error {
    case unimplemented
}

private func makeWorkingSetItem(
    id: Int,
    name: String,
    parentID: Int = 10,
    updatedAt: TimeInterval
) -> KDriveRemoteItem {
    KDriveRemoteItem(
        id: id,
        name: name,
        type: "file",
        status: "ok",
        driveID: 100,
        parentID: parentID,
        path: "/\(name)",
        size: 10,
        mimeType: "text/plain",
        createdAt: Date(timeIntervalSince1970: updatedAt - 10),
        modifiedAt: Date(timeIntervalSince1970: updatedAt),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}
