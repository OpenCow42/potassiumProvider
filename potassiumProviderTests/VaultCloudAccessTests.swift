import Foundation
import Security
@testable import PotassiumProviderCore
import Testing

struct VaultCloudAccessTests {
    @Test func recordRoundTripsWithoutRecoveryOrDeviceState() throws {
        let record = try makeRecord()
        let data = try VaultCoding.encoder.encode(record)
        let decoded = try VaultCoding.decoder.decode(
            VaultCloudAccessRecord.self,
            from: data
        )

        #expect(decoded == record)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("recoverySecret") == false)
        #expect(text.contains("trustedState") == false)
        #expect(text.contains("deviceID") == false)
    }

    @Test func malformedRootKeyAndUnsupportedRecordVersionFailClosed() throws {
        let record = try makeRecord()
        let encoded = try VaultCoding.encoder.encode(record)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["recordVersion"] = 2
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: VaultCloudAccessStoreError.self) {
            _ = try VaultCoding.decoder.decode(
                VaultCloudAccessRecord.self,
                from: future
            )
        }

        object["recordVersion"] = 1
        var remoteLayout = try #require(
            object["remoteLayout"] as? [String: Any]
        )
        remoteLayout["unexpectedField"] = true
        object["remoteLayout"] = remoteLayout
        let unknownNestedField = try JSONSerialization.data(
            withJSONObject: object
        )
        #expect(throws: VaultCloudAccessStoreError.malformedRecord) {
            _ = try VaultCoding.decoder.decode(
                VaultCloudAccessRecord.self,
                from: unknownNestedField
            )
        }

        remoteLayout["unexpectedField"] = nil
        object["remoteLayout"] = remoteLayout
        object["unexpectedField"] = "must fail closed"
        let unknownField = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: VaultCloudAccessStoreError.malformedRecord) {
            _ = try VaultCoding.decoder.decode(
                VaultCloudAccessRecord.self,
                from: unknownField
            )
        }

        object["unexpectedField"] = nil
        object["rootKey"] = Data(repeating: 1, count: 8).base64EncodedString()
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: VaultCloudAccessStoreError.malformedRecord) {
            _ = try VaultCoding.decoder.decode(
                VaultCloudAccessRecord.self,
                from: malformed
            )
        }
    }

    @Test func recoveryVerificationAuthenticatesSecretWithoutPersistingIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let objectStore = InMemoryOpaqueObjectStore()
        let keyStore = InMemoryVaultKeyStore()
        let provisioning = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await provisioning.prepareNewVault(driveID: 42)

        try await provisioning.verifyRecoveryKit(
            pending.recoveryKit.encoded,
            expectedConfiguration: pending.vaultConfiguration,
            expectedDriveID: 42
        )
        #expect(
            try await keyStore.loadRootKey(vaultID: pending.vaultID) == nil
        )

        let wrongKit = VaultRecoveryKit(
            vaultID: pending.vaultID,
            driveID: pending.driveID,
            vaultRootFileID: pending.vaultConfiguration.vaultRootFileID,
            vaultHeaderFileID: pending.vaultConfiguration.vaultHeaderFileID,
            recoverySecret: try VaultKeyMaterial.random()
        )
        await #expect(throws: VaultCryptoError.authenticationFailed) {
            try await provisioning.verifyRecoveryKit(
                wrongKit.encoded,
                expectedConfiguration: pending.vaultConfiguration,
                expectedDriveID: 42
            )
        }
        #expect(
            try await keyStore.loadRootKey(vaultID: pending.vaultID) == nil
        )
    }

    @Test func cloudAndDeviceKeychainAttributesRemainSeparated() async throws {
        let cloud = KeychainVaultCloudAccessStore(
            service: "test.cloud",
            accessGroup: "TEAM.test"
        )
        let query = await cloud.baseQuery(account: "vaultCloudAccess:test")
        let attributes = await cloud.saveAttributes(data: Data([1]))

        #expect(
            query[kSecAttrSynchronizable as String] as? Bool == true
        )
        #expect(
            query[kSecUseDataProtectionKeychain as String] as? Bool == true
        )
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlocked as String
        )

        let device = KeychainVaultKeyStore(
            service: "test.device",
            accessGroup: "TEAM.test"
        )
        let deviceQuery = await device.baseQuery(account: "vaultRootKey:test")
        let deviceAttributes = await device.saveAttributes(data: Data([1]))
        #expect(
            deviceQuery[kSecAttrSynchronizable as String] as? Bool == false
        )
        #expect(
            deviceAttributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @Test func authenticatedCloudImportRestoresRootAndPreservesTrustedFrontier() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let objectStore = InMemoryOpaqueObjectStore()
        let keyStore = InMemoryVaultKeyStore()
        let provisioning = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await provisioning.prepareNewVault(driveID: 42)
        _ = try await provisioning.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "cloud-import",
            displayName: "Encrypted",
            driveID: 42,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: pending.vaultConfiguration
        )
        let localStore = try VaultSQLiteStore(
            databaseURL: directory.appendingPathComponent("cloud-import.sqlite3"),
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
            filename: "encrypted-name",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let trustedBefore = try #require(
            try await keyStore.loadTrustedState(vaultID: pending.vaultID)
        )
        try await keyStore.deleteRootKey(vaultID: pending.vaultID)
        let record = try VaultCloudAccessRecord(
            configuration: pending.vaultConfiguration,
            driveID: 42,
            rootKey: pending.rootKey
        )

        let opened = try await provisioning.openExistingVault(
            cloudAccessRecord: record,
            expectedDriveID: 42
        )

        #expect(opened == pending.vaultConfiguration)
        #expect(
            try await keyStore.loadRootKey(vaultID: pending.vaultID)
                == pending.rootKey
        )
        let trustedAfter = try #require(
            try await keyStore.loadTrustedState(vaultID: pending.vaultID)
        )
        #expect(
            trustedAfter.frontier.transactionIDs
                .isSuperset(of: trustedBefore.frontier.transactionIDs)
        )
    }

    @Test func wrongCloudRootAndStaleEpochNeverPersistLocally() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let objectStore = InMemoryOpaqueObjectStore()
        let sourceStore = InMemoryVaultKeyStore()
        let source = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: sourceStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await source.prepareNewVault(driveID: 7)
        let targetStore = InMemoryVaultKeyStore()
        let target = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: targetStore,
            temporaryDirectoryURL: directory
        )
        let wrongRoot = try VaultKeyMaterial.random()
        let wrongRecord = try VaultCloudAccessRecord(
            configuration: pending.vaultConfiguration,
            driveID: 7,
            rootKey: wrongRoot
        )

        await #expect(throws: VaultCryptoError.authenticationFailed) {
            try await target.openExistingVault(
                cloudAccessRecord: wrongRecord,
                expectedDriveID: 7
            )
        }
        #expect(
            try await targetStore.loadRootKey(vaultID: pending.vaultID) == nil
        )

        let stale = VaultCloudAccessRecord(
            vaultID: pending.vaultID,
            driveID: 7,
            vaultRootFileID: pending.vaultConfiguration.vaultRootFileID,
            vaultHeaderFileID: pending.vaultConfiguration.vaultHeaderFileID,
            formatVersion: pending.vaultConfiguration.formatVersion,
            keyEpoch: pending.vaultConfiguration.keyEpoch + 1,
            remoteLayout: try #require(
                pending.vaultConfiguration.remoteLayout
            ),
            rootKey: pending.rootKey
        )
        await #expect(throws: VaultProvisioningError.keyEpochMismatch) {
            try await target.openExistingVault(
                cloudAccessRecord: stale,
                expectedDriveID: 7
            )
        }
        #expect(
            try await targetStore.loadRootKey(vaultID: pending.vaultID) == nil
        )
    }

    @Test func cloudRestoreRejectsRollbackBeforePersistingRootKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let objectStore = InMemoryOpaqueObjectStore()
        let keyStore = InMemoryVaultKeyStore()
        let provisioning = VaultProvisioningService(
            objectStore: objectStore,
            keyStore: keyStore,
            temporaryDirectoryURL: directory
        )
        let pending = try await provisioning.prepareNewVault(driveID: 42)
        _ = try await provisioning.confirm(
            pending,
            recoveryKitConfirmation: pending.recoveryKit.encoded
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "cloud-rollback",
            displayName: "Encrypted",
            driveID: 42,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: pending.vaultConfiguration
        )
        let localStore = try VaultSQLiteStore(
            databaseURL: directory.appendingPathComponent("cloud-rollback.sqlite3"),
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
            filename: "trusted-folder",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let trustedBefore = try #require(
            try await keyStore.loadTrustedState(vaultID: pending.vaultID)
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
        try await keyStore.deleteRootKey(vaultID: pending.vaultID)
        let record = try VaultCloudAccessRecord(
            configuration: pending.vaultConfiguration,
            driveID: 42,
            rootKey: pending.rootKey
        )

        await #expect(throws: VaultJournalError.rollbackDetected) {
            try await provisioning.openExistingVault(
                cloudAccessRecord: record,
                expectedDriveID: 42
            )
        }
        #expect(
            try await keyStore.loadRootKey(vaultID: pending.vaultID) == nil
        )
        #expect(
            try await keyStore.loadTrustedState(vaultID: pending.vaultID)
                == trustedBefore
        )
    }

    private func makeRecord() throws -> VaultCloudAccessRecord {
        VaultCloudAccessRecord(
            vaultID: VaultIdentifier(
                rawValue: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
            ),
            driveID: 42,
            vaultRootFileID: 10,
            vaultHeaderFileID: 11,
            formatVersion: VaultFormat.currentVersion,
            keyEpoch: VaultFormat.currentKeyEpoch,
            remoteLayout: VaultBootstrap.RemoteLayout(
                contentContainerID: 12,
                journalContainerID: 13,
                checkpointContainerID: 14,
                checkpointToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAA"
            ),
            rootKey: try #require(
                VaultKeyMaterial(data: Data(repeating: 0xA5, count: 32))
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "VaultCloudAccessTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
