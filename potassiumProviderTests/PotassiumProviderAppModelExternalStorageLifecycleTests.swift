#if os(macOS)
import FileProvider
import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@Suite(.serialized)
@MainActor
struct PotassiumProviderAppModelExternalStorageLifecycleTests {
    @Test func movingInternalDomainToExternalStoragePreservesIdentityAndClearsOldState() async throws {
        let context = try await makeContext(knownFolderState: .inactive)
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }

        await context.model.moveDomain(
            context.sourceConfiguration,
            toExternalVolume: context.externalVolume
        )

        let movedConfiguration = try #require(try await context.domainStore.configuration(
            configurationIdentifier: context.sourceConfiguration.configurationIdentifier
        ))
        #expect(movedConfiguration.configurationIdentifier == context.sourceConfiguration.configurationIdentifier)
        #expect(movedConfiguration.domainIdentifier != context.sourceConfiguration.domainIdentifier)
        #expect(movedConfiguration.storageLocation == .externalVolume(
            uuid: context.externalVolume.uuid,
            displayName: context.externalVolume.displayName
        ))

        let stabilizationIndex = try #require(context.registrar.events.firstIndex {
            $0 == .stabilize(domainIdentifier: context.sourceConfiguration.domainIdentifier)
        })
        let removalIndex = try #require(context.registrar.events.firstIndex {
            $0 == .removePreservingData(domainIdentifier: context.sourceConfiguration.domainIdentifier)
        })
        let additionIndex = try #require(context.registrar.events.firstIndex {
            if case .addPrepared(let domainIdentifier) = $0 {
                return domainIdentifier == movedConfiguration.domainIdentifier
            }
            return false
        })
        #expect(stabilizationIndex < removalIndex)
        #expect(removalIndex < additionIndex)

        #expect(await context.snapshotStore.removedDomainIdentifiers == [
            context.sourceConfiguration.domainIdentifier,
        ])
        #expect(await context.eventStore.removedDomainIdentifiers == [
            context.sourceConfiguration.domainIdentifier,
        ])
        #expect(try await context.journalStore.journal(
            configurationIdentifier: context.sourceConfiguration.configurationIdentifier
        ) == nil)
        #expect(context.model.placementState(for: movedConfiguration) == .connected)
        #expect(context.model.errorMessage == nil)
    }

    @Test func failedTargetRegistrationRecreatesSourcePlacementWithFreshDomainIdentifier() async throws {
        let context = try await makeContext(
            knownFolderState: .inactive,
            failExternalRegistration: true
        )
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }

        await context.model.moveDomain(
            context.sourceConfiguration,
            toExternalVolume: context.externalVolume
        )

        let failedTargetIdentifier = try #require(context.registrar.events.compactMap { event in
            if case .prepare(
                domainIdentifier: let domainIdentifier,
                target: .externalVolume
            ) = event {
                return domainIdentifier
            }
            return nil
        }.first)
        let recoveredSourceIdentifier = try #require(context.registrar.events.compactMap { event in
            if case .prepare(
                domainIdentifier: let domainIdentifier,
                target: .onThisMac
            ) = event {
                return domainIdentifier
            }
            return nil
        }.last)
        let recoveredConfiguration = try #require(try await context.domainStore.configuration(
            configurationIdentifier: context.sourceConfiguration.configurationIdentifier
        ))

        #expect(recoveredConfiguration.configurationIdentifier == context.sourceConfiguration.configurationIdentifier)
        #expect(recoveredConfiguration.domainIdentifier == recoveredSourceIdentifier)
        #expect(recoveredConfiguration.domainIdentifier != context.sourceConfiguration.domainIdentifier)
        #expect(recoveredConfiguration.domainIdentifier != failedTargetIdentifier)
        #expect(recoveredConfiguration.storageLocation == .onThisMac)
        #expect(context.registrar.events.contains(
            .addPrepared(domainIdentifier: recoveredSourceIdentifier)
        ))
        #expect(try await context.journalStore.journal(
            configurationIdentifier: context.sourceConfiguration.configurationIdentifier
        ) == nil)
        #expect(await context.snapshotStore.removedDomainIdentifiers == [
            context.sourceConfiguration.domainIdentifier,
        ])
        #expect(await context.eventStore.removedDomainIdentifiers == [
            context.sourceConfiguration.domainIdentifier,
        ])
        #expect(context.model.placementState(for: recoveredConfiguration) == .connected)
        #expect(context.model.errorMessage?.contains("Could not change storage") == true)
    }

    @Test func knownFolderReclaimFailureKeepsSuccessfulPlacementAndPersistsRepairState() async throws {
        let context = try await makeContext(
            knownFolderState: .active,
            failKnownFolderClaim: true
        )
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }

        await context.model.moveDomain(
            context.sourceConfiguration,
            toExternalVolume: context.externalVolume
        )

        let movedConfiguration = try #require(try await context.domainStore.configuration(
            configurationIdentifier: context.sourceConfiguration.configurationIdentifier
        ))
        let journal = try #require(try await context.journalStore.journal(
            configurationIdentifier: context.sourceConfiguration.configurationIdentifier
        ))

        #expect(movedConfiguration.configurationIdentifier == context.sourceConfiguration.configurationIdentifier)
        #expect(movedConfiguration.domainIdentifier != context.sourceConfiguration.domainIdentifier)
        #expect(movedConfiguration.storageLocation == .externalVolume(
            uuid: context.externalVolume.uuid,
            displayName: context.externalVolume.displayName
        ))
        #expect(journal.phase == .knownFolderReclaimRequired)
        #expect(journal.knownFoldersWereActive)
        #expect(journal.targetDomainIdentifier == movedConfiguration.domainIdentifier)
        #expect(context.registrar.events.contains(
            .claim(
                domainIdentifier: movedConfiguration.domainIdentifier,
                parentFileID: ExternalStorageLifecycleRemote.privateDirectoryFileID
            )
        ))
        #expect(await context.snapshotStore.removedDomainIdentifiers == [
            context.sourceConfiguration.domainIdentifier,
        ])
        #expect(await context.eventStore.removedDomainIdentifiers == [
            context.sourceConfiguration.domainIdentifier,
        ])

        if case .needsRepair(let detail) = context.model.placementState(for: movedConfiguration) {
            #expect(detail.contains("Desktop & Documents"))
        } else {
            Issue.record("Expected a Needs Repair placement after known-folder reclaim failed.")
        }
        #expect(context.model.statusMessage?.contains("need repair") == true)
        #expect(context.model.errorMessage == nil)
    }

    @Test func reloadAndRepairRestoreRegisteredSourceWithoutCreatingDuplicateDomain() async throws {
        let context = try await makeContext(knownFolderState: .inactive)
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }

        let journal = ProviderDomainRelocationJournal(
            configurationIdentifier: context.sourceConfiguration.configurationIdentifier,
            sourceConfiguration: context.sourceConfiguration,
            targetStorageLocation: .externalVolume(
                uuid: context.externalVolume.uuid,
                displayName: context.externalVolume.displayName
            ),
            knownFoldersWereActive: false,
            phase: .preparing
        )
        try await context.journalStore.save(journal)
        context.registrar.resetEvents()

        await context.model.reloadStoredState()

        #expect(context.registrar.events.contains(
            .addExisting(domainIdentifier: context.sourceConfiguration.domainIdentifier)
        ) == false)
        #expect(context.model.canMutate(context.sourceConfiguration) == false)

        context.registrar.resetEvents()
        await context.model.repairDomain(context.sourceConfiguration)

        #expect(context.registrar.events.contains { event in
            if case .prepare = event { return true }
            return false
        } == false)
        #expect(context.registrar.events.contains { event in
            if case .addPrepared = event { return true }
            return false
        } == false)
        #expect(try await context.journalStore.journal(
            configurationIdentifier: context.sourceConfiguration.configurationIdentifier
        ) == nil)
        #expect(context.model.placementState(for: context.sourceConfiguration) == .connected)
        #expect(context.model.errorMessage == nil)
    }

    private func makeContext(
        knownFolderState: ProviderKnownFolderSyncState,
        failExternalRegistration: Bool = false,
        failKnownFolderClaim: Bool = false
    ) async throws -> ExternalStorageLifecycleContext {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "external-storage-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        let accountStore = ProviderAccountFileStore(
            directoryURL: directoryURL.appendingPathComponent("Accounts", isDirectory: true)
        )
        let domainStore = DomainConfigurationFileStore(
            directoryURL: directoryURL.appendingPathComponent("Domains", isDirectory: true)
        )
        let journalStore = ProviderDomainRelocationFileStore(
            directoryURL: directoryURL.appendingPathComponent("Relocations", isDirectory: true)
        )
        let tokenStore = ExternalStorageLifecycleTokenStore()
        let snapshotStore = ExternalStorageLifecycleSnapshotStore()
        let eventStore = ExternalStorageLifecycleEventStore()
        let account = ProviderAccount(
            accountIdentifier: "account-1",
            displayName: "Test Account",
            authenticationKind: .manualAccessToken
        )
        let sourceConfiguration = ProviderDomainConfiguration(
            configurationIdentifier: "configuration-1",
            domainIdentifier: "source-domain-1",
            accountIdentifier: account.accountIdentifier,
            displayName: "Test Drive",
            driveID: 42,
            driveName: "Test Drive",
            rootFileID: 1,
            storageLocation: .onThisMac,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try await accountStore.save(account)
        try await domainStore.save(sourceConfiguration)
        await tokenStore.setToken(
            KDriveOAuthToken(
                accessToken: "test-token",
                tokenType: "Bearer",
                refreshToken: nil,
                scope: nil,
                idToken: nil,
                expiresAt: nil
            ),
            accountIdentifier: account.accountIdentifier
        )

        let volumeURL = directoryURL.appendingPathComponent("External Drive", isDirectory: true)
        let volumeUUID = UUID(uuidString: "81B6B7A0-3822-48EF-9C72-6759862DD158")!
        let volumeSelector = ProviderExternalVolumeSelectionService(
            chooseURL: { volumeURL },
            startAccessing: { _ in false },
            stopAccessing: { _ in },
            volumeRoot: { $0 },
            volumeMetadata: { _ in
                ProviderExternalVolumeMetadata(
                    uuid: volumeUUID,
                    displayName: "External Drive",
                    totalCapacity: 2_000,
                    availableCapacity: 1_000
                )
            },
            checkEligibility: { _ in .eligible },
            mountedVolumeURLs: { [volumeURL] }
        )
        let externalVolume = try volumeSelector.inspectVolume(at: volumeURL)
        let registrar = ExternalStorageLifecycleRegistrar(
            initialConfiguration: sourceConfiguration,
            knownFolderState: knownFolderState,
            externalVolumeUUID: volumeUUID,
            failExternalRegistration: failExternalRegistration,
            failKnownFolderClaim: failKnownFolderClaim
        )
        let remote = ExternalStorageLifecycleRemote()
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: domainStore,
            tokenStore: tokenStore,
            domainRegistrar: registrar,
            relocationJournalStore: journalStore,
            externalVolumeSelector: volumeSelector,
            snapshotStore: snapshotStore,
            eventStore: eventStore,
            automaticallyReloadStoredState: false,
            fileProviderFactory: { _ in remote }
        )
        await model.reloadStoredState()
        registrar.resetEvents()

        return ExternalStorageLifecycleContext(
            directoryURL: directoryURL,
            sourceConfiguration: sourceConfiguration,
            externalVolume: externalVolume,
            domainStore: domainStore,
            journalStore: journalStore,
            snapshotStore: snapshotStore,
            eventStore: eventStore,
            registrar: registrar,
            model: model
        )
    }
}

