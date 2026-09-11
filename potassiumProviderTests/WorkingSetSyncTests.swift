import Foundation
import PotassiumChannelCore
import Testing
import PotassiumProviderCore

@Suite(.serialized)
struct WorkingSetSyncTests {
    @Test(arguments: [false, true])
    func newerMutationStopsObsoletePollBeforeMoreRequestsOrCursorWrites(duringFolder: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let base = makeWorkingSetItem(id: 30, name: "Base.txt", updatedAt: 1_000)
        let edited = makeWorkingSetItem(id: 30, name: "Edited.txt", updatedAt: 1_001)
        let previousTime = Date(timeIntervalSince1970: 1_000)
        let initial = try await store.commitWorkingSetPoll(domainIdentifier: "domain-1", containerSnapshotUpdates: [],
            items: [base], changes: KDriveSnapshotChangeSet(updatedItems: [base], deletedItemIDs: []), completedAt: previousTime)
        try await store.replaceMaterializedItems((10..<18).map { .init(fileID: $0, isContainer: true) }, domainIdentifier: "domain-1")
        let publish: @Sendable () async throws -> Void = {
            let published = try await store.publishKnownWorkingSetItem(edited, replacing: base,
                domainIdentifier: "domain-1", recordedAt: previousTime.addingTimeInterval(1))
            #expect(published)
        }
        let remote = WorkingSetRemoteMock(relevantItems: [], advancedResponses: [
            "<initial>": KDriveAdvancedItemPage(items: [base], actions: [], actionItems: [], nextCursor: "obsolete", hasMore: false)
        ], itemByID: [:], partialResults: [], beforeRelevantReturn: duringFolder ? nil : publish,
            beforeAdvancedReturn: duringFolder ? publish : nil)
        let coordinator = makeCoordinator(remote: remote, store: store)
        let delivery = try await KDriveWorkingSetChangeDelivery.changes(domainIdentifier: "domain-1", from: initial.anchor, store: store) {
            let outcome = try await coordinator.poll(now: previousTime.addingTimeInterval(100))
            #expect(!outcome.didPoll && outcome.snapshot?.items == [edited])
        }
        #expect(delivery?.changes.updatedItems == [edited])
        #expect(await remote.advancedRequestCount() <= (duringFolder ? 4 : 0))
        if duringFolder { #expect(await remote.advancedRequestCount() > 0) }
        #expect(await remote.requestedPartialFileIDs().isEmpty)
        #expect(try await store.snapshot(domainIdentifier: "domain-1", containerIdentifier: "10") == nil)
        #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "domain-1") == previousTime)
    }
    @Test(.timeLimit(.minutes(1)))
    func independentFoldersOverlapWithinBoundAndCommitCompleteOrderedState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        try await store.replaceMaterializedItems((10..<18).map { .init(fileID: $0, isContainer: true) }, domainIdentifier: "domain-1")
        let gate = WorkingSetContainerGate()
        let remote = WorkingSetRemoteMock(relevantItems: [], advancedResponses: [:], itemByID: [:], partialResults: [],
            advancedResponse: { folderID in try await gate.page(folderID: folderID) })
        let coordinator = makeCoordinator(remote: remote, store: store)
        let time = Date(timeIntervalSince1970: 2_000)
        let polling = Task { try await coordinator.poll(now: time) }
        defer { polling.cancel() }
        try await gate.waitForStarted(4)
        #expect(await gate.peakActive == 4)
        #expect(try await store.snapshot(domainIdentifier: "domain-1", containerIdentifier: "10") == nil)
        await gate.release([13, 12, 11, 10])
        try await gate.waitForStarted(8)
        // Completed first-batch cursors remain uncommitted while the rest waits.
        #expect(try await store.snapshot(domainIdentifier: "domain-1", containerIdentifier: "10") == nil)
        await gate.release([17, 16, 15, 14])
        let result = try await polling.value
        let expected = (10..<18).map { makeWorkingSetItem(id: $0 * 10, name: "Fixture.txt", parentID: $0, updatedAt: 1_000) }
        #expect(result.didPoll && result.snapshot?.items == expected)
        #expect(result.changes.updatedItems == expected)
        #expect(await gate.peakActive == 4)
        #expect(await gate.finished == 8)
        #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "domain-1") == time)
        for folderID in 10..<18 {
            let snapshot = try #require(await store.snapshot(domainIdentifier: "domain-1", containerIdentifier: String(folderID)))
            #expect(snapshot.serverCursor == "cursor-\(folderID)")
            #expect(snapshot.items == expected.filter { $0.parentID == folderID })
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledOrThrottledFolderBatchCannotAdvanceAnyCursor(cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        try await store.replaceMaterializedItems((10..<18).map { .init(fileID: $0, isContainer: true) }, domainIdentifier: "domain-1")
        let gate = WorkingSetContainerGate(throttle: !cancel)
        let remote = WorkingSetRemoteMock(relevantItems: [], advancedResponses: [:], itemByID: [:], partialResults: [],
            advancedResponse: { folderID in try await gate.page(folderID: folderID) })
        let coordinator = makeCoordinator(remote: remote, store: store)
        let polling = Task { try await coordinator.poll(now: Date(timeIntervalSince1970: 2_000)) }
        defer { polling.cancel() }
        try await gate.waitForStarted(4)
        if cancel {
            polling.cancel()
            await #expect(throws: CancellationError.self) { try await polling.value }
        } else {
            await gate.release([10])
            // Retry-After survives; the poll neither retries nor commits a prefix.
            await #expect(throws: APIClientError.unacceptableStatusCode(429, body: "synthetic", metadata: .init(retryAfter: "60"))) {
                try await polling.value
            }
        }
        #expect(await gate.startedCount == 4)
        #expect(await gate.finished == 4)
        #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "domain-1") == nil)
        #expect(await remote.requestedPartialFileIDs().isEmpty)
        for folderID in 10..<18 {
            #expect(try await store.snapshot(domainIdentifier: "domain-1", containerIdentifier: String(folderID)) == nil)
        }
    }

    @Test func immediateMaterializationPollsCannotOverlapEachOther() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let remote = WorkingSetRemoteMock(relevantItems: [], advancedResponses: [:], itemByID: [:], partialResults: [],
            relevantDelay: .milliseconds(40))
        let coordinator = makeCoordinator(remote: remote, store: store)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try await coordinator.poll(now: Date(timeIntervalSince1970: 1_000), minimumInterval: 0) }
            }
            try await group.waitForAll()
        }
        #expect(await remote.relevantRequestCount() == 4)
        #expect(await remote.peakConcurrentRelevantRequests() == 1)
    }
    @Test(arguments: [false, true])
    func equivalentServerResultPreservesNewerGenerationButDifferentContentsStillReject(differentContents: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let item = makeWorkingSetItem(id: 30, name: "Server.txt", updatedAt: 1_000)
        let current = KDriveSnapshot(anchor: "newer-local-anchor", serverCursor: "same-server-cursor", isFullyEnumerated: true,
            usesAdvancedListing: true, items: [item])
        try await store.save(current, domainIdentifier: "domain-1", containerIdentifier: "10")
        let prepared = KDriveSnapshot(anchor: "prepared-local-anchor", serverCursor: "same-server-cursor", isFullyEnumerated: true,
            usesAdvancedListing: true, items: differentContents ? [] : [item])
        let updates = [KDriveWorkingSetContainerSnapshotUpdate(containerIdentifier: "10", snapshot: prepared,
            condition: .matching(anchor: "old-local-anchor", serverCursor: "old-server-cursor"))]
        let now = Date(timeIntervalSince1970: 2_000)
        if differentContents {
            await #expect(throws: KDriveSnapshotStoreError.staleSnapshot(domainIdentifier: "domain-1", containerIdentifier: "10")) {
                try await store.commitWorkingSetPoll(domainIdentifier: "domain-1", containerSnapshotUpdates: updates,
                    items: [], changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: [item.id]), completedAt: now)
            }
            #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "domain-1") == nil)
        } else {
            _ = try await store.commitWorkingSetPoll(domainIdentifier: "domain-1", containerSnapshotUpdates: updates,
                items: [item], changes: KDriveSnapshotChangeSet(updatedItems: [item], deletedItemIDs: []), completedAt: now)
            #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "domain-1") == now)
        }
        #expect(try await store.snapshot(domainIdentifier: "domain-1", containerIdentifier: "10") == current)
    }
    @Test(arguments: [false, true])
    func concurrentEnumerationIsRetriedWithoutAdvancingARejectedWatermark(persistentRace: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        try await store.replaceMaterializedItems([KDriveMaterializedItem(fileID: 10, isContainer: true)], domainIdentifier: "domain-1")
        let old = makeWorkingSetItem(id: 30, name: "Old.txt", updatedAt: 1_000)
        let fresh = makeWorkingSetItem(id: 31, name: "Fresh.txt", updatedAt: 1_001)
        let race = WorkingSetSnapshotRace(store: store, item: fresh, persistent: persistentRace)
        let remote = WorkingSetRemoteMock(relevantItems: [], advancedResponses: [
            "<initial>": KDriveAdvancedItemPage(items: [old], actions: [], actionItems: [], nextCursor: "initial", hasMore: false),
            "concurrent": KDriveAdvancedItemPage(items: [], actions: [], actionItems: [], nextCursor: "final", hasMore: false),
        ], itemByID: [:], partialResults: [], beforePartial: { try await race.inject() })
        let coordinator = makeCoordinator(remote: remote, store: store)
        let now = Date(timeIntervalSince1970: 2_000)
        if persistentRace {
            await #expect(throws: KDriveSnapshotStoreError.staleSnapshot(domainIdentifier: "domain-1", containerIdentifier: "10")) {
                try await coordinator.poll(now: now)
            }
            #expect(await remote.relevantRequestCount() == 3)
            #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "domain-1") == nil)
            #expect(try await store.snapshot(domainIdentifier: "domain-1", containerIdentifier: "10")?.items == [fresh])
        } else {
            let result = try await coordinator.poll(now: now)
            #expect(result.snapshot?.items == [fresh])
            #expect(await remote.relevantRequestCount() == 2)
            #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "domain-1") == now)
        }
    }
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
            containerSnapshotUpdates: [],
            items: [firstItem],
            changes: KDriveSnapshotChangeSet(updatedItems: [firstItem], deletedItemIDs: []),
            completedAt: now.addingTimeInterval(60)
        )
        let secondItem = makeWorkingSetItem(id: 2, name: "Second.txt", updatedAt: 10_002)
        let secondSnapshot = try await store.commitWorkingSetPoll(
            domainIdentifier: domain,
            containerSnapshotUpdates: [],
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

    @Test func staleContainerUpdateRollsBackEntireWorkingSetCommit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-set-rollback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let domain = "domain-1"
        let oldFirst = KDriveSnapshot(
            anchor: "first-old",
            serverCursor: "first-old",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: []
        )
        let oldSecond = KDriveSnapshot(
            anchor: "second-old",
            serverCursor: "second-old",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: []
        )
        try await store.save(oldFirst, domainIdentifier: domain, containerIdentifier: "10")
        try await store.save(oldSecond, domainIdentifier: domain, containerIdentifier: "20")
        #expect(try await store.claimWorkingSetPoll(
            domainIdentifier: domain,
            now: Date(timeIntervalSince1970: 1_000),
            minimumInterval: 0
        ))
        let initialWorkingSet = try #require(await store.workingSetSnapshot(domainIdentifier: domain))

        let concurrentSecond = KDriveSnapshot(
            anchor: "second-concurrent",
            serverCursor: "second-concurrent",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: []
        )
        try await store.save(
            concurrentSecond,
            domainIdentifier: domain,
            containerIdentifier: "20",
            condition: .matching(anchor: oldSecond.anchor, serverCursor: oldSecond.serverCursor)
        )
        let workingItem = makeWorkingSetItem(id: 1, name: "Updated.txt", updatedAt: 1_001)

        await #expect(throws: KDriveSnapshotStoreError.staleSnapshot(
            domainIdentifier: domain,
            containerIdentifier: "20"
        )) {
            try await store.commitWorkingSetPoll(
                domainIdentifier: domain,
                containerSnapshotUpdates: [
                    KDriveWorkingSetContainerSnapshotUpdate(
                        containerIdentifier: "10",
                        snapshot: KDriveSnapshot(
                            anchor: "first-new",
                            serverCursor: "first-new",
                            isFullyEnumerated: true,
                            usesAdvancedListing: true,
                            items: []
                        ),
                        condition: .matching(anchor: oldFirst.anchor, serverCursor: oldFirst.serverCursor)
                    ),
                    KDriveWorkingSetContainerSnapshotUpdate(
                        containerIdentifier: "20",
                        snapshot: KDriveSnapshot(
                            anchor: "second-new",
                            serverCursor: "second-new",
                            isFullyEnumerated: true,
                            usesAdvancedListing: true,
                            items: []
                        ),
                        condition: .matching(anchor: oldSecond.anchor, serverCursor: oldSecond.serverCursor)
                    ),
                ],
                items: [workingItem],
                changes: KDriveSnapshotChangeSet(updatedItems: [workingItem], deletedItemIDs: []),
                completedAt: Date(timeIntervalSince1970: 1_001)
            )
        }

        #expect(try await store.snapshot(domainIdentifier: domain, containerIdentifier: "10") == oldFirst)
        #expect(try await store.snapshot(domainIdentifier: domain, containerIdentifier: "20") == concurrentSecond)
        #expect(try await store.workingSetSnapshot(domainIdentifier: domain) == initialWorkingSet)
        #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: domain) == nil)
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

    @Test func failedPollDoesNotAdvanceMaterializedContainerCursor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-set-atomic-poll-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let oldItem = makeWorkingSetItem(id: 5, name: "Old.txt", parentID: 10, updatedAt: 4_000)
        let updatedItem = makeWorkingSetItem(id: 5, name: "Updated.txt", parentID: 10, updatedAt: 4_001)
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
                    actions: [KDriveRemoteFileAction(action: "file_update", fileID: 5, parentID: 10)],
                    actionItems: [updatedItem],
                    nextCursor: "new-cursor",
                    hasMore: false
                )
            ],
            itemByID: [:],
            partialResults: [],
            failsPartialListing: true
        )

        await #expect(throws: WorkingSetRemoteMockError.self) {
            try await makeCoordinator(remote: remote, store: store)
                .poll(now: Date(timeIntervalSince1970: 5_000))
        }

        let storedSnapshot = try #require(await store.snapshot(
            domainIdentifier: "domain-1",
            containerIdentifier: "10"
        ))
        #expect(storedSnapshot.anchor == "old-cursor")
        #expect(storedSnapshot.serverCursor == "old-cursor")
        #expect(storedSnapshot.items == [oldItem])
        #expect(try await store.lastSuccessfulWorkingSetPoll(domainIdentifier: "domain-1") == nil)
    }

    @Test func partialMoveOutOfMaterializedFileIsReportedAsUpdateNotDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-set-partial-move-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let movedItem = makeWorkingSetItem(id: 5, name: "Moved.txt", parentID: 11, updatedAt: 5_000)
        try await store.replaceMaterializedItems(
            [KDriveMaterializedItem(fileID: 5, isContainer: false)],
            domainIdentifier: "domain-1"
        )
        let remote = WorkingSetRemoteMock(
            relevantItems: [],
            advancedResponses: [:],
            itemByID: [5: movedItem],
            partialResults: [
                KDrivePartialActivityResult(
                    fileID: 5,
                    lastAction: "file_move_out",
                    lastActionAt: Date(timeIntervalSince1970: 5_000),
                    item: nil
                )
            ]
        )

        let result = try await makeCoordinator(remote: remote, store: store)
            .poll(now: Date(timeIntervalSince1970: 6_000))

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
            stateStore: store
        )
    }
}

