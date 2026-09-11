import Foundation
import PotassiumProviderCore
import Testing

@Suite("Stability Finder run model")
struct StabilityFinderRunModelTests {
    @Test func deferredDeletionIsVersionedAndNeverCountsAsPassed() throws {
        var steps = passingSteps()
        steps[11] = step(sequenceNumber: 12, scenario: .permanentDeletion,
            outcome: .skipped(.permanentDeletionNotSelected), assertionOutcome: .notEvaluated(.stepSkipped))
        let report = try StabilityFinderRunReport(schemaVersion: StabilityFinderRunReport.selectiveSchemaVersion,
            correlationID: UUID(), startedAt: timestamp(0), finishedAt: timestamp(20),
            preflightResults: passingPreflight(), stepResults: steps)
        #expect(report.hasOnlyDeferredPermanentDeletion)
        #expect(report.stepSummary.passed == 15 && report.stepSummary.skipped == 1)
        #expect(try JSONDecoder().decode(StabilityFinderRunReport.self, from: JSONEncoder().encode(report)) == report)
        for version in [StabilityFinderRunReport.currentSchemaVersion, StabilityFinderRunReport.liveSchemaVersion] {
            #expect(throws: StabilityFinderRunValidationError.invalidStepDeferral(.permanentDeletion)) {
                try StabilityFinderRunReport(schemaVersion: version, correlationID: UUID(),
                    startedAt: timestamp(0), finishedAt: timestamp(20), preflightResults: passingPreflight(), stepResults: steps)
            }
            let historical = try StabilityFinderRunReport(schemaVersion: version, correlationID: UUID(),
                startedAt: timestamp(0), finishedAt: timestamp(20), preflightResults: passingPreflight(), stepResults: passingSteps())
            #expect(try JSONDecoder().decode(StabilityFinderRunReport.self, from: JSONEncoder().encode(historical)) == historical)
            #expect(!historical.hasOnlyDeferredPermanentDeletion)
        }
        steps[12] = step(sequenceNumber: 13, scenario: .concurrentRemotePreserveBoth,
            outcome: .failed(.operationFailed), assertionOutcome: .notEvaluated(.operationDidNotReachAssertion))
        let failed = try StabilityFinderRunReport(schemaVersion: StabilityFinderRunReport.selectiveSchemaVersion,
            correlationID: UUID(), startedAt: timestamp(0), finishedAt: timestamp(20), preflightResults: passingPreflight(), stepResults: steps)
        #expect(!failed.hasOnlyDeferredPermanentDeletion)
        steps[12] = step(sequenceNumber: 13, scenario: .concurrentRemotePreserveBoth,
            outcome: .skipped(.permanentDeletionNotSelected), assertionOutcome: .notEvaluated(.stepSkipped))
        #expect(throws: StabilityFinderRunValidationError.invalidStepDeferral(.concurrentRemotePreserveBoth)) {
            try StabilityFinderRunReport(schemaVersion: StabilityFinderRunReport.selectiveSchemaVersion,
                correlationID: UUID(), startedAt: timestamp(0), finishedAt: timestamp(20), preflightResults: passingPreflight(), stepResults: steps)
        }
    }

    @Test func standardSequenceCoversEveryPlannedScenario() {
        #expect(StabilityFinderScenario.allCases == [
            .enumerationAndChangeAnchors,
            .hydrate,
            .evict,
            .download,
            .fileCreate,
            .directoryCreate,
            .editAndUpload,
            .rename,
            .move,
            .trash,
            .restore,
            .permanentDeletion,
            .concurrentRemotePreserveBoth,
            .cancellationAndProgress,
            .workingSetRefresh,
            .supportedContextualActions,
        ])
    }

    @Test func completedRunProducesImmutableOutcomeCounts() throws {
        let report = try makeReport()

        #expect(report.preflightSummary.passed == StabilityFinderPreflightCheck.allCases.count)
        #expect(report.preflightSummary.failed == 0)
        #expect(report.preflightSummary.checkpointed == 0)
        #expect(report.preflightSummary.skipped == 0)
        #expect(report.stepSummary.passed == StabilityFinderScenario.allCases.count)
        #expect(report.stepSummary.failed == 0)
        #expect(report.stepSummary.checkpointed == 0)
        #expect(report.stepSummary.skipped == 0)
        #expect(report.durationMilliseconds == 20_000)
    }

    @Test func checkpointsRemainDistinctFromFailuresAndSkips() throws {
        var preflight = passingPreflight()
        preflight[0] = StabilityFinderPreflightResult(
            check: .accessibilityPermission,
            outcome: .checkpoint(.accessibilityConsentRequired),
            recordedAt: timestamp(0)
        )
        var steps = passingSteps()
        steps[0] = step(
            sequenceNumber: 1,
            scenario: .enumerationAndChangeAnchors,
            outcome: .skipped(.preflightCheckpoint),
            assertionOutcome: .notEvaluated(.stepSkipped)
        )
        steps[1] = step(
            sequenceNumber: 2,
            scenario: .hydrate,
            outcome: .failed(.assertionFailed),
            assertionOutcome: .failed(.stateMismatch)
        )
        steps[15] = step(
            sequenceNumber: 16,
            scenario: .supportedContextualActions,
            outcome: .checkpoint(.variableContextualUI),
            assertionOutcome: .notEvaluated(.checkpointReached)
        )

        let report = try makeReport(preflight: preflight, steps: steps)

        #expect(report.preflightSummary.checkpointed == 1)
        #expect(report.preflightSummary.failed == 0)
        #expect(report.stepSummary.checkpointed == 1)
        #expect(report.stepSummary.skipped == 1)
        #expect(report.stepSummary.failed == 1)
    }

    @Test func checkpointReasonsAreRestrictedToTheirScenario() throws {
        var invalidCreateCheckpoint = passingSteps()
        invalidCreateCheckpoint[4] = step(
            sequenceNumber: 5,
            scenario: .fileCreate,
            outcome: .checkpoint(.scopedPermanentDeletionWorkflowRequired),
            assertionOutcome: .notEvaluated(.checkpointReached)
        )
        #expect(throws: StabilityFinderRunValidationError.invalidStepCheckpoint(
            scenario: .fileCreate,
            reason: .scopedPermanentDeletionWorkflowRequired
        )) {
            try makeReport(steps: invalidCreateCheckpoint)
        }

        var invalidRestoreCheckpoint = passingSteps()
        invalidRestoreCheckpoint[10] = step(
            sequenceNumber: 11,
            scenario: .restore,
            outcome: .checkpoint(.variableContextualUI),
            assertionOutcome: .notEvaluated(.checkpointReached)
        )
        #expect(throws: StabilityFinderRunValidationError.invalidStepCheckpoint(
            scenario: .restore,
            reason: .variableContextualUI
        )) {
            try makeReport(steps: invalidRestoreCheckpoint)
        }

        var validRestoreCheckpoint = passingSteps()
        validRestoreCheckpoint[10] = step(
            sequenceNumber: 11,
            scenario: .restore,
            outcome: .checkpoint(.scopedRestoreWorkflowRequired),
            assertionOutcome: .notEvaluated(.checkpointReached)
        )
        let validReport = try makeReport(steps: validRestoreCheckpoint)
        #expect(validReport.stepSummary.checkpointed == 1)

        let encoded = try JSONEncoder().encode(validReport)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        let tamperedText = encodedText.replacingOccurrences(
            of: "scopedRestoreWorkflowRequired",
            with: "variableContextualUI"
        )
        #expect(tamperedText != encodedText)
        #expect(throws: StabilityFinderRunValidationError.invalidStepCheckpoint(
            scenario: .restore,
            reason: .variableContextualUI
        )) {
            try JSONDecoder().decode(
                StabilityFinderRunReport.self,
                from: Data(tamperedText.utf8)
            )
        }
    }

    @Test func preflightAllowsTypedPermissionQueryFailuresButRejectsMisplacedConsentCheckpoints() throws {
        var failedConsent = passingPreflight()
        failedConsent[0] = StabilityFinderPreflightResult(
            check: .accessibilityPermission,
            outcome: .failed(.permissionStateUnavailable),
            recordedAt: timestamp(0)
        )
        #expect(try makeReport(preflight: failedConsent).preflightResults[0].outcome == .failed(.permissionStateUnavailable))

        var misplacedCheckpoint = passingPreflight()
        misplacedCheckpoint[2] = StabilityFinderPreflightResult(
            check: .fileProviderRegistration,
            outcome: .checkpoint(.accessibilityConsentRequired),
            recordedAt: timestamp(0)
        )
        #expect(throws: StabilityFinderRunValidationError.invalidPreflightOutcome(
            check: .fileProviderRegistration
        )) {
            try makeReport(preflight: misplacedCheckpoint)
        }
    }

    @Test func duplicateAndMissingTerminalStepResultsAreRejected() {
        var duplicate = passingSteps()
        duplicate[1] = step(
            sequenceNumber: 2,
            scenario: .enumerationAndChangeAnchors
        )
        #expect(throws: StabilityFinderRunValidationError.duplicateStepResult(
            .enumerationAndChangeAnchors
        )) {
            try makeReport(steps: duplicate)
        }

        let missing = Array(passingSteps().dropLast())
        #expect(throws: StabilityFinderRunValidationError.missingStepResult(
            .supportedContextualActions
        )) {
            try makeReport(steps: missing)
        }
    }

    @Test func outOfSequenceResultsAndDuplicateCorrelationsAreRejected() {
        var outOfSequence = passingSteps()
        outOfSequence.swapAt(0, 1)
        #expect(throws: StabilityFinderRunValidationError.stepOutOfSequence(
            expected: .enumerationAndChangeAnchors,
            actual: .hydrate
        )) {
            try makeReport(steps: outOfSequence)
        }

        var duplicateCorrelation = passingSteps()
        duplicateCorrelation[1] = step(
            sequenceNumber: 2,
            scenario: .hydrate,
            correlationID: duplicateCorrelation[0].correlationID
        )
        #expect(throws: StabilityFinderRunValidationError.duplicateCorrelationID(
            duplicateCorrelation[0].correlationID
        )) {
            try makeReport(steps: duplicateCorrelation)
        }
    }

    @Test func chronologicalOverlapIsRejectedEvenWhenScenarioOrderIsCorrect() {
        var steps = passingSteps()
        steps[0] = StabilityFinderStepResult(
            sequenceNumber: 1,
            scenario: .enumerationAndChangeAnchors,
            correlationID: UUID(),
            startedAt: timestamp(1),
            finishedAt: timestamp(3),
            outcome: .passed,
            assertions: passingAssertions()
        )
        steps[1] = StabilityFinderStepResult(
            sequenceNumber: 2,
            scenario: .hydrate,
            correlationID: UUID(),
            startedAt: timestamp(2),
            finishedAt: timestamp(4),
            outcome: .passed,
            assertions: passingAssertions()
        )

        #expect(throws: StabilityFinderRunValidationError.stepTimestampOutOfSequence(
            previous: .enumerationAndChangeAnchors,
            current: .hydrate
        )) {
            try makeReport(steps: steps)
        }
    }

    @Test func everyTerminalResultRequiresBothAssertionClassesExactlyOnce() {
        let missingServerAssertion = StabilityFinderStepResult(
            sequenceNumber: 1,
            scenario: .enumerationAndChangeAnchors,
            correlationID: UUID(),
            startedAt: timestamp(1),
            finishedAt: timestamp(2),
            outcome: .passed,
            assertions: [
                StabilityFinderAssertionResult(
                    assertionClass: .finderVisible,
                    outcome: .passed
                ),
            ]
        )
        var steps = passingSteps()
        steps[0] = missingServerAssertion
        #expect(throws: StabilityFinderRunValidationError.missingAssertion(
            scenario: .enumerationAndChangeAnchors,
            assertionClass: .serverAuthoritative
        )) {
            try makeReport(steps: steps)
        }

        var duplicateAssertions = passingSteps()
        duplicateAssertions[0] = StabilityFinderStepResult(
            sequenceNumber: 1,
            scenario: .enumerationAndChangeAnchors,
            correlationID: UUID(),
            startedAt: timestamp(1),
            finishedAt: timestamp(2),
            outcome: .passed,
            assertions: [
                StabilityFinderAssertionResult(assertionClass: .finderVisible, outcome: .passed),
                StabilityFinderAssertionResult(assertionClass: .finderVisible, outcome: .passed),
                StabilityFinderAssertionResult(assertionClass: .serverAuthoritative, outcome: .passed),
            ]
        )
        #expect(throws: StabilityFinderRunValidationError.duplicateAssertion(
            scenario: .enumerationAndChangeAnchors,
            assertionClass: .finderVisible
        )) {
            try makeReport(steps: duplicateAssertions)
        }
    }

    @Test func terminalOutcomeMustAgreeWithAssertionOutcomes() {
        var malformedPass = passingSteps()
        malformedPass[0] = step(
            sequenceNumber: 1,
            scenario: .enumerationAndChangeAnchors,
            outcome: .passed,
            assertionOutcome: .failed(.stateMismatch)
        )
        #expect(throws: StabilityFinderRunValidationError.assertionOutcomeMismatch(
            .enumerationAndChangeAnchors
        )) {
            try makeReport(steps: malformedPass)
        }

        var malformedCheckpoint = passingSteps()
        malformedCheckpoint[15] = step(
            sequenceNumber: 16,
            scenario: .supportedContextualActions,
            outcome: .checkpoint(.variableContextualUI),
            assertionOutcome: .passed
        )
        #expect(throws: StabilityFinderRunValidationError.assertionOutcomeMismatch(
            .supportedContextualActions
        )) {
            try makeReport(steps: malformedCheckpoint)
        }
    }

    @Test func invalidIntervalsAndDecodedDurationTamperingAreRejected() throws {
        var invalidInterval = passingSteps()
        invalidInterval[0] = StabilityFinderStepResult(
            sequenceNumber: 1,
            scenario: .enumerationAndChangeAnchors,
            correlationID: UUID(),
            startedAt: timestamp(2),
            finishedAt: timestamp(1),
            outcome: .passed,
            assertions: passingAssertions()
        )
        #expect(throws: StabilityFinderRunValidationError.invalidStepInterval(
            .enumerationAndChangeAnchors
        )) {
            try makeReport(steps: invalidInterval)
        }

        let report = try makeReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(report)
        let original = try #require(String(data: encoded, encoding: .utf8))
        let tampered = original.replacingOccurrences(
            of: "\"durationMilliseconds\":1000",
            with: "\"durationMilliseconds\":999999"
        )
        #expect(tampered != original)
        #expect(throws: StabilityFinderRunValidationError.invalidStepDuration(
            .enumerationAndChangeAnchors
        )) {
            try JSONDecoder().decode(
                StabilityFinderRunReport.self,
                from: Data(tampered.utf8)
            )
        }
    }

    @Test func reportCodableRoundTripContainsNoPrivateValueFields() throws {
        let report = try makeReport()
        let data = try JSONEncoder().encode(report)
        let encoded = try #require(String(data: data, encoding: .utf8))

        #expect(try JSONDecoder().decode(StabilityFinderRunReport.self, from: data) == report)
        for prohibitedKey in [
            "\"name\":", "\"path\":", "\"url\":", "\"accountID\":",
            "\"remoteID\":", "\"diagnosticText\":", "\"message\":",
        ] {
            #expect(encoded.contains(prohibitedKey) == false)
        }
    }

    @Test func iso8601EvidenceRoundTripPreservesMillisecondDurations() throws {
        let runStart = Date(timeIntervalSince1970: 0.125)
        let runFinish = Date(timeIntervalSince1970: 20.875)
        let preflight = StabilityFinderPreflightCheck.allCases.map {
            StabilityFinderPreflightResult(
                check: $0,
                outcome: .passed,
                recordedAt: Date(timeIntervalSince1970: 0.25)
            )
        }
        let steps = StabilityFinderScenario.allCases.enumerated().map { index, scenario in
            StabilityFinderStepResult(
                sequenceNumber: UInt16(index + 1),
                scenario: scenario,
                correlationID: UUID(),
                startedAt: Date(timeIntervalSince1970: Double(index + 1) + 0.125),
                finishedAt: Date(timeIntervalSince1970: Double(index + 1) + 0.875),
                outcome: .passed,
                assertions: passingAssertions()
            )
        }
        let report = try StabilityFinderRunReport(
            correlationID: UUID(),
            startedAt: runStart,
            finishedAt: runFinish,
            preflightResults: preflight,
            stepResults: steps
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            StabilityFinderRunReport.self,
            from: encoder.encode(report)
        )

        #expect(decoded.durationMilliseconds == 20_750)
        #expect(decoded.stepResults.map(\.durationMilliseconds) == Array(repeating: 750, count: 16))
    }

    private func makeReport(
        preflight: [StabilityFinderPreflightResult]? = nil,
        steps: [StabilityFinderStepResult]? = nil
    ) throws -> StabilityFinderRunReport {
        try StabilityFinderRunReport(
            correlationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            startedAt: timestamp(0),
            finishedAt: timestamp(20),
            preflightResults: preflight ?? passingPreflight(),
            stepResults: steps ?? passingSteps()
        )
    }

    private func passingPreflight() -> [StabilityFinderPreflightResult] {
        StabilityFinderPreflightCheck.allCases.map {
            StabilityFinderPreflightResult(
                check: $0,
                outcome: .passed,
                recordedAt: timestamp(0)
            )
        }
    }

    private func passingSteps() -> [StabilityFinderStepResult] {
        StabilityFinderScenario.allCases.enumerated().map { index, scenario in
            step(sequenceNumber: UInt16(index + 1), scenario: scenario)
        }
    }

    private func step(
        sequenceNumber: UInt16,
        scenario: StabilityFinderScenario,
        correlationID: UUID = UUID(),
        outcome: StabilityFinderStepOutcome = .passed,
        assertionOutcome: StabilityFinderAssertionOutcome = .passed
    ) -> StabilityFinderStepResult {
        StabilityFinderStepResult(
            sequenceNumber: sequenceNumber,
            scenario: scenario,
            correlationID: correlationID,
            startedAt: timestamp(Int(sequenceNumber)),
            finishedAt: timestamp(Int(sequenceNumber) + 1),
            outcome: outcome,
            assertions: StabilityFinderAssertionClass.allCases.map {
                StabilityFinderAssertionResult(
                    assertionClass: $0,
                    outcome: assertionOutcome
                )
            }
        )
    }

    private func passingAssertions() -> [StabilityFinderAssertionResult] {
        StabilityFinderAssertionClass.allCases.map {
            StabilityFinderAssertionResult(assertionClass: $0, outcome: .passed)
        }
    }

    private func timestamp(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
