import Foundation
import PotassiumProviderCore
import Testing

@Suite("Stability Finder evidence")
struct StabilityFinderEvidenceTests {
    @Test func finderRunOwnershipAndStepCorrelationAreExclusive() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let ordinary = try await coordinator.startRun(buildRevision: nil)

        await #expect(throws: ProviderDiagnosticStoreError.runAlreadyActive) {
            _ = try await coordinator.startOwnedRun(buildRevision: nil)
        }
        _ = try await coordinator.finishRun(
            runID: ordinary.runID,
            summary: StabilityRunSummary(
                assertionCount: 0,
                failedAssertionCount: 0,
                checkpointCount: 0
            )
        )

        let owned = try await coordinator.startOwnedRun(buildRevision: nil)
        await #expect(throws: ProviderDiagnosticStoreError.runOwnedByFinderRunner(owned.run.runID)) {
            _ = try await coordinator.finishRun(
                runID: owned.run.runID,
                summary: StabilityRunSummary(
                    assertionCount: 0,
                    failedAssertionCount: 0,
                    checkpointCount: 0
                )
            )
        }

        let correlationID = UUID()
        try await coordinator.beginFinderStep(ownedRun: owned, correlationID: correlationID)
        #expect(try StabilityRunLocator.activeFinderStepCorrelation(rootDirectoryURL: root) == correlationID)
        await #expect(throws: ProviderDiagnosticStoreError.finderStepAlreadyActive) {
            try await coordinator.beginFinderStep(
                ownedRun: owned,
                correlationID: UUID()
            )
        }
        await #expect(throws: ProviderDiagnosticStoreError.finderStepCorrelationMismatch) {
            try await coordinator.endFinderStep(
                ownedRun: owned,
                correlationID: UUID()
            )
        }
        try await coordinator.endFinderStep(ownedRun: owned, correlationID: correlationID)
        #expect(try StabilityRunLocator.activeFinderStepCorrelation(rootDirectoryURL: root) == nil)

        let report = try passingReport()
        try await recordPassingDiagnostics(report, in: owned.run)
        try await coordinator.writeFinderEvidence(
            ownedRun: owned,
            report: report,
            observations: passingObservations(for: report)
        )
        await #expect(throws: ProviderDiagnosticStoreError.finderSummaryMismatch) {
            _ = try await coordinator.finishOwnedRun(
                owned,
                summary: StabilityRunSummary(
                    assertionCount: 32,
                    failedAssertionCount: 0,
                    checkpointCount: 0
                )
            )
        }
        #expect(FileManager.default.fileExists(atPath: owned.run.summaryURL.path) == false)
        _ = try await coordinator.finishOwnedRun(
            owned,
            summary: StabilityRunSummary(
                assertionCount: 32,
                failedAssertionCount: 0,
                checkpointCount: 4
            )
        )
        #expect(try await coordinator.activeRun() == nil)
    }

    @Test func failedEvidenceAssemblyNeverSealsAndCanBeRetried() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let owned = try await coordinator.startOwnedRun(buildRevision: nil)
        let report = try passingReport()
        let observations = passingObservations(for: report)
        try await recordPassingDiagnostics(report, in: owned.run)

        try FileManager.default.removeItem(at: owned.run.observationsURL)
        try FileManager.default.createDirectory(
            at: owned.run.observationsURL,
            withIntermediateDirectories: false
        )
        await #expect(throws: ProviderDiagnosticStoreError.self) {
            try await coordinator.writeFinderEvidence(
                ownedRun: owned,
                report: report,
                observations: observations
            )
        }
        #expect(FileManager.default.fileExists(atPath: owned.run.finderReportURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: owned.run.summaryURL.path) == false)
        #expect(try Data(contentsOf: owned.run.assertionsURL).isEmpty == false)

        try FileManager.default.removeItem(at: owned.run.observationsURL)
        try Data().write(to: owned.run.observationsURL, options: .withoutOverwriting)
        try await coordinator.writeFinderEvidence(
            ownedRun: owned,
            report: report,
            observations: observations
        )
        #expect(FileManager.default.fileExists(atPath: owned.run.finderReportURL.path))
    }

    @Test func deadFinderOwnerCanBeExplicitlyAbandonedWithoutSealingEvidence() async throws {
        let root = try temporaryDirectory()
        let owner = StabilityRunCoordinator(
            rootDirectoryURL: root,
            processIdentifier: Int32.max
        )
        let owned = try await owner.startOwnedRun(buildRevision: nil)
        try await owner.beginFinderStep(ownedRun: owned, correlationID: UUID())

        let recovery = StabilityRunCoordinator(rootDirectoryURL: root)
        let abandoned = try await recovery.abandonStaleOwnedRun()
        #expect(abandoned.runID == owned.run.runID)
        #expect(FileManager.default.fileExists(atPath: abandoned.finderAbandonedURL.path))
        #expect(try await recovery.activeRun() == nil)
        #expect(try StabilityRunLocator.activeFinderStepCorrelation(rootDirectoryURL: root) == nil)
        await #expect(throws: ProviderDiagnosticStoreError.runAbandonedByFinderRunner(
            owned.run.runID
        )) {
            _ = try await recovery.finishRun(
                runID: owned.run.runID,
                summary: StabilityRunSummary(
                    assertionCount: 0,
                    failedAssertionCount: 0,
                    checkpointCount: 0
                )
            )
        }

        let next = try await recovery.startRun(buildRevision: nil)
        _ = try await recovery.finishRun(
            runID: next.runID,
            summary: StabilityRunSummary(
                assertionCount: 0,
                failedAssertionCount: 0,
                checkpointCount: 0
            )
        )
    }

    @Test func liveFinderOwnerCannotBeAbandoned() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        _ = try await coordinator.startOwnedRun(buildRevision: nil)

        await #expect(throws: ProviderDiagnosticStoreError.finderOwnerProcessStillRunning) {
            _ = try await coordinator.abandonStaleOwnedRun()
        }
        #expect(try await coordinator.activeRun() != nil)
    }

    @Test func ordinaryRunIsNotEligibleForStaleFinderRecovery() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let ordinary = try await coordinator.startRun(buildRevision: nil)

        await #expect(throws: ProviderDiagnosticStoreError.noStaleFinderRun) {
            _ = try await coordinator.abandonStaleOwnedRun()
        }
        _ = try await coordinator.finishRun(
            runID: ordinary.runID,
            summary: StabilityRunSummary(
                assertionCount: 0,
                failedAssertionCount: 0,
                checkpointCount: 0
            )
        )
    }

    @Test func coordinatorWritesClosedImmutableFinderEvidence() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let ownedRun = try await coordinator.startOwnedRun(buildRevision: "abc123")
        let handle = ownedRun.run
        let report = try passingReport()
        let observations = passingObservations(for: report)
        try await recordPassingDiagnostics(report, in: handle)

        try await coordinator.writeFinderEvidence(
            ownedRun: ownedRun,
            report: report,
            observations: observations
        )

        let decodedReport = try JSONDecoder.stability.decode(
            StabilityFinderRunReport.self,
            from: Data(contentsOf: handle.finderReportURL)
        )
        #expect(decodedReport == report)
        #expect(try Data(contentsOf: handle.assertionsURL).split(separator: 0x0A).count == StabilityFinderPreflightCheck.allCases.count + StabilityFinderScenario.allCases.count)
        #expect(try Data(contentsOf: handle.observationsURL).split(separator: 0x0A).count == 32)

        for url in [handle.finderReportURL, handle.assertionsURL, handle.observationsURL] {
            let text = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
            for prohibited in [
                "\"name\":", "\"path\":", "\"url\":",
                "\"account\":", "\"accountIdentifier\":", "\"driveID\":",
                "\"fileID\":", "\"remoteID\":", "\"requestBody\":",
                "\"responseBody\":", "\"authorization\":", "\"shareLink\":",
            ] {
                #expect(text.localizedCaseInsensitiveContains(prohibited) == false)
            }
        }

        await #expect(throws: ProviderDiagnosticStoreError.finderEvidenceAlreadyFinalized(handle.runID)) {
            try await coordinator.writeFinderEvidence(
                ownedRun: ownedRun,
                report: report,
                observations: observations
            )
        }
    }

    @Test func passedStepsRequireUniqueCorrelatedBaselineAndPostconditions() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let first = try await coordinator.startOwnedRun(buildRevision: nil)
        let report = try passingReport()
        var missing = passingObservations(for: report)
        missing.removeFirst()

        await #expect(throws: StabilityFinderEvidenceValidationError.missingPassedObservation(
            scenario: .enumerationAndChangeAnchors,
            phase: .baseline
        )) {
            try await coordinator.writeFinderEvidence(
                ownedRun: first,
                report: report,
                observations: missing
            )
        }

        var duplicate = passingObservations(for: report)
        duplicate.append(duplicate[0])
        await #expect(throws: StabilityFinderEvidenceValidationError.duplicateObservation(
            scenario: .enumerationAndChangeAnchors,
            phase: .baseline
        )) {
            try await coordinator.writeFinderEvidence(
                ownedRun: first,
                report: report,
                observations: duplicate
            )
        }
    }

    @Test func passedStepsRequireScenarioSpecificCorrelatedTerminalDiagnostics() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let owned = try await coordinator.startOwnedRun(buildRevision: nil)
        let report = try passingReport()

        await #expect(throws: StabilityFinderEvidenceValidationError.missingDiagnosticEvidence(
            .enumerationAndChangeAnchors
        )) {
            try await coordinator.writeFinderEvidence(
                ownedRun: owned,
                report: report,
                observations: passingObservations(for: report)
            )
        }

        let store = try KDriveProviderEventJSONLStore(runDirectoryURL: owned.run.directoryURL)
        let firstStep = try #require(report.stepResults.first)
        try await store.recordDiagnostic(ProviderDiagnosticEvent(
            correlationID: firstStep.correlationID,
            source: .finderRunner,
            operation: .enumerateItems,
            phase: .completed
        ))
        await #expect(throws: StabilityFinderEvidenceValidationError.missingDiagnosticEvidence(
            .enumerationAndChangeAnchors
        )) {
            try await coordinator.writeFinderEvidence(
                ownedRun: owned,
                report: report,
                observations: passingObservations(for: report)
            )
        }

        try await store.recordDiagnostic(ProviderDiagnosticEvent(
            correlationID: firstStep.correlationID,
            source: .fileProviderExtension,
            operation: .enumerateItems,
            phase: .completed
        ))
        await #expect(throws: StabilityFinderEvidenceValidationError.missingDiagnosticEvidence(
            .enumerationAndChangeAnchors
        )) {
            try await coordinator.writeFinderEvidence(
                ownedRun: owned,
                report: report,
                observations: passingObservations(for: report)
            )
        }

        try await recordPassingDiagnostics(report, in: owned.run)
        try await coordinator.writeFinderEvidence(
            ownedRun: owned,
            report: report,
            observations: passingObservations(for: report)
        )
    }

    private func passingReport() throws -> StabilityFinderRunReport {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let preflight = StabilityFinderPreflightCheck.allCases.map {
            StabilityFinderPreflightResult(check: $0, outcome: .passed, recordedAt: startedAt)
        }
        let steps = StabilityFinderScenario.allCases.enumerated().map { index, scenario in
            let isCheckpoint = scenario.diagnosticRequirement == nil
            return StabilityFinderStepResult(
                sequenceNumber: UInt16(index + 1),
                scenario: scenario,
                correlationID: correlationID(index),
                startedAt: startedAt.addingTimeInterval(TimeInterval(index + 1)),
                finishedAt: startedAt.addingTimeInterval(TimeInterval(index + 2)),
                outcome: isCheckpoint
                    ? .checkpoint(checkpointReason(for: scenario))
                    : .passed,
                assertions: StabilityFinderAssertionClass.allCases.map {
                    StabilityFinderAssertionResult(
                        assertionClass: $0,
                        outcome: isCheckpoint ? .notEvaluated(.checkpointReached) : .passed
                    )
                }
            )
        }
        return try StabilityFinderRunReport(
            correlationID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(30),
            preflightResults: preflight,
            stepResults: steps
        )
    }

    private func passingObservations(
        for report: StabilityFinderRunReport
    ) -> [StabilityFinderAPIObservation] {
        report.stepResults.flatMap { step in
            StabilityFinderAPIObservationPhase.allCasesForEvidence.map { phase in
                StabilityFinderAPIObservation(
                    scenario: step.scenario,
                    correlationID: step.correlationID,
                    phase: phase,
                    outcome: .passed,
                    recordedAt: step.finishedAt,
                    hasMore: false,
                    itemCount: 2
                )
            }
        }
    }

    private func correlationID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", index + 1))!
    }

    private func checkpointReason(
        for scenario: StabilityFinderScenario
    ) -> StabilityFinderCheckpointReason {
        switch scenario {
        case .restore:
            .scopedRestoreWorkflowRequired
        case .permanentDeletion:
            .scopedPermanentDeletionWorkflowRequired
        case .cancellationAndProgress:
            .finderCancellationRequired
        case .supportedContextualActions:
            .variableContextualUI
        default:
            .variableContextualUI
        }
    }

    private func recordPassingDiagnostics(
        _ report: StabilityFinderRunReport,
        in run: StabilityRunHandle
    ) async throws {
        let store = try KDriveProviderEventJSONLStore(runDirectoryURL: run.directoryURL)
        for step in report.stepResults where step.outcome == .passed {
            let requirement = try #require(step.scenario.diagnosticRequirement)
            for operationGroup in requirement.operationGroups {
                let operation = try #require(operationGroup.sorted {
                    $0.rawValue < $1.rawValue
                }.first)
                try await store.recordDiagnostic(ProviderDiagnosticEvent(
                    correlationID: step.correlationID,
                    source: requirement.source,
                    operation: operation,
                    phase: .completed,
                    statusClass: .success
                ))
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StabilityFinderEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension StabilityFinderAPIObservationPhase {
    static var allCasesForEvidence: [Self] { [.baseline, .postcondition] }
}

private extension JSONDecoder {
    static var stability: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
