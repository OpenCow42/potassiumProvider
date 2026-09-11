#if os(macOS) && STABILITY
import Foundation

public enum StabilityLaunchPreparationError: String, Error {
    case initialProcessAbsent, initialProcessChanged
}

/// An unsuccessful preflight has no Finder report. Retain a closed diagnostic
/// without sealing it or fabricating the missing scenario/lifecycle evidence.
public struct StabilityLaunchPreparationFailure: Codable {
    public enum Stage: String, Codable { case initialProcessObservation, labPreflight, launchPreparation, liveContext }
    public let schemaVersion: UInt16
    public let stage: Stage
    public let occurredAt: Date
    public let errorClass: ProviderDiagnosticErrorClass
    public let errorCode: Int
    public let reason: String
    public let eligibleForAcceptance: Bool

    public init(stage: Stage, error: any Error) {
        schemaVersion = 1; self.stage = stage; occurredAt = Date()
        errorClass = ProviderDiagnosticErrorClassifier.classify(error)
        errorCode = (error as NSError).code
        reason = (error as? StabilityLaunchPreparationError)?.rawValue
            ?? (error is StabilityDeadlineError ? "deadline" : "unclassified")
        eligibleForAcceptance = false
    }

    public static func record(stage: Stage, error: any Error, run: StabilityRunHandle) {
        let failure = Self(stage: stage, error: error)
        print("finder stability preparation failed: stage=\(stage.rawValue) reason=\(failure.reason) class=\(failure.errorClass.rawValue) code=\(failure.errorCode)")
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try SecurePOSIXFile.createExclusively(encoder.encode(failure),
                at: run.directoryURL.appendingPathComponent("launch-preparation-failed.json"), permissions: 0o400)
        } catch { print("finder stability preparation failure evidence could not be retained") }
    }
}
#endif
