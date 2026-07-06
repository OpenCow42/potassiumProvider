import Foundation

public enum FileProviderUninstallInvocation: Equatable, Sendable {
    case notRequested
    case help
    case run(FileProviderUninstallOptions)
}

public struct FileProviderUninstallOptions: Equatable, Sendable {
    public static let commandFlag = "--file-provider-uninstall"

    public var dryRun: Bool
    public var confirmed: Bool
    public var fullLogout: Bool
    public var hardPurge: Bool

    public init(
        dryRun: Bool = false,
        confirmed: Bool = false,
        fullLogout: Bool = false,
        hardPurge: Bool = false
    ) {
        self.dryRun = dryRun
        self.confirmed = confirmed
        self.fullLogout = fullLogout || hardPurge
        self.hardPurge = hardPurge
    }

    public var domainRemovalMode: FileProviderUninstallDomainRemovalMode {
        hardPurge ? .removeAll : .preserveDirtyUserData
    }

    public var deletesOAuthToken: Bool {
        fullLogout || hardPurge
    }

    public var removesConflictStaging: Bool {
        hardPurge
    }
}

public enum FileProviderUninstallDomainRemovalMode: String, Equatable, Sendable {
    case preserveDirtyUserData
    case removeAll

    public var displayName: String {
        switch self {
        case .preserveDirtyUserData:
            "preserve dirty user data"
        case .removeAll:
            "remove all"
        }
    }
}

public enum FileProviderUninstallArgumentParser {
    private static let allowedFlags: Set<String> = [
        "--dry-run",
        "--yes",
        "--full-logout",
        "--hard-purge",
    ]

    public static func parse(arguments: [String]) throws -> FileProviderUninstallInvocation {
        let parser = CommandLineParser()
        let launchArguments = Array(arguments.dropFirst())
        guard let commandArguments = parser.arguments(
            after: FileProviderUninstallOptions.commandFlag,
            in: launchArguments
        ) else {
            return .notRequested
        }

        if parser.requestsHelp(commandArguments) {
            return .help
        }

        let flags = try parser.flags(in: commandArguments, allowedFlags: allowedFlags)
        return .run(FileProviderUninstallOptions(
            dryRun: flags.contains("--dry-run"),
            confirmed: flags.contains("--yes"),
            fullLogout: flags.contains("--full-logout"),
            hardPurge: flags.contains("--hard-purge")
        ))
    }
}

public struct FileProviderUninstallRegisteredDomain: Equatable, Sendable {
    public var identifier: String
    public var displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }

    public init(configuration: ProviderDomainConfiguration) {
        self.init(identifier: configuration.domainIdentifier, displayName: configuration.displayName)
    }
}

public struct FileProviderUninstallDomainListingFailure: Equatable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public init(error: any Error) {
        self.message = FileProviderUninstallErrorDiagnostics.description(for: error)
    }
}

public enum FileProviderUninstallStateItemKind: String, Equatable, Sendable {
    case domainConfiguration
    case sqliteRows
    case thumbnailCache
}

public struct FileProviderUninstallStateItem: Equatable, Sendable {
    public var kind: FileProviderUninstallStateItemKind
    public var domainIdentifier: String?
    public var description: String

    public init(kind: FileProviderUninstallStateItemKind, domainIdentifier: String?, description: String) {
        self.kind = kind
        self.domainIdentifier = domainIdentifier
        self.description = description
    }
}

public struct FileProviderUninstallConflictStagingPlan: Equatable, Sendable {
    public var directoryPath: String
    public var fileNames: [String]
    public var willRemove: Bool

    public init(directoryPath: String, fileNames: [String], willRemove: Bool) {
        self.directoryPath = directoryPath
        self.fileNames = fileNames.sorted()
        self.willRemove = willRemove
    }
}

public struct FileProviderUninstallPlan: Equatable, Sendable {
    public var options: FileProviderUninstallOptions
    public var registeredDomains: [FileProviderUninstallRegisteredDomain]
    public var domainListingFailure: FileProviderUninstallDomainListingFailure?
    public var storedConfigurations: [ProviderDomainConfiguration]
    public var cleanupDomainIdentifiers: [String]
    public var stateItems: [FileProviderUninstallStateItem]
    public var conflictStaging: FileProviderUninstallConflictStagingPlan?

