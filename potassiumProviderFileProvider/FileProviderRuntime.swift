import FileProvider
import Foundation
import PotassiumProviderCore

struct FileProviderRuntime: Sendable {
    let configuration: ProviderDomainConfiguration
    let token: KDriveOAuthToken
    let remote: any KDriveFileProviding
    let snapshotStore: any KDriveSnapshotStoring

    private init(configuration: ProviderDomainConfiguration, token: KDriveOAuthToken, snapshotStore: any KDriveSnapshotStoring) {
        self.configuration = configuration
        self.token = token
        self.remote = PotassiumKDriveService(bearerToken: token.accessToken)
        self.snapshotStore = snapshotStore
    }

    static func load(domain: NSFileProviderDomain) async throws -> FileProviderRuntime {
        let configuration = try loadConfiguration(domain: domain)
        let tokenStore = KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        guard var token = try tokenStore.loadToken() else {
            throw NSFileProviderError(.notAuthenticated)
        }

        if token.shouldRefresh() {
            guard let refreshToken = token.refreshToken else {
                throw NSFileProviderError(.notAuthenticated)
            }
            token = try await KDriveOAuthClient.refresh(refreshToken: refreshToken)
            try tokenStore.saveToken(token)
        }

        return FileProviderRuntime(
            configuration: configuration,
            token: token,
            snapshotStore: try makeSnapshotStore()
        )
    }

    static func loadConfiguration(domain: NSFileProviderDomain) throws -> ProviderDomainConfiguration {
        let configurationStore = try DomainConfigurationFileStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier)
        guard let configuration = try configurationStore.configuration(domainIdentifier: domain.identifier.rawValue) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        return configuration
    }

    static func makeSnapshotStore() throws -> any KDriveSnapshotStoring {
        try KDriveSnapshotFileStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier)
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
        return fileProviderError
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        return NSFileProviderError(.serverUnreachable)
    }

    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSFileProviderErrorDomain {
        return error
    }

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
