import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@Suite("Stability Lab remote lifecycle")
struct StabilityLabRemoteCoordinatorTests {
    private let driveID = 7
    private let driveRootFileID = 1
    private let rootFileID = 100
    private let markerFileID = 101
    private let identifier = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ordinaryDomainRejectionMakesNoRemoteCall() async {
        let remote = StabilityLabRemoteFake()
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)
        let ordinaryDomain = StabilityLabRegisteredDomain(
            purpose: .ordinary,
            driveID: 90,
            rootFileID: 91,
            encryptionMode: .legacyPlaintext
        )

        await #expect(throws: StabilityLabRemoteCoordinatorError.ordinaryDomainRegistered) {
            _ = try await coordinator.provision(
                driveID: driveID,
                driveRootFileID: driveRootFileID,
                registeredDomainsProvider: { [ordinaryDomain] }
            )
        }

        #expect(await remote.snapshot().totalCallCount == 0)
    }

    @Test func provisionCreatesTopLevelRootAndReadableFixedMarker() async throws {
        let driveRoot = item(
            id: driveRootFileID,
            parentID: 0,
            type: "dir",
            etag: "drive-root"
        )
        let createdRoot = item(
            id: rootFileID,
            parentID: driveRootFileID,
            type: "dir",
            etag: "root"
        )
        let uploadedMarker = item(
            id: markerFileID,
            parentID: rootFileID,
            type: "file",
            etag: "marker"
        )
        let remote = StabilityLabRemoteFake(
            items: [driveRootFileID: driveRoot],
            createDirectoryResponse: createdRoot,
            uploadResponse: uploadedMarker
        )
        let coordinator = StabilityLabRemoteCoordinator(
            remote: remote,
            makeUUID: { identifier },
            now: { createdAt }
        )

        let configuration = try await coordinator.provision(
            driveID: driveID,
            driveRootFileID: driveRootFileID,
            registeredDomainsProvider: { [] }
        )
        let snapshot = await remote.snapshot()
        let uploadedMarkerData = try #require(snapshot.uploadedData)
        let decodedMarker = try JSONDecoder().decode(
            StabilityLabOwnershipMarker.self,
            from: uploadedMarkerData
        )

        #expect(configuration.driveID == driveID)
        #expect(configuration.driveRootFileID == driveRootFileID)
        #expect(configuration.rootFileID == rootFileID)
        #expect(configuration.ownershipMarkerFileID == markerFileID)
        #expect(configuration.ownershipMarker == decodedMarker)
        #expect(decodedMarker.identifier == identifier)
        #expect(decodedMarker.driveID == driveID)
        #expect(decodedMarker.rootFileID == rootFileID)
        #expect(snapshot.createdParentFileID == driveRootFileID)
        #expect(snapshot.uploadedParentFileID == rootFileID)
        #expect(snapshot.uploadConflictStrategy == .error)
        #expect(snapshot.replaceCallCount == 0)
        #expect(snapshot.trashedFileIDs.isEmpty)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    @MainActor
    @Test func appProvisionRechecksStoredDomainsImmediatelyBeforeRegistration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let driveRoot = item(
            id: driveRootFileID,
            parentID: 0,
            type: "dir",
            etag: "drive-root"
        )
        let createdRoot = item(
            id: rootFileID,
            parentID: driveRootFileID,
            type: "dir",
            etag: "root"
        )
        let uploadedMarker = item(
            id: markerFileID,
            parentID: rootFileID,
            type: "file",
            etag: "marker"
        )
        let drive = KDriveDriveSummary(
            id: driveID,
            name: "fixture",
            accountID: 0,
            role: "admin",
            status: "active",
            isInMaintenance: false
        )
        let remote = StabilityLabRemoteFake(
            items: [driveRootFileID: driveRoot],
            createDirectoryResponse: createdRoot,
            uploadResponse: uploadedMarker
        )
        let domainStore = StabilityLabRegistrationRaceStore()
        let registrar = StabilityLabRegistrationRecorder()
        let account = ProviderAccount(
            accountIdentifier: ProviderConstants.legacyAccountIdentifier,
            displayName: "fixture",
            authenticationKind: .manualAccessToken
        )
        let tokenStore = InMemoryOAuthTokenStore(token: KDriveOAuthToken(
            accessToken: "lab-private-canary",
            tokenType: "Synthetic",
            refreshToken: nil,
            scope: nil,
            idToken: nil,
            expiresAt: nil
        ))
        let databaseURL = directory.appendingPathComponent("state.sqlite3")
        let model = PotassiumProviderAppModel(
            accountStore: ProviderAccountFileStore(
                directoryURL: directory.appendingPathComponent("accounts", isDirectory: true)
            ),
            domainStore: domainStore,
            tokenStore: tokenStore,
            domainRegistrar: registrar,
            snapshotStore: try KDriveSnapshotSQLiteStore(databaseURL: databaseURL),
            eventStore: try KDriveProviderEventSQLiteStore(databaseURL: databaseURL),
            automaticallyReloadStoredState: false,
            initialAccounts: [account],
            initialDrivesByAccountIdentifier: [account.accountIdentifier: [drive]],
            fileProviderFactory: { _ in remote }
        )

        await model.provisionStabilityLab(
            accountIdentifier: account.accountIdentifier,
            drive: drive
        )

        #expect(registrar.addedConfigurations.isEmpty)
        #expect(await domainStore.hasInjectedOrdinaryConfiguration())
        #expect(model.errorMessage != nil)
    }

    @Test func provisionRejectsExternalDriveBeforeRemoteMutation() async {
        let remote = StabilityLabRemoteFake(
            drives: [
                KDriveDriveSummary(
                    id: driveID,
                    name: "fixture",
                    accountID: 0,
                    role: "external",
                    status: "active",
                    isInMaintenance: false
                ),
            ]
        )
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)

        await #expect(throws: StabilityLabRemoteCoordinatorError.driveAccessNotVerified) {
            _ = try await coordinator.provision(
                driveID: driveID,
                driveRootFileID: driveRootFileID,
                registeredDomainsProvider: { [] }
            )
        }

        let snapshot = await remote.snapshot()
        #expect(snapshot.totalCallCount == 1)
        #expect(snapshot.createdParentFileID == nil)
        #expect(snapshot.uploadedParentFileID == nil)
        #expect(snapshot.trashedFileIDs.isEmpty)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    @Test func provisionRechecksDomainIsolationImmediatelyBeforeCreate() async {
        let ordinary = StabilityLabRegisteredDomain(
            purpose: .ordinary,
            driveID: 0,
            rootFileID: 0,
            encryptionMode: .legacyPlaintext
        )
        let evidence = StabilityLabDomainEvidenceSequence([[], [ordinary]])
        let remote = StabilityLabRemoteFake(items: [
            driveRootFileID: item(
                id: driveRootFileID,
                parentID: 0,
                type: "dir"
            ),
        ])
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)

        await #expect(throws: StabilityLabRemoteCoordinatorError.ordinaryDomainRegistered) {
            _ = try await coordinator.provision(
                driveID: driveID,
                driveRootFileID: driveRootFileID,
                registeredDomainsProvider: { await evidence.next() }
            )
        }

        let snapshot = await remote.snapshot()
        #expect(snapshot.createdParentFileID == nil)
        #expect(snapshot.uploadedParentFileID == nil)
        #expect(snapshot.trashedFileIDs.isEmpty)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    @Test func resetConsumesEveryPageAndPreservesRootAndMarker() async throws {
        let marker = makeMarker()
        let root = item(id: rootFileID, parentID: driveRootFileID, type: "dir")
        let markerItem = item(id: markerFileID, parentID: rootFileID, type: "file")
        let laterChild = item(id: 103, parentID: rootFileID, type: "file")
        let earlierChild = item(id: 102, parentID: rootFileID, type: "dir")
        let remote = StabilityLabRemoteFake(
            items: [
                rootFileID: root,
                markerFileID: markerItem,
                102: earlierChild,
                103: laterChild,
            ],
            markerData: try JSONEncoder().encode(marker),
            pages: [
                StabilityLabRemoteFake.initialCursorKey: KDriveItemPage(
                    items: [markerItem, laterChild],
                    nextCursor: "second-page",
                    hasMore: true
                ),
                "second-page": KDriveItemPage(
                    items: [earlierChild],
                    nextCursor: nil,
                    hasMore: false
                ),
            ]
        )
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)

        let result = try await coordinator.reset(
            configuration: configuration(marker: marker),
            configuredEncryptionMode: .legacyPlaintext,
            registeredDomainsProvider: { [registeredLab(marker: marker)] },
            confirmation: try confirmation(marker: marker)
        )
        let snapshot = await remote.snapshot()

        #expect(result.trashedImmediateChildCount == 2)
        #expect(snapshot.listingCursors == [nil, "second-page"])
        #expect(snapshot.trashedFileIDs == [102, 103])
        #expect(snapshot.trashedFileIDs.contains(rootFileID) == false)
        #expect(snapshot.trashedFileIDs.contains(markerFileID) == false)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    @Test func paginationCursorLoopFailsBeforeAnyTrashMutation() async throws {
        let marker = makeMarker()
        let root = item(id: rootFileID, parentID: driveRootFileID, type: "dir")
        let markerItem = item(id: markerFileID, parentID: rootFileID, type: "file")
        let child = item(id: 102, parentID: rootFileID, type: "file")
        let repeatingPage = KDriveItemPage(
            items: [markerItem, child],
            nextCursor: "repeat",
            hasMore: true
        )
        let remote = StabilityLabRemoteFake(
            items: [rootFileID: root, markerFileID: markerItem, 102: child],
            markerData: try JSONEncoder().encode(marker),
            pages: [
                StabilityLabRemoteFake.initialCursorKey: repeatingPage,
                "repeat": repeatingPage,
            ]
        )
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)

        await #expect(throws: StabilityLabRemoteCoordinatorError.repeatedDirectoryCursor) {
            _ = try await coordinator.reset(
                configuration: configuration(marker: marker),
                configuredEncryptionMode: .legacyPlaintext,
                registeredDomainsProvider: { [registeredLab(marker: marker)] },
                confirmation: try confirmation(marker: marker)
            )
        }

        let snapshot = await remote.snapshot()
        #expect(snapshot.trashedFileIDs.isEmpty)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    @Test func resetRechecksDomainIsolationBeforeEachTrashMutation() async throws {
        let marker = makeMarker()
        let registered = registeredLab(marker: marker)
        let ordinary = StabilityLabRegisteredDomain(
            purpose: .ordinary,
            driveID: 0,
            rootFileID: 0,
            encryptionMode: .legacyPlaintext
        )
        let evidence = StabilityLabDomainEvidenceSequence([[registered], [ordinary]])
        let root = item(id: rootFileID, parentID: driveRootFileID, type: "dir")
        let markerItem = item(id: markerFileID, parentID: rootFileID, type: "file")
        let child = item(id: 102, parentID: rootFileID, type: "file")
        let remote = StabilityLabRemoteFake(
            items: [rootFileID: root, markerFileID: markerItem, 102: child],
            markerData: try JSONEncoder().encode(marker),
            pages: [
                StabilityLabRemoteFake.initialCursorKey: KDriveItemPage(
                    items: [markerItem, child],
                    nextCursor: nil,
                    hasMore: false
                ),
            ]
        )
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)

        await #expect(throws: StabilityLabResetPlanningError.self) {
            _ = try await coordinator.reset(
                configuration: configuration(marker: marker),
                configuredEncryptionMode: .legacyPlaintext,
                registeredDomainsProvider: { await evidence.next() },
                confirmation: try confirmation(marker: marker)
            )
        }

        let snapshot = await remote.snapshot()
        #expect(snapshot.trashedFileIDs.isEmpty)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    @Test func resetRejectsTargetMovedAfterPlanningBeforeTrashCall() async throws {
        let marker = makeMarker()
        let root = item(id: rootFileID, parentID: driveRootFileID, type: "dir")
        let markerItem = item(id: markerFileID, parentID: rootFileID, type: "file")
        let listedChild = item(id: 102, parentID: rootFileID, type: "file")
        let movedChild = item(id: 102, parentID: 999, type: "file")
        let remote = StabilityLabRemoteFake(
            items: [rootFileID: root, markerFileID: markerItem, 102: listedChild],
            markerData: try JSONEncoder().encode(marker),
            pages: [
                StabilityLabRemoteFake.initialCursorKey: KDriveItemPage(
                    items: [markerItem, listedChild],
                    nextCursor: nil,
                    hasMore: false
                ),
            ],
            itemResponseQueues: [102: [movedChild]]
        )
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)

        await #expect(throws: StabilityLabRemoteCoordinatorError.resetTargetIdentityChanged) {
            _ = try await coordinator.reset(
                configuration: configuration(marker: marker),
                configuredEncryptionMode: .legacyPlaintext,
                registeredDomainsProvider: { [registeredLab(marker: marker)] },
                confirmation: try confirmation(marker: marker)
            )
        }

        let snapshot = await remote.snapshot()
        #expect(snapshot.trashedFileIDs.isEmpty)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    @Test func resetRejectsFreshRootDriftBeforeTrashCall() async throws {
        let marker = makeMarker()
        let root = item(id: rootFileID, parentID: driveRootFileID, type: "dir")
        let movedRoot = item(id: rootFileID, parentID: 999, type: "dir")
        let markerItem = item(id: markerFileID, parentID: rootFileID, type: "file")
        let child = item(id: 102, parentID: rootFileID, type: "file")
        let remote = StabilityLabRemoteFake(
            items: [rootFileID: root, markerFileID: markerItem, 102: child],
            markerData: try JSONEncoder().encode(marker),
            pages: [
                StabilityLabRemoteFake.initialCursorKey: KDriveItemPage(
                    items: [markerItem, child],
                    nextCursor: nil,
                    hasMore: false
                ),
            ],
            itemResponseQueues: [rootFileID: [root, movedRoot]]
        )
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)

        await #expect(throws: StabilityLabRemoteCoordinatorError.invalidProvisionedRoot) {
            _ = try await coordinator.reset(
                configuration: configuration(marker: marker),
                configuredEncryptionMode: .legacyPlaintext,
                registeredDomainsProvider: { [registeredLab(marker: marker)] },
                confirmation: try confirmation(marker: marker)
            )
        }

        let snapshot = await remote.snapshot()
        #expect(snapshot.trashedFileIDs.isEmpty)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    @Test func resetRejectsFreshMarkerDriftBeforeTrashCall() async throws {
        let marker = makeMarker()
        let changedMarker = StabilityLabOwnershipMarker(
            identifier: UUID(uuidString: "50000000-0000-0000-0000-000000000099")!,
            driveID: driveID,
            rootFileID: rootFileID,
            createdAt: createdAt
        )
        let root = item(id: rootFileID, parentID: driveRootFileID, type: "dir")
        let markerItem = item(id: markerFileID, parentID: rootFileID, type: "file")
        let child = item(id: 102, parentID: rootFileID, type: "file")
        let remote = StabilityLabRemoteFake(
            items: [rootFileID: root, markerFileID: markerItem, 102: child],
            markerData: try JSONEncoder().encode(marker),
            pages: [
                StabilityLabRemoteFake.initialCursorKey: KDriveItemPage(
                    items: [markerItem, child],
                    nextCursor: nil,
                    hasMore: false
                ),
            ],
            downloadDataQueue: [
                try JSONEncoder().encode(marker),
                try JSONEncoder().encode(changedMarker),
            ]
        )
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)

        await #expect(throws: StabilityLabRemoteCoordinatorError.ownershipMarkerMismatch) {
            _ = try await coordinator.reset(
                configuration: configuration(marker: marker),
                configuredEncryptionMode: .legacyPlaintext,
                registeredDomainsProvider: { [registeredLab(marker: marker)] },
                confirmation: try confirmation(marker: marker)
            )
        }

        let snapshot = await remote.snapshot()
        #expect(snapshot.trashedFileIDs.isEmpty)
        #expect(snapshot.permanentlyDeletedFileIDs.isEmpty)
    }

    private func makeMarker() -> StabilityLabOwnershipMarker {
        StabilityLabOwnershipMarker(
            identifier: identifier,
            driveID: driveID,
            rootFileID: rootFileID,
            createdAt: createdAt
        )
    }

    private func configuration(
        marker: StabilityLabOwnershipMarker
    ) -> StabilityLabRemoteConfiguration {
        StabilityLabRemoteConfiguration(
            driveID: driveID,
            driveRootFileID: driveRootFileID,
            rootFileID: rootFileID,
            ownershipMarkerFileID: markerFileID,
            ownershipMarker: marker
        )
    }

    private func registeredLab(
        marker: StabilityLabOwnershipMarker
    ) -> StabilityLabRegisteredDomain {
        StabilityLabRegisteredDomain(
            purpose: .stabilityLab,
            driveID: driveID,
            rootFileID: rootFileID,
            encryptionMode: .legacyPlaintext,
            ownershipMarkerIdentifier: marker.identifier
        )
    }

    private func confirmation(
        marker: StabilityLabOwnershipMarker
    ) throws -> StabilityLabResetConfirmation {
        try StabilityLabResetConfirmation(
            typedPhrase: StabilityLabResetConfirmation.requiredPhrase,
            marker: marker
        )
    }

    private func item(
        id: Int,
        parentID: Int,
        type: String,
        etag: String? = "etag"
    ) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: "fixture",
            type: type,
            status: "active",
            driveID: driveID,
            parentID: parentID,
            path: nil,
            size: type == "file" ? 10 : nil,
            mimeType: type == "file" ? "application/json" : nil,
            createdAt: createdAt,
            modifiedAt: createdAt,
            revisedAt: createdAt,
            updatedAt: createdAt,
            etag: etag
        )
    }

}

