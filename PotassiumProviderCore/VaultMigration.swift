import CryptoKit
import Foundation

public enum VaultMigrationState: Int, Codable, Comparable, Sendable {
    case inventoried
    case encrypted
    case uploaded
    case committed
    case verified
    case sourcePurged

    public static func < (lhs: VaultMigrationState, rhs: VaultMigrationState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct VaultMigrationSourceItem: Codable, Equatable, Sendable {
    public let sourceIdentifier: String
    public let sourceParentIdentifier: String?
    public let sourceRevision: String
    public let filename: String
    public let isDirectory: Bool
    public let contentTypeIdentifier: String?
    public let createdAt: Date
    public let modifiedAt: Date
    public let plaintextSize: Int64

    public init(
        sourceIdentifier: String,
        sourceParentIdentifier: String?,
        sourceRevision: String,
        filename: String,
        isDirectory: Bool,
        contentTypeIdentifier: String?,
        createdAt: Date,
        modifiedAt: Date,
        plaintextSize: Int64
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.sourceParentIdentifier = sourceParentIdentifier
        self.sourceRevision = sourceRevision
        self.filename = filename
        self.isDirectory = isDirectory
        self.contentTypeIdentifier = contentTypeIdentifier
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.plaintextSize = plaintextSize
    }
}

public struct VaultMigrationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { source.sourceIdentifier }
    public var source: VaultMigrationSourceItem
    public var destinationItemID: VaultItemIdentifier
    public var destinationParentID: VaultItemIdentifier?
    public var state: VaultMigrationState
    public var stagedContent: VaultStagedContent?
    public var uploadedContent: VaultUploadedContent?
    public var verifiedDigest: Data?
    public var updatedAt: Date

    public init(
        source: VaultMigrationSourceItem,
        destinationItemID: VaultItemIdentifier = VaultItemIdentifier(),
        destinationParentID: VaultItemIdentifier?,
        state: VaultMigrationState = .inventoried,
        stagedContent: VaultStagedContent? = nil,
        uploadedContent: VaultUploadedContent? = nil,
        verifiedDigest: Data? = nil,
        updatedAt: Date = Date()
    ) {
        self.source = source
        self.destinationItemID = destinationItemID
        self.destinationParentID = destinationParentID
        self.state = state
        self.stagedContent = stagedContent
        self.uploadedContent = uploadedContent
        self.verifiedDigest = verifiedDigest
        self.updatedAt = updatedAt
    }
}

public struct VaultMigrationPreflight: Equatable, Sendable {
    public let itemCount: Int
    public let plaintextByteCount: Int64
    public let estimatedCiphertextByteCount: Int64
    public let inaccessibleItemCount: Int
    public let sharedItemCount: Int
    public let versionCount: Int
    public let ownsKnownFolders: Bool

