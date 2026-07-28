import CryptoKit
import Foundation

public enum VaultJournalError: Error, Equatable, LocalizedError, Sendable {
    case duplicateTransaction(UUID)
    case missingParent(transactionID: UUID, parentID: UUID)
    case cyclicGraph
    case invalidBaseRevision(VaultItemIdentifier)
    case malformedFixedTransaction
    case transactionTooLarge(Int)
    case rollbackDetected
    case invalidMerkleProof

    public var errorDescription: String? {
        switch self {
        case .duplicateTransaction:
            return "The encrypted journal contains a duplicate transaction."
        case .missingParent:
            return "The encrypted journal is missing causal ancestry."
        case .cyclicGraph:
            return "The encrypted journal contains a causal cycle."
        case .invalidBaseRevision:
            return "A mutation does not match its declared base revision."
        case .malformedFixedTransaction:
            return "The fixed-size transaction object is malformed."
        case .transactionTooLarge:
            return "The encrypted transaction exceeds the 64 KiB format limit."
        case .rollbackDetected:
            return "The remote vault state does not include this device's last trusted state."
        case .invalidMerkleProof:
            return "The checkpoint did not provide a valid transaction inclusion proof."
        }
    }
}

public struct VaultConflict: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case content
        case metadata
        case siblingName
        case deletionRejected
        case folderDeletionRejected
    }

    public let id: UUID
    public let kind: Kind
    public let itemID: VaultItemIdentifier
    public let transactionID: UUID
    public let conflictCopyID: VaultItemIdentifier?

    public init(
        kind: Kind,
        itemID: VaultItemIdentifier,
        transactionID: UUID,
        conflictCopyID: VaultItemIdentifier? = nil
    ) {
        self.id = Self.stableUUID(
            components: [
                Data(kind.rawValue.utf8),
                itemID.rawValue.data,
                transactionID.data,
            ]
        )
        self.kind = kind
        self.itemID = itemID
        self.transactionID = transactionID
        self.conflictCopyID = conflictCopyID
    }

    private static func stableUUID(components: [Data]) -> UUID {
        var hasher = SHA256()
        for component in components {
            hasher.update(data: component)
        }
        var bytes = Array(Data(hasher.finalize()).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(bytes: Data(bytes))
    }
}

public struct VaultReducedState: Equatable, Sendable {
    public let items: [VaultItemIdentifier: VaultItem]
    public let frontier: VaultFrontier
    public let appliedTransactionIDs: Set<UUID>
    public let conflicts: [VaultConflict]

    public init(
        items: [VaultItemIdentifier: VaultItem] = [:],
        frontier: VaultFrontier = VaultFrontier(),
        appliedTransactionIDs: Set<UUID> = [],
        conflicts: [VaultConflict] = []
    ) {
        self.items = items
        self.frontier = frontier
        self.appliedTransactionIDs = appliedTransactionIDs
        self.conflicts = conflicts
    }
}

