import Foundation

/// The fixed scenario order used by the macOS Finder stability runner.
///
/// Raw values are durable report vocabulary. They intentionally describe only
/// operation classes and never carry item names, paths, URLs, or identifiers.
public enum StabilityFinderScenario: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case enumerationAndChangeAnchors
    case hydrate
    case evict
    case download
    case fileCreate
    case directoryCreate
    case editAndUpload
    case rename
    case move
    case trash
    case restore
    case permanentDeletion
    case concurrentRemotePreserveBoth
    case cancellationAndProgress
    case workingSetRefresh
    case supportedContextualActions
}

public enum StabilityFinderPreflightCheck: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case accessibilityPermission
    case finderAutomationPermission
    case fileProviderRegistration
    case fileProviderConsent
    case stabilityLabSafety
    case screenRecordingPermission
}

/// A pause that needs operator or OS-owned UI action, not a product failure.
public enum StabilityFinderCheckpointReason: String, Codable, Equatable, Hashable, Sendable {
    case accessibilityConsentRequired
    case screenRecordingConsentRequired
    case finderAutomationConsentRequired
    case fileProviderConsentRequired
    case variableContextualUI
    case scopedRestoreWorkflowRequired
    case scopedPermanentDeletionWorkflowRequired
    case finderCancellationRequired
}

public enum StabilityFinderPreflightFailure: String, Codable, Equatable, Hashable, Sendable {
    case permissionStateUnavailable
    case finderUnavailable
    case fileProviderNotRegistered
    case stabilityLabRejected
}

public enum StabilityFinderPreflightSkipReason: String, Codable, Equatable, Hashable, Sendable {
    case blockedByEarlierPreflight
}

public enum StabilityFinderPreflightOutcome: Codable, Equatable, Sendable {
    case passed
    case failed(StabilityFinderPreflightFailure)
    case checkpoint(StabilityFinderCheckpointReason)
    case skipped(StabilityFinderPreflightSkipReason)
}

public struct StabilityFinderPreflightResult: Codable, Equatable, Sendable {
    public let check: StabilityFinderPreflightCheck
    public let outcome: StabilityFinderPreflightOutcome
    public let recordedAt: Date

    public init(
        check: StabilityFinderPreflightCheck,
        outcome: StabilityFinderPreflightOutcome,
        recordedAt: Date
    ) {
        self.check = check
        self.outcome = outcome
        self.recordedAt = recordedAt
    }
}

public enum StabilityFinderAssertionClass: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case finderVisible
    case serverAuthoritative
}

public enum StabilityFinderAssertionFailure: String, Codable, Equatable, Hashable, Sendable {
    case stateMismatch
    case stateUnavailable
    case timedOut
    case diagnosticCorrelationMissing
}

public enum StabilityFinderAssertionNotEvaluatedReason: String, Codable, Equatable, Hashable, Sendable {
    case operationDidNotReachAssertion
    case checkpointReached
    case stepSkipped
}

public enum StabilityFinderAssertionOutcome: Codable, Equatable, Sendable {
    case passed
    case failed(StabilityFinderAssertionFailure)
    case notEvaluated(StabilityFinderAssertionNotEvaluatedReason)
}

public struct StabilityFinderAssertionResult: Codable, Equatable, Sendable {
    public let assertionClass: StabilityFinderAssertionClass
    public let outcome: StabilityFinderAssertionOutcome

    public init(
        assertionClass: StabilityFinderAssertionClass,
        outcome: StabilityFinderAssertionOutcome
    ) {
        self.assertionClass = assertionClass
        self.outcome = outcome
    }
}

public enum StabilityFinderStepFailure: String, Codable, Equatable, Hashable, Sendable {
    case operationFailed
    case timedOut
    case cancellationContractViolated
    case progressContractViolated
    case assertionFailed
}

public enum StabilityFinderStepSkipReason: String, Codable, Equatable, Hashable, Sendable {
    case preflightFailure
    case preflightCheckpoint
    case earlierStepFailure
    case earlierStepCheckpoint
}

