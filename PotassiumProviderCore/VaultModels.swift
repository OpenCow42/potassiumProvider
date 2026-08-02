import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

public enum VaultFormat {
    public static let currentVersion: UInt16 = 2
    public static let currentKeyEpoch: UInt32 = 1
    public static let contentFrameSize = 1_048_576
    public static let minimumFinalFrameSize = 4_096
    public static let transactionObjectSize = 65_536
    public static let minimumCheckpointPayloadSize = 65_536
    public static let maximumCheckpointPayloadSize = 256 * 1_048_576
    public static let fileProviderIdentifierPrefix = "ev2:"
}

public struct VaultIdentifier: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

public struct VaultItemIdentifier: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public init?(fileProviderIdentifier: String) {
        guard fileProviderIdentifier.hasPrefix(VaultFormat.fileProviderIdentifierPrefix) else {
            return nil
        }
        let encoded = String(fileProviderIdentifier.dropFirst(VaultFormat.fileProviderIdentifierPrefix.count))
        guard let data = Data(base64URLEncoded: encoded),
              data.count == MemoryLayout<uuid_t>.size else {
            return nil
        }
        self.init(rawValue: UUID(bytes: data))
    }

    public var fileProviderIdentifier: String {
        VaultFormat.fileProviderIdentifierPrefix + rawValue.data.vaultBase64URLEncodedString()
    }
}

public struct VaultRevision: Codable, Hashable, Sendable {
    public static let byteCount = SHA256.Digest.byteCount

    public let data: Data

    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
    }

    public init<D: DataProtocol>(hashing data: D) {
        self.data = Data(SHA256.hash(data: data))
    }

    public static func random() throws -> VaultRevision {
        VaultRevision(data: try VaultRandom.bytes(count: byteCount))!
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Data.self)
        guard let revision = Self(data: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A vault revision must contain exactly \(Self.byteCount) bytes."
            )
        }
        self = revision
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}

public struct VaultFrontier: Codable, Equatable, Sendable {
    public private(set) var transactionIDs: Set<UUID>

    public init(transactionIDs: Set<UUID> = []) {
        self.transactionIDs = transactionIDs
    }

    public mutating func replaceParents(_ parents: Set<UUID>, with transactionID: UUID) {
        transactionIDs.subtract(parents)
        transactionIDs.insert(transactionID)
    }

    public func sortedTransactionIDs() -> [UUID] {
        transactionIDs.sorted { $0.uuidString < $1.uuidString }
    }

    public var anchorString: String {
        var material = Data("vault-frontier-v2".utf8)
        for identifier in sortedTransactionIDs() {
            material.append(identifier.data)
        }
        return Data(SHA256.hash(data: material)).base64EncodedString()
    }

    private enum CodingKeys: String, CodingKey {
        case transactionIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionIDs = Set(try container.decode([UUID].self, forKey: .transactionIDs))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sortedTransactionIDs(), forKey: .transactionIDs)
    }
}

public struct VaultContentReference: Codable, Equatable, Sendable {
    /// Logical item UUID used in frame associated data when this immutable
    /// revision was first encrypted. Copy-on-write duplicates retain it.
    public let encryptionItemID: VaultItemIdentifier
    public let objectToken: String
    public let remoteFileID: Int?
    public let wrappedContentKey: Data
    public let noncePrefix: UInt64
    public let plaintextLength: Int64
    public let plaintextDigest: Data
    public let frameCount: UInt32

    public init(
        encryptionItemID: VaultItemIdentifier,
        objectToken: String,
        remoteFileID: Int? = nil,
        wrappedContentKey: Data,
        noncePrefix: UInt64,
        plaintextLength: Int64,
        plaintextDigest: Data,
        frameCount: UInt32
    ) {
        self.encryptionItemID = encryptionItemID
        self.objectToken = objectToken
        self.remoteFileID = remoteFileID
        self.wrappedContentKey = wrappedContentKey
        self.noncePrefix = noncePrefix
        self.plaintextLength = plaintextLength
        self.plaintextDigest = plaintextDigest
        self.frameCount = frameCount
    }
}

public struct VaultItem: Codable, Equatable, Identifiable, Sendable {
    public let id: VaultItemIdentifier
    public var parentID: VaultItemIdentifier?
    public var filename: String
    public var isDirectory: Bool
    public var contentTypeIdentifier: String?
    public var createdAt: Date
    public var modifiedAt: Date
    public var plaintextSize: Int64
    public var isFavorite: Bool
    public var isTrashed: Bool
    /// Identifies the top-level trash operation that hid this item. A directly
    /// trashed item uses its own identifier; descendants inherit that value.
    /// This lets restoring a folder preserve descendants that were already in
    /// the trash independently.
    public var trashRootID: VaultItemIdentifier?
    public var contentRevision: VaultRevision
    public var metadataRevision: VaultRevision
    public var contentReference: VaultContentReference?
    public var versions: [VaultVersion]

    public init(
        id: VaultItemIdentifier = VaultItemIdentifier(),
        parentID: VaultItemIdentifier?,
        filename: String,
        isDirectory: Bool,
        contentTypeIdentifier: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        plaintextSize: Int64 = 0,
        isFavorite: Bool = false,
        isTrashed: Bool = false,
        trashRootID: VaultItemIdentifier? = nil,
        contentRevision: VaultRevision,
        metadataRevision: VaultRevision,
        contentReference: VaultContentReference? = nil,
        versions: [VaultVersion] = []
    ) {
        self.id = id
        self.parentID = parentID
        self.filename = filename
        self.isDirectory = isDirectory
        self.contentTypeIdentifier = contentTypeIdentifier
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.plaintextSize = plaintextSize
        self.isFavorite = isFavorite
        self.isTrashed = isTrashed
        self.trashRootID = trashRootID ?? (isTrashed ? id : nil)
        self.contentRevision = contentRevision
        self.metadataRevision = metadataRevision
        self.contentReference = contentReference
        self.versions = versions
    }

