import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@Suite(.serialized)
@MainActor
struct VaultUXAppModelTests {
    @Test func knownFolderPreflightRequiresUnlockAndBlocksUnsafeOwnership() {
        let external = KnownFolderPreflight(
            ownership: .externalProvider(displayName: "iCloud Drive"),
            vaultIsUnlocked: true,
            remoteIsReachable: true,
            availableQuotaBytes: nil
        )
        #expect(external.canRequestClaim)

        let legacy = KnownFolderPreflight(
            ownership: .legacyPotassium(domainIdentifier: "plaintext"),
            vaultIsUnlocked: true,
            remoteIsReachable: true,
            availableQuotaBytes: nil
        )
        #expect(legacy.canRequestClaim == false)

        let locked = KnownFolderPreflight(
            ownership: .none,
            vaultIsUnlocked: false,
            remoteIsReachable: true,
            availableQuotaBytes: nil
        )
        #expect(locked.canRequestClaim == false)
    }

    @Test func cloudAccessCanBeEnabledAndRemovedWithoutChangingDeviceKey() async throws {
        let context = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        await context.model.refreshVaultAccessState()

        #expect(
            context.model.localKeyStatus(for: context.configuration)
                == .available
        )
        #expect(
            context.model.cloudAccessStatus(for: context.configuration)
                == .disabled
        )

        await context.model.enableICloudKeychainAccess(
            for: context.configuration
        )
        #expect(
            try await context.cloudStore.record(vaultID: context.vaultID)?
                .rootKey == context.rootKey
        )
        #expect(
            try await context.keyStore.loadRootKey(vaultID: context.vaultID)
                == context.rootKey
        )

        await context.model.removeICloudKeychainAccess(
            for: context.configuration
        )
        #expect(
            try await context.cloudStore.record(vaultID: context.vaultID)
                == nil
        )
        #expect(
            try await context.keyStore.loadRootKey(vaultID: context.vaultID)
                == context.rootKey
        )
    }

    @Test func forgettingDeviceKeyNeverDeletesOrSilentlyImportsCloudRecord() async throws {
        let context = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let cloudRecord = try VaultCloudAccessRecord(
            configuration: try #require(context.configuration.vault),
            driveID: context.configuration.driveID,
            rootKey: context.rootKey
        )
        try await context.cloudStore.save(cloudRecord)

        await context.model.forgetVaultKey(
            for: context.configuration,
            recoveryKitConfirmation: context.recoveryKit.encoded
        )

        #expect(
            try await context.keyStore.loadRootKey(vaultID: context.vaultID)
                == nil
        )
        #expect(
            try await context.cloudStore.record(vaultID: context.vaultID)
                == cloudRecord
        )
        #expect(
            context.model.localKeyStatus(for: context.configuration) == .missing
        )
    }

    @Test func failedCloudPublicationKeepsRegisteredVaultAndRecoveryBoundary() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let account = ProviderAccount(
            accountIdentifier: "account",
            displayName: "Account",
            authenticationKind: .oauth
        )
        let drive = KDriveDriveSummary(
            id: 42,
            name: "Drive",
            accountID: 1,
            role: "admin",
            status: "active",
            isInMaintenance: false
        )
        let tokenStore = InMemoryOAuthTokenStore()
        try await tokenStore.saveToken(
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
        let keyStore = InMemoryVaultKeyStore()
        let objectStore = InMemoryOpaqueObjectStore()
        var currentUptime: TimeInterval = 1_000
        let model = PotassiumProviderAppModel(
            accountStore: ProviderAccountFileStore(
                directoryURL: directory.appendingPathComponent("Accounts")
            ),
            domainStore: DomainConfigurationFileStore(
                directoryURL: directory.appendingPathComponent("Domains")
            ),
            tokenStore: tokenStore,
            oauthAuthenticator: VaultUXOAuthAuthenticator(),
            domainRegistrar: VaultUXDomainRegistrar(),
            automaticallyReloadStoredState: false,
            initialAccounts: [account],
            initialDrivesByAccountIdentifier: [
                account.accountIdentifier: [drive],
            ],
            fileProviderFactory: { _ in VaultUXFileProvider() },
            objectStoreFactory: { _, _ in objectStore },
            vaultKeyStore: keyStore,
            vaultDeviceIdentityStore: VaultUXDeviceIdentityStore(),
            vaultCloudAccessStore: FailingVaultCloudAccessStore(),
            vaultUserPresenceAuthorizer: AllowVaultUserPresenceAuthorizer(),
            vaultUXDefaults: UserDefaults(
                suiteName: "VaultUXAppModelTests.\(UUID().uuidString)"
            ),
            encryptedVaultsEnabled: true,
            encryptedVaultICloudKeychainEnabled: true,
            currentUptime: { currentUptime }
        )

        await model.prepareEncryptedVault(
            accountIdentifier: account.accountIdentifier,
            drive: drive
        )
        #expect(model.vaultSetupStep == .unsupportedRiskWarning)
        #expect(model.pendingVaultProvisioning == nil)
        #expect(await objectStore.allTokens().isEmpty)

        await model.acceptEncryptedVaultRiskAndPrepare()
        #expect(model.vaultSetupStep == .unsupportedRiskWarning)
        #expect(model.pendingVaultProvisioning == nil)
        #expect(model.errorMessage?.contains("Wait five seconds") == true)
        #expect(await objectStore.allTokens().isEmpty)

        currentUptime += 4.999
        await model.acceptEncryptedVaultRiskAndPrepare()
        #expect(model.vaultSetupStep == .unsupportedRiskWarning)
        #expect(model.pendingVaultProvisioning == nil)
        #expect(await objectStore.allTokens().isEmpty)

        currentUptime += 0.001
        await model.acceptEncryptedVaultRiskAndPrepare()
        #expect(model.vaultSetupStep == .overview)
        let pending = try #require(model.pendingVaultProvisioning)
        #expect(
            try await keyStore.loadRootKey(vaultID: pending.vaultID) == nil
        )

        await model.confirmEncryptedVault(
            recoveryKitConfirmation: pending.recoveryKit.encoded,
            useICloudKeychain: true
        )

        let registered = try #require(model.domains.first)
        #expect(registered.vault?.vaultIdentifier == pending.vaultID)
        #expect(model.pendingVaultProvisioning == nil)
        #expect(model.vaultSetupOutcome.cloudAccessStatus == .unavailable)
        #expect(model.vaultSetupOutcome.recoveryKitVerified)
        #if os(macOS)
        #expect(model.vaultSetupStep == .desktopDocuments)
        #expect(model.vaultSetupNeedsAttention(for: registered))
        model.finishVaultSetup()
        model.resumeVaultSetup(for: registered)
        #expect(model.vaultSetupStep == .desktopDocuments)
        await model.configureDesktopDocumentsDuringSetup(enable: false)
        await model.refreshVaultAccessState()
        #expect(model.vaultSetupNeedsAttention(for: registered) == false)
        #else
        #expect(model.vaultSetupStep == .complete)
        #expect(model.vaultSetupNeedsAttention(for: registered) == false)
        #endif
        #expect(
            try await keyStore.loadRootKey(vaultID: pending.vaultID)
                == pending.rootKey
        )
        #expect(model.errorMessage == nil)
    }

    @Test func recoveryAndICloudOpenCannotBypassRiskDelay() async throws {
        var currentUptime: TimeInterval = 2_000
        let context = try await makeContext(currentUptime: { currentUptime })
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let drive = KDriveDriveSummary(
            id: context.configuration.driveID,
            name: context.configuration.driveName,
            accountID: 1,
            role: "admin",
            status: "active",
            isInMaintenance: false
        )
        let initialTokens = await context.objectStore.allTokens()

        context.model.prepareOpenEncryptedVault(
            accountIdentifier: context.configuration.accountIdentifier,
            drive: drive,
            recoveryKitText: context.recoveryKit.encoded
        )
        #expect(context.model.vaultSetupStep == .unsupportedRiskWarning)
        await context.model.acceptEncryptedVaultRiskAndPrepare()
        #expect(context.model.vaultSetupStep == .unsupportedRiskWarning)
        #expect(await context.objectStore.allTokens() == initialTokens)
        context.model.finishVaultSetup()

        context.model.prepareOpenEncryptedVaultFromICloud(
            accountIdentifier: context.configuration.accountIdentifier,
            drive: drive,
            vaultID: context.vaultID
        )
        #expect(context.model.vaultSetupStep == .unsupportedRiskWarning)
        currentUptime += 4.999
        await context.model.acceptEncryptedVaultRiskAndPrepare()
        #expect(context.model.vaultSetupStep == .unsupportedRiskWarning)
        #expect(context.authorizer.authorizationCount == 0)
        #expect(await context.objectStore.allTokens() == initialTokens)
    }

    @Test func iCloudConvenienceGateCannotBypassDisabledVaultGate() async throws {
        let context = try await makeContext(encryptedVaultsEnabled: false)
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let drive = KDriveDriveSummary(
            id: context.configuration.driveID,
            name: context.configuration.driveName,
            accountID: 1,
            role: "admin",
            status: "active",
            isInMaintenance: false
        )

        context.model.prepareOpenEncryptedVaultFromICloud(
            accountIdentifier: context.configuration.accountIdentifier,
            drive: drive,
            vaultID: context.vaultID
        )

        #expect(context.model.vaultSetupStep == nil)
        #expect(context.model.errorMessage?.contains("Encrypted vaults are disabled") == true)
        #expect(context.authorizer.authorizationCount == 0)
    }

    @Test func reloadDoesNotReactivateAnUnsupportedV1Domain() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let domainStore = DomainConfigurationFileStore(
            directoryURL: directory.appendingPathComponent("Domains")
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "unsupported-v1-domain",
            accountIdentifier: "account",
            displayName: "Unsupported",
            driveID: 42,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV1,
            vault: ProviderVaultConfiguration(
                vaultIdentifier: VaultIdentifier(),
                vaultRootFileID: 100,
                vaultHeaderFileID: 101,
                formatVersion: 1
            )
        )
        try await domainStore.save(configuration)
        let registrar = RecordingVaultUXDomainRegistrar()
        let model = PotassiumProviderAppModel(
            accountStore: ProviderAccountFileStore(
                directoryURL: directory.appendingPathComponent("Accounts")
            ),
            domainStore: domainStore,
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: VaultUXOAuthAuthenticator(),
            domainRegistrar: registrar,
            automaticallyReloadStoredState: false,
            fileProviderFactory: { _ in VaultUXFileProvider() },
            vaultKeyStore: InMemoryVaultKeyStore(),
            vaultDeviceIdentityStore: VaultUXDeviceIdentityStore(),
            vaultCloudAccessStore: InMemoryVaultCloudAccessStore(),
            vaultUserPresenceAuthorizer: AllowVaultUserPresenceAuthorizer(),
            vaultUXDefaults: UserDefaults(
                suiteName: "VaultUXAppModelTests.\(UUID().uuidString)"
            )
        )

        await model.reloadStoredState()

        #expect(registrar.addedDomainIdentifiers.isEmpty)
        #expect(model.domains.map(\.domainIdentifier) == [configuration.domainIdentifier])
    }

    private func makeContext(
        encryptedVaultsEnabled: Bool = true,
        currentUptime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) async throws -> VaultUXContext {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let keyStore = InMemoryVaultKeyStore()
        let objectStore = InMemoryOpaqueObjectStore()
        let provisioning = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await provisioning.prepareNewVault(driveID: 42)
        let vault = try await provisioning.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "encrypted-domain",
            accountIdentifier: "account",
            displayName: "Encrypted",
            driveID: 42,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: vault
        )
        let cloudStore = InMemoryVaultCloudAccessStore()
        let authorizer = CountingVaultUserPresenceAuthorizer()
        let tokenStore = InMemoryOAuthTokenStore()
        try await tokenStore.saveToken(
            KDriveOAuthToken(
                accessToken: "test-token",
                tokenType: "Bearer",
                refreshToken: nil,
                scope: nil,
                idToken: nil,
                expiresAt: nil
            ),
            accountIdentifier: configuration.accountIdentifier
        )
        let model = PotassiumProviderAppModel(
            accountStore: ProviderAccountFileStore(
                directoryURL: directory.appendingPathComponent("Accounts")
            ),
            domainStore: DomainConfigurationFileStore(
                directoryURL: directory.appendingPathComponent("Domains")
            ),
            tokenStore: tokenStore,
            oauthAuthenticator: VaultUXOAuthAuthenticator(),
            domainRegistrar: VaultUXDomainRegistrar(),
            automaticallyReloadStoredState: false,
            initialAccounts: [
                ProviderAccount(
                    accountIdentifier: configuration.accountIdentifier,
                    displayName: "Account",
                    authenticationKind: .oauth
                ),
            ],
            initialDomains: [configuration],
            fileProviderFactory: { _ in VaultUXFileProvider() },
            objectStoreFactory: { _, _ in objectStore },
            vaultKeyStore: keyStore,
            vaultDeviceIdentityStore: VaultUXDeviceIdentityStore(),
            vaultCloudAccessStore: cloudStore,
            vaultUserPresenceAuthorizer: authorizer,
            vaultUXDefaults: UserDefaults(
                suiteName: "VaultUXAppModelTests.\(UUID().uuidString)"
            ),
            encryptedVaultsEnabled: encryptedVaultsEnabled,
            encryptedVaultICloudKeychainEnabled: true,
            currentUptime: currentUptime
        )
        return VaultUXContext(
            directory: directory,
            model: model,
            configuration: configuration,
            vaultID: pending.vaultID,
            rootKey: pending.rootKey,
            recoveryKit: pending.recoveryKit,
            keyStore: keyStore,
            cloudStore: cloudStore,
            objectStore: objectStore,
            authorizer: authorizer
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "VaultUXAppModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct VaultUXContext {
    let directory: URL
    let model: PotassiumProviderAppModel
    let configuration: ProviderDomainConfiguration
    let vaultID: VaultIdentifier
    let rootKey: VaultKeyMaterial
    let recoveryKit: VaultRecoveryKit
    let keyStore: InMemoryVaultKeyStore
    let cloudStore: InMemoryVaultCloudAccessStore
    let objectStore: InMemoryOpaqueObjectStore
    let authorizer: CountingVaultUserPresenceAuthorizer
}

