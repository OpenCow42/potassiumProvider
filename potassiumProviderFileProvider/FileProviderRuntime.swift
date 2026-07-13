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
    let workingSetRemote: any KDriveWorkingSetRemoteProviding
    let snapshotStore: any KDriveSnapshotStoring
    let workingSetStateStore: any KDriveWorkingSetStateStoring
    let eventStore: (any KDriveProviderEventStoring)?

    private init(
        configuration: ProviderDomainConfiguration,
        token: KDriveOAuthToken,
        remote: any KDriveFileProviding,
        workingSetRemote: any KDriveWorkingSetRemoteProviding,
        snapshotStore: any KDriveSnapshotStoring,
        workingSetStateStore: any KDriveWorkingSetStateStoring,
        eventStore: (any KDriveProviderEventStoring)?
    ) {
        self.configuration = configuration
        self.token = token
        self.remote = remote
        self.workingSetRemote = workingSetRemote
        self.snapshotStore = snapshotStore
        self.workingSetStateStore = workingSetStateStore
        self.eventStore = eventStore
    }

    static func load(domain: NSFileProviderDomain) async throws -> FileProviderRuntime {
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
        let remote = PotassiumKDriveService(bearerToken: token.accessToken)
        FileProviderLog.runtime.debug("loaded runtime for domain(\(domain.identifier.rawValue, privacy: .public)) driveID(\(configuration.driveID, privacy: .public)) rootFileID(\(configuration.rootFileID, privacy: .public))")
        return FileProviderRuntime(
            configuration: configuration,
            token: token,
            remote: remote,
            workingSetRemote: remote,
            snapshotStore: sqliteStore,
            workingSetStateStore: sqliteStore,
            eventStore: makeEventStore()
        )
    }

    static func loadConfiguration(domain: NSFileProviderDomain) async throws -> ProviderDomainConfiguration {
        FileProviderLog.runtime.debug("load configuration for domain(\(domain.identifier.rawValue, privacy: .public)) from app group")
        let configurationStore: DomainConfigurationFileStore
        do {
            configurationStore = try DomainConfigurationFileStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier)
        } catch {
            FileProviderLog.runtime.error("failed to open app group configuration store for domain(\(domain.identifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        guard let configuration = try await configurationStore.configuration(domainIdentifier: domain.identifier.rawValue) else {
            FileProviderLog.runtime.error("missing configuration for domain(\(domain.identifier.rawValue, privacy: .public)); returning notAuthenticated")
            throw NSFileProviderError(.notAuthenticated)
        }
        FileProviderLog.runtime.debug("loaded configuration for domain(\(configuration.domainIdentifier, privacy: .public)) driveID(\(configuration.driveID, privacy: .public)) displayName(\(configuration.displayName, privacy: .private))")
        return configuration
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
            return try KDriveProviderEventSQLiteStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier)
        } catch {
            FileProviderLog.runtime.error("failed to open provider event store in app group: \(error.localizedDescription, privacy: .public)")
            return nil
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

struct ProviderErrorMapping {
    let mappedError: Error
    let diagnostic: KDriveProviderActivityErrorDiagnostic
}

func providerErrorMapping(_ error: Error) -> ProviderErrorMapping {
    if let fileProviderError = error as? NSFileProviderError {
        let nsError = fileProviderError as NSError
        FileProviderLog.runtime.debug("preserve FileProvider error code(\(nsError.code, privacy: .public)): \(nsError.localizedDescription, privacy: .public)")
        return ProviderErrorMapping(
            mappedError: fileProviderError,
            diagnostic: providerDiagnostic(
                category: providerActivityErrorCategory(originalError: nsError),
                originalError: error,
                mappedError: fileProviderError
            )
        )
    }

    if let apiRejection = KDriveRemoteErrorClassifier.apiRejection(from: error) {
        let mappedError = fileProviderError(for: apiRejection.recovery)
        let mappedNSError = mappedError as NSError
        FileProviderLog.runtime.error("map API rejection HTTP \(apiRejection.statusCode, privacy: .public) to \(mappedNSError.domain, privacy: .public) code(\(mappedNSError.code, privacy: .public))")
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .api,
                originalError: error,
                mappedError: mappedError,
                diagnosticSummary: apiRejection.diagnosticSummary
            )
        )
    }

    if let mutationConflictError = error as? KDriveMutationConflictError {
        switch mutationConflictError {
        case .staleVersion:
            FileProviderLog.runtime.error("map stale mutation version to cannotSynchronize: \(error.localizedDescription, privacy: .public)")
            let mappedError = staleMutationVersionError()
            return ProviderErrorMapping(
                mappedError: mappedError,
                diagnostic: providerDiagnostic(
                    category: .mutationConflict,
                    originalError: error,
                    mappedError: mappedError
                )
            )
        }
    }

    if error is KDriveListingValidationError {
        FileProviderLog.runtime.error("map listing validation failure to cannotSynchronize: \(error.localizedDescription, privacy: .public)")
        let mappedError = NSFileProviderError(.cannotSynchronize)
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .listing,
                originalError: error,
                mappedError: mappedError
            )
        )
    }

    if let snapshotStoreError = error as? KDriveSnapshotStoreError,
       case .staleSnapshot = snapshotStoreError {
        FileProviderLog.runtime.error("map stale snapshot write to cannotSynchronize: \(error.localizedDescription, privacy: .public)")
        let mappedError = NSFileProviderError(.cannotSynchronize)
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .snapshot,
                originalError: error,
                mappedError: mappedError
            )
        )
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        FileProviderLog.runtime.error("map URL error \(nsError.code, privacy: .public) to serverUnreachable: \(nsError.localizedDescription, privacy: .public)")
        let mappedError = NSFileProviderError(.serverUnreachable)
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .network,
                originalError: error,
                mappedError: mappedError
            )
        )
    }

    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSFileProviderErrorDomain {
        FileProviderLog.runtime.error("preserve Cocoa/FileProvider error \(nsError.domain, privacy: .public) code(\(nsError.code, privacy: .public)): \(nsError.localizedDescription, privacy: .public)")
        return ProviderErrorMapping(
            mappedError: error,
            diagnostic: providerDiagnostic(
                category: providerActivityErrorCategory(originalError: nsError),
                originalError: error,
                mappedError: error
            )
        )
    }

    FileProviderLog.runtime.error("wrap unexpected error as XPC reply invalid: \(error.localizedDescription, privacy: .public)")
    let mappedError = NSError(
        domain: NSCocoaErrorDomain,
        code: NSXPCConnectionReplyInvalid,
        userInfo: [NSUnderlyingErrorKey: error]
    )
    return ProviderErrorMapping(
        mappedError: mappedError,
        diagnostic: providerDiagnostic(
            category: providerActivityErrorCategory(originalError: nsError),
            originalError: error,
            mappedError: mappedError
        )
    )
}

