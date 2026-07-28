import CryptoKit
import Foundation
@preconcurrency import SQLite

public struct VaultStoredJournalObject: Equatable, Sendable {
    public let transactionID: UUID
    public let objectToken: String
    public let remoteFileID: Int?
    public let envelope: Data
    public let committedAt: Date

    public init(
        transactionID: UUID,
        objectToken: String,
        remoteFileID: Int?,
        envelope: Data,
        committedAt: Date
    ) {
        self.transactionID = transactionID
        self.objectToken = objectToken
        self.remoteFileID = remoteFileID
        self.envelope = envelope
        self.committedAt = committedAt
    }
}

public struct VaultGarbageCollectionCandidate: Codable, Equatable, Sendable {
    public let objectToken: String
    public let remoteFileID: Int
    public let firstObservedAt: Date
    public let observedFrontier: VaultFrontier

    public init(
        objectToken: String,
        remoteFileID: Int,
        firstObservedAt: Date,
        observedFrontier: VaultFrontier
    ) {
        self.objectToken = objectToken
        self.remoteFileID = remoteFileID
        self.firstObservedAt = firstObservedAt
        self.observedFrontier = observedFrontier
    }
}

public protocol VaultLocalStateStoring: Sendable {
    func item(_ identifier: VaultItemIdentifier) async throws -> VaultItem?
    func children(of parentID: VaultItemIdentifier?, trashed: Bool) async throws -> [VaultItem]
    func allItems() async throws -> [VaultItem]
    func state() async throws -> VaultReducedState
    func state(anchorString: String) async throws -> VaultReducedState?
    func replace(with state: VaultReducedState) async throws
    func save(
        state: VaultReducedState,
        journalObjects: [VaultStoredJournalObject]
    ) async throws
    func journalObjects() async throws -> [VaultStoredJournalObject]
    func garbageCollectionCandidates() async throws -> [VaultGarbageCollectionCandidate]
    func replaceGarbageCollectionCandidates(
        _ candidates: [VaultGarbageCollectionCandidate]
    ) async throws
    func removeAll() async throws
}

public enum VaultLocalStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidStoredIdentifier(String)
    case missingState

    public var errorDescription: String? {
        switch self {
        case .invalidStoredIdentifier:
            return "The local encrypted vault index contains an invalid item identifier."
        case .missingState:
            return "The local encrypted vault index is missing its state record."
        }
    }
}