private actor WorkingSetRemoteMock: KDriveFileProviding, KDriveWorkingSetRemoteProviding {
    private let beforePartial: (@Sendable () async throws -> Void)?
    private let beforeRelevantReturn: (@Sendable () async throws -> Void)?
    private let beforeAdvancedReturn: (@Sendable () async throws -> Void)?
    private let advancedResponse: (@Sendable (Int) async throws -> KDriveAdvancedItemPage)?
    private var advancedCalls = 0
    private let relevantItems: [KDriveRemoteItem]
    private let advancedResponses: [String: KDriveAdvancedItemPage]
    private let itemByID: [Int: KDriveRemoteItem]
    private let partialResults: [KDrivePartialActivityResult]
    private let failsPartialListing: Bool
    private var relevantCalls = 0
    private let relevantDelay: Duration
    private var activeRelevantCalls = 0
    private var peakRelevantCalls = 0
    private var partialFileIDs: [Int] = []
    private var partialSince: Date?

    init(
        relevantItems: [KDriveRemoteItem],
        advancedResponses: [String: KDriveAdvancedItemPage],
        itemByID: [Int: KDriveRemoteItem],
        partialResults: [KDrivePartialActivityResult],
        failsPartialListing: Bool = false,
        beforePartial: (@Sendable () async throws -> Void)? = nil,
        relevantDelay: Duration = .zero,
        beforeRelevantReturn: (@Sendable () async throws -> Void)? = nil,
        beforeAdvancedReturn: (@Sendable () async throws -> Void)? = nil,
        advancedResponse: (@Sendable (Int) async throws -> KDriveAdvancedItemPage)? = nil
    ) {
        self.relevantItems = relevantItems
        self.advancedResponses = advancedResponses
        self.itemByID = itemByID
        self.partialResults = partialResults
        self.failsPartialListing = failsPartialListing
        self.beforePartial = beforePartial
        self.relevantDelay = relevantDelay
        self.beforeRelevantReturn = beforeRelevantReturn
        self.beforeAdvancedReturn = beforeAdvancedReturn
        self.advancedResponse = advancedResponse
    }

    func listWorkingSetRelevantItems(driveID: Int, latestLimit: Int) async throws -> [KDriveRemoteItem] {
        relevantCalls += 1
        activeRelevantCalls += 1
        peakRelevantCalls = max(peakRelevantCalls, activeRelevantCalls)
        defer { activeRelevantCalls -= 1 }
        if relevantDelay > .zero { try await Task.sleep(for: relevantDelay) }
        try await beforeRelevantReturn?()
        return relevantItems
    }

    func listPartialActivities(driveID: Int, fileIDs: [Int], since: Date) async throws -> [KDrivePartialActivityResult] {
        try await beforePartial?()
        partialFileIDs.append(contentsOf: fileIDs)
        partialSince = since
        if failsPartialListing { throw WorkingSetRemoteMockError.unimplemented }
        return partialResults.filter { fileIDs.contains($0.fileID) }
    }

    func requestedPartialFileIDs() -> [Int] { partialFileIDs.sorted() }
    func requestedPartialSince() -> Date? { partialSince }
    func relevantRequestCount() -> Int { relevantCalls }
    func peakConcurrentRelevantRequests() -> Int { peakRelevantCalls }
    func advancedRequestCount() -> Int { advancedCalls }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        guard let item = itemByID[fileID] else { throw WorkingSetRemoteMockError.unimplemented }
        return item
    }

    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage {
        advancedCalls += 1
        try await beforeAdvancedReturn?()
        if let advancedResponse { return try await advancedResponse(folderID) }
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
    func uploadFile(driveID: Int, parentID: Int, fileName: String, contents: Data, lastModifiedAt: Date?, conflictStrategy: KDriveUploadConflictStrategy, clientToken: String?, contentHash: String?) async throws -> KDriveRemoteItem { throw WorkingSetRemoteMockError.unimplemented }
    func replaceFile(driveID: Int, fileID: Int, expectedETag: String, clientToken: String, contentHash: String, contents: Data, lastModifiedAt: Date?) async throws -> KDriveRemoteItem { throw WorkingSetRemoteMockError.unimplemented }
    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem { throw WorkingSetRemoteMockError.unimplemented }
    func renameItem(driveID: Int, fileID: Int, name: String) async throws { throw WorkingSetRemoteMockError.unimplemented }
    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws { throw WorkingSetRemoteMockError.unimplemented }
    func updateModificationDate(driveID: Int, fileID: Int, date: Date) async throws { throw WorkingSetRemoteMockError.unimplemented }
    func trashItem(driveID: Int, fileID: Int) async throws { throw WorkingSetRemoteMockError.unimplemented }
    func deleteTrashedItem(driveID: Int, fileID: Int) async throws { throw WorkingSetRemoteMockError.unimplemented }
}

