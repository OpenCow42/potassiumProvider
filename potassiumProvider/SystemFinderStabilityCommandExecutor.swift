#if os(macOS) && STABILITY
import AppKit
import ApplicationServices
import CoreServices
import FileProvider
import Foundation
import PotassiumProviderCore

@MainActor
final class SystemFinderStabilityCommandExecutor: FinderStabilityCommandExecuting {
    private let contextLoader: FinderStabilityContextLoader
    private let permissionChecker: any FinderStabilityPermissionChecking
    private let scenarioRunner: any FinderStabilityScenarioRunning

    init() {
        self.contextLoader = FinderStabilityContextLoader()
        self.permissionChecker = SystemFinderStabilityPermissionChecker()
        self.scenarioRunner = LiveFinderStabilityScenarioRunner()
    }

    init(
        contextLoader: FinderStabilityContextLoader,
        permissionChecker: any FinderStabilityPermissionChecking,
        scenarioRunner: any FinderStabilityScenarioRunning
    ) {
        self.contextLoader = contextLoader
        self.permissionChecker = permissionChecker
        self.scenarioRunner = scenarioRunner
    }

    func preflight(requestPermissions: Bool) async -> FinderStabilityCommandResult {
        do {
            let context = try await contextLoader.loadPreflight()
            let results = FinderStabilityPreflightEvaluator.results(
                permissions: permissionChecker.check(requestPermissions: requestPermissions),
                hasFileProviderRegistration: true,
                hasVerifiedFileProviderConsent: context.hasVerifiedFileProviderConsent,
                labSafetyAllowed: true,
                recordedAt: Date()
            )
            return FinderStabilityPreflightEvaluator.commandResult(for: results)
        } catch {
            return .rejected
        }
    }

    func run(requestPermissions: Bool) async -> FinderStabilityCommandResult {
        let preflightContext: FinderStabilityPreflightContext
        do {
            preflightContext = try await contextLoader.loadPreflight()
        } catch {
            return .rejected
        }

        let reportStartedAt = Date()
        let preflight = FinderStabilityPreflightEvaluator.results(
            permissions: permissionChecker.check(requestPermissions: requestPermissions),
            hasFileProviderRegistration: true,
            hasVerifiedFileProviderConsent: preflightContext.hasVerifiedFileProviderConsent,
            labSafetyAllowed: true,
            recordedAt: Date()
        )
        let preflightCommandResult = FinderStabilityPreflightEvaluator.commandResult(for: preflight)
        let runCoordinator: StabilityRunCoordinator
        let ownedRun: StabilityOwnedRunHandle
        do {
            runCoordinator = try StabilityRunCoordinator()
            ownedRun = try await runCoordinator.startOwnedRun()
        } catch {
            return .failed
        }
        let context: FinderStabilityLiveContext
        do {
            // Reconstruct after the run starts so typed network spans bind to
            // this run's active JSONL recorder instead of a cached nil sink.
            context = try await contextLoader.load(
                ownedRun: ownedRun,
                runCoordinator: runCoordinator
            )
        } catch {
            // Never seal a run without its required Finder report. The active
            // owner marker and partial bundle remain intact for explicit stale
            // owner recovery after this process exits.
            return .failed
        }

        let execution: FinderStabilityScenarioExecution
        if preflightCommandResult == .ready {
            execution = await scenarioRunner.run(context: context)
        } else {
            let skipReason: StabilityFinderStepSkipReason = preflightCommandResult == .checkpoint
                ? .preflightCheckpoint
                : .preflightFailure
            execution = FinderStabilityScenarioExecution.skippingAll(
                reason: skipReason,
                startedAt: reportStartedAt
            )
        }

        do {
            let report = try StabilityFinderRunReport(
                correlationID: UUID(),
                startedAt: reportStartedAt,
                finishedAt: Date(),
                preflightResults: preflight,
                stepResults: execution.stepResults
            )
            try await runCoordinator.writeFinderEvidence(
                ownedRun: ownedRun,
                report: report,
                observations: execution.observations
            )
            _ = try await runCoordinator.finishOwnedRun(
                ownedRun,
                summary: StabilityRunSummary(
                    assertionCount: report.stepResults.flatMap(\.assertions).count,
                    failedAssertionCount: report.stepResults.flatMap(\.assertions).filter {
                        if case .failed = $0.outcome { return true }
                        return false
                    }.count,
                    checkpointCount: report.preflightSummary.checkpointed
                        + report.stepSummary.checkpointed
                )
            )
            _ = try await runCoordinator.pruneCompletedRuns()

            if report.preflightSummary.failed > 0 || report.stepSummary.failed > 0 {
                return .failed
            }
            if report.preflightSummary.checkpointed > 0 || report.stepSummary.checkpointed > 0 {
                return .checkpoint
            }
            return .completed
        } catch {
            // A report is the commit marker for the two evidence JSONL files.
            // Do not create summary.json after any assembly/finalization
            // failure, because that would seal a partial bundle.
            return .failed
        }
    }

