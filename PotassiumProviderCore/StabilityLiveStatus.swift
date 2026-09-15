import Foundation

public struct StabilityLiveStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case preflight, awaitingPermissions, running, settling, finished, failed }
    public let schemaVersion: UInt16
    public let state: State
    public let scenario: StabilityFinderScenario?
    public let recordedAt: Date
    public init(state: State, scenario: StabilityFinderScenario? = nil) {
        schemaVersion = 1; self.state = state; self.scenario = scenario; recordedAt = Date()
    }
    public func write(to run: StabilityRunHandle) throws {
        guard try StabilityDiagnosticIdentity.activeRun()?.runID == run.runID,
              SecurePOSIXFile.pathKind(run.finderReportURL) == .missing else { throw CancellationError() }
        try SecurePOSIXFile.replaceAtomically(JSONEncoder().encode(self),
            at: run.directoryURL.appendingPathComponent("live-status.json"), permissions: 0o400)
    }
    public static func read(from run: StabilityRunHandle) throws -> Self? {
        let url = run.directoryURL.appendingPathComponent("live-status.json")
        guard SecurePOSIXFile.pathKind(url) != .missing else { return nil }
        return try JSONDecoder().decode(Self.self, from: SecurePOSIXFile.read(url, maximumBytes: 4096))
    }
}
