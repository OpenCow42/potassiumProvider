import Foundation
import PotassiumChannelCore
import Testing
import UniformTypeIdentifiers
@preconcurrency import SQLite
@testable import potassiumProvider
import PotassiumProviderCore

@Suite(.serialized)
struct PotassiumProviderCoreTests {
    @Test func domainConfigurationStorePersistsAndRemovesConfigurations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("potassium-provider-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DomainConfigurationFileStore(directoryURL: directory)
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "domain-1",
            displayName: "Work Drive",
            driveID: 42,
            driveName: "kDrive",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        try await store.save(configuration)

        #expect(try await store.configuration(domainIdentifier: "domain-1") == configuration)
        #expect(try await store.allConfigurations() == [configuration])

        try await store.remove(domainIdentifier: "domain-1")

        #expect(try await store.configuration(domainIdentifier: "domain-1") == nil)
        #expect(try await store.allConfigurations().isEmpty)
    }

    @Test func providerAccountStorePersistsAndRemovesAccounts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderAccountFileStore(directoryURL: directory)
        let account = ProviderAccount(
            accountIdentifier: "account-1",
            displayName: "Work",
            authenticationKind: .oauth,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        try await store.save(account)

        #expect(try await store.account(accountIdentifier: "account-1") == account)
        #expect(try await store.allAccounts() == [account])

        try await store.remove(accountIdentifier: "account-1")

        #expect(try await store.account(accountIdentifier: "account-1") == nil)
        #expect(try await store.allAccounts().isEmpty)
    }

