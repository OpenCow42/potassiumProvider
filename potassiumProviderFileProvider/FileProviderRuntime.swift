import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

enum FileProviderLog {
    static let replicatedExtension = Logger(subsystem: ProviderConstants.logSubsystem, category: "file-provider")
    static let enumeration = Logger(subsystem: ProviderConstants.logSubsystem, category: "enumeration")
    static let runtime = Logger(subsystem: ProviderConstants.logSubsystem, category: "runtime")
}

struct FileProviderRuntime: Sendable {
    let configuration: ProviderDomainConfiguration
    let token: KDriveOAuthToken
    let remote: any KDriveFileProviding
    let snapshotStore: any KDriveSnapshotStoring
    let eventStore: (any KDriveProviderEventStoring)?

    private init(
        configuration: ProviderDomainConfiguration,
        token: KDriveOAuthToken,
        snapshotStore: any KDriveSnapshotStoring,
        eventStore: (any KDriveProviderEventStoring)?
    ) {
        self.configuration = configuration
        self.token = token
        self.remote = PotassiumKDriveService(bearerToken: token.accessToken)
        self.snapshotStore = snapshotStore
        self.eventStore = eventStore
    }

    static func load(domain: NSFileProviderDomain) async throws -> FileProviderRuntime {
        FileProviderLog.runtime.debug("load runtime for domain(\(domain.identifier.rawValue, privacy: .public))")
        let configuration = try await loadConfiguration(domain: domain)
        let tokenStore = KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        guard var token = try await tokenStore.loadToken() else {
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
            try await tokenStore.saveToken(token)
            FileProviderLog.runtime.info("refreshed OAuth token for domain(\(domain.identifier.rawValue, privacy: .public))")
        }

        let snapshotStore = try makeSnapshotStore()
        FileProviderLog.runtime.debug("loaded runtime for domain(\(domain.identifier.rawValue, privacy: .public)) driveID(\(configuration.driveID, privacy: .public)) rootFileID(\(configuration.rootFileID, privacy: .public))")
        return FileProviderRuntime(
            configuration: configuration,
            token: token,
            snapshotStore: snapshotStore,
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

func providerError(_ error: Error) -> Error {
    if let fileProviderError = error as? NSFileProviderError {
        let nsError = fileProviderError as NSError
        FileProviderLog.runtime.debug("preserve FileProvider error code(\(nsError.code, privacy: .public)): \(nsError.localizedDescription, privacy: .public)")
        return fileProviderError
    }

    if error is KDriveListingValidationError {
        FileProviderLog.runtime.error("map listing validation failure to cannotSynchronize: \(error.localizedDescription, privacy: .public)")
        return NSFileProviderError(.cannotSynchronize)
    }

    if let snapshotStoreError = error as? KDriveSnapshotStoreError,
       case .staleSnapshot = snapshotStoreError {
        FileProviderLog.runtime.error("map stale snapshot write to cannotSynchronize: \(error.localizedDescription, privacy: .public)")
        return NSFileProviderError(.cannotSynchronize)
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        FileProviderLog.runtime.error("map URL error \(nsError.code, privacy: .public) to serverUnreachable: \(nsError.localizedDescription, privacy: .public)")
        return NSFileProviderError(.serverUnreachable)
    }

    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSFileProviderErrorDomain {
        FileProviderLog.runtime.error("preserve Cocoa/FileProvider error \(nsError.domain, privacy: .public) code(\(nsError.code, privacy: .public)): \(nsError.localizedDescription, privacy: .public)")
        return error
    }

    FileProviderLog.runtime.error("wrap unexpected error as XPC reply invalid: \(error.localizedDescription, privacy: .public)")
    return NSError(
        domain: NSCocoaErrorDomain,
        code: NSXPCConnectionReplyInvalid,
        userInfo: [NSUnderlyingErrorKey: error]
    )
}

extension Progress {
    static func cancellable(_ cancellation: @escaping () -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        progress.cancellationHandler = cancellation
        return progress
    }
}
