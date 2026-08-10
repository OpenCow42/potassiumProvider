import Foundation
import PotassiumProviderCore
import Testing

@Suite(.serialized)
struct ProviderDomainConfigurationIdentityTests {
    @Test func legacyConfigurationUsesDomainIdentifierAsStableIdentityAndMacStorage() throws {
        let json = """
        {
          "domainIdentifier": "legacy-domain",
          "accountIdentifier": "account-1",
          "displayName": "Work Drive",
          "driveID": 42,
          "driveName": "Work Drive",
          "rootFileID": 1,
          "createdAt": "1970-01-01T00:16:40Z",
          "updatedAt": "1970-01-01T00:16:40Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let configuration = try decoder.decode(
            ProviderDomainConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(configuration.configurationIdentifier == "legacy-domain")
        #expect(configuration.domainIdentifier == "legacy-domain")
        #expect(configuration.id == "legacy-domain")
        #expect(configuration.storageLocation == .onThisMac)
    }

    @Test func storeKeepsFilenameAndIdentityStableWhenDomainIdentifierChanges() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DomainConfigurationFileStore(directoryURL: directory)
        let volumeUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var configuration = ProviderDomainConfiguration(
            domainIdentifier: "initial-domain",
            configurationIdentifier: "configuration/1",
            accountIdentifier: "account-1",
            displayName: "Work Drive",
            driveID: 42,
            driveName: "Work Drive",
            storageLocation: .externalVolume(uuid: volumeUUID, displayName: "External SSD"),
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        try await store.save(configuration)
        #expect(try jsonFileNames(in: directory) == ["configuration-1.json"])

        configuration.domainIdentifier = "replacement-domain"
        configuration.updatedAt = Date(timeIntervalSince1970: 2_000)
        try await store.save(configuration)

        #expect(try jsonFileNames(in: directory) == ["configuration-1.json"])
        #expect(try await store.configuration(
            configurationIdentifier: "configuration/1"
        ) == configuration)
        #expect(try await store.configuration(domainIdentifier: "initial-domain") == nil)
        #expect(try await store.configuration(domainIdentifier: "replacement-domain") == configuration)
        #expect(configuration.id == "configuration/1")
        #expect(configuration.storageLocation == .externalVolume(
            uuid: volumeUUID,
            displayName: "External SSD"
        ))

        try await store.remove(domainIdentifier: "replacement-domain")
        #expect(try jsonFileNames(in: directory).isEmpty)
    }

    @Test func storeCanRemoveConfigurationByStableIdentifier() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DomainConfigurationFileStore(directoryURL: directory)
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "generated-domain",
            configurationIdentifier: "stable-configuration",
            displayName: "Work Drive",
            driveID: 42,
            driveName: "Work Drive",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try await store.save(configuration)

        #expect(try await store.configuration(
            configurationIdentifier: "stable-configuration"
        ) == configuration)

        try await store.remove(configurationIdentifier: "stable-configuration")

        #expect(try await store.configuration(
            configurationIdentifier: "stable-configuration"
        ) == nil)
        #expect(try await store.configuration(domainIdentifier: "generated-domain") == nil)
    }

    @Test func protocolDefaultsPreserveExistingDomainIdentifierBasedStores() async throws {
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "generated-domain",
            configurationIdentifier: "stable-configuration",
            displayName: "Work Drive",
            driveID: 42,
            driveName: "Work Drive"
        )
        let store = DomainIdentifierBasedConfigurationStore(configuration: configuration)

        #expect(try await store.configuration(
            configurationIdentifier: "stable-configuration"
        ) == configuration)

        try await store.remove(configurationIdentifier: "stable-configuration")

        #expect(await store.allConfigurations().isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-domain-identity-\(UUID().uuidString)", isDirectory: true)
    }

    private func jsonFileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map(\.lastPathComponent)
        .sorted()
    }
}

private actor DomainIdentifierBasedConfigurationStore: DomainConfigurationStoring {
    private var configurations: [ProviderDomainConfiguration]

    init(configuration: ProviderDomainConfiguration) {
        self.configurations = [configuration]
    }

    func allConfigurations() -> [ProviderDomainConfiguration] {
        configurations
    }

    func configuration(domainIdentifier: String) -> ProviderDomainConfiguration? {
        configurations.first { $0.domainIdentifier == domainIdentifier }
    }

    func save(_ configuration: ProviderDomainConfiguration) {
        configurations.removeAll {
            $0.domainIdentifier == configuration.domainIdentifier
        }
        configurations.append(configuration)
    }

    func remove(domainIdentifier: String) {
        configurations.removeAll { $0.domainIdentifier == domainIdentifier }
    }
}
