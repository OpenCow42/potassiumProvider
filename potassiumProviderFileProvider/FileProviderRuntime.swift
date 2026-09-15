import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

enum FileProviderLog {
    static let replicatedExtension = ProviderLog.fileProvider
    static let enumeration = ProviderLog.enumeration
    static let runtime = ProviderLog.runtime
}

struct FileProviderRuntime: Sendable {
    let configuration: ProviderDomainConfiguration
    let token: KDriveOAuthToken
    let remote: any KDriveFileProviding
    let actions: any KDriveContextActionProviding
    let workingSetRemote: any KDriveWorkingSetRemoteProviding
    let snapshotStore: any KDriveSnapshotStoring
    let workingSetStateStore: any KDriveWorkingSetStateStoring
    let eventStore: (any KDriveProviderEventStoring)?
    let encryptedVault: (any EncryptedVaultProviding)?

    private init(
        configuration: ProviderDomainConfiguration,
        token: KDriveOAuthToken,
        remote: any KDriveFileProviding,
        actions: any KDriveContextActionProviding,
        workingSetRemote: any KDriveWorkingSetRemoteProviding,
        snapshotStore: any KDriveSnapshotStoring,
        workingSetStateStore: any KDriveWorkingSetStateStoring,
        eventStore: (any KDriveProviderEventStoring)?,
        encryptedVault: (any EncryptedVaultProviding)?
    ) {
        self.configuration = configuration
        self.token = token
        self.remote = remote
        self.actions = actions
        self.workingSetRemote = workingSetRemote
        self.snapshotStore = snapshotStore
        self.workingSetStateStore = workingSetStateStore
        self.eventStore = eventStore
        self.encryptedVault = encryptedVault
    }

    static func load(domain: NSFileProviderDomain) async throws -> FileProviderRuntime {
        let eventStore = makeEventStore()
        let span = await ProviderDiagnosticSpan.start(
            source: .fileProviderExtension,
            operation: .runtimeLoad,
            recorder: eventStore as? any ProviderDiagnosticRecording
        )
        do {
            let runtime = try await loadRuntime(
                domain: domain,
                eventStore: eventStore
            )
            await span.complete(statusClass: .success)
            return runtime
        } catch {
            await span.fail(error: error)
            throw error
        }
    }

    private static func loadRuntime(
        domain: NSFileProviderDomain,
        eventStore: (any KDriveProviderEventStoring)?
    ) async throws -> FileProviderRuntime {
        FileProviderLog.runtime.debug("load runtime for domain(\(domain.identifier.rawValue, privacy: .public))")
        let configuration = try await loadConfiguration(domain: domain)
        let tokenStore = KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        guard var token = try await tokenStore.loadToken(accountIdentifier: configuration.accountIdentifier) else {
            FileProviderLog.runtime.error("missing OAuth token for domain(\(domain.identifier.rawValue, privacy: .public)); returning notAuthenticated")
            throw NSFileProviderError(.notAuthenticated)
        }

        if token.shouldRefresh() {
            FileProviderLog.runtime.info("refresh OAuth token for domain(\(domain.identifier.rawValue, privacy: .public)) driveID(\(configuration.driveID, privacy: .public))")
            guard let refreshToken = token.refreshToken else {
                FileProviderLog.runtime.error("OAuth token expired without refresh token for domain(\(domain.identifier.rawValue, privacy: .public)); returning notAuthenticated")
                throw NSFileProviderError(.notAuthenticated)
            }
            token = try await KDriveOAuthClient.refresh(refreshToken: refreshToken)
            try await tokenStore.saveToken(token, accountIdentifier: configuration.accountIdentifier)
            FileProviderLog.runtime.info("refreshed OAuth token for domain(\(domain.identifier.rawValue, privacy: .public))")
        }

        let sqliteStore = try makeSQLiteStore()
        let remote = PotassiumKDriveService(
            bearerToken: token.accessToken,
            diagnosticRecorder: eventStore as? any ProviderDiagnosticRecording,
            diagnosticSource: .fileProviderExtension
        )
        let encryptedVault: (any EncryptedVaultProviding)?
        if configuration.encryptionMode == .opaqueVaultV2 {
            guard let vaultConfiguration = configuration.vault,
                  vaultConfiguration.formatVersion == VaultFormat.currentVersion,
                  vaultConfiguration.remoteLayout != nil else {
                throw NSFileProviderError(.cannotSynchronize)
            }
            let keyStore = KeychainVaultKeyStore(
                accessGroup: ProviderConstants.keychainAccessGroup
            )
            let rootKey: VaultKeyMaterial
            do {
                guard let loadedKey = try await keyStore.loadRootKey(
                    vaultID: vaultConfiguration.vaultIdentifier
                ) else {
                    throw NSFileProviderError(.notAuthenticated)
                }
                rootKey = loadedKey
            } catch is NSFileProviderError {
                throw NSFileProviderError(.notAuthenticated)
            } catch VaultKeyStoreError.unhandledStatus {
                throw NSFileProviderError(.notAuthenticated)
            } catch {
                throw NSFileProviderError(.cannotSynchronize)
            }
            let deviceID = try await keyStore.loadOrCreateDeviceID(
                vaultID: vaultConfiguration.vaultIdentifier
            )
            let localStore = try VaultSQLiteStore(
                appGroupIdentifier: ProviderConstants.appGroupIdentifier,
                domainIdentifier: configuration.domainIdentifier,
                vaultID: vaultConfiguration.vaultIdentifier,
                rootKey: rootKey,
                keyEpoch: vaultConfiguration.keyEpoch
            )
            let objectStore = PotassiumKDriveObjectStore(
                driveID: configuration.driveID,
                bearerToken: token.accessToken
            )
            encryptedVault = try EncryptedVaultService(
                configuration: configuration,
                rootKey: rootKey,
                deviceID: deviceID,
                objectStore: objectStore,
                localStore: localStore,
                keyStore: keyStore
            )
        } else {
            encryptedVault = nil
        }
        FileProviderLog.runtime.debug("loaded runtime for domain(\(domain.identifier.rawValue, privacy: .public)) driveID(\(configuration.driveID, privacy: .public)) rootFileID(\(configuration.rootFileID, privacy: .public))")
        return FileProviderRuntime(
            configuration: configuration,
            token: token,
            remote: remote,
            actions: remote,
            workingSetRemote: remote,
            snapshotStore: sqliteStore,
            workingSetStateStore: sqliteStore,
            eventStore: eventStore,
            encryptedVault: encryptedVault
        )
    }

