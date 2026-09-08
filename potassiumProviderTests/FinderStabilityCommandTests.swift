#if os(macOS) && STABILITY
import FileProvider
import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@MainActor
@Suite("Finder Stability command")
struct FinderStabilityCommandTests {
    @Test func parserRequiresExplicitLiveConfirmationOnlyForRun() throws {
        #expect(try FinderStabilityArgumentParser.parse(arguments: [
            "app", "--finder-stability", "preflight",
        ]) == .execute(FinderStabilityCommandOptions(
            mode: .preflight,
            requestPermissions: false
        )))
        #expect(try FinderStabilityArgumentParser.parse(arguments: [
            "app", "--finder-stability", "run", "--yes-live", "--request-permissions",
        ]) == .execute(FinderStabilityCommandOptions(
            mode: .run,
            requestPermissions: true
        )))
        #expect(throws: FinderStabilityArgumentError.liveConfirmationRequired) {
            try FinderStabilityArgumentParser.parse(arguments: [
                "app", "--finder-stability", "run",
            ])
        }
        #expect(throws: FinderStabilityArgumentError.liveConfirmationNotAllowedForPreflight) {
            try FinderStabilityArgumentParser.parse(arguments: [
                "app", "--finder-stability", "preflight", "--yes-live",
            ])
        }
        #expect(try FinderStabilityArgumentParser.parse(arguments: [
            "app", "--finder-stability", "recover", "--yes-recover",
        ]) == .execute(FinderStabilityCommandOptions(
            mode: .recover,
            requestPermissions: false
        )))
        #expect(throws: FinderStabilityArgumentError.recoveryConfirmationRequired) {
            try FinderStabilityArgumentParser.parse(arguments: [
                "app", "--finder-stability", "recover",
            ])
        }
        #expect(throws: FinderStabilityArgumentError.recoveryConfirmationNotAllowed) {
            try FinderStabilityArgumentParser.parse(arguments: [
                "app", "--finder-stability", "run", "--yes-live", "--yes-recover",
            ])
        }
        #expect(throws: FinderStabilityArgumentError.permissionRequestNotAllowedForRecovery) {
            try FinderStabilityArgumentParser.parse(arguments: [
                "app", "--finder-stability", "recover", "--yes-recover", "--request-permissions",
            ])
        }
    }

    @Test func parserRejectsUnknownDuplicateAndCredentialShapedArguments() {
        #expect(throws: FinderStabilityArgumentError.duplicateMode) {
            try FinderStabilityArgumentParser.parse(arguments: [
                "app", "--finder-stability", "preflight", "run",
            ])
        }
        for argument in ["--access-token", "--credential-file", "--account-id", "--root-path"] {
            #expect(throws: FinderStabilityArgumentError.unknownOption) {
                try FinderStabilityArgumentParser.parse(arguments: [
                    "app", "--finder-stability", "preflight", argument,
                ])
            }
        }
    }

    @Test func commandMapsConsentCheckpointWithoutReportingFailure() async {
        let executor = FinderStabilityCommandExecutorFake(preflightResult: .checkpoint)
        let code = await FinderStabilityCommandLine.run(
            arguments: ["app", "--finder-stability", "preflight"],
            executor: executor
        )

        #expect(code == 3)
        #expect(executor.preflightRequests == [false])
        #expect(executor.runRequests.isEmpty)
    }

    @Test func recoveryCommandUsesOnlyTheLocalRecoveryPath() async {
        let executor = FinderStabilityCommandExecutorFake(preflightResult: .ready)
        let code = await FinderStabilityCommandLine.run(
            arguments: ["app", "--finder-stability", "recover", "--yes-recover"],
            executor: executor
        )

        #expect(code == 0)
        #expect(executor.recoveryRequestCount == 1)
        #expect(executor.preflightRequests.isEmpty)
        #expect(executor.runRequests.isEmpty)
    }

    @Test func consoleDescriptionsContainOnlyClosedStatusText() {
        #expect(FinderStabilityCommandResult.ready.safeConsoleDescription == "finder stability preflight: ready")
        #expect(FinderStabilityCommandResult.checkpoint.exitCode == 3)
        #expect(FinderStabilityCommandResult.failed.exitCode == 1)
        #expect(FinderStabilityCommandResult.recovered.exitCode == 0)
        #expect(FinderStabilityCommandResult.recovered.safeConsoleDescription
            == "finder stability recovery: stale run preserved and released")
    }

    @Test func permissionAndConsentStatesBecomeCheckpointsRatherThanFailures() {
        let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let results = FinderStabilityPreflightEvaluator.results(
            permissions: FinderStabilityPermissionSnapshot(
                accessibilityOutcome: .checkpoint(.accessibilityConsentRequired),
                automationOutcome: .checkpoint(.finderAutomationConsentRequired)
            ),
            hasFileProviderRegistration: true,
            hasVerifiedFileProviderConsent: false,
            labSafetyAllowed: true,
            recordedAt: recordedAt
        )

        #expect(FinderStabilityPreflightEvaluator.commandResult(for: results) == .checkpoint)
        #expect(results.map(\.recordedAt).allSatisfy { $0 == recordedAt })
        #expect(results.first { $0.check == .fileProviderConsent }?.outcome
            == .checkpoint(.fileProviderConsentRequired))
    }

    @Test func registrationAndLabSafetyFailuresRejectTheCommand() {
        let results = FinderStabilityPreflightEvaluator.results(
            permissions: FinderStabilityPermissionSnapshot(
                accessibilityOutcome: .passed,
                automationOutcome: .passed
            ),
            hasFileProviderRegistration: false,
            hasVerifiedFileProviderConsent: true,
            labSafetyAllowed: false,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(FinderStabilityPreflightEvaluator.commandResult(for: results) == .rejected)
        #expect(results.first { $0.check == .fileProviderRegistration }?.outcome
            == .failed(.fileProviderNotRegistered))
        #expect(results.first { $0.check == .stabilityLabSafety }?.outcome
            == .failed(.stabilityLabRejected))
    }

    @Test func commandPreflightLoaderUsesInjectedDomainKeychainAndRemoteEvidence() async throws {
        let marker = StabilityLabOwnershipMarker(
            identifier: UUID(),
            driveID: 7,
            rootFileID: 42,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let domain = ProviderDomainConfiguration(
            domainIdentifier: "finder-preflight-domain",
            accountIdentifier: "finder-preflight-account",
            displayName: "Synthetic Lab",
            driveID: 7,
            driveName: "Synthetic Drive",
            rootFileID: 42,
            purpose: .stabilityLab,
            stabilityLab: ProviderStabilityLabConfiguration(
                driveRootFileID: ProviderConstants.defaultRootFileID,
                markerFileID: 43,
                ownershipMarker: marker
            )
        )
        let account = ProviderAccount(
            accountIdentifier: domain.accountIdentifier,
            displayName: "Synthetic Account",
            authenticationKind: .manualAccessToken
        )
        let tokenStore = InMemoryOAuthTokenStore()
        let privateCanary = UUID().uuidString
        await tokenStore.saveToken(
            KDriveOAuthToken(
                accessToken: privateCanary,
                tokenType: "Synthetic",
                refreshToken: nil,
                scope: nil,
                idToken: nil,
                expiresAt: nil
            ),
            accountIdentifier: account.accountIdentifier
        )
        let remote = FinderPreflightRemote(
            root: finderPreflightItem(id: 42, parentID: 1, type: "dir"),
            marker: finderPreflightItem(id: 43, parentID: 42, type: "file"),
            markerData: try JSONEncoder().encode(marker)
        )
        let registrar = FinderPreflightRegistrar(
            domainIdentifier: domain.domainIdentifier,
            rootURL: URL(fileURLWithPath: "/tmp/synthetic-finder-preflight-root")
        )
        let factory = FinderPreflightRemoteFactory(remote: remote)
        let domainStore = FinderPreflightDomainStore(domains: [domain])
        let visibleBindingResolver = FinderVisibleBindingResolverFake(binding:
            FinderStabilityVisibleItemBinding(
                itemIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
                domainIdentifier: domain.domainIdentifier
            )
        )
        let loader = FinderStabilityContextLoader(
            accountStore: FinderPreflightAccountStore(accounts: [account]),
            domainStore: domainStore,
            tokenStore: tokenStore,
            registrar: registrar,
            remoteFactory: { _, _ in factory.makeRemote() },
            visibleDomainResolver: { url in
                visibleBindingResolver.resolve(url)
            }
        )

        let context = try await loader.loadPreflight()

        #expect(context.hasVerifiedFileProviderConsent)
        #expect(factory.makeCallCount == 1)
        #expect(await remote.readCallCount == 4)

        await domainStore.save(ProviderDomainConfiguration(
            domainIdentifier: "ordinary-race-domain",
            displayName: "Synthetic Ordinary",
            driveID: 8,
            driveName: "Synthetic Drive"
        ))
        await #expect(throws: FinderStabilityContextError.fileProviderNotRegistered) {
            try await context.verifySafety()
        }
        #expect(await remote.readCallCount == 4)

        await domainStore.remove(domainIdentifier: "ordinary-race-domain")
        visibleBindingResolver.binding = FinderStabilityVisibleItemBinding(
            itemIdentifier: "rebound-root",
            domainIdentifier: domain.domainIdentifier
        )
        await #expect(throws: FinderStabilityContextError.fileProviderNotRegistered) {
            try await context.verifySafety()
        }
        #expect(await remote.readCallCount == 8)
    }

    @Test func targetBindingRejectsItemOrDomainDrift() {
        #expect(FinderStabilityTargetBinding.matches(
            expectedFileID: 42,
            expectedDomainIdentifier: "expected-domain",
            actualItemIdentifier: "42",
            actualDomainIdentifier: "expected-domain"
        ))
        #expect(FinderStabilityTargetBinding.matches(
            expectedFileID: 42,
            expectedDomainIdentifier: "expected-domain",
            actualItemIdentifier: "43",
            actualDomainIdentifier: "expected-domain"
        ) == false)
        #expect(FinderStabilityTargetBinding.matches(
            expectedFileID: 42,
            expectedDomainIdentifier: "expected-domain",
            actualItemIdentifier: "42",
            actualDomainIdentifier: "other-domain"
        ) == false)
    }

    @Test func targetBindingReturnsTheSingleValidatedResolution() async throws {
        var resolutionCount = 0
        let resolvedIdentifier = try await FinderStabilityTargetBinding.resolve(
            expectedFileID: 42,
            expectedDomainIdentifier: "expected-domain",
            using: {
                resolutionCount += 1
                if resolutionCount == 1 {
                    return ("42", "expected-domain")
                }
                return ("43", "other-domain")
            }
        )

        #expect(resolvedIdentifier == "42")
        #expect(resolutionCount == 1)
    }

    @Test func scenarioGateRevalidatesAfterBaselineImmediatelyBeforeExecution() async throws {
        var order: [String] = []
        let values = try await FinderStabilityScenarioGate.run(
            baseline: {
                order.append("baseline")
                return 1
            },
            verifySafety: {
                order.append("safety")
            },
            execute: {
                order.append("execute")
                return 2
            }
        )

        #expect(order == ["baseline", "safety", "execute"])
        #expect(values.0 == 1)
        #expect(values.1 == 2)
    }

    @Test func stabilityMacBuildAloneCarriesFinderAutomationEntitlement() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectText = try String(contentsOf:
            repositoryRoot
                .appendingPathComponent("potassiumProvider.xcodeproj")
                .appendingPathComponent("project.pbxproj"),
            encoding: .utf8
        )
        #expect(projectText.contains(
            "\"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]\" = "
                + "Config/potassiumProviderStability.entitlements;"
        ))

        let stabilityData = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Config/potassiumProviderStability.entitlements"))
        let ordinaryData = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Config/potassiumProvider.entitlements"))
        let stability = try #require(PropertyListSerialization.propertyList(
            from: stabilityData,
            format: nil
        ) as? [String: Any])
        let ordinary = try #require(PropertyListSerialization.propertyList(
            from: ordinaryData,
            format: nil
        ) as? [String: Any])

        #expect(stability["com.apple.security.automation.apple-events"] as? Bool == true)
        #expect(
            stability["com.apple.security.temporary-exception.apple-events"] as? [String]
                == ["com.apple.finder"]
        )
        #expect(ordinary["com.apple.security.automation.apple-events"] == nil)
        #expect(ordinary["com.apple.security.temporary-exception.apple-events"] == nil)
    }
}