    public init(
        options: FileProviderUninstallOptions,
        registeredDomains: [FileProviderUninstallRegisteredDomain],
        domainListingFailure: FileProviderUninstallDomainListingFailure? = nil,
        storedConfigurations: [ProviderDomainConfiguration],
        stateItems: [FileProviderUninstallStateItem],
        conflictStaging: FileProviderUninstallConflictStagingPlan?
    ) {
        self.options = options
        self.registeredDomains = registeredDomains.sorted { $0.identifier < $1.identifier }
        self.domainListingFailure = domainListingFailure
        self.storedConfigurations = storedConfigurations.sorted { $0.domainIdentifier < $1.domainIdentifier }
        self.cleanupDomainIdentifiers = Array(Set(
            registeredDomains.map(\.identifier) + storedConfigurations.map(\.domainIdentifier)
        )).sorted()
        self.stateItems = stateItems
        self.conflictStaging = conflictStaging
    }

    public var deletesOAuthToken: Bool {
        options.deletesOAuthToken
    }

    public var hasWork: Bool {
        registeredDomains.isEmpty == false ||
            storedConfigurations.isEmpty == false ||
            stateItems.isEmpty == false ||
            conflictStaging != nil ||
            deletesOAuthToken
    }
}

public enum FileProviderUninstallErrorDiagnostics {
    public static func description(for error: any Error) -> String {
        let nsError = error as NSError
        var details = ["\(error.localizedDescription) (\(nsError.domain) \(nsError.code))"]

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("underlying \(underlyingError.domain) \(underlyingError.code): \(underlyingError.localizedDescription)")
        }

        return details.joined(separator: "; ")
    }
}

public struct FileProviderUninstallResult: Equatable, Sendable {
    public var plan: FileProviderUninstallPlan
    public var removedDomains: [FileProviderUninstallRegisteredDomain]
    public var preservedLocations: [String]
    public var usedRemoveAllDomainsFallback: Bool
    public var removedLocalStateDomainIdentifiers: [String]
    public var removedConflictStaging: Bool
    public var deletedOAuthToken: Bool

    public init(
        plan: FileProviderUninstallPlan,
        removedDomains: [FileProviderUninstallRegisteredDomain] = [],
        preservedLocations: [String] = [],
        usedRemoveAllDomainsFallback: Bool = false,
        removedLocalStateDomainIdentifiers: [String] = [],
        removedConflictStaging: Bool = false,
        deletedOAuthToken: Bool = false
    ) {
        self.plan = plan
        self.removedDomains = removedDomains
        self.preservedLocations = preservedLocations
        self.usedRemoveAllDomainsFallback = usedRemoveAllDomainsFallback
        self.removedLocalStateDomainIdentifiers = removedLocalStateDomainIdentifiers
        self.removedConflictStaging = removedConflictStaging
        self.deletedOAuthToken = deletedOAuthToken
    }
}

public enum FileProviderUninstallCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case confirmationRequired

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            "Uninstall requires --yes unless --dry-run is used."
        }
    }
}

public protocol FileProviderUninstallDomainManaging: Sendable {
    func registeredDomains() async throws -> [FileProviderUninstallRegisteredDomain]
    func removeDomain(
        _ domain: FileProviderUninstallRegisteredDomain,
        mode: FileProviderUninstallDomainRemovalMode
    ) async throws -> URL?
    func removeAllDomains() async throws
}

public protocol FileProviderUninstallLocalStateManaging: Sendable {
    func storedConfigurations() async throws -> [ProviderDomainConfiguration]
    func stateItems(forDomainIdentifiers domainIdentifiers: Set<String>) async throws -> [FileProviderUninstallStateItem]
    func conflictStagingPlan(removeContents: Bool) async throws -> FileProviderUninstallConflictStagingPlan?
    func removeLocalState(domainIdentifier: String) async throws
    func removeConflictStaging() async throws
}

public protocol FileProviderUninstallTokenDeleting: Sendable {
    func deleteToken() async throws
}