    static func loadConfiguration(domain: NSFileProviderDomain) async throws -> ProviderDomainConfiguration {
        FileProviderLog.runtime.debug("load configuration for domain(\(domain.identifier.rawValue, privacy: .public)) from app group")
        let configurationStore = try makeConfigurationStore(domain: domain)

        do {
            let configuration = try await resolveConfiguration(
                domain: domain,
                configurationStore: configurationStore
            )
            try validateSupportedConfiguration(configuration, domain: domain)
            FileProviderLog.runtime.debug("loaded configuration for domain(\(configuration.domainIdentifier, privacy: .public)) driveID(\(configuration.driveID, privacy: .public)) displayName(\(configuration.displayName, privacy: .private))")
            return configuration
        } catch let error as ExternalDomainBindingError {
            FileProviderLog.runtime.error("invalid local binding for domain(\(domain.identifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public); returning notAuthenticated")
            throw NSFileProviderError(.notAuthenticated)
        }
    }

    #if os(macOS)
    static func approveExternalDomainConnection(domain: NSFileProviderDomain) async throws {
        guard domain.volumeUUID != nil else {
            throw ExternalDomainBindingError.storageLocationMismatch
        }

        let configurationStore = try DomainConfigurationFileStore(
            appGroupIdentifier: ProviderConstants.appGroupIdentifier
        )
        let configuration = try await resolveConfiguration(
            domain: domain,
            configurationStore: configurationStore
        )
        try validateSupportedConfiguration(configuration, domain: domain)
        let tokenStore = KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        guard let token = try await tokenStore.loadToken(accountIdentifier: configuration.accountIdentifier),
              token.shouldRefresh() == false || token.refreshToken != nil
        else {
            throw ExternalDomainBindingError.missingCredentials
        }
    }
    #endif

    private static func resolveConfiguration(
        domain: NSFileProviderDomain,
        configurationStore: DomainConfigurationFileStore
    ) async throws -> ProviderDomainConfiguration {
        #if os(macOS)
        if ProviderExternalDomainUserInfoCodec.containsBinding(in: domain.userInfo) || domain.volumeUUID != nil {
            let binding: ProviderExternalDomainBinding
            do {
                binding = try ProviderExternalDomainUserInfoCodec.decode(domain.userInfo)
            } catch {
                throw ExternalDomainBindingError.invalidBinding
            }
            guard let configuration = try await configurationStore.configuration(
                configurationIdentifier: binding.configurationIdentifier
            ) else {
                throw ExternalDomainBindingError.missingConfiguration
            }
            guard configuration.domainIdentifier == domain.identifier.rawValue else {
                throw ExternalDomainBindingError.domainIdentifierMismatch
            }

            switch configuration.storageLocation {
            case .onThisMac:
                guard domain.volumeUUID == nil else {
                    throw ExternalDomainBindingError.storageLocationMismatch
                }
            case .externalVolume(let expectedVolumeUUID, _):
                guard let actualVolumeUUID = domain.volumeUUID else {
                    throw ExternalDomainBindingError.storageLocationMismatch
                }
                guard actualVolumeUUID == expectedVolumeUUID else {
                    throw ExternalDomainBindingError.volumeIdentifierMismatch
                }
            }
            return configuration
        }
        #endif

        guard let configuration = try await configurationStore.configuration(
            domainIdentifier: domain.identifier.rawValue
        ) else {
            throw ExternalDomainBindingError.missingConfiguration
        }
        return configuration
    }