@MainActor
private struct AllowVaultUserPresenceAuthorizer:
    VaultUserPresenceAuthorizing
{
    func authorize(reason: String) async throws {}
}

@MainActor
private final class CountingVaultUserPresenceAuthorizer:
    VaultUserPresenceAuthorizing
{
    private(set) var authorizationCount = 0

    func authorize(reason: String) async throws {
        authorizationCount += 1
    }
}

private actor VaultUXDeviceIdentityStore: VaultDeviceIdentityStoring {
    func loadOrCreateDeviceID(vaultID: VaultIdentifier) -> UUID {
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    }
}

private actor FailingVaultCloudAccessStore: VaultCloudAccessStoring {
    func records() -> [VaultCloudAccessRecord] { [] }
    func record(vaultID: VaultIdentifier) -> VaultCloudAccessRecord? { nil }
    func save(_ record: VaultCloudAccessRecord) throws {
        throw VaultUXTestError.cloudUnavailable
    }
    func delete(vaultID: VaultIdentifier) {}
}

@MainActor
private struct VaultUXDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {}
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}

@MainActor
private final class RecordingVaultUXDomainRegistrar: ProviderDomainRegistering {
    private(set) var addedDomainIdentifiers: [String] = []

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        addedDomainIdentifiers.append(configuration.domainIdentifier)
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}

