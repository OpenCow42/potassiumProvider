#if STABILITY
import Foundation
import PotassiumProviderCore
import Testing

struct StabilityExtensionLaunchEvidenceTests {
    private let runID = UUID(), process = UUID(), correlation = UUID()
    private let hash = String(repeating: "a", count: 40)
    private func time(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func event(_ operation: ProviderDiagnosticOperation, _ phase: ProviderDiagnosticPhase,
                       _ at: Double, process other: UUID? = nil) -> ProviderDiagnosticEvent {
        ProviderDiagnosticEvent(occurredAt: time(at), spanID: UUID(), processInstanceID: other ?? process,
            processCodeHash: hash, correlationID: correlation, source: .fileProviderExtension,
            operation: operation, phase: phase)
    }
    private func report(passing: Bool = false) throws -> StabilityFinderRunReport {
        try StabilityFinderRunReport(schemaVersion: StabilityFinderRunReport.liveSchemaVersion,
            correlationID: correlation, startedAt: time(10), finishedAt: time(30),
            preflightResults: StabilityFinderPreflightCheck.allCases.map { .init(check: $0, outcome: .passed, recordedAt: time(10)) },
            stepResults: StabilityFinderScenario.allCases.enumerated().map { index, scenario in
                .init(sequenceNumber: UInt16(index + 1), scenario: scenario, correlationID: UUID(),
                    startedAt: time(20), finishedAt: time(20), outcome: passing && index == 0 ? .passed : .skipped(.notSelectedForConflictProfile),
                    assertions: StabilityFinderAssertionClass.allCases.map { .init(assertionClass: $0, outcome: passing && index == 0 ? .passed : .notEvaluated(.stepSkipped)) })
            })
    }
    private func proof(_ mode: StabilityExtensionLaunchMode, born: Double) -> StabilityExtensionLaunchEvidence {
        .init(runID: runID, mode: mode, recordingStartedAt: time(10), preparedAt: time(15), processStartedAt: time(born),
              processInstanceID: process, expectedCodeHash: hash)
    }

    @Test func freshRequiresKernelBirthAndInitializationBeforeMutation() throws {
        let events = [event(.runtimeInitialize, .completed, 17), event(.modifyItem, .started, 20), event(.modifyItem, .completed, 21)]
        try proof(.fresh, born: 16).validate(runID: runID, report: report(), diagnostics: events)
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try proof(.fresh, born: 9).validate(runID: runID, report: report(), diagnostics: events)
        }
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try proof(.fresh, born: 16).validate(runID: runID, report: report(), diagnostics: Array(events.dropFirst()))
        }
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try proof(.fresh, born: 16).validate(runID: runID, report: report(),
                diagnostics: [event(.modifyItem, .started, 16), event(.runtimeInitialize, .completed, 17)])
        }
    }
    @Test func warmRequiresEarlierCallbackAndAnUnchangedProcess() throws {
        let events = [event(.itemLookup, .completed, 12), event(.modifyItem, .started, 20), event(.modifyItem, .completed, 21)]
        try proof(.running, born: 9).validate(runID: runID, report: report(), diagnostics: events)
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try proof(.running, born: 16).validate(runID: runID, report: report(), diagnostics: events)
        }
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try proof(.running, born: 9).validate(runID: runID, report: report(), diagnostics: Array(events.dropFirst()))
        }
        for unexpected in [event(.runtimeInitialize, .completed, 11), event(.runtimeInvalidate, .completed, 22),
                           event(.modifyItem, .completed, 22, process: UUID())] {
            #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
                try proof(.running, born: 9).validate(runID: runID, report: report(), diagnostics: events + [unexpected])
            }
        }
    }
    @Test func kernelTimesKeepSubsecondPrecisionAcrossDiagnosticEncoding() throws {
        let original = StabilityExtensionLaunchEvidence(runID: runID, mode: .running,
            recordingStartedAt: time(10.8), preparedAt: time(15), processStartedAt: time(10.2),
            processInstanceID: process, expectedCodeHash: hash)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StabilityExtensionLaunchEvidence.self, from: encoder.encode(original))
        #expect(decoded == original && decoded.processStartedAt < decoded.recordingStartedAt)
        try decoded.validate(runID: runID, report: report(), diagnostics:
            [event(.itemLookup, .completed, 12), event(.modifyItem, .started, 20), event(.modifyItem, .completed, 21)])
    }

    @Test func originalRunCannotCertifyRequestedLifecycleWithoutMatchingEvidence() throws {
        let request = StabilityExtensionLaunchRequest(runID: runID, mode: .fresh)
        let events = [event(.runtimeInitialize, .completed, 17), event(.modifyItem, .started, 20), event(.modifyItem, .completed, 21)]
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try request.validate(evidence: nil, report: report(passing: true), diagnostics: events)
        }
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try request.validate(evidence: proof(.running, born: 9), report: report(passing: true), diagnostics: events)
        }
        try request.validate(evidence: proof(.fresh, born: 16), report: report(passing: true), diagnostics: events)
    }

    @Test func historicalProfileRemainsReadableWithoutLaunchCertification() throws {
        let json = Data("{\"schemaVersion\":1,\"runID\":\"\(runID.uuidString)\",\"selectedCase\":\"content-after-preflight\"}".utf8)
        let old = try JSONDecoder().decode(StabilityConflictProfile.self, from: json)
        #expect(old.schemaVersion == 1 && old.extensionLaunchMode == nil)
    }
}
#endif