    func recoverStaleRun() async -> FinderStabilityCommandResult {
        do {
            let runCoordinator = try StabilityRunCoordinator()
            _ = try await runCoordinator.abandonStaleOwnedRun()
            return .recovered
        } catch ProviderDiagnosticStoreError.finderOwnerProcessStillRunning {
            return .rejected
        } catch ProviderDiagnosticStoreError.noStaleFinderRun {
            return .rejected
        } catch {
            return .failed
        }
    }

}

enum FinderStabilityPreflightEvaluator {
    static func results(
        permissions: FinderStabilityPermissionSnapshot,
        hasFileProviderRegistration: Bool,
        hasVerifiedFileProviderConsent: Bool,
        labSafetyAllowed: Bool,
        recordedAt: Date
    ) -> [StabilityFinderPreflightResult] {
        let outcomes: [StabilityFinderPreflightCheck: StabilityFinderPreflightOutcome] = [
            .accessibilityPermission: permissions.accessibilityOutcome,
            .finderAutomationPermission: permissions.automationOutcome,
            .fileProviderRegistration: hasFileProviderRegistration
                ? .passed
                : .failed(.fileProviderNotRegistered),
            .fileProviderConsent: hasVerifiedFileProviderConsent
                ? .passed
                : .checkpoint(.fileProviderConsentRequired),
            .stabilityLabSafety: labSafetyAllowed
                ? .passed
                : .failed(.stabilityLabRejected),
        ]
        return StabilityFinderPreflightCheck.allCases.map { check in
            StabilityFinderPreflightResult(
                check: check,
                outcome: outcomes[check] ?? .failed(.permissionStateUnavailable),
                recordedAt: recordedAt
            )
        }
    }

    static func commandResult(
        for results: [StabilityFinderPreflightResult]
    ) -> FinderStabilityCommandResult {
        if results.contains(where: {
            if case .failed = $0.outcome { return true }
            return false
        }) {
            return .rejected
        }
        if results.contains(where: {
            if case .checkpoint = $0.outcome { return true }
            return false
        }) {
            return .checkpoint
        }
        return .ready
    }
}

struct FinderStabilityPermissionSnapshot: Equatable, Sendable {
    let accessibilityOutcome: StabilityFinderPreflightOutcome
    let automationOutcome: StabilityFinderPreflightOutcome
}

protocol FinderStabilityPermissionChecking: Sendable {
    nonisolated func check(requestPermissions: Bool) -> FinderStabilityPermissionSnapshot
}

struct SystemFinderStabilityPermissionChecker: FinderStabilityPermissionChecking {
    nonisolated func check(requestPermissions: Bool) -> FinderStabilityPermissionSnapshot {
        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: requestPermissions,
        ] as CFDictionary
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(accessibilityOptions)
        let accessibility: StabilityFinderPreflightOutcome = accessibilityTrusted
            ? .passed
            : .checkpoint(.accessibilityConsentRequired)