private final class VaultUXOAuthAuthenticator: KDriveOAuthAuthenticating {
    func authenticate() async throws -> KDriveOAuthToken {
        throw VaultUXTestError.unsupported
    }
}

private actor VaultUXFileProvider: KDriveFileProviding {
    func listDrives() async throws -> [KDriveDriveSummary] { [] }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        throw VaultUXTestError.unsupported
    }

    func listDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveItemPage {
        throw VaultUXTestError.unsupported
    }

    func listAdvancedDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveAdvancedItemPage {
        throw VaultUXTestError.unsupported
    }

    func listTrash(
        driveID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveItemPage {
        throw VaultUXTestError.unsupported
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        throw VaultUXTestError.unsupported
    }

    func thumbnail(
        driveID: Int,
        fileID: Int,
        width: Int?,
        height: Int?
    ) async throws -> Data {
        throw VaultUXTestError.unsupported
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
        throw VaultUXTestError.unsupported
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
        throw VaultUXTestError.unsupported
    }

    func createDirectory(
        driveID: Int,
        parentID: Int,
        name: String
    ) async throws -> KDriveRemoteItem {
        throw VaultUXTestError.unsupported
    }

    func renameItem(
        driveID: Int,
        fileID: Int,
        name: String
    ) async throws {
        throw VaultUXTestError.unsupported
    }

    func moveItem(
        driveID: Int,
        fileID: Int,
        destinationParentID: Int,
        name: String?
    ) async throws {
        throw VaultUXTestError.unsupported
    }

    func updateModificationDate(
        driveID: Int,
        fileID: Int,
        date: Date
    ) async throws {
        throw VaultUXTestError.unsupported
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        throw VaultUXTestError.unsupported
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        throw VaultUXTestError.unsupported
    }
}

private enum VaultUXTestError: Error {
    case cloudUnavailable
    case unsupported
}
