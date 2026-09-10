import Foundation
import PotassiumProviderCore
@preconcurrency import SQLite
import Testing

struct SnapshotInitializationContentionTests {
    @Test func openingSnapshotStoreWaitsForTemporaryWALLockAndPreservesData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Snapshots.sqlite3")
        let lock = try SnapshotInitializationLock(url: url)
        let began = AsyncStream<Void>.makeStream()
        let opening = Task.detached {
            began.continuation.yield(())
            began.continuation.finish()
            return try KDriveSnapshotSQLiteStore(databaseURL: url)
        }
        do {
            for await _ in began.stream { break }
            // Model the exclusive lock held during WAL cleanup/recovery. The
            // opener must tolerate this short overlap before its first query.
            try await Task.sleep(for: .milliseconds(200))
            await lock.release()
            let store = try await opening.value
            let snapshot = KDriveSnapshot(anchor: "synthetic-anchor", items: [])
            try await store.save(snapshot, domainIdentifier: "synthetic", containerIdentifier: "root")
            #expect(try await store.snapshot(domainIdentifier: "synthetic", containerIdentifier: "root") == snapshot)
            let verifier = try Connection(url.path)
            #expect(try verifier.scalar("SELECT value FROM retained_fixture") as? String == "preserved")
        } catch {
            await lock.release()
            opening.cancel()
            _ = await opening.result
            throw error
        }
    }
}

private actor SnapshotInitializationLock {
    private var database: Connection?
    init(url: URL) throws {
        let database = try Connection(url.path)
        try database.execute("PRAGMA locking_mode=EXCLUSIVE")
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("CREATE TABLE retained_fixture(value TEXT)")
        try database.run("INSERT INTO retained_fixture VALUES (?)", "preserved")
        self.database = database
    }
    func release() { database = nil }
}
