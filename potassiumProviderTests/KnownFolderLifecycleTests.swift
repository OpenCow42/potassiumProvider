#if os(macOS)
import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@Suite(.serialized)
@MainActor
struct KnownFolderLifecycleTests {
    @Test func enablingSyncClaimsDesktopAndDocumentsUnderMacNamespace() async throws {
        let registrar = RecordingKnownFolderRegistrar(state: .inactive)
        try await withContext(registrar: registrar) { context in
            registrar.resetEvents()

            await context.model.enableKnownFolderSync(for: context.configuration)

            #expect(registrar.events == [
                .claim(domainIdentifier: context.configuration.domainIdentifier, parentFileID: 88),
                .refreshStates,
            ])
            #expect(context.model.knownFolderSyncState(for: context.configuration) == .active)
            #expect(context.model.isChangingKnownFolderSync(for: context.configuration) == false)
            #expect(context.model.errorMessage == nil)
            #expect(context.model.statusMessage?.contains("kDrive /Private/Studio Mac") == true)
            let storedConfiguration = try #require(
                try await context.domainStore.configuration(
                    domainIdentifier: context.configuration.domainIdentifier
                )
            )
            #expect(storedConfiguration.knownFolderLayout == .machineNamespace)
        }
    }

    @Test func disablingSyncReleasesKnownFoldersAndRefreshesState() async throws {
        let registrar = RecordingKnownFolderRegistrar(state: .active)
        try await withContext(registrar: registrar) { context in
            #expect(context.model.knownFolderRemotePath(for: context.configuration) == "/Private")
            registrar.resetEvents()

            await context.model.disableKnownFolderSync(for: context.configuration)

            #expect(registrar.events == [
                .release(domainIdentifier: context.configuration.domainIdentifier),
                .refreshStates,
            ])
            #expect(context.model.knownFolderSyncState(for: context.configuration) == .inactive)
            #expect(
                context.model.knownFolderRemotePath(for: context.configuration)
                    == "/Private/Studio Mac"
            )
            #expect(context.model.isChangingKnownFolderSync(for: context.configuration) == false)
            #expect(context.model.errorMessage == nil)
        }
    }

    @Test func failedClaimRestoresLegacyLayoutMarker() async throws {
        let registrar = RecordingKnownFolderRegistrar(
            state: .inactive,
            claimError: KnownFolderLifecycleTestError.claimFailed
        )
        try await withContext(registrar: registrar) { context in
            await context.model.enableKnownFolderSync(for: context.configuration)

            let storedConfiguration = try #require(
                try await context.domainStore.configuration(
                    domainIdentifier: context.configuration.domainIdentifier
                )
            )
            #expect(storedConfiguration.knownFolderLayout == .legacyPrivate)
            #expect(context.model.domains.first?.knownFolderLayout == .legacyPrivate)
            #expect(context.model.knownFolderSyncState(for: context.configuration) == .inactive)
            #expect(context.model.errorMessage?.contains("Could not sync") == true)
        }
    }

    @Test func removingActiveDomainReleasesKnownFoldersBeforeRemovingDomain() async throws {
        let registrar = RecordingKnownFolderRegistrar(state: .active)
        try await withContext(registrar: registrar) { context in
            registrar.resetEvents()

            await context.model.removeDomain(context.configuration)

            let releaseIndex = try #require(registrar.events.firstIndex(of: .release(
                domainIdentifier: context.configuration.domainIdentifier
            )))
            let removalIndex = try #require(registrar.events.firstIndex(of: .remove(
                domainIdentifier: context.configuration.domainIdentifier
            )))
            #expect(releaseIndex < removalIndex)
            #expect(context.model.domains.isEmpty)
            #expect(try await context.domainStore.configuration(
                domainIdentifier: context.configuration.domainIdentifier
            ) == nil)
        }
    }

    @Test func releaseFailureAbortsDomainRemovalAndPreservesConfiguration() async throws {
        let registrar = RecordingKnownFolderRegistrar(
            state: .active,
            releaseError: KnownFolderLifecycleTestError.releaseFailed
        )
        try await withContext(registrar: registrar) { context in
            registrar.resetEvents()

            await context.model.removeDomain(context.configuration)

            #expect(registrar.events.contains(.release(
                domainIdentifier: context.configuration.domainIdentifier
            )))
            #expect(registrar.events.contains(.remove(
                domainIdentifier: context.configuration.domainIdentifier
            )) == false)
            #expect(context.model.domains.map(\.domainIdentifier) == [
                context.configuration.domainIdentifier,
            ])
            let storedConfiguration = try #require(try await context.domainStore.configuration(
                domainIdentifier: context.configuration.domainIdentifier
            ))
            #expect(storedConfiguration.domainIdentifier == context.configuration.domainIdentifier)
            #expect(storedConfiguration.driveID == context.configuration.driveID)
            #expect(context.model.knownFolderSyncState(for: context.configuration) == .active)
            #expect(context.model.errorMessage?.contains("Could not remove the provider domain") == true)
        }
    }

    @Test func releaseFailureAbortsLogoutAndPreservesAccountTokenAndDomain() async throws {
        let registrar = RecordingKnownFolderRegistrar(
            state: .active,
            releaseError: KnownFolderLifecycleTestError.releaseFailed
        )
        try await withContext(registrar: registrar) { context in
            registrar.resetEvents()

            await context.model.logoutAccount(context.account)

            #expect(registrar.events.contains(.release(
                domainIdentifier: context.configuration.domainIdentifier
            )))
            #expect(registrar.events.contains(.remove(
                domainIdentifier: context.configuration.domainIdentifier
            )) == false)
            let storedAccount = try #require(try await context.accountStore.account(
                accountIdentifier: context.account.accountIdentifier
            ))
            #expect(storedAccount.accountIdentifier == context.account.accountIdentifier)
            #expect(storedAccount.displayName == context.account.displayName)
            #expect(await context.tokenStore.loadToken(
                accountIdentifier: context.account.accountIdentifier
            )?.accessToken == "test-token")
            let storedConfiguration = try #require(try await context.domainStore.configuration(
                domainIdentifier: context.configuration.domainIdentifier
            ))
            #expect(storedConfiguration.domainIdentifier == context.configuration.domainIdentifier)
            #expect(storedConfiguration.driveID == context.configuration.driveID)
            #expect(context.model.accounts.map(\.accountIdentifier) == [context.account.accountIdentifier])
            #expect(context.model.domains.map(\.domainIdentifier) == [
                context.configuration.domainIdentifier,
            ])
            #expect(context.model.errorMessage?.contains("Could not log out") == true)
        }
    }

    private func withContext(
        registrar: RecordingKnownFolderRegistrar,
        operation: @MainActor (KnownFolderLifecycleContext) async throws -> Void
    ) async throws {
        let directory = try await performWithContext(
            registrar: registrar,
            operation: operation
        )
        try? FileManager.default.removeItem(at: directory)
    }

    private func performWithContext(
        registrar: RecordingKnownFolderRegistrar,
        operation: @MainActor (KnownFolderLifecycleContext) async throws -> Void
    ) async throws -> URL {
        let context = try await makeContext(registrar: registrar)
        try await operation(context)
        return context.directory
    }

    private func makeContext(
        registrar: RecordingKnownFolderRegistrar
    ) async throws -> KnownFolderLifecycleContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-folder-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let accountStore = ProviderAccountFileStore(
            directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true)
        )
        let domainStore = DomainConfigurationFileStore(
            directoryURL: directory.appendingPathComponent("Domains", isDirectory: true)
        )
        let tokenStore = InMemoryOAuthTokenStore()
        let account = ProviderAccount(
            accountIdentifier: "account-1",
            displayName: "Test Account",
            authenticationKind: .manualAccessToken
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "domain-1",
            accountIdentifier: account.accountIdentifier,
            displayName: "Test Drive",
            driveID: 42,
            driveName: "Test Drive",
            rootFileID: 1,
            knownFolderLayout: .legacyPrivate
        )
        try await accountStore.save(account)
        try await domainStore.save(configuration)
        await tokenStore.saveToken(
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

        let databaseURL = directory.appendingPathComponent("Provider.sqlite3")
        let snapshotStore = try KDriveSnapshotSQLiteStore(databaseURL: databaseURL)
        let eventStore = try KDriveProviderEventSQLiteStore(databaseURL: databaseURL)
        let remote = KnownFolderLifecycleRemote(privateDirectoryFileID: 77)
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: domainStore,
            tokenStore: tokenStore,
            domainRegistrar: registrar,
            snapshotStore: snapshotStore,
            eventStore: eventStore,
            automaticallyReloadStoredState: false,
            fileProviderFactory: { _ in remote },
            computerNameProvider: { "Studio Mac" }
        )
        await model.reloadStoredState()
        #expect(model.knownFolderSyncState(for: configuration) == registrar.state)

        return KnownFolderLifecycleContext(
            directory: directory,
            account: account,
            accountStore: accountStore,
            configuration: configuration,
            domainStore: domainStore,
            tokenStore: tokenStore,
            model: model
        )
    }
}

