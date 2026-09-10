import Foundation
@testable import PotassiumProviderCore
import Testing

struct VaultConflictReplayTests {
    @Test(arguments: Array(UInt64(1)...32))
    func seededContentRacesPreserveEveryVersionAfterPersistentReplay(seed: UInt64) async throws {
        var random = ConflictSeedGenerator(seed: seed)
        let id = VaultItemIdentifier(rawValue: random.uuid())
        let base = item(id: id, bytes: Data("base".utf8))
        let create = VaultTransaction(id: random.uuid(), parents: VaultFrontier(), deviceID: random.uuid(),
            createdAt: Date(timeIntervalSince1970: 1), operation: .upsert(base))
        var transactions = [create]
        var contents: [VaultRevision: Data] = [:]
        for index in 0..<6 {
            let bytes = Data("seed-\(seed)-writer-\(index)".utf8)
            var changed = item(id: id, bytes: bytes)
            changed.filename = index.isMultiple(of: 2) ? "First.txt" : "Second.txt"
            changed.metadataRevision = try VaultRevisionDigests.metadata(for: changed)
            contents[changed.contentRevision] = bytes
            transactions.append(VaultTransaction(id: random.uuid(), parents: VaultFrontier(transactionIDs: [create.id]),
                deviceID: random.uuid(), createdAt: Date(timeIntervalSince1970: 2), baseItem: base, operation: .upsert(changed)))
        }
        let expected = try VaultJournalReducer.reduce(transactions)
        var permutations: [[VaultTransaction]] = [transactions, Array(transactions.reversed())]
        for _ in 0..<12 { permutations.append(transactions.shuffled(using: &random)) }
        for order in permutations {
            let observed = try VaultJournalReducer.reduce(order)
            if observed != expected {
                let minimal = try minimize(order) { try VaultJournalReducer.reduce($0) != VaultJournalReducer.reduce($0.sorted { $0.id.uuidString < $1.id.uuidString }) }
                let file = try persistFailure(seed: seed, transactions: minimal)
                Issue.record("Vault replay diverged; seed \(seed); synthetic reproducer: \(file.path)")
            }
            #expect(observed == expected)
            #expect(Set(observed.items.values.map(\.contentRevision)) == Set(contents.keys))
            #expect(observed.items.count == 6)
            #expect(observed.conflicts.filter { $0.kind == .content }.count == 5)
            for value in observed.items.values {
                let bytes = try #require(contents[value.contentRevision])
                #expect(VaultRevision(hashing: bytes) == value.contentRevision)
                #expect(value.parentID == nil && !value.isTrashed)
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = VaultKeyMaterial(data: Data(repeating: 7, count: 32))!, vaultID = VaultIdentifier(rawValue: random.uuid())
        for name in ["first", "second"] {
            let database = directory.appendingPathComponent(name + ".sqlite3")
            let store = try VaultSQLiteStore(databaseURL: database, domainIdentifier: name, vaultID: vaultID, rootKey: key)
            try await store.replace(with: expected)
            let restarted = try VaultSQLiteStore(databaseURL: database, domainIdentifier: name, vaultID: vaultID, rootKey: key)
            #expect(try await restarted.state().items == expected.items)
            // Reapplying the same complete journal does not create more copies.
            try await restarted.replace(with: VaultJournalReducer.reduce(transactions))
            #expect(try await restarted.state().items == expected.items)
        }
    }

    @Test func competingMetadataUsesCanonicalWinnerInEveryPermutation() throws {
        let base = item(id: VaultItemIdentifier(), bytes: Data("same bytes".utf8))
        let create = VaultTransaction(id: orderedID(1), parents: VaultFrontier(), deviceID: orderedID(10), operation: .upsert(base))
        var first = base, second = base
        first.filename = "First.txt"; first.metadataRevision = try VaultRevisionDigests.metadata(for: first)
        second.filename = "Second.txt"; second.metadataRevision = try VaultRevisionDigests.metadata(for: second)
        let a = VaultTransaction(id: orderedID(2), parents: VaultFrontier(transactionIDs: [create.id]), deviceID: orderedID(10), baseItem: base, operation: .upsert(first))
        let b = VaultTransaction(id: orderedID(3), parents: VaultFrontier(transactionIDs: [create.id]), deviceID: orderedID(11), baseItem: base, operation: .upsert(second))
        let expected = try VaultJournalReducer.reduce([create, a, b])
        for order in [[create, b, a], [a, create, b], [a, b, create], [b, create, a], [b, a, create]] {
            #expect(try VaultJournalReducer.reduce(order) == expected)
        }
        #expect(expected.items.count == 1)
        #expect(expected.items[base.id]?.contentRevision == base.contentRevision)
        #expect(expected.conflicts.contains { $0.kind == .metadata })
    }

    @Test func stalePurgePreservesEditedIdentity() throws {
        let base = item(id: VaultItemIdentifier(), bytes: Data("base".utf8))
        let create = VaultTransaction(id: orderedID(1), parents: VaultFrontier(), deviceID: orderedID(10), operation: .upsert(base))
        let changed = item(id: base.id, bytes: Data("new".utf8))
        let edit = VaultTransaction(id: orderedID(2), parents: VaultFrontier(transactionIDs: [create.id]), deviceID: orderedID(10), baseItem: base, operation: .upsert(changed))
        let purge = VaultTransaction(id: orderedID(3), parents: VaultFrontier(transactionIDs: [create.id]), deviceID: orderedID(11), baseItem: base,
            operation: .purge(itemID: base.id, baseContentRevision: base.contentRevision, baseMetadataRevision: base.metadataRevision))
        for order in [[create, edit, purge], [purge, edit, create], [edit, create, purge]] {
            let result = try VaultJournalReducer.reduce(order)
            #expect(result.items[base.id]?.contentRevision == changed.contentRevision)
            #expect(result.conflicts.contains { $0.kind == .deletionRejected })
        }
    }

    @Test func duplicateJournalDeliveryFailsClosedWithoutChangingPersistentState() throws {
        let base = item(id: VaultItemIdentifier(), bytes: Data("base".utf8))
        let transaction = VaultTransaction(parents: VaultFrontier(), deviceID: UUID(), operation: .upsert(base))
        #expect(throws: VaultJournalError.duplicateTransaction(transaction.id)) {
            try VaultJournalReducer.reduce([transaction, transaction])
        }
    }

    @Test func reproducerReductionRetainsRequiredCausalAncestors() throws {
        let base = item(id: VaultItemIdentifier(), bytes: Data("base".utf8))
        let create = VaultTransaction(id: orderedID(1), parents: VaultFrontier(), deviceID: orderedID(10), operation: .upsert(base))
        let leaf = VaultTransaction(id: orderedID(2), parents: VaultFrontier(transactionIDs: [create.id]), deviceID: orderedID(10), baseItem: base, operation: .upsert(base))
        let unrelated = VaultTransaction(id: orderedID(3), parents: VaultFrontier(), deviceID: orderedID(11), operation: .upsert(item(id: VaultItemIdentifier(), bytes: Data())))
        let reduced = try minimize([unrelated, leaf, create]) { input in
            _ = try VaultJournalReducer.reduce(input)
            return input.contains { $0.id == leaf.id }
        }
        #expect(Set(reduced.map(\.id)) == [create.id, leaf.id])
    }

    private func item(id: VaultItemIdentifier, bytes: Data) -> VaultItem {
        VaultItem(id: id, parentID: nil, filename: "Synthetic.txt", isDirectory: false,
            createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1),
            plaintextSize: Int64(bytes.count), contentRevision: VaultRevision(hashing: bytes), metadataRevision: VaultRevision(hashing: Data("metadata".utf8)))
    }
    private func orderedID(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }
    private func minimize(_ input: [VaultTransaction], fails: ([VaultTransaction]) throws -> Bool) throws -> [VaultTransaction] {
        var current = input, changed = true
        while changed {
            changed = false
            for transaction in current {
                guard !current.contains(where: { $0.parents.transactionIDs.contains(transaction.id) }) else { continue }
                let candidate = current.filter { $0.id != transaction.id }
                if try fails(candidate) { current = candidate; changed = true; break }
            }
        }
        return current
    }
    private func persistFailure(seed: UInt64, transactions: [VaultTransaction]) throws -> URL {
        struct Reproducer: Encodable { let schemaVersion = 1; let seed: UInt64; let transactions: [VaultTransaction] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("potassium-conflict-failures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("vault-\(seed)-\(UUID().uuidString).json")
        try JSONEncoder().encode(Reproducer(seed: seed, transactions: transactions)).write(to: file, options: .withoutOverwriting)
        return file
    }
}

private struct ConflictSeedGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func uuid() -> UUID {
        let first = next(), second = next()
        return UUID(uuidString: String(format: "%08X-%04X-%04X-%04X-%012llX", UInt32(truncatingIfNeeded: first >> 32),
            UInt16(truncatingIfNeeded: first >> 16), UInt16(truncatingIfNeeded: first), UInt16(truncatingIfNeeded: second >> 48), second & 0xFFFFFFFFFFFF))!
    }
}
