import Foundation

public enum StabilityFailureOrigin: String, Codable, Sendable {
    case automation, harness, provider, api, environment
}

public enum StabilityLiveFailureReason: String, Codable, Sendable {
    case deadline, missingFixture, unsafeTarget, unverifiedBuild, uiUnavailable, selectionMismatch, windowMismatch
    case missingTelemetry, screenshotUnavailable, operatorStopped, cancellationNotExercised, assertionFailed, remoteError, unsupportedControl, resourceBusy, unknown
}

/// Additional evidence required by the live UI report (version 2).
/// Values name operation classes and run-local aliases, never file names or URLs.
public struct StabilityLiveStepEvidence: Codable, Equatable, Sendable {
    public var subjects: [UUID]
    public var observedUIActions: Int
    public var expectedExtensionCodeHash: String
    public var expectedActionsCodeHash: String?
    public var conflictBarrierReached: Bool
    public var cancellationObserved: Bool
    public var workingSetMemberObserved: Bool
    public var expectedWorkingSetMetadataAlias: UUID?
    public var failureOrigin: StabilityFailureOrigin?
    public var failureReason: StabilityLiveFailureReason?
    public var supportingSpanIDs: [UUID]?

    public init(subjects: [UUID], observedUIActions: Int, expectedExtensionCodeHash: String,
                conflictBarrierReached: Bool = false, cancellationObserved: Bool = false,
                workingSetMemberObserved: Bool = false, failureOrigin: StabilityFailureOrigin? = nil,
                failureReason: StabilityLiveFailureReason? = nil, supportingSpanIDs: [UUID]? = nil,
                expectedActionsCodeHash: String? = nil, expectedWorkingSetMetadataAlias: UUID? = nil) {
        self.subjects = subjects
        self.observedUIActions = observedUIActions
        self.expectedExtensionCodeHash = expectedExtensionCodeHash
        self.expectedActionsCodeHash = expectedActionsCodeHash
        self.conflictBarrierReached = conflictBarrierReached
        self.cancellationObserved = cancellationObserved
        self.workingSetMemberObserved = workingSetMemberObserved
        self.expectedWorkingSetMetadataAlias = expectedWorkingSetMetadataAlias
        self.failureOrigin = failureOrigin
        self.failureReason = failureReason
        self.supportingSpanIDs = supportingSpanIDs
    }
}

public enum StabilityLiveEvidenceError: Error, Equatable {
    case missingUIEvidence, missingSubject, missingCallback, wrongExtensionBuild
    case contradictoryTerminal, missingConflict, missingCancellation, missingWorkingSet
    case pendingOperations, missingSpanStart, unexpectedFailure
}