private actor StabilityLabDomainEvidenceSequence {
    private var values: [[StabilityLabRegisteredDomain]]

    init(_ values: [[StabilityLabRegisteredDomain]]) {
        self.values = values
    }

    func next() -> [StabilityLabRegisteredDomain] {
        guard values.count > 1 else { return values.first ?? [] }
        return values.removeFirst()
    }
}

private actor StabilityLabRegistrationRaceStore: DomainConfigurationStoring {
    private var savedLab: ProviderDomainConfiguration?
    private var readsAfterSave = 0
    private var didInjectOrdinaryConfiguration = false

    func allConfigurations() -> [ProviderDomainConfiguration] {
        guard let savedLab else { return [] }
        readsAfterSave += 1
        guard readsAfterSave > 1 else { return [savedLab] }
        didInjectOrdinaryConfiguration = true
        return [savedLab, ordinaryConfiguration]
    }

    func configuration(domainIdentifier: String) -> ProviderDomainConfiguration? {
        guard let savedLab else { return nil }
        if savedLab.domainIdentifier == domainIdentifier { return savedLab }
        return ordinaryConfiguration.domainIdentifier == domainIdentifier
            ? ordinaryConfiguration
            : nil
    }

    func save(_ configuration: ProviderDomainConfiguration) {
        savedLab = configuration
    }

    func remove(domainIdentifier: String) {
        if savedLab?.domainIdentifier == domainIdentifier {
            savedLab = nil
        }
    }

    func hasInjectedOrdinaryConfiguration() -> Bool {
        didInjectOrdinaryConfiguration
    }

    private var ordinaryConfiguration: ProviderDomainConfiguration {
        ProviderDomainConfiguration(
            domainIdentifier: "ordinary-race-fixture",
            displayName: "fixture",
            driveID: 900,
            driveName: "fixture",
            rootFileID: 901
        )
    }
}

