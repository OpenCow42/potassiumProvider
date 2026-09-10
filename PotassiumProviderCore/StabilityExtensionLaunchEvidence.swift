#if STABILITY
import Foundation

public enum StabilityExtensionLaunchMode: String, Codable, Sendable {
    case fresh
    case running
}

/// Kernel birth time, signed build and diagnostic process identity jointly
/// distinguish a new extension process from one that remained alive throughout.
public struct StabilityExtensionLaunchEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let runID: UUID
    public let mode: StabilityExtensionLaunchMode
    public let preparedAt: Date
    public let processStartedAt: Date
    public let processInstanceID: UUID
    public let expectedCodeHash: String

    public init(runID: UUID, mode: StabilityExtensionLaunchMode, preparedAt: Date,
                processStartedAt: Date, processInstanceID: UUID, expectedCodeHash: String) {
        schemaVersion = 1; self.runID = runID; self.mode = mode
        self.preparedAt = preparedAt; self.processStartedAt = processStartedAt
        self.processInstanceID = processInstanceID; self.expectedCodeHash = expectedCodeHash
    }

    public func validate(runID: UUID, report: StabilityFinderRunReport,
                         diagnostics: [ProviderDiagnosticEvent]) throws {
        guard schemaVersion == 1, self.runID == runID, !expectedCodeHash.isEmpty,
              preparedAt >= report.startedAt, preparedAt < report.finishedAt else {
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
                  let initialized = observed.first(where: { $0.operation == .runtimeInitialize && $0.phase == .completed }),
                  let mutation = observed.first(where: { $0.operation == .modifyItem && $0.phase == .started }),
                  initialized.occurredAt <= mutation.occurredAt else {
                throw StabilityLiveEvidenceError.wrongExtensionBuild
            }
        case .running:
            guard processStartedAt < report.startedAt,
                  !diagnostics.contains(where: { $0.source == .fileProviderExtension && $0.operation == .runtimeInitialize }),
                  diagnostics.contains(where: { $0.source == .fileProviderExtension && $0.occurredAt < preparedAt &&
                      $0.phase == .completed && $0.processInstanceID == processInstanceID && $0.processCodeHash == expectedCodeHash }) else {
                throw StabilityLiveEvidenceError.wrongExtensionBuild
            }
        }
    }
}
#endif
