import Foundation
@testable import PotassiumProviderCore
import Testing

struct VaultProvisioningTests {
    @Test func domainIsNotUnlockedUntilRecoveryKitConfirmation() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectStore = InMemoryOpaqueObjectStore()
        let keyStore = InMemoryVaultKeyStore()
        let service = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )

        let pending = try await service.prepareNewVault(driveID: 42)
        #expect(try await keyStore.loadRootKey(vaultID: pending.vaultID) == nil)
        await #expect(throws: VaultProvisioningError.recoveryConfirmationMismatch) {
            try await service.confirm(
                pending,
                recoveryKitConfirmation: "KPV2-NOT-A-RECOVERY-KIT"
            )
        }
        #expect(try await keyStore.loadRootKey(vaultID: pending.vaultID) == nil)

        let configuration = try await service.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )
        #expect(configuration == pending.vaultConfiguration)
        #expect(try await keyStore.loadRootKey(vaultID: pending.vaultID) == pending.rootKey)
        #expect(
            try await keyStore.loadTrustedState(vaultID: pending.vaultID)?.frontier
                == VaultFrontier()
        )

        let stored = await objectStore.filePayloads()
        #expect(stored.allSatisfy {
            $0.range(of: pending.rootKey.data) == nil
                && $0.range(of: pending.recoveryKit.recoverySecret.data) == nil
        })
        #expect(await objectStore.allTokens().allSatisfy(Self.isOpaqueToken))
    }

    @Test func recoveryImportAuthenticatesBootstrapAndCheckpoint() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectStore = InMemoryOpaqueObjectStore()
        let firstKeyStore = InMemoryVaultKeyStore()
        let firstService = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: firstKeyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await firstService.prepareNewVault(driveID: 9)
        _ = try await firstService.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )

        let returningKeyStore = InMemoryVaultKeyStore()
        let returningService = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: returningKeyStore,
            temporaryDirectoryURL: directory
        )
        let opened = try await returningService.openExistingVault(
            recoveryKitText: pending.recoveryKit.encoded,
            expectedDriveID: 9
        )
        #expect(opened == pending.vaultConfiguration)
        #expect(
            try await returningKeyStore.loadRootKey(vaultID: pending.vaultID)
                == pending.rootKey
        )
    }

    @Test func cancellingUnregisteredProvisioningDeletesOnlyItsNewRoot() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectStore = InMemoryOpaqueObjectStore()
        let service = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: InMemoryVaultKeyStore(),
            temporaryDirectoryURL: directory
        )
        let unrelated = try await objectStore.createContainer(
            parentID: 1,
            token: Data(repeating: 0xAB, count: 20).opaqueToken
        )
        let pending = try await service.prepareNewVault(driveID: 2)

        await service.cancel(pending)
        #expect(await objectStore.contains(fileID: unrelated.id))
        #expect(
            await objectStore.contains(
                fileID: pending.vaultConfiguration.vaultRootFileID
            ) == false
        )
    }

    @Test func copyOnWriteDuplicateDecryptsSharedImmutableRevision() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectStore = InMemoryOpaqueObjectStore()
        let content = try await objectStore.createContainer(
            parentID: 1,
            token: Data(repeating: 1, count: 20).opaqueToken
        )
        let journal = try await objectStore.createContainer(
            parentID: 1,
            token: Data(repeating: 2, count: 20).opaqueToken
        )
        let checkpoints = try await objectStore.createContainer(
            parentID: 1,
            token: Data(repeating: 3, count: 20).opaqueToken
        )
        let vaultID = VaultIdentifier()
        let rootKey = try VaultKeyMaterial.random()
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "duplicate-domain",
            displayName: "Encrypted",
            driveID: 5,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: ProviderVaultConfiguration(
                vaultIdentifier: vaultID,
                vaultRootFileID: 1,
                vaultHeaderFileID: 2,
                remoteLayout: VaultBootstrap.RemoteLayout(
                    contentContainerID: content.id,
                    journalContainerID: journal.id,
                    checkpointContainerID: checkpoints.id,
                    checkpointToken: Data(repeating: 4, count: 20).opaqueToken
                )
            )
        )
        let localStore = try VaultSQLiteStore(
            databaseURL: directory.appendingPathComponent("vault.sqlite3"),
            domainIdentifier: configuration.domainIdentifier,
            vaultID: vaultID,
            rootKey: rootKey
        )
        let service = try EncryptedVaultService(
            configuration: configuration,
            rootKey: rootKey,
            deviceID: UUID(),
            objectStore: objectStore,
            localStore: localStore,
            keyStore: InMemoryVaultKeyStore(),
            temporaryDirectoryURL: directory
        )
        let plaintext = Data("duplicate me without decrypting on the server".utf8)
        let sourceURL = directory.appendingPathComponent("source")
        try plaintext.write(to: sourceURL)
        let original = try await service.createFile(
            parentID: nil,
            filename: "secret.txt",
            contentTypeIdentifier: "public.plain-text",
            plaintextURL: sourceURL,
            modifiedAt: Date()
        )
        let duplicate = try await service.duplicate(itemID: original.id)
        #expect(duplicate.id != original.id)
        #expect(duplicate.contentReference == original.contentReference)

        let openedURL = directory.appendingPathComponent("opened")
        _ = try await service.fetchContent(
            itemID: duplicate.id,
            expectedRevision: duplicate.contentRevision,
            to: openedURL
        )
        #expect(try Data(contentsOf: openedURL) == plaintext)
    }

    @Test func restoringVersionPublishesFreshRevisionAndRejectsABAStaleWrite() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectStore = InMemoryOpaqueObjectStore()
        let keyStore = InMemoryVaultKeyStore()
        let provisioning = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await provisioning.prepareNewVault(driveID: 6)
        _ = try await provisioning.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "version-domain",
            displayName: "Encrypted",
            driveID: 6,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: pending.vaultConfiguration
        )
        let localStore = try VaultSQLiteStore(
            databaseURL: directory.appendingPathComponent("versions.sqlite3"),
            domainIdentifier: configuration.domainIdentifier,
            vaultID: pending.vaultID,
            rootKey: pending.rootKey
        )
        let vault = try EncryptedVaultService(
            configuration: configuration,
            rootKey: pending.rootKey,
            deviceID: UUID(),
            objectStore: objectStore,
            localStore: localStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let firstURL = directory.appendingPathComponent("first")
        let secondURL = directory.appendingPathComponent("second")
        try Data("first revision".utf8).write(to: firstURL)
        try Data("second revision".utf8).write(to: secondURL)
        let original = try await vault.createFile(
            parentID: nil,
            filename: "document.txt",
            contentTypeIdentifier: "public.plain-text",
            plaintextURL: firstURL,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let modified = try await vault.modify(
            itemID: original.id,
            baseContentRevision: original.contentRevision,
            baseMetadataRevision: original.metadataRevision,
            parentID: original.parentID,
            filename: original.filename,
            favorite: original.isFavorite,
            plaintextURL: secondURL,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let restored = try await vault.restoreVersion(
            itemID: original.id,
            contentRevision: original.contentRevision
        )
        #expect(restored.contentRevision != original.contentRevision)
        #expect(restored.contentRevision != modified.contentRevision)
        #expect(restored.contentReference?.objectToken != original.contentReference?.objectToken)

        let openedURL = directory.appendingPathComponent("restored")
        _ = try await vault.fetchContent(
            itemID: restored.id,
            expectedRevision: restored.contentRevision,
            to: openedURL
        )
        #expect(try Data(contentsOf: openedURL) == Data("first revision".utf8))

        await #expect(throws: EncryptedVaultError.staleRevision) {
            try await vault.modify(
                itemID: original.id,
                baseContentRevision: original.contentRevision,
                baseMetadataRevision: original.metadataRevision,
                parentID: original.parentID,
                filename: original.filename,
                favorite: original.isFavorite,
                plaintextURL: secondURL,
                modifiedAt: Date(timeIntervalSince1970: 300)
            )
        }
    }

    @Test func returningDeviceRejectsOmittedRemoteJournalObject() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectStore = InMemoryOpaqueObjectStore()
        let keyStore = InMemoryVaultKeyStore()
        let provisioning = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await provisioning.prepareNewVault(driveID: 8)
        _ = try await provisioning.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "rollback-domain",
            displayName: "Encrypted",
            driveID: 8,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: pending.vaultConfiguration
        )
        let localStore = try VaultSQLiteStore(
            databaseURL: directory.appendingPathComponent("rollback.sqlite3"),
            domainIdentifier: configuration.domainIdentifier,
            vaultID: pending.vaultID,
            rootKey: pending.rootKey
        )
        let vault = try EncryptedVaultService(
            configuration: configuration,
            rootKey: pending.rootKey,
            deviceID: UUID(),
            objectStore: objectStore,
            localStore: localStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        _ = try await vault.createDirectory(
            parentID: nil,
            filename: "private-folder",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        let journalContainerID = try #require(
            pending.vaultConfiguration.remoteLayout?.journalContainerID
        )
        let journalPage = await objectStore.listObjects(
            containerID: journalContainerID,
            cursor: nil
        )
        let journalObject = try #require(journalPage.objects.first)
        await objectStore.deleteObject(fileID: journalObject.id)

        await #expect(throws: VaultJournalError.rollbackDetected) {
            try await vault.synchronize()
        }
    }

    @Test func maintenanceNeverDeletesCiphertextThatAnOfflineDeviceMayReference() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectStore = InMemoryOpaqueObjectStore()
        let keyStore = InMemoryVaultKeyStore()
        let provisioning = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await provisioning.prepareNewVault(driveID: 12)
        _ = try await provisioning.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "maintenance-domain",
            displayName: "Encrypted",
            driveID: 12,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: pending.vaultConfiguration
        )
        let localStore = try VaultSQLiteStore(
            databaseURL: directory.appendingPathComponent("maintenance.sqlite3"),
            domainIdentifier: configuration.domainIdentifier,
            vaultID: pending.vaultID,
            rootKey: pending.rootKey
        )
        let vault = try EncryptedVaultService(
            configuration: configuration,
            rootKey: pending.rootKey,
            deviceID: UUID(),
            objectStore: objectStore,
            localStore: localStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let plaintextURL = directory.appendingPathComponent("referenced")
        try Data("referenced private bytes".utf8).write(to: plaintextURL)
        let referenced = try await vault.createFile(
            parentID: nil,
            filename: "referenced.txt",
            contentTypeIdentifier: "public.plain-text",
            plaintextURL: plaintextURL,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let referencedFileID = try #require(referenced.contentReference?.remoteFileID)

        let layout = try #require(pending.vaultConfiguration.remoteLayout)
        let orphanURL = directory.appendingPathComponent("orphan")
        try Data(repeating: 0xA5, count: 256).write(to: orphanURL)
        let orphan = try await objectStore.uploadObject(
            containerID: layout.contentContainerID,
            token: VaultCryptography.makeObjectToken(
                rootKey: pending.rootKey,
                vaultID: pending.vaultID
            ),
            fileURL: orphanURL
        )
        let maintenance = try VaultMaintenanceService(
            vaultConfiguration: pending.vaultConfiguration,
            rootKey: pending.rootKey,
            objectStore: objectStore,
            localStore: localStore,
            vault: vault,
            temporaryDirectoryURL: directory
        )

        let first = try await maintenance.checkpointAndReportUnreferencedContent(
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(first.unreferencedObjectCount == 1)
        #expect(await objectStore.contains(fileID: orphan.id))

        let later = try await maintenance.checkpointAndReportUnreferencedContent(
            now: Date(timeIntervalSince1970: 10_000)
        )
        #expect(later.unreferencedObjectCount == 1)
        #expect(await objectStore.contains(fileID: orphan.id))

        let muchLater = try await maintenance.checkpointAndReportUnreferencedContent(
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(muchLater.unreferencedObjectCount == 1)
        #expect(await objectStore.contains(fileID: orphan.id))
        #expect(await objectStore.contains(fileID: referencedFileID))
    }

    @Test func changeHistoryUsesRequestedFrontierAndReportsMovesAsUpdates() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectStore = InMemoryOpaqueObjectStore()
        let keyStore = InMemoryVaultKeyStore()
        let provisioning = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await provisioning.prepareNewVault(driveID: 13)
        _ = try await provisioning.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "changes-domain",
            displayName: "Encrypted",
            driveID: 13,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: pending.vaultConfiguration
        )
        let localStore = try VaultSQLiteStore(
            databaseURL: directory.appendingPathComponent("changes.sqlite3"),
            domainIdentifier: configuration.domainIdentifier,
            vaultID: pending.vaultID,
            rootKey: pending.rootKey
        )
        let vault = try EncryptedVaultService(
            configuration: configuration,
            rootKey: pending.rootKey,
            deviceID: UUID(),
            objectStore: objectStore,
            localStore: localStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )

        let folder = try await vault.createDirectory(
            parentID: nil,
            filename: "folder",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let folderFrontier = try await vault.synchronize()
        let folderAnchor = folderFrontier.anchorString
        let moving = try await vault.createDirectory(
            parentID: nil,
            filename: "moving",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let createChanges = try await vault.changes(
            since: folderAnchor,
            scope: .children(parentID: nil)
        )
        #expect(createChanges.updated.map(\.id) == [moving.id])
        #expect(createChanges.deleted.isEmpty)

        let beforeMoveAnchor = createChanges.frontier.anchorString
        let moved = try await vault.modify(
            itemID: moving.id,
            baseContentRevision: moving.contentRevision,
            baseMetadataRevision: moving.metadataRevision,
            parentID: folder.id,
            filename: moving.filename,
            favorite: moving.isFavorite,
            plaintextURL: nil,
            modifiedAt: moving.modifiedAt
        )
        let moveChanges = try await vault.changes(
            since: beforeMoveAnchor,
            scope: .children(parentID: nil)
        )
        #expect(moveChanges.updated.map(\.id) == [moving.id])
        #expect(moveChanges.updated.first?.parentID == folder.id)
        #expect(moveChanges.deleted.isEmpty)
        #expect(moved.parentID == folder.id)

        for index in 0..<4 {
            _ = try await vault.createDirectory(
                parentID: nil,
                filename: "generation-\(index)",
                createdAt: Date(timeIntervalSince1970: Double(30 + index))
            )
        }
        await #expect(throws: EncryptedVaultError.syncAnchorExpired) {
            try await vault.changes(
                since: folderAnchor,
                scope: .children(parentID: nil)
            )
        }
    }

    private static func isOpaqueToken(_ value: String) -> Bool {
        guard value.count == 27 else { return false }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "VaultProvisioningTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

actor InMemoryOpaqueObjectStore: KDriveObjectStoreProviding {
    private struct Entry {
        var metadata: KDriveOpaqueObject
        var payload: Data?
    }

    private var nextID = 10
    private var entries: [Int: Entry] = [:]

    func createContainer(parentID: Int, token: String) -> KDriveOpaqueObject {
        insert(parentID: parentID, token: token, payload: nil, isContainer: true)
    }

    func listObjects(
        containerID: Int,
        cursor: String?
    ) -> KDriveOpaqueObjectPage {
        KDriveOpaqueObjectPage(
            objects: entries.values
                .map(\.metadata)
                .filter { $0.parentID == containerID }
                .sorted { $0.id < $1.id },
            nextCursor: nil
        )
    }

    func uploadObject(
        containerID: Int,
        token: String,
        fileURL: URL
    ) throws -> KDriveOpaqueObject {
        insert(
            parentID: containerID,
            token: token,
            payload: try Data(contentsOf: fileURL),
            isContainer: false
        )
    }

    func downloadObject(fileID: Int, to destinationURL: URL) throws {
        guard let payload = entries[fileID]?.payload else {
            throw TestObjectStoreError.missing
        }
        try payload.write(to: destinationURL)
    }

    func deleteObject(fileID: Int) {
        let descendants = recursiveDescendants(of: fileID)
        for identifier in descendants.union([fileID]) {
            entries[identifier] = nil
        }
    }

    func filePayloads() -> [Data] {
        entries.values.compactMap(\.payload)
    }

    func allTokens() -> [String] {
        entries.values.map(\.metadata.token)
    }

    func contains(fileID: Int) -> Bool {
        entries[fileID] != nil
    }

    private func insert(
        parentID: Int,
        token: String,
        payload: Data?,
        isContainer: Bool
    ) -> KDriveOpaqueObject {
        let identifier = nextID
        nextID += 1
        let value = KDriveOpaqueObject(
            id: identifier,
            parentID: parentID,
            token: token,
            byteCount: payload.map { Int64($0.count) },
            serverUpdatedAt: Date(timeIntervalSince1970: Double(identifier)),
            isContainer: isContainer
        )
        entries[identifier] = Entry(metadata: value, payload: payload)
        return value
    }

    private func recursiveDescendants(of fileID: Int) -> Set<Int> {
        let children = entries.values
            .map(\.metadata)
            .filter { $0.parentID == fileID }
            .map(\.id)
        return children.reduce(into: Set(children)) { result, child in
            result.formUnion(recursiveDescendants(of: child))
        }
    }
}

enum TestObjectStoreError: Error {
    case missing
}

private extension Data {
    var opaqueToken: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