@MainActor
private struct KnownFolderLifecycleContext {
    let directory: URL
    let account: ProviderAccount
    let accountStore: ProviderAccountFileStore
    let configuration: ProviderDomainConfiguration
    let domainStore: DomainConfigurationFileStore
    let tokenStore: InMemoryOAuthTokenStore
    let model: PotassiumProviderAppModel
}

@MainActor
private final class RecordingKnownFolderRegistrar: ProviderDomainRegistering {
    enum Event: Equatable {
        case add(domainIdentifier: String)
        case refreshStates
        case claim(domainIdentifier: String, parentFileID: Int)
        case release(domainIdentifier: String)
        case remove(domainIdentifier: String)
    }

    private(set) var events: [Event] = []
    private(set) var state: ProviderKnownFolderSyncState
    private let claimError: Error?
    private let releaseError: Error?

    init(
        state: ProviderKnownFolderSyncState,
        claimError: Error? = nil,
        releaseError: Error? = nil
    ) {
        self.state = state
        self.claimError = claimError
        self.releaseError = releaseError
    }

    func resetEvents() {
        events = []
    }

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        events.append(.add(domainIdentifier: configuration.domainIdentifier))
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {
        events.append(.remove(domainIdentifier: configuration.domainIdentifier))
    }

    func knownFolderSyncStates() async throws -> [String: ProviderKnownFolderSyncState] {
        events.append(.refreshStates)
        return ["domain-1": state]
    }

