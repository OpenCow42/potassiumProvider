import Foundation
@testable import PotassiumProviderCore
import Testing

struct VaultDomainConfigurationTests {
    @Test func v2FormatMarkersAreCurrentAndV1ModeIsFailClosed() {
        #expect(VaultFormat.currentVersion == 2)
        #expect(VaultFormat.fileProviderIdentifierPrefix == "ev2:")
        #expect(ProviderEncryptionMode.opaqueVaultV2.isSupportedEncryptedVault)
        #expect(ProviderEncryptionMode.opaqueVaultV1.isEncryptedVault)
        #expect(ProviderEncryptionMode.opaqueVaultV1.isSupportedEncryptedVault == false)
    }

    @Test func legacyConfigurationDefaultsToPlaintextMode() throws {
        let json = """
        {
          "domainIdentifier": "legacy-domain",
          "accountIdentifier": "legacy-account",
          "displayName": "Legacy",
          "driveID": 12,
          "driveName": "Legacy",
          "rootFileID": 1,
          "knownFolderLayout": "machineNamespace",
          "createdAt": "2026-07-28T00:00:00Z",
          "updatedAt": "2026-07-28T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let configuration = try decoder.decode(
            ProviderDomainConfiguration.self,
            from: Data(json.utf8)
        )
        #expect(configuration.encryptionMode == .legacyPlaintext)
        #expect(configuration.vault == nil)
    }

    @Test func encryptedConfigurationRoundTripsThroughFileStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultDomainConfigurationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DomainConfigurationFileStore(directoryURL: directory)
        let vault = ProviderVaultConfiguration(
            vaultIdentifier: VaultIdentifier(),
            vaultRootFileID: 101,
            vaultHeaderFileID: 102,
            keyEpoch: 3
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "encrypted-domain",
            displayName: "Private",
            driveID: 9,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: vault,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        try await store.save(configuration)
        let loaded = try await store.configuration(domainIdentifier: configuration.domainIdentifier)
        #expect(loaded == configuration)
        #expect(loaded?.vault == vault)
    }

    @Test func v2ModeCannotOverrideAnIncompatibleEmbeddedFormat() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultDomainConfigurationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let vaultID = VaultIdentifier()
        let rootKey = try VaultKeyMaterial.random()
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "mismatched-format-domain",
            displayName: "Unsupported",
            driveID: 9,
            driveName: "Drive",
            encryptionMode: .opaqueVaultV2,
            vault: ProviderVaultConfiguration(
                vaultIdentifier: vaultID,
                vaultRootFileID: 100,
                vaultHeaderFileID: 101,
                formatVersion: 1,
                remoteLayout: VaultBootstrap.RemoteLayout(
                    contentContainerID: 102,
                    journalContainerID: 103,
                    checkpointContainerID: 104,
                    checkpointToken: "unsupported-format-token"
                )
            )
        )
        let localStore = try VaultSQLiteStore(
            databaseURL: directory.appendingPathComponent("vault.sqlite3"),
            domainIdentifier: configuration.domainIdentifier,
            vaultID: vaultID,
            rootKey: rootKey
        )

        #expect(throws: EncryptedVaultError.missingConfiguration) {
            _ = try EncryptedVaultService(
                configuration: configuration,
                rootKey: rootKey,
                deviceID: UUID(),
                objectStore: InMemoryOpaqueObjectStore(),
                localStore: localStore,
                keyStore: InMemoryVaultKeyStore(),
                temporaryDirectoryURL: directory
            )
        }
    }
}