    public init(
        itemCount: Int,
        plaintextByteCount: Int64,
        estimatedCiphertextByteCount: Int64,
        inaccessibleItemCount: Int,
        sharedItemCount: Int,
        versionCount: Int,
        ownsKnownFolders: Bool
    ) {
        self.itemCount = itemCount
        self.plaintextByteCount = plaintextByteCount
        self.estimatedCiphertextByteCount = estimatedCiphertextByteCount
        self.inaccessibleItemCount = inaccessibleItemCount
        self.sharedItemCount = sharedItemCount
        self.versionCount = versionCount
        self.ownsKnownFolders = ownsKnownFolders
    }
}

public protocol VaultMigrationJournalStoring: Sendable {
    func records() async throws -> [VaultMigrationRecord]
    func record(sourceIdentifier: String) async throws -> VaultMigrationRecord?
    func save(_ record: VaultMigrationRecord) async throws
    func removeAll() async throws
}

public actor InMemoryVaultMigrationJournal: VaultMigrationJournalStoring {
    private var values: [String: VaultMigrationRecord] = [:]

    public init() {}

    public func records() -> [VaultMigrationRecord] {
        values.values.sorted { $0.source.sourceIdentifier < $1.source.sourceIdentifier }
    }

    public func record(sourceIdentifier: String) -> VaultMigrationRecord? {
        values[sourceIdentifier]
    }

    public func save(_ record: VaultMigrationRecord) {
        values[record.source.sourceIdentifier] = record
    }

    public func removeAll() {
        values.removeAll()
    }
}

/// The complete migration journal is encrypted with the vault local-state key,
/// so source names and paths never appear in local support databases.
public actor VaultMigrationFileJournal: VaultMigrationJournalStoring {
    private let fileURL: URL
    private let rootKey: VaultKeyMaterial
    private let vaultID: VaultIdentifier
    private let keyEpoch: UInt32
    private var cachedRecords: [String: VaultMigrationRecord]?

    public init(
        fileURL: URL,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) {
        self.fileURL = fileURL
        self.rootKey = rootKey
        self.vaultID = vaultID
        self.keyEpoch = keyEpoch
    }

    public func records() throws -> [VaultMigrationRecord] {
        try load().values.sorted { $0.source.sourceIdentifier < $1.source.sourceIdentifier }
    }

    public func record(sourceIdentifier: String) throws -> VaultMigrationRecord? {
        try load()[sourceIdentifier]
    }

    public func save(_ record: VaultMigrationRecord) throws {
        var values = try load()
        values[record.source.sourceIdentifier] = record
        try persist(values)
    }

    public func removeAll() throws {
        cachedRecords = [:]
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func load() throws -> [String: VaultMigrationRecord] {
        if let cachedRecords { return cachedRecords }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedRecords = [:]
            return [:]
        }
        let envelope = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let records = try VaultCryptography.open(
            [VaultMigrationRecord].self,
            envelope: envelope,
            expectedRole: .localState,
            expectedObjectToken: objectToken,
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
        let values = Dictionary(uniqueKeysWithValues: records.map {
            ($0.source.sourceIdentifier, $0)
        })
        cachedRecords = values
        return values
    }

    private func persist(_ records: [String: VaultMigrationRecord]) throws {
        let sorted = records.values.sorted {
            $0.source.sourceIdentifier < $1.source.sourceIdentifier
        }
        let envelope = try VaultCryptography.seal(
            sorted,
            role: .localState,
            objectToken: objectToken,
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try envelope.write(to: fileURL, options: [.atomic, .completeFileProtection])
        cachedRecords = records
    }

    private var objectToken: String {
        Data(
            SHA256.hash(data: Data("migration-journal:\(vaultID.rawValue.uuidString)".utf8))
                .prefix(20)
        )
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public protocol VaultMigrationSourceProviding: Sendable {
    func currentRevision(sourceIdentifier: String) async throws -> String
    func download(sourceIdentifier: String, to destinationURL: URL) async throws
    func purgePlaintext(sourceIdentifier: String) async throws
}

public protocol VaultMigrationDestinationProviding: EncryptedVaultProviding {
    func stageFileImport(
        itemID: VaultItemIdentifier,
        plaintextURL: URL
    ) async throws -> VaultStagedContent
    func uploadStagedFileImport(
        _ staged: VaultStagedContent
    ) async throws -> VaultUploadedContent
    func commitUploadedFileImport(
        _ uploaded: VaultUploadedContent,
        parentID: VaultItemIdentifier?,
        filename: String,
        contentTypeIdentifier: String?,
        createdAt: Date,
        modifiedAt: Date
    ) async throws -> VaultItem
    func discardStagedFileImport(_ staged: VaultStagedContent) async
}

extension EncryptedVaultService: VaultMigrationDestinationProviding {}

public enum VaultMigrationError: Error, Equatable, LocalizedError, Sendable {
    case sourceChanged(String)
    case verificationFailed(String)
    case invalidJournalState(String)
    case sourceNotVerified(String)

    public var errorDescription: String? {
        switch self {
        case .sourceChanged:
            return "The source item changed during migration and must be recopied."
        case .verificationFailed:
            return "The encrypted destination did not verify against the source digest and size."
        case .invalidJournalState:
            return "The resumable migration journal contains an invalid transition."
        case .sourceNotVerified:
            return "Plaintext cannot be purged before its encrypted copy is verified."
        }
    }
}

/// Resumable single-item state machine. Source purge is deliberately a
/// separate method; no copy operation can delete plaintext.
public actor VaultMigrationCoordinator {
    private let source: any VaultMigrationSourceProviding
    private let destination: any VaultMigrationDestinationProviding
    private let journal: any VaultMigrationJournalStoring
    private let temporaryDirectoryURL: URL

    public init(
        source: any VaultMigrationSourceProviding,
        destination: any VaultMigrationDestinationProviding,
        journal: any VaultMigrationJournalStoring,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.source = source
        self.destination = destination
        self.journal = journal
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    public func inventory(
        _ sourceItem: VaultMigrationSourceItem,
        destinationParentID: VaultItemIdentifier?
    ) async throws -> VaultMigrationRecord {
        if let existing = try await journal.record(
            sourceIdentifier: sourceItem.sourceIdentifier
        ), existing.source.sourceRevision == sourceItem.sourceRevision {
            return existing
        }
        let record = VaultMigrationRecord(
            source: sourceItem,
            destinationParentID: destinationParentID
        )
        try await journal.save(record)
        return record
    }

    public func resume(sourceIdentifier: String) async throws -> VaultMigrationRecord {
        guard var record = try await journal.record(sourceIdentifier: sourceIdentifier) else {
            throw VaultMigrationError.invalidJournalState(sourceIdentifier)
        }
        if record.state == .sourcePurged { return record }
        guard try await source.currentRevision(sourceIdentifier: sourceIdentifier)
            == record.source.sourceRevision else {
            if let staged = record.stagedContent {
                await destination.discardStagedFileImport(staged)
            }
            throw VaultMigrationError.sourceChanged(sourceIdentifier)
        }
        if record.state == .verified { return record }

        if record.source.isDirectory {
            if record.state == .inventoried {
                let item = try await destination.createDirectory(
                    parentID: record.destinationParentID,
                    filename: record.source.filename,
                    createdAt: record.source.createdAt
                )
                record.destinationItemID = item.id
                record.state = .committed
                record.updatedAt = Date()
                try await journal.save(record)
            }
            // Observe the immutable transaction back through the complete
            // journal listing before treating the folder as remotely durable.
            _ = try await destination.synchronize()
            record.state = .verified
            record.updatedAt = Date()
            try await journal.save(record)
            return record
        }

        if record.state == .inventoried || stagedFileIsMissing(record) {
            let plaintextURL = temporaryURL(prefix: "migration-plaintext")
            defer { try? FileManager.default.removeItem(at: plaintextURL) }
            try await source.download(
                sourceIdentifier: sourceIdentifier,
                to: plaintextURL
            )
            try applyPlaintextProtection(to: plaintextURL)
            let staged = try await destination.stageFileImport(
                itemID: record.destinationItemID,
                plaintextURL: plaintextURL
            )
            record.stagedContent = staged
            record.uploadedContent = nil
            record.state = .encrypted
            record.updatedAt = Date()
            try await journal.save(record)
        }

        if record.state == .encrypted {
            guard let staged = record.stagedContent else {
                throw VaultMigrationError.invalidJournalState(sourceIdentifier)
            }
            let uploaded = try await destination.uploadStagedFileImport(staged)
            record.uploadedContent = uploaded
            record.state = .uploaded
            record.updatedAt = Date()
            try await journal.save(record)
        }

        if record.state == .uploaded {
            guard try await source.currentRevision(sourceIdentifier: sourceIdentifier)
                    == record.source.sourceRevision,
                  let uploaded = record.uploadedContent else {
                throw VaultMigrationError.sourceChanged(sourceIdentifier)
            }
            _ = try await destination.commitUploadedFileImport(
                uploaded,
                parentID: record.destinationParentID,
                filename: record.source.filename,
                contentTypeIdentifier: record.source.contentTypeIdentifier,
                createdAt: record.source.createdAt,
                modifiedAt: record.source.modifiedAt
            )
            record.state = .committed
            record.updatedAt = Date()
            try await journal.save(record)
        }

        if record.state == .committed {
            let verificationURL = temporaryURL(prefix: "migration-verification")
            defer { try? FileManager.default.removeItem(at: verificationURL) }
            _ = try await destination.fetchContent(
                itemID: record.destinationItemID,
                expectedRevision: record.uploadedContent?.staged.contentRevision,
                to: verificationURL
            )
            let digest = try Self.digestAndSize(of: verificationURL)
            guard digest.size == record.source.plaintextSize,
                  digest.digest == record.uploadedContent?.staged.plaintextDigest else {
                throw VaultMigrationError.verificationFailed(sourceIdentifier)
            }
            guard try await source.currentRevision(
                sourceIdentifier: sourceIdentifier
            ) == record.source.sourceRevision else {
                throw VaultMigrationError.sourceChanged(sourceIdentifier)
            }
            record.verifiedDigest = digest.digest
            record.state = .verified
            record.updatedAt = Date()
            try await journal.save(record)
        }
        return record
    }

    public func purgeVerifiedSource(sourceIdentifier: String) async throws {
        guard var record = try await journal.record(sourceIdentifier: sourceIdentifier),
              record.state == .verified else {
            throw VaultMigrationError.sourceNotVerified(sourceIdentifier)
        }
        guard try await source.currentRevision(
            sourceIdentifier: sourceIdentifier
        ) == record.source.sourceRevision else {
            throw VaultMigrationError.sourceChanged(sourceIdentifier)
        }
        try await source.purgePlaintext(sourceIdentifier: sourceIdentifier)
        record.state = .sourcePurged
        record.updatedAt = Date()
        try await journal.save(record)
    }

    private func stagedFileIsMissing(_ record: VaultMigrationRecord) -> Bool {
        guard record.state == .encrypted, let staged = record.stagedContent else {
            return false
        }
        return FileManager.default.fileExists(atPath: staged.ciphertextURL.path) == false
    }

    private func temporaryURL(prefix: String) -> URL {
        temporaryDirectoryURL.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: false
        )
    }

    private func applyPlaintextProtection(to url: URL) throws {
        #if canImport(Darwin)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func digestAndSize(of url: URL) throws -> (digest: Data, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let data = try handle.read(upToCount: VaultFormat.contentFrameSize),
              data.isEmpty == false {
            hasher.update(data: data)
            size += Int64(data.count)
        }
        return (Data(hasher.finalize()), size)
    }
}