@MainActor
private struct ExternalStorageLifecycleContext {
    let directoryURL: URL
    let sourceConfiguration: ProviderDomainConfiguration
    let externalVolume: ProviderExternalVolume
    let domainStore: DomainConfigurationFileStore
    let journalStore: ProviderDomainRelocationFileStore
    let snapshotStore: ExternalStorageLifecycleSnapshotStore
    let eventStore: ExternalStorageLifecycleEventStore
    let registrar: ExternalStorageLifecycleRegistrar
    let model: PotassiumProviderAppModel
}

private enum ExternalStorageLifecyclePreparationTarget: Equatable {
    case onThisMac
    case externalVolume
}

@MainActor
private final class ExternalStorageLifecycleRegistrar: ProviderDomainRegistering {
    enum Event: Equatable {
        case addExisting(domainIdentifier: String)
        case prepare(domainIdentifier: String, target: ExternalStorageLifecyclePreparationTarget)
        case addPrepared(domainIdentifier: String)
        case refreshRegisteredDomains
        case refreshKnownFolders
        case stabilize(domainIdentifier: String)
        case removePreservingData(domainIdentifier: String)
        case reconnect(domainIdentifier: String)
        case claim(domainIdentifier: String, parentFileID: Int)
        case release(domainIdentifier: String)
        case remove(domainIdentifier: String)
    }

