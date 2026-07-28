import Foundation
@testable import PotassiumProviderCore
import Testing

struct VaultSQLiteStoreTests {
    @Test func generationsRoundTripWithoutPersistingDecryptedNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VaultSQLiteStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("vault.sqlite3")
        let key = try VaultKeyMaterial.random()
        let vaultID = VaultIdentifier()
        let store = try VaultSQLiteStore(
            databaseURL: databaseURL,
            domainIdentifier: "encrypted-domain",
            vaultID: vaultID,
            rootKey: key
        )
        let revision = VaultRevision(hashing: Data("revision".utf8))
        let item = VaultItem(
            parentID: nil,
            filename: "extremely-secret-name.pdf",
            isDirectory: false,
            contentTypeIdentifier: "com.adobe.pdf",
            createdAt: Date(timeIntervalSince1970: 10),
            modifiedAt: Date(timeIntervalSince1970: 20),
            plaintextSize: 123,
            contentRevision: revision,
            metadataRevision: revision
        )
        let frontier = VaultFrontier(transactionIDs: [UUID()])
        try await store.replace(with: VaultReducedState(
            items: [item.id: item],
            frontier: frontier
        ))

        #expect(try await store.item(item.id) == item)
        #expect(try await store.state().frontier == frontier)
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            let databaseBytes = try Data(contentsOf: url)
            #expect(databaseBytes.range(of: Data(item.filename.utf8)) == nil)
            #expect(databaseBytes.range(of: Data("com.adobe.pdf".utf8)) == nil)
        }

        let wrongKeyStore = try VaultSQLiteStore(
            databaseURL: databaseURL,
            domainIdentifier: "encrypted-domain",
            vaultID: vaultID,
            rootKey: try VaultKeyMaterial.random()
        )
        await #expect(throws: VaultCryptoError.authenticationFailed) {
            try await wrongKeyStore.item(item.id)
        }
    }
}