@MainActor
private final class FinderVisibleBindingResolverFake {
    var binding: FinderStabilityVisibleItemBinding

    init(binding: FinderStabilityVisibleItemBinding) {
        self.binding = binding
    }

    func resolve(_ url: URL) -> FinderStabilityVisibleItemBinding {
        binding
    }
}

@MainActor
private final class FinderStabilityCommandExecutorFake: FinderStabilityCommandExecuting {
    let preflightResult: FinderStabilityCommandResult
    var preflightRequests: [Bool] = []
    var runRequests: [Bool] = []
    var recoveryRequestCount = 0

    init(preflightResult: FinderStabilityCommandResult) {
        self.preflightResult = preflightResult
    }

    func preflight(requestPermissions: Bool) async -> FinderStabilityCommandResult {
        preflightRequests.append(requestPermissions)
        return preflightResult
    }

    func run(requestPermissions: Bool) async -> FinderStabilityCommandResult {
        runRequests.append(requestPermissions)
        return .completed
    }

    func recoverStaleRun() async -> FinderStabilityCommandResult {
        recoveryRequestCount += 1
        return .recovered
    }
}

private actor FinderPreflightAccountStore: ProviderAccountStoring {
    var accounts: [ProviderAccount]

    init(accounts: [ProviderAccount]) { self.accounts = accounts }

    func allAccounts() -> [ProviderAccount] { accounts }
    func account(accountIdentifier: String) -> ProviderAccount? {
        accounts.first { $0.accountIdentifier == accountIdentifier }
    }
    func save(_ account: ProviderAccount) { accounts.append(account) }
    func remove(accountIdentifier: String) {
        accounts.removeAll { $0.accountIdentifier == accountIdentifier }
    }
}

