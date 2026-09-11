import Foundation
import Testing
@testable import PotassiumProviderCore

@Suite("Live Finder evidence")
struct StabilityLiveEvidenceTests {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private let subject = UUID()
    private let correlation = UUID()
    private let process = UUID()
    private let hash = String(repeating: "a", count: 40)

    private func step(_ scenario: StabilityFinderScenario, conflict: Bool = false, cancellation: Bool = false,
                      workingSet: Bool = false, actions: Int = 1, actionsHash: String? = nil, metadata: UUID? = nil) -> StabilityFinderStepResult {
        StabilityFinderStepResult(sequenceNumber: 1, scenario: scenario, correlationID: correlation,
            startedAt: time, finishedAt: time.addingTimeInterval(10), outcome: .passed, assertions: [],
            liveEvidence: StabilityLiveStepEvidence(subjects: [subject], observedUIActions: actions,
                expectedExtensionCodeHash: hash, conflictBarrierReached: conflict,
                cancellationObserved: cancellation, workingSetMemberObserved: workingSet, expectedActionsCodeHash: actionsHash,
                expectedWorkingSetMetadataAlias: metadata))
    }

    private func span(_ operation: ProviderDiagnosticOperation, terminal: ProviderDiagnosticPhase = .completed,
                      subject override: UUID? = nil, offset: TimeInterval = 0, parent: UUID? = nil, progress: Bool = false,
                      source: ProviderDiagnosticSource = .fileProviderExtension, fields: [ProviderDiagnosticField] = [],
                      metadata: UUID? = nil, terminalOffset: TimeInterval? = nil,
                      failureClass: ProviderDiagnosticErrorClass? = nil, failureCode: Int? = nil) -> [ProviderDiagnosticEvent] {
        let id = UUID()
        let phases: [ProviderDiagnosticPhase] = progress ? [.started, .progress, terminal] : [.started, terminal]
        return phases.enumerated().map { index, phase in
            ProviderDiagnosticEvent(occurredAt: time.addingTimeInterval(offset + (phase == terminal ? terminalOffset ?? Double(index) : Double(index))), spanID: id,
                parentSpanID: parent, subjectAlias: override ?? subject, itemMetadataAlias: phase == .completed ? metadata : nil,
                processInstanceID: process, processCodeHash: hash,
                errorCode: phase == .failed ? failureCode : nil,
                correlationID: correlation, source: source, operation: operation, phase: phase, fieldShape: fields,
                errorClass: phase == .cancelled ? .cancellation : phase == .failed ? failureClass : nil,
                progressPercentBucket: phase == .progress ? 10 : nil)
        }
    }

