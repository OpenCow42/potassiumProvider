import FileProvider
import Foundation
import PotassiumProviderCore

struct FileProviderRuntime: Sendable {
    let configuration: ProviderDomainConfiguration
    let token: KDriveOAuthToken
    let remote: any KDriveFileProviding

    init(domain: NSFileProviderDomain) throws {
        let configurationStore = try DomainConfigurationFileStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier)
        guard let configuration = try configurationStore.configuration(domainIdentifier: domain.identifier.rawValue) else {
            throw NSFileProviderError(.notAuthenticated)
        }

        let tokenStore = KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        guard let token = try tokenStore.loadToken() else {
            throw NSFileProviderError(.notAuthenticated)
        }

        self.configuration = configuration
        self.token = token
        self.remote = PotassiumKDriveService(bearerToken: token.accessToken)
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
        NSFileProviderSyncAnchor(Data(Date().timeIntervalSince1970.description.utf8))
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
