#if STABILITY
import Foundation

public enum StabilityExtensionLaunchMode: String, Codable, Sendable {
    case fresh
    case running
}

/// Declares the lifecycle requirement for the original sixteen-scenario runner.
/// Conflict selections carry the same requirement in their profile manifest.
public struct StabilityExtensionLaunchRequest: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let runID: UUID
    public let mode: StabilityExtensionLaunchMode
    public init(runID: UUID, mode: StabilityExtensionLaunchMode) { schemaVersion = 1; self.runID = runID; self.mode = mode }

    public func validate(evidence: StabilityExtensionLaunchEvidence?, report: StabilityFinderRunReport,
                         diagnostics: [ProviderDiagnosticEvent]) throws {
        guard schemaVersion == 1 else { throw StabilityLiveEvidenceError.wrongExtensionBuild }
        guard report.stepSummary.passed > 0 else { return }
        guard let evidence, evidence.mode == mode else { throw StabilityLiveEvidenceError.wrongExtensionBuild }
        try evidence.validate(runID: runID, report: report, diagnostics: diagnostics)
    }
}

/// Kernel birth time, signed build and diagnostic process identity jointly
/// distinguish a new extension process from one that remained alive throughout.
public struct StabilityExtensionLaunchEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let runID: UUID
    public let mode: StabilityExtensionLaunchMode
    public let recordingStartedAtMicroseconds: Int64
    public let preparedAtMicroseconds: Int64
    public let processStartedAtMicroseconds: Int64
    public var recordingStartedAt: Date { Date(timeIntervalSince1970: Double(recordingStartedAtMicroseconds) / 1_000_000) }
    public var preparedAt: Date { Date(timeIntervalSince1970: Double(preparedAtMicroseconds) / 1_000_000) }
    public var processStartedAt: Date { Date(timeIntervalSince1970: Double(processStartedAtMicroseconds) / 1_000_000) }
    public let processInstanceID: UUID
    public let expectedCodeHash: String

    public init(runID: UUID, mode: StabilityExtensionLaunchMode, recordingStartedAt: Date, preparedAt: Date,
                processStartedAt: Date, processInstanceID: UUID, expectedCodeHash: String) {
        schemaVersion = 1; self.runID = runID; self.mode = mode
        recordingStartedAtMicroseconds = Int64(recordingStartedAt.timeIntervalSince1970 * 1_000_000)
        preparedAtMicroseconds = Int64(preparedAt.timeIntervalSince1970 * 1_000_000)
        processStartedAtMicroseconds = Int64(processStartedAt.timeIntervalSince1970 * 1_000_000)
        self.processInstanceID = processInstanceID; self.expectedCodeHash = expectedCodeHash
    }

    public func validate(runID: UUID, report: StabilityFinderRunReport,
                         diagnostics: [ProviderDiagnosticEvent]) throws {
        guard schemaVersion == 1, self.runID == runID, !expectedCodeHash.isEmpty,
              floor(recordingStartedAt.timeIntervalSince1970) == floor(report.startedAt.timeIntervalSince1970),
              preparedAt >= recordingStartedAt, preparedAt < report.finishedAt else {
            throw StabilityLiveEvidenceError.wrongExtensionBuild
        }
        let observed = diagnostics.filter { $0.source == .fileProviderExtension && $0.occurredAt >= preparedAt }
        guard !observed.isEmpty, observed.allSatisfy({ $0.processInstanceID == processInstanceID &&
            $0.processCodeHash == expectedCodeHash }),
              !observed.contains(where: { $0.operation == .runtimeInvalidate }) else {
            throw StabilityLiveEvidenceError.wrongExtensionBuild
        }
        switch mode {
        case .fresh:
            guard processStartedAt >= preparedAt,
                  let initialized = observed.filter({ $0.operation == .runtimeInitialize && $0.phase == .completed }).min(by: { $0.occurredAt < $1.occurredAt }),
                  let mutation = observed.filter({ $0.operation == .modifyItem && $0.phase == .started }).min(by: { $0.occurredAt < $1.occurredAt }),
                  initialized.occurredAt <= mutation.occurredAt else {
                throw StabilityLiveEvidenceError.wrongExtensionBuild
            }
        case .running:
            guard processStartedAt < recordingStartedAt,
                  !diagnostics.contains(where: { $0.source == .fileProviderExtension && $0.operation == .runtimeInitialize }),
                  diagnostics.contains(where: { $0.source == .fileProviderExtension && $0.occurredAt < preparedAt &&
                      $0.phase == .completed && $0.processInstanceID == processInstanceID && $0.processCodeHash == expectedCodeHash }) else {
                throw StabilityLiveEvidenceError.wrongExtensionBuild
            }
        }
    }
}
#endif
