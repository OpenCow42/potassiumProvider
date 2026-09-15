#if STABILITY
import Foundation

/// A targeted conflict result is never a sixteen-scenario Finder certificate.
/// The original report remains complete, with non-selected scenarios explicitly
/// skipped; this immutable manifest declares the narrower selection.
public struct StabilityConflictProfile: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let runID: UUID
    public let selectedCase: StabilityLiveConflictCase
    public let extensionLaunchMode: StabilityExtensionLaunchMode?

    public init(runID: UUID, selectedCase: StabilityLiveConflictCase, extensionLaunchMode: StabilityExtensionLaunchMode? = nil) {
        schemaVersion = 3; self.runID = runID; self.selectedCase = selectedCase
        self.extensionLaunchMode = extensionLaunchMode
    }

    public func validate(report: StabilityFinderRunReport, ticket: StabilityConflictBarrier.Ticket?,
                         reached: Bool, released: Bool, competingMutationVerified: Bool = false,
                         diagnostics: [ProviderDiagnosticEvent]) throws {
        guard [1, 2, 3].contains(schemaVersion) else { throw StabilityLiveEvidenceError.missingConflict }
        for step in report.stepResults where step.scenario != selectedCase.scenario {
            guard step.outcome == .skipped(.notSelectedForConflictProfile) ||
                    step.outcome == .skipped(.preflightFailure) || step.outcome == .skipped(.preflightCheckpoint) else {
                throw StabilityLiveEvidenceError.missingConflict
            }
        }
        guard let step = report.stepResults.first(where: { $0.scenario == selectedCase.scenario }) else {
            throw StabilityLiveEvidenceError.missingConflict
        }
        guard step.outcome == .passed else { return }
        guard schemaVersion < 3 || competingMutationVerified else { throw StabilityLiveEvidenceError.missingConflict }
        guard report.preflightResults.allSatisfy({ $0.outcome == .passed }),
              let ticket, reached, released, ticket.runID == runID, ticket.caseID == selectedCase,
              ticket.point == selectedCase.schedulingPoint, ticket.correlationID == step.correlationID,
              let proof = step.liveEvidence, proof.conflictBarrierReached, proof.subjects.contains(ticket.subject),
              diagnostics.contains(where: { $0.correlationID == step.correlationID && $0.subjectAlias == ticket.subject &&
                  $0.source == .fileProviderExtension && $0.operation == .modifyItem && $0.phase == .completed }) else {
            throw StabilityLiveEvidenceError.missingConflict
        }
        if selectedCase == .contentBeforePreflight {
            guard diagnostics.contains(where: { $0.correlationID == step.correlationID && $0.subjectAlias == ticket.subject &&
                $0.source == .fileProviderExtension && $0.operation == .uploadFile && $0.phase == .completed }) else {
                throw StabilityLiveEvidenceError.missingConflict
            }
        }
    }
}
#endif
