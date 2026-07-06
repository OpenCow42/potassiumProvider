import Foundation
import Testing
@testable import potassiumProvider
@testable import PotassiumProviderCore

@Suite(.serialized)
struct FileProviderUninstallTests {
    @Test func parserBuildsDefaultDevReset() throws {
        let options = try parsedOptions(["potassiumProvider", "--file-provider-uninstall"])

        #expect(options.dryRun == false)
        #expect(options.confirmed == false)
        #expect(options.fullLogout == false)
        #expect(options.hardPurge == false)
        #expect(options.domainRemovalMode == .preserveDirtyUserData)
        #expect(options.deletesOAuthToken == false)
        #expect(options.removesConflictStaging == false)
    }

    @Test func parserBuildsDryRunFullLogout() throws {
        let options = try parsedOptions([
            "potassiumProvider",
            "--file-provider-uninstall",
            "--dry-run",
            "--yes",
            "--full-logout",
        ])

        #expect(options.dryRun)
        #expect(options.confirmed)
        #expect(options.fullLogout)
        #expect(options.hardPurge == false)
        #expect(options.domainRemovalMode == .preserveDirtyUserData)
        #expect(options.deletesOAuthToken)
        #expect(options.removesConflictStaging == false)
    }

    @Test func parserHardPurgeImpliesFullLogoutAndConflictStagingRemoval() throws {
        let options = try parsedOptions([
            "potassiumProvider",
            "--file-provider-uninstall",
            "--hard-purge",
        ])

        #expect(options.fullLogout)
        #expect(options.hardPurge)
        #expect(options.domainRemovalMode == .removeAll)
        #expect(options.deletesOAuthToken)
        #expect(options.removesConflictStaging)
    }