        let automation: StabilityFinderPreflightOutcome
        var target = AEAddressDesc()
        let finderBundleIdentifier = Data("com.apple.finder".utf8)
        let descriptorStatus = finderBundleIdentifier.withUnsafeBytes { bytes in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                bytes.baseAddress,
                finderBundleIdentifier.count,
                &target
            )
        }
        if descriptorStatus != noErr {
            automation = .failed(.permissionStateUnavailable)
        } else {
            defer { AEDisposeDesc(&target) }
            let status = AEDeterminePermissionToAutomateTarget(
                &target,
                AEEventClass(kAECoreSuite),
                AEEventID(kAEGetData),
                requestPermissions
            )
            switch status {
            case noErr:
                automation = .passed
            case OSStatus(errAEEventNotPermitted):
                automation = .checkpoint(.finderAutomationConsentRequired)
            default:
                automation = .failed(.finderUnavailable)
            }
        }
        return FinderStabilityPermissionSnapshot(
            accessibilityOutcome: accessibility,
            automationOutcome: automation
        )
    }
}

@MainActor
struct FinderStabilityLiveContext {
    let domain: ProviderDomainConfiguration
    let remoteConfiguration: StabilityLabRemoteConfiguration
    let remote: any KDriveFileProviding
    let rootURL: URL
    let fileProviderManager: NSFileProviderManager
    let hasVerifiedFileProviderConsent: Bool
    let verifySafety: @MainActor () async throws -> Void
    let beginStep: @MainActor (UUID) async throws -> Void
    let endStep: @MainActor (UUID) async throws -> Void
}

@MainActor
struct FinderStabilityPreflightContext {
    let hasVerifiedFileProviderConsent: Bool
    let verifySafety: @MainActor () async throws -> Void
}

struct FinderStabilityContextLoader {
    typealias RemoteFactory = @MainActor (
        _ accessToken: String,
        _ recorder: (any ProviderDiagnosticRecording)?
    ) -> any KDriveFileProviding
    typealias VisibleDomainResolver = @MainActor (
        _ rootURL: URL
    ) async throws -> FinderStabilityVisibleItemBinding

    private let accountStoreProvider: @MainActor () throws -> any ProviderAccountStoring
    private let domainStoreProvider: @MainActor () throws -> any DomainConfigurationStoring
    private let tokenStore: any OAuthTokenStoring
    private let registrar: any ProviderDomainRegistering
    private let remoteFactory: RemoteFactory
    private let visibleDomainResolver: VisibleDomainResolver

    @MainActor
    init() {
        self.accountStoreProvider = { try ProviderAccountFileStore() }
        self.domainStoreProvider = { try DomainConfigurationFileStore() }
        self.tokenStore = KeychainOAuthTokenStore(
            accessGroup: ProviderConstants.keychainAccessGroup
        )
        self.registrar = FileProviderDomainRegistrar()
        self.remoteFactory = { accessToken, recorder in
            PotassiumKDriveService(
                bearerToken: accessToken,
                diagnosticRecorder: recorder,
                diagnosticSource: .finderRunner
            )
        }
        self.visibleDomainResolver = { rootURL in
            let resolved = try await Self.identifier(for: rootURL)
            return FinderStabilityVisibleItemBinding(
                itemIdentifier: resolved.0.rawValue,
                domainIdentifier: resolved.1.rawValue
            )
        }
    }

    @MainActor
    init(
        accountStore: any ProviderAccountStoring,
        domainStore: any DomainConfigurationStoring,
        tokenStore: any OAuthTokenStoring,
        registrar: any ProviderDomainRegistering,
        remoteFactory: @escaping RemoteFactory,
        visibleDomainResolver: @escaping VisibleDomainResolver
    ) {
        self.accountStoreProvider = { accountStore }
        self.domainStoreProvider = { domainStore }
        self.tokenStore = tokenStore
        self.registrar = registrar
        self.remoteFactory = remoteFactory
        self.visibleDomainResolver = visibleDomainResolver
    }