    private struct Registration {
        let configurationIdentifier: String
        let domainIdentifier: String
        let displayName: String
        let volumeUUID: UUID?
    }

    private(set) var events: [Event] = []
    private var registrations: [String: Registration] = [:]
    private var knownFolderStates: [String: ProviderKnownFolderSyncState]
    private var preparedTargets: [String: ProviderDomainPreparationTarget] = [:]
    private let externalVolumeUUID: UUID
    private let failExternalRegistration: Bool
    private let failKnownFolderClaim: Bool

    init(
        initialConfiguration: ProviderDomainConfiguration,
        knownFolderState: ProviderKnownFolderSyncState,
        externalVolumeUUID: UUID,
        failExternalRegistration: Bool,
        failKnownFolderClaim: Bool
    ) {
        self.knownFolderStates = [initialConfiguration.domainIdentifier: knownFolderState]
        self.externalVolumeUUID = externalVolumeUUID
        self.failExternalRegistration = failExternalRegistration
        self.failKnownFolderClaim = failKnownFolderClaim
    }

    func resetEvents() {
        events = []
    }

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        events.append(.addExisting(domainIdentifier: configuration.domainIdentifier))
        registrations[configuration.domainIdentifier] = Registration(
            configurationIdentifier: configuration.configurationIdentifier,
            domainIdentifier: configuration.domainIdentifier,
            displayName: configuration.displayName,
            volumeUUID: nil
        )
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {
        events.append(.remove(domainIdentifier: configuration.domainIdentifier))
        registrations[configuration.domainIdentifier] = nil
        knownFolderStates[configuration.domainIdentifier] = nil
    }

