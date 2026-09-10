#if STABILITY
import Foundation

/// Controls scheduling only. The held callback still sends its real conditional
/// request to kDrive after release; no response, conflict, or progress is faked.
public enum StabilityConflictBarrier {
    private struct Request: Codable {
        let subject: UUID
        let correlationID: UUID
    }
    public static func arm(run: StabilityRunHandle, itemIdentifier: String, correlationID: UUID) throws {
        try arm(run: run, itemIdentifier: itemIdentifier, correlationID: correlationID,
                activeRunID: StabilityDiagnosticIdentity.activeRun()?.runID)
    }
    static func arm(run: StabilityRunHandle, itemIdentifier: String, correlationID: UUID, activeRunID: UUID?) throws {
        guard activeRunID == run.runID else { throw CancellationError() }
        let request = Request(subject: StabilityDiagnosticIdentity.alias(for: itemIdentifier, runID: run.runID), correlationID: correlationID)
        try SecurePOSIXFile.createExclusively(JSONEncoder().encode(request), at: run.directoryURL.appendingPathComponent("conflict-request.json"), permissions: 0o600)
    }
    public static func reached(run: StabilityRunHandle) -> Bool {
        SecurePOSIXFile.isRegularFile(run.directoryURL.appendingPathComponent("conflict-reached"))
    }
    public static func release(run: StabilityRunHandle) throws {
        try release(run: run, activeRunID: StabilityDiagnosticIdentity.activeRun()?.runID)
    }
    static func release(run: StabilityRunHandle, activeRunID: UUID?) throws {
        guard activeRunID == run.runID else { throw CancellationError() }
        try SecurePOSIXFile.createExclusively(Data(), at: run.directoryURL.appendingPathComponent("conflict-release"), permissions: 0o600)
    }
    public static func arriveIfArmed(itemIdentifier: String) async throws {
        try await arriveIfArmed(itemIdentifier: itemIdentifier, correlationID: ProviderDiagnosticCorrelationContext.current,
                               activeRun: { try StabilityDiagnosticIdentity.activeRun() })
    }
    static func arriveIfArmed(itemIdentifier: String, correlationID: UUID?, budget: Duration = .seconds(90),
                             activeRun: @Sendable () throws -> StabilityRunHandle?) async throws {
        try Task.checkCancellation()
        guard let run = try activeRun() else { return }
        let url = run.directoryURL.appendingPathComponent("conflict-request.json")
        guard SecurePOSIXFile.isRegularFile(url) else { return }
        let request = try JSONDecoder().decode(Request.self, from: SecurePOSIXFile.read(url, maximumBytes: 4096))
        guard request.subject == StabilityDiagnosticIdentity.alias(for: itemIdentifier, runID: run.runID),
              request.correlationID == correlationID else { return }
        if SecurePOSIXFile.isRegularFile(run.directoryURL.appendingPathComponent("conflict-release")) { return }
        try SecurePOSIXFile.createExclusively(Data(), at: run.directoryURL.appendingPathComponent("conflict-reached"), permissions: 0o600)
        let deadline = ContinuousClock.now.advanced(by: budget)
        while !SecurePOSIXFile.isRegularFile(run.directoryURL.appendingPathComponent("conflict-release")) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, try activeRun()?.runID == run.runID else {
                throw CancellationError()
            }
            try await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: deadline)))
        }
    }
}
#endif