    public var contentType: UTType {
        if isDirectory { return .folder }
        if let contentTypeIdentifier, let type = UTType(contentTypeIdentifier) {
            return type
        }
        return UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    }
}

public enum VaultRevisionDigests {
    public static func metadata(for item: VaultItem) throws -> VaultRevision {
        try VaultCryptography.revision(for: MetadataMaterial(
            parentID: item.parentID,
            filename: item.filename,
            isDirectory: item.isDirectory,
            contentTypeIdentifier: item.contentTypeIdentifier,
            createdAt: item.createdAt,
            isFavorite: item.isFavorite,
            isTrashed: item.isTrashed,
            trashRootID: item.trashRootID
        ))
    }

    private struct MetadataMaterial: Codable {
        let parentID: VaultItemIdentifier?
        let filename: String
        let isDirectory: Bool
        let contentTypeIdentifier: String?
        let createdAt: Date
        let isFavorite: Bool
        let isTrashed: Bool
        let trashRootID: VaultItemIdentifier?
    }
}

public struct VaultVersion: Codable, Equatable, Identifiable, Sendable {
    public var id: VaultRevision { contentRevision }
    public let contentRevision: VaultRevision
    public let contentReference: VaultContentReference
    public let plaintextSize: Int64
    public let modifiedAt: Date

    public init(
        contentRevision: VaultRevision,
        contentReference: VaultContentReference,
        plaintextSize: Int64,
        modifiedAt: Date
    ) {
        self.contentRevision = contentRevision
        self.contentReference = contentReference
        self.plaintextSize = plaintextSize
        self.modifiedAt = modifiedAt
    }
}

public struct VaultTransaction: Codable, Equatable, Identifiable, Sendable {
    public enum Operation: Codable, Equatable, Sendable {
        case upsert(VaultItem)
        case trash(
            itemID: VaultItemIdentifier,
            baseContentRevision: VaultRevision,
            baseMetadataRevision: VaultRevision
        )
        case restore(itemID: VaultItemIdentifier, parentID: VaultItemIdentifier?)
        case purge(
            itemID: VaultItemIdentifier,
            baseContentRevision: VaultRevision,
            baseMetadataRevision: VaultRevision
        )
    }

    public let id: UUID
    public let parents: VaultFrontier
    public let deviceID: UUID
    public let createdAt: Date
    /// The item observed by the author before applying `operation`. It provides
    /// the common base needed for deterministic three-way conflict resolution.
    public let baseItem: VaultItem?
    public let operation: Operation

    public init(
        id: UUID = UUID(),
        parents: VaultFrontier,
        deviceID: UUID,
        createdAt: Date = Date(),
        baseItem: VaultItem? = nil,
        operation: Operation
    ) {
        self.id = id
        self.parents = parents
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.baseItem = baseItem
        self.operation = operation
    }
}

public struct VaultCheckpoint: Codable, Equatable, Sendable {
    public let frontier: VaultFrontier
    public let items: [VaultItem]
    public let transactionMerkleRoot: Data
    public let createdAt: Date

    public init(
        frontier: VaultFrontier,
        items: [VaultItem],
        transactionMerkleRoot: Data,
        createdAt: Date = Date()
    ) {
        self.frontier = frontier
        self.items = items.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        self.transactionMerkleRoot = transactionMerkleRoot
        self.createdAt = createdAt
    }
}

public struct VaultTrustedState: Codable, Equatable, Sendable {
    public let vaultID: VaultIdentifier
    public let keyEpoch: UInt32
    public let frontier: VaultFrontier
    public let checkpointDigest: Data?
    public let observedAt: Date

    public init(
        vaultID: VaultIdentifier,
        keyEpoch: UInt32,
        frontier: VaultFrontier,
        checkpointDigest: Data?,
        observedAt: Date = Date()
    ) {
        self.vaultID = vaultID
        self.keyEpoch = keyEpoch
        self.frontier = frontier
        self.checkpointDigest = checkpointDigest
        self.observedAt = observedAt
    }
}

public enum VaultObjectRole: UInt8, Codable, Sendable {
    case metadata = 1
    case transaction = 2
    case checkpoint = 3
    case merkleNode = 4
    case localState = 5
}

public struct VaultKeyMaterial: Equatable, Sendable {
    public static let byteCount = 32

    public let data: Data

    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
    }

    public static func random() throws -> VaultKeyMaterial {
        VaultKeyMaterial(data: try VaultRandom.bytes(count: byteCount))!
    }

    var symmetricKey: SymmetricKey {
        SymmetricKey(data: data)
    }
}

enum VaultRandom {
    static func bytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw VaultCryptoError.invalidLength
        }
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VaultCryptoError.randomGenerationFailed(status)
        }
        return data
    }

    static func uint64() throws -> UInt64 {
        let data = try bytes(count: MemoryLayout<UInt64>.size)
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }
}

extension UUID {
    init(bytes data: Data) {
        precondition(data.count == MemoryLayout<uuid_t>.size)
        self = data.withUnsafeBytes { bytes in
            let value = bytes.loadUnaligned(as: uuid_t.self)
            return UUID(uuid: value)
        }
    }

    var data: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: normalized)
    }

    func vaultBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
