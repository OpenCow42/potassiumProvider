import Darwin
import FileProvider
import Foundation
import PotassiumProviderCore

enum FileProviderUninstallCommandLine {
    nonisolated static func shouldHandle(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(FileProviderUninstallOptions.commandFlag)
    }

    static func runInCurrentProcess(arguments: [String]) -> Int32 {
        var exitCode: Int32?

        Task {
            exitCode = await run(arguments: arguments)
        }

        while exitCode == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        return exitCode ?? 1
    }

    nonisolated static func run(arguments: [String]) async -> Int32 {
        do {
            switch try FileProviderUninstallArgumentParser.parse(arguments: arguments) {
            case .notRequested:
                return 0
            case .help:
                print(usage)
                return 0
            case .run(let options):
                let coordinator = try makeDefaultCoordinator()
                let plan = try await coordinator.makePlan(options: options)
                printPlan(plan)

                do {
                    let result = try await coordinator.execute(plan: plan)
                    printResult(result)
                    return 0
                } catch FileProviderUninstallCoordinatorError.confirmationRequired {
                    print("")
                    print("No changes made. Re-run with --yes to perform this uninstall, or add --dry-run for inspection only.")
                    return 2
                }
            }
        } catch {
            fputs("file-provider uninstall failed: \(FileProviderUninstallErrorDiagnostics.description(for: error))\n", stderr)
            return 1
        }
    }

    private nonisolated static func makeDefaultCoordinator() throws -> FileProviderUninstallCoordinator {
        FileProviderUninstallCoordinator(
            domainManager: SystemFileProviderUninstallDomainManager(),
            localState: try AppGroupFileProviderUninstallLocalState(),
            tokenStore: FileProviderUninstallKeychainTokenDeleter(accessGroup: ProviderConstants.keychainAccessGroup)
        )
    }

    private nonisolated static var usage: String {
        """
        Usage:
          potassiumProvider --file-provider-uninstall [--dry-run] [--yes] [--full-logout] [--hard-purge]

        Options:
          --dry-run       Print the uninstall plan without removing domains or local state.
          --yes           Perform the uninstall. Required unless --dry-run is present.
          --full-logout   Also delete the saved OAuth token.
          --hard-purge    Use File Provider remove-all mode, delete ConflictStaging, and delete the OAuth token.
        """
    }

    private nonisolated static func printPlan(_ plan: FileProviderUninstallPlan) {
        print("potassiumProvider File Provider uninstall")
        print("Mode: \(plan.options.hardPurge ? "hard purge" : "dev reset")")
        print("File Provider removal mode: \(plan.options.domainRemovalMode.displayName)")
        print("Dry run: \(plan.options.dryRun ? "yes" : "no")")
        print("")

        if let domainListingFailure = plan.domainListingFailure {
            print("Warning: could not list registered File Provider domains: \(domainListingFailure.message)")
            if plan.registeredDomains.isEmpty {
                print("No saved domain configurations were available as removal candidates.")
            } else {
                print("Using saved domain configurations as removal candidates.")
            }
            print("")
        }

        if plan.hasWork == false {
            print("No registered File Provider domains or local provider state were found.")
            return
        }

        if plan.registeredDomains.isEmpty {
            print("Registered domains: none")
        } else {
            print("Registered domains to remove:")
            for domain in plan.registeredDomains {
                print("- \(domain.displayName) [\(domain.identifier)]")
            }
        }

        if plan.storedConfigurations.isEmpty {
            print("Stored domain configurations: none")
        } else {
            print("Stored domain configurations to remove:")
            for configuration in plan.storedConfigurations {
                print("- \(configuration.displayName) [\(configuration.domainIdentifier)] driveID \(configuration.driveID)")
            }
        }

        if plan.stateItems.isEmpty == false {
            print("Local provider state to remove:")
            for item in plan.stateItems {
                print("- \(item.description)")
            }
        }

        if let conflictStaging = plan.conflictStaging {
            let action = conflictStaging.willRemove ? "remove" : "preserve"
            print("Conflict staging: \(action) \(conflictStaging.fileNames.count) file(s) at \(conflictStaging.directoryPath)")
            for fileName in conflictStaging.fileNames {
                print("- \(fileName)")
            }
        }

        print("OAuth token: \(plan.deletesOAuthToken ? "delete" : "keep")")
    }