    func prepareDomain(
        configurationIdentifier: String,
        domainIdentifier: String,
        displayName: String,
        target: ProviderDomainPreparationTarget
    ) throws -> ProviderPreparedDomain {
        preparedTargets[domainIdentifier] = target
        let volumeUUID: UUID?
        switch target {
        case .onThisMac:
            events.append(.prepare(domainIdentifier: domainIdentifier, target: .onThisMac))
            volumeUUID = nil
        case .externalVolume:
            events.append(.prepare(domainIdentifier: domainIdentifier, target: .externalVolume))
            volumeUUID = externalVolumeUUID
        }
        return ProviderPreparedDomain(
            configurationIdentifier: configurationIdentifier,
            domainIdentifier: domainIdentifier,
            volumeUUID: volumeUUID,
            fileProviderDomain: NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: domainIdentifier),
                displayName: displayName
            )
        )
    }

    func addPreparedDomain(_ preparedDomain: ProviderPreparedDomain) async throws {
        events.append(.addPrepared(domainIdentifier: preparedDomain.domainIdentifier))
        if failExternalRegistration,
           case .externalVolume = preparedTargets[preparedDomain.domainIdentifier] {
            throw ExternalStorageLifecycleTestError.externalRegistrationFailed
        }
        registrations[preparedDomain.domainIdentifier] = Registration(
            configurationIdentifier: preparedDomain.configurationIdentifier,
            domainIdentifier: preparedDomain.domainIdentifier,
            displayName: preparedDomain.fileProviderDomain.displayName,
            volumeUUID: preparedDomain.volumeUUID
        )
        knownFolderStates[preparedDomain.domainIdentifier] = .inactive
    }

    func registeredDomainStates() async throws -> [ProviderRegisteredDomainState] {
        events.append(.refreshRegisteredDomains)
        return registrations.values.map { registration in
            ProviderRegisteredDomainState(
                configurationIdentifier: registration.configurationIdentifier,
                domainIdentifier: registration.domainIdentifier,
                displayName: registration.displayName,
                volumeUUID: registration.volumeUUID,
                isDisconnected: false,
                isUserEnabled: true,
                knownFolderSyncState: knownFolderStates[registration.domainIdentifier] ?? .inactive
            )
        }
    }

    func waitForStabilization(for configuration: ProviderDomainConfiguration) async throws {
        events.append(.stabilize(domainIdentifier: configuration.domainIdentifier))
    }

    func removeDomainPreservingDirtyUserData(
        for configuration: ProviderDomainConfiguration
    ) async throws -> URL? {
        events.append(.removePreservingData(domainIdentifier: configuration.domainIdentifier))
        registrations[configuration.domainIdentifier] = nil
        knownFolderStates[configuration.domainIdentifier] = nil
        return nil
    }

    func reconnectDomain(for configuration: ProviderDomainConfiguration) async throws {
        events.append(.reconnect(domainIdentifier: configuration.domainIdentifier))
    }

    func knownFolderSyncStates() async throws -> [String: ProviderKnownFolderSyncState] {
        events.append(.refreshKnownFolders)
        return knownFolderStates
    }

    func claimKnownFolders(
        for configuration: ProviderDomainConfiguration,
        parentFileID: Int
    ) async throws {
        events.append(.claim(
            domainIdentifier: configuration.domainIdentifier,
            parentFileID: parentFileID
        ))
        if failKnownFolderClaim {
            throw ExternalStorageLifecycleTestError.knownFolderClaimFailed
        }
        knownFolderStates[configuration.domainIdentifier] = .active
    }

    func releaseKnownFolders(for configuration: ProviderDomainConfiguration) async throws {
        events.append(.release(domainIdentifier: configuration.domainIdentifier))
        knownFolderStates[configuration.domainIdentifier] = .inactive
    }
}