private actor FinderPreflightDomainStore: DomainConfigurationStoring {
    var domains: [ProviderDomainConfiguration]

    init(domains: [ProviderDomainConfiguration]) { self.domains = domains }

    func allConfigurations() -> [ProviderDomainConfiguration] { domains }
    func configuration(domainIdentifier: String) -> ProviderDomainConfiguration? {
        domains.first { $0.domainIdentifier == domainIdentifier }
    }
    func save(_ configuration: ProviderDomainConfiguration) { domains.append(configuration) }
    func remove(domainIdentifier: String) {
        domains.removeAll { $0.domainIdentifier == domainIdentifier }
    }
}

@MainActor
private struct FinderPreflightRegistrar: ProviderDomainRegistering {
    let domainIdentifier: String
    let rootURL: URL

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {}
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
    func registeredDomainIdentifiers() async throws -> Set<String> { [domainIdentifier] }
    func userVisibleRootURL(for configuration: ProviderDomainConfiguration) async throws -> URL {
        rootURL
    }
}

@MainActor
private final class FinderPreflightRemoteFactory {
    let remote: FinderPreflightRemote
    private(set) var makeCallCount = 0

    init(remote: FinderPreflightRemote) { self.remote = remote }

    func makeRemote() -> any KDriveFileProviding {
        makeCallCount += 1
        return remote
    }
}

