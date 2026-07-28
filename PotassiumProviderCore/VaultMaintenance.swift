import Foundation

public struct VaultGarbageCollectionReport: Equatable, Sendable {
    public let checkpointFileID: Int
    public let examinedObjectCount: Int
    public let deletedObjectCount: Int

    public init(
        checkpointFileID: Int,
        examinedObjectCount: Int,
        deletedObjectCount: Int
    ) {
        self.checkpointFileID = checkpointFileID
        self.examinedObjectCount = examinedObjectCount
        self.deletedObjectCount = deletedObjectCount
    }
}

/// Conservative maintenance: an authenticated checkpoint is uploaded and
/// downloaded again before any unreferenced ciphertext can be deleted.
/// Journal objects remain immutable in v1 until Merkle-node proof retrieval has
/// passed independent review; this intentionally prefers quota use over an
/// unsafe compaction.
public actor VaultMaintenanceService {
    private let vaultConfiguration: ProviderVaultConfiguration
    private let rootKey: VaultKeyMaterial
    private let objectStore: any KDriveObjectStoreProviding
    private let localStore: any VaultLocalStateStoring
    private let vault: any EncryptedVaultProviding
    private let temporaryDirectoryURL: URL

    public init(
        vaultConfiguration: ProviderVaultConfiguration,
        rootKey: VaultKeyMaterial,
        objectStore: any KDriveObjectStoreProviding,
        localStore: any VaultLocalStateStoring,
        vault: any EncryptedVaultProviding,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) throws {
        guard vaultConfiguration.remoteLayout != nil else {
            throw EncryptedVaultError.missingConfiguration
        }
        self.vaultConfiguration = vaultConfiguration
        self.rootKey = rootKey
        self.objectStore = objectStore
        self.localStore = localStore
        self.vault = vault
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    public func checkpointAndCollectUnreferencedContent(
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        now: Date = Date()
    ) async throws -> VaultGarbageCollectionReport {
        guard let layout = vaultConfiguration.remoteLayout else {
            throw EncryptedVaultError.missingConfiguration
        }
        let synchronizedFrontier = try await vault.synchronize()
        let state = try await localStore.state()
        guard state.frontier == synchronizedFrontier else {
            throw VaultJournalError.rollbackDetected
        }
        let storedTransactions = try await localStore.journalObjects()
        let transactions = try storedTransactions.map {
            try VaultFixedTransactionCodec.open(
                $0.envelope,
                objectToken: $0.objectToken,
                rootKey: rootKey,
                vaultID: vaultConfiguration.vaultIdentifier,
                keyEpoch: vaultConfiguration.keyEpoch
            )
        }
        let checkpoint = VaultCheckpoint(
            frontier: state.frontier,
            items: Array(state.items.values),
            transactionMerkleRoot: try VaultMerkleTree.root(for: transactions),
            createdAt: now
        )
        let checkpointToken = try VaultCryptography.makeObjectToken(
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier
        )
        let envelope = try VaultCryptography.seal(
            checkpoint,
            role: .checkpoint,
            objectToken: checkpointToken,
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier,
            keyEpoch: vaultConfiguration.keyEpoch
        )
        let uploadURL = temporaryURL(prefix: "maintenance-checkpoint")
        let verificationURL = temporaryURL(prefix: "maintenance-verification")
        defer {
            try? FileManager.default.removeItem(at: uploadURL)
            try? FileManager.default.removeItem(at: verificationURL)
        }
        try envelope.write(to: uploadURL, options: [.atomic])
        let remoteCheckpoint = try await objectStore.uploadObject(
            containerID: layout.checkpointContainerID,
            token: checkpointToken,
            fileURL: uploadURL
        )
        try await objectStore.downloadObject(
            fileID: remoteCheckpoint.id,
            to: verificationURL
        )
        let verified = try VaultCryptography.open(
            VaultCheckpoint.self,
            envelope: Data(contentsOf: verificationURL, options: .mappedIfSafe),
            expectedRole: .checkpoint,
            expectedObjectToken: checkpointToken,
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier,
            keyEpoch: vaultConfiguration.keyEpoch
        )
        guard verified == checkpoint else {
            throw VaultCryptoError.authenticationFailed
        }

        let referencedTokens = Self.referencedContentTokens(in: verified.items)
        let cutoff = now.addingTimeInterval(-max(0, retentionInterval))
        var candidatesByToken = Dictionary(uniqueKeysWithValues:
            try await localStore.garbageCollectionCandidates().map {
                ($0.objectToken, $0)
            }
        )
        var observedTokens: Set<String> = []
        var cursor: String?
        var examined = 0
        var deleted = 0
        repeat {
            let page = try await objectStore.listObjects(
                containerID: layout.contentContainerID,
                cursor: cursor
            )
            for object in page.objects where object.isContainer == false {
                examined += 1
                observedTokens.insert(object.token)
                guard referencedTokens.contains(object.token) == false else {
                    candidatesByToken[object.token] = nil
                    continue
                }
                if let candidate = candidatesByToken[object.token],
                   candidate.remoteFileID == object.id {
                    if candidate.firstObservedAt <= cutoff,
                       candidate.observedFrontier.transactionIDs.isSubset(
                           of: state.appliedTransactionIDs
                       ) {
                        try await objectStore.deleteObject(fileID: object.id)
                        candidatesByToken[object.token] = nil
                        deleted += 1
                    }
                } else {
                    candidatesByToken[object.token] = VaultGarbageCollectionCandidate(
                        objectToken: object.token,
                        remoteFileID: object.id,
                        firstObservedAt: now,
                        observedFrontier: state.frontier
                    )
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        candidatesByToken = candidatesByToken.filter {
            observedTokens.contains($0.key) &&
                referencedTokens.contains($0.key) == false
        }
        try await localStore.replaceGarbageCollectionCandidates(
            Array(candidatesByToken.values)
        )

        return VaultGarbageCollectionReport(
            checkpointFileID: remoteCheckpoint.id,
            examinedObjectCount: examined,
            deletedObjectCount: deleted
        )
    }

    private static func referencedContentTokens(in items: [VaultItem]) -> Set<String> {
        var tokens: Set<String> = []
        for item in items {
            if let token = item.contentReference?.objectToken {
                tokens.insert(token)
            }
            tokens.formUnion(item.versions.map(\.contentReference.objectToken))
        }
        return tokens
    }

    private func temporaryURL(prefix: String) -> URL {
        temporaryDirectoryURL.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: false
        )
    }
}
