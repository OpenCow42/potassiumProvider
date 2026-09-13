#if STABILITY
import Foundation

public enum StabilityConflictSchedulingPoint: String, Codable, Sendable {
    case beforeContentPreflight
    case afterContentPreflight
    case afterRenamePreflight
    case afterMovePreflight
}

public enum StabilityLiveConflictCase: String, Codable, CaseIterable, Sendable {
    case contentBeforePreflight = "content-before-preflight"
    case contentAfterPreflight = "content-after-preflight"
    case renameRename = "rename-rename"
    case moveMove = "move-move"
    case editRename = "edit-rename"
    case editMove = "edit-move"

    public var scenario: StabilityFinderScenario {
        switch self {
        case .contentAfterPreflight: .concurrentRemotePreserveBoth
        case .renameRename: .rename
        case .moveMove: .move
        case .contentBeforePreflight, .editRename, .editMove: .editAndUpload
        }
    }
    public var schedulingPoint: StabilityConflictSchedulingPoint {
        switch self {
        case .contentBeforePreflight: .beforeContentPreflight
        case .renameRename: .afterRenamePreflight
        case .moveMove: .afterMovePreflight
        default: .afterContentPreflight
        }
    }
}

/// Changes scheduling only. Each arm has a unique attempt identity; release and
/// arrival files from prior cases cannot satisfy a later race.
public enum StabilityConflictBarrier {
    public struct Ticket: Codable, Equatable, Sendable {
        public let runID: UUID
        public let caseID: StabilityLiveConflictCase
        public let attemptID: UUID
        public let subject: UUID
        public let correlationID: UUID
        public let point: StabilityConflictSchedulingPoint
    }

    private struct CompetingMutation: Codable {
        let schemaVersion: UInt16
        let ticket: Ticket
        let metadataAlias: UUID
    }

    /// Records independent server read-back while this exact attempt is held.
    /// An accepted asynchronous mutation response alone is not this evidence.
    public static func recordVerifiedCompetingMutation(_ ticket: Ticket, run: StabilityRunHandle,
                                                       itemIdentifier: String, metadataAlias: UUID) throws {
        try recordVerifiedCompetingMutation(ticket, run: run, itemIdentifier: itemIdentifier,
            metadataAlias: metadataAlias, activeRunID: StabilityDiagnosticIdentity.activeRun()?.runID)
    }
    static func recordVerifiedCompetingMutation(_ ticket: Ticket, run: StabilityRunHandle,
                                                itemIdentifier: String, metadataAlias: UUID, activeRunID: UUID?) throws {
        guard activeRunID == run.runID, try request(run) == ticket, reached(ticket, run: run),
              !settled(ticket, run: run), ticket.subject == StabilityDiagnosticIdentity.alias(for: itemIdentifier, runID: run.runID)
        else { throw CancellationError() }
        let evidence = CompetingMutation(schemaVersion: 1, ticket: ticket, metadataAlias: metadataAlias)
        try SecurePOSIXFile.createExclusively(JSONEncoder().encode(evidence),
            at: path(ticket, "competitor-verified.json", run), permissions: 0o400)
    }
    public static func competingMutationVerified(_ ticket: Ticket, run: StabilityRunHandle) -> Bool {
        guard ticket.runID == run.runID, !SecurePOSIXFile.isRegularFile(path(ticket, "cancelled", run)),
              let data = try? SecurePOSIXFile.read(path(ticket, "competitor-verified.json", run), maximumBytes: 4096),
              let evidence = try? JSONDecoder().decode(CompetingMutation.self, from: data) else { return false }
        return evidence.schemaVersion == 1 && evidence.ticket == ticket
    }