    @Test func domainConfigurationDecodesLegacyAccountIdentifier() throws {
        let json = """
        {
          "domainIdentifier": "domain-1",
          "displayName": "Work Drive",
          "driveID": 42,
          "driveName": "Work Drive",
          "rootFileID": 1,
          "createdAt": "1970-01-01T00:16:40Z",
          "updatedAt": "1970-01-01T00:16:40Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let configuration = try decoder.decode(ProviderDomainConfiguration.self, from: Data(json.utf8))

        #expect(configuration.accountIdentifier == ProviderConstants.legacyAccountIdentifier)
        #expect(configuration.driveID == 42)
    }

    @Test func inMemoryTokenStoreScopesTokensAndMigratesLegacyToken() async throws {
        let store = InMemoryOAuthTokenStore()
        let firstToken = token(accessToken: "first-token")
        let secondToken = token(accessToken: "second-token")

        await store.saveToken(firstToken, accountIdentifier: "account-1")
        await store.saveToken(secondToken, accountIdentifier: "account-2")

        #expect(await store.loadToken(accountIdentifier: "account-1")?.accessToken == "first-token")
        #expect(await store.loadToken(accountIdentifier: "account-2")?.accessToken == "second-token")

        await store.deleteToken(accountIdentifier: "account-1")

        #expect(await store.loadToken(accountIdentifier: "account-1") == nil)
        #expect(await store.loadToken(accountIdentifier: "account-2")?.accessToken == "second-token")

        let legacyStore = InMemoryOAuthTokenStore(token: token(accessToken: "legacy-token"))
        #expect(try await legacyStore.migrateLegacyToken(to: "migrated-account"))
        #expect(await legacyStore.loadToken(accountIdentifier: "migrated-account")?.accessToken == "legacy-token")
        #expect(await legacyStore.loadLegacyToken() == nil)
    }

    @Test func providerDomainConfigurationDerivesFinderDisplayName() {
        #expect(ProviderDomainConfiguration.finderDisplayName(forDriveName: " Work Drive ") == "Work Drive")
        #expect(ProviderDomainConfiguration.finderDisplayName(forDriveName: "   ") == "kDrive")
    }

    @Test func asyncOperationLimiterCapsConcurrentOperations() async throws {
        let maximumConcurrentOperations = 4
        let operationCount = 20
        let limiter = AsyncOperationLimiter(maxConcurrentOperations: maximumConcurrentOperations)
        let activityProbe = LimiterActivityProbe()

        let completedOperations = try await withThrowingTaskGroup(of: Int.self) { group in
            for operation in 0..<operationCount {
                group.addTask {
                    try await limiter.withPermit {
                        await activityProbe.startOperation()
                        do {
                            try await Task.sleep(nanoseconds: 10_000_000)
                            await activityProbe.finishOperation()
                            return operation
                        } catch {
                            await activityProbe.finishOperation()
                            throw error
                        }
                    }
                }
            }

            var operations = Set<Int>()
            while let operation = try await group.next() {
                operations.insert(operation)
            }
            return operations
        }

        #expect(completedOperations == Set(0..<operationCount))
        #expect(await activityProbe.maximumActiveOperationCount() <= maximumConcurrentOperations)
        #expect(await activityProbe.finishedOperationCount() == operationCount)
    }

    @Test func asyncOperationLimiterCancelsWaitingOperationWithoutConsumingPermit() async throws {
        let limiter = AsyncOperationLimiter(maxConcurrentOperations: 1)
        let holderStarted = AsyncTestGate()
        let releaseHolder = AsyncTestGate()
        let cancelledOperationProbe = LimiterActivityProbe()

        let holder = Task {
            try await limiter.withPermit {
                await holderStarted.open()
                await releaseHolder.wait()
            }
        }
        await holderStarted.wait()

        let waitingOperation = Task {
            try await limiter.withPermit {
                await cancelledOperationProbe.startOperation()
                await cancelledOperationProbe.finishOperation()
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        waitingOperation.cancel()

        var sawCancellation = false
        do {
            try await withTimeout(nanoseconds: 1_000_000_000) {
                try await waitingOperation.value
            }
        } catch is CancellationError {
            sawCancellation = true
        }
        #expect(sawCancellation)
        #expect(await cancelledOperationProbe.startedOperationCount() == 0)

        await releaseHolder.open()
        try await holder.value

        let nextValue = try await withTimeout(nanoseconds: 1_000_000_000) {
            try await limiter.withPermit {
                42
            }
        }
        #expect(nextValue == 42)
    }

    @Test func asyncOperationLimiterReleasesPermitAfterThrownError() async throws {
        let limiter = AsyncOperationLimiter(maxConcurrentOperations: 1)

        var sawExpectedError = false
        do {
            let _: Void = try await limiter.withPermit {
                throw AsyncOperationLimiterTestError.expected
            }
        } catch AsyncOperationLimiterTestError.expected {
            sawExpectedError = true
        }
        #expect(sawExpectedError)

        let nextValue = try await withTimeout(nanoseconds: 1_000_000_000) {
            try await limiter.withPermit {
                "next"
            }
        }
        #expect(nextValue == "next")
    }

    @Test func snapshotStorePersistsAndRemovesDomainSnapshots() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let rootSnapshot = KDriveSnapshot(
            anchor: "root-anchor",
            serverCursor: "root-cursor",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: [makeItem(id: 1, name: "Root.txt")]
        )
        let trashSnapshot = KDriveSnapshot(anchor: "trash-anchor", items: [makeItem(id: 2, name: "Trash.txt")])

        try await store.save(rootSnapshot, domainIdentifier: "domain/1", containerIdentifier: "root")
        try await store.save(trashSnapshot, domainIdentifier: "domain/1", containerIdentifier: "trash")

        #expect(try await store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "root") == rootSnapshot)
        #expect(try await store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "trash") == trashSnapshot)

        try await store.removeSnapshot(domainIdentifier: "domain/1", containerIdentifier: "root")

        #expect(try await store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "root") == nil)
        #expect(try await store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "trash") == trashSnapshot)

        try await store.removeSnapshots(domainIdentifier: "domain/1")

        #expect(try await store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "root") == nil)
        #expect(try await store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "trash") == nil)
    }

    @Test func snapshotStoreReportsDomainStatistics() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))

        try await store.save(
            KDriveSnapshot(
                serverCursor: "root-cursor",
                isFullyEnumerated: true,
                usesAdvancedListing: true,
                items: [
                    makeItem(id: 1, name: "Root.txt"),
                    makeItem(id: 2, name: "Folder", type: "dir", mimeType: nil),
                ]
            ),
            domainIdentifier: "domain-1",
            containerIdentifier: "root"
        )
        try await store.save(
            KDriveSnapshot(items: [makeItem(id: 3, name: "Trash.txt")]),
            domainIdentifier: "domain-1",
            containerIdentifier: "trash"
        )
        try await store.save(
            KDriveSnapshot(isFullyEnumerated: true, items: [makeItem(id: 4, name: "Other.txt")]),
            domainIdentifier: "domain-2",
            containerIdentifier: "root"
        )

        let statistics = try await store.snapshotStatistics(domainIdentifiers: ["domain-1", "domain-2", "missing-domain"])
        let statisticsByDomain = Dictionary(uniqueKeysWithValues: statistics.map { ($0.domainIdentifier, $0) })

        let domainOne = try #require(statisticsByDomain["domain-1"])
        #expect(domainOne.containerCount == 2)
        #expect(domainOne.itemCount == 3)
        #expect(domainOne.fullyEnumeratedContainerCount == 1)
        #expect(domainOne.advancedListingContainerCount == 1)
        #expect(domainOne.lastUpdatedAt != nil)

        let domainTwo = try #require(statisticsByDomain["domain-2"])
        #expect(domainTwo.containerCount == 1)
        #expect(domainTwo.itemCount == 1)
        #expect(domainTwo.fullyEnumeratedContainerCount == 1)

        let missingDomain = try #require(statisticsByDomain["missing-domain"])
        #expect(missingDomain.containerCount == 0)
        #expect(missingDomain.itemCount == 0)
        #expect(missingDomain.lastUpdatedAt == nil)
    }

    @Test func guardedSnapshotSaveHonorsConditions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let initialSnapshot = KDriveSnapshot(
            anchor: "initial-anchor",
            serverCursor: "initial-cursor",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: [makeItem(id: 1, name: "Initial.txt")]
        )
        let updatedSnapshot = KDriveSnapshot(
            anchor: "updated-anchor",
            serverCursor: "updated-cursor",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: [makeItem(id: 2, name: "Updated.txt")]
        )

        try await store.save(
            initialSnapshot,
            domainIdentifier: "domain-1",
            containerIdentifier: "folder-1",
            condition: .missing
        )
        var missingConditionRejected = false
        do {
            try await store.save(
                updatedSnapshot,
                domainIdentifier: "domain-1",
                containerIdentifier: "folder-1",
                condition: .missing
            )
        } catch let error as KDriveSnapshotStoreError {
            missingConditionRejected = error == .staleSnapshot(domainIdentifier: "domain-1", containerIdentifier: "folder-1")
        }
        #expect(missingConditionRejected)

        try await store.save(
            updatedSnapshot,
            domainIdentifier: "domain-1",
            containerIdentifier: "folder-1",
            condition: .matching(anchor: "initial-anchor", serverCursor: "initial-cursor")
        )

        #expect(try await store.snapshot(domainIdentifier: "domain-1", containerIdentifier: "folder-1") == updatedSnapshot)
    }

    @Test func guardedSnapshotSavePreventsCrossInstanceCursorRegression() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Snapshots.sqlite3")
        let firstStore = try KDriveSnapshotSQLiteStore(databaseURL: databaseURL)
        let secondStore = try KDriveSnapshotSQLiteStore(databaseURL: databaseURL)
        let oldSnapshot = KDriveSnapshot(
            anchor: "old-anchor",
            serverCursor: "old-cursor",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: [makeItem(id: 1, name: "Old.txt")]
        )
        let newerSnapshot = KDriveSnapshot(
            anchor: "new-anchor",
            serverCursor: "new-cursor",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: [makeItem(id: 2, name: "New.txt")]
        )
        let regressingSnapshot = KDriveSnapshot(
            anchor: "regressing-anchor",
            serverCursor: "regressing-cursor",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: [makeItem(id: 3, name: "Regressing.txt")]
        )

        try await firstStore.save(oldSnapshot, domainIdentifier: "domain-1", containerIdentifier: "folder-1")
        try await secondStore.save(
            newerSnapshot,
            domainIdentifier: "domain-1",
            containerIdentifier: "folder-1",
            condition: .matching(anchor: "old-anchor", serverCursor: "old-cursor")
        )

        var staleSaveRejected = false
        do {
            try await firstStore.save(
                regressingSnapshot,
                domainIdentifier: "domain-1",
                containerIdentifier: "folder-1",
                condition: .matching(anchor: "old-anchor", serverCursor: "old-cursor")
            )
        } catch let error as KDriveSnapshotStoreError {
            staleSaveRejected = error == .staleSnapshot(domainIdentifier: "domain-1", containerIdentifier: "folder-1")
        }
        #expect(staleSaveRejected)
        #expect(try await firstStore.snapshot(domainIdentifier: "domain-1", containerIdentifier: "folder-1") == newerSnapshot)
    }

    @Test func providerEventStorePersistsUpdatesFiltersAndRemovesEvents() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try KDriveProviderEventSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let oldConflictID = UUID()
        let newConflictID = UUID()
        let otherDomainConflictID = UUID()
        var oldConflict = makeConflictEvent(
            id: oldConflictID,
            detectedAt: Date(timeIntervalSince1970: 100),
            domainIdentifier: "domain-1",
            itemName: "Old.txt",
            state: .unresolved
        )
        let newConflict = makeConflictEvent(
            id: newConflictID,
            detectedAt: Date(timeIntervalSince1970: 300),
            domainIdentifier: "domain-1",
            itemName: "New.txt",
            state: .blockedRetryable
        )
        let otherDomainConflict = makeConflictEvent(
            id: otherDomainConflictID,
            detectedAt: Date(timeIntervalSince1970: 200),
            domainIdentifier: "domain-2",
            itemName: "Other.txt",
            state: .failed
        )

        try await store.saveConflict(oldConflict)
        try await store.saveConflict(newConflict)
        try await store.saveConflict(otherDomainConflict)

        oldConflict.resolvedAt = Date(timeIntervalSince1970: 400)
        oldConflict.conflictItemIdentifier = "99"
        oldConflict.conflictItemName = "Old conflict.txt"
        oldConflict.resolutionState = .automaticallyResolved
        oldConflict.automaticallyResolved = true
        oldConflict.resolutionKind = .preservedBothAsRenamedConflictCopy
        oldConflict.resolutionSummary = "Preserved both."
        try await store.saveConflict(oldConflict)

        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 150),
            domainIdentifier: "domain-1",
            kind: .enumeration,
            summary: "Older activity."
        ))
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 350),
            domainIdentifier: "domain-1",
            kind: .changeSync,
            summary: "Newer activity.",
            relatedConflictID: newConflictID
        ))
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 250),
            domainIdentifier: "domain-2",
            kind: .delete,
            summary: "Other domain activity."
        ))

        let allConflicts = try await store.recentConflicts(domainIdentifier: nil, limit: 10)
        #expect(allConflicts.map(\.id) == [newConflictID, otherDomainConflictID, oldConflictID])

        let domainConflicts = try await store.recentConflicts(domainIdentifier: "domain-1", limit: 10)
        #expect(domainConflicts.map(\.id) == [newConflictID, oldConflictID])
        #expect(domainConflicts.last?.resolutionState == .automaticallyResolved)
        #expect(domainConflicts.last?.conflictItemIdentifier == "99")

        let domainActivity = try await store.recentActivity(domainIdentifier: "domain-1", limit: 10)
        #expect(domainActivity.map(\.summary) == ["Newer activity.", "Older activity."])
        #expect(domainActivity.first?.relatedConflictID == newConflictID)

        let failureDiagnostic = KDriveProviderActivityErrorDiagnostic(
            errorCategory: .network,
            providerErrorCode: -1009,
            underlyingErrorDomain: NSURLErrorDomain,
            underlyingErrorCode: NSURLErrorNotConnectedToInternet,
            recoverySuggestion: "Connect to the network and retry.",
            diagnosticSummary: "A network request failed before the operation could complete."
        )
        try await store.recordActivity(KDriveProviderActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 450),
            domainIdentifier: "domain-1",
            driveID: 10,
            kind: .metadataLookup,
            outcome: .failure,
            severity: .error,
            itemIdentifier: "42",
            itemName: "Report.txt",
            itemPath: "/Report.txt",
            summary: "Could not resolve item metadata.",
            diagnostic: failureDiagnostic
        ))
        try await store.recordActivity(KDriveProviderActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 500),
            domainIdentifier: ProviderConstants.appActivityDomainIdentifier,
            driveID: 0,
            kind: .driveDiscovery,
            scope: .app,
            outcome: .failure,
            severity: .error,
            itemIdentifier: nil,
            itemName: nil,
            itemPath: nil,
            summary: "Could not load kDrives.",
            diagnostic: KDriveProviderActivityErrorDiagnostic(errorCategory: .api)
        ))

        let domainFailures = try await store.recentActivity(domainIdentifier: "domain-1", outcome: .failure, limit: 10)
        #expect(domainFailures.map(\.summary) == ["Could not resolve item metadata."])
        #expect(domainFailures.first?.scope == .domain)
        #expect(domainFailures.first?.severity == .error)
        #expect(domainFailures.first?.errorCategory == .network)
        #expect(domainFailures.first?.providerErrorCode == -1009)

        let domainSuccesses = try await store.recentActivity(domainIdentifier: "domain-1", outcome: .success, limit: 10)
        #expect(domainSuccesses.map(\.summary) == ["Newer activity.", "Older activity."])

        try await store.removeEvents(domainIdentifier: "domain-1")

        #expect(try await store.recentConflicts(domainIdentifier: "domain-1", limit: 10).isEmpty)
        #expect(try await store.recentActivity(domainIdentifier: "domain-1", limit: 10).isEmpty)
        #expect(try await store.recentConflicts(domainIdentifier: nil, limit: 10).map(\.id) == [otherDomainConflictID])
        #expect(try await store.recentActivity(domainIdentifier: ProviderConstants.appActivityDomainIdentifier, limit: 10).map(\.summary) == ["Could not load kDrives."])
    }

    @Test func providerEventStoreReportsDomainStatistics() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try KDriveProviderEventSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        var resolvedConflict = makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 100),
            domainIdentifier: "domain-1",
            itemName: "Resolved.txt",
            state: .automaticallyResolved
        )
        resolvedConflict.resolvedAt = Date(timeIntervalSince1970: 450)

        try await store.saveConflict(makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 200),
            domainIdentifier: "domain-1",
            itemName: "Unresolved.txt",
            state: .unresolved
        ))
        try await store.saveConflict(makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 300),
            domainIdentifier: "domain-1",
            itemName: "Blocked.txt",
            state: .blockedRetryable
        ))
        try await store.saveConflict(makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 400),
            domainIdentifier: "domain-1",
            itemName: "Failed.txt",
            state: .failed
        ))
        try await store.saveConflict(resolvedConflict)
        try await store.saveConflict(makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 500),
            domainIdentifier: "domain-2",
            itemName: "Other.txt",
            state: .unresolved
        ))

        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 600),
            domainIdentifier: "domain-1",
            kind: .enumeration,
            summary: "Enumerated folder."
        ))
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 700),
            domainIdentifier: "domain-1",
            kind: .metadataLookup,
            summary: "Metadata failed.",
            outcome: .failure
        ))
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 800),
            domainIdentifier: "domain-1",
            kind: .changeSync,
            summary: "Sync failed.",
            outcome: .failure
        ))
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 900),
            domainIdentifier: ProviderConstants.appActivityDomainIdentifier,
            kind: .driveDiscovery,
            summary: "Could not load kDrives.",
            scope: .app,
            outcome: .failure
        ))

        let statistics = try await store.eventStatistics(domainIdentifiers: [
            "domain-1",
            "domain-2",
            "missing-domain",
            ProviderConstants.appActivityDomainIdentifier,
        ])
        let statisticsByDomain = Dictionary(uniqueKeysWithValues: statistics.map { ($0.domainIdentifier, $0) })

        let domainOne = try #require(statisticsByDomain["domain-1"])
        #expect(domainOne.unresolvedConflictCount == 1)
        #expect(domainOne.blockedConflictCount == 1)
        #expect(domainOne.failedConflictCount == 1)
        #expect(domainOne.resolvedConflictCount == 1)
        #expect(domainOne.recentSuccessCount == 1)
        #expect(domainOne.recentFailureCount == 2)
        #expect(domainOne.latestConflictAt == Date(timeIntervalSince1970: 450))
        #expect(domainOne.latestActivityAt == Date(timeIntervalSince1970: 800))

        let domainTwo = try #require(statisticsByDomain["domain-2"])
        #expect(domainTwo.unresolvedConflictCount == 1)
        #expect(domainTwo.recentFailureCount == 0)

        let appStats = try #require(statisticsByDomain[ProviderConstants.appActivityDomainIdentifier])
        #expect(appStats.recentFailureCount == 1)
        #expect(appStats.latestActivityAt == Date(timeIntervalSince1970: 900))

        let missingDomain = try #require(statisticsByDomain["missing-domain"])
        #expect(missingDomain.attentionCount == 0)
    }

    @Test func providerEventStoreClearsActivityAndResolvedConflictsOnly() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try KDriveProviderEventSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let resolvedConflictID = UUID()
        let unresolvedConflictID = UUID()
        let blockedConflictID = UUID()
        let failedConflictID = UUID()
        let otherDomainResolvedConflictID = UUID()

        try await store.saveConflict(makeConflictEvent(
            id: resolvedConflictID,
            detectedAt: Date(timeIntervalSince1970: 100),
            domainIdentifier: "domain-1",
            itemName: "Resolved.txt",
            state: .automaticallyResolved
        ))
        try await store.saveConflict(makeConflictEvent(
            id: unresolvedConflictID,
            detectedAt: Date(timeIntervalSince1970: 200),
            domainIdentifier: "domain-1",
            itemName: "Unresolved.txt",
            state: .unresolved
        ))
        try await store.saveConflict(makeConflictEvent(
            id: blockedConflictID,
            detectedAt: Date(timeIntervalSince1970: 300),
            domainIdentifier: "domain-1",
            itemName: "Blocked.txt",
            state: .blockedRetryable
        ))
        try await store.saveConflict(makeConflictEvent(
            id: failedConflictID,
            detectedAt: Date(timeIntervalSince1970: 400),
            domainIdentifier: "domain-1",
            itemName: "Failed.txt",
            state: .failed
        ))
        try await store.saveConflict(makeConflictEvent(
            id: otherDomainResolvedConflictID,
            detectedAt: Date(timeIntervalSince1970: 500),
            domainIdentifier: "domain-2",
            itemName: "Other resolved.txt",
            state: .automaticallyResolved
        ))

        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 600),
            domainIdentifier: "domain-1",
            kind: .enumeration,
            summary: "Domain activity."
        ))
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 700),
            domainIdentifier: ProviderConstants.appActivityDomainIdentifier,
            kind: .runtimeLoading,
            summary: "App activity.",
            scope: .app,
            outcome: .failure
        ))

        try await store.removeActivityAndResolvedConflicts(domainIdentifier: nil)

        #expect(try await store.recentActivity(domainIdentifier: nil, limit: 10).isEmpty)
        #expect(try await store.recentConflicts(domainIdentifier: nil, limit: 10).map(\.id) == [
            failedConflictID,
            blockedConflictID,
            unresolvedConflictID
        ])
    }

    @Test func providerEventStoreMigratesLegacyActivityRowsWithSuccessDefaults() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Snapshots.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try Connection(databaseURL.path)
        try database.execute("""
        CREATE TABLE provider_activity_events(
            id TEXT PRIMARY KEY NOT NULL,
            occurredAt REAL NOT NULL,
            domainIdentifier TEXT NOT NULL,
            driveID INTEGER NOT NULL,
            kind TEXT NOT NULL,
            itemIdentifier TEXT,
            itemName TEXT,
            itemPath TEXT,
            summary TEXT NOT NULL,
            relatedConflictID TEXT
        )
        """)
        try database.execute("""
        INSERT INTO provider_activity_events(
            id,
            occurredAt,
            domainIdentifier,
            driveID,
            kind,
            itemIdentifier,
            itemName,
            itemPath,
            summary,
            relatedConflictID
        ) VALUES (
            '00000000-0000-0000-0000-000000000001',
            100,
            'domain-1',
            10,
            'enumeration',
            '42',
            'Report.txt',
            '/Report.txt',
            'Legacy activity.',
            NULL
        )
        """)

        let store = try KDriveProviderEventSQLiteStore(databaseURL: databaseURL)
        let event = try #require(try await store.recentActivity(domainIdentifier: "domain-1", limit: 10).first)

        #expect(event.summary == "Legacy activity.")
        #expect(event.scope == .domain)
        #expect(event.outcome == .success)
        #expect(event.severity == .info)
        #expect(event.errorCategory == nil)
        #expect(event.correlationID == nil)
        #expect(event.durationMilliseconds == nil)
        #expect(event.networkOperation == nil)
        #expect(event.httpStatusCode == nil)
        #expect(event.remoteRequestID == nil)
    }

    @Test func providerEventStoreRetainsOnlyTheMostRecentActivityEvents() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try KDriveProviderEventSQLiteStore(
            databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"),
            maximumActivityEventCount: 2
        )
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 100),
            domainIdentifier: "domain-1",
            kind: .enumeration,
            summary: "Oldest activity."
        ))
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 200),
            domainIdentifier: "domain-1",
            kind: .changeSync,
            summary: "Middle activity."
        ))
        try await store.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 300),
            domainIdentifier: "domain-1",
            kind: .metadataLookup,
            summary: "Newest activity."
        ))

        let activity = try await store.recentActivity(domainIdentifier: "domain-1", limit: 10)
        #expect(activity.map(\.summary) == ["Newest activity.", "Middle activity."])
    }

    @Test func providerEventStoreExportsRedactedSupportLog() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try KDriveProviderEventSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        var activity = makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 100),
            domainIdentifier: "domain-1",
            kind: .fetchContents,
            summary: "Could not download Report.txt from https://example.test/private/Report.txt.",
            outcome: .failure,
            diagnostic: KDriveProviderActivityErrorDiagnostic(
                errorCategory: .network,
                diagnosticSummary: "Request for /Report.txt failed."
            )
        )
        activity.correlationID = "correlation-secret"
        activity.durationMilliseconds = 125
        activity.networkOperation = "downloadFile"
        activity.httpStatusCode = 503
        activity.remoteRequestID = "request-secret"
        try await store.recordActivity(activity)
        try await store.saveConflict(makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 200),
            domainIdentifier: "domain-1",
            itemName: "Report.txt",
            state: .blockedRetryable
        ))

        let data = try await store.supportLogData(domainIdentifier: nil)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("downloadFile"))
        #expect(text.contains("durationMilliseconds"))
        #expect(text.contains("Report.txt") == false)
        #expect(text.contains("/Report.txt") == false)
        #expect(text.contains("domain-1") == false)
        #expect(text.contains("correlation-secret") == false)
        #expect(text.contains("request-secret") == false)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let supportLog = try decoder.decode(KDriveProviderSupportLog.self, from: data)
        #expect(supportLog.schemaVersion == KDriveProviderSupportLog.schemaVersion)
        #expect(supportLog.activity.first?.durationMilliseconds == 125)
        #expect(supportLog.activity.first?.httpStatusCode == 503)
        #expect(supportLog.activity.first?.domain.hasPrefix("domain-") == true)
    }

    @Test func providerEventStoreObservesLocalAndExternalDatabaseChanges() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Snapshots.sqlite3")
        let observingStore = try KDriveProviderEventSQLiteStore(databaseURL: databaseURL)

        let localChanges = await observingStore.eventChanges(pollInterval: 0.05)
        async let observedLocalChange = eventChangeArrives(from: localChanges)

        try await observingStore.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 100),
            domainIdentifier: "domain-1",
            kind: .enumeration,
            summary: "Observed local activity."
        ))

        #expect(await observedLocalChange)

        let externalChanges = await observingStore.eventChanges(pollInterval: 0.05)
        async let observedExternalChange = eventChangeArrives(from: externalChanges)
        let writingStore = try KDriveProviderEventSQLiteStore(databaseURL: databaseURL)

        try await writingStore.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 200),
            domainIdentifier: "domain-1",
            kind: .changeSync,
            summary: "Observed external activity."
        ))

        #expect(await observedExternalChange)
    }

    @MainActor
    @Test func conflictLogModelLoadsConflictsAndOptionalActivityFromStore() async throws {
        let conflict = makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 100),
            domainIdentifier: "domain-1",
            itemName: "Report.txt",
            state: .blockedRetryable
        )
        let failureActivity = makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 200),
            domainIdentifier: "domain-1",
            kind: .metadataLookup,
            summary: "Could not resolve item metadata.",
            outcome: .failure,
            diagnostic: KDriveProviderActivityErrorDiagnostic(errorCategory: .fileProvider)
        )
        let successActivity = makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 300),
            domainIdentifier: "domain-1",
            kind: .enumeration,
            summary: "Enumerated folder."
        )
        let store = FakeProviderEventStore(conflicts: [conflict], activity: [successActivity, failureActivity])
        let model = ConflictLogViewModel(eventStore: store)

        await model.load()

        #expect(model.conflicts == [conflict])
        #expect(model.activity == [failureActivity])
        #expect(model.timelineItems.map(\.id) == [
            "activity-\(failureActivity.id.uuidString)",
            "conflict-\(conflict.id.uuidString)"
        ])
        #expect(await store.activityQueryCount() == 1)

        model.showsActivity = true
        await model.load()

        #expect(model.activity == [successActivity, failureActivity])
        #expect(model.timelineItems.map(\.id) == [
            "activity-\(successActivity.id.uuidString)",
            "activity-\(failureActivity.id.uuidString)",
            "conflict-\(conflict.id.uuidString)"
        ])
        #expect(await store.activityQueryCount() == 2)
    }

    @MainActor
    @Test func conflictLogModelClearsActivityAndResolvedConflicts() async throws {
        let resolvedConflict = makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 100),
            domainIdentifier: "domain-1",
            itemName: "Resolved.txt",
            state: .automaticallyResolved
        )
        let unresolvedConflict = makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 200),
            domainIdentifier: "domain-1",
            itemName: "Unresolved.txt",
            state: .unresolved
        )
        let failureActivity = makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 300),
            domainIdentifier: "domain-1",
            kind: .metadataLookup,
            summary: "Could not resolve item metadata.",
            outcome: .failure,
            diagnostic: KDriveProviderActivityErrorDiagnostic(errorCategory: .fileProvider)
        )
        let successActivity = makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 400),
            domainIdentifier: "domain-1",
            kind: .enumeration,
            summary: "Enumerated folder."
        )
        let store = FakeProviderEventStore(
            conflicts: [resolvedConflict, unresolvedConflict],
            activity: [failureActivity, successActivity]
        )
        let model = ConflictLogViewModel(eventStore: store)

        await model.clearActivity()

        #expect(model.conflicts == [unresolvedConflict])
        #expect(model.activity.isEmpty)
        #expect(model.timelineItems.map(\.id) == ["conflict-\(unresolvedConflict.id.uuidString)"])
        #expect(await store.storedConflicts().map(\.id) == [unresolvedConflict.id])
        #expect(await store.activities().isEmpty)
    }

    @MainActor
    @Test func statusModelAggregatesAccountsDrivesSnapshotsAndEvents() async throws {
        let account = ProviderAccount(
            accountIdentifier: "account-1",
            displayName: "Work",
            authenticationKind: .oauth,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let domain = ProviderDomainConfiguration(
            domainIdentifier: "domain-1",
            accountIdentifier: account.accountIdentifier,
            displayName: "Work Drive",
            driveID: 10,
            driveName: "Work Drive",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let loadedDrive = KDriveDriveSummary(
            id: 10,
            name: "Work Drive",
            accountID: 100,
            role: "admin",
            status: "active",
            isInMaintenance: false
        )
        let model = ProviderStatusViewModel(
            snapshotStatisticsProvider: FakeSnapshotStatisticsProvider(statistics: [
                KDriveSnapshotDomainStatistics(
                    domainIdentifier: domain.domainIdentifier,
                    containerCount: 2,
                    itemCount: 8,
                    fullyEnumeratedContainerCount: 1,
                    advancedListingContainerCount: 1,
                    lastUpdatedAt: Date(timeIntervalSince1970: 500)
                )
            ]),
            eventStatisticsProvider: FakeProviderEventStatisticsProvider(statistics: [
                KDriveProviderEventDomainStatistics(
                    domainIdentifier: domain.domainIdentifier,
                    unresolvedConflictCount: 1,
                    blockedConflictCount: 1,
                    recentFailureCount: 2,
                    recentSuccessCount: 3,
                    latestActivityAt: Date(timeIntervalSince1970: 700)
                ),
                KDriveProviderEventDomainStatistics(
                    domainIdentifier: ProviderConstants.appActivityDomainIdentifier,
                    recentFailureCount: 1,
                    latestActivityAt: Date(timeIntervalSince1970: 800)
                ),
            ])
        )

        await model.load(input: ProviderStatusInput(
            accounts: [account],
            domains: [domain],
            drivesByAccountIdentifier: [account.accountIdentifier: [loadedDrive]],
            loadingDriveAccountIdentifiers: []
        ))

        #expect(model.dashboard.summary.accountCount == 1)
        #expect(model.dashboard.summary.configuredDriveCount == 1)
        #expect(model.dashboard.summary.loadedDriveCount == 1)
        #expect(model.dashboard.summary.cachedSnapshotItemCount == 8)
        #expect(model.dashboard.summary.issueCount == 5)
        #expect(model.dashboard.summary.latestActivityAt == Date(timeIntervalSince1970: 800))
        #expect(model.dashboard.warnings.isEmpty)

        let accountRow = try #require(model.dashboard.accounts.first)
        #expect(accountRow.displayName == "Work")
        #expect(accountRow.configuredDriveCount == 1)
        #expect(accountRow.loadedDriveCount == 1)

        let driveRow = try #require(model.dashboard.drives.first)
        #expect(driveRow.displayName == "Work Drive")
        #expect(driveRow.accountName == "Work")
        #expect(driveRow.role == "admin")
        #expect(driveRow.snapshotContainerCount == 2)
        #expect(driveRow.cachedSnapshotItemCount == 8)
        #expect(driveRow.recentFailureCount == 2)
        #expect(driveRow.issueCount == 4)
        #expect(driveRow.health == .attention)
    }

    @Test func tabSelectionPolicyDefaultsToStatus() {
        #expect(ProviderAppTabSelectionPolicy.defaultSelection(configuredDomainCount: 0) == .status)
        #expect(ProviderAppTabSelectionPolicy.defaultSelection(configuredDomainCount: 1) == .status)
    }

    @Test func snapshotDecodesLegacyFileStoreShape() throws {
        struct LegacySnapshot: Encodable {
            let anchor: String
            let items: [KDriveRemoteItem]
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(LegacySnapshot(anchor: "legacy-anchor", items: [makeItem(id: 7, name: "Legacy.txt")]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(KDriveSnapshot.self, from: data)

        #expect(snapshot.anchor == "legacy-anchor")
        #expect(snapshot.serverCursor == nil)
        #expect(snapshot.isFullyEnumerated == false)
        #expect(snapshot.usesAdvancedListing == false)
        #expect(snapshot.items.first?.id == 7)
    }

    @Test func oauthAuthorizationRequestContainsPkceStateAndNoScopes() throws {
        let request = try KDriveOAuthClient.makeAuthorizationRequest(
            state: "known-state",
            codeVerifier: "known-verifier"
        )
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "login.infomaniak.com")
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == ProviderConstants.oauthClientID)
        #expect(ProviderConstants.oauthClientID == "9473D73C-C20F-4971-9E10-D957C563FA68")
        #expect(query["redirect_uri"] == ProviderConstants.oauthRedirectURI.absoluteString)
        #expect(query["scope"] == nil)
        #expect(query["state"] == "known-state")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == KDriveOAuthClient.codeChallenge(for: "known-verifier"))
        #expect(request.callbackScheme == "com.infomaniak.drive")
    }

    @Test func oauthRefreshRequestDoesNotSpecifyScopes() async throws {
        await OAuthRequestCapturingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthRequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        _ = try await KDriveOAuthClient.refresh(refreshToken: "refresh-token", session: session)

        let body = try #require(await OAuthRequestCapturingURLProtocol.lastBody())
        let form = try decodedFormBody(from: body)
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["client_id"] == ProviderConstants.oauthClientID)
        #expect(form["refresh_token"] == "refresh-token")
        #expect(form["scope"] == nil)
    }

    @Test func oauthCallbackValidatesStateAndAuthorizationCode() throws {
        let callback = URL(string: "com.infomaniak.drive://oauth2redirect?code=abc123&state=state-1")!

        #expect(try KDriveOAuthClient.authorizationCode(from: callback, expectedState: "state-1") == "abc123")
        #expect(throws: KDriveOAuthError.stateMismatch) {
            try KDriveOAuthClient.authorizationCode(from: callback, expectedState: "different-state")
        }
    }

    @Test func tokenRefreshLeewayIsComputed() {
        let token = KDriveOAuthToken(
            accessToken: "redacted",
            tokenType: "Bearer",
            refreshToken: "refresh",
            scope: "profile drive",
            idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(token.shouldRefresh(now: Date(timeIntervalSince1970: 800), leeway: 300))
        #expect(!token.shouldRefresh(now: Date(timeIntervalSince1970: 600), leeway: 300))
    }

    @Test func itemIdentifierParsesFileProviderAndKDriveValues() throws {
        #expect(try KDriveItemIdentifier(rawValue: "NSFileProviderRootContainerItemIdentifier") == .root)
        #expect(try KDriveItemIdentifier(rawValue: "NSFileProviderTrashContainerItemIdentifier") == .trash)
        #expect(try KDriveItemIdentifier(rawValue: "123") == .item(123))
        #expect(KDriveItemIdentifier.item(456).rawValue == "456")
        #expect(KDriveItemIdentifier.root.fileID == ProviderConstants.defaultRootFileID)
        #expect(KDriveItemIdentifier.root.fileID(rootFileID: 999) == 999)
        #expect(throws: KDriveItemIdentifierError.invalid("not-a-number")) {
            try KDriveItemIdentifier(rawValue: "not-a-number")
        }
    }

    @Test func remoteItemMapsContentTypes() {
        let folder = makeItem(id: 1, name: "Documents", type: "dir", mimeType: nil)
        let text = makeItem(id: 2, name: "Notes.txt", type: "file", mimeType: "text/plain")

        #expect(folder.isDirectory)
        #expect(folder.contentType == .folder)
        #expect(!text.isDirectory)
        #expect(text.contentType.conforms(to: .plainText))
    }

    @Test func snapshotDiffReportsUpdatesAndDeletes() {
        let oldSnapshot = KDriveSnapshot(anchor: "old", items: [
            makeItem(id: 1, name: "Keep.txt"),
            makeItem(id: 2, name: "Delete.txt")
        ])
        let newSnapshot = KDriveSnapshot(anchor: "new", items: [
            makeItem(id: 1, name: "Keep Renamed.txt"),
            makeItem(id: 3, name: "Create.txt")
        ])

        let changes = KDriveSnapshotDiffer.changes(from: oldSnapshot, to: newSnapshot)

        #expect(changes.updatedItems.map(\.id) == [1, 3])
        #expect(changes.deletedItemIDs == [2])
    }

    @Test func advancedActionReducerReportsUpdatesAndDeletes() throws {
        let updated = makeItem(id: 1, name: "Updated.txt")
        let created = makeItem(id: 3, name: "Created.txt")
        let changes = try KDriveAdvancedActionReducer.changes(
            from: [
                KDriveRemoteFileAction(action: "file_update", fileID: 1, parentID: 10),
                KDriveRemoteFileAction(action: "file_trash", fileID: 2, parentID: 10),
                KDriveRemoteFileAction(action: "file_create", fileID: 3, parentID: 10),
            ],
            actionItems: [updated, created]
        )

        #expect(changes.updatedItems.map(\.id) == [1, 3])
        #expect(changes.deletedItemIDs == [2])
    }

    @Test func listingValidatorRejectsAmbiguousPagination() throws {
        #expect(throws: KDriveListingValidationError.missingContinuationCursor) {
            _ = try KDriveListingValidator.validatedNextCursor(
                currentCursor: nil,
                nextCursor: nil,
                hasMore: true
            )
        }

        var seenCursors = Set<String>()
        #expect(try KDriveListingValidator.validatedNextCursor(
            currentCursor: nil,
            nextCursor: "cursor-1",
            hasMore: true,
            seenCursors: &seenCursors
        ) == "cursor-1")

        #expect(throws: KDriveListingValidationError.repeatedContinuationCursor("cursor-1")) {
            _ = try KDriveListingValidator.validatedNextCursor(
                currentCursor: "cursor-1",
                nextCursor: "cursor-1",
                hasMore: true,
                seenCursors: &seenCursors
            )
        }
    }

    @Test func advancedActionValidatorFailsClosedForUnsafeActions() throws {
        #expect(throws: KDriveListingValidationError.unknownAdvancedAction("file_mystery")) {
            try KDriveListingValidator.validateAdvancedActions(
                [KDriveRemoteFileAction(action: "file_mystery", fileID: 1, parentID: 10)],
                actionItems: []
            )
        }

        #expect(throws: KDriveListingValidationError.missingActionItem(action: "file_update", fileID: 1)) {
            try KDriveListingValidator.validateAdvancedActions(
                [KDriveRemoteFileAction(action: "file_update", fileID: 1, parentID: 10)],
                actionItems: []
            )
        }

        let changes = try KDriveAdvancedActionReducer.changes(
            from: [KDriveRemoteFileAction(action: "file_delete", fileID: 2, parentID: 10)],
            actionItems: []
        )
        #expect(changes.updatedItems.isEmpty)
        #expect(changes.deletedItemIDs == [2])
    }

    @Test func advancedActionReducerUsesNewestActionAndDeletesWithoutActionFile() throws {
        let oldSnapshot = KDriveSnapshot(
            anchor: "old-cursor",
            serverCursor: "old-cursor",
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: [
                makeItem(id: 1, name: "Old.txt"),
                makeItem(id: 2, name: "Deleted.txt"),
            ]
        )
        let newItem = makeItem(id: 1, name: "Newest.txt")

        let result = try KDriveAdvancedActionReducer.applying(
            actions: [
                KDriveRemoteFileAction(action: "file_delete", fileID: 1, parentID: 10),
                KDriveRemoteFileAction(action: "file_delete", fileID: 2, parentID: 10),
                KDriveRemoteFileAction(action: "file_rename", fileID: 1, parentID: 10),
            ],
            actionItems: [newItem],
            to: oldSnapshot,
            anchor: "new-cursor",
            serverCursor: "new-cursor"
        )

        #expect(result.changes.updatedItems.isEmpty)
        #expect(result.changes.deletedItemIDs == [1, 2])
        #expect(result.snapshot.items.isEmpty)
        #expect(result.snapshot.serverCursor == "new-cursor")
    }

    @Test func versionConflictResolverComparesRelevantVersions() {
        let item = makeItem(id: 1, name: "Versioned.txt")

        #expect(KDriveVersionConflictResolver.contentMatches(baseVersion: item.contentVersion, remoteItem: item))
        #expect(KDriveVersionConflictResolver.metadataMatches(baseVersion: item.metadataVersion, remoteItem: item))
        #expect(KDriveVersionConflictResolver.itemVersionMatches(
            contentVersion: item.contentVersion,
            metadataVersion: item.metadataVersion,
            remoteItem: item
        ))
        #expect(!KDriveVersionConflictResolver.contentMatches(baseVersion: Data("stale".utf8), remoteItem: item))
        #expect(!KDriveVersionConflictResolver.metadataMatches(baseVersion: Data("stale".utf8), remoteItem: item))
    }

    @Test func metadataVersionParsesHyphenatedNames() throws {
        let updatedAt = Date(timeIntervalSince1970: 300)
        let metadataVersion = KDriveItemMetadataVersion(
            itemID: 42,
            updatedAt: updatedAt,
            name: "01 - A-B - C.txt",
            parentID: 77
        )

        let parsedVersion = try #require(KDriveItemMetadataVersion(data: metadataVersion.data))

        #expect(parsedVersion == metadataVersion)
        #expect(KDriveItemMetadataVersion(data: Data("stale".utf8)) == nil)
    }

    @Test func versionConflictResolverAllowsMetadataTimestampOnlyDrift() {
        let baseItem = makeItem(id: 1, name: "Versioned.txt")
        let driftedItem = makeItem(
            id: 1,
            name: "Versioned.txt",
            modifiedAt: baseItem.modifiedAt,
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let renamedItem = makeItem(
            id: 1,
            name: "Remote.txt",
            modifiedAt: baseItem.modifiedAt,
            updatedAt: Date(timeIntervalSince1970: 350)
        )

        #expect(KDriveVersionConflictResolver.metadataMatchesBaseStateIgnoringTimestamp(
            baseVersion: baseItem.metadataVersion,
            remoteItem: driftedItem
        ))
        #expect(KDriveVersionConflictResolver.itemVersionMatchesAllowingMetadataTimestampDrift(
            contentVersion: baseItem.contentVersion,
            metadataVersion: baseItem.metadataVersion,
            remoteItem: driftedItem
        ))
        #expect(!KDriveVersionConflictResolver.itemVersionMatchesAllowingMetadataTimestampDrift(
            contentVersion: baseItem.contentVersion,
            metadataVersion: baseItem.metadataVersion,
            remoteItem: renamedItem
        ))
    }

    @Test func conflictFilenamePreservesExtensionAndIsDeterministic() {
        let conflictName = KDriveConflictFilename.filename(
            for: "Report.pdf",
            deviceName: "Mac/One:Two",
            date: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(conflictName == "Report (conflict - Mac-One.Two - 1970-01-01 00.00.00).pdf")
        #expect(conflictName.hasSuffix(").pdf"))
        #expect(KDriveUploadConflictStrategy.version.rawValue == "version")
        #expect(KDriveUploadConflictStrategy.rename.rawValue == "rename")
    }

    @Test func kdriveRemoteAPIRejectionClassifierMapsHTTPStatusWithoutPersistingBody() throws {
        let quotaError = APIClientError.unacceptableStatusCode(
            507,
            body: #"{"error":"quota exceeded","token":"secret-token"}"#
        )
        let quotaRejection = try #require(KDriveRemoteErrorClassifier.apiRejection(from: quotaError))

        #expect(quotaRejection.statusCode == 507)
        #expect(quotaRejection.recovery == .insufficientQuota)
        #expect(quotaRejection.diagnosticSummary == "The remote API rejected the operation. HTTP 507.")
        #expect(quotaRejection.diagnosticSummary.contains("secret-token") == false)
        #expect(quotaRejection.responseBodyPreview(maxLength: 8) == #"{"error"..."#)

        let authRejection = try #require(KDriveRemoteErrorClassifier.apiRejection(
            from: APIClientError.unacceptableStatusCode(401, body: "Unauthorized")
        ))
        let serverRejection = try #require(KDriveRemoteErrorClassifier.apiRejection(
            from: APIClientError.unacceptableStatusCode(503, body: "Unavailable")
        ))
        let validationRejection = try #require(KDriveRemoteErrorClassifier.apiRejection(
            from: APIClientError.unacceptableStatusCode(422, body: "Invalid upload parameters")
        ))

        #expect(authRejection.recovery == .notAuthenticated)
        #expect(serverRejection.recovery == .serverUnreachable)
        #expect(validationRejection.recovery == .cannotSynchronize)
        #expect(KDriveRemoteErrorClassifier.apiRejection(from: NSError(domain: NSURLErrorDomain, code: -1009)) == nil)
    }

    @Test func kdriveServiceReplacesFileByNameWithVersionConflictStrategy() async throws {
        await KDriveJSONRequestCapturingURLProtocol.reset(responseData: Self.fileUploadResponseData)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KDriveJSONRequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = PotassiumKDriveService(
            bearerToken: "redacted-token",
            apiBaseURL: URL(string: "https://api.example.test")!,
            session: session
        )
        let contents = Data([0xFF, 0xD8, 0xFF, 0xE0])

        let item = try await service.replaceFile(
            driveID: 100,
            parentID: 7,
            fileName: "Edited.jpg",
            contents: contents,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let request = try #require(await KDriveJSONRequestCapturingURLProtocol.lastRequest())
        let body = try #require(await KDriveJSONRequestCapturingURLProtocol.lastBody())
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(item.id == 42)
        #expect(body == contents)
        #expect(request.httpMethod == "POST")
        #expect(components.path == "/3/drive/100/upload")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer redacted-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(query["total_size"] == "4")
        #expect(query["directory_id"] == "7")
        #expect(query["file_name"] == "Edited.jpg")
        #expect(query["last_modified_at"] == "1700000001")
        #expect(query["conflict"] == "version")
        #expect(query["file_id"] == nil)
    }

    @Test func kdriveServiceCreatesFileWithVersionConflictStrategy() async throws {
        await KDriveJSONRequestCapturingURLProtocol.reset(responseData: Self.fileUploadResponseData)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KDriveJSONRequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = PotassiumKDriveService(
            bearerToken: "redacted-token",
            apiBaseURL: URL(string: "https://api.example.test")!,
            session: session
        )
        let contents = Data("new picture bytes".utf8)

        let operation = try service.uploadFileOperation(
            driveID: 100,
            parentID: 7,
            fileName: "Edited.jpg",
            contents: contents,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_002),
            conflictStrategy: .version
        )
        #expect(operation.progress.totalUnitCount >= -1)
        #expect(await KDriveJSONRequestCapturingURLProtocol.lastRequest() == nil)

        let item = try await operation.value
        let request = try #require(await KDriveJSONRequestCapturingURLProtocol.lastRequest())
        let body = try #require(await KDriveJSONRequestCapturingURLProtocol.lastBody())
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(item.id == 42)
        #expect(body == contents)
        #expect(request.httpMethod == "POST")
        #expect(components.path == "/3/drive/100/upload")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(query["total_size"] == "\(contents.count)")
        #expect(query["directory_id"] == "7")
        #expect(query["file_name"] == "Edited.jpg")
        #expect(query["last_modified_at"] == "1700000002")
        #expect(query["conflict"] == "version")
        #expect(query["file_id"] == nil)
    }

    @Test func kdriveServiceExposesLazyObservableDownloadOperation() async throws {
        await KDriveDataRequestCapturingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KDriveDataRequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = PotassiumKDriveService(
            bearerToken: "redacted-token",
            apiBaseURL: URL(string: "https://api.example.test")!,
            session: session
        )

        let operation = try service.downloadFileOperation(driveID: 100, fileID: 42)
        #expect(operation.progress.totalUnitCount >= -1)
        #expect(await KDriveDataRequestCapturingURLProtocol.lastRequest() == nil)

        let data = try await operation.value
        let request = try #require(await KDriveDataRequestCapturingURLProtocol.lastRequest())

        #expect(data == KDriveDataRequestCapturingURLProtocol.responseData)
        #expect(request.url?.path == "/2/drive/100/files/42/download")
    }

    @Test func kdriveServiceFetchesThumbnailThroughPotassiumRoute() async throws {
        await KDriveDataRequestCapturingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KDriveDataRequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = PotassiumKDriveService(
            bearerToken: "redacted-token",
            apiBaseURL: URL(string: "https://api.example.test")!,
            session: session
        )

        let data = try await service.thumbnail(driveID: 100, fileID: 42, width: 128, height: 256)
        let request = try #require(await KDriveDataRequestCapturingURLProtocol.lastRequest())
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(data == KDriveDataRequestCapturingURLProtocol.responseData)
        #expect(request.httpMethod == "GET")
        #expect(components.path == "/2/drive/100/files/42/thumbnail")
        #expect(query["width"] == "128")
        #expect(query["height"] == "256")
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/*")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer redacted-token")
    }

    @Test func kdriveServiceFetchesInitialAdvancedListingThroughPotassiumRoute() async throws {
        await KDriveJSONRequestCapturingURLProtocol.reset(responseData: Self.advancedListingResponseData)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KDriveJSONRequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = PotassiumKDriveService(
            bearerToken: "redacted-token",
            apiBaseURL: URL(string: "https://api.example.test")!,
            session: session
        )

        let page = try await service.listAdvancedDirectory(driveID: 100, folderID: 42, cursor: nil, limit: 50)
        let request = try #require(await KDriveJSONRequestCapturingURLProtocol.lastRequest())
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        #expect(request.httpMethod == "GET")
        #expect(components.path == "/3/drive/100/files/42/listing")
        #expect(queryItems.contains(URLQueryItem(name: "limit", value: "50")))
        #expect(queryItems.contains(URLQueryItem(name: "order_by", value: "type")))
        #expect(queryItems.contains(URLQueryItem(name: "order_by", value: "name")))
        #expect(queryItems.contains(URLQueryItem(name: "order_for[name]", value: "asc")))
        #expect(queryItems.contains(URLQueryItem(name: "order_for[type]", value: "asc")))
        #expect(page.items.first?.id == 43)
        #expect(page.actions.first?.action == "file_update")
        #expect(page.actionItems.first?.id == 44)
        #expect(page.nextCursor == "next-cursor")
        #expect(page.hasMore == true)
    }

    @Test func kdriveServiceContinuesAdvancedListingThroughPotassiumRoute() async throws {
        await KDriveJSONRequestCapturingURLProtocol.reset(responseData: Self.advancedListingResponseData)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KDriveJSONRequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = PotassiumKDriveService(
            bearerToken: "redacted-token",
            apiBaseURL: URL(string: "https://api.example.test")!,
            session: session
        )

        _ = try await service.listAdvancedDirectory(driveID: 100, folderID: 42, cursor: "old-cursor", limit: 50)
        let request = try #require(await KDriveJSONRequestCapturingURLProtocol.lastRequest())
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        #expect(request.httpMethod == "GET")
        #expect(components.path == "/3/drive/100/files/42/listing/continue")
        #expect(queryItems.contains(URLQueryItem(name: "cursor", value: "old-cursor")))
    }

    @MainActor
    @Test func appModelStoresManualTokenAndLoadsDrives() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountStore = ProviderAccountFileStore(directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true))
        let domainStore = DomainConfigurationFileStore(directoryURL: directory.appendingPathComponent("Domains", isDirectory: true))
        let tokenStore = InMemoryOAuthTokenStore()
        let drive = KDriveDriveSummary(
            id: 42,
            name: "Work Drive",
            accountID: 100,
            role: "admin",
            status: "ok",
            isInMaintenance: false
        )
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: domainStore,
            tokenStore: tokenStore,
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: NoopProviderDomainRegistrar(),
            automaticallyReloadStoredState: false,
            fileProviderFactory: { token in
                #expect(token == "manual-token")
                return FakeKDriveFileProvider(drives: [drive])
            }
        )

        model.manualAccessToken = " manual-token "

        await model.saveManualAccessToken()

        #expect(model.isConnected)
        #expect(model.manualAccessToken.isEmpty)
        let account = try #require(model.accounts.first)
        #expect(account.authenticationKind == .manualAccessToken)
        #expect(model.drives(for: account.accountIdentifier) == [drive])
        #expect(model.selectedDriveID(for: account.accountIdentifier) == drive.id)
        let savedToken = await tokenStore.loadToken(accountIdentifier: account.accountIdentifier)
        #expect(savedToken?.accessToken == "manual-token")
        #expect(savedToken?.scope == nil)
    }

    @MainActor
    @Test func appModelAutomaticallyLoadsSavedAccountDrivesWhenPossible() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountStore = ProviderAccountFileStore(directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true))
        let domainStore = DomainConfigurationFileStore(directoryURL: directory.appendingPathComponent("Domains", isDirectory: true))
        let tokenStore = InMemoryOAuthTokenStore()
        let accountWithToken = ProviderAccount(
            accountIdentifier: "account-with-token",
            displayName: "Connected Account",
            authenticationKind: .manualAccessToken
        )
        let accountWithoutToken = ProviderAccount(
            accountIdentifier: "account-without-token",
            displayName: "Disconnected Account",
            authenticationKind: .manualAccessToken
        )
        try await accountStore.save(accountWithToken)
        try await accountStore.save(accountWithoutToken)
        await tokenStore.saveToken(token(accessToken: "saved-token"), accountIdentifier: accountWithToken.accountIdentifier)

        let drive = KDriveDriveSummary(
            id: 42,
            name: "Work Drive",
            accountID: 100,
            role: "admin",
            status: "ok",
            isInMaintenance: false
        )
        var requestedTokens: [String] = []
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: domainStore,
            tokenStore: tokenStore,
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: NoopProviderDomainRegistrar(),
            automaticallyReloadStoredState: false,
            fileProviderFactory: { token in
                requestedTokens.append(token)
                return FakeKDriveFileProvider(drives: [drive])
            }
        )

        await model.reloadStoredState()
        await model.loadDrivesForAccountsIfPossible()
        await model.loadDrivesForAccountsIfPossible()

        #expect(requestedTokens == ["saved-token"])
        #expect(model.drives(for: accountWithToken.accountIdentifier) == [drive])
        #expect(model.drives(for: accountWithoutToken.accountIdentifier).isEmpty)
        #expect(model.errorMessage == nil)
    }

    @MainActor
    @Test func appModelUsesOAuthIDTokenNameForAccountDisplayName() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountStore = ProviderAccountFileStore(directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true))
        let domainStore = DomainConfigurationFileStore(directoryURL: directory.appendingPathComponent("Domains", isDirectory: true))
        let tokenStore = InMemoryOAuthTokenStore()
        let drive = KDriveDriveSummary(
            id: 42,
            name: "Work Drive",
            accountID: 100,
            role: "admin",
            status: "ok",
            isInMaintenance: false
        )
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: domainStore,
            tokenStore: tokenStore,
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(token: KDriveOAuthToken(
                accessToken: "oauth-token",
                tokenType: "Bearer",
                refreshToken: nil,
                scope: nil,
                idToken: unsignedIDToken(payload: #"{"name":"Alice Example","email":"alice@example.test"}"#),
                expiresAt: nil
            )),
            domainRegistrar: NoopProviderDomainRegistrar(),
            automaticallyReloadStoredState: false,
            fileProviderFactory: { _ in FakeKDriveFileProvider(drives: [drive]) }
        )

        await model.connectWithOAuth()

        let account = try #require(model.accounts.first)
        #expect(account.displayName == "Alice Example")
        #expect(account.authenticationKind == .oauth)
        #expect(model.drives(for: account.accountIdentifier) == [drive])
    }

    @MainActor
    @Test func appModelKeepsMultipleAccountsAndLogsOutIndependently() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountStore = ProviderAccountFileStore(directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true))
        let domainStore = DomainConfigurationFileStore(directoryURL: directory.appendingPathComponent("Domains", isDirectory: true))
        let tokenStore = InMemoryOAuthTokenStore()
        let driveA = KDriveDriveSummary(
            id: 42,
            name: "Work Drive",
            accountID: 100,
            role: "admin",
            status: "ok",
            isInMaintenance: false
        )
        let driveB = KDriveDriveSummary(
            id: 84,
            name: "Work Drive",
            accountID: 200,
            role: "admin",
            status: "ok",
            isInMaintenance: false
        )
        let databaseURL = directory.appendingPathComponent("Snapshots.sqlite3")
        let snapshotStore = try KDriveSnapshotSQLiteStore(databaseURL: databaseURL)
        let eventStore = try KDriveProviderEventSQLiteStore(databaseURL: databaseURL)
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: domainStore,
            tokenStore: tokenStore,
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: NoopProviderDomainRegistrar(),
            snapshotStore: snapshotStore,
            eventStore: eventStore,
            automaticallyReloadStoredState: false,
            fileProviderFactory: { token in
                FakeKDriveFileProvider(drives: token == "token-a" ? [driveA] : [driveB])
            }
        )

        model.manualAccessToken = "token-a"
        await model.saveManualAccessToken()
        let accountA = try #require(model.accounts.first)

        model.manualAccessToken = "token-b"
        await model.saveManualAccessToken()
        let accountB = try #require(model.accounts.first { $0.accountIdentifier != accountA.accountIdentifier })

        await model.addDomain(accountIdentifier: accountA.accountIdentifier, drive: driveA)
        await model.addDomain(accountIdentifier: accountB.accountIdentifier, drive: driveB)

        let configuredDomains = try await domainStore.allConfigurations()
        #expect(configuredDomains.count == 2)
        #expect(Set(configuredDomains.map(\.accountIdentifier)) == [
            accountA.accountIdentifier,
            accountB.accountIdentifier,
        ])
        #expect(Set(configuredDomains.map(\.displayName)) == [
            "Work Drive (\(accountA.displayName))",
            "Work Drive (\(accountB.displayName))",
        ])

        await model.logoutAccount(accountA)

        #expect(model.accounts.map(\.accountIdentifier) == [accountB.accountIdentifier])
        #expect(model.domains.map(\.accountIdentifier) == [accountB.accountIdentifier])
        #expect(await tokenStore.loadToken(accountIdentifier: accountA.accountIdentifier) == nil)
        #expect(await tokenStore.loadToken(accountIdentifier: accountB.accountIdentifier)?.accessToken == "token-b")
        #expect(try await domainStore.allConfigurations().map(\.accountIdentifier) == [accountB.accountIdentifier])
    }

    @MainActor
    @Test func appModelAddsAndRemovesDomainConfigurations() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountStore = ProviderAccountFileStore(directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true))
        let domainStore = DomainConfigurationFileStore(directoryURL: directory.appendingPathComponent("Domains", isDirectory: true))
        let tokenStore = InMemoryOAuthTokenStore()
        let databaseURL = directory.appendingPathComponent("Snapshots.sqlite3")
        let snapshotStore = try KDriveSnapshotSQLiteStore(databaseURL: databaseURL)
        let eventStore = try KDriveProviderEventSQLiteStore(databaseURL: databaseURL)
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: domainStore,
            tokenStore: tokenStore,
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: NoopProviderDomainRegistrar(),
            snapshotStore: snapshotStore,
            eventStore: eventStore,
            automaticallyReloadStoredState: false,
            fileProviderFactory: { _ in FakeKDriveFileProvider(drives: []) }
        )

        model.manualAccessToken = "token"
        await model.saveManualAccessToken()
        let account = try #require(model.accounts.first)
        model.setManualDriveID(" 42 ", for: account.accountIdentifier)
        model.setManualDriveName("Work Drive", for: account.accountIdentifier)

        await model.addDomain(accountIdentifier: account.accountIdentifier)

        let domain = try #require(model.domains.first)
        #expect(domain.accountIdentifier == account.accountIdentifier)
        #expect(domain.displayName == "Work Drive")
        #expect(domain.driveID == 42)
        #expect(domain.driveName == "Work Drive")
        #expect(try await domainStore.allConfigurations().count == 1)
        try await snapshotStore.save(
            KDriveSnapshot(anchor: "anchor", items: [makeItem(id: 7, name: "Cached.txt")]),
            domainIdentifier: domain.domainIdentifier,
            containerIdentifier: "root"
        )
        try await eventStore.saveConflict(makeConflictEvent(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 500),
            domainIdentifier: domain.domainIdentifier,
            itemName: "Cached.txt",
            state: .blockedRetryable
        ))
        try await eventStore.recordActivity(makeActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 600),
            domainIdentifier: domain.domainIdentifier,
            kind: .changeSync,
            summary: "Synced cached item."
        ))

        await model.removeDomain(domain)

        #expect(model.domains.isEmpty)
        #expect(try await domainStore.allConfigurations().isEmpty)
        #expect(try await snapshotStore.snapshot(domainIdentifier: domain.domainIdentifier, containerIdentifier: "root") == nil)
        #expect(try await eventStore.recentConflicts(domainIdentifier: domain.domainIdentifier, limit: 10).isEmpty)
        #expect(try await eventStore.recentActivity(domainIdentifier: domain.domainIdentifier, limit: 10).isEmpty)
    }

    @MainActor
    @Test func appModelNormalizesLegacyDomainDisplayNameDuringReload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let domainStore = DomainConfigurationFileStore(directoryURL: directory)
        let legacyUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let legacyConfiguration = ProviderDomainConfiguration(
            domainIdentifier: "legacy-domain",
            displayName: "PotassiumProvider",
            driveID: 42,
            driveName: "Work Drive",
            createdAt: Date(timeIntervalSince1970: 900),
            updatedAt: legacyUpdatedAt
        )
        try await domainStore.save(legacyConfiguration)

        let registrar = RecordingProviderDomainRegistrar()
        let model = PotassiumProviderAppModel(
            accountStore: ProviderAccountFileStore(directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true)),
            domainStore: domainStore,
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: registrar,
            automaticallyReloadStoredState: false,
            fileProviderFactory: { _ in FakeKDriveFileProvider(drives: []) }
        )

        await model.reloadStoredState()

        let domain = try #require(model.domains.first)
        let account = try #require(model.accounts.first)
        #expect(account.accountIdentifier == ProviderConstants.legacyAccountIdentifier)
        #expect(account.displayName == "Legacy Account")
        #expect(domain.displayName == "Work Drive")
        #expect(domain.accountIdentifier == ProviderConstants.legacyAccountIdentifier)
        #expect(domain.driveName == "Work Drive")
        #expect(domain.updatedAt > legacyUpdatedAt)

        let storedDomain = try #require(await domainStore.configuration(domainIdentifier: "legacy-domain"))
        #expect(storedDomain.displayName == "Work Drive")
        #expect(storedDomain.accountIdentifier == ProviderConstants.legacyAccountIdentifier)

        let registeredDomain = try #require(registrar.addedConfigurations.first)
        #expect(registeredDomain.domainIdentifier == "legacy-domain")
        #expect(registeredDomain.displayName == "Work Drive")
    }

    @MainActor
    @Test func appModelRollsBackDomainConfigurationWhenRegistrationFails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountStore = ProviderAccountFileStore(directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true))
        let domainStore = DomainConfigurationFileStore(directoryURL: directory.appendingPathComponent("Domains", isDirectory: true))
        let snapshotStore = try KDriveSnapshotSQLiteStore(databaseURL: directory.appendingPathComponent("Snapshots.sqlite3"))
        let eventStore = FakeProviderEventStore(conflicts: [], activity: [])
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: domainStore,
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: FailingProviderDomainRegistrar(),
            snapshotStore: snapshotStore,
            eventStore: eventStore,
            automaticallyReloadStoredState: false,
            fileProviderFactory: { _ in FakeKDriveFileProvider(drives: []) }
        )

        model.manualAccessToken = "token"
        await model.saveManualAccessToken()
        let account = try #require(model.accounts.first)
        model.setManualDriveID("42", for: account.accountIdentifier)
        model.setManualDriveName("Work Drive", for: account.accountIdentifier)

        await model.addDomain(accountIdentifier: account.accountIdentifier)

        #expect(model.domains.isEmpty)
        #expect(try await domainStore.allConfigurations().isEmpty)
        #expect(model.errorMessage?.contains("The application cannot be used right now") == true)

        let failure = try #require(await eventStore.activities().first)
        #expect(failure.domainIdentifier == ProviderConstants.appActivityDomainIdentifier)
        #expect(failure.scope == .app)
        #expect(failure.kind == .domainManagement)
        #expect(failure.outcome == .failure)
        #expect(failure.summary == "Could not add the provider domain.")
    }

    @MainActor
    @Test func appModelRecordsSanitizedFailureActivity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountStore = ProviderAccountFileStore(directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true))
        let account = ProviderAccount(
            accountIdentifier: "account-1",
            displayName: "Stored Account",
            authenticationKind: .manualAccessToken
        )
        try await accountStore.save(account)
        let tokenStore = InMemoryOAuthTokenStore()
        await tokenStore.saveToken(KDriveOAuthToken(
            accessToken: "secret-token",
            tokenType: "Bearer",
            refreshToken: nil,
            scope: nil,
            idToken: nil,
            expiresAt: nil
        ), accountIdentifier: account.accountIdentifier)
        let eventStore = FakeProviderEventStore(conflicts: [], activity: [])
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: DomainConfigurationFileStore(directoryURL: directory.appendingPathComponent("Domains", isDirectory: true)),
            tokenStore: tokenStore,
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: NoopProviderDomainRegistrar(),
            eventStore: eventStore,
            automaticallyReloadStoredState: false,
            fileProviderFactory: { _ in
                FakeKDriveFileProvider(
                    drives: [],
                    listDrivesError: SensitiveFailureError(message: "request failed with bearer secret-token")
                )
            }
        )

        await model.reloadStoredState()
        await model.loadDrives(accountIdentifier: account.accountIdentifier)

        let failure = try #require(await eventStore.activities().first)
        #expect(failure.scope == .app)
        #expect(failure.outcome == .failure)
        #expect(failure.severity == .error)
        #expect(failure.kind == .driveDiscovery)
        #expect(failure.errorCategory == .api)
        #expect(failure.summary == "Could not load kDrives.")
        #expect(failure.summary.contains("secret-token") == false)
        #expect(failure.diagnosticSummary?.contains("secret-token") == false)
    }

    private func makeItem(
        id: Int,
        name: String,
        parentID: Int = ProviderConstants.defaultRootFileID,
        modifiedAt: Date = Date(timeIntervalSince1970: 200),
        updatedAt: Date = Date(timeIntervalSince1970: 300),
        type: String? = "file",
        mimeType: String? = "text/plain"
    ) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name,
            type: type,
            status: "ok",
            driveID: 10,
            parentID: parentID,
            path: "/\(name)",
            size: type == "dir" ? nil : 12,
            mimeType: mimeType,
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: modifiedAt,
            updatedAt: updatedAt
        )
    }

    private func token(accessToken: String) -> KDriveOAuthToken {
        KDriveOAuthToken(
            accessToken: accessToken,
            tokenType: "Bearer",
            refreshToken: nil,
            scope: nil,
            idToken: nil,
            expiresAt: nil
        )
    }

    private func unsignedIDToken(payload: String) -> String {
        let header = #"{"alg":"none"}"#
        return [
            base64URLEncodedString(header),
            base64URLEncodedString(payload),
            "",
        ].joined(separator: ".")
    }

    private func base64URLEncodedString(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeConflictEvent(
        id: UUID,
        detectedAt: Date,
        domainIdentifier: String,
        itemName: String,
        state: KDriveConflictResolutionState
    ) -> KDriveConflictEvent {
        KDriveConflictEvent(
            id: id,
            detectedAt: detectedAt,
            domainIdentifier: domainIdentifier,
            driveID: 10,
            operation: .modify,
            originalItemIdentifier: "42",
            originalItemName: itemName,
            originalItemPath: "/\(itemName)",
            resolutionState: state,
            automaticallyResolved: state == .automaticallyResolved,
            resolutionKind: state == .blockedRetryable ? .blockedBeforeServerMutation : nil,
            resolutionSummary: "Conflict for \(itemName)."
        )
    }

    private func makeActivityEvent(
        occurredAt: Date,
        domainIdentifier: String,
        kind: KDriveProviderActivityKind,
        summary: String,
        relatedConflictID: UUID? = nil,
        scope: KDriveProviderActivityScope = .domain,
        outcome: KDriveProviderActivityOutcome = .success,
        severity: KDriveProviderActivitySeverity = .info,
        diagnostic: KDriveProviderActivityErrorDiagnostic? = nil
    ) -> KDriveProviderActivityEvent {
        KDriveProviderActivityEvent(
            occurredAt: occurredAt,
            domainIdentifier: domainIdentifier,
            driveID: 10,
            kind: kind,
            scope: scope,
            outcome: outcome,
            severity: severity,
            itemIdentifier: "42",
            itemName: "Report.txt",
            itemPath: "/Report.txt",
            summary: summary,
            relatedConflictID: relatedConflictID,
            diagnostic: diagnostic
        )
    }

    private static let advancedListingResponseData = """
    {
      "result": "success",
      "data": {
        "actions": [
          {
            "action": "file_update",
            "file_id": 44,
            "parent_id": 42
          }
        ],
        "files": [
          {
            "id": 43,
            "name": "Nested.pdf",
            "path": "/Documents/Nested.pdf",
            "type": "file",
            "status": "active",
            "visibility": "is_private_space",
            "drive_id": 100,
            "parent_id": 42,
            "depth": 3,
            "created_at": 1710000000,
            "last_modified_at": 1710000100,
            "updated_at": 1710000200,
            "size": 1024,
            "mime_type": "application/pdf",
            "is_favorite": false
          }
        ],
        "actions_files": [
          {
            "id": 44,
            "name": "Changed.txt",
            "path": "/Documents/Changed.txt",
            "type": "file",
            "status": "active",
            "visibility": "is_private_space",
            "drive_id": 100,
            "parent_id": 42,
            "depth": 3,
            "created_at": 1710000000,
            "last_modified_at": 1710000100,
            "updated_at": 1710000200,
            "size": 128,
            "mime_type": "text/plain",
            "is_favorite": true
          }
        ]
      },
      "cursor": "next-cursor",
      "has_more": true,
      "response_at": 1710000300
    }
    """.data(using: .utf8)!

    private static let fileUploadResponseData = """
    {
      "result": "success",
      "data": {
        "id": 42,
        "name": "Edited.jpg",
        "path": "/Pictures/Edited.jpg",
        "type": "file",
        "status": "active",
        "visibility": "is_private_space",
        "drive_id": 100,
        "parent_id": 7,
        "depth": 3,
        "created_at": 1700000000,
        "last_modified_at": 1700000001,
        "updated_at": 1700000002,
        "size": 4,
        "mime_type": "image/jpeg",
        "is_favorite": false
      },
      "response_at": 1700000003
    }
    """.data(using: .utf8)!

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("potassium-provider-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func eventChangeArrives(
        from stream: AsyncStream<Void>,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func decodedFormBody(from body: Data) throws -> [String: String] {
        let encodedBody = String(decoding: body, as: UTF8.self)
        let components = try #require(URLComponents(string: "?\(encodedBody)"))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

private enum AsyncOperationLimiterTestError: Error {
    case expected
    case timedOut
}

private func withTimeout<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw AsyncOperationLimiterTestError.timedOut
        }

        guard let result = try await group.next() else {
            throw AsyncOperationLimiterTestError.timedOut
        }
        group.cancelAll()
        return result
    }
}

private actor LimiterActivityProbe {
    private var activeOperations = 0
    private var maximumActiveOperations = 0
    private var startedOperations = 0
    private var finishedOperations = 0

    func startOperation() {
        activeOperations += 1
        startedOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
    }

    func finishOperation() {
        activeOperations -= 1
        finishedOperations += 1
    }

    func maximumActiveOperationCount() -> Int {
        maximumActiveOperations
    }

    func startedOperationCount() -> Int {
        startedOperations
    }

    func finishedOperationCount() -> Int {
        finishedOperations
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        guard isOpen == false else { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class OAuthRequestCapturingURLProtocol: URLProtocol {
    private static let capture = CapturedURLRequestStore()

    static func reset() async {
        await capture.reset()
    }

    static func lastRequest() async -> URLRequest? {
        await capture.lastRequest()
    }

    static func lastBody() async -> Data? {
        await capture.lastBody()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        let body = request.httpBody ?? Self.readBodyStream(from: request)
        Task { await Self.capture.record(request: request, body: body) }

        let data = """
        {
          "access_token": "refreshed-token",
          "token_type": "Bearer",
          "expires_in": 3600,
          "refresh_token": "new-refresh-token"
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            guard bytesRead > 0 else {
                break
            }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}

private final class KDriveDataRequestCapturingURLProtocol: URLProtocol {
    static let responseData = Data([0x89, 0x50, 0x4E, 0x47])
    private static let capture = CapturedURLRequestStore()

    static func reset() async {
        await capture.reset()
    }

    static func lastRequest() async -> URLRequest? {
        await capture.lastRequest()
    }

    static func lastBody() async -> Data? {
        await capture.lastBody()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        Task { await Self.capture.record(request: request) }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class KDriveJSONRequestCapturingURLProtocol: URLProtocol {
    private static let capture = CapturedURLRequestStore()
    private static let responseStore = CapturedResponseStore()

    static func reset(responseData: Data) async {
        await capture.reset()
        await responseStore.set(responseData)
    }

    static func lastRequest() async -> URLRequest? {
        await capture.lastRequest()
    }

    static func lastBody() async -> Data? {
        await capture.lastBody()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        let body = request.httpBody ?? Self.readBodyStream(from: request)
        Task {
            await Self.capture.record(request: request, body: body)
            let data = await Self.responseStore.data()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBodyStream(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            guard bytesRead > 0 else {
                break
            }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}

private actor CapturedURLRequestStore {
    private var capturedRequest: URLRequest?
    private var capturedBody: Data?
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    func reset() {
        capturedRequest = nil
        capturedBody = nil
        captureWaiters.removeAll()
    }

    func record(request: URLRequest, body: Data? = nil) {
        capturedRequest = request
        capturedBody = body
        let waiters = captureWaiters
        captureWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func lastRequest() async -> URLRequest? {
        await waitForCapture()
        return capturedRequest
    }

    func lastBody() async -> Data? {
        await waitForCapture()
        return capturedBody
    }

    private func waitForCapture() async {
        guard capturedRequest == nil else { return }

        await withCheckedContinuation { continuation in
            captureWaiters.append(continuation)
        }
    }
}

private actor CapturedResponseStore {
    private var responseData = Data()

    func set(_ data: Data) {
        responseData = data
    }

    func data() -> Data {
        responseData
    }
}

@MainActor
private final class FakeKDriveOAuthAuthenticator: KDriveOAuthAuthenticating {
    private let token: KDriveOAuthToken

    init(token: KDriveOAuthToken = KDriveOAuthToken(
        accessToken: "oauth-token",
        tokenType: "Bearer",
        refreshToken: nil,
        scope: nil,
        idToken: nil,
        expiresAt: nil
    )) {
        self.token = token
    }

    func authenticate() async throws -> KDriveOAuthToken {
        token
    }
}

private struct FakeKDriveFileProvider: KDriveFileProviding {
    let drives: [KDriveDriveSummary]
    let listDrivesError: Error?

    init(drives: [KDriveDriveSummary], listDrivesError: Error? = nil) {
        self.drives = drives
        self.listDrivesError = listDrivesError
    }

    func listDrives() async throws -> [KDriveDriveSummary] {
        if let listDrivesError {
            throw listDrivesError
        }
        return drives
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func replaceFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        throw FakeKDriveFileProviderError.unimplemented
    }
}

private enum FakeKDriveFileProviderError: Error {
    case unimplemented
}

private struct SensitiveFailureError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct FakeSnapshotStatisticsProvider: KDriveSnapshotStatisticsProviding {
    let statistics: [KDriveSnapshotDomainStatistics]

    func snapshotStatistics(domainIdentifiers: Set<String>) async throws -> [KDriveSnapshotDomainStatistics] {
        let statisticsByDomain = Dictionary(uniqueKeysWithValues: statistics.map { ($0.domainIdentifier, $0) })
        return domainIdentifiers
            .sorted()
            .map { statisticsByDomain[$0] ?? KDriveSnapshotDomainStatistics(domainIdentifier: $0) }
    }
}

private struct FakeProviderEventStatisticsProvider: KDriveProviderEventStatisticsProviding {
    let statistics: [KDriveProviderEventDomainStatistics]

    func eventStatistics(domainIdentifiers: Set<String>) async throws -> [KDriveProviderEventDomainStatistics] {
        let statisticsByDomain = Dictionary(uniqueKeysWithValues: statistics.map { ($0.domainIdentifier, $0) })
        return domainIdentifiers
            .sorted()
            .map { statisticsByDomain[$0] ?? KDriveProviderEventDomainStatistics(domainIdentifier: $0) }
    }
}

private actor FakeProviderEventStore: KDriveProviderEventStoring {
    private var conflicts: [KDriveConflictEvent]
    private var activity: [KDriveProviderActivityEvent]
    private var activityQueries = 0

    init(conflicts: [KDriveConflictEvent], activity: [KDriveProviderActivityEvent]) {
        self.conflicts = conflicts
        self.activity = activity
    }

    func saveConflict(_ event: KDriveConflictEvent) throws {
        conflicts.removeAll { $0.id == event.id }
        conflicts.append(event)
    }

    func recordActivity(_ event: KDriveProviderActivityEvent) throws {
        activity.append(event)
    }

    func recentConflicts(domainIdentifier: String?, limit: Int) throws -> [KDriveConflictEvent] {
        Array(conflicts
            .filter { domainIdentifier == nil || $0.domainIdentifier == domainIdentifier }
            .sorted { $0.detectedAt > $1.detectedAt }
            .prefix(limit))
    }

    func recentActivity(domainIdentifier: String?, limit: Int) throws -> [KDriveProviderActivityEvent] {
        try recentActivity(domainIdentifier: domainIdentifier, outcome: nil, limit: limit)
    }

    func recentActivity(
        domainIdentifier: String?,
        outcome: KDriveProviderActivityOutcome?,
        limit: Int
    ) throws -> [KDriveProviderActivityEvent] {
        activityQueries += 1
        return Array(activity
            .filter { domainIdentifier == nil || $0.domainIdentifier == domainIdentifier }
            .filter { outcome == nil || $0.outcome == outcome }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit))
    }

    func removeEvents(domainIdentifier: String) throws {
        conflicts.removeAll { $0.domainIdentifier == domainIdentifier }
        activity.removeAll { $0.domainIdentifier == domainIdentifier }
    }

    func removeActivityAndResolvedConflicts(domainIdentifier: String?) throws {
        activity.removeAll { domainIdentifier == nil || $0.domainIdentifier == domainIdentifier }
        conflicts.removeAll {
            (domainIdentifier == nil || $0.domainIdentifier == domainIdentifier)
                && $0.resolutionState == .automaticallyResolved
        }
    }

    func activityQueryCount() -> Int {
        activityQueries
    }

    func storedConflicts() -> [KDriveConflictEvent] {
        conflicts
    }

    func activities() -> [KDriveProviderActivityEvent] {
        activity
    }
}

@MainActor
private struct NoopProviderDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {}
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}

@MainActor
private final class RecordingProviderDomainRegistrar: ProviderDomainRegistering {
    private(set) var addedConfigurations: [ProviderDomainConfiguration] = []
    private(set) var removedConfigurations: [ProviderDomainConfiguration] = []

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        addedConfigurations.append(configuration)
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {
        removedConfigurations.append(configuration)
    }
}

@MainActor
private struct FailingProviderDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        throw FailingProviderDomainRegistrarError.applicationUnavailable
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}

private enum FailingProviderDomainRegistrarError: LocalizedError {
    case applicationUnavailable

    var errorDescription: String? {
        "The application cannot be used right now"
    }
}
