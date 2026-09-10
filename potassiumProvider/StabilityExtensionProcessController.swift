#if os(macOS) && STABILITY
import Darwin
import Foundation
import PotassiumProviderCore

/// Operates only on the exact signed extension embedded in this ordinary app.
/// Domain/account isolation is verified by the caller before any termination.
@MainActor
final class StabilityExtensionProcessController {
    private struct ProcessIdentity: Equatable {
        let pid: Int32
        let startedAt: Date
    }
    private let mode: StabilityExtensionLaunchMode
    private let run: StabilityRunHandle
    private let executable: URL
    private let expectedCodeHash: String
    private let initial: ProcessIdentity?
    private let createdAt = Date()
    private var preparedAt: Date?

    init(mode: StabilityExtensionLaunchMode, run: StabilityRunHandle) throws {
        self.mode = mode; self.run = run
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/potassiumProviderFileProvider.appex")
        guard let executable = Bundle(url: extensionURL)?.executableURL,
              let hash = StabilityDiagnosticIdentity.codeHash(at: extensionURL) else { throw FinderLiveError.unverifiedBuild }
        self.executable = executable; expectedCodeHash = hash
        initial = try Self.observe(executable: executable, codeHash: hash)
        if mode == .running, initial == nil { throw FinderLiveError.unverifiedBuild }
    }

    func prepare(verifySafety: @MainActor () async throws -> Void) async throws {
        try await verifySafety()
        if mode == .running {
            let end = ContinuousClock.now.advanced(by: .seconds(90))
            while true {
                try Task.checkCancellation()
                guard try observe() == initial else { throw FinderLiveError.unverifiedBuild }
                guard ContinuousClock.now < end else { throw StabilityDeadlineError.expired }
                let boundary = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
                let events = try StabilityRunCoordinator.readDiagnosticEvents(from: run.eventsURL)
                if boundary >= createdAt, events.contains(where: { $0.source == .fileProviderExtension &&
                    $0.phase == .completed && $0.occurredAt < boundary &&
                    $0.processCodeHash == expectedCodeHash && $0.processInstanceID != nil }) {
                    preparedAt = boundary
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        // Wait for all recorded work to finish before stopping this one process.
        // Any callback racing this fence remains visible and prevents certification.
        let end = ContinuousClock.now.advanced(by: .seconds(90))
        var quietSince: ContinuousClock.Instant?
        var lastEventID: UUID?
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < end else { throw StabilityDeadlineError.expired }
            let events = try StabilityRunCoordinator.readDiagnosticEvents(from: run.eventsURL)
            let starts = events.filter { $0.phase == .started }
            guard starts.allSatisfy({ $0.spanID != nil }),
                  !FileManager.default.fileExists(atPath: run.directoryURL.appendingPathComponent("diagnostic-health.failed").path) else {
                throw StabilityLiveEvidenceError.pendingOperations
            }
            let started = Set(starts.compactMap(\.spanID))
            let terminal = Set(events.filter { [.completed, .failed, .cancelled].contains($0.phase) }.compactMap(\.spanID))
            if events.last?.id != lastEventID { quietSince = nil; lastEventID = events.last?.id }
            if started.isSubset(of: terminal) {
                quietSince = quietSince ?? .now
                if let quietSince, quietSince.duration(to: .now) >= .seconds(2) { break }
            } else { quietSince = nil }
            try await Task.sleep(for: .milliseconds(200))
        }
        let current = try observe()
        // JSONL event times use whole seconds. Two seconds without any new
        // event leaves a clean whole-second fence without reclassifying old
        // callbacks as belonging to the replacement process.
        preparedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        if let current {
            guard try observe() == current, kill(current.pid, SIGTERM) == 0 else { throw FinderLiveError.unverifiedBuild }
            while Self.identity(pid: current.pid) == current {
                try Task.checkCancellation()
                guard ContinuousClock.now < end else { throw StabilityDeadlineError.expired }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        print("finder conflict: fresh extension launch requested after recorded work settled")
    }

    func evidence(report: StabilityFinderRunReport) throws -> StabilityExtensionLaunchEvidence {
        guard let preparedAt, let current = try observe() else { throw FinderLiveError.unverifiedBuild }
        if mode == .running, current != initial { throw FinderLiveError.unverifiedBuild }
        let events = try StabilityRunCoordinator.readDiagnosticEvents(from: run.eventsURL)
        let ids = Set(events.filter { $0.source == .fileProviderExtension && $0.occurredAt >= preparedAt }.compactMap(\.processInstanceID))
        guard ids.count == 1, let instance = ids.first else { throw FinderLiveError.unverifiedBuild }
        let evidence = StabilityExtensionLaunchEvidence(runID: run.runID, mode: mode, recordingStartedAt: report.startedAt, preparedAt: preparedAt,
            processStartedAt: current.startedAt, processInstanceID: instance, expectedCodeHash: expectedCodeHash)
        try evidence.validate(runID: run.runID, report: report, diagnostics: events)
        return evidence
    }

    private func observe() throws -> ProcessIdentity? { try Self.observe(executable: executable, codeHash: expectedCodeHash) }
    private static func observe(executable: URL, codeHash: String) throws -> ProcessIdentity? {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { throw FinderLiveError.unverifiedBuild }
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count >= 0, count <= capacity else { throw FinderLiveError.unverifiedBuild }
        var matches: [ProcessIdentity] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0, String(cString: path) == executable.path else { continue }
            guard let identity = identity(pid: pid), StabilityDiagnosticIdentity.codeHash(forProcessIdentifier: pid) == codeHash else {
                throw FinderLiveError.unverifiedBuild
            }
            matches.append(identity)
        }
        guard matches.count <= 1 else { throw FinderLiveError.unverifiedBuild }
        return matches.first
    }
    private static func identity(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return ProcessIdentity(pid: pid, startedAt: Date(timeIntervalSince1970:
            Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000))
    }
}
#endif
