import Foundation

public struct PendingVaultProvisioning: Sendable {
    public let driveID: Int
    public let vaultID: VaultIdentifier
    public let rootKey: VaultKeyMaterial
    public let recoveryKit: VaultRecoveryKit
    public let vaultConfiguration: ProviderVaultConfiguration

    public init(
        driveID: Int,
        vaultID: VaultIdentifier,
        rootKey: VaultKeyMaterial,
        recoveryKit: VaultRecoveryKit,
        vaultConfiguration: ProviderVaultConfiguration
    ) {
        self.driveID = driveID
        self.vaultID = vaultID
        self.rootKey = rootKey
        self.recoveryKit = recoveryKit
        self.vaultConfiguration = vaultConfiguration
    }
}

public struct PendingVaultRecoveryRewrap: Sendable {
    public let recoveryKit: VaultRecoveryKit
    public let vaultConfiguration: ProviderVaultConfiguration

    public init(
        recoveryKit: VaultRecoveryKit,
        vaultConfiguration: ProviderVaultConfiguration
    ) {
        self.recoveryKit = recoveryKit
        self.vaultConfiguration = vaultConfiguration
    }
}

public enum VaultProvisioningError: Error, Equatable, LocalizedError, Sendable {
    case recoveryConfirmationMismatch
    case missingRemoteLayout
    case checkpointNotFound
    case driveMismatch
    case cloudRecordMismatch
    case keyEpochMismatch

    public var errorDescription: String? {
        switch self {
        case .recoveryConfirmationMismatch:
            return "The recovery-kit confirmation does not match the generated kit."
        case .missingRemoteLayout:
            return "The vault bootstrap does not contain a supported remote layout."
        case .checkpointNotFound:
            return "The authenticated vault checkpoint could not be found."
        case .driveMismatch:
            return "The recovery kit belongs to a different kDrive."
        case .cloudRecordMismatch:
            return "The iCloud Keychain record does not match the remote vault."
        case .keyEpochMismatch:
            return "The iCloud Keychain record belongs to a different vault key epoch."
        }
    }
}

public struct VaultProvisioningService: Sendable {
    private let objectStore: any KDriveObjectStoreProviding
    private let keyStore: any VaultKeyStoring
    private let temporaryDirectoryURL: URL