private actor ExternalStorageLifecycleTokenStore: OAuthTokenStoring {
    private var tokens: [String: KDriveOAuthToken] = [:]

    func setToken(_ token: KDriveOAuthToken, accountIdentifier: String) {
        tokens[accountIdentifier] = token
    }

    func loadToken(accountIdentifier: String) throws -> KDriveOAuthToken? {
        tokens[accountIdentifier]
    }

    func saveToken(_ token: KDriveOAuthToken, accountIdentifier: String) throws {
        tokens[accountIdentifier] = token
    }

    func deleteToken(accountIdentifier: String) throws {
        tokens[accountIdentifier] = nil
    }

    func loadLegacyToken() throws -> KDriveOAuthToken? {
        nil
    }

    func deleteLegacyToken() throws {}
}

private actor ExternalStorageLifecycleSnapshotStore: KDriveSnapshotStoring {
    private(set) var removedDomainIdentifiers: [String] = []

    func snapshot(domainIdentifier: String, containerIdentifier: String) throws -> KDriveSnapshot? {
        nil
    }

    func item(domainIdentifier: String, fileID: Int) throws -> KDriveRemoteItem? {
        nil
    }

    func save(
        _ snapshot: KDriveSnapshot,
        domainIdentifier: String,
        containerIdentifier: String,
        condition: KDriveSnapshotSaveCondition
    ) throws {}

    func removeSnapshot(domainIdentifier: String, containerIdentifier: String) throws {}

    func removeSnapshots(domainIdentifier: String) throws {
        removedDomainIdentifiers.append(domainIdentifier)
    }
}

private actor ExternalStorageLifecycleEventStore: KDriveProviderEventStoring {
    private(set) var removedDomainIdentifiers: [String] = []

    func saveConflict(_ event: KDriveConflictEvent) throws {}

    func recordActivity(_ event: KDriveProviderActivityEvent) throws {}

    func recentConflicts(domainIdentifier: String?, limit: Int) throws -> [KDriveConflictEvent] {
        []
    }

    func recentActivity(
        domainIdentifier: String?,
        limit: Int
    ) throws -> [KDriveProviderActivityEvent] {
        []
    }

    func recentActivity(
        domainIdentifier: String?,
        outcome: KDriveProviderActivityOutcome?,
        limit: Int
    ) throws -> [KDriveProviderActivityEvent] {
        []
    }

    func removeActivityAndResolvedConflicts(domainIdentifier: String?) throws {}

    func removeEvents(domainIdentifier: String) throws {
        removedDomainIdentifiers.append(domainIdentifier)
    }
}

private struct ExternalStorageLifecycleRemote: KDriveFileProviding {
    static let privateDirectoryFileID = 77

    func listDrives() async throws -> [KDriveDriveSummary] {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func listDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveItemPage {
        KDriveItemPage(
            items: [KDriveRemoteItem(
                id: Self.privateDirectoryFileID,
                name: KDrivePrivateDirectoryResolver.directoryName,
                type: "dir",
                status: "ok",
                driveID: driveID,
                parentID: folderID,
                path: "/private",
                size: nil,
                mimeType: nil,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)
            )],
            nextCursor: nil,
            hasMore: false
        )
    }

    func listAdvancedDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveAdvancedItemPage {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func replaceFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func moveItem(
        driveID: Int,
        fileID: Int,
        destinationParentID: Int,
        name: String?
    ) async throws {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        throw ExternalStorageLifecycleTestError.unexpectedRemoteCall
    }
}

private enum ExternalStorageLifecycleTestError: LocalizedError {
    case externalRegistrationFailed
    case knownFolderClaimFailed
    case unexpectedRemoteCall

    var errorDescription: String? {
        switch self {
        case .externalRegistrationFailed:
            "The external domain registration failed."
        case .knownFolderClaimFailed:
            "The known-folder claim failed."
        case .unexpectedRemoteCall:
            "The test made an unexpected remote call."
        }
    }
}
#endif