    @discardableResult
    public static func arm(run: StabilityRunHandle, itemIdentifier: String, correlationID: UUID,
                           caseID: StabilityLiveConflictCase = .contentAfterPreflight) throws -> Ticket {
        try arm(run: run, itemIdentifier: itemIdentifier, correlationID: correlationID,
            caseID: caseID, activeRunID: StabilityDiagnosticIdentity.activeRun()?.runID)
    }
    @discardableResult
    static func arm(run: StabilityRunHandle, itemIdentifier: String, correlationID: UUID,
                    caseID: StabilityLiveConflictCase = .contentAfterPreflight, activeRunID: UUID?) throws -> Ticket {
        guard activeRunID == run.runID else { throw CancellationError() }
        return try SecurePOSIXFile.withLock(at: run.directoryURL.appendingPathComponent("conflict-gate.lock"), operation: LOCK_EX) {
            if let old = try request(run), !settled(old, run: run) { throw CancellationError() }
            let ticket = Ticket(runID: run.runID, caseID: caseID, attemptID: UUID(),
                subject: StabilityDiagnosticIdentity.alias(for: itemIdentifier, runID: run.runID),
                correlationID: correlationID, point: caseID.schedulingPoint)
            try SecurePOSIXFile.replaceAtomically(JSONEncoder().encode(ticket),
                at: run.directoryURL.appendingPathComponent("conflict-request.json"), permissions: 0o600)
            return ticket
        }
    }
    public static func reached(run: StabilityRunHandle) -> Bool {
        guard let ticket = try? request(run) else { return false }
        return reached(ticket, run: run)
    }
    public static func reached(_ ticket: Ticket, run: StabilityRunHandle) -> Bool {
        ticket.runID == run.runID && SecurePOSIXFile.isRegularFile(path(ticket, "reached", run))
    }
    public static func release(run: StabilityRunHandle) throws {
        try release(run: run, activeRunID: StabilityDiagnosticIdentity.activeRun()?.runID)
    }
    public static func release(_ ticket: Ticket, run: StabilityRunHandle) throws {
        try release(ticket, run: run, activeRunID: StabilityDiagnosticIdentity.activeRun()?.runID)
    }
    static func release(run: StabilityRunHandle, activeRunID: UUID?) throws {
        guard let ticket = try request(run) else { throw CancellationError() }
        try release(ticket, run: run, activeRunID: activeRunID)
    }
    static func release(_ ticket: Ticket, run: StabilityRunHandle, activeRunID: UUID?) throws {
        guard activeRunID == run.runID, ticket.runID == run.runID, try request(run) == ticket else { throw CancellationError() }
        let url = path(ticket, "release", run)
        if !SecurePOSIXFile.isRegularFile(url) { try SecurePOSIXFile.createExclusively(Data(), at: url, permissions: 0o600) }
    }
    public static func arriveIfArmed(itemIdentifier: String, point: StabilityConflictSchedulingPoint = .afterContentPreflight) async throws {
        try await arriveIfArmed(itemIdentifier: itemIdentifier, correlationID: ProviderDiagnosticCorrelationContext.current,
            point: point, activeRun: { try StabilityDiagnosticIdentity.activeRun() })
    }
    static func arriveIfArmed(itemIdentifier: String, correlationID: UUID?,
                             point: StabilityConflictSchedulingPoint = .afterContentPreflight,
                             budget: Duration = .seconds(90),
                             activeRun: @Sendable () throws -> StabilityRunHandle?) async throws {
        try Task.checkCancellation()
        guard let run = try activeRun(), let ticket = try request(run) else { return }
        guard ticket.runID == run.runID, ticket.point == point,
              ticket.subject == StabilityDiagnosticIdentity.alias(for: itemIdentifier, runID: run.runID),
              ticket.correlationID == correlationID else { return }
        if SecurePOSIXFile.isRegularFile(path(ticket, "cancelled", run)) { throw CancellationError() }
        if SecurePOSIXFile.isRegularFile(path(ticket, "release", run)) { return }
        // Only one callback attempt can claim this gate. An overlapping attempt
        // must fail rather than bypassing the held mutation and changing the race.
        try SecurePOSIXFile.createExclusively(Data(), at: path(ticket, "reached", run), permissions: 0o600)
        let deadline = ContinuousClock.now.advanced(by: budget)
        do {
            while !SecurePOSIXFile.isRegularFile(path(ticket, "release", run)) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline, try activeRun()?.runID == run.runID,
                      try request(run) == ticket else { throw CancellationError() }
                try await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: deadline)))
            }
            try Task.checkCancellation()
        } catch {
            try? SecurePOSIXFile.createExclusively(Data(), at: path(ticket, "cancelled", run), permissions: 0o600)
            throw error
        }
    }
    private static func request(_ run: StabilityRunHandle) throws -> Ticket? {
        let url = run.directoryURL.appendingPathComponent("conflict-request.json")
        guard SecurePOSIXFile.isRegularFile(url) else { return nil }
        return try JSONDecoder().decode(Ticket.self, from: SecurePOSIXFile.read(url, maximumBytes: 4096))
    }
    private static func settled(_ ticket: Ticket, run: StabilityRunHandle) -> Bool {
        SecurePOSIXFile.isRegularFile(path(ticket, "release", run)) || SecurePOSIXFile.isRegularFile(path(ticket, "cancelled", run))
    }
    private static func path(_ ticket: Ticket, _ phase: String, _ run: StabilityRunHandle) -> URL {
        run.directoryURL.appendingPathComponent("conflict-" + ticket.attemptID.uuidString.lowercased() + "-" + phase)
    }
}
#endif
