#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@MainActor
struct FinderTransferObservationTests {
    let subject = UUID(), correlation = UUID(), process = UUID(), fetch = UUID(), download = UUID()
    let hash = String(repeating: "a", count: 40)

    @Test func cancellationRequiresIntermediateProgressFromTheActualFetchAttempt() throws {
        let observation = observer()
        try observation.ingest([event(.started)])
        #expect(!observation.canCancel)
        try observation.ingest([event(.progress, operation: .downloadFile, progress: 0)])
        #expect(!observation.canCancel)
        try observation.ingest([event(.progress, operation: .downloadFile, progress: 30)])
        #expect(observation.canCancel)
        try observation.ingest([event(.cancelled)])
        #expect(observation.fetchCancelled)
        #expect(!observation.canCancel)
        #expect(!observation.fetchCompleted)
        #expect(throws: StabilityLiveEvidenceError.contradictoryTerminal) { try observation.ingest([event(.completed)]) }
    }

    @Test func completedTransferStopsControlSearchWithoutCountingAsCancellation() throws {
        let observation = observer()
        try observation.ingest([event(.started), event(.progress, operation: .downloadFile, progress: 40),
                                event(.completed, operation: .downloadFile)])
        #expect(observation.downloadFinished)
        #expect(!observation.canCancel)
        #expect(!observation.fetchCancelled)
        try observation.ingest([event(.completed)])
        #expect(observation.fetchCompleted)
    }

    @Test(arguments: ["subject", "correlation", "build", "process", "parent", "source", "no-start", "terminal-only"])
    func unrelatedOrTerminalProgressCannotTriggerCancellation(mismatch: String) throws {
        let observation = observer()
        if mismatch != "no-start" { try observation.ingest([event(.started)]) }
        let progress = ProviderDiagnosticEvent(spanID: download, parentSpanID: mismatch == "parent" ? UUID() : fetch,
            subjectAlias: mismatch == "subject" ? UUID() : subject,
            processInstanceID: mismatch == "process" ? UUID() : process,
            processCodeHash: mismatch == "build" ? String(repeating: "b", count: 40) : hash,
            correlationID: mismatch == "correlation" ? UUID() : correlation,
            source: mismatch == "source" ? .app : .fileProviderExtension, operation: .downloadFile, phase: .progress,
            progressPercentBucket: mismatch == "terminal-only" ? 100 : 30)
        try observation.ingest([progress])
        #expect(!observation.canCancel)
        #expect(!observation.fetchCancelled)
    }

    private func observer() -> FinderTransferObservation { .init(subject: subject, correlation: correlation, codeHash: hash) }
    private func event(_ phase: ProviderDiagnosticPhase, operation: ProviderDiagnosticOperation = .fetchContents,
                       progress: Int? = nil) -> ProviderDiagnosticEvent {
        ProviderDiagnosticEvent(spanID: operation == .fetchContents ? fetch : download,
            parentSpanID: operation == .fetchContents ? nil : fetch, subjectAlias: subject,
            processInstanceID: process, processCodeHash: hash, correlationID: correlation,
            source: .fileProviderExtension, operation: operation, phase: phase, progressPercentBucket: progress)
    }
}
#endif