    private static func validateSupportedConfiguration(
        _ configuration: ProviderDomainConfiguration,
        domain: NSFileProviderDomain
    ) throws {
        guard configuration.isCompatible(with: .current) else {
            FileProviderLog.runtime.error("domain purpose does not match this runtime profile; returning cannotSynchronize")
            throw NSFileProviderError(.cannotSynchronize)
        }
        guard configuration.encryptionMode != .opaqueVaultV1 else {
            FileProviderLog.runtime.error("unsupported experimental encrypted vault v1 for domain(\(domain.identifier.rawValue, privacy: .public)); returning cannotSynchronize")
            throw NSFileProviderError(.cannotSynchronize)
        }
        if case .externalVolume = configuration.storageLocation,
           configuration.supportsStorageRelocation == false {
            FileProviderLog.runtime.error("unsupported encrypted-vault external placement for domain(\(domain.identifier.rawValue, privacy: .public)); returning cannotSynchronize")
            throw NSFileProviderError(.cannotSynchronize)
        }
    }

    static func markMachineNamespaceLayout(domain: NSFileProviderDomain) async throws {
        let configurationStore = try makeConfigurationStore(domain: domain)
        guard var configuration = try await configurationStore.configuration(
            domainIdentifier: domain.identifier.rawValue
        ) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        guard configuration.knownFolderLayout != .machineNamespace else {
            return
        }
        configuration.knownFolderLayout = .machineNamespace
        configuration.updatedAt = Date()
        try await configurationStore.save(configuration)
    }

    static func makeSnapshotStore() throws -> any KDriveSnapshotStoring {
        try makeSQLiteStore()
    }

    static func makeWorkingSetStateStore() throws -> any KDriveWorkingSetStateStoring {
        try makeSQLiteStore()
    }

    private static func makeSQLiteStore() throws -> KDriveSnapshotSQLiteStore {
        do {
            return try KDriveSnapshotSQLiteStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier)
        } catch {
            FileProviderLog.runtime.error("failed to open snapshot store in app group: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    static func makeEventStore() -> (any KDriveProviderEventStoring)? {
        do {
            return try ProviderEventStoreFactory.makeDefault()
        } catch {
            FileProviderLog.runtime.error("failed to open provider event store in app group")
            return nil
        }
    }

    private static func makeConfigurationStore(
        domain: NSFileProviderDomain
    ) throws -> DomainConfigurationFileStore {
        do {
            return try DomainConfigurationFileStore(
                appGroupIdentifier: ProviderConstants.appGroupIdentifier
            )
        } catch {
            FileProviderLog.runtime.error("failed to open app group configuration store for domain(\(domain.identifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

private enum ExternalDomainBindingError: Error, Equatable, LocalizedError, Sendable {
    case invalidBinding
    case missingConfiguration
    case domainIdentifierMismatch
    case storageLocationMismatch
    case volumeIdentifierMismatch
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidBinding:
            return "The external File Provider domain has an invalid configuration binding."
        case .missingConfiguration:
            return "This Mac has no configuration for the external File Provider domain."
        case .domainIdentifierMismatch:
            return "The external File Provider domain does not match its local configuration."
        case .storageLocationMismatch:
            return "The File Provider domain storage location does not match its local configuration."
        case .volumeIdentifierMismatch:
            return "The external File Provider domain is on a different volume than its local configuration."
        case .missingCredentials:
            return "This Mac has no usable credentials for the external File Provider domain."
        }
    }
}

enum FileProviderPageCodec {
    static func cursor(from page: NSFileProviderPage) -> String? {
        let initialPageSortedByDate = NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
        let initialPageSortedByName = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        if page == initialPageSortedByDate || page == initialPageSortedByName {
            return nil
        }
        guard page.rawValue.isEmpty == false else { return nil }
        return String(data: page.rawValue, encoding: .utf8)
    }

    static func page(from cursor: String?) -> NSFileProviderPage? {
        guard let cursor, cursor.isEmpty == false else { return nil }
        return NSFileProviderPage(Data(cursor.utf8))
    }

    static func anchor() -> NSFileProviderSyncAnchor {
        anchor(from: UUID().uuidString)
    }

    static func anchor(from value: String) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(value.utf8))
    }

    static func anchorString(from anchor: NSFileProviderSyncAnchor) -> String? {
        guard anchor.rawValue.isEmpty == false else { return nil }
        return String(data: anchor.rawValue, encoding: .utf8)
    }
}

func signalRecoverableProviderErrorsResolved(for domain: NSFileProviderDomain) async {
    guard let manager = NSFileProviderManager(for: domain) else { return }
    let errorCodes: [NSFileProviderError.Code] = [
        .notAuthenticated,
        .insufficientQuota,
        .serverUnreachable,
        .cannotSynchronize,
    ]

    for code in errorCodes {
        let error = NSFileProviderError(code) as NSError
        await withCheckedContinuation { continuation in
            manager.signalErrorResolved(error) { signalError in
                if let signalError {
                    FileProviderLog.runtime.debug(
                        "could not signal resolved provider error code(\(error.code, privacy: .public)): \(signalError.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume()
            }
        }
    }
}