    public init(
        objectStore: any KDriveObjectStoreProviding,
        keyStore: any VaultKeyStoring,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.objectStore = objectStore
        self.keyStore = keyStore
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    /// Creates only randomized physical containers and authenticated encrypted
    /// bootstrap/checkpoint objects. The caller must show `recoveryKit` and call
    /// `confirm` before saving or registering a File Provider domain.
    public func prepareNewVault(
        driveID: Int,
        remoteParentID: Int = ProviderConstants.defaultRootFileID
    ) async throws -> PendingVaultProvisioning {
        let vaultID = VaultIdentifier()
        let rootKey = try VaultCryptography.makeRootKey()
        let recoverySecret = try VaultKeyMaterial.random()
        let rootToken = try VaultCryptography.makeObjectToken(
            rootKey: rootKey,
            vaultID: vaultID
        )
        let rootObject = try await objectStore.createContainer(
            parentID: remoteParentID,
            token: rootToken
        )

        do {
            let contentContainer = try await objectStore.createContainer(
                parentID: rootObject.id,
                token: VaultCryptography.makeObjectToken(rootKey: rootKey, vaultID: vaultID)
            )
            let journalContainer = try await objectStore.createContainer(
                parentID: rootObject.id,
                token: VaultCryptography.makeObjectToken(rootKey: rootKey, vaultID: vaultID)
            )
            let checkpointContainer = try await objectStore.createContainer(
                parentID: rootObject.id,
                token: VaultCryptography.makeObjectToken(rootKey: rootKey, vaultID: vaultID)
            )
            let checkpointToken = try VaultCryptography.makeObjectToken(
                rootKey: rootKey,
                vaultID: vaultID
            )
            let layout = VaultBootstrap.RemoteLayout(
                contentContainerID: contentContainer.id,
                journalContainerID: journalContainer.id,
                checkpointContainerID: checkpointContainer.id,
                checkpointToken: checkpointToken
            )

            let checkpoint = VaultCheckpoint(
                frontier: VaultFrontier(),
                items: [],
                transactionMerkleRoot: VaultMerkleTree.emptyRoot
            )
            let checkpointEnvelope = try VaultPaddedCheckpointCodec.seal(
                checkpoint,
                objectToken: checkpointToken,
                rootKey: rootKey,
                vaultID: vaultID
            )
            let checkpointURL = temporaryURL(prefix: "checkpoint")
            defer { try? FileManager.default.removeItem(at: checkpointURL) }
            try checkpointEnvelope.write(to: checkpointURL, options: [.atomic])
            _ = try await objectStore.uploadObject(
                containerID: checkpointContainer.id,
                token: checkpointToken,
                fileURL: checkpointURL
            )

            let bootstrapToken = try VaultCryptography.makeObjectToken(
                rootKey: rootKey,
                vaultID: vaultID
            )
            let bootstrap = try VaultBootstrap.create(
                vaultID: vaultID,
                rootKey: rootKey,
                recoverySecret: recoverySecret,
                remoteLayout: layout
            )
            let bootstrapURL = temporaryURL(prefix: "bootstrap")
            defer { try? FileManager.default.removeItem(at: bootstrapURL) }
            try bootstrap.write(to: bootstrapURL, options: [.atomic])
            let header = try await objectStore.uploadObject(
                containerID: rootObject.id,
                token: bootstrapToken,
                fileURL: bootstrapURL
            )

            let recoveryKit = VaultRecoveryKit(
                vaultID: vaultID,
                driveID: driveID,
                vaultRootFileID: rootObject.id,
                vaultHeaderFileID: header.id,
                recoverySecret: recoverySecret
            )
            return PendingVaultProvisioning(
                driveID: driveID,
                vaultID: vaultID,
                rootKey: rootKey,
                recoveryKit: recoveryKit,
                vaultConfiguration: ProviderVaultConfiguration(
                    vaultIdentifier: vaultID,
                    vaultRootFileID: rootObject.id,
                    vaultHeaderFileID: header.id,
                    remoteLayout: layout
                )
            )
        } catch {
            try? await objectStore.deleteObject(fileID: rootObject.id)
            throw error
        }
    }

    public func confirm(
        _ pending: PendingVaultProvisioning,
        recoveryKitConfirmation: String
    ) async throws -> ProviderVaultConfiguration {
        let confirmedKit: VaultRecoveryKit
        do {
            confirmedKit = try VaultRecoveryKit(encoded: recoveryKitConfirmation)
        } catch {
            throw VaultProvisioningError.recoveryConfirmationMismatch
        }
        guard confirmedKit == pending.recoveryKit else {
            throw VaultProvisioningError.recoveryConfirmationMismatch
        }
        try await keyStore.saveRootKey(pending.rootKey, vaultID: pending.vaultID)
        try await keyStore.saveTrustedState(VaultTrustedState(
            vaultID: pending.vaultID,
            keyEpoch: pending.vaultConfiguration.keyEpoch,
            frontier: VaultFrontier(),
            checkpointDigest: VaultMerkleTree.emptyRoot
        ))
        return pending.vaultConfiguration
    }

    public func cancel(_ pending: PendingVaultProvisioning) async {
        // This root was created by this unfinished provisioning session and has
        // never been registered as a domain, so removing it cannot delete user
        // plaintext or an established vault.
        try? await objectStore.deleteObject(
            fileID: pending.vaultConfiguration.vaultRootFileID
        )
    }

    public func openExistingVault(
        recoveryKitText: String,
        expectedDriveID: Int
    ) async throws -> ProviderVaultConfiguration {
        let kit = try VaultRecoveryKit(encoded: recoveryKitText)
        guard kit.driveID == expectedDriveID else {
            throw VaultProvisioningError.driveMismatch
        }
        let bootstrapURL = temporaryURL(prefix: "bootstrap-download")
        defer { try? FileManager.default.removeItem(at: bootstrapURL) }
        try await objectStore.downloadObject(
            fileID: kit.vaultHeaderFileID,
            to: bootstrapURL
        )
        let unlocked = try VaultBootstrap.unlock(
            Data(contentsOf: bootstrapURL, options: .mappedIfSafe),
            recoverySecret: kit.recoverySecret,
            expectedVaultID: kit.vaultID
        )
        guard let layout = unlocked.remoteLayout else {
            throw VaultProvisioningError.missingRemoteLayout
        }
        let checkpointObject = try await findObject(
            token: layout.checkpointToken,
            containerID: layout.checkpointContainerID
        )
        let checkpointURL = temporaryURL(prefix: "checkpoint-download")
        defer { try? FileManager.default.removeItem(at: checkpointURL) }
        try await objectStore.downloadObject(
            fileID: checkpointObject.id,
            to: checkpointURL
        )
        let checkpoint = try VaultPaddedCheckpointCodec.open(
            Data(contentsOf: checkpointURL, options: .mappedIfSafe),
            objectToken: layout.checkpointToken,
            rootKey: unlocked.rootKey,
            vaultID: unlocked.vaultID,
            keyEpoch: unlocked.keyEpoch
        )

        try await keyStore.saveRootKey(unlocked.rootKey, vaultID: unlocked.vaultID)
        try await keyStore.saveTrustedState(VaultTrustedState(
            vaultID: unlocked.vaultID,
            keyEpoch: unlocked.keyEpoch,
            frontier: checkpoint.frontier,
            checkpointDigest: checkpoint.transactionMerkleRoot
        ))
        return ProviderVaultConfiguration(
            vaultIdentifier: unlocked.vaultID,
            vaultRootFileID: kit.vaultRootFileID,
            vaultHeaderFileID: kit.vaultHeaderFileID,
            formatVersion: VaultFormat.currentVersion,
            keyEpoch: unlocked.keyEpoch,
            remoteLayout: layout
        )
    }

    /// Proves that a recovery kit opens the selected vault without copying its
    /// root key into device custody. Recovery material is used only in memory
    /// and is never sent to the object store.
    public func verifyRecoveryKit(
        _ recoveryKitText: String,
        expectedConfiguration: ProviderVaultConfiguration,
        expectedDriveID: Int
    ) async throws {
        let kit = try VaultRecoveryKit(encoded: recoveryKitText)
        guard kit.driveID == expectedDriveID else {
            throw VaultProvisioningError.driveMismatch
        }
        guard kit.vaultID == expectedConfiguration.vaultIdentifier,
              kit.vaultRootFileID == expectedConfiguration.vaultRootFileID,
              kit.vaultHeaderFileID == expectedConfiguration.vaultHeaderFileID
        else {
            throw VaultProvisioningError.recoveryConfirmationMismatch
        }

        let bootstrapURL = temporaryURL(prefix: "recovery-verification")
        defer { try? FileManager.default.removeItem(at: bootstrapURL) }
        try await objectStore.downloadObject(
            fileID: kit.vaultHeaderFileID,
            to: bootstrapURL
        )
        let unlocked = try VaultBootstrap.unlock(
            Data(contentsOf: bootstrapURL, options: .mappedIfSafe),
            recoverySecret: kit.recoverySecret,
            expectedVaultID: kit.vaultID
        )
        guard unlocked.keyEpoch == expectedConfiguration.keyEpoch,
              unlocked.remoteLayout == expectedConfiguration.remoteLayout,
              let layout = unlocked.remoteLayout else {
            throw VaultProvisioningError.cloudRecordMismatch
        }

        let checkpointObject = try await findObject(
            token: layout.checkpointToken,
            containerID: layout.checkpointContainerID
        )
        let checkpointURL = temporaryURL(prefix: "recovery-checkpoint")
        defer { try? FileManager.default.removeItem(at: checkpointURL) }
        try await objectStore.downloadObject(
            fileID: checkpointObject.id,
            to: checkpointURL
        )
        _ = try VaultPaddedCheckpointCodec.open(
            Data(contentsOf: checkpointURL, options: .mappedIfSafe),
            objectToken: layout.checkpointToken,
            rootKey: unlocked.rootKey,
            vaultID: unlocked.vaultID,
            keyEpoch: unlocked.keyEpoch
        )

        if let deviceKey = try await keyStore.loadRootKey(
            vaultID: unlocked.vaultID
        ), deviceKey != unlocked.rootKey {
            throw VaultCloudAccessStoreError.conflictingRecord
        }
    }

    /// Authenticates a synchronizable convenience record against the remote
    /// bootstrap header, checkpoint, complete journal, and any returning-device
    /// trusted frontier before copying its root key into device-local custody.
    public func openExistingVault(
        cloudAccessRecord record: VaultCloudAccessRecord,
        expectedDriveID: Int
    ) async throws -> ProviderVaultConfiguration {
        guard record.driveID == expectedDriveID else {
            throw VaultProvisioningError.driveMismatch
        }
        guard record.formatVersion == VaultFormat.currentVersion else {
            throw VaultProvisioningError.cloudRecordMismatch
        }

        let bootstrapURL = temporaryURL(prefix: "cloud-bootstrap-download")
        defer { try? FileManager.default.removeItem(at: bootstrapURL) }
        try await objectStore.downloadObject(
            fileID: record.vaultHeaderFileID,
            to: bootstrapURL
        )
        let header = try VaultBootstrap.inspectHeader(
            Data(contentsOf: bootstrapURL, options: .mappedIfSafe)
        )
        guard header.vaultID == record.vaultID,
              header.formatVersion == record.formatVersion else {
            throw VaultProvisioningError.cloudRecordMismatch
        }
        guard header.keyEpoch == record.keyEpoch else {
            throw VaultProvisioningError.keyEpochMismatch
        }

        let checkpointObject = try await findObject(
            token: record.remoteLayout.checkpointToken,
            containerID: record.remoteLayout.checkpointContainerID
        )
        let checkpointURL = temporaryURL(prefix: "cloud-checkpoint-download")
        defer { try? FileManager.default.removeItem(at: checkpointURL) }
        try await objectStore.downloadObject(
            fileID: checkpointObject.id,
            to: checkpointURL
        )
        let checkpoint = try VaultPaddedCheckpointCodec.open(
            Data(contentsOf: checkpointURL, options: .mappedIfSafe),
            objectToken: record.remoteLayout.checkpointToken,
            rootKey: record.rootKey,
            vaultID: record.vaultID,
            keyEpoch: record.keyEpoch
        )
        let transactions = try await loadJournalTransactions(record: record)
        let state = try VaultJournalReducer.reduce(
            transactions,
            checkpoint: checkpoint
        )

        let trustedState = try await keyStore.loadTrustedState(
            vaultID: record.vaultID
        )
        if let trustedState, trustedState.keyEpoch != record.keyEpoch {
            throw VaultProvisioningError.keyEpochMismatch
        }
        try VaultRollbackValidator.validate(
            trustedState: trustedState,
            currentState: state
        )
        if let existingKey = try await keyStore.loadRootKey(vaultID: record.vaultID),
           existingKey != record.rootKey {
            throw VaultCloudAccessStoreError.conflictingRecord
        }

        try await keyStore.saveTrustedState(VaultTrustedState(
            vaultID: record.vaultID,
            keyEpoch: record.keyEpoch,
            frontier: state.frontier,
            checkpointDigest: try VaultMerkleTree.root(for: transactions)
        ))
        try await keyStore.saveRootKey(record.rootKey, vaultID: record.vaultID)
        return record.vaultConfiguration
    }

    /// Rewraps the existing root key under a fresh recovery secret. This does
    /// not revoke an old recovery kit while an older bootstrap object or server
    /// backup remains reachable; device revocation requires full rekeying.
    public func prepareRecoveryRewrap(
        configuration: ProviderVaultConfiguration,
        driveID: Int,
        currentRecoveryKitText: String
    ) async throws -> PendingVaultRecoveryRewrap {
        let currentKit = try VaultRecoveryKit(encoded: currentRecoveryKitText)
        guard currentKit.vaultID == configuration.vaultIdentifier,
              currentKit.driveID == driveID else {
            throw VaultProvisioningError.recoveryConfirmationMismatch
        }
        let bootstrapURL = temporaryURL(prefix: "recovery-rewrap-bootstrap-download")
        defer { try? FileManager.default.removeItem(at: bootstrapURL) }
        try await objectStore.downloadObject(
            fileID: currentKit.vaultHeaderFileID,
            to: bootstrapURL
        )
        let unlocked = try VaultBootstrap.unlock(
            Data(contentsOf: bootstrapURL, options: .mappedIfSafe),
            recoverySecret: currentKit.recoverySecret,
            expectedVaultID: configuration.vaultIdentifier
        )
        guard let layout = unlocked.remoteLayout else {
            throw VaultProvisioningError.missingRemoteLayout
        }

        let newRecoverySecret = try VaultKeyMaterial.random()
        let newHeaderToken = try VaultCryptography.makeObjectToken(
            rootKey: unlocked.rootKey,
            vaultID: configuration.vaultIdentifier
        )
        let newBootstrap = try VaultBootstrap.create(
            vaultID: configuration.vaultIdentifier,
            keyEpoch: configuration.keyEpoch,
            rootKey: unlocked.rootKey,
            recoverySecret: newRecoverySecret,
            remoteLayout: layout
        )
        let uploadURL = temporaryURL(prefix: "recovery-rewrap-bootstrap")
        defer { try? FileManager.default.removeItem(at: uploadURL) }
        try newBootstrap.write(to: uploadURL, options: [.atomic])
        let header = try await objectStore.uploadObject(
            containerID: configuration.vaultRootFileID,
            token: newHeaderToken,
            fileURL: uploadURL
        )
        var rotatedConfiguration = configuration
        rotatedConfiguration.vaultHeaderFileID = header.id
        return PendingVaultRecoveryRewrap(
            recoveryKit: VaultRecoveryKit(
                vaultID: configuration.vaultIdentifier,
                driveID: driveID,
                vaultRootFileID: configuration.vaultRootFileID,
                vaultHeaderFileID: header.id,
                recoverySecret: newRecoverySecret
            ),
            vaultConfiguration: rotatedConfiguration
        )
    }

    public func confirmRecoveryRewrap(
        _ pending: PendingVaultRecoveryRewrap,
        recoveryKitConfirmation: String
    ) throws -> ProviderVaultConfiguration {
        guard let confirmation = try? VaultRecoveryKit(
            encoded: recoveryKitConfirmation
        ), confirmation == pending.recoveryKit else {
            throw VaultProvisioningError.recoveryConfirmationMismatch
        }
        return pending.vaultConfiguration
    }

    private func findObject(
        token: String,
        containerID: Int
    ) async throws -> KDriveOpaqueObject {
        var cursor: String?
        repeat {
            let page = try await objectStore.listObjects(
                containerID: containerID,
                cursor: cursor
            )
            if let object = page.objects.first(where: { $0.token == token }) {
                return object
            }
            cursor = page.nextCursor
        } while cursor != nil
        throw VaultProvisioningError.checkpointNotFound
    }

    private func loadJournalTransactions(
        record: VaultCloudAccessRecord
    ) async throws -> [VaultTransaction] {
        var transactionsByID: [UUID: VaultTransaction] = [:]
        var cursor: String?
        repeat {
            let page = try await objectStore.listObjects(
                containerID: record.remoteLayout.journalContainerID,
                cursor: cursor
            )
            for object in page.objects {
                let url = temporaryURL(prefix: "cloud-journal-download")
                defer { try? FileManager.default.removeItem(at: url) }
                try await objectStore.downloadObject(fileID: object.id, to: url)
                let transaction = try VaultFixedTransactionCodec.open(
                    Data(contentsOf: url, options: .mappedIfSafe),
                    objectToken: object.token,
                    rootKey: record.rootKey,
                    vaultID: record.vaultID,
                    keyEpoch: record.keyEpoch
                )
                guard transactionsByID.updateValue(
                    transaction,
                    forKey: transaction.id
                ) == nil else {
                    throw VaultJournalError.duplicateTransaction(transaction.id)
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        return Array(transactionsByID.values)
    }

    private func temporaryURL(prefix: String) -> URL {
        temporaryDirectoryURL
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension("bin")
    }
}