    @MainActor
    func loadPreflight() async throws -> FinderStabilityPreflightContext {
        let base = try await loadBase()
        return FinderStabilityPreflightContext(
            hasVerifiedFileProviderConsent: base.hasVerifiedFileProviderConsent,
            verifySafety: base.verifySafety
        )
    }

    @MainActor
    func load(
        ownedRun: StabilityOwnedRunHandle,
        runCoordinator: StabilityRunCoordinator
    ) async throws -> FinderStabilityLiveContext {
        let base = try await loadBase()
        let fileProviderDomain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: base.domain.domainIdentifier),
            displayName: base.domain.displayName
        )
        guard let manager = NSFileProviderManager(for: fileProviderDomain) else {
            throw FinderStabilityContextError.fileProviderNotRegistered
        }

        return FinderStabilityLiveContext(
            domain: base.domain,
            remoteConfiguration: base.remoteConfiguration,
            remote: base.remote,
            rootURL: base.rootURL,
            fileProviderManager: manager,
            hasVerifiedFileProviderConsent: base.hasVerifiedFileProviderConsent,
            verifySafety: base.verifySafety,
            beginStep: { correlationID in
                try await runCoordinator.beginFinderStep(
                    ownedRun: ownedRun,
                    correlationID: correlationID
                )
            },
            endStep: { correlationID in
                try await runCoordinator.endFinderStep(
                    ownedRun: ownedRun,
                    correlationID: correlationID
                )
            }
        )
    }

    @MainActor
    private func loadBase() async throws -> FinderStabilityBaseContext {
        guard ProviderRuntimeProfile.current == .stability else {
            throw FinderStabilityContextError.stabilityBuildRequired
        }
        let accountStore = try accountStoreProvider()
        let domainStore = try domainStoreProvider()
        let accounts = try await accountStore.allAccounts()
        let domains = try await domainStore.allConfigurations()
        guard domains.count == 1,
              let domain = domains.first,
              domain.isCompatible(with: .stability),
              let lab = domain.stabilityLab,
              accounts.first(where: { $0.accountIdentifier == domain.accountIdentifier })?
                .authenticationKind == .manualAccessToken else {
            throw FinderStabilityContextError.invalidLabConfiguration
        }

        guard try await registrar.registeredDomainIdentifiers() == [domain.domainIdentifier] else {
            throw FinderStabilityContextError.fileProviderNotRegistered
        }
        guard let token = try await tokenStore.loadToken(
            accountIdentifier: domain.accountIdentifier
        ), token.accessToken.isEmpty == false else {
            throw FinderStabilityContextError.credentialUnavailable
        }

        let recorder = try ProviderEventStoreFactory.makeDefault(
            profile: .stability
        ) as? any ProviderDiagnosticRecording
        let remote = remoteFactory(token.accessToken, recorder)
        let remoteConfiguration = StabilityLabRemoteConfiguration(
            driveID: domain.driveID,
            driveRootFileID: lab.driveRootFileID,
            rootFileID: domain.rootFileID,
            ownershipMarkerFileID: lab.markerFileID,
            ownershipMarker: lab.ownershipMarker
        )
        let coordinator = StabilityLabRemoteCoordinator(remote: remote)
        let verifyRemoteSafety: @MainActor () async throws -> Void = {
            guard try await domainStore.allConfigurations() == [domain],
                  try await registrar.registeredDomainIdentifiers() == [domain.domainIdentifier] else {
                throw FinderStabilityContextError.fileProviderNotRegistered
            }
            let observation = try await coordinator.observe(configuration: remoteConfiguration)
            let safetyResult = StabilityLabSafety.preflight(StabilityLabPreflightInput(
                expectedMarker: lab.ownershipMarker,
                expectedOwnershipMarkerFileID: lab.markerFileID,
                configuredEncryptionMode: domain.encryptionMode,
                root: observation,
                registeredDomains: [StabilityLabRegisteredDomain(
                    purpose: .stabilityLab,
                    driveID: domain.driveID,
                    rootFileID: domain.rootFileID,
                    encryptionMode: domain.encryptionMode,
                    ownershipMarkerIdentifier: lab.ownershipMarker.identifier
                )]
            ))
            guard safetyResult.isAllowed else {
                throw FinderStabilityContextError.invalidLabConfiguration
            }
        }
        try await verifyRemoteSafety()

        let rootURL = try await registrar.userVisibleRootURL(for: domain)
        let visibleRootBinding = try await visibleDomainResolver(rootURL)
        let consentMatches = FinderStabilityRootBinding.matches(
            expectedDomainIdentifier: domain.domainIdentifier,
            actualItemIdentifier: visibleRootBinding.itemIdentifier,
            actualDomainIdentifier: visibleRootBinding.domainIdentifier
        )
        let verifySafety: @MainActor () async throws -> Void = {
            try await verifyRemoteSafety()
            let currentRootBinding = try await visibleDomainResolver(rootURL)
            guard FinderStabilityRootBinding.matches(
                expectedDomainIdentifier: domain.domainIdentifier,
                actualItemIdentifier: currentRootBinding.itemIdentifier,
                actualDomainIdentifier: currentRootBinding.domainIdentifier
            ) else {
                throw FinderStabilityContextError.fileProviderNotRegistered
            }
        }

        return FinderStabilityBaseContext(
            domain: domain,
            remoteConfiguration: remoteConfiguration,
            remote: remote,
            rootURL: rootURL,
            hasVerifiedFileProviderConsent: consentMatches,
            verifySafety: verifySafety
        )
    }

    private static func identifier(
        for url: URL
    ) async throws -> (NSFileProviderItemIdentifier, NSFileProviderDomainIdentifier) {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) {
                itemIdentifier, domainIdentifier, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let itemIdentifier, let domainIdentifier {
                    continuation.resume(returning: (itemIdentifier, domainIdentifier))
                } else {
                    continuation.resume(throwing: FinderStabilityContextError.fileProviderNotRegistered)
                }
            }
        }
    }
}