public enum StabilityLiveEvidenceValidator {
    public static func validate(step: StabilityFinderStepResult, diagnostics: [ProviderDiagnosticEvent]) throws {
        guard step.outcome == .passed else { return }
        guard let proof = step.liveEvidence, proof.observedUIActions > 0 else {
            throw StabilityLiveEvidenceError.missingUIEvidence
        }
        guard !proof.subjects.isEmpty else { throw StabilityLiveEvidenceError.missingSubject }
        let events = diagnostics.filter {
            $0.correlationID == step.correlationID && $0.occurredAt.timeIntervalSince1970 >= floor(step.startedAt.timeIntervalSince1970) &&
            $0.occurredAt.timeIntervalSince1970 <= ceil(step.finishedAt.timeIntervalSince1970) && $0.subjectAlias.map(proof.subjects.contains) == true
        }
        let callbacks = events.filter { $0.source == .fileProviderExtension && Self.callbackOperations.contains($0.operation) }
        guard !callbacks.isEmpty else { throw StabilityLiveEvidenceError.missingCallback }
        guard proof.expectedExtensionCodeHash.count == 40,
              callbacks.allSatisfy({ $0.processCodeHash == proof.expectedExtensionCodeHash && $0.processInstanceID != nil }) else {
            throw StabilityLiveEvidenceError.wrongExtensionBuild
        }
        let actionEvents = events.filter { $0.source == .actionExtension }
        if !actionEvents.isEmpty {
            guard let expected = proof.expectedActionsCodeHash, expected.count == 40,
                  actionEvents.allSatisfy({ $0.processCodeHash == expected && $0.processInstanceID != nil }) else {
                throw StabilityLiveEvidenceError.wrongExtensionBuild
            }
        }
        for (_, span) in Dictionary(grouping: events.filter { $0.spanID != nil }, by: { $0.spanID! }) {
            guard span.filter({ $0.phase == .started }).count == 1 else { throw StabilityLiveEvidenceError.missingSpanStart }
            let terminals = span.filter { [.completed, .cancelled, .failed].contains($0.phase) }
            guard terminals.count <= 1 else { throw StabilityLiveEvidenceError.contradictoryTerminal }
            if terminals.isEmpty {
                throw StabilityLiveEvidenceError.pendingOperations
            }
            for terminal in terminals where terminal.phase != .completed {
                let expectedCancellation = step.scenario == .cancellationAndProgress && terminal.phase == .cancelled && [.fetchContents, .downloadFile].contains(terminal.operation)
                let expectedConflict = step.scenario == .concurrentRemotePreserveBoth && terminal.errorClass == .conflict
                guard expectedCancellation || expectedConflict else { throw StabilityLiveEvidenceError.unexpectedFailure }
            }
        }
        func completed(_ groups: [Set<ProviderDiagnosticOperation>]) throws {
            for group in groups {
                guard events.contains(where: { group.contains($0.operation) && $0.phase == .completed &&
                    ($0.source == .fileProviderExtension || $0.source == .actionExtension) }) else {
                    throw StabilityLiveEvidenceError.missingCallback
                }
            }
        }
        switch step.scenario {
        case .enumerationAndChangeAnchors:
            try completed([[.enumerateItems], [.enumerateChanges, .currentSyncAnchor]])
        case .hydrate, .download: try completed([[.fetchContents]])
        case .evict: try completed([[.itemLookup, .materializedItemsChanged]])
        case .fileCreate, .directoryCreate: try completed([[.createItem]])
        case .editAndUpload, .rename, .move:
            let field: ProviderDiagnosticField = step.scenario == .editAndUpload ? .contents :
                step.scenario == .rename ? .filename : .parent
            guard callbacks.contains(where: { $0.operation == .modifyItem && $0.phase == .completed &&
                $0.fieldShape.contains(field) && !$0.fieldShape.contains(.trash) }) else {
                throw StabilityLiveEvidenceError.missingCallback
            }
        case .trash:
            guard callbacks.contains(where: { $0.operation == .modifyItem && $0.phase == .completed &&
                $0.fieldShape.contains(.parent) && $0.fieldShape.contains(.trash) }) else {
                throw StabilityLiveEvidenceError.missingCallback
            }
        case .restore:
            guard callbacks.contains(where: { $0.phase == .completed &&
                ($0.operation == .restoreTrashedItem || ($0.operation == .modifyItem &&
                 $0.fieldShape.contains(.parent) && !$0.fieldShape.contains(.trash))) }) else {
                throw StabilityLiveEvidenceError.missingCallback
            }
        case .permanentDeletion: try completed([[.deleteItem]])
        case .concurrentRemotePreserveBoth:
            guard proof.conflictBarrierReached,
                  events.contains(where: { $0.errorClass == .conflict && $0.source == .fileProviderExtension }) else {
                throw StabilityLiveEvidenceError.missingConflict
            }
            try completed([[.modifyItem], [.uploadFile]])
        case .cancellationAndProgress:
            guard proof.cancellationObserved,
                  let cancelled = callbacks.first(where: { $0.operation == .fetchContents && $0.phase == .cancelled }),
                  let spanID = cancelled.spanID,
                  events.contains(where: { $0.phase == .progress && ($0.progressPercentBucket ?? 0) > 0 &&
                    ($0.spanID == spanID || $0.parentSpanID == spanID) }) else {
                throw StabilityLiveEvidenceError.missingCancellation
            }
            guard callbacks.contains(where: { $0.operation == .fetchContents && $0.phase == .completed &&
                $0.subjectAlias == cancelled.subjectAlias && $0.spanID != spanID && $0.occurredAt >= cancelled.occurredAt }) else {
                throw StabilityLiveEvidenceError.missingCallback
            }
        case .workingSetRefresh:
            guard proof.workingSetMemberObserved else { throw StabilityLiveEvidenceError.missingWorkingSet }
            try completed([[.workingSetRefresh]])
            guard let expected = proof.expectedWorkingSetMetadataAlias,
                  callbacks.contains(where: { $0.operation == .workingSetRefresh && $0.phase == .completed &&
                      $0.itemMetadataAlias == expected && $0.parentSpanID.map { parentID in
                          callbacks.contains { $0.spanID == parentID && $0.phase == .completed &&
                              [.enumerateItems, .enumerateChanges].contains($0.operation) }
                      } == true }) else {
                throw StabilityLiveEvidenceError.missingWorkingSet
            }
        case .supportedContextualActions:
            guard callbacks.filter({ $0.operation == .favoriteItem && $0.phase == .completed && $0.parentSpanID == nil }).count >= 2 else {
                throw StabilityLiveEvidenceError.missingCallback
            }
            try completed([[.favoriteItem], [.duplicateItem], [.createShareLink], [.updateShareLink], [.deleteShareLink], [.restoreFileVersion]])
        }
    }

    private static let callbackOperations: Set<ProviderDiagnosticOperation> = [
        .itemLookup, .enumerateItems, .enumerateChanges, .currentSyncAnchor, .fetchContents,
        .createItem, .modifyItem, .deleteItem, .materializedItemsChanged, .workingSetRefresh,
        .favoriteItem, .duplicateItem, .restoreTrashedItem,
    ]
}
