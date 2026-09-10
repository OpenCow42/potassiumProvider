#if STABILITY
import Foundation
import PotassiumProviderCore
import Testing

struct StabilityExtensionLaunchEvidenceTests {
    private let runID = UUID(), process = UUID(), correlation = UUID()
    private let hash = String(repeating: "a", count: 40)
    private func time(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func event(_ operation: ProviderDiagnosticOperation, _ phase: ProviderDiagnosticPhase,
                       _ at: Double, process other: UUID? = nil, span: UUID = UUID()) -> ProviderDiagnosticEvent {
        ProviderDiagnosticEvent(occurredAt: time(at), spanID: span, processInstanceID: other ?? process,
            processCodeHash: hash, correlationID: correlation, source: .fileProviderExtension,
            operation: operation, phase: phase)
    }
    private func lifecycle(_ operation: ProviderDiagnosticOperation, at: Double) -> [ProviderDiagnosticEvent] {
        let span = UUID()
        return [event(operation, .started, at, span: span), event(operation, .completed, at + 1, span: span)]
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
        let events = lifecycle(.runtimeInitialize, at: 16) + [event(.modifyItem, .started, 20), event(.modifyItem, .completed, 21)]
        try proof(.fresh, born: 16).validate(runID: runID, report: report(), diagnostics: events)
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try proof(.fresh, born: 9).validate(runID: runID, report: report(), diagnostics: events)
        }
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try proof(.fresh, born: 16).validate(runID: runID, report: report(),
                diagnostics: events.filter { $0.operation != .runtimeInitialize })
        }
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try proof(.fresh, born: 16).validate(runID: runID, report: report(),
                diagnostics: [event(.modifyItem, .started, 16)] + lifecycle(.runtimeInitialize, at: 17))
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
        for unexpected in [event(.itemLookup, .completed, 11, process: UUID()),
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

    @Test func warmProcessSupportsBalancedReplicatedInstanceLifecycles() throws {
        let events = [event(.itemLookup, .completed, 12)] +
            lifecycle(.runtimeInvalidate, at: 13) + lifecycle(.runtimeInitialize, at: 16) +
            [event(.modifyItem, .started, 20), event(.modifyItem, .completed, 21)] +
            lifecycle(.runtimeInvalidate, at: 22)
        try proof(.running, born: 9).validate(runID: runID, report: report(), diagnostics: events)
    }

    @Test func freshProcessMayDiscardAReplicatedInstanceAfterCompletedWork() throws {
        let events = lifecycle(.runtimeInitialize, at: 16) +
            [event(.modifyItem, .started, 20), event(.modifyItem, .completed, 21)] +
            lifecycle(.runtimeInvalidate, at: 22)
        try proof(.fresh, born: 16).validate(runID: runID, report: report(), diagnostics: events)
    }

    @Test(arguments: [ProviderDiagnosticPhase.failed, .cancelled])
    func failedInstanceLifecycleCannotPass(_ terminal: ProviderDiagnosticPhase) throws {
        let span = UUID()
        let events = [event(.itemLookup, .completed, 12), event(.runtimeInitialize, .started, 16, span: span),
                      event(.runtimeInitialize, terminal, 17, span: span)]
        #expect(throws: StabilityLiveEvidenceError.unexpectedFailure) {
            try proof(.running, born: 9).validate(runID: runID, report: report(), diagnostics: events)
        }
    }

    @Test func incompleteDuplicatedOrMisorderedInstanceLifecycleCannotPass() throws {
        let pair = lifecycle(.runtimeInvalidate, at: 22)
        let span = UUID()
        for broken in [[pair[0]], [pair[1]], pair + [pair[0]], pair + [pair[1]],
                       [event(.runtimeInitialize, .started, 23, span: span), event(.runtimeInitialize, .completed, 22, span: span)],
                       [event(.runtimeInitialize, .started, 22, span: span), event(.runtimeInvalidate, .completed, 23, span: span)]] {
            #expect(throws: StabilityLiveEvidenceError.pendingOperations) {
                try proof(.running, born: 9).validate(runID: runID, report: report(),
                    diagnostics: [event(.itemLookup, .completed, 12)] + broken)
            }
        }
    }

    @Test func historicalProofKeepsItsOriginalLifecycleInterpretation() throws {
        let modern = proof(.running, born: 9)
        #expect(modern.schemaVersion == 2)
        let encoded = try JSONEncoder().encode(modern)
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(decoded as? [String: Any])
        object["schemaVersion"] = 1
        let legacy = try JSONDecoder().decode(StabilityExtensionLaunchEvidence.self, from: JSONSerialization.data(withJSONObject: object))
        let earlierWork = [event(.itemLookup, .completed, 12), event(.modifyItem, .completed, 21)]
        try legacy.validate(runID: runID, report: report(), diagnostics: earlierWork)
        #expect(throws: StabilityLiveEvidenceError.wrongExtensionBuild) {
            try legacy.validate(runID: runID, report: report(), diagnostics: earlierWork + lifecycle(.runtimeInitialize, at: 16))
        }
    }

    @Test func originalRunCannotCertifyRequestedLifecycleWithoutMatchingEvidence() throws {
        let request = StabilityExtensionLaunchRequest(runID: runID, mode: .fresh)
        let events = lifecycle(.runtimeInitialize, at: 16) + [event(.modifyItem, .started, 20), event(.modifyItem, .completed, 21)]
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