    @Test(arguments: [StabilityFinderScenario.hydrate, .download])
    func cachedContentsAndUnrelatedCallbacksCannotProveFetch(_ scenario: StabilityFinderScenario) {
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(scenario), diagnostics: span(.itemLookup))
        }
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(scenario), diagnostics: span(.fetchContents, subject: UUID()))
        }
    }

    @Test func missingTelemetryAndUIAreRejected() {
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(.hydrate), diagnostics: [])
        }
        #expect(throws: StabilityLiveEvidenceError.missingUIEvidence) {
            try StabilityLiveEvidenceValidator.validate(step: step(.hydrate, actions: 0), diagnostics: span(.fetchContents))
        }
        #expect(throws: StabilityLiveEvidenceError.missingSpanStart) {
            try StabilityLiveEvidenceValidator.validate(step: step(.hydrate), diagnostics: Array(span(.fetchContents).dropFirst()))
        }
    }

    @Test func settlingRetainsCompleteSpansWithoutBorrowingOtherCallbacks() throws {
        let events = span(.fetchContents, offset: 9, terminalOffset: 4)
        try StabilityLiveEvidenceValidator.validate(step: step(.hydrate), diagnostics: events)
        #expect(throws: StabilityLiveEvidenceError.pendingOperations) {
            try StabilityLiveEvidenceValidator.validate(step: step(.hydrate), diagnostics: [events[0]])
        }
        #expect(throws: StabilityLiveEvidenceError.pendingOperations) {
            try StabilityLiveEvidenceValidator.validate(step: step(.hydrate),
                diagnostics: [events[0]] + span(.fetchContents, subject: UUID(), offset: 9, terminalOffset: 4))
        }
        #expect(throws: StabilityLiveEvidenceError.contradictoryTerminal) {
            try StabilityLiveEvidenceValidator.validate(step: step(.hydrate), diagnostics: events + [events[1]])
        }
        #expect(throws: StabilityLiveEvidenceError.unexpectedFailure) {
            try StabilityLiveEvidenceValidator.validate(step: step(.hydrate),
                diagnostics: span(.fetchContents, terminal: .failed, offset: 9, terminalOffset: 4))
        }
        // A cached earlier fetch or a later unrelated fetch cannot satisfy this step.
        for unrelated in [span(.fetchContents, offset: -2, terminalOffset: 4),
                          span(.fetchContents, offset: 12)] {
            #expect(throws: StabilityLiveEvidenceError.missingCallback) {
                try StabilityLiveEvidenceValidator.validate(step: step(.hydrate), diagnostics: unrelated)
            }
        }
    }

    @Test func requiredMappingsDistinguishTrashFromDeletion() throws {
        try StabilityLiveEvidenceValidator.validate(step: step(.trash), diagnostics: span(.modifyItem, fields: [.parent, .trash]))
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(.trash), diagnostics: span(.modifyItem, fields: [.contents]))
        }
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(.trash), diagnostics: span(.deleteItem))
        }
        try StabilityLiveEvidenceValidator.validate(step: step(.permanentDeletion), diagnostics: span(.deleteItem))
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(.restore), diagnostics: span(.itemLookup))
        }
        try StabilityLiveEvidenceValidator.validate(step: step(.restore), diagnostics: span(.restoreTrashedItem))
        try StabilityLiveEvidenceValidator.validate(step: step(.restore), diagnostics: span(.modifyItem, fields: [.parent]))
        for fields: [ProviderDiagnosticField] in [[.lastUsedDate], [.parent, .trash]] {
            #expect(throws: StabilityLiveEvidenceError.missingCallback) {
                try StabilityLiveEvidenceValidator.validate(step: step(.restore), diagnostics: span(.modifyItem, fields: fields))
            }
        }
    }

    @Test func untriggeredConflictCannotPass() {
        #expect(throws: StabilityLiveEvidenceError.missingConflict) {
            try StabilityLiveEvidenceValidator.validate(step: step(.concurrentRemotePreserveBoth), diagnostics: span(.modifyItem) + span(.uploadFile))
        }
    }

    @Test func handledActive404RequiresMatchingSuccessfulTrashAndParentSpans() throws {
        let parent = span(.itemLookup, terminalOffset: 4)
        let parentID = parent.first!.spanID!
        let failed = span(.itemLookup, terminal: .failed, parent: parentID, failureClass: .notFound, failureCode: 404)
        let trash = span(.trashedItem, offset: 2, parent: parentID)
        let restore = span(.restoreTrashedItem, offset: 5)
        try StabilityLiveEvidenceValidator.validate(step: step(.restore), diagnostics: parent + failed + trash + restore)
        // Recovery metadata never substitutes for the actual Restore action.
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(.restore), diagnostics: parent + failed + trash)
        }
        for incomplete in [
            parent + failed,
            failed + trash,
            parent + failed + span(.trashedItem, offset: 2, parent: UUID()),
            parent + failed + span(.trashedItem, subject: UUID(), offset: 2, parent: parentID),
            parent + failed + span(.trashedItem, parent: parentID, terminalOffset: 0),
            parent + failed + span(.trashedItem, terminal: .failed, offset: 2, parent: parentID),
            parent + trash + span(.itemLookup, terminal: .failed, parent: parentID, failureClass: .notFound, failureCode: 403),
            trash + span(.itemLookup, terminal: .failed, failureClass: .notFound, failureCode: 404)
        ] {
            #expect(throws: StabilityLiveEvidenceError.unexpectedFailure) {
                try StabilityLiveEvidenceValidator.validate(step: step(.restore), diagnostics: incomplete + restore)
            }
        }
    }

    @Test(arguments: [StabilityFinderScenario.editAndUpload, .rename, .move])
    func incidentalMetadataCallbacksCannotProveTheIntendedMutation(_ scenario: StabilityFinderScenario) throws {
        let field: ProviderDiagnosticField = scenario == .editAndUpload ? .contents : scenario == .rename ? .filename : .parent
        try StabilityLiveEvidenceValidator.validate(step: step(scenario), diagnostics: span(.modifyItem, fields: [field]))
        for fields: [ProviderDiagnosticField] in [[.lastUsedDate], [.contentModificationDate], [.parent, .trash]] {
            #expect(throws: StabilityLiveEvidenceError.missingCallback) {
                try StabilityLiveEvidenceValidator.validate(step: step(scenario), diagnostics: span(.modifyItem, fields: fields))
            }
        }
    }

    @Test func cancellationNeedsProgressAndSubsequentSuccessWithDifferentOperation() throws {
        let cancelled = span(.fetchContents, terminal: .cancelled, progress: true)
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(.cancellationAndProgress, cancellation: true), diagnostics: cancelled)
        }
        let events = cancelled + span(.fetchContents, offset: 3)
        try StabilityLiveEvidenceValidator.validate(step: step(.cancellationAndProgress, cancellation: true), diagnostics: events)
        #expect(throws: StabilityLiveEvidenceError.contradictoryTerminal) {
            try StabilityLiveEvidenceValidator.validate(step: step(.cancellationAndProgress, cancellation: true), diagnostics: events + [cancelled.last!])
        }
        #expect(throws: StabilityLiveEvidenceError.missingCancellation) {
            try StabilityLiveEvidenceValidator.validate(step: step(.cancellationAndProgress), diagnostics: span(.fetchContents))
        }
    }

    @Test func rootEnumerationCannotProveWorkingSetMembership() {
        #expect(throws: StabilityLiveEvidenceError.missingCallback) {
            try StabilityLiveEvidenceValidator.validate(step: step(.workingSetRefresh, workingSet: true), diagnostics: span(.enumerateItems))
        }
    }

    @Test func cachedWorkingSetMetadataOrUnparentedMembershipCannotPass() throws {
        let expected = UUID(), enumeration = span(.enumerateChanges)
        let proof = step(.workingSetRefresh, workingSet: true, metadata: expected)
        let parent = enumeration.first!.spanID!
        try StabilityLiveEvidenceValidator.validate(step: proof,
            diagnostics: enumeration + span(.workingSetRefresh, parent: parent, metadata: expected))
        for events in [span(.workingSetRefresh, parent: parent, metadata: UUID()),
                       span(.workingSetRefresh, parent: parent), span(.workingSetRefresh, metadata: expected)] {
            #expect(throws: StabilityLiveEvidenceError.missingWorkingSet) {
                try StabilityLiveEvidenceValidator.validate(step: proof, diagnostics: enumeration + events)
            }
        }
    }

    @Test func diagnosticAliasesAreStableWithinRunAndChangeBetweenRuns() {
        let run = UUID()
        #expect(StabilityDiagnosticIdentity.alias(for: "synthetic", runID: run) == StabilityDiagnosticIdentity.alias(for: "synthetic", runID: run))
        #expect(StabilityDiagnosticIdentity.alias(for: "synthetic", runID: run) != StabilityDiagnosticIdentity.alias(for: "synthetic", runID: UUID()))
        #expect(StabilityDiagnosticIdentity.alias(for: "synthetic", runID: run) != StabilityDiagnosticIdentity.alias(for: "other", runID: run))
    }

    @Test func contextualPanelsRequireTheAttestedActionsBuildAndEveryMutation() throws {
        let callbacks = span(.favoriteItem) + span(.favoriteItem) + span(.duplicateItem)
        let panelOperations: [ProviderDiagnosticOperation] = [.createShareLink, .updateShareLink, .deleteShareLink, .restoreFileVersion]
        let panels = panelOperations.flatMap { span($0, source: .actionExtension) }
        let proof = step(.supportedContextualActions, actionsHash: hash)
        try StabilityLiveEvidenceValidator.validate(step: proof, diagnostics: callbacks + panels)
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try StabilityLiveEvidenceValidator.validate(step: step(.supportedContextualActions), diagnostics: callbacks + panels)
        }
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try StabilityLiveEvidenceValidator.validate(step: step(.supportedContextualActions, actionsHash: String(repeating: "b", count: 40)), diagnostics: callbacks + panels)
        }
        for operation in panelOperations {
            #expect(throws: StabilityLiveEvidenceError.missingCallback) {
                try StabilityLiveEvidenceValidator.validate(step: proof, diagnostics: callbacks + panels.filter { $0.operation != operation })
            }
        }
    }
}
