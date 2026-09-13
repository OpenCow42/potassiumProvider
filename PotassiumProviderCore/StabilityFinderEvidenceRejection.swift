import Foundation

/// Diagnostic candidate only. This file is never an acceptance commit marker.
public struct StabilityFinderEvidenceRejection: Codable, Sendable {
    public let schemaVersion: Int
    public let eligibleForAcceptance: Bool
    public let evidenceError: StabilityLiveEvidenceError?
    public let errorClass: ProviderDiagnosticErrorClass
    public let report: StabilityFinderRunReport
    public let observations: [StabilityFinderAPIObservation]

    public init(report: StabilityFinderRunReport, observations: [StabilityFinderAPIObservation], error: Error) {
        schemaVersion = 1
        eligibleForAcceptance = false
        evidenceError = error as? StabilityLiveEvidenceError
        errorClass = ProviderDiagnosticErrorClassifier.classify(error)
        self.report = report
        self.observations = observations
    }
}