struct FinderStabilityVisibleItemBinding: Equatable, Sendable {
    let itemIdentifier: String
    let domainIdentifier: String
}

enum FinderStabilityRootBinding {
    static func matches(
        expectedDomainIdentifier: String,
        actualItemIdentifier: String,
        actualDomainIdentifier: String
    ) -> Bool {
        actualItemIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue
            && actualDomainIdentifier == expectedDomainIdentifier
    }
}

@MainActor
private struct FinderStabilityBaseContext {
    let domain: ProviderDomainConfiguration
    let remoteConfiguration: StabilityLabRemoteConfiguration
    let remote: any KDriveFileProviding
    let rootURL: URL
    let hasVerifiedFileProviderConsent: Bool
    let verifySafety: @MainActor () async throws -> Void
}

enum FinderStabilityContextError: Error, Equatable, Sendable {
    case stabilityBuildRequired
    case invalidLabConfiguration
    case fileProviderNotRegistered
    case credentialUnavailable
}

@MainActor
protocol FinderStabilityScenarioRunning {
    func run(context: FinderStabilityLiveContext) async -> FinderStabilityScenarioExecution
}

struct FinderStabilityScenarioExecution: Sendable {
    let stepResults: [StabilityFinderStepResult]
    let observations: [StabilityFinderAPIObservation]

    static func skippingAll(
        reason: StabilityFinderStepSkipReason,
        startedAt: Date
    ) -> FinderStabilityScenarioExecution {
        let steps = StabilityFinderScenario.allCases.enumerated().map { index, scenario in
            StabilityFinderStepResult(
                sequenceNumber: UInt16(index + 1),
                scenario: scenario,
                correlationID: UUID(),
                startedAt: startedAt,
                finishedAt: startedAt,
                outcome: .skipped(reason),
                assertions: StabilityFinderAssertionClass.allCases.map {
                    StabilityFinderAssertionResult(
                        assertionClass: $0,
                        outcome: .notEvaluated(.stepSkipped)
                    )
                }
            )
        }
        return FinderStabilityScenarioExecution(stepResults: steps, observations: [])
    }
}
#endif