@MainActor
private final class StabilityLabRegistrationRecorder: ProviderDomainRegistering {
    private(set) var addedConfigurations: [ProviderDomainConfiguration] = []

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        addedConfigurations.append(configuration)
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}

    func registeredDomainIdentifiers() async throws -> Set<String> { [] }
}

private enum StabilityLabRemoteFakeError: Error {
    case unexpectedCall
}

private struct StabilityLabRemoteFakeSnapshot: Sendable {
    let totalCallCount: Int
    let createdParentFileID: Int?
    let uploadedParentFileID: Int?
    let uploadConflictStrategy: KDriveUploadConflictStrategy?
    let uploadedData: Data?
    let replaceCallCount: Int
    let listingCursors: [String?]
    let trashedFileIDs: [Int]
    let permanentlyDeletedFileIDs: [Int]
}

private actor StabilityLabRemoteFake: KDriveFileProviding {
    static let initialCursorKey = "<initial>"

    private var items: [Int: KDriveRemoteItem]
    private let drives: [KDriveDriveSummary]
    private var markerData: Data?
    private var downloadDataQueue: [Data]
    private let pages: [String: KDriveItemPage]
    private var itemResponseQueues: [Int: [KDriveRemoteItem]]
    private let createDirectoryResponse: KDriveRemoteItem?
    private let uploadResponse: KDriveRemoteItem?

    private var totalCallCount = 0
    private var createdParentFileID: Int?
    private var uploadedParentFileID: Int?
    private var uploadConflictStrategy: KDriveUploadConflictStrategy?
    private var uploadedData: Data?
    private var replaceCallCount = 0
    private var listingCursors: [String?] = []
    private var trashedFileIDs: [Int] = []
    private var permanentlyDeletedFileIDs: [Int] = []

    init(
        items: [Int: KDriveRemoteItem] = [:],
        drives: [KDriveDriveSummary] = [
            KDriveDriveSummary(
                id: 7,
                name: "fixture",
                accountID: 0,
                role: "admin",
                status: "active",
                isInMaintenance: false
            ),
        ],
        markerData: Data? = nil,
        pages: [String: KDriveItemPage] = [:],
        itemResponseQueues: [Int: [KDriveRemoteItem]] = [:],
        downloadDataQueue: [Data] = [],
        createDirectoryResponse: KDriveRemoteItem? = nil,
        uploadResponse: KDriveRemoteItem? = nil
    ) {
        self.items = items
        self.drives = drives
        self.markerData = markerData
        self.pages = pages
        self.itemResponseQueues = itemResponseQueues
        self.downloadDataQueue = downloadDataQueue
        self.createDirectoryResponse = createDirectoryResponse
        self.uploadResponse = uploadResponse
    }

    func snapshot() -> StabilityLabRemoteFakeSnapshot {
        StabilityLabRemoteFakeSnapshot(
            totalCallCount: totalCallCount,
            createdParentFileID: createdParentFileID,
            uploadedParentFileID: uploadedParentFileID,
            uploadConflictStrategy: uploadConflictStrategy,
            uploadedData: uploadedData,
            replaceCallCount: replaceCallCount,
            listingCursors: listingCursors,
            trashedFileIDs: trashedFileIDs,
            permanentlyDeletedFileIDs: permanentlyDeletedFileIDs
        )
    }

    func listDrives() async throws -> [KDriveDriveSummary] {
        totalCallCount += 1
        return drives
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        totalCallCount += 1
        if var queued = itemResponseQueues[fileID], queued.isEmpty == false {
            let result = queued.removeFirst()
            itemResponseQueues[fileID] = queued
            return result
        }
        guard let item = items[fileID] else {
            throw StabilityLabRemoteFakeError.unexpectedCall
        }
        return item
    }

    func listDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveItemPage {
        totalCallCount += 1
        listingCursors.append(cursor)
        guard let page = pages[cursor ?? Self.initialCursorKey] else {
            throw StabilityLabRemoteFakeError.unexpectedCall
        }
        return page
    }

    func listAdvancedDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveAdvancedItemPage {
        totalCallCount += 1
        throw StabilityLabRemoteFakeError.unexpectedCall
    }

    func listTrash(
        driveID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveItemPage {
        totalCallCount += 1
        throw StabilityLabRemoteFakeError.unexpectedCall
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        totalCallCount += 1
        if downloadDataQueue.isEmpty == false {
            return downloadDataQueue.removeFirst()
        }
        guard let markerData else {
            throw StabilityLabRemoteFakeError.unexpectedCall
        }
        return markerData
    }

    func thumbnail(
        driveID: Int,
        fileID: Int,
        width: Int?,
        height: Int?
    ) async throws -> Data {
        totalCallCount += 1
        throw StabilityLabRemoteFakeError.unexpectedCall
    }

    func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy,
        clientToken: String?,
        contentHash: String?
    ) async throws -> KDriveRemoteItem {
        totalCallCount += 1
        guard let uploadResponse else {
            throw StabilityLabRemoteFakeError.unexpectedCall
        }
        uploadedParentFileID = parentID
        uploadConflictStrategy = conflictStrategy
        uploadedData = contents
        markerData = contents
        items[uploadResponse.id] = uploadResponse
        return uploadResponse
    }

    func replaceFile(
        driveID: Int,
        fileID: Int,
        expectedETag: String,
        clientToken: String,
        contentHash: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem {
        totalCallCount += 1
        replaceCallCount += 1
        throw StabilityLabRemoteFakeError.unexpectedCall
    }

    func createDirectory(
        driveID: Int,
        parentID: Int,
        name: String
    ) async throws -> KDriveRemoteItem {
        totalCallCount += 1
        guard let createDirectoryResponse else {
            throw StabilityLabRemoteFakeError.unexpectedCall
        }
        createdParentFileID = parentID
        items[createDirectoryResponse.id] = createDirectoryResponse
        return createDirectoryResponse
    }

    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        totalCallCount += 1
        throw StabilityLabRemoteFakeError.unexpectedCall
    }

    func moveItem(
        driveID: Int,
        fileID: Int,
        destinationParentID: Int,
        name: String?
    ) async throws {
        totalCallCount += 1
        throw StabilityLabRemoteFakeError.unexpectedCall
    }

    func updateModificationDate(driveID: Int, fileID: Int, date: Date) async throws {
        totalCallCount += 1
        throw StabilityLabRemoteFakeError.unexpectedCall
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        totalCallCount += 1
        trashedFileIDs.append(fileID)
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        totalCallCount += 1
        permanentlyDeletedFileIDs.append(fileID)
    }
}
