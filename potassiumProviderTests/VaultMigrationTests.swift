import CryptoKit
import Foundation
@testable import PotassiumProviderCore
import Testing

struct VaultMigrationTests {
    @Test func encryptedJournalDoesNotExposeSourceMetadata() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("migration.bin")
        let key = try VaultKeyMaterial.random()
        let vaultID = VaultIdentifier()
        let journal = VaultMigrationFileJournal(
            fileURL: fileURL,
            rootKey: key,
            vaultID: vaultID
        )
        let record = VaultMigrationRecord(
            source: Self.sourceItem(filename: "secret-name.txt"),
            destinationParentID: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try await journal.save(record)

        let stored = try Data(contentsOf: fileURL)
        #expect(stored.range(of: Data("secret-name.txt".utf8)) == nil)
        let reopened = VaultMigrationFileJournal(
            fileURL: fileURL,
            rootKey: key,
            vaultID: vaultID
        )
        #expect(try await reopened.record(sourceIdentifier: "source-1") == record)

        let wrongKey = VaultMigrationFileJournal(
            fileURL: fileURL,
            rootKey: try VaultKeyMaterial.random(),
            vaultID: vaultID
        )
        await #expect(throws: VaultCryptoError.authenticationFailed) {
            try await wrongKey.records()
        }
    }

    @Test func sourcePurgeCannotPrecedeAuthenticatedVerification() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plaintext = Data("highly private migration bytes".utf8)
        let source = FakeMigrationSource(data: plaintext)
        let destination = FakeMigrationDestination(directory: directory)
        let journal = InMemoryVaultMigrationJournal()
        let coordinator = VaultMigrationCoordinator(
            source: source,
            destination: destination,
            journal: journal,
            temporaryDirectoryURL: directory
        )
        _ = try await coordinator.inventory(
            Self.sourceItem(filename: "private.txt", size: Int64(plaintext.count)),
            destinationParentID: Optional<VaultItemIdentifier>.none
        )

        await #expect(throws: VaultMigrationError.sourceNotVerified("source-1")) {
            try await coordinator.purgeVerifiedSource(sourceIdentifier: "source-1")
        }
        #expect(await source.purgeCount() == 0)

        let verified = try await coordinator.resume(sourceIdentifier: "source-1")
        #expect(verified.state == VaultMigrationState.verified)
        #expect(verified.verifiedDigest == Data(SHA256.hash(data: plaintext)))
        #expect(await source.purgeCount() == 0)

        try await coordinator.purgeVerifiedSource(sourceIdentifier: "source-1")
        #expect(await source.purgeCount() == 1)
        #expect(
            try await journal.record(sourceIdentifier: "source-1")?.state
                == VaultMigrationState.sourcePurged
        )
    }

    @Test func changedSourceFailsClosedBeforeCommit() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = FakeMigrationSource(data: Data("first".utf8))
        let coordinator = VaultMigrationCoordinator(
            source: source,
            destination: FakeMigrationDestination(directory: directory),
            journal: InMemoryVaultMigrationJournal(),
            temporaryDirectoryURL: directory
        )
        _ = try await coordinator.inventory(
            Self.sourceItem(filename: "changing.txt", size: 5),
            destinationParentID: Optional<VaultItemIdentifier>.none
        )
        await source.setRevision("revision-2")

        await #expect(throws: VaultMigrationError.sourceChanged("source-1")) {
            try await coordinator.resume(sourceIdentifier: "source-1")
        }
        #expect(await source.purgeCount() == 0)
    }

    @Test func sourceChangeAfterVerificationStillBlocksPlaintextPurge() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let plaintext = Data("verified, then changed".utf8)
        let source = FakeMigrationSource(data: plaintext)
        let coordinator = VaultMigrationCoordinator(
            source: source,
            destination: FakeMigrationDestination(directory: directory),
            journal: InMemoryVaultMigrationJournal(),
            temporaryDirectoryURL: directory
        )
        _ = try await coordinator.inventory(
            Self.sourceItem(
                filename: "changed-after-verification.txt",
                size: Int64(plaintext.count)
            ),
            destinationParentID: Optional<VaultItemIdentifier>.none
        )
        let verified = try await coordinator.resume(sourceIdentifier: "source-1")
        #expect(verified.state == .verified)

        await source.setRevision("revision-2")
        await #expect(throws: VaultMigrationError.sourceChanged("source-1")) {
            try await coordinator.purgeVerifiedSource(sourceIdentifier: "source-1")
        }
        #expect(await source.purgeCount() == 0)
    }

    private static func sourceItem(
        filename: String,
        size: Int64 = 12
    ) -> VaultMigrationSourceItem {
        VaultMigrationSourceItem(
            sourceIdentifier: "source-1",
            sourceParentIdentifier: nil,
            sourceRevision: "revision-1",
            filename: filename,
            isDirectory: false,
            contentTypeIdentifier: "public.data",
            createdAt: Date(timeIntervalSince1970: 10),
            modifiedAt: Date(timeIntervalSince1970: 20),
            plaintextSize: size
        )
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "VaultMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private actor FakeMigrationSource: VaultMigrationSourceProviding {
    private let data: Data
    private var revision = "revision-1"
    private var purges = 0

    init(data: Data) {
        self.data = data
    }

    func currentRevision(sourceIdentifier: String) -> String {
        revision
    }

    func download(sourceIdentifier: String, to destinationURL: URL) throws {
        try data.write(to: destinationURL)
    }

    func purgePlaintext(sourceIdentifier: String) {
        purges += 1
    }

    func setRevision(_ value: String) {
        revision = value
    }

    func purgeCount() -> Int {
        purges
    }
}