/// Exactly one case is persisted for every planned step.
public enum StabilityFinderStepOutcome: Codable, Equatable, Sendable {
    case passed
    case failed(StabilityFinderStepFailure)
    case checkpoint(StabilityFinderCheckpointReason)
    case skipped(StabilityFinderStepSkipReason)
}

public struct StabilityFinderStepResult: Codable, Equatable, Sendable {
    public let sequenceNumber: UInt16
    public let scenario: StabilityFinderScenario
    public let correlationID: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let durationMilliseconds: UInt64
    public let outcome: StabilityFinderStepOutcome
    public let assertions: [StabilityFinderAssertionResult]
    public let liveEvidence: StabilityLiveStepEvidence?

    public init(
        sequenceNumber: UInt16,
        scenario: StabilityFinderScenario,
        correlationID: UUID,
        startedAt: Date,
        finishedAt: Date,
        outcome: StabilityFinderStepOutcome,
        assertions: [StabilityFinderAssertionResult],
        liveEvidence: StabilityLiveStepEvidence? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.scenario = scenario
        self.correlationID = correlationID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMilliseconds = Self.milliseconds(from: startedAt, to: finishedAt)
        self.outcome = outcome
        self.assertions = assertions
        self.liveEvidence = liveEvidence
    }

    private static func milliseconds(from startedAt: Date, to finishedAt: Date) -> UInt64 {
        guard finishedAt >= startedAt else {
            return 0
        }
        return UInt64((finishedAt.timeIntervalSince(startedAt) * 1_000).rounded())
    }
}

/// Immutable aggregate counts. `total` is derived so it cannot drift from the
/// four terminal buckets.
public struct StabilityFinderOutcomeSummary: Codable, Equatable, Sendable {
    public let passed: Int
    public let failed: Int
    public let checkpointed: Int
    public let skipped: Int

    public var total: Int {
        passed + failed + checkpointed + skipped
    }

    fileprivate init(passed: Int, failed: Int, checkpointed: Int, skipped: Int) {
        self.passed = passed
        self.failed = failed
        self.checkpointed = checkpointed
        self.skipped = skipped
    }
}

public enum StabilityFinderRunValidationError: Error, Codable, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case invalidRunInterval
    case invalidRunDuration
    case summaryMismatch
    case duplicatePreflightResult(StabilityFinderPreflightCheck)
    case missingPreflightResult(StabilityFinderPreflightCheck)
    case preflightOutOfSequence(
        expected: StabilityFinderPreflightCheck,
        actual: StabilityFinderPreflightCheck
    )
    case invalidPreflightOutcome(check: StabilityFinderPreflightCheck)
    case preflightTimestampOutOfBounds(StabilityFinderPreflightCheck)
    case duplicateStepResult(StabilityFinderScenario)
    case missingStepResult(StabilityFinderScenario)
    case stepOutOfSequence(expected: StabilityFinderScenario, actual: StabilityFinderScenario)
    case invalidSequenceNumber(scenario: StabilityFinderScenario, expected: UInt16, actual: UInt16)
    case duplicateCorrelationID(UUID)
    case invalidStepInterval(StabilityFinderScenario)
    case invalidStepDuration(StabilityFinderScenario)
    case stepTimestampOutOfBounds(StabilityFinderScenario)
    case stepTimestampOutOfSequence(
        previous: StabilityFinderScenario,
        current: StabilityFinderScenario
    )
    case duplicateAssertion(
        scenario: StabilityFinderScenario,
        assertionClass: StabilityFinderAssertionClass
    )
    case missingAssertion(
        scenario: StabilityFinderScenario,
        assertionClass: StabilityFinderAssertionClass
    )
    case assertionOutcomeMismatch(StabilityFinderScenario)
    case invalidStepCheckpoint(
        scenario: StabilityFinderScenario,
        reason: StabilityFinderCheckpointReason
    )
}