func providerError(_ error: Error) -> Error {
    providerErrorMapping(error).mappedError
}

func shouldRecordGenericFailure(for error: Error) -> Bool {
    if error is CancellationError { return false }
    if error is KDriveMutationConflictError { return false }

    let nsError = error as NSError
    return nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError
}

func providerActivityKindForRuntimeLoadFailure(_ error: Error) -> KDriveProviderActivityKind {
    let nsError = error as NSError
    if nsError.domain == NSFileProviderErrorDomain,
       nsError.code == NSFileProviderError.notAuthenticated.rawValue {
        return .authentication
    }
    if let apiRejection = KDriveRemoteErrorClassifier.apiRejection(from: error),
       apiRejection.recovery == .notAuthenticated {
        return .authentication
    }
    if error is KDriveOAuthError || error is KeychainTokenStoreError {
        return .authentication
    }
    return .runtimeLoading
}

private func providerDiagnostic(
    category: KDriveProviderActivityErrorCategory,
    originalError: Error,
    mappedError: Error,
    diagnosticSummary: String? = nil
) -> KDriveProviderActivityErrorDiagnostic {
    let originalNSError = originalError as NSError
    let mappedNSError = mappedError as NSError
    let providerCode = mappedNSError.domain == NSFileProviderErrorDomain ? mappedNSError.code : nil
    let recoverySuggestion = mappedNSError.localizedRecoverySuggestion
        ?? (originalError as? LocalizedError)?.recoverySuggestion

    return KDriveProviderActivityErrorDiagnostic(
        errorCategory: category,
        providerErrorCode: providerCode,
        underlyingErrorDomain: originalNSError.domain,
        underlyingErrorCode: originalNSError.code,
        recoverySuggestion: recoverySuggestion,
        diagnosticSummary: diagnosticSummary ?? providerDiagnosticSummary(category: category)
    )
}

private func fileProviderError(for recovery: KDriveRemoteAPIRejectionRecovery) -> Error {
    switch recovery {
    case .notAuthenticated:
        return NSFileProviderError(.notAuthenticated)
    case .serverUnreachable:
        return NSFileProviderError(.serverUnreachable)
    case .insufficientQuota:
        return NSFileProviderError(.insufficientQuota)
    case .cannotSynchronize:
        return NSFileProviderError(.cannotSynchronize)
    }
}

private func providerActivityErrorCategory(originalError nsError: NSError) -> KDriveProviderActivityErrorCategory {
    if nsError.domain == NSURLErrorDomain {
        return .network
    }
    if nsError.domain == NSFileProviderErrorDomain {
        if nsError.code == NSFileProviderError.notAuthenticated.rawValue {
            return .authentication
        }
        return .fileProvider
    }
    if nsError.domain == NSCocoaErrorDomain {
        return .storage
    }
    return .unknown
}

private func providerDiagnosticSummary(category: KDriveProviderActivityErrorCategory) -> String {
    switch category {
    case .authentication:
        return "Authentication is unavailable or needs to be refreshed."
    case .network:
        return "A network request failed before the operation could complete."
    case .api:
        return "The remote API rejected the operation."
    case .fileProvider:
        return "File Provider returned a recoverable provider error."
    case .listing:
        return "The remote listing response could not be safely applied."
    case .snapshot:
        return "Local sync snapshot state could not be updated safely."
    case .storage:
        return "Local storage returned an error."
    case .validation:
        return "Input or remote state failed validation."
    case .mutationConflict:
        return "The remote item changed before the local mutation could be applied."
    case .unknown:
        return "An unexpected provider error occurred."
    }
}

private func staleMutationVersionError() -> Error {
    NSError(
        domain: NSFileProviderErrorDomain,
        code: NSFileProviderError.cannotSynchronize.rawValue,
        userInfo: [
            NSLocalizedDescriptionKey: "The item changed on the server before the local mutation could be applied.",
            NSLocalizedRecoverySuggestionErrorKey: "Refresh the folder and retry the change."
        ]
    )
}