public struct FileProviderUninstallCoordinator: Sendable {
    private let domainManager: any FileProviderUninstallDomainManaging
    private let localState: any FileProviderUninstallLocalStateManaging
    private let tokenStore: (any FileProviderUninstallTokenDeleting)?

    public init(
        domainManager: any FileProviderUninstallDomainManaging,
        localState: any FileProviderUninstallLocalStateManaging,
        tokenStore: (any FileProviderUninstallTokenDeleting)? = nil
    ) {
        self.domainManager = domainManager
        self.localState = localState
        self.tokenStore = tokenStore
    }

    public func makePlan(options: FileProviderUninstallOptions) async throws -> FileProviderUninstallPlan {
        let storedConfigurations = try await localState.storedConfigurations()
        let registeredDomains: [FileProviderUninstallRegisteredDomain]
        let domainListingFailure: FileProviderUninstallDomainListingFailure?

        do {
            registeredDomains = try await domainManager.registeredDomains()
            domainListingFailure = nil
        } catch {
            registeredDomains = storedConfigurations.map(FileProviderUninstallRegisteredDomain.init(configuration:))
            domainListingFailure = FileProviderUninstallDomainListingFailure(error: error)
        }

        let cleanupDomainIdentifiers = Set(registeredDomains.map(\.identifier) + storedConfigurations.map(\.domainIdentifier))
        let stateItems = try await localState.stateItems(forDomainIdentifiers: cleanupDomainIdentifiers)
        let conflictStaging = try await localState.conflictStagingPlan(removeContents: options.removesConflictStaging)

        return FileProviderUninstallPlan(
            options: options,
            registeredDomains: registeredDomains,
            domainListingFailure: domainListingFailure,
            storedConfigurations: storedConfigurations,
            stateItems: stateItems,
            conflictStaging: conflictStaging
        )
    }

    public func run(options: FileProviderUninstallOptions) async throws -> FileProviderUninstallResult {
        let plan = try await makePlan(options: options)
        return try await execute(plan: plan)
    }

    public func execute(plan: FileProviderUninstallPlan) async throws -> FileProviderUninstallResult {
        if plan.options.dryRun {
            return FileProviderUninstallResult(plan: plan)
        }

        guard plan.options.confirmed else {
            throw FileProviderUninstallCoordinatorError.confirmationRequired
        }

        var removedDomains: [FileProviderUninstallRegisteredDomain] = []
        var preservedLocations: [String] = []
        var usedRemoveAllDomainsFallback = false

        for domain in plan.registeredDomains {
            do {
                let preservedLocation = try await domainManager.removeDomain(domain, mode: plan.options.domainRemovalMode)
                removedDomains.append(domain)
                if let preservedLocation {
                    preservedLocations.append(preservedLocation.path)
                }
            } catch {
                guard plan.domainListingFailure != nil, plan.options.domainRemovalMode == .removeAll else {
                    throw error
                }

                try await domainManager.removeAllDomains()
                removedDomains = plan.registeredDomains
                preservedLocations.removeAll()
                usedRemoveAllDomainsFallback = true
                break
            }
        }

        var removedLocalStateDomainIdentifiers: [String] = []
        for domainIdentifier in plan.cleanupDomainIdentifiers {
            try await localState.removeLocalState(domainIdentifier: domainIdentifier)
            removedLocalStateDomainIdentifiers.append(domainIdentifier)
        }

        var removedConflictStaging = false
        if plan.options.removesConflictStaging {
            try await localState.removeConflictStaging()
            removedConflictStaging = true
        }

        var deletedOAuthToken = false
        if plan.options.deletesOAuthToken {
            try await tokenStore?.deleteToken()
            deletedOAuthToken = tokenStore != nil
        }

        return FileProviderUninstallResult(
            plan: plan,
            removedDomains: removedDomains,
            preservedLocations: preservedLocations,
            usedRemoveAllDomainsFallback: usedRemoveAllDomainsFallback,
            removedLocalStateDomainIdentifiers: removedLocalStateDomainIdentifiers,
            removedConflictStaging: removedConflictStaging,
            deletedOAuthToken: deletedOAuthToken
        )
    }
}