/// A validated, terminal report. Initialization succeeds only when every
/// required preflight and scenario has one ordered result and every scenario
/// has both Finder-visible and server-authoritative assertion records.
public struct StabilityFinderRunReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let liveSchemaVersion: UInt16 = 2

    public let schemaVersion: UInt16
    public let correlationID: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let durationMilliseconds: UInt64
    public let preflightResults: [StabilityFinderPreflightResult]
    public let stepResults: [StabilityFinderStepResult]
    public let preflightSummary: StabilityFinderOutcomeSummary
    public let stepSummary: StabilityFinderOutcomeSummary

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        correlationID: UUID,
        startedAt: Date,
        finishedAt: Date,
        preflightResults: [StabilityFinderPreflightResult],
        stepResults: [StabilityFinderStepResult]
    ) throws {
        guard [Self.currentSchemaVersion, Self.liveSchemaVersion].contains(schemaVersion) else {
            throw StabilityFinderRunValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard finishedAt >= startedAt else {
            throw StabilityFinderRunValidationError.invalidRunInterval
        }

        try Self.validatePreflight(
            preflightResults,
            schemaVersion: schemaVersion,
            runStartedAt: startedAt,
            runFinishedAt: finishedAt
        )
        try Self.validateSteps(
            stepResults,
            runStartedAt: startedAt,
            runFinishedAt: finishedAt
        )

        self.schemaVersion = schemaVersion
        self.correlationID = correlationID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMilliseconds = Self.milliseconds(from: startedAt, to: finishedAt)
        self.preflightResults = preflightResults
        self.stepResults = stepResults
        self.preflightSummary = Self.summary(for: preflightResults)
        self.stepSummary = Self.summary(for: stepResults)
    }

    private enum CodingKeys: String, CodingKey, Codable, Equatable, Sendable {
        case schemaVersion
        case correlationID
        case startedAt
        case finishedAt
        case durationMilliseconds
        case preflightResults
        case stepResults
        case preflightSummary
        case stepSummary
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        let correlationID = try container.decode(UUID.self, forKey: .correlationID)
        let startedAt = try container.decode(Date.self, forKey: .startedAt)
        let finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        let encodedDuration = try container.decode(UInt64.self, forKey: .durationMilliseconds)
        let preflightResults = try container.decode(
            [StabilityFinderPreflightResult].self,
            forKey: .preflightResults
        )
        let stepResults = try container.decode(
            [StabilityFinderStepResult].self,
            forKey: .stepResults
        )
        let encodedPreflightSummary = try container.decode(
            StabilityFinderOutcomeSummary.self,
            forKey: .preflightSummary
        )
        let encodedStepSummary = try container.decode(
            StabilityFinderOutcomeSummary.self,
            forKey: .stepSummary
        )

        guard [Self.currentSchemaVersion, Self.liveSchemaVersion].contains(schemaVersion) else {
            throw StabilityFinderRunValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard finishedAt >= startedAt else {
            throw StabilityFinderRunValidationError.invalidRunInterval
        }
        try Self.validatePreflight(
            preflightResults,
            schemaVersion: schemaVersion,
            runStartedAt: startedAt,
            runFinishedAt: finishedAt
        )
        try Self.validateSteps(
            stepResults,
            runStartedAt: startedAt,
            runFinishedAt: finishedAt
        )
        let decodedDuration = Self.milliseconds(from: startedAt, to: finishedAt)
        guard Self.duration(encodedDuration, isPlausibleFor: decodedDuration) else {
            throw StabilityFinderRunValidationError.invalidRunDuration
        }
        let preflightSummary = Self.summary(for: preflightResults)
        let stepSummary = Self.summary(for: stepResults)
        guard encodedPreflightSummary == preflightSummary,
              encodedStepSummary == stepSummary else {
            throw StabilityFinderRunValidationError.summaryMismatch
        }

        self.schemaVersion = schemaVersion
        self.correlationID = correlationID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMilliseconds = encodedDuration
        self.preflightResults = preflightResults
        self.stepResults = stepResults
        self.preflightSummary = preflightSummary
        self.stepSummary = stepSummary
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(correlationID, forKey: .correlationID)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
        try container.encode(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encode(preflightResults, forKey: .preflightResults)
        try container.encode(stepResults, forKey: .stepResults)
        try container.encode(preflightSummary, forKey: .preflightSummary)
        try container.encode(stepSummary, forKey: .stepSummary)
    }

    private static func validatePreflight(
        _ results: [StabilityFinderPreflightResult],
        schemaVersion: UInt16,
        runStartedAt: Date,
        runFinishedAt: Date
    ) throws {
        var seen = Set<StabilityFinderPreflightCheck>()
        for result in results where !seen.insert(result.check).inserted {
            throw StabilityFinderRunValidationError.duplicatePreflightResult(result.check)
        }
        let required = StabilityFinderPreflightCheck.allCases.filter { schemaVersion >= Self.liveSchemaVersion || seen.contains(.screenRecordingPermission) || $0 != .screenRecordingPermission }
        for check in required where !seen.contains(check) {
            throw StabilityFinderRunValidationError.missingPreflightResult(check)
        }
        for (expected, actual) in zip(required, results) {
            guard expected == actual.check else {
                throw StabilityFinderRunValidationError.preflightOutOfSequence(
                    expected: expected,
                    actual: actual.check
                )
            }
            guard actual.recordedAt >= runStartedAt,
                  actual.recordedAt <= runFinishedAt else {
                throw StabilityFinderRunValidationError.preflightTimestampOutOfBounds(
                    actual.check
                )
            }
            try validatePreflightOutcome(actual.outcome, for: actual.check)
        }
    }

    private static func validatePreflightOutcome(
        _ outcome: StabilityFinderPreflightOutcome,
        for check: StabilityFinderPreflightCheck
    ) throws {
        guard case let .checkpoint(reason) = outcome else {
            return
        }
        let isValid = switch (check, reason) {
        case (.screenRecordingPermission, .screenRecordingConsentRequired),
             (.accessibilityPermission, .accessibilityConsentRequired),
             (.finderAutomationPermission, .finderAutomationConsentRequired),
             (.fileProviderConsent, .fileProviderConsentRequired):
            true
        default:
            false
        }
        guard isValid else {
            throw StabilityFinderRunValidationError.invalidPreflightOutcome(check: check)
        }
    }

    private static func validateSteps(
        _ results: [StabilityFinderStepResult],
        runStartedAt: Date,
        runFinishedAt: Date
    ) throws {
        var seenScenarios = Set<StabilityFinderScenario>()
        for result in results where !seenScenarios.insert(result.scenario).inserted {
            throw StabilityFinderRunValidationError.duplicateStepResult(result.scenario)
        }
        for scenario in StabilityFinderScenario.allCases where !seenScenarios.contains(scenario) {
            throw StabilityFinderRunValidationError.missingStepResult(scenario)
        }

        var seenCorrelations = Set<UUID>()
        var previousResult: StabilityFinderStepResult?
        for (index, result) in results.enumerated() {
            let expectedScenario = StabilityFinderScenario.allCases[index]
            guard result.scenario == expectedScenario else {
                throw StabilityFinderRunValidationError.stepOutOfSequence(
                    expected: expectedScenario,
                    actual: result.scenario
                )
            }
            let expectedSequence = UInt16(index + 1)
            guard result.sequenceNumber == expectedSequence else {
                throw StabilityFinderRunValidationError.invalidSequenceNumber(
                    scenario: result.scenario,
                    expected: expectedSequence,
                    actual: result.sequenceNumber
                )
            }
            guard seenCorrelations.insert(result.correlationID).inserted else {
                throw StabilityFinderRunValidationError.duplicateCorrelationID(result.correlationID)
            }
            guard result.finishedAt >= result.startedAt else {
                throw StabilityFinderRunValidationError.invalidStepInterval(result.scenario)
            }
            guard result.startedAt >= runStartedAt,
                  result.finishedAt <= runFinishedAt else {
                throw StabilityFinderRunValidationError.stepTimestampOutOfBounds(result.scenario)
            }
            if let previousResult, result.startedAt < previousResult.finishedAt {
                throw StabilityFinderRunValidationError.stepTimestampOutOfSequence(
                    previous: previousResult.scenario,
                    current: result.scenario
                )
            }
            let expectedDuration = milliseconds(from: result.startedAt, to: result.finishedAt)
            guard duration(result.durationMilliseconds, isPlausibleFor: expectedDuration) else {
                throw StabilityFinderRunValidationError.invalidStepDuration(result.scenario)
            }
            try validateAssertions(for: result)
            try validateCheckpoint(for: result)
            previousResult = result
        }
    }

    private static func validateCheckpoint(for result: StabilityFinderStepResult) throws {
        guard case let .checkpoint(reason) = result.outcome else { return }
        let expectedReason: StabilityFinderCheckpointReason? = switch result.scenario {
        case .restore:
            .scopedRestoreWorkflowRequired
        case .permanentDeletion:
            .scopedPermanentDeletionWorkflowRequired
        case .cancellationAndProgress:
            .finderCancellationRequired
        case .supportedContextualActions:
            .variableContextualUI
        default:
            nil
        }
        guard reason == expectedReason else {
            throw StabilityFinderRunValidationError.invalidStepCheckpoint(
                scenario: result.scenario,
                reason: reason
            )
        }
    }

    private static func validateAssertions(for result: StabilityFinderStepResult) throws {
        var seen = Set<StabilityFinderAssertionClass>()
        for assertion in result.assertions where !seen.insert(assertion.assertionClass).inserted {
            throw StabilityFinderRunValidationError.duplicateAssertion(
                scenario: result.scenario,
                assertionClass: assertion.assertionClass
            )
        }
        for assertionClass in StabilityFinderAssertionClass.allCases where !seen.contains(assertionClass) {
            throw StabilityFinderRunValidationError.missingAssertion(
                scenario: result.scenario,
                assertionClass: assertionClass
            )
        }

        let outcomes = result.assertions.map(\.outcome)
        let isConsistent = switch result.outcome {
        case .passed:
            outcomes.allSatisfy { $0 == .passed }
        case .failed:
            outcomes.contains { outcome in
                if case .failed = outcome { return true }
                return false
            } || outcomes.allSatisfy { $0 == .notEvaluated(.operationDidNotReachAssertion) }
        case .checkpoint:
            outcomes.allSatisfy { $0 == .notEvaluated(.checkpointReached) }
        case .skipped:
            outcomes.allSatisfy { $0 == .notEvaluated(.stepSkipped) }
        }
        guard isConsistent else {
            throw StabilityFinderRunValidationError.assertionOutcomeMismatch(result.scenario)
        }
    }

    private static func summary(
        for results: [StabilityFinderPreflightResult]
    ) -> StabilityFinderOutcomeSummary {
        var passed = 0
        var failed = 0
        var checkpointed = 0
        var skipped = 0
        for result in results {
            switch result.outcome {
            case .passed: passed += 1
            case .failed: failed += 1
            case .checkpoint: checkpointed += 1
            case .skipped: skipped += 1
            }
        }
        return StabilityFinderOutcomeSummary(
            passed: passed,
            failed: failed,
            checkpointed: checkpointed,
            skipped: skipped
        )
    }

    private static func summary(
        for results: [StabilityFinderStepResult]
    ) -> StabilityFinderOutcomeSummary {
        var passed = 0
        var failed = 0
        var checkpointed = 0
        var skipped = 0
        for result in results {
            switch result.outcome {
            case .passed: passed += 1
            case .failed: failed += 1
            case .checkpoint: checkpointed += 1
            case .skipped: skipped += 1
            }
        }
        return StabilityFinderOutcomeSummary(
            passed: passed,
            failed: failed,
            checkpointed: checkpointed,
            skipped: skipped
        )
    }

    private static func milliseconds(from startedAt: Date, to finishedAt: Date) -> UInt64 {
        UInt64((finishedAt.timeIntervalSince(startedAt) * 1_000).rounded())
    }

    /// The run-bundle encoder uses ISO-8601 timestamps, which omit fractional
    /// seconds. The stored duration keeps millisecond precision, so decoding
    /// may legitimately differ from the timestamps by at most 999 ms.
    private static func duration(_ duration: UInt64, isPlausibleFor expected: UInt64) -> Bool {
        let difference = duration >= expected ? duration - expected : expected - duration
        return difference <= 999
    }
}