    @Test func parserRejectsInvalidFlag() throws {
        #expect(throws: CommandLineError.unknownOption("--surprise")) {
            _ = try FileProviderUninstallArgumentParser.parse(arguments: [
                "potassiumProvider",
                "--file-provider-uninstall",
                "--surprise",
            ])
        }
    }

    @Test func parserRejectsUnexpectedFlagValues() throws {
        #expect(throws: CommandLineError.unexpectedArgument("true")) {
            _ = try FileProviderUninstallArgumentParser.parse(arguments: [
                "potassiumProvider",
                "--file-provider-uninstall",
                "--dry-run",
                "true",
            ])
        }
    }

    @Test func commandLineParserCollectsAllowedFlags() throws {
        let flags = try CommandLineParser().flags(
            in: ["--dry-run", "--yes", "--dry-run"],
            allowedFlags: ["--dry-run", "--yes"]
        )

        #expect(flags == ["--dry-run", "--yes"])
    }

    @Test func parserIgnoresNormalAppLaunch() throws {
        let invocation = try FileProviderUninstallArgumentParser.parse(arguments: ["potassiumProvider"])
        #expect(invocation == .notRequested)
    }

    @Test func coordinatorDryRunReportsWithoutMutatingStores() async throws {
        let domainManager = RecordingUninstallDomainManager(domains: [registeredDomain("domain-1")])
        let localState = RecordingUninstallLocalState(
            storedConfigurations: [configuration("domain-2")],
            stateItems: [
                FileProviderUninstallStateItem(
                    kind: .domainConfiguration,
                    domainIdentifier: "domain-2",
                    description: "Domain configuration domain-2.json"
                ),
                FileProviderUninstallStateItem(
                    kind: .sqliteRows,
                    domainIdentifier: "domain-1",
                    description: "Snapshots.sqlite3 rows for domain domain-1"
                ),
            ],
            conflictStagingFileNames: ["stale.upload"]
        )
        let tokenStore = RecordingUninstallTokenStore()
        let coordinator = FileProviderUninstallCoordinator(
            domainManager: domainManager,
            localState: localState,
            tokenStore: tokenStore
        )

        let result = try await coordinator.run(options: FileProviderUninstallOptions(dryRun: true))

        #expect(result.plan.cleanupDomainIdentifiers == ["domain-1", "domain-2"])
        #expect(result.plan.conflictStaging?.willRemove == false)
        #expect(await domainManager.removedRecords().isEmpty)
        #expect(await localState.removedDomainIdentifiers().isEmpty)
        #expect(await localState.didRemoveConflictStaging() == false)
        #expect(await tokenStore.didDeleteToken() == false)
    }

    @Test func coordinatorDevResetRemovesDomainsAndLocalStateWithoutDeletingTokenOrStaging() async throws {
        let domainManager = RecordingUninstallDomainManager(domains: [registeredDomain("domain-1")])
        let localState = RecordingUninstallLocalState(
            storedConfigurations: [configuration("domain-2")],
            stateItems: [],
            conflictStagingFileNames: ["retained.upload"]
        )
        let tokenStore = RecordingUninstallTokenStore()
        let coordinator = FileProviderUninstallCoordinator(
            domainManager: domainManager,
            localState: localState,
            tokenStore: tokenStore
        )

        let result = try await coordinator.run(options: FileProviderUninstallOptions(confirmed: true))

        #expect(await domainManager.removedRecords() == [
            RemovedDomainRecord(domain: registeredDomain("domain-1"), mode: .preserveDirtyUserData)
        ])
        #expect(await localState.removedDomainIdentifiers() == ["domain-1", "domain-2"])
        #expect(await localState.didRemoveConflictStaging() == false)
        #expect(await tokenStore.didDeleteToken() == false)
        #expect(result.deletedOAuthToken == false)
    }

    @Test func coordinatorFallsBackToStoredConfigurationsWhenDomainListingFails() async throws {
        let domainManager = RecordingUninstallDomainManager(
            domains: [],
            listingError: .domainListingFailed
        )
        let localState = RecordingUninstallLocalState(
            storedConfigurations: [configuration("domain-2")],
            stateItems: [
                FileProviderUninstallStateItem(
                    kind: .domainConfiguration,
                    domainIdentifier: "domain-2",
                    description: "Domain configuration domain-2.json"
                ),
            ]
        )
        let tokenStore = RecordingUninstallTokenStore()
        let coordinator = FileProviderUninstallCoordinator(
            domainManager: domainManager,
            localState: localState,
            tokenStore: tokenStore
        )

        let result = try await coordinator.run(options: FileProviderUninstallOptions(confirmed: true))

        #expect(result.plan.domainListingFailure != nil)
        #expect(result.plan.registeredDomains == [registeredDomain("domain-2")])
        #expect(await domainManager.removedRecords() == [
            RemovedDomainRecord(domain: registeredDomain("domain-2"), mode: .preserveDirtyUserData)
        ])
        #expect(await localState.removedDomainIdentifiers() == ["domain-2"])
    }

    @Test func coordinatorUsesRemoveAllFallbackWhenFallbackDomainRemovalFails() async throws {
        let domainManager = RecordingUninstallDomainManager(
            domains: [],
            listingError: .domainListingFailed,
            removalError: .domainRemovalFailed
        )
        let localState = RecordingUninstallLocalState(
            storedConfigurations: [configuration("domain-2")],
            stateItems: []
        )
        let coordinator = FileProviderUninstallCoordinator(
            domainManager: domainManager,
            localState: localState
        )

        let result = try await coordinator.run(options: FileProviderUninstallOptions(
            confirmed: true,
            hardPurge: true
        ))

        #expect(result.usedRemoveAllDomainsFallback)
        #expect(result.removedDomains == [registeredDomain("domain-2")])
        #expect(await domainManager.didRemoveAllDomains())
        #expect(await localState.removedDomainIdentifiers() == ["domain-2"])
        #expect(result.deletedOAuthToken == false)
    }

    @Test func coordinatorDoesNotUseRemoveAllFallbackForDevResetRemovalFailure() async throws {
        let domainManager = RecordingUninstallDomainManager(
            domains: [],
            listingError: .domainListingFailed,
            removalError: .domainRemovalFailed
        )
        let localState = RecordingUninstallLocalState(
            storedConfigurations: [configuration("domain-2")],
            stateItems: []
        )
        let coordinator = FileProviderUninstallCoordinator(
            domainManager: domainManager,
            localState: localState
        )

        var sawRemovalFailure = false
        do {
            _ = try await coordinator.run(options: FileProviderUninstallOptions(confirmed: true))
        } catch FileProviderUninstallTestError.domainRemovalFailed {
            sawRemovalFailure = true
        }

        #expect(sawRemovalFailure)
        #expect(await domainManager.didRemoveAllDomains() == false)
        #expect(await localState.removedDomainIdentifiers().isEmpty)
    }

    @Test func coordinatorFullLogoutDeletesTokenOnlyAfterDomainAndLocalCleanup() async throws {
        let domainManager = RecordingUninstallDomainManager(domains: [registeredDomain("domain-1")])
        let localState = RecordingUninstallLocalState(storedConfigurations: [], stateItems: [])
        let tokenStore = RecordingUninstallTokenStore()
        let coordinator = FileProviderUninstallCoordinator(
            domainManager: domainManager,
            localState: localState,
            tokenStore: tokenStore
        )

        let result = try await coordinator.run(options: FileProviderUninstallOptions(
            confirmed: true,
            fullLogout: true
        ))

        #expect(await domainManager.removedRecords().map(\.mode) == [.preserveDirtyUserData])
        #expect(await localState.removedDomainIdentifiers() == ["domain-1"])
        #expect(await tokenStore.didDeleteToken())
        #expect(result.deletedOAuthToken)
    }

    @Test func coordinatorHardPurgeUsesRemoveAllAndDeletesConflictStagingAndToken() async throws {
        let domainManager = RecordingUninstallDomainManager(domains: [registeredDomain("domain-1")])
        let localState = RecordingUninstallLocalState(
            storedConfigurations: [],
            stateItems: [],
            conflictStagingFileNames: ["stale.upload"]
        )
        let tokenStore = RecordingUninstallTokenStore()
        let coordinator = FileProviderUninstallCoordinator(
            domainManager: domainManager,
            localState: localState,
            tokenStore: tokenStore
        )

        let result = try await coordinator.run(options: FileProviderUninstallOptions(
            confirmed: true,
            hardPurge: true
        ))

        #expect(await domainManager.removedRecords() == [
            RemovedDomainRecord(domain: registeredDomain("domain-1"), mode: .removeAll)
        ])
        #expect(result.plan.conflictStaging?.willRemove == true)
        #expect(await localState.didRemoveConflictStaging())
        #expect(await tokenStore.didDeleteToken())
        #expect(result.removedConflictStaging)
        #expect(result.deletedOAuthToken)
    }

    @Test func coordinatorRequiresConfirmationBeforeMutating() async throws {
        let domainManager = RecordingUninstallDomainManager(domains: [registeredDomain("domain-1")])
        let localState = RecordingUninstallLocalState(storedConfigurations: [configuration("domain-2")], stateItems: [])
        let tokenStore = RecordingUninstallTokenStore()
        let coordinator = FileProviderUninstallCoordinator(
            domainManager: domainManager,
            localState: localState,
            tokenStore: tokenStore
        )

        var sawConfirmationRequired = false
        do {
            _ = try await coordinator.run(options: FileProviderUninstallOptions())
        } catch FileProviderUninstallCoordinatorError.confirmationRequired {
            sawConfirmationRequired = true
        }

        #expect(sawConfirmationRequired)
        #expect(await domainManager.removedRecords().isEmpty)
        #expect(await localState.removedDomainIdentifiers().isEmpty)
        #expect(await tokenStore.didDeleteToken() == false)
    }

    private func parsedOptions(_ arguments: [String]) throws -> FileProviderUninstallOptions {
        guard case .run(let options) = try FileProviderUninstallArgumentParser.parse(arguments: arguments) else {
            throw FileProviderUninstallTestError.expectedRunInvocation
        }
        return options
    }

    private func registeredDomain(_ identifier: String) -> FileProviderUninstallRegisteredDomain {
        FileProviderUninstallRegisteredDomain(identifier: identifier, displayName: "Drive \(identifier)")
    }

    private func configuration(_ identifier: String) -> ProviderDomainConfiguration {
        ProviderDomainConfiguration(
            domainIdentifier: identifier,
            displayName: "Drive \(identifier)",
            driveID: 42,
            driveName: "Drive \(identifier)",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private enum FileProviderUninstallTestError: Error, Equatable, LocalizedError, Sendable {
    case expectedRunInvocation
    case domainListingFailed
    case domainRemovalFailed

    var errorDescription: String? {
        switch self {
        case .expectedRunInvocation:
            "Expected file-provider uninstall run invocation."
        case .domainListingFailed:
            "Domain listing failed."
        case .domainRemovalFailed:
            "Domain removal failed."
        }
    }
}

private struct RemovedDomainRecord: Equatable {
    var domain: FileProviderUninstallRegisteredDomain
    var mode: FileProviderUninstallDomainRemovalMode
}

private actor RecordingUninstallDomainManager: FileProviderUninstallDomainManaging {
    private let domains: [FileProviderUninstallRegisteredDomain]
    private let listingError: FileProviderUninstallTestError?
    private let removalError: FileProviderUninstallTestError?
    private var removed: [RemovedDomainRecord] = []
    private var removedAll = false

    init(
        domains: [FileProviderUninstallRegisteredDomain],
        listingError: FileProviderUninstallTestError? = nil,
        removalError: FileProviderUninstallTestError? = nil
    ) {
        self.domains = domains
        self.listingError = listingError
        self.removalError = removalError
    }

    func registeredDomains() throws -> [FileProviderUninstallRegisteredDomain] {
        if let listingError {
            throw listingError
        }
        return domains
    }

    func removeDomain(
        _ domain: FileProviderUninstallRegisteredDomain,
        mode: FileProviderUninstallDomainRemovalMode
    ) throws -> URL? {
        if let removalError {
            throw removalError
        }
        removed.append(RemovedDomainRecord(domain: domain, mode: mode))
        return nil
    }

    func removeAllDomains() {
        removedAll = true
    }

    func removedRecords() -> [RemovedDomainRecord] {
        removed
    }

    func didRemoveAllDomains() -> Bool {
        removedAll
    }
}

private actor RecordingUninstallLocalState: FileProviderUninstallLocalStateManaging {
    private let configurations: [ProviderDomainConfiguration]
    private let plannedStateItems: [FileProviderUninstallStateItem]
    private let conflictStagingFileNames: [String]
    private var removedIdentifiers: [String] = []
    private var removedConflictStaging = false

    init(
        storedConfigurations: [ProviderDomainConfiguration],
        stateItems: [FileProviderUninstallStateItem],
        conflictStagingFileNames: [String] = []
    ) {
        self.configurations = storedConfigurations
        self.plannedStateItems = stateItems
        self.conflictStagingFileNames = conflictStagingFileNames
    }

    func storedConfigurations() -> [ProviderDomainConfiguration] {
        configurations
    }

    func stateItems(forDomainIdentifiers domainIdentifiers: Set<String>) -> [FileProviderUninstallStateItem] {
        plannedStateItems.filter { item in
            guard let domainIdentifier = item.domainIdentifier else {
                return true
            }
            return domainIdentifiers.contains(domainIdentifier)
        }
    }

    func conflictStagingPlan(removeContents: Bool) -> FileProviderUninstallConflictStagingPlan? {
        guard conflictStagingFileNames.isEmpty == false else {
            return nil
        }

        return FileProviderUninstallConflictStagingPlan(
            directoryPath: "/tmp/ConflictStaging",
            fileNames: conflictStagingFileNames,
            willRemove: removeContents
        )
    }

    func removeLocalState(domainIdentifier: String) {
        removedIdentifiers.append(domainIdentifier)
    }

    func removeConflictStaging() {
        removedConflictStaging = true
    }

    func removedDomainIdentifiers() -> [String] {
        removedIdentifiers
    }

    func didRemoveConflictStaging() -> Bool {
        removedConflictStaging
    }
}

private actor RecordingUninstallTokenStore: FileProviderUninstallTokenDeleting {
    private var deleted = false

    func deleteToken() {
        deleted = true
    }

    func didDeleteToken() -> Bool {
        deleted
    }
}
