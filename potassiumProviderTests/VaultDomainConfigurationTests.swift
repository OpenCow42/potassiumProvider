import Foundation
@testable import PotassiumProviderCore
import Testing

struct VaultDomainConfigurationTests {
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
            encryptionMode: .opaqueVaultV1,
            vault: vault,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        try await store.save(configuration)
        let loaded = try await store.configuration(domainIdentifier: configuration.domainIdentifier)
        #expect(loaded == configuration)
        #expect(loaded?.vault == vault)
    }
}
