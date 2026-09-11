#if os(macOS) && STABILITY
import Darwin
import Foundation
import Testing
@testable import PotassiumProviderCore

@MainActor
struct StabilityDiagnosticTailTests {
    @Test func registrationExcludesHistoryAndRetainsImmediateAppend() async throws {
        let (directory, run, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = event(), second = event()
        try await store.recordDiagnostic(first)
        let tail = try StabilityDiagnosticTail(eventsURL: run.eventsURL)
        try await store.recordDiagnostic(second)
        #expect(try tail.readAvailable().map(\.id) == [second.id])
        #expect(try tail.readAvailable().isEmpty)
        #expect(try StabilityRunCoordinator.readDiagnosticEvents(from: run.eventsURL).map(\.id) == [first.id, second.id])
    }

    @Test func incompleteRecordIsRetainedUntilNewline() async throws {
        let (directory, run, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = event()
        try await store.recordDiagnostic(sample)
        let record = try Data(contentsOf: run.eventsURL)
        let tail = try StabilityDiagnosticTail(eventsURL: run.eventsURL)
        try append(Data(record.dropLast()), to: run.eventsURL)
        #expect(try tail.readAvailable().isEmpty)
        try append(Data([0x0A]), to: run.eventsURL)
        #expect(try tail.readAvailable().map(\.id) == [sample.id])
        #expect(try tail.readAvailable().isEmpty)
    }

    @Test(arguments: ["replace", "truncate", "rewrite", "symlink", "health"])
    func evidenceChangesFailClosed(change: String) async throws {
        let (directory, run, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.recordDiagnostic(event())
        let original = try Data(contentsOf: run.eventsURL)
        let tail = try StabilityDiagnosticTail(eventsURL: run.eventsURL)
        switch change {
        case "replace": try original.write(to: run.eventsURL, options: .atomic)
        case "truncate":
            let handle = try FileHandle(forWritingTo: run.eventsURL)
            try handle.truncate(atOffset: 0); try handle.close()
        case "rewrite":
            let handle = try FileHandle(forWritingTo: run.eventsURL)
            try handle.write(contentsOf: Data(repeating: 0x20, count: original.count)); try handle.close()
        case "symlink":
            let other = run.directoryURL.appendingPathComponent("other.jsonl")
            try original.write(to: other)
            try FileManager.default.removeItem(at: run.eventsURL)
            try FileManager.default.createSymbolicLink(at: run.eventsURL, withDestinationURL: other)
        default: try Data().write(to: run.directoryURL.appendingPathComponent("diagnostic-health.failed"))
        }
        #expect(throws: StabilityDiagnosticTailError.self) { try tail.readAvailable() }
    }

    @Test func busyWriterDoesNotBlockOrConsumeAnEvent() async throws {
        let (directory, run, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tail = try StabilityDiagnosticTail(eventsURL: run.eventsURL)
        let fd = Darwin.open(run.eventsURL.path, O_RDWR)
        defer { Darwin.close(fd) }
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(try tail.readAvailable().isEmpty)
        #expect(flock(fd, LOCK_UN) == 0)
        let sample = event()
        try await store.recordDiagnostic(sample)
        #expect(try tail.readAvailable().map(\.id) == [sample.id])
    }

    @Test func malformedCompleteRecordIsNotIgnored() async throws {
        let (directory, run, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tail = try StabilityDiagnosticTail(eventsURL: run.eventsURL)
        try append(Data("{malformed}\n".utf8), to: run.eventsURL)
        #expect(throws: ProviderDiagnosticStoreError.corruptRecord(line: 1)) { try tail.readAvailable() }
    }

    private func event() -> ProviderDiagnosticEvent {
        ProviderDiagnosticEvent(correlationID: UUID(), source: .fileProviderExtension, operation: .fetchContents, phase: .started)
    }
    private func append(_ bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: bytes); try handle.close()
    }
    private func fixture() async throws -> (URL, StabilityRunHandle, KDriveProviderEventJSONLStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: directory)
        let run = try await coordinator.startRun(buildRevision: nil)
        return (directory, run, try KDriveProviderEventJSONLStore(runDirectoryURL: run.directoryURL))
    }
}
#endif
