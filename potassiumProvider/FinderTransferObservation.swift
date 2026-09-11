#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore

/// Tracks one UI download attempt, from a cursor registered before dispatch.
/// Correlation alone cannot associate progress with the selected fixture.
@MainActor
final class FinderTransferObservation {
    let subject: UUID
    let correlation: UUID
    let codeHash: String
    private var events: [ProviderDiagnosticEvent] = []
    private var fetch: ProviderDiagnosticEvent?

    init(subject: UUID, correlation: UUID, codeHash: String) {
        self.subject = subject
        self.correlation = correlation
        self.codeHash = codeHash
    }

    func ingest(_ newEvents: [ProviderDiagnosticEvent]) throws {
        events += newEvents.filter { $0.subjectAlias == subject && $0.correlationID == correlation &&
            $0.processCodeHash == codeHash && $0.source == .fileProviderExtension &&
            [.fetchContents, .downloadFile].contains($0.operation) }
        let starts = events.filter { $0.operation == .fetchContents && $0.phase == .started }
        guard starts.count <= 1 else { throw StabilityLiveEvidenceError.contradictoryTerminal }
        fetch = starts.first
        let terminals = related.filter { $0.operation == .fetchContents && [.completed, .cancelled, .failed].contains($0.phase) }
        guard terminals.count <= 1 else { throw StabilityLiveEvidenceError.contradictoryTerminal }
        guard !related.contains(where: { $0.phase == .failed }) else { throw StabilityLiveEvidenceError.unexpectedFailure }
    }

    private var related: [ProviderDiagnosticEvent] {
        guard let fetch, let span = fetch.spanID, let process = fetch.processInstanceID else { return [] }
        return events.filter { $0.processInstanceID == process &&
            (($0.operation == .fetchContents && $0.spanID == span) ||
             ($0.operation == .downloadFile && $0.parentSpanID == span)) }
    }

    var hasIntermediateProgress: Bool {
        related.contains { $0.phase == .progress && (1..<100).contains($0.progressPercentBucket ?? 0) }
    }
    var downloadFinished: Bool { related.contains { $0.phase == .completed } }
    var fetchCompleted: Bool { related.contains { $0.operation == .fetchContents && $0.phase == .completed } }
    var fetchCancelled: Bool { related.contains { $0.operation == .fetchContents && $0.phase == .cancelled } }
    var canCancel: Bool { hasIntermediateProgress && !downloadFinished && !fetchCancelled }
}
#endif