private actor FinderPreflightRemote: KDriveFileProviding {
    let root: KDriveRemoteItem
    let marker: KDriveRemoteItem
    let markerData: Data
    private(set) var readCallCount = 0

    init(root: KDriveRemoteItem, marker: KDriveRemoteItem, markerData: Data) {
        self.root = root
        self.marker = marker
        self.markerData = markerData
    }

    func listDrives() -> [KDriveDriveSummary] {
        readCallCount += 1
        return [KDriveDriveSummary(
            id: 7,
            name: "Synthetic Drive",
            accountID: 0,
            role: "admin",
            status: "active",
            isInMaintenance: false
        )]
    }

    func item(driveID: Int, fileID: Int) throws -> KDriveRemoteItem {
        readCallCount += 1
        if fileID == root.id { return root }
        if fileID == marker.id { return marker }
        throw FinderPreflightRemoteError.unexpectedCall
    }

    func downloadFile(driveID: Int, fileID: Int) throws -> Data {
        readCallCount += 1
        guard fileID == marker.id else { throw FinderPreflightRemoteError.unexpectedCall }
        return markerData
    }

    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) throws -> KDriveItemPage { throw FinderPreflightRemoteError.unexpectedCall }
    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) throws -> KDriveAdvancedItemPage { throw FinderPreflightRemoteError.unexpectedCall }
    func listTrash(driveID: Int, cursor: String?, limit: Int) throws -> KDriveItemPage { throw FinderPreflightRemoteError.unexpectedCall }
    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) throws -> Data { throw FinderPreflightRemoteError.unexpectedCall }
    func uploadFile(driveID: Int, parentID: Int, fileName: String, contents: Data, lastModifiedAt: Date?, conflictStrategy: KDriveUploadConflictStrategy, clientToken: String?, contentHash: String?) throws -> KDriveRemoteItem { throw FinderPreflightRemoteError.unexpectedCall }
    func replaceFile(driveID: Int, fileID: Int, expectedETag: String, clientToken: String, contentHash: String, contents: Data, lastModifiedAt: Date?) throws -> KDriveRemoteItem { throw FinderPreflightRemoteError.unexpectedCall }
    func createDirectory(driveID: Int, parentID: Int, name: String) throws -> KDriveRemoteItem { throw FinderPreflightRemoteError.unexpectedCall }
    func renameItem(driveID: Int, fileID: Int, name: String) throws { throw FinderPreflightRemoteError.unexpectedCall }
    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) throws { throw FinderPreflightRemoteError.unexpectedCall }
    func updateModificationDate(driveID: Int, fileID: Int, date: Date) throws { throw FinderPreflightRemoteError.unexpectedCall }
    func trashItem(driveID: Int, fileID: Int) throws { throw FinderPreflightRemoteError.unexpectedCall }
    func deleteTrashedItem(driveID: Int, fileID: Int) throws { throw FinderPreflightRemoteError.unexpectedCall }
}

private enum FinderPreflightRemoteError: Error { case unexpectedCall }

private func finderPreflightItem(id: Int, parentID: Int, type: String) -> KDriveRemoteItem {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    return KDriveRemoteItem(
        id: id,
        name: "Synthetic Item",
        type: type,
        status: "active",
        driveID: 7,
        parentID: parentID,
        path: nil,
        size: type == "file" ? 10 : nil,
        mimeType: type == "file" ? "application/json" : nil,
        createdAt: date,
        modifiedAt: date,
        revisedAt: date,
        updatedAt: date,
        etag: "synthetic-etag"
    )
}
#endif