    private nonisolated static func printResult(_ result: FileProviderUninstallResult) {
        print("")
        if result.plan.options.dryRun {
            print("Dry run complete. No changes made.")
            return
        }

        print("Uninstall complete.")
        print("Removed domains: \(result.removedDomains.count)")
        if result.usedRemoveAllDomainsFallback {
            print("Used File Provider remove-all fallback after targeted domain removal failed.")
        }
        if result.preservedLocations.isEmpty == false {
            print("Preserved File Provider data:")
            for location in result.preservedLocations {
                print("- \(location)")
            }
        }
        print("Cleaned local domain state: \(result.removedLocalStateDomainIdentifiers.count)")
        if result.removedConflictStaging {
            print("Removed ConflictStaging contents.")
        }
        if result.deletedOAuthToken {
            print("Deleted saved OAuth token.")
        }
    }
}

private struct SystemFileProviderUninstallDomainManager: FileProviderUninstallDomainManaging {
    func registeredDomains() async throws -> [FileProviderUninstallRegisteredDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: domains.map {
                    FileProviderUninstallRegisteredDomain(
                        identifier: $0.identifier.rawValue,
                        displayName: $0.displayName
                    )
                })
            }
        }
    }

    func removeDomain(
        _ domain: FileProviderUninstallRegisteredDomain,
        mode: FileProviderUninstallDomainRemovalMode
    ) async throws -> URL? {
        let fileProviderDomain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domain.identifier),
            displayName: domain.displayName
        )

        return try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.remove(fileProviderDomain, mode: mode.fileProviderMode) { preservedLocation, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: preservedLocation)
                }
            }
        }
    }

    func removeAllDomains() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSFileProviderManager.removeAllDomains { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private extension FileProviderUninstallDomainRemovalMode {
    nonisolated var fileProviderMode: NSFileProviderManager.DomainRemovalMode {
        switch self {
        case .preserveDirtyUserData:
            #if os(macOS)
            .preserveDirtyUserData
            #else
            .removeAll
            #endif
        case .removeAll:
            .removeAll
        }
    }
}

private struct AppGroupFileProviderUninstallLocalState: FileProviderUninstallLocalStateManaging {
    private let containerURL: URL
    private let domainConfigurationsURL: URL
    private let snapshotsDatabaseURL: URL
    private let conflictStagingURL: URL
    private let thumbnailCacheURL: URL

    init(appGroupIdentifier: String = ProviderConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw KDriveSnapshotStoreError.missingAppGroupContainer(appGroupIdentifier)
        }

        self.containerURL = containerURL
        self.domainConfigurationsURL = containerURL.appendingPathComponent("DomainConfigurations", isDirectory: true)
        self.snapshotsDatabaseURL = containerURL.appendingPathComponent("Snapshots.sqlite3")
        self.conflictStagingURL = containerURL.appendingPathComponent("ConflictStaging", isDirectory: true)
        self.thumbnailCacheURL = containerURL.appendingPathComponent(KDriveThumbnailPipeline.cacheDirectoryName, isDirectory: true)
    }

    func storedConfigurations() throws -> [ProviderDomainConfiguration] {
        guard FileManager.default.fileExists(atPath: domainConfigurationsURL.path) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: domainConfigurationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return try urls
            .filter { $0.pathExtension == "json" }
            .map { try Self.makeDecoder().decode(ProviderDomainConfiguration.self, from: Data(contentsOf: $0)) }
            .sorted { $0.domainIdentifier < $1.domainIdentifier }
    }

    func stateItems(forDomainIdentifiers domainIdentifiers: Set<String>) throws -> [FileProviderUninstallStateItem] {
        let sortedDomainIdentifiers = domainIdentifiers.sorted()
        var items: [FileProviderUninstallStateItem] = []

        for domainIdentifier in sortedDomainIdentifiers {
            let configurationURL = domainConfigurationURL(domainIdentifier: domainIdentifier)
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                items.append(FileProviderUninstallStateItem(
                    kind: .domainConfiguration,
                    domainIdentifier: domainIdentifier,
                    description: "Domain configuration \(configurationURL.path)"
                ))
            }
        }

        if FileManager.default.fileExists(atPath: snapshotsDatabaseURL.path) {
            for domainIdentifier in sortedDomainIdentifiers {
                items.append(FileProviderUninstallStateItem(
                    kind: .sqliteRows,
                    domainIdentifier: domainIdentifier,
                    description: "Snapshots.sqlite3 rows for domain \(domainIdentifier)"
                ))
            }
        }

        for domainIdentifier in sortedDomainIdentifiers {
            if try KDriveThumbnailPipeline.containsCachedThumbnails(
                cacheDirectoryURL: thumbnailCacheURL,
                domainIdentifier: domainIdentifier
            ) {
                items.append(FileProviderUninstallStateItem(
                    kind: .thumbnailCache,
                    domainIdentifier: domainIdentifier,
                    description: "ThumbnailCache files for domain \(domainIdentifier)"
                ))
            }
        }

        return items
    }

    func conflictStagingPlan(removeContents: Bool) throws -> FileProviderUninstallConflictStagingPlan? {
        guard FileManager.default.fileExists(atPath: conflictStagingURL.path) else {
            return nil
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: conflictStagingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let fileNames = urls.map(\.lastPathComponent).sorted()
        guard fileNames.isEmpty == false else {
            return nil
        }

        return FileProviderUninstallConflictStagingPlan(
            directoryPath: conflictStagingURL.path,
            fileNames: fileNames,
            willRemove: removeContents
        )
    }

    func removeLocalState(domainIdentifier: String) async throws {
        let configurationURL = domainConfigurationURL(domainIdentifier: domainIdentifier)
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            try FileManager.default.removeItem(at: configurationURL)
        }

        try KDriveThumbnailPipeline.removeCachedThumbnails(
            cacheDirectoryURL: thumbnailCacheURL,
            domainIdentifier: domainIdentifier
        )

        guard FileManager.default.fileExists(atPath: snapshotsDatabaseURL.path) else {
            return
        }

        let snapshotStore = try KDriveSnapshotSQLiteStore(databaseURL: snapshotsDatabaseURL)
        try await snapshotStore.removeSnapshots(domainIdentifier: domainIdentifier)

        let eventStore = try KDriveProviderEventSQLiteStore(databaseURL: snapshotsDatabaseURL)
        try await eventStore.removeEvents(domainIdentifier: domainIdentifier)
    }

    func removeConflictStaging() throws {
        guard FileManager.default.fileExists(atPath: conflictStagingURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: conflictStagingURL)
    }

    private func domainConfigurationURL(domainIdentifier: String) -> URL {
        domainConfigurationsURL
            .appendingPathComponent(Self.safeFileName(for: domainIdentifier))
            .appendingPathExtension("json")
    }

    private static func safeFileName(for value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }.reduce(into: "") { $0.append($1) }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct FileProviderUninstallKeychainTokenDeleter: FileProviderUninstallTokenDeleting {
    private let store: KeychainOAuthTokenStore

    init(accessGroup: String) {
        self.store = KeychainOAuthTokenStore(accessGroup: accessGroup)
    }

    func deleteToken() async throws {
        try await store.deleteToken()
    }
}