/// Canonical transaction replay. Every client first topologically sorts by
/// causal ancestry and then by transaction UUID. No server timestamp is used.
public enum VaultJournalReducer {
    public static func reduce(
        _ transactions: [VaultTransaction],
        checkpoint: VaultCheckpoint? = nil
    ) throws -> VaultReducedState {
        let ordered = try canonicalOrder(
            transactions,
            knownAncestorIDs: checkpoint?.frontier.transactionIDs ?? []
        )
        var items = Dictionary(uniqueKeysWithValues: (checkpoint?.items ?? []).map { ($0.id, $0) })
        var frontier = checkpoint?.frontier ?? VaultFrontier()
        var applied = Set<UUID>()
        var conflicts: [VaultConflict] = []
        let forcedDirectoryDeletionRejections = directoryDeletionRejections(
            in: ordered
        )

        for transaction in ordered {
            frontier.replaceParents(
                transaction.parents.transactionIDs,
                with: transaction.id
            )
            applied.insert(transaction.id)
        }
        for transaction in ordered {
            try apply(
                transaction,
                forceDirectoryDeletionRejection:
                    forcedDirectoryDeletionRejections.contains(transaction.id),
                items: &items,
                conflicts: &conflicts
            )
        }

        try resolveSiblingNameCollisions(items: &items, conflicts: &conflicts)
        return VaultReducedState(
            items: items,
            frontier: frontier,
            appliedTransactionIDs: applied,
            conflicts: conflicts.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private static func directoryDeletionRejections(
        in transactions: [VaultTransaction]
    ) -> Set<UUID> {
        let byID = Dictionary(uniqueKeysWithValues: transactions.map {
            ($0.id, $0)
        })
        var rejected: Set<UUID> = []
        for deletion in transactions {
            guard let directoryID = directoryDeletionTarget(deletion) else {
                continue
            }
            let hasNewChild = transactions.contains { candidate in
                guard candidate.id != deletion.id,
                      case .upsert(let item) = candidate.operation,
                      item.parentID == directoryID,
                      item.isTrashed == false else {
                    return false
                }
                // Children already in the deletion's causal history are normal
                // subtree members. A concurrent or later child preserves the
                // folder and rejects the stale deletion.
                return isAncestor(candidate.id, of: deletion.id, byID: byID) == false
            }
            if hasNewChild {
                rejected.insert(deletion.id)
            }
        }
        return rejected
    }

    private static func directoryDeletionTarget(
        _ transaction: VaultTransaction
    ) -> VaultItemIdentifier? {
        guard transaction.baseItem?.isDirectory == true else { return nil }
        switch transaction.operation {
        case .trash(let itemID, _, _), .purge(let itemID, _, _):
            return itemID
        default:
            return nil
        }
    }

    private static func isAncestor(
        _ possibleAncestor: UUID,
        of transactionID: UUID,
        byID: [UUID: VaultTransaction]
    ) -> Bool {
        var pending = Array(byID[transactionID]?.parents.transactionIDs ?? [])
        var visited: Set<UUID> = []
        while let candidate = pending.popLast() {
            if candidate == possibleAncestor { return true }
            guard visited.insert(candidate).inserted,
                  let transaction = byID[candidate] else {
                continue
            }
            pending.append(contentsOf: transaction.parents.transactionIDs)
        }
        return false
    }

    public static func canonicalOrder(
        _ transactions: [VaultTransaction],
        knownAncestorIDs: Set<UUID> = []
    ) throws -> [VaultTransaction] {
        var byID: [UUID: VaultTransaction] = [:]
        for transaction in transactions {
            guard byID.updateValue(transaction, forKey: transaction.id) == nil else {
                throw VaultJournalError.duplicateTransaction(transaction.id)
            }
        }

        let transactionIDs = Set(byID.keys)
        for transaction in transactions {
            for parentID in transaction.parents.transactionIDs
            where transactionIDs.contains(parentID) == false && knownAncestorIDs.contains(parentID) == false {
                throw VaultJournalError.missingParent(
                    transactionID: transaction.id,
                    parentID: parentID
                )
            }
        }

        var remainingParents = Dictionary(uniqueKeysWithValues: transactions.map {
            ($0.id, $0.parents.transactionIDs.subtracting(knownAncestorIDs))
        })
        var ready = remainingParents
            .filter { $0.value.isEmpty }
            .map(\.key)
            .sorted(by: uuidLessThan)
        var ordered: [VaultTransaction] = []

        while let next = ready.first {
            ready.removeFirst()
            guard let transaction = byID[next] else { continue }
            ordered.append(transaction)
            remainingParents.removeValue(forKey: next)
            for transactionID in remainingParents.keys.sorted(by: uuidLessThan) {
                guard remainingParents[transactionID]?.remove(next) != nil,
                      remainingParents[transactionID]?.isEmpty == true else {
                    continue
                }
                ready.append(transactionID)
                ready.sort(by: uuidLessThan)
            }
        }

        guard ordered.count == transactions.count else {
            throw VaultJournalError.cyclicGraph
        }
        return ordered
    }

    private static func apply(
        _ transaction: VaultTransaction,
        forceDirectoryDeletionRejection: Bool,
        items: inout [VaultItemIdentifier: VaultItem],
        conflicts: inout [VaultConflict]
    ) throws {
        if forceDirectoryDeletionRejection,
           let itemID = directoryDeletionTarget(transaction) {
            conflicts.append(VaultConflict(
                kind: .folderDeletionRejected,
                itemID: itemID,
                transactionID: transaction.id
            ))
            return
        }
        switch transaction.operation {
        case .upsert(let desired):
            try applyUpsert(
                desired,
                base: transaction.baseItem,
                transaction: transaction,
                items: &items,
                conflicts: &conflicts
            )
        case .trash(let itemID, let baseContentRevision, let baseMetadataRevision):
            guard var current = items[itemID] else { return }
            guard current.contentRevision == baseContentRevision,
                  current.metadataRevision == baseMetadataRevision else {
                conflicts.append(VaultConflict(
                    kind: current.isDirectory ? .folderDeletionRejected : .deletionRejected,
                    itemID: itemID,
                    transactionID: transaction.id
                ))
                return
            }
            current.isTrashed = true
            current.metadataRevision = try metadataRevision(for: current)
            items[itemID] = current
            if current.isDirectory {
                try setDescendants(
                    of: itemID,
                    isTrashed: true,
                    items: &items
                )
            }
        case .restore(let itemID, let parentID):
            guard var current = items[itemID] else { return }
            current.parentID = parentID
            current.isTrashed = false
            current.metadataRevision = try metadataRevision(for: current)
            items[itemID] = current
            if current.isDirectory {
                try setDescendants(
                    of: itemID,
                    isTrashed: false,
                    items: &items
                )
            }
        case .purge(let itemID, let baseContentRevision, let baseMetadataRevision):
            guard let current = items[itemID] else { return }
            guard current.contentRevision == baseContentRevision,
                  current.metadataRevision == baseMetadataRevision else {
                conflicts.append(VaultConflict(
                    kind: current.isDirectory ? .folderDeletionRejected : .deletionRejected,
                    itemID: itemID,
                    transactionID: transaction.id
                ))
                return
            }
            if current.isDirectory,
               items.values.contains(where: { $0.parentID == itemID && $0.isTrashed == false }) {
                conflicts.append(VaultConflict(
                    kind: .folderDeletionRejected,
                    itemID: itemID,
                    transactionID: transaction.id
                ))
                return
            }
            if current.isDirectory {
                removeDescendants(of: itemID, items: &items)
            }
            items.removeValue(forKey: itemID)
        }
    }

    private static func setDescendants(
        of parentID: VaultItemIdentifier,
        isTrashed: Bool,
        items: inout [VaultItemIdentifier: VaultItem]
    ) throws {
        let childIDs = items.values
            .filter { $0.parentID == parentID }
            .map(\.id)
        for childID in childIDs {
            guard var child = items[childID] else { continue }
            child.isTrashed = isTrashed
            child.metadataRevision = try metadataRevision(for: child)
            items[childID] = child
            if child.isDirectory {
                try setDescendants(
                    of: childID,
                    isTrashed: isTrashed,
                    items: &items
                )
            }
        }
    }

    private static func removeDescendants(
        of parentID: VaultItemIdentifier,
        items: inout [VaultItemIdentifier: VaultItem]
    ) {
        let childIDs = items.values
            .filter { $0.parentID == parentID }
            .map(\.id)
        for childID in childIDs {
            removeDescendants(of: childID, items: &items)
            items.removeValue(forKey: childID)
        }
    }

    private static func applyUpsert(
        _ desired: VaultItem,
        base: VaultItem?,
        transaction: VaultTransaction,
        items: inout [VaultItemIdentifier: VaultItem],
        conflicts: inout [VaultConflict]
    ) throws {
        guard let current = items[desired.id] else {
            if base != nil {
                // Delete versus edit preserves the edit.
                conflicts.append(VaultConflict(
                    kind: .deletionRejected,
                    itemID: desired.id,
                    transactionID: transaction.id
                ))
            }
            items[desired.id] = desired
            return
        }

        guard let base else {
            // A base-less upsert is valid only for an idempotent create.
            if current == desired { return }
            throw VaultJournalError.invalidBaseRevision(desired.id)
        }

        let currentContentChanged = current.contentRevision != base.contentRevision
        let desiredContentChanged = desired.contentRevision != base.contentRevision
        let currentMetadataChanged = current.metadataRevision != base.metadataRevision
        let desiredMetadataChanged = desired.metadataRevision != base.metadataRevision

        if currentContentChanged && desiredContentChanged &&
            current.contentRevision != desired.contentRevision {
            let conflictID = stableConflictCopyID(
                originalItemID: desired.id,
                transactionID: transaction.id
            )
            var conflictCopy = desired
            conflictCopy = VaultItem(
                id: conflictID,
                parentID: desired.parentID,
                filename: conflictFilename(desired.filename, transactionID: transaction.id),
                isDirectory: desired.isDirectory,
                contentTypeIdentifier: desired.contentTypeIdentifier,
                createdAt: desired.createdAt,
                modifiedAt: desired.modifiedAt,
                plaintextSize: desired.plaintextSize,
                isFavorite: desired.isFavorite,
                isTrashed: desired.isTrashed,
                contentRevision: desired.contentRevision,
                metadataRevision: desired.metadataRevision,
                contentReference: desired.contentReference,
                versions: desired.versions
            )
            conflictCopy.metadataRevision = try metadataRevision(for: conflictCopy)
            items[conflictID] = conflictCopy
            conflicts.append(VaultConflict(
                kind: .content,
                itemID: desired.id,
                transactionID: transaction.id,
                conflictCopyID: conflictID
            ))
            return
        }

        var merged = current
        if desiredContentChanged {
            merged.contentRevision = desired.contentRevision
            merged.contentReference = desired.contentReference
            merged.plaintextSize = desired.plaintextSize
            merged.modifiedAt = desired.modifiedAt
            merged.versions = desired.versions
        }
        if desiredMetadataChanged {
            if currentMetadataChanged && metadataFields(of: current) != metadataFields(of: desired) {
                conflicts.append(VaultConflict(
                    kind: .metadata,
                    itemID: desired.id,
                    transactionID: transaction.id
                ))
            }
            // Canonical replay means the later canonical transaction wins
            // conflicting metadata fields while independent content survives.
            merged.parentID = desired.parentID
            merged.filename = desired.filename
            merged.contentTypeIdentifier = desired.contentTypeIdentifier
            merged.createdAt = desired.createdAt
            merged.isFavorite = desired.isFavorite
            merged.isTrashed = desired.isTrashed
            merged.metadataRevision = desired.metadataRevision
        }
        items[desired.id] = merged
    }

    private static func resolveSiblingNameCollisions(
        items: inout [VaultItemIdentifier: VaultItem],
        conflicts: inout [VaultConflict]
    ) throws {
        let visibleItems = items.values.filter { $0.isTrashed == false }
        let groups = Dictionary(grouping: visibleItems) {
            SiblingKey(parentID: $0.parentID, normalizedName: $0.filename.precomposedStringWithCanonicalMapping.lowercased())
        }

        for group in groups.values where group.count > 1 {
            let ordered = group.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            for item in ordered.dropFirst() {
                guard var renamed = items[item.id] else { continue }
                renamed.filename = conflictFilename(
                    renamed.filename,
                    transactionID: renamed.id.rawValue
                )
                renamed.metadataRevision = try metadataRevision(for: renamed)
                items[item.id] = renamed
                conflicts.append(VaultConflict(
                    kind: .siblingName,
                    itemID: item.id,
                    transactionID: item.id.rawValue
                ))
            }
        }
    }

    private static func metadataFields(of item: VaultItem) -> MetadataFields {
        MetadataFields(
            parentID: item.parentID,
            filename: item.filename,
            isDirectory: item.isDirectory,
            typeIdentifier: item.contentTypeIdentifier,
            createdAt: item.createdAt,
            favorite: item.isFavorite,
            trashed: item.isTrashed
        )
    }

    private static func metadataRevision(for item: VaultItem) throws -> VaultRevision {
        try VaultRevisionDigests.metadata(for: item)
    }

    private static func stableConflictCopyID(
        originalItemID: VaultItemIdentifier,
        transactionID: UUID
    ) -> VaultItemIdentifier {
        var hasher = SHA256()
        hasher.update(data: Data("vault-conflict-copy".utf8))
        hasher.update(data: originalItemID.rawValue.data)
        hasher.update(data: transactionID.data)
        var bytes = Array(Data(hasher.finalize()).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return VaultItemIdentifier(rawValue: UUID(bytes: Data(bytes)))
    }

    private static func conflictFilename(_ filename: String, transactionID: UUID) -> String {
        let suffix = String(transactionID.uuidString.prefix(8)).lowercased()
        let pathExtension = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        if pathExtension.isEmpty {
            return "\(base) (conflict \(suffix))"
        }
        return "\(base) (conflict \(suffix)).\(pathExtension)"
    }

    private static func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private struct MetadataFields: Codable, Equatable {
        let parentID: VaultItemIdentifier?
        let filename: String
        let isDirectory: Bool
        let typeIdentifier: String?
        let createdAt: Date
        let favorite: Bool
        let trashed: Bool
    }

    private struct SiblingKey: Hashable {
        let parentID: VaultItemIdentifier?
        let normalizedName: String
    }
}

public enum VaultFixedTransactionCodec {
    private static let lengthByteCount = MemoryLayout<UInt32>.size
    private static let envelopeOverhead = 4 + 2 + 1 + 4 + 16 + 20 + 12 + 16
    private static let payloadByteCount = VaultFormat.transactionObjectSize - envelopeOverhead

    public static func seal(
        _ transaction: VaultTransaction,
        objectToken: String,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws -> Data {
        let encoded = try VaultCoding.encoder.encode(transaction)
        let paddingCount = payloadByteCount - lengthByteCount - encoded.count
        guard paddingCount >= 0 else {
            throw VaultJournalError.transactionTooLarge(encoded.count)
        }
        var payload = Data()
        payload.appendUInt32(UInt32(encoded.count))
        payload.append(encoded)
        payload.append(try VaultRandom.bytes(count: paddingCount))
        let envelope = try VaultCryptography.seal(
            payload,
            role: .transaction,
            objectToken: objectToken,
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
        guard envelope.count == VaultFormat.transactionObjectSize else {
            throw VaultJournalError.malformedFixedTransaction
        }
        return envelope
    }

    public static func open(
        _ envelope: Data,
        objectToken: String,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws -> VaultTransaction {
        guard envelope.count == VaultFormat.transactionObjectSize else {
            throw VaultJournalError.malformedFixedTransaction
        }
        let payload = try VaultCryptography.open(
            envelope,
            expectedRole: .transaction,
            expectedObjectToken: objectToken,
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
        var cursor = VaultDataCursor(data: payload)
        let encodedLength = Int(try cursor.readUInt32())
        guard encodedLength > 0,
              encodedLength <= payload.count - lengthByteCount else {
            throw VaultJournalError.malformedFixedTransaction
        }
        let encoded = try cursor.read(count: encodedLength)
        do {
            return try VaultCoding.decoder.decode(VaultTransaction.self, from: encoded)
        } catch {
            throw VaultJournalError.malformedFixedTransaction
        }
    }
}

public struct VaultMerkleProof: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public let siblingDigest: Data
        public let siblingIsLeft: Bool

        public init(siblingDigest: Data, siblingIsLeft: Bool) {
            self.siblingDigest = siblingDigest
            self.siblingIsLeft = siblingIsLeft
        }
    }

    public let transactionID: UUID
    public let leafDigest: Data
    public let steps: [Step]

    public init(transactionID: UUID, leafDigest: Data, steps: [Step]) {
        self.transactionID = transactionID
        self.leafDigest = leafDigest
        self.steps = steps
    }
}

public enum VaultMerkleTree {
    public static let emptyRoot = Data(SHA256.hash(data: Data("vault-empty-merkle-tree".utf8)))

    public static func root(for transactions: [VaultTransaction]) throws -> Data {
        let ordered = try VaultJournalReducer.canonicalOrder(transactions)
        return merkleRoot(ordered.map {
            merkleLeaf(
                transactionID: $0.id,
                transactionDigest: transactionDigest($0)
            )
        })
    }

    public static func proof(
        for transactionID: UUID,
        in transactions: [VaultTransaction]
    ) throws -> VaultMerkleProof {
        let ordered = try VaultJournalReducer.canonicalOrder(transactions)
        guard var index = ordered.firstIndex(where: { $0.id == transactionID }) else {
            throw VaultJournalError.invalidMerkleProof
        }
        let transaction = ordered[index]
        let selectedTransactionDigest = transactionDigest(transaction)
        var level = ordered.map {
            merkleLeaf(
                transactionID: $0.id,
                transactionDigest: transactionDigest($0)
            )
        }
        var steps: [VaultMerkleProof.Step] = []

        while level.count > 1 {
            if level.count.isMultiple(of: 2) == false {
                level.append(level.last!)
            }
            let siblingIndex = index.isMultiple(of: 2) ? index + 1 : index - 1
            steps.append(VaultMerkleProof.Step(
                siblingDigest: level[siblingIndex],
                siblingIsLeft: siblingIndex < index
            ))
            var next: [Data] = []
            for pairStart in stride(from: 0, to: level.count, by: 2) {
                next.append(nodeDigest(left: level[pairStart], right: level[pairStart + 1]))
            }
            index /= 2
            level = next
        }

        return VaultMerkleProof(
            transactionID: transactionID,
            leafDigest: selectedTransactionDigest,
            steps: steps
        )
    }

    public static func verify(_ proof: VaultMerkleProof, expectedRoot: Data) -> Bool {
        guard expectedRoot.count == SHA256.Digest.byteCount,
              proof.leafDigest.count == SHA256.Digest.byteCount,
              proof.steps.allSatisfy({
                  $0.siblingDigest.count == SHA256.Digest.byteCount
              }) else {
            return false
        }
        var digest = merkleLeaf(
            transactionID: proof.transactionID,
            transactionDigest: proof.leafDigest
        )
        for step in proof.steps {
            digest = step.siblingIsLeft
                ? nodeDigest(left: step.siblingDigest, right: digest)
                : nodeDigest(left: digest, right: step.siblingDigest)
        }
        return digest == expectedRoot
    }

    private static func transactionDigest(_ transaction: VaultTransaction) -> Data {
        Data(SHA256.hash(data:
            (try? VaultCoding.encoder.encode(transaction)) ?? Data()
        ))
    }

    private static func merkleLeaf(
        transactionID: UUID,
        transactionDigest: Data
    ) -> Data {
        var data = Data([0])
        data.append(transactionID.data)
        data.append(transactionDigest)
        return Data(SHA256.hash(data: data))
    }

    private static func merkleRoot(_ leaves: [Data]) -> Data {
        guard leaves.isEmpty == false else { return emptyRoot }
        var level = leaves
        while level.count > 1 {
            if level.count.isMultiple(of: 2) == false {
                level.append(level.last!)
            }
            var next: [Data] = []
            for index in stride(from: 0, to: level.count, by: 2) {
                next.append(nodeDigest(left: level[index], right: level[index + 1]))
            }
            level = next
        }
        return level[0]
    }

    private static func nodeDigest(left: Data, right: Data) -> Data {
        var data = Data([1])
        data.append(left)
        data.append(right)
        return Data(SHA256.hash(data: data))
    }
}

public enum VaultRollbackValidator {
    public static func validate(
        trustedState: VaultTrustedState?,
        currentState: VaultReducedState,
        checkpointRoot: Data? = nil,
        inclusionProofs: [VaultMerkleProof] = []
    ) throws {
        guard let trustedState else {
            return
        }

        let missing = trustedState.frontier.transactionIDs
            .subtracting(currentState.appliedTransactionIDs)
        guard missing.isEmpty == false else {
            return
        }
        guard let checkpointRoot else {
            throw VaultJournalError.rollbackDetected
        }
        let proofsByID = Dictionary(uniqueKeysWithValues: inclusionProofs.map {
            ($0.transactionID, $0)
        })
        for transactionID in missing {
            guard let proof = proofsByID[transactionID],
                  VaultMerkleTree.verify(proof, expectedRoot: checkpointRoot) else {
                throw VaultJournalError.rollbackDetected
            }
        }
    }
}