private actor FakeMigrationDestination: VaultMigrationDestinationProviding {
    private let directory: URL
    private var contentsByItemID: [VaultItemIdentifier: Data] = [:]
    private var items: [VaultItemIdentifier: VaultItem] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func synchronize() -> VaultFrontier { VaultFrontier() }

    func item(_ identifier: VaultItemIdentifier) throws -> VaultItem {
        guard let item = items[identifier] else { throw EncryptedVaultError.itemNotFound }
        return item
    }

    func children(
        of parentID: VaultItemIdentifier?,
        trashed: Bool,
        cursor: String?,
        limit: Int
    ) -> VaultItemPage {
        VaultItemPage(items: [], nextCursor: nil)
    }

    func workingSet(limit: Int) -> [VaultItem] { Array(items.values) }

    func changes(
        since anchorString: String,
        scope: VaultChangeScope
    ) -> VaultItemChanges {
        VaultItemChanges(
            updated: [],
            deleted: [],
            frontier: VaultFrontier()
        )
    }

    func fetchContent(
        itemID: VaultItemIdentifier,
        expectedRevision: VaultRevision?,
        to plaintextURL: URL
    ) throws -> VaultItem {
        guard let item = items[itemID], let data = contentsByItemID[itemID] else {
            throw EncryptedVaultError.itemNotFound
        }
        try data.write(to: plaintextURL)
        return item
    }

    func createDirectory(
        parentID: VaultItemIdentifier?,
        filename: String,
        createdAt: Date
    ) -> VaultItem {
        let revision = VaultRevision(hashing: Data(filename.utf8))
        let item = VaultItem(
            parentID: parentID,
            filename: filename,
            isDirectory: true,
            createdAt: createdAt,
            modifiedAt: createdAt,
            contentRevision: revision,
            metadataRevision: revision
        )
        items[item.id] = item
        return item
    }

    func stageFileImport(
        itemID: VaultItemIdentifier,
        plaintextURL: URL
    ) throws -> VaultStagedContent {
        let data = try Data(contentsOf: plaintextURL)
        let ciphertextURL = directory.appendingPathComponent("stage-\(itemID.rawValue)")
        try data.write(to: ciphertextURL)
        contentsByItemID[itemID] = data
        return VaultStagedContent(
            itemID: itemID,
            contentRevision: VaultRevision(hashing: data),
            objectToken: Data(repeating: 7, count: 20).base64URL,
            ciphertextURL: ciphertextURL,
            wrappedContentKey: Data(repeating: 8, count: 60),
            noncePrefix: 9,
            plaintextLength: Int64(data.count),
            plaintextDigest: Data(SHA256.hash(data: data)),
            frameCount: 1
        )
    }

    func uploadStagedFileImport(
        _ staged: VaultStagedContent
    ) -> VaultUploadedContent {
        VaultUploadedContent(staged: staged, remoteFileID: 99)
    }

    func commitUploadedFileImport(
        _ uploaded: VaultUploadedContent,
        parentID: VaultItemIdentifier?,
        filename: String,
        contentTypeIdentifier: String?,
        createdAt: Date,
        modifiedAt: Date
    ) -> VaultItem {
        let item = VaultItem(
            id: uploaded.staged.itemID,
            parentID: parentID,
            filename: filename,
            isDirectory: false,
            contentTypeIdentifier: contentTypeIdentifier,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            plaintextSize: uploaded.staged.plaintextLength,
            contentRevision: uploaded.staged.contentRevision,
            metadataRevision: uploaded.staged.contentRevision,
            contentReference: uploaded.contentReference
        )
        items[item.id] = item
        return item
    }

    func discardStagedFileImport(_ staged: VaultStagedContent) {
        try? FileManager.default.removeItem(at: staged.ciphertextURL)
    }

    func createFile(
        parentID: VaultItemIdentifier?,
        filename: String,
        contentTypeIdentifier: String?,
        plaintextURL: URL,
        modifiedAt: Date
    ) throws -> VaultItem {
        throw FakeMigrationError.unsupported
    }

    func modify(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision,
        parentID: VaultItemIdentifier?,
        filename: String,
        favorite: Bool,
        plaintextURL: URL?,
        modifiedAt: Date
    ) throws -> VaultItem {
        throw FakeMigrationError.unsupported
    }

    func trash(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision
    ) throws {
        throw FakeMigrationError.unsupported
    }

    func restore(
        itemID: VaultItemIdentifier,
        parentID: VaultItemIdentifier?
    ) throws -> VaultItem {
        throw FakeMigrationError.unsupported
    }

    func purge(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision
    ) throws {
        throw FakeMigrationError.unsupported
    }

    func duplicate(itemID: VaultItemIdentifier) throws -> VaultItem {
        throw FakeMigrationError.unsupported
    }

    func versions(itemID: VaultItemIdentifier) -> [VaultVersion] { [] }

    func restoreVersion(
        itemID: VaultItemIdentifier,
        contentRevision: VaultRevision
    ) throws -> VaultItem {
        throw FakeMigrationError.unsupported
    }
}

private enum FakeMigrationError: Error {
    case unsupported
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