    func claimKnownFolders(
        for configuration: ProviderDomainConfiguration,
        parentFileID: Int
    ) async throws {
        events.append(.claim(
            domainIdentifier: configuration.domainIdentifier,
            parentFileID: parentFileID
        ))
        if let claimError {
            throw claimError
        }
        state = .active
    }

    func releaseKnownFolders(for configuration: ProviderDomainConfiguration) async throws {
        events.append(.release(domainIdentifier: configuration.domainIdentifier))
        if let releaseError {
            throw releaseError
        }
        state = .inactive
    }
}

private enum KnownFolderLifecycleTestError: LocalizedError {
    case claimFailed
    case releaseFailed

    var errorDescription: String? {
        switch self {
        case .claimFailed:
            "The test claim failed."
        case .releaseFailed:
            "The test release failed."
        }
    }
}

private struct KnownFolderLifecycleRemote: KDriveFileProviding {
    let privateDirectoryFileID: Int

    func listDrives() async throws -> [KDriveDriveSummary] {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func listDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveItemPage {
        let items: [KDriveRemoteItem]
        if folderID == 1 {
            items = [remoteItem(
                id: privateDirectoryFileID,
                name: KDrivePrivateDirectoryResolver.directoryName,
                driveID: driveID,
                parentID: folderID,
                path: "/Private"
            )]
        } else {
            items = []
        }
        return KDriveItemPage(items: items, nextCursor: nil, hasMore: false)
    }

    func listAdvancedDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveAdvancedItemPage {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data {
        throw KnownFolderLifecycleTestError.releaseFailed
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
        throw KnownFolderLifecycleTestError.releaseFailed
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
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        remoteItem(
            id: 88,
            name: name,
            driveID: driveID,
            parentID: parentID,
            path: "/Private/\(name)"
        )
    }

    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func updateModificationDate(driveID: Int, fileID: Int, date: Date) async throws {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        throw KnownFolderLifecycleTestError.releaseFailed
    }

    private func remoteItem(
        id: Int,
        name: String,
        driveID: Int,
        parentID: Int,
        path: String
    ) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name,
            type: "dir",
            status: "ok",
            driveID: driveID,
            parentID: parentID,
            path: path,
            size: nil,
            mimeType: nil,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
#endif