private actor WorkingSetSnapshotRace {
    let store: KDriveSnapshotSQLiteStore
    let item: KDriveRemoteItem
    let persistent: Bool
    var injected = false
    init(store: KDriveSnapshotSQLiteStore, item: KDriveRemoteItem, persistent: Bool) {
        self.store = store; self.item = item; self.persistent = persistent
    }
    func inject() async throws {
        guard persistent || !injected else { return }
        injected = true
        try await store.save(KDriveSnapshot(anchor: UUID().uuidString, serverCursor: "concurrent",
            isFullyEnumerated: true, usesAdvancedListing: true, items: [item]),
            domainIdentifier: "domain-1", containerIdentifier: "10")
    }
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

/// Suspension is controlled by requests, not subsecond sleeps or CPU scheduling.
private actor WorkingSetContainerGate {
    let throttle: Bool
    private var waiters: [Int: AsyncStream<Void>.Continuation] = [:]
    private let starts = AsyncStream<Int>.makeStream()
    private(set) var startedCount = 0
    private(set) var finished = 0
    private(set) var peakActive = 0
    init(throttle: Bool = false) { self.throttle = throttle }
    func page(folderID: Int) async throws -> KDriveAdvancedItemPage {
        let release = AsyncStream<Void>.makeStream()
        waiters[folderID] = release.continuation
        startedCount += 1
        peakActive = max(peakActive, waiters.count)
        starts.continuation.yield(startedCount)
        defer { waiters[folderID] = nil; finished += 1 }
        var iterator = release.stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
        if throttle { throw APIClientError.unacceptableStatusCode(429, body: "synthetic", metadata: .init(retryAfter: "60")) }
        return KDriveAdvancedItemPage(items: [makeWorkingSetItem(id: folderID * 10, name: "Fixture.txt", parentID: folderID, updatedAt: 1_000)],
            actions: [], actionItems: [], nextCursor: "cursor-\(folderID)", hasMore: false)
    }
    func waitForStarted(_ count: Int) async throws {
        if startedCount >= count { return }
        for await number in starts.stream {
            if number >= count { return }
        }
        throw CancellationError()
    }
    func release(_ folders: [Int]) {
        for folder in folders { waiters[folder]?.yield(()); waiters[folder]?.finish() }
    }
}
