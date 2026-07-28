import CryptoKit
import Foundation

public struct VaultItemPage: Equatable, Sendable {
    public let items: [VaultItem]
    public let nextCursor: String?

    public init(items: [VaultItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum VaultChangeScope: Equatable, Sendable {
    case children(parentID: VaultItemIdentifier?)
    case trash
    case workingSet
}

public struct VaultItemChanges: Equatable, Sendable {
    public let updated: [VaultItem]
    public let deleted: [VaultItemIdentifier]
    public let frontier: VaultFrontier

    public init(
        updated: [VaultItem],
        deleted: [VaultItemIdentifier],
        frontier: VaultFrontier
    ) {
        self.updated = updated
        self.deleted = deleted
        self.frontier = frontier
    }
}

public struct VaultStagedContent: Codable, Equatable, Sendable {
    public let itemID: VaultItemIdentifier
    public let contentRevision: VaultRevision
    public let objectToken: String
    public let ciphertextURL: URL
    public let wrappedContentKey: Data
    public let noncePrefix: UInt64
    public let plaintextLength: Int64
    public let plaintextDigest: Data
    public let frameCount: UInt32

    public init(
        itemID: VaultItemIdentifier,
        contentRevision: VaultRevision,
        objectToken: String,
        ciphertextURL: URL,
        wrappedContentKey: Data,
        noncePrefix: UInt64,
        plaintextLength: Int64,
        plaintextDigest: Data,
        frameCount: UInt32
    ) {
        self.itemID = itemID
        self.contentRevision = contentRevision
        self.objectToken = objectToken
        self.ciphertextURL = ciphertextURL
        self.wrappedContentKey = wrappedContentKey
        self.noncePrefix = noncePrefix
        self.plaintextLength = plaintextLength
        self.plaintextDigest = plaintextDigest
        self.frameCount = frameCount
    }
}

public struct VaultUploadedContent: Codable, Equatable, Sendable {
    public let staged: VaultStagedContent
    public let remoteFileID: Int

    public init(staged: VaultStagedContent, remoteFileID: Int) {
        self.staged = staged
        self.remoteFileID = remoteFileID
    }

    public var contentReference: VaultContentReference {
        VaultContentReference(
            encryptionItemID: staged.itemID,
            objectToken: staged.objectToken,
            remoteFileID: remoteFileID,
            wrappedContentKey: staged.wrappedContentKey,
            noncePrefix: staged.noncePrefix,
            plaintextLength: staged.plaintextLength,
            plaintextDigest: staged.plaintextDigest,
            frameCount: staged.frameCount
        )
    }
}

public enum EncryptedVaultError: Error, Equatable, LocalizedError, Sendable {
    case missingConfiguration
    case missingKey
    case missingContent
    case itemNotFound
    case parentNotFound
    case notDirectory
    case unsupportedNativeSharing
    case staleRevision
    case syncAnchorExpired

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "The encrypted domain configuration is incomplete."
        case .missingKey:
            return "The vault key is not available on this device."
        case .missingContent:
            return "The encrypted item has no content revision."
        case .itemNotFound:
            return "The encrypted item no longer exists."
        case .parentNotFound:
            return "The encrypted destination folder no longer exists."
        case .notDirectory:
            return "The encrypted destination is not a folder."
        case .unsupportedNativeSharing:
            return "Recipient-key sharing is not supported for encrypted vaults in version 1."
        case .staleRevision:
            return "The encrypted item changed on another device."
        case .syncAnchorExpired:
            return "The encrypted sync anchor is no longer retained."
        }
    }
}

public protocol EncryptedVaultProviding: Sendable {
    func synchronize() async throws -> VaultFrontier
    func item(_ identifier: VaultItemIdentifier) async throws -> VaultItem
    func children(
        of parentID: VaultItemIdentifier?,
        trashed: Bool,
        cursor: String?,
        limit: Int
    ) async throws -> VaultItemPage
    func workingSet(limit: Int) async throws -> [VaultItem]
    func changes(
        since anchorString: String,
        scope: VaultChangeScope
    ) async throws -> VaultItemChanges
    func fetchContent(
        itemID: VaultItemIdentifier,
        expectedRevision: VaultRevision?,
        to plaintextURL: URL
    ) async throws -> VaultItem
    func createDirectory(
        parentID: VaultItemIdentifier?,
        filename: String,
        createdAt: Date
    ) async throws -> VaultItem
    func createFile(
        parentID: VaultItemIdentifier?,
        filename: String,
        contentTypeIdentifier: String?,
        plaintextURL: URL,
        modifiedAt: Date
    ) async throws -> VaultItem
    func modify(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision,
        parentID: VaultItemIdentifier?,
        filename: String,
        favorite: Bool,
        plaintextURL: URL?,
        modifiedAt: Date
    ) async throws -> VaultItem
    func trash(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision
    ) async throws
    func restore(itemID: VaultItemIdentifier, parentID: VaultItemIdentifier?) async throws -> VaultItem
    func purge(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision
    ) async throws
    func duplicate(itemID: VaultItemIdentifier) async throws -> VaultItem
    func versions(itemID: VaultItemIdentifier) async throws -> [VaultVersion]
    func restoreVersion(
        itemID: VaultItemIdentifier,
        contentRevision: VaultRevision
    ) async throws -> VaultItem
}

public actor EncryptedVaultService: EncryptedVaultProviding {
    private let configuration: ProviderDomainConfiguration
    private let vaultConfiguration: ProviderVaultConfiguration
    private let layout: VaultBootstrap.RemoteLayout
    private let rootKey: VaultKeyMaterial
    private let deviceID: UUID
    private let objectStore: any KDriveObjectStoreProviding
    private let localStore: any VaultLocalStateStoring
    private let keyStore: any VaultKeyStoring
    private let temporaryDirectoryURL: URL

    public init(
        configuration: ProviderDomainConfiguration,
        rootKey: VaultKeyMaterial,
        deviceID: UUID,
        objectStore: any KDriveObjectStoreProviding,
        localStore: any VaultLocalStateStoring,
        keyStore: any VaultKeyStoring,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) throws {
        guard configuration.encryptionMode == .opaqueVaultV1,
              let vaultConfiguration = configuration.vault,
              let layout = vaultConfiguration.remoteLayout else {
            throw EncryptedVaultError.missingConfiguration
        }
        self.configuration = configuration
        self.vaultConfiguration = vaultConfiguration
        self.layout = layout
        self.rootKey = rootKey
        self.deviceID = deviceID
        self.objectStore = objectStore
        self.localStore = localStore
        self.keyStore = keyStore
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    public func synchronize() async throws -> VaultFrontier {
        let localObjects = try await localStore.journalObjects()
        var objectsByID = Dictionary(uniqueKeysWithValues: localObjects.map {
            ($0.transactionID, $0)
        })
        var knownRemoteIDs = Set(localObjects.compactMap(\.remoteFileID))
        var observedRemoteIDs: Set<Int> = []
        var cursor: String?
        var downloaded: [VaultStoredJournalObject] = []

        repeat {
            let page = try await objectStore.listObjects(
                containerID: layout.journalContainerID,
                cursor: cursor
            )
            for object in page.objects {
                observedRemoteIDs.insert(object.id)
                guard knownRemoteIDs.contains(object.id) == false else {
                    continue
                }
                let url = temporaryURL(prefix: "journal-download")
                defer { try? FileManager.default.removeItem(at: url) }
                try await objectStore.downloadObject(fileID: object.id, to: url)
                let envelope = try Data(contentsOf: url, options: .mappedIfSafe)
                let transaction = try VaultFixedTransactionCodec.open(
                    envelope,
                    objectToken: object.token,
                    rootKey: rootKey,
                    vaultID: vaultConfiguration.vaultIdentifier,
                    keyEpoch: vaultConfiguration.keyEpoch
                )
                guard objectsByID[transaction.id] == nil else {
                    throw VaultJournalError.duplicateTransaction(transaction.id)
                }
                let stored = VaultStoredJournalObject(
                    transactionID: transaction.id,
                    objectToken: object.token,
                    remoteFileID: object.id,
                    envelope: envelope,
                    committedAt: object.serverUpdatedAt
                )
                objectsByID[transaction.id] = stored
                knownRemoteIDs.insert(object.id)
                downloaded.append(stored)
            }
            cursor = page.nextCursor
        } while cursor != nil

        // Journal compaction is intentionally disabled in v1. Therefore every
        // previously stored remote journal object must remain present in a
        // complete listing. Folding cached transactions into a listing that
        // omitted them would mask a server rollback.
        guard knownRemoteIDs.isSubset(of: observedRemoteIDs) else {
            throw VaultJournalError.rollbackDetected
        }

        let transactions = try objectsByID.values.map { stored in
            try VaultFixedTransactionCodec.open(
                stored.envelope,
                objectToken: stored.objectToken,
                rootKey: rootKey,
                vaultID: vaultConfiguration.vaultIdentifier,
                keyEpoch: vaultConfiguration.keyEpoch
            )
        }
        let state = try VaultJournalReducer.reduce(transactions)
        let trustedState = try await keyStore.loadTrustedState(
            vaultID: vaultConfiguration.vaultIdentifier
        )
        try VaultRollbackValidator.validate(
            trustedState: trustedState,
            currentState: state
        )

        let localState = try await localStore.state()
        if downloaded.isEmpty {
            if localState != state {
                try await localStore.replace(with: state)
            }
        } else {
            try await localStore.save(
                state: state,
                journalObjects: downloaded
            )
        }
        try await keyStore.saveTrustedState(VaultTrustedState(
            vaultID: vaultConfiguration.vaultIdentifier,
            keyEpoch: vaultConfiguration.keyEpoch,
            frontier: state.frontier,
            checkpointDigest: try VaultMerkleTree.root(for: transactions)
        ))
        return state.frontier
    }

    public func item(_ identifier: VaultItemIdentifier) async throws -> VaultItem {
        guard let item = try await localStore.item(identifier) else {
            throw EncryptedVaultError.itemNotFound
        }
        return item
    }

    public func children(
        of parentID: VaultItemIdentifier?,
        trashed: Bool,
        cursor: String?,
        limit: Int
    ) async throws -> VaultItemPage {
        let source: [VaultItem]
        if trashed, parentID == nil {
            source = try await localStore.allItems().filter(\.isTrashed)
        } else {
            source = try await localStore.children(of: parentID, trashed: trashed)
        }
        let all = source
            .sorted {
                let order = $0.filename.localizedStandardCompare($1.filename)
                return order == .orderedSame
                    ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                    : order == .orderedAscending
            }
        let offset = cursor.flatMap(Int.init) ?? 0
        guard offset >= 0, offset <= all.count else {
            throw VaultCryptoError.invalidLength
        }
        let pageSize = max(1, limit)
        let upper = min(all.count, offset + pageSize)
        let items = Array(all[offset..<upper])
        return VaultItemPage(
            items: items,
            nextCursor: upper < all.count ? String(upper) : nil
        )
    }

    public func workingSet(limit: Int) async throws -> [VaultItem] {
        Array(try await localStore.allItems()
            .filter { $0.isTrashed == false }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt {
                    return $0.modifiedAt > $1.modifiedAt
                }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            .prefix(max(1, limit)))
    }

    public func changes(
        since anchorString: String,
        scope: VaultChangeScope
    ) async throws -> VaultItemChanges {
        let frontier = try await synchronize()
        let before: VaultReducedState
        if let retained = try await localStore.state(anchorString: anchorString) {
            before = retained
        } else if anchorString == VaultFrontier().anchorString {
            before = VaultReducedState()
        } else {
            throw EncryptedVaultError.syncAnchorExpired
        }
        let after = try await localStore.state()
        let identifiers = Set(before.items.keys).union(after.items.keys)
        var updated: [VaultItem] = []
        var deleted: [VaultItemIdentifier] = []
        for identifier in identifiers.sorted(by: {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }) {
            let oldItem = before.items[identifier]
            let newItem = after.items[identifier]
            guard oldItem != newItem else { continue }
            let wasInScope = oldItem.map { itemIsInScope($0, scope: scope) } ?? false
            let isInScope = newItem.map { itemIsInScope($0, scope: scope) } ?? false
            guard wasInScope || isInScope else { continue }
            if let newItem {
                updated.append(newItem)
            } else {
                deleted.append(identifier)
            }
        }
        return VaultItemChanges(
            updated: updated,
            deleted: deleted,
            frontier: frontier
        )
    }

    public func fetchContent(
        itemID: VaultItemIdentifier,
        expectedRevision: VaultRevision?,
        to plaintextURL: URL
    ) async throws -> VaultItem {
        _ = try await synchronize()
        let item = try await item(itemID)
        if let expectedRevision, expectedRevision != item.contentRevision {
            throw EncryptedVaultError.staleRevision
        }
        guard let reference = item.contentReference,
              let remoteFileID = reference.remoteFileID else {
            throw EncryptedVaultError.missingContent
        }
        let ciphertextURL = temporaryURL(prefix: "content-download")
        defer { try? FileManager.default.removeItem(at: ciphertextURL) }
        try await objectStore.downloadObject(fileID: remoteFileID, to: ciphertextURL)
        try Task.checkCancellation()
        let contentKey = try VaultCryptography.unwrapContentKey(
            reference.wrappedContentKey,
            objectToken: reference.objectToken,
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier,
            keyEpoch: vaultConfiguration.keyEpoch
        )
        try VaultContentCipher.decrypt(
            ciphertextURL: ciphertextURL,
            plaintextURL: plaintextURL,
            context: VaultContentEncryptionContext(
                vaultID: vaultConfiguration.vaultIdentifier,
                itemID: reference.encryptionItemID,
                contentRevision: item.contentRevision,
                objectToken: reference.objectToken,
                keyEpoch: vaultConfiguration.keyEpoch
            ),
            contentKey: contentKey,
            expectedNoncePrefix: reference.noncePrefix,
            expectedPlaintextLength: reference.plaintextLength,
            expectedPlaintextDigest: reference.plaintextDigest,
            expectedFrameCount: reference.frameCount
        )
        try applyPlaintextFileProtection(to: plaintextURL)
        return item
    }

    public func createDirectory(
        parentID: VaultItemIdentifier?,
        filename: String,
        createdAt: Date
    ) async throws -> VaultItem {
        _ = try await synchronize()
        try await validateParent(parentID)
        let identifier = VaultItemIdentifier()
        let contentRevision = VaultRevision(
            hashing: Data("directory:\(identifier.rawValue.uuidString)".utf8)
        )
        var item = VaultItem(
            id: identifier,
            parentID: parentID,
            filename: filename,
            isDirectory: true,
            createdAt: createdAt,
            modifiedAt: createdAt,
            contentRevision: contentRevision,
            metadataRevision: contentRevision
        )
        item.metadataRevision = try metadataRevision(for: item)
        return try await commitUpsert(item, base: nil)
    }

    public func createFile(
        parentID: VaultItemIdentifier?,
        filename: String,
        contentTypeIdentifier: String?,
        plaintextURL: URL,
        modifiedAt: Date
    ) async throws -> VaultItem {
        _ = try await synchronize()
        try await validateParent(parentID)
        let identifier = VaultItemIdentifier()
        let encrypted = try await encryptAndUpload(
            plaintextURL: plaintextURL,
            itemID: identifier
        )
        var item = VaultItem(
            id: identifier,
            parentID: parentID,
            filename: filename,
            isDirectory: false,
            contentTypeIdentifier: contentTypeIdentifier,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            plaintextSize: encrypted.reference.plaintextLength,
            contentRevision: encrypted.revision,
            metadataRevision: encrypted.revision,
            contentReference: encrypted.reference
        )
        item.metadataRevision = try metadataRevision(for: item)
        return try await commitUpsert(item, base: nil)
    }

    /// Migration-only staging boundary. The returned file contains ciphertext
    /// and can be resumed without retaining a plaintext staging file.
    public func stageFileImport(
        itemID: VaultItemIdentifier = VaultItemIdentifier(),
        plaintextURL: URL
    ) async throws -> VaultStagedContent {
        let token = try VaultCryptography.makeObjectToken(
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier
        )
        let revision = try VaultRevision.random()
        let ciphertextURL = temporaryURL(prefix: "migration-content")
        let result: VaultContentEncryptionResult
        do {
            result = try VaultContentCipher.encrypt(
                plaintextURL: plaintextURL,
                ciphertextURL: ciphertextURL,
                context: VaultContentEncryptionContext(
                    vaultID: vaultConfiguration.vaultIdentifier,
                    itemID: itemID,
                    contentRevision: revision,
                    objectToken: token,
                    keyEpoch: vaultConfiguration.keyEpoch
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: ciphertextURL)
            throw error
        }
        let wrappedKey = try VaultCryptography.wrapContentKey(
            result.contentKey,
            objectToken: token,
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier,
            keyEpoch: vaultConfiguration.keyEpoch
        )
        return VaultStagedContent(
            itemID: itemID,
            contentRevision: revision,
            objectToken: token,
            ciphertextURL: ciphertextURL,
            wrappedContentKey: wrappedKey,
            noncePrefix: result.noncePrefix,
            plaintextLength: result.plaintextLength,
            plaintextDigest: result.plaintextDigest,
            frameCount: result.frameCount
        )
    }

    public func uploadStagedFileImport(
        _ staged: VaultStagedContent
    ) async throws -> VaultUploadedContent {
        let remote = try await uploadIdempotently(
            containerID: layout.contentContainerID,
            token: staged.objectToken,
            fileURL: staged.ciphertextURL
        )
        return VaultUploadedContent(staged: staged, remoteFileID: remote.id)
    }

    public func commitUploadedFileImport(
        _ uploaded: VaultUploadedContent,
        parentID: VaultItemIdentifier?,
        filename: String,
        contentTypeIdentifier: String?,
        createdAt: Date,
        modifiedAt: Date
    ) async throws -> VaultItem {
        _ = try await synchronize()
        try await validateParent(parentID)
        var item = VaultItem(
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
        item.metadataRevision = try metadataRevision(for: item)
        let committed = try await commitUpsert(item, base: nil)
        try? FileManager.default.removeItem(at: uploaded.staged.ciphertextURL)
        return committed
    }

    public func discardStagedFileImport(_ staged: VaultStagedContent) {
        try? FileManager.default.removeItem(at: staged.ciphertextURL)
    }

    public func modify(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision,
        parentID: VaultItemIdentifier?,
        filename: String,
        favorite: Bool,
        plaintextURL: URL?,
        modifiedAt: Date
    ) async throws -> VaultItem {
        _ = try await synchronize()
        try await validateParent(parentID)
        let base = try await item(itemID)
        guard base.contentRevision == baseContentRevision,
              base.metadataRevision == baseMetadataRevision else {
            throw EncryptedVaultError.staleRevision
        }
        var desired = base
        desired.parentID = parentID
        desired.filename = filename
        desired.isFavorite = favorite

        if let plaintextURL {
            if let existingReference = base.contentReference {
                desired.versions.insert(VaultVersion(
                    contentRevision: base.contentRevision,
                    contentReference: existingReference,
                    plaintextSize: base.plaintextSize,
                    modifiedAt: base.modifiedAt
                ), at: 0)
                desired.versions = retainedVersions(desired.versions)
            }
            let encrypted = try await encryptAndUpload(
                plaintextURL: plaintextURL,
                itemID: itemID
            )
            desired.contentRevision = encrypted.revision
            desired.contentReference = encrypted.reference
            desired.plaintextSize = encrypted.reference.plaintextLength
            desired.modifiedAt = modifiedAt
        }
        desired.metadataRevision = try metadataRevision(for: desired)
        return try await commitUpsert(desired, base: base)
    }

    public func trash(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision
    ) async throws {
        _ = try await synchronize()
        let current = try await item(itemID)
        guard current.contentRevision == baseContentRevision,
              current.metadataRevision == baseMetadataRevision else {
            throw EncryptedVaultError.staleRevision
        }
        _ = try await commit(
            operation: .trash(
                itemID: itemID,
                baseContentRevision: baseContentRevision,
                baseMetadataRevision: baseMetadataRevision
            ),
            base: current
        )
    }

    public func restore(
        itemID: VaultItemIdentifier,
        parentID: VaultItemIdentifier?
    ) async throws -> VaultItem {
        _ = try await synchronize()
        try await validateParent(parentID)
        let current = try await item(itemID)
        let state = try await commit(
            operation: .restore(itemID: itemID, parentID: parentID),
            base: current
        )
        guard let restored = state.items[itemID] else {
            throw EncryptedVaultError.itemNotFound
        }
        return restored
    }

    public func purge(
        itemID: VaultItemIdentifier,
        baseContentRevision: VaultRevision,
        baseMetadataRevision: VaultRevision
    ) async throws {
        _ = try await synchronize()
        let current = try await item(itemID)
        guard current.contentRevision == baseContentRevision,
              current.metadataRevision == baseMetadataRevision else {
            throw EncryptedVaultError.staleRevision
        }
        _ = try await commit(
            operation: .purge(
                itemID: itemID,
                baseContentRevision: baseContentRevision,
                baseMetadataRevision: baseMetadataRevision
            ),
            base: current
        )
    }

    public func duplicate(itemID: VaultItemIdentifier) async throws -> VaultItem {
        _ = try await synchronize()
        let source = try await item(itemID)
        let duplicateID = VaultItemIdentifier()
        var duplicate = VaultItem(
            id: duplicateID,
            parentID: source.parentID,
            filename: duplicateFilename(source.filename),
            isDirectory: source.isDirectory,
            contentTypeIdentifier: source.contentTypeIdentifier,
            createdAt: Date(),
            modifiedAt: source.modifiedAt,
            plaintextSize: source.plaintextSize,
            isFavorite: false,
            isTrashed: false,
            contentRevision: source.contentRevision,
            metadataRevision: source.metadataRevision,
            contentReference: source.contentReference,
            versions: source.versions
        )
        duplicate.metadataRevision = try metadataRevision(for: duplicate)
        return try await commitUpsert(duplicate, base: nil)
    }

    public func versions(itemID: VaultItemIdentifier) async throws -> [VaultVersion] {
        _ = try await synchronize()
        return try await item(itemID).versions
    }

    public func restoreVersion(
        itemID: VaultItemIdentifier,
        contentRevision: VaultRevision
    ) async throws -> VaultItem {
        _ = try await synchronize()
        let base = try await item(itemID)
        guard let version = base.versions.first(where: {
            $0.contentRevision == contentRevision
        }) else {
            throw EncryptedVaultError.missingContent
        }
        var desired = base
        if let currentReference = base.contentReference {
            desired.versions.insert(VaultVersion(
                contentRevision: base.contentRevision,
                contentReference: currentReference,
                plaintextSize: base.plaintextSize,
                modifiedAt: base.modifiedAt
            ), at: 0)
        }
        desired.versions.removeAll { $0.contentRevision == contentRevision }
        desired.versions = retainedVersions(desired.versions)
        desired.contentRevision = version.contentRevision
        desired.contentReference = version.contentReference
        desired.plaintextSize = version.plaintextSize
        desired.modifiedAt = Date()
        desired.metadataRevision = try metadataRevision(for: desired)
        return try await commitUpsert(desired, base: base)
    }

    private func commitUpsert(
        _ item: VaultItem,
        base: VaultItem?
    ) async throws -> VaultItem {
        let state = try await commit(operation: .upsert(item), base: base)
        guard let committed = state.items[item.id] else {
            throw EncryptedVaultError.itemNotFound
        }
        return committed
    }

    private func commit(
        operation: VaultTransaction.Operation,
        base: VaultItem?
    ) async throws -> VaultReducedState {
        let current = try await localStore.state()
        let transaction = VaultTransaction(
            parents: current.frontier,
            deviceID: deviceID,
            baseItem: base,
            operation: operation
        )
        let token = try VaultCryptography.makeObjectToken(
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier
        )
        let envelope = try VaultFixedTransactionCodec.seal(
            transaction,
            objectToken: token,
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier,
            keyEpoch: vaultConfiguration.keyEpoch
        )
        let transactionURL = temporaryURL(prefix: "transaction")
        defer { try? FileManager.default.removeItem(at: transactionURL) }
        try envelope.write(to: transactionURL, options: [.atomic])

        // Publishing this immutable object is the sole atomic visibility point.
        let remote = try await uploadIdempotently(
            containerID: layout.journalContainerID,
            token: token,
            fileURL: transactionURL
        )
        let checkpoint = VaultCheckpoint(
            frontier: current.frontier,
            items: Array(current.items.values),
            transactionMerkleRoot: Data()
        )
        let reduced = try VaultJournalReducer.reduce(
            [transaction],
            checkpoint: checkpoint
        )
        let combined = VaultReducedState(
            items: reduced.items,
            frontier: reduced.frontier,
            appliedTransactionIDs: current.appliedTransactionIDs.union([transaction.id]),
            conflicts: current.conflicts + reduced.conflicts
        )
        try await localStore.save(
            state: combined,
            journalObjects: [VaultStoredJournalObject(
                transactionID: transaction.id,
                objectToken: token,
                remoteFileID: remote.id,
                envelope: envelope,
                committedAt: remote.serverUpdatedAt
            )]
        )
        try await keyStore.saveTrustedState(VaultTrustedState(
            vaultID: vaultConfiguration.vaultIdentifier,
            keyEpoch: vaultConfiguration.keyEpoch,
            frontier: combined.frontier,
            checkpointDigest: nil
        ))
        return combined
    }

    private func encryptAndUpload(
        plaintextURL: URL,
        itemID: VaultItemIdentifier
    ) async throws -> (revision: VaultRevision, reference: VaultContentReference) {
        let token = try VaultCryptography.makeObjectToken(
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier
        )
        let provisionalRevision = try VaultRevision.random()
        let context = VaultContentEncryptionContext(
            vaultID: vaultConfiguration.vaultIdentifier,
            itemID: itemID,
            contentRevision: provisionalRevision,
            objectToken: token,
            keyEpoch: vaultConfiguration.keyEpoch
        )
        let ciphertextURL = temporaryURL(prefix: "content")
        defer { try? FileManager.default.removeItem(at: ciphertextURL) }
        let result = try VaultContentCipher.encrypt(
            plaintextURL: plaintextURL,
            ciphertextURL: ciphertextURL,
            context: context
        )
        let remote = try await uploadIdempotently(
            containerID: layout.contentContainerID,
            token: token,
            fileURL: ciphertextURL
        )
        let wrappedKey = try VaultCryptography.wrapContentKey(
            result.contentKey,
            objectToken: token,
            rootKey: rootKey,
            vaultID: vaultConfiguration.vaultIdentifier,
            keyEpoch: vaultConfiguration.keyEpoch
        )
        return (
            provisionalRevision,
            VaultContentReference(
                encryptionItemID: itemID,
                objectToken: token,
                remoteFileID: remote.id,
                wrappedContentKey: wrappedKey,
                noncePrefix: result.noncePrefix,
                plaintextLength: result.plaintextLength,
                plaintextDigest: result.plaintextDigest,
                frameCount: result.frameCount
            )
        )
    }

    private func uploadIdempotently(
        containerID: Int,
        token: String,
        fileURL: URL
    ) async throws -> KDriveOpaqueObject {
        do {
            return try await objectStore.uploadObject(
                containerID: containerID,
                token: token,
                fileURL: fileURL
            )
        } catch KDriveObjectStoreError.responseRejected(let statusCode, _)
            where statusCode == 409 {
            var cursor: String?
            repeat {
                let page = try await objectStore.listObjects(
                    containerID: containerID,
                    cursor: cursor
                )
                if let existing = page.objects.first(where: { $0.token == token }) {
                    return existing
                }
                cursor = page.nextCursor
            } while cursor != nil
            throw KDriveObjectStoreError.responseRejected(
                statusCode: statusCode,
                body: "An idempotent upload conflicted without a matching opaque token."
            )
        }
    }

    private func validateParent(_ parentID: VaultItemIdentifier?) async throws {
        guard let parentID else { return }
        guard let parent = try await localStore.item(parentID) else {
            throw EncryptedVaultError.parentNotFound
        }
        guard parent.isDirectory, parent.isTrashed == false else {
            throw EncryptedVaultError.notDirectory
        }
    }

    private func metadataRevision(for item: VaultItem) throws -> VaultRevision {
        try VaultRevisionDigests.metadata(for: item)
    }

    private func retainedVersions(_ versions: [VaultVersion]) -> [VaultVersion] {
        let newestFirst = versions.sorted { $0.modifiedAt > $1.modifiedAt }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        var retained = Array(newestFirst.prefix(10))
        let retainedIDs = Set(retained.map(\.contentRevision))
        retained.append(contentsOf: newestFirst.filter {
            $0.modifiedAt >= cutoff && retainedIDs.contains($0.contentRevision) == false
        })
        return retained
    }

    private func duplicateFilename(_ filename: String) -> String {
        let pathExtension = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        if pathExtension.isEmpty {
            return "\(base) copy"
        }
        return "\(base) copy.\(pathExtension)"
    }

    private func temporaryURL(prefix: String) -> URL {
        temporaryDirectoryURL
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension("bin")
    }

    private func applyPlaintextFileProtection(to url: URL) throws {
        #if canImport(Darwin)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func itemIsInScope(
        _ item: VaultItem,
        scope: VaultChangeScope
    ) -> Bool {
        switch scope {
        case .children(let parentID):
            return item.parentID == parentID && item.isTrashed == false
        case .trash:
            return item.isTrashed
        case .workingSet:
            return item.isTrashed == false
        }
    }

}
