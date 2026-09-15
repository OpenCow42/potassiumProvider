import Foundation
import PotassiumProviderCore
@preconcurrency import SQLite
import Synchronization
import Testing

struct SnapshotInitializationContentionTests {
    @Test(.timeLimit(.minutes(1))) func openingSnapshotStoreWaitsForTemporaryWALLockAndPreservesData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Snapshots.sqlite3")
        // SQLite's synchronous busy wait must not occupy the executor needed to
        // release its test lock. Dedicated queues keep that contention real even
        // when the simulator's cooperative pool has only one available thread.
        let (store, waited): (KDriveSnapshotSQLiteStore, Duration) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "snapshot-contention-open").async {
                do {
                    let lock = try SnapshotInitializationLock(url: url)
                    defer { lock.release() }
                    DispatchQueue(label: "snapshot-contention-release").asyncAfter(deadline: .now() + .milliseconds(200)) {
                        lock.release()
                    }
                    let start = ContinuousClock.now
                    let store = try KDriveSnapshotSQLiteStore(databaseURL: url)
                    continuation.resume(returning: (store, start.duration(to: .now)))
                } catch { continuation.resume(throwing: error) }
            }
        }
        #expect(waited >= .milliseconds(100))
        let snapshot = KDriveSnapshot(anchor: "synthetic-anchor", items: [])
        try await store.save(snapshot, domainIdentifier: "synthetic", containerIdentifier: "root")
        #expect(try await store.snapshot(domainIdentifier: "synthetic", containerIdentifier: "root") == snapshot)
        let verifier = try Connection(url.path)
        #expect(try verifier.scalar("SELECT value FROM retained_fixture") as? String == "preserved")
    }
}

private final class SnapshotInitializationLock: Sendable {
    private let database: Mutex<Connection?>
    init(url: URL) throws {
        let database = try Connection(url.path)
        try database.execute("PRAGMA locking_mode=EXCLUSIVE")
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("CREATE TABLE retained_fixture(value TEXT)")
        try database.run("INSERT INTO retained_fixture VALUES (?)", "preserved")
        self.database = Mutex(database)
    }
    func release() { database.withLock { $0 = nil } }
}
