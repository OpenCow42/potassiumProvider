import Foundation
@testable import PotassiumProviderCore
import Testing

struct VaultJournalTests {
    @Test func fixedTransactionIs64KiBAuthenticatedAndRandomized() throws {
        let rootKey = VaultKeyMaterial(data: Data(repeating: 0x11, count: 32))!
        let vaultID = VaultIdentifier(
            rawValue: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        )
        let transaction = VaultTransaction(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            parents: VaultFrontier(),
            deviceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            operation: .upsert(Self.item(named: "private-name.txt"))
        )
        let token = Data(0..<20).vaultBase64URLForTest()

        let first = try VaultFixedTransactionCodec.seal(
            transaction,
            objectToken: token,
            rootKey: rootKey,
            vaultID: vaultID
        )
        let second = try VaultFixedTransactionCodec.seal(
            transaction,
            objectToken: token,
            rootKey: rootKey,
            vaultID: vaultID
        )
        #expect(first.count == VaultFormat.transactionObjectSize)
        #expect(first != second)
        #expect(first.range(of: Data("private-name.txt".utf8)) == nil)
        #expect(try VaultFixedTransactionCodec.open(
            first,
            objectToken: token,
            rootKey: rootKey,
            vaultID: vaultID
        ) == transaction)

        var tampered = first
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        #expect(throws: VaultCryptoError.authenticationFailed) {
            try VaultFixedTransactionCodec.open(
                tampered,
                objectToken: token,
                rootKey: rootKey,
                vaultID: vaultID
            )
        }
    }

    @Test func concurrentContentEditsConvergeForEveryReplayOrder() throws {
        let itemID = VaultItemIdentifier(
            rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        )
        let base = Self.item(named: "report.txt", id: itemID, contentByte: 1)
        let createID = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        let firstID = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
        let secondID = UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        let create = VaultTransaction(
            id: createID,
            parents: VaultFrontier(),
            deviceID: UUID(),
            operation: .upsert(base)
        )
        let first = VaultTransaction(
            id: firstID,
            parents: VaultFrontier(transactionIDs: [createID]),
            deviceID: UUID(),
            baseItem: base,
            operation: .upsert(Self.item(named: "report.txt", id: itemID, contentByte: 2))
        )
        let second = VaultTransaction(
            id: secondID,
            parents: VaultFrontier(transactionIDs: [createID]),
            deviceID: UUID(),
            baseItem: base,
            operation: .upsert(Self.item(named: "report.txt", id: itemID, contentByte: 3))
        )

        let expected = try VaultJournalReducer.reduce([create, first, second])
        for order in [
            [second, create, first],
            [first, second, create],
            [create, second, first],
        ] {
            #expect(try VaultJournalReducer.reduce(order) == expected)
        }
        #expect(expected.items.count == 2)
        #expect(expected.items[itemID]?.contentRevision == Self.revision(byte: 2))
        #expect(expected.conflicts.contains { $0.kind == VaultConflict.Kind.content })
        let conflictCopyID = try #require(
            expected.conflicts.first { $0.kind == .content }?.conflictCopyID
        )
        let conflictCopy = try #require(expected.items[conflictCopyID])
        #expect(
            conflictCopy.metadataRevision
                == (try VaultRevisionDigests.metadata(for: conflictCopy))
        )
    }

    @Test func independentConcurrentContentAndMetadataEditsMerge() throws {
        let itemID = VaultItemIdentifier(
            rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        )
        var base = Self.item(named: "before.txt", id: itemID, contentByte: 1)
        base.metadataRevision = try VaultRevisionDigests.metadata(for: base)
        let createID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let create = VaultTransaction(
            id: createID,
            parents: VaultFrontier(),
            deviceID: UUID(),
            operation: .upsert(base)
        )

        var renamed = base
        renamed.filename = "after.txt"
        renamed.metadataRevision = try VaultRevisionDigests.metadata(for: renamed)
        let rename = VaultTransaction(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            parents: VaultFrontier(transactionIDs: [createID]),
            deviceID: UUID(),
            baseItem: base,
            operation: .upsert(renamed)
        )

        var edited = base
        edited.contentRevision = Self.revision(byte: 2)
        edited.modifiedAt = Date(timeIntervalSince1970: 2)
        edited.plaintextSize = 2
        let contentEdit = VaultTransaction(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            parents: VaultFrontier(transactionIDs: [createID]),
            deviceID: UUID(),
            baseItem: base,
            operation: .upsert(edited)
        )

        let expected = try VaultJournalReducer.reduce([create, rename, contentEdit])
        for order in [
            [contentEdit, create, rename],
            [rename, contentEdit, create],
        ] {
            #expect(try VaultJournalReducer.reduce(order) == expected)
        }
        #expect(expected.items[itemID]?.filename == "after.txt")
        #expect(expected.items[itemID]?.contentRevision == Self.revision(byte: 2))
        #expect(expected.items[itemID]?.plaintextSize == 2)
        #expect(expected.conflicts.isEmpty)
    }

    @Test func staleDeleteLosesToEditAndFolderDeleteLosesToChild() throws {
        let folder = Self.item(named: "Folder", isDirectory: true, contentByte: 1)
        let createFolder = VaultTransaction(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
            parents: VaultFrontier(),
            deviceID: UUID(),
            operation: .upsert(folder)
        )
        let child = Self.item(
            named: "child.txt",
            parentID: folder.id,
            contentByte: 2
        )
        let createChild = VaultTransaction(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000000")!,
            parents: VaultFrontier(transactionIDs: [createFolder.id]),
            deviceID: UUID(),
            operation: .upsert(child)
        )
        let purge = VaultTransaction(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!,
            parents: VaultFrontier(transactionIDs: [createFolder.id]),
            deviceID: UUID(),
            baseItem: folder,
            operation: .purge(
                itemID: folder.id,
                baseContentRevision: folder.contentRevision,
                baseMetadataRevision: folder.metadataRevision
            )
        )
        let state = try VaultJournalReducer.reduce([createFolder, createChild, purge])
        #expect(state.items[folder.id] != nil)
        #expect(state.items[child.id] != nil)
        #expect(state.conflicts.contains {
            $0.kind == VaultConflict.Kind.folderDeletionRejected
        })
    }

    @Test func concurrentDirectoryMovesCannotCreateAParentCycle() throws {
        let firstDirectory = Self.item(
            named: "First",
            id: VaultItemIdentifier(
                rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
            ),
            isDirectory: true
        )
        let secondDirectory = Self.item(
            named: "Second",
            id: VaultItemIdentifier(
                rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
            ),
            isDirectory: true
        )
        let createFirst = VaultTransaction(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            parents: VaultFrontier(),
            deviceID: UUID(),
            operation: .upsert(firstDirectory)
        )
        let createSecond = VaultTransaction(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            parents: VaultFrontier(),
            deviceID: UUID(),
            operation: .upsert(secondDirectory)
        )
        let sharedFrontier = VaultFrontier(transactionIDs: [
            createFirst.id,
            createSecond.id,
        ])
        var firstMoved = firstDirectory
        firstMoved.parentID = secondDirectory.id
        firstMoved.metadataRevision = try VaultRevisionDigests.metadata(for: firstMoved)
        var secondMoved = secondDirectory
        secondMoved.parentID = firstDirectory.id
        secondMoved.metadataRevision = try VaultRevisionDigests.metadata(for: secondMoved)
        let moveFirst = VaultTransaction(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            parents: sharedFrontier,
            deviceID: UUID(),
            baseItem: firstDirectory,
            operation: .upsert(firstMoved)
        )
        let moveSecond = VaultTransaction(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            parents: sharedFrontier,
            deviceID: UUID(),
            baseItem: secondDirectory,
            operation: .upsert(secondMoved)
        )

        let expected = try VaultJournalReducer.reduce([
            createFirst,
            createSecond,
            moveFirst,
            moveSecond,
        ])
        for replayOrder in [
            [moveSecond, createFirst, moveFirst, createSecond],
            [createSecond, moveFirst, createFirst, moveSecond],
        ] {
            #expect(try VaultJournalReducer.reduce(replayOrder) == expected)
        }
        #expect(expected.items[firstDirectory.id]?.parentID == secondDirectory.id)
        #expect(expected.items[secondDirectory.id]?.parentID == nil)
        #expect(expected.conflicts.contains {
            $0.kind == .invalidMove && $0.itemID == secondDirectory.id
        })
    }

    @Test func restoringFolderPreservesIndependentlyTrashedDescendant() throws {
        let folder = Self.item(named: "Folder", isDirectory: true)
        let child = Self.item(named: "child.txt", parentID: folder.id)
        let createFolder = VaultTransaction(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            parents: VaultFrontier(),
            deviceID: UUID(),
            operation: .upsert(folder)
        )
        let createChild = VaultTransaction(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
            parents: VaultFrontier(transactionIDs: [createFolder.id]),
            deviceID: UUID(),
            operation: .upsert(child)
        )
        let trashChild = VaultTransaction(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000010")!,
            parents: VaultFrontier(transactionIDs: [createChild.id]),
            deviceID: UUID(),
            baseItem: child,
            operation: .trash(
                itemID: child.id,
                baseContentRevision: child.contentRevision,
                baseMetadataRevision: child.metadataRevision
            )
        )
        let trashFolder = VaultTransaction(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000010")!,
            parents: VaultFrontier(transactionIDs: [trashChild.id]),
            deviceID: UUID(),
            baseItem: folder,
            operation: .trash(
                itemID: folder.id,
                baseContentRevision: folder.contentRevision,
                baseMetadataRevision: folder.metadataRevision
            )
        )
        let restoreFolder = VaultTransaction(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000010")!,
            parents: VaultFrontier(transactionIDs: [trashFolder.id]),
            deviceID: UUID(),
            operation: .restore(itemID: folder.id, parentID: nil)
        )

        let state = try VaultJournalReducer.reduce([
            restoreFolder,
            createChild,
            trashFolder,
            createFolder,
            trashChild,
        ])
        #expect(state.items[folder.id]?.isTrashed == false)
        #expect(state.items[folder.id]?.trashRootID == nil)
        #expect(state.items[child.id]?.isTrashed == true)
        #expect(state.items[child.id]?.trashRootID == child.id)
    }

    @Test func siblingConflictAllocatorSkipsExistingGeneratedName() throws {
        let winner = Self.item(
            named: "report.txt",
            id: VaultItemIdentifier(
                rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000020")!
            )
        )
        let loser = Self.item(
            named: "report.txt",
            id: VaultItemIdentifier(
                rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000020")!
            )
        )
        let reserved = Self.item(
            named: "report (conflict bbbbbbbb).txt",
            id: VaultItemIdentifier(
                rawValue: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000020")!
            )
        )
        let transactionIDs = [
            UUID(uuidString: "10000000-0000-0000-0000-000000000020")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000020")!,
            UUID(uuidString: "30000000-0000-0000-0000-000000000020")!,
        ]
        let transactions = zip(transactionIDs, [winner, loser, reserved]).map {
            transactionID, item in
            VaultTransaction(
                id: transactionID,
                parents: VaultFrontier(),
                deviceID: UUID(),
                operation: .upsert(item)
            )
        }

        let expected = try VaultJournalReducer.reduce(transactions)
        #expect(expected.items[loser.id]?.filename == "report (conflict bbbbbbbb-2).txt")
        let normalizedNames = expected.items.values.map {
            $0.filename.precomposedStringWithCanonicalMapping.lowercased()
        }
        #expect(Set(normalizedNames).count == normalizedNames.count)
        #expect(try VaultJournalReducer.reduce(Array(transactions.reversed())) == expected)
    }

    @Test func merkleProofAllowsTrustedFrontierCompactionButRejectsWrongRoot() throws {
        let transaction = VaultTransaction(
            parents: VaultFrontier(),
            deviceID: UUID(),
            operation: .upsert(Self.item(named: "file"))
        )
        let root = try VaultMerkleTree.root(for: [transaction])
        let proof = try VaultMerkleTree.proof(for: transaction.id, in: [transaction])
        let relabeledProof = VaultMerkleProof(
            transactionID: UUID(),
            leafDigest: proof.leafDigest,
            steps: proof.steps
        )
        #expect(VaultMerkleTree.verify(relabeledProof, expectedRoot: root) == false)
        let trusted = VaultTrustedState(
            vaultID: VaultIdentifier(),
            keyEpoch: 1,
            frontier: VaultFrontier(transactionIDs: [transaction.id]),
            checkpointDigest: root
        )
        let compactedState = VaultReducedState()

        try VaultRollbackValidator.validate(
            trustedState: trusted,
            currentState: compactedState,
            checkpointRoot: root,
            inclusionProofs: [proof]
        )
        #expect(throws: VaultJournalError.rollbackDetected) {
            try VaultRollbackValidator.validate(
                trustedState: trusted,
                currentState: compactedState,
                checkpointRoot: Data(repeating: 0xCC, count: 32),
                inclusionProofs: [proof]
            )
        }
    }

    private static func item(
        named filename: String,
        id: VaultItemIdentifier = VaultItemIdentifier(),
        parentID: VaultItemIdentifier? = nil,
        isDirectory: Bool = false,
        contentByte: UInt8 = 1
    ) -> VaultItem {
        VaultItem(
            id: id,
            parentID: parentID,
            filename: filename,
            isDirectory: isDirectory,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1),
            plaintextSize: isDirectory ? 0 : 1,
            contentRevision: Self.revision(byte: contentByte),
            metadataRevision: Self.revision(byte: contentByte &+ 100)
        )
    }

    private static func revision(byte: UInt8) -> VaultRevision {
        VaultRevision(data: Data(repeating: byte, count: VaultRevision.byteCount))!
    }
}

private extension Data {
    func vaultBase64URLForTest() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
