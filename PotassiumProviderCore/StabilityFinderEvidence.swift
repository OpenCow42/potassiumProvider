import Foundation

public enum StabilityFinderAPIObservationPhase: String, Codable, Equatable, Hashable, Sendable {
    case baseline
    case postcondition
}

public enum StabilityFinderAPIObservationOutcome: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case checkpoint
    case notEvaluated
}

/// Closed, value-only server evidence. It deliberately has no field capable of
/// retaining an item name, path, URL, account identity, remote identifier, or
/// response body.
public struct StabilityFinderAPIObservation: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let scenario: StabilityFinderScenario
    public let correlationID: UUID
    public let phase: StabilityFinderAPIObservationPhase
    public let outcome: StabilityFinderAPIObservationOutcome
    public let recordedAt: Date
    public let hasMore: Bool?
    public let itemCountBucket: UInt16?

    public init(
        scenario: StabilityFinderScenario,
        correlationID: UUID,
        phase: StabilityFinderAPIObservationPhase,
        outcome: StabilityFinderAPIObservationOutcome,
        recordedAt: Date = Date(),
        hasMore: Bool? = nil,
        itemCount: Int? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.scenario = scenario
        self.correlationID = correlationID
        self.phase = phase
        self.outcome = outcome
        self.recordedAt = recordedAt
        self.hasMore = hasMore
        self.itemCountBucket = itemCount.map(Self.bucket)
    }

    private static func bucket(_ count: Int) -> UInt16 {
        switch max(0, count) {
        case 0: 0
        case 1: 1
        case 2...5: 5
        case 6...10: 10
        case 11...25: 25
        case 26...50: 50
        case 51...100: 100
        default: 101
        }
    }
}

public enum StabilityFinderEvidenceValidationError: Error, Equatable, Sendable {
    case duplicateObservation(
        scenario: StabilityFinderScenario,
        phase: StabilityFinderAPIObservationPhase
    )
    case observationCorrelationMismatch(StabilityFinderScenario)
    case missingPassedObservation(
        scenario: StabilityFinderScenario,
        phase: StabilityFinderAPIObservationPhase
    )
    case invalidPassedObservation(StabilityFinderScenario)
    case missingDiagnosticEvidence(StabilityFinderScenario)
}

/// A closed requirement used when a Finder step is sealed. A passed step must
/// have one successful terminal diagnostic for every operation group; the
/// operations inside a group are alternatives. Synthetic report observations
/// alone are never sufficient.
public struct StabilityFinderDiagnosticRequirement: Equatable, Sendable {
    public let source: ProviderDiagnosticSource
    /// Every group must have one matching completed event. Operations within
    /// a group are alternatives, while separate groups are conjunctive.
    public let operationGroups: [Set<ProviderDiagnosticOperation>]

    public init(
        source: ProviderDiagnosticSource,
        operations: Set<ProviderDiagnosticOperation>
    ) {
        self.source = source
        self.operationGroups = [operations]
    }

    public init(
        source: ProviderDiagnosticSource,
        operationGroups: [Set<ProviderDiagnosticOperation>]
    ) {
        self.source = source
        self.operationGroups = operationGroups
    }
}

public extension StabilityFinderScenario {
    var diagnosticRequirement: StabilityFinderDiagnosticRequirement? {
        switch self {
        case .enumerationAndChangeAnchors:
            StabilityFinderDiagnosticRequirement(
                source: .fileProviderExtension,
                operationGroups: [
                    [.enumerateItems],
                    [.enumerateChanges, .currentSyncAnchor],
                ]
            )
        case .hydrate, .download:
            StabilityFinderDiagnosticRequirement(
                source: .fileProviderExtension,
                operations: [.fetchContents]
            )
        case .evict:
            StabilityFinderDiagnosticRequirement(
                source: .finderRunner,
                operations: [.itemLookup]
            )
        case .fileCreate, .directoryCreate:
            StabilityFinderDiagnosticRequirement(
                source: .fileProviderExtension,
                operations: [.createItem]
            )
        case .editAndUpload, .rename, .move, .concurrentRemotePreserveBoth:
            StabilityFinderDiagnosticRequirement(
                source: .fileProviderExtension,
                operations: [.modifyItem]
            )
        case .trash:
            StabilityFinderDiagnosticRequirement(
                source: .fileProviderExtension,
                operations: [.modifyItem]
            )
        case .workingSetRefresh:
            StabilityFinderDiagnosticRequirement(
                source: .fileProviderExtension,
                operations: [.workingSetRefresh, .enumerateItems, .enumerateChanges]
            )
        case .restore, .permanentDeletion, .cancellationAndProgress,
                .supportedContextualActions:
            nil
        }
    }
}
