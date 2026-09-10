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
    private let runCoordinatorProvider: () throws -> StabilityRunCoordinator
    private let statusWriter: (StabilityLiveStatus, StabilityRunHandle) throws -> Void

    init() {
        self.contextLoader = FinderStabilityContextLoader()
        self.permissionChecker = SystemFinderStabilityPermissionChecker()
        self.scenarioRunner = LiveFinderStabilityScenarioRunner()
        self.runCoordinatorProvider = { try StabilityRunCoordinator() }
        self.statusWriter = { try $0.write(to: $1) }
    }

    init(
        contextLoader: FinderStabilityContextLoader,
        permissionChecker: any FinderStabilityPermissionChecking,
        scenarioRunner: any FinderStabilityScenarioRunning,
        runCoordinatorProvider: @escaping () throws -> StabilityRunCoordinator = { try StabilityRunCoordinator() },
        statusWriter: @escaping (StabilityLiveStatus, StabilityRunHandle) throws -> Void = { try $0.write(to: $1) }
    ) {
        self.contextLoader = contextLoader
        self.permissionChecker = permissionChecker
        self.scenarioRunner = scenarioRunner
        self.runCoordinatorProvider = runCoordinatorProvider
        self.statusWriter = statusWriter
    }

    func provision() async -> FinderStabilityCommandResult {
        let model = PotassiumProviderAppModel(automaticallyReloadStoredState: false)
        await model.reloadStoredState()
        if model.domains.count == 1, model.stabilityLabConfiguration != nil {
            do {
                try await model.resumeStabilityLabRegistration()
                print("finder stability provision: existing lab verified and registered")
                return .ready
            } catch {
                if let safety = error as? StabilityLabRemoteCoordinatorError { print(safety.localizedDescription) }
                print("finder stability registration: type \(String(reflecting: type(of: error))); class \(ProviderDiagnosticErrorClassifier.classify(error).rawValue); code \((error as NSError).code)")
                return .failed
            }
        }
        guard model.accounts.count == 1, model.domains.isEmpty, let account = model.accounts.first else {
            print("finder stability provision: requires one saved account and no domain")
            return .rejected
        }
        await model.loadDrives(accountIdentifier: account.accountIdentifier)
        let drives = model.drives(for: account.accountIdentifier).filter(\.isUsableInternalDrive)
        guard let drive = drives.first(where: { $0.id == model.selectedDriveIDs[account.accountIdentifier] }) ?? drives.first else {
            print("finder stability provision: available drive count \(drives.count); error \(model.lastDriveDiscoveryErrorClass?.rawValue ?? "none") \(model.lastDriveDiscoveryErrorCode.map(String.init) ?? "")")
            return .rejected
        }
        await model.provisionStabilityLab(accountIdentifier: account.accountIdentifier, drive: drive)
        guard model.stabilityLabConfiguration != nil, model.errorMessage == nil else {
            print("finder stability provision: " + (model.errorMessage ?? "root creation or domain registration failed"))
            return .failed
        }
        print("finder stability provision: verified lab created inside Private")
        return .ready
    }

    func watch() async -> FinderStabilityCommandResult {
        do {
            guard let run = try StabilityDiagnosticIdentity.activeRun() else {
                print("finder stability watch: no active run")
                return .ready
            }
            var seen: Set<UUID> = []
            var previousStatus: StabilityLiveStatus?
            repeat {
                if let status = try StabilityLiveStatus.read(from: run), status != previousStatus {
                    print("run \(status.state.rawValue): \(status.scenario?.rawValue ?? "preflight")")
                    previousStatus = status
                }
                let events = try StabilityRunCoordinator.readDiagnosticEvents(from: run.eventsURL)
                for event in events where seen.insert(event.id).inserted {
                    guard [.failed, .cancelled, .checkpoint].contains(event.phase) ||
                          [.runtimeInitialize, .runtimeInvalidate].contains(event.operation) else { continue }
                    print("\(event.source.rawValue) \(event.operation.rawValue) \(event.phase.rawValue) \(event.errorClass?.rawValue ?? "") \(event.errorCode.map(String.init) ?? "")")
                }
                if try StabilityDiagnosticIdentity.activeRun()?.runID != run.runID { break }
                try await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled
            return .ready
        } catch { return .failed }
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
            for result in results { print("finder stability permission: \(result.check.rawValue) \(result.outcome)") }
            return FinderStabilityPreflightEvaluator.commandResult(for: results)
        } catch {
            return .rejected
        }
    }

    func conflicts(requestPermissions: Bool, selectedCase: StabilityLiveConflictCase?, extensionLaunchMode: StabilityExtensionLaunchMode?) async -> FinderStabilityCommandResult {
        var failed = false
        for conflict in selectedCase.map({ [$0] }) ?? StabilityLiveConflictCase.allCases {
            print("finder conflict case: " + conflict.rawValue)
            let result = await run(requestPermissions: requestPermissions, conflictCase: conflict, extensionLaunchMode: extensionLaunchMode)
            if result != .completed { failed = true }
            // An unsealed run still owns the recorder. Do not repurpose its
            // evidence or recover it automatically while the owner is alive.
            if (try? await runCoordinatorProvider().activeRun()) != nil { return .failed }
        }
        return failed ? .failed : .completed
    }

    func run(requestPermissions: Bool) async -> FinderStabilityCommandResult {
        await run(requestPermissions: requestPermissions, conflictCase: nil)
    }

    func run(requestPermissions: Bool, extensionLaunchMode: StabilityExtensionLaunchMode?) async -> FinderStabilityCommandResult {
        await run(requestPermissions: requestPermissions, conflictCase: nil, extensionLaunchMode: extensionLaunchMode)
    }

    private func run(requestPermissions: Bool, conflictCase: StabilityLiveConflictCase?, extensionLaunchMode: StabilityExtensionLaunchMode? = nil) async -> FinderStabilityCommandResult {
        let reportStartedAt = Date()
        let runCoordinator: StabilityRunCoordinator
        let ownedRun: StabilityOwnedRunHandle
        let launchController: StabilityExtensionProcessController?
        do {
            // Domain discovery or visible-root resolution may launch the
            // extension. Its first callback must already have a recorder.
            runCoordinator = try runCoordinatorProvider()
            ownedRun = try await runCoordinator.startOwnedRun()
            try statusWriter(StabilityLiveStatus(state: .preflight), ownedRun.run)
            if let conflictCase {
                try await runCoordinator.selectConflictProfile(conflictCase, ownedRun: ownedRun, extensionLaunchMode: extensionLaunchMode)
            } else if let extensionLaunchMode {
                try await runCoordinator.requireExtensionLaunch(extensionLaunchMode, ownedRun: ownedRun)
            }
            launchController = try extensionLaunchMode.map { try StabilityExtensionProcessController(mode: $0, run: ownedRun.run) }
        } catch {
            print("finder conflict: extension launch preparation could not establish the requested initial state")
            return .failed
        }
        let preflightContext: FinderStabilityPreflightContext
        do {
            preflightContext = try await contextLoader.loadPreflight()
        } catch {
            try? statusWriter(StabilityLiveStatus(state: .failed), ownedRun.run)
            // Preserve preflight diagnostics and the unsealed owned run for
            // explicit stale-owner recovery; missing context cannot certify it.
            return .rejected
        }

        var preflight = FinderStabilityPreflightEvaluator.results(
            permissions: permissionChecker.check(requestPermissions: false),
            hasFileProviderRegistration: true,
            hasVerifiedFileProviderConsent: preflightContext.hasVerifiedFileProviderConsent,
            labSafetyAllowed: true,
            recordedAt: Date()
        )
        var preflightCommandResult = FinderStabilityPreflightEvaluator.commandResult(for: preflight)
        while preflightCommandResult == .checkpoint {
            let missing = preflight.filter { if case .checkpoint = $0.outcome { return true }; return false }.map { $0.check.rawValue }.joined(separator: ", ")
            try? statusWriter(StabilityLiveStatus(state: .awaitingPermissions), ownedRun.run)
            print("finder stability paused: " + missing)
            if requestPermissions { _ = permissionChecker.check(requestPermissions: true) }
            guard await FinderRunnerPanel.awaitResume(message: "Allow the required macOS permissions, then continue. Pending: " + missing) else { break }
            do {
                try await preflightContext.verifySafety()
                preflight = FinderStabilityPreflightEvaluator.results(
                    permissions: permissionChecker.check(requestPermissions: false), hasFileProviderRegistration: true,
                    hasVerifiedFileProviderConsent: true, labSafetyAllowed: true, recordedAt: Date())
                preflightCommandResult = FinderStabilityPreflightEvaluator.commandResult(for: preflight)
            } catch { preflightCommandResult = .rejected; break }
        }
        let context: FinderStabilityLiveContext
        do {
            // Reconstruct after the run starts so typed network spans bind to
            // this run's active JSONL recorder instead of a cached nil sink.
            if preflightCommandResult == .ready {
                try await launchController?.prepare(verifySafety: preflightContext.verifySafety)
            }
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
            if let conflictCase {
                execution = await LiveFinderStabilityScenarioRunner(conflictCase: conflictCase).run(context: context)
            } else { execution = await scenarioRunner.run(context: context) }
        } else {
            let skipReason: StabilityFinderStepSkipReason = preflightCommandResult == .checkpoint
                ? .preflightCheckpoint
                : .preflightFailure
            execution = FinderStabilityScenarioExecution.skippingAll(
                reason: skipReason,
                startedAt: reportStartedAt
            )
        }

        var candidateReport: StabilityFinderRunReport?
        do {
            let report = try StabilityFinderRunReport(
                schemaVersion: StabilityFinderRunReport.liveSchemaVersion,
                correlationID: UUID(),
                startedAt: reportStartedAt,
                finishedAt: Date(),
                preflightResults: preflight,
                stepResults: execution.stepResults
            )
            candidateReport = report
            guard execution.canSeal else { throw StabilityLiveEvidenceError.incompleteRun }
            if report.stepSummary.passed > 0, let launchController {
                let launch = try launchController.evidence(report: report)
                try await runCoordinator.recordExtensionLaunch(launch, ownedRun: ownedRun)
            }
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
            // Live failures are comparison evidence. Retention is an explicit
            // maintenance operation; never prune them after a later run.

            if report.preflightSummary.failed > 0 || report.stepSummary.failed > 0 {
                return .failed
            }
            if report.preflightSummary.checkpointed > 0 || report.stepSummary.checkpointed > 0 {
                return .checkpoint
            }
            if let conflictCase {
                guard report.stepResults.first(where: { $0.scenario == conflictCase.scenario })?.outcome == .passed else { return .failed }
            } else {
                guard report.stepSummary.passed == StabilityFinderScenario.allCases.count else { return .failed }
            }
            return .completed
        } catch {
            // A report is the commit marker for the two evidence JSONL files.
            // Do not create summary.json after any assembly/finalization
            // failure, because that would seal a partial bundle.
            print("finder stability: evidence sealing rejected; reason \((error as? StabilityLiveEvidenceError)?.rawValue ?? "assemblyFailure")")
            if let candidateReport {
                do {
                    try await runCoordinator.recordFinderEvidenceRejection(
                        StabilityFinderEvidenceRejection(report: candidateReport, observations: execution.observations, error: error),
                        ownedRun: ownedRun)
                } catch { print("finder stability: rejected candidate could not be retained") }
            }
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
            .screenRecordingPermission: permissions.recordingOutcome,
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
    var recordingOutcome: StabilityFinderPreflightOutcome = .passed
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
            case OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent):
                automation = .checkpoint(.finderAutomationConsentRequired)
            default:
                automation = .failed(.finderUnavailable)
            }
        }
        return FinderStabilityPermissionSnapshot(
            accessibilityOutcome: accessibility,
            automationOutcome: automation,
            recordingOutcome: (requestPermissions ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()) ? .passed : .checkpoint(.screenRecordingConsentRequired)
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
        print("finder stability preflight: stored configuration")
        let accounts = try await accountStore.allAccounts()
        let domains = try await domainStore.allConfigurations()
        guard domains.count == 1,
              let domain = domains.first,
              domain.isCompatible(with: .stability),
              let lab = domain.stabilityLab,
              accounts.contains(where: { $0.accountIdentifier == domain.accountIdentifier }) else {
            throw FinderStabilityContextError.invalidLabConfiguration
        }

        print("finder stability preflight: domain registration")
        guard try await registrar.registeredDomainIdentifiers() == [domain.domainIdentifier] else {
            throw FinderStabilityContextError.fileProviderNotRegistered
        }
        print("finder stability preflight: Keychain authentication")
        guard var token = try await tokenStore.loadToken(
            accountIdentifier: domain.accountIdentifier
        ), token.accessToken.isEmpty == false else {
            throw FinderStabilityContextError.credentialUnavailable
        }
        if token.shouldRefresh() {
            guard let refreshToken = token.refreshToken else {
                throw FinderStabilityContextError.credentialUnavailable
            }
            token = try await KDriveOAuthClient.refresh(refreshToken: refreshToken)
            try await tokenStore.saveToken(token, accountIdentifier: domain.accountIdentifier)
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
        print("finder stability preflight: remote ownership verified; resolving visible root")

        let rootURL = try await registrar.userVisibleRootURL(for: domain)
        print("finder stability preflight: binding visible domain")
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
        try await StabilityCallbackWaiter<(NSFileProviderItemIdentifier, NSFileProviderDomainIdentifier)>().wait { completion in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) {
                itemIdentifier, domainIdentifier, error in
                if let error {
                    completion(.failure(error))
                } else if let itemIdentifier, let domainIdentifier {
                    completion(.success((itemIdentifier, domainIdentifier)))
                } else {
                    completion(.failure(FinderStabilityContextError.fileProviderNotRegistered))
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
    var canSeal = true

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
