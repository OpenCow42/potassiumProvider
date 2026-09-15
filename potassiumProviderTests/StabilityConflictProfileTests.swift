#if STABILITY
import Foundation
@testable import PotassiumProviderCore
import Testing

struct StabilityConflictProfileTests {
    @Test func selectedCaseCannotBecomeFullFinderAcceptanceAndNeedsItsOwnGate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = StabilityRunHandle(runID: UUID(), directoryURL: directory)
        let correlation = UUID(), selected = StabilityLiveConflictCase.contentAfterPreflight
        let ticket = try StabilityConflictBarrier.arm(run: run, itemIdentifier: "synthetic", correlationID: correlation,
            caseID: selected, activeRunID: run.runID)
        let profile = StabilityConflictProfile(runID: run.runID, selectedCase: selected)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let proof = StabilityLiveStepEvidence(subjects: [ticket.subject], observedUIActions: 3,
            expectedExtensionCodeHash: String(repeating: "a", count: 40), conflictBarrierReached: true)
        let steps = StabilityFinderScenario.allCases.enumerated().map { index, scenario in
            let chosen = scenario == selected.scenario
            return StabilityFinderStepResult(sequenceNumber: UInt16(index + 1), scenario: scenario,
                correlationID: chosen ? correlation : UUID(), startedAt: time, finishedAt: time,
                outcome: chosen ? .passed : .skipped(.notSelectedForConflictProfile),
                assertions: StabilityFinderAssertionClass.allCases.map { StabilityFinderAssertionResult(assertionClass: $0,
                    outcome: chosen ? .passed : .notEvaluated(.stepSkipped)) }, liveEvidence: chosen ? proof : nil)
        }
        let report = try StabilityFinderRunReport(schemaVersion: StabilityFinderRunReport.liveSchemaVersion,
            correlationID: UUID(), startedAt: time, finishedAt: time,
            preflightResults: StabilityFinderPreflightCheck.allCases.map { .init(check: $0, outcome: .passed, recordedAt: time) }, stepResults: steps)
        let callback = ProviderDiagnosticEvent(subjectAlias: ticket.subject, correlationID: correlation,
            source: .fileProviderExtension, operation: .modifyItem, phase: .completed)
        try profile.validate(report: report, ticket: ticket, reached: true, released: true, competingMutationVerified: true, diagnostics: [callback])
        #expect(throws: StabilityLiveEvidenceError.missingConflict) {
            try profile.validate(report: report, ticket: ticket, reached: true, released: true, diagnostics: [callback])
        }
        #expect(report.stepSummary.passed == 1 && report.stepSummary.skipped == 15)
        for (reached, released) in [(false, true), (true, false), (false, false)] {
            #expect(throws: StabilityLiveEvidenceError.missingConflict) {
                try profile.validate(report: report, ticket: ticket, reached: reached, released: released, competingMutationVerified: true, diagnostics: [callback])
            }
        }
        #expect(throws: StabilityLiveEvidenceError.missingConflict) {
            try profile.validate(report: report, ticket: nil, reached: true, released: true, competingMutationVerified: true, diagnostics: [callback])
        }
        #expect(throws: StabilityLiveEvidenceError.missingConflict) {
            try profile.validate(report: report, ticket: ticket, reached: true, released: true, competingMutationVerified: true, diagnostics: [])
        }
        let wrongRun = StabilityConflictProfile(runID: UUID(), selectedCase: selected)
        #expect(throws: StabilityLiveEvidenceError.missingConflict) {
            try wrongRun.validate(report: report, ticket: ticket, reached: true, released: true, competingMutationVerified: true, diagnostics: [callback])
        }
    }
}
#endif