/// A generation-based logical index. Item payloads and the frontier are AEAD
/// encrypted even though this database lives only on the trusted endpoint.
public actor VaultSQLiteStore: VaultLocalStateStoring {
    private let database: Connection
    private let domainIdentifier: String
    private let vaultID: VaultIdentifier
    private let rootKey: VaultKeyMaterial
    private let keyEpoch: UInt32

    public init(
        databaseURL: URL,
        domainIdentifier: String,
        vaultID: VaultIdentifier,
        rootKey: VaultKeyMaterial,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try Connection(databaseURL.path)
        try Self.configure(database)
        try Self.createTables(database)
        self.database = database
        self.domainIdentifier = domainIdentifier
        self.vaultID = vaultID
        self.rootKey = rootKey
        self.keyEpoch = keyEpoch
    }

    public init(
        appGroupIdentifier: String = ProviderConstants.appGroupIdentifier,
        domainIdentifier: String,
        vaultID: VaultIdentifier,
        rootKey: VaultKeyMaterial,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw DomainConfigurationStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        try self.init(
            databaseURL: containerURL.appendingPathComponent("EncryptedVaults.sqlite3"),
            domainIdentifier: domainIdentifier,
            vaultID: vaultID,
            rootKey: rootKey,
            keyEpoch: keyEpoch
        )
    }

    public func item(_ identifier: VaultItemIdentifier) throws -> VaultItem? {
        guard let generation = try activeGeneration() else { return nil }
        let query = Schema.items.filter(
            Schema.domain == domainIdentifier &&
            Schema.generation == generation &&
            Schema.itemID == identifier.rawValue.uuidString
        ).limit(1)
        guard let row = try database.pluck(query) else { return nil }
        return try decodeItem(row[Schema.envelope], identifier: identifier)
    }

    public func children(
        of parentID: VaultItemIdentifier?,
        trashed: Bool
    ) throws -> [VaultItem] {
        guard let generation = try activeGeneration() else { return [] }
        let parent = parentID?.rawValue.uuidString ?? ""
        let query = Schema.items.filter(
            Schema.domain == domainIdentifier &&
            Schema.generation == generation &&
            Schema.parentID == parent &&
            Schema.isTrashed == trashed
        ).order(Schema.itemID.asc)
        return try database.prepare(query).map { row in
            let identifier = try itemIdentifier(row[Schema.itemID])
            return try decodeItem(row[Schema.envelope], identifier: identifier)
        }
    }

    public func allItems() throws -> [VaultItem] {
        guard let generation = try activeGeneration() else { return [] }
        let query = Schema.items.filter(
            Schema.domain == domainIdentifier &&
            Schema.generation == generation
        ).order(Schema.itemID.asc)
        return try database.prepare(query).map { row in
            let identifier = try itemIdentifier(row[Schema.itemID])
            return try decodeItem(row[Schema.envelope], identifier: identifier)
        }
    }

    public func state() throws -> VaultReducedState {
        guard let generation = try activeGeneration(),
              let stateRow = try database.pluck(Schema.generations.filter(
                Schema.domain == domainIdentifier &&
                Schema.generation == generation
              )) else {
            return VaultReducedState()
        }
        return try state(generation: generation, stateRow: stateRow)
    }

    public func state(anchorString: String) throws -> VaultReducedState? {
        let query = Schema.generations.filter(
            Schema.domain == domainIdentifier
        ).order(Schema.generation.desc)
        for row in try database.prepare(query) {
            let stored = try decodeGenerationState(row[Schema.stateEnvelope])
            guard stored.frontier.anchorString == anchorString else {
                continue
            }
            return try state(
                generation: row[Schema.generation],
                stateRow: row
            )
        }
        return nil
    }

    private func state(
        generation: Int64,
        stateRow: Row
    ) throws -> VaultReducedState {
        let items = try items(generation: generation)
        let stored = try decodeGenerationState(stateRow[Schema.stateEnvelope])
        return VaultReducedState(
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            frontier: stored.frontier,
            appliedTransactionIDs: Set(stored.appliedTransactionIDs),
            conflicts: stored.conflicts
        )
    }

    public func replace(with state: VaultReducedState) throws {
        try database.transaction {
            try writeGeneration(state)
        }
    }

    public func save(
        state: VaultReducedState,
        journalObjects: [VaultStoredJournalObject]
    ) throws {
        try database.transaction {
            for journalObject in journalObjects {
                try database.run(
                    Schema.journal.insert(or: .ignore,
                        Schema.domain <- domainIdentifier,
                        Schema.transactionID <- journalObject.transactionID.uuidString,
                        Schema.objectToken <- journalObject.objectToken,
                        Schema.remoteFileID <- journalObject.remoteFileID.map(Int64.init),
                        Schema.envelope <- Blob(bytes: [UInt8](journalObject.envelope)),
                        Schema.committedAt <- journalObject.committedAt.timeIntervalSince1970
                    )
                )
            }
            try writeGeneration(state)
        }
    }

    public func journalObjects() throws -> [VaultStoredJournalObject] {
        let query = Schema.journal.filter(
            Schema.domain == domainIdentifier
        ).order(Schema.transactionID.asc)
        return try database.prepare(query).map { row in
            guard let transactionID = UUID(uuidString: row[Schema.transactionID]) else {
                throw VaultLocalStoreError.invalidStoredIdentifier(row[Schema.transactionID])
            }
            return VaultStoredJournalObject(
                transactionID: transactionID,
                objectToken: row[Schema.objectToken],
                remoteFileID: row[Schema.remoteFileID].map(Int.init),
                envelope: Data(row[Schema.envelope].bytes),
                committedAt: Date(timeIntervalSince1970: row[Schema.committedAt])
            )
        }
    }

    public func garbageCollectionCandidates() throws -> [VaultGarbageCollectionCandidate] {
        let query = Schema.garbageCollection.filter(
            Schema.domain == domainIdentifier
        ).order(Schema.objectToken.asc)
        return try database.prepare(query).map { row in
            let token = row[Schema.objectToken]
            return try VaultCryptography.open(
                VaultGarbageCollectionCandidate.self,
                envelope: Data(row[Schema.envelope].bytes),
                expectedRole: .localState,
                expectedObjectToken: localToken("garbage-collection:\(token)"),
                rootKey: rootKey,
                vaultID: vaultID,
                keyEpoch: keyEpoch
            )
        }
    }

    public func replaceGarbageCollectionCandidates(
        _ candidates: [VaultGarbageCollectionCandidate]
    ) throws {
        try database.transaction {
            try database.run(Schema.garbageCollection.filter(
                Schema.domain == domainIdentifier
            ).delete())
            for candidate in candidates.sorted(by: {
                $0.objectToken < $1.objectToken
            }) {
                let envelope = try VaultCryptography.seal(
                    candidate,
                    role: .localState,
                    objectToken: localToken(
                        "garbage-collection:\(candidate.objectToken)"
                    ),
                    rootKey: rootKey,
                    vaultID: vaultID,
                    keyEpoch: keyEpoch
                )
                try database.run(
                    Schema.garbageCollection.insert(
                        Schema.domain <- domainIdentifier,
                        Schema.objectToken <- candidate.objectToken,
                        Schema.envelope <- Blob(bytes: [UInt8](envelope))
                    )
                )
            }
        }
    }

    public func removeAll() throws {
        try database.transaction {
            try database.run(Schema.items.filter(Schema.domain == domainIdentifier).delete())
            try database.run(Schema.generations.filter(Schema.domain == domainIdentifier).delete())
            try database.run(Schema.heads.filter(Schema.domain == domainIdentifier).delete())
            try database.run(Schema.journal.filter(Schema.domain == domainIdentifier).delete())
            try database.run(
                Schema.garbageCollection.filter(
                    Schema.domain == domainIdentifier
                ).delete()
            )
        }
    }

    private func writeGeneration(_ state: VaultReducedState) throws {
        let nextGeneration = (try activeGeneration() ?? 0) + 1
        let generationState = StoredGenerationState(
            frontier: state.frontier,
            appliedTransactionIDs: state.appliedTransactionIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            conflicts: state.conflicts
        )
        let stateEnvelope = try encodeGenerationState(generationState)
        try database.run(
            Schema.generations.insert(
                Schema.domain <- domainIdentifier,
                Schema.generation <- nextGeneration,
                Schema.stateEnvelope <- Blob(bytes: [UInt8](stateEnvelope)),
                Schema.createdAt <- Date().timeIntervalSince1970
            )
        )

        for item in state.items.values.sorted(by: {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }) {
            let envelope = try encodeItem(item)
            try database.run(
                Schema.items.insert(
                    Schema.domain <- domainIdentifier,
                    Schema.generation <- nextGeneration,
                    Schema.itemID <- item.id.rawValue.uuidString,
                    Schema.parentID <- item.parentID?.rawValue.uuidString ?? "",
                    Schema.isTrashed <- item.isTrashed,
                    Schema.envelope <- Blob(bytes: [UInt8](envelope))
                )
            )
        }

        try database.run(
            Schema.heads.insert(or: .replace,
                Schema.domain <- domainIdentifier,
                Schema.generation <- nextGeneration
            )
        )
        try database.run(Schema.items.filter(
            Schema.domain == domainIdentifier &&
            Schema.generation <= nextGeneration - Self.retainedGenerationCount
        ).delete())
        try database.run(Schema.generations.filter(
            Schema.domain == domainIdentifier &&
            Schema.generation <= nextGeneration - Self.retainedGenerationCount
        ).delete())
    }

    private func activeGeneration() throws -> Int64? {
        try database.pluck(Schema.heads.filter(
            Schema.domain == domainIdentifier
        ))?[Schema.generation]
    }

    private func items(generation: Int64) throws -> [VaultItem] {
        let query = Schema.items.filter(
            Schema.domain == domainIdentifier &&
            Schema.generation == generation
        ).order(Schema.itemID.asc)
        return try database.prepare(query).map { row in
            let identifier = try itemIdentifier(row[Schema.itemID])
            return try decodeItem(row[Schema.envelope], identifier: identifier)
        }
    }

    private func encodeItem(_ item: VaultItem) throws -> Data {
        try VaultCryptography.seal(
            item,
            role: .localState,
            objectToken: localToken("item:\(item.id.rawValue.uuidString)"),
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
    }

    private func decodeItem(
        _ blob: Blob,
        identifier: VaultItemIdentifier
    ) throws -> VaultItem {
        try VaultCryptography.open(
            VaultItem.self,
            envelope: Data(blob.bytes),
            expectedRole: .localState,
            expectedObjectToken: localToken("item:\(identifier.rawValue.uuidString)"),
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
    }

    private func encodeGenerationState(_ state: StoredGenerationState) throws -> Data {
        try VaultCryptography.seal(
            state,
            role: .localState,
            objectToken: localToken("generation-state"),
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
    }

    private func decodeGenerationState(_ blob: Blob) throws -> StoredGenerationState {
        try VaultCryptography.open(
            StoredGenerationState.self,
            envelope: Data(blob.bytes),
            expectedRole: .localState,
            expectedObjectToken: localToken("generation-state"),
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
    }

    private func localToken(_ purpose: String) -> String {
        let digest = Data(SHA256.hash(data: Data(
            "local:\(domainIdentifier):\(purpose)".utf8
        )))
        return Data(digest.prefix(20)).vaultBase64URLEncodedString()
    }

    private func itemIdentifier(_ value: String) throws -> VaultItemIdentifier {
        guard let uuid = UUID(uuidString: value) else {
            throw VaultLocalStoreError.invalidStoredIdentifier(value)
        }
        return VaultItemIdentifier(rawValue: uuid)
    }

    private static func configure(_ database: Connection) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA busy_timeout = 5000")
    }

    private static func createTables(_ database: Connection) throws {
        try database.run(Schema.heads.create(ifNotExists: true) { table in
            table.column(Schema.domain, primaryKey: true)
            table.column(Schema.generation)
        })
        try database.run(Schema.generations.create(ifNotExists: true) { table in
            table.column(Schema.domain)
            table.column(Schema.generation)
            table.column(Schema.stateEnvelope)
            table.column(Schema.createdAt)
            table.primaryKey(Schema.domain, Schema.generation)
        })
        try database.run(Schema.items.create(ifNotExists: true) { table in
            table.column(Schema.domain)
            table.column(Schema.generation)
            table.column(Schema.itemID)
            table.column(Schema.parentID)
            table.column(Schema.isTrashed)
            table.column(Schema.envelope)
            table.primaryKey(Schema.domain, Schema.generation, Schema.itemID)
        })
        try database.run(Schema.items.createIndex(
            Schema.domain,
            Schema.generation,
            Schema.parentID,
            Schema.isTrashed,
            ifNotExists: true
        ))
        try database.run(Schema.journal.create(ifNotExists: true) { table in
            table.column(Schema.domain)
            table.column(Schema.transactionID)
            table.column(Schema.objectToken)
            table.column(Schema.remoteFileID)
            table.column(Schema.envelope)
            table.column(Schema.committedAt)
            table.primaryKey(Schema.domain, Schema.transactionID)
        })
        try database.run(Schema.garbageCollection.create(ifNotExists: true) { table in
            table.column(Schema.domain)
            table.column(Schema.objectToken)
            table.column(Schema.envelope)
            table.primaryKey(Schema.domain, Schema.objectToken)
        })
    }

    private struct StoredGenerationState: Codable {
        let frontier: VaultFrontier
        let appliedTransactionIDs: [UUID]
        let conflicts: [VaultConflict]
    }

    private enum Schema {
        static let heads = Table("vault_heads_v1")
        static let generations = Table("vault_generations_v1")
        static let items = Table("vault_items_v1")
        static let journal = Table("vault_journal_v1")
        static let garbageCollection = Table("vault_gc_candidates_v1")

        static let domain = Expression<String>("domain_identifier")
        static let generation = Expression<Int64>("generation")
        static let itemID = Expression<String>("item_identifier")
        static let parentID = Expression<String>("parent_identifier")
        static let isTrashed = Expression<Bool>("is_trashed")
        static let envelope = Expression<Blob>("envelope")
        static let stateEnvelope = Expression<Blob>("state_envelope")
        static let createdAt = Expression<Double>("created_at")
        static let transactionID = Expression<String>("transaction_identifier")
        static let objectToken = Expression<String>("object_token")
        static let remoteFileID = Expression<Int64?>("remote_file_identifier")
        static let committedAt = Expression<Double>("committed_at")
    }

    private static let retainedGenerationCount: Int64 = 4
}
