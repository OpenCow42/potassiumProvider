import Foundation

public struct ProviderActionRuntime: Sendable {
    public let configuration: ProviderDomainConfiguration
    public let remote: any KDriveFileProviding
    public let actions: any KDriveContextActionProviding
    public let eventStore: (any KDriveProviderEventStoring)?

    public init(
        configuration: ProviderDomainConfiguration,
        remote: any KDriveFileProviding,
        actions: any KDriveContextActionProviding,
        eventStore: (any KDriveProviderEventStoring)?
    ) {
        self.configuration = configuration
        self.remote = remote
        self.actions = actions
        self.eventStore = eventStore
    }

    public static func load(domainIdentifier: String) async throws -> ProviderActionRuntime {
        let configurationStore = try DomainConfigurationFileStore(
            appGroupIdentifier: ProviderConstants.appGroupIdentifier
        )
        guard let configuration = try await configurationStore.configuration(
            domainIdentifier: domainIdentifier
        ) else {
            throw ProviderActionRuntimeError.configurationUnavailable
        }

        let tokenStore = KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        guard var token = try await tokenStore.loadToken(
            accountIdentifier: configuration.accountIdentifier
        ) else {
            throw ProviderActionRuntimeError.notAuthenticated
        }

        if token.shouldRefresh() {
            guard let refreshToken = token.refreshToken else {
                throw ProviderActionRuntimeError.notAuthenticated
            }
            token = try await KDriveOAuthClient.refresh(refreshToken: refreshToken)
            try await tokenStore.saveToken(token, accountIdentifier: configuration.accountIdentifier)
        }

        let service = PotassiumKDriveService(bearerToken: token.accessToken)
        let eventStore = try? KDriveProviderEventSQLiteStore(
            appGroupIdentifier: ProviderConstants.appGroupIdentifier
        )
        return ProviderActionRuntime(
            configuration: configuration,
            remote: service,
            actions: service,
            eventStore: eventStore
        )
    }
}

public enum ProviderActionRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case configurationUnavailable
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "The selected kDrive is no longer configured."
        case .notAuthenticated:
            return "Open potassiumProvider and reconnect this account."
        }
    }
}
