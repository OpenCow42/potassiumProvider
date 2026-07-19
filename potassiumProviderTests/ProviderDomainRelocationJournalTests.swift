import Foundation
import PotassiumProviderCore
import Testing

@Suite("Provider domain relocation journal")
struct ProviderDomainRelocationJournalTests {
    @Test
    func persistsUpdatesAndRemovesJournalByStableConfigurationIdentifier() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderDomainRelocationJournalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = ProviderDomainRelocationFileStore(directoryURL: directoryURL)
        let source = ProviderDomainConfiguration(
            configurationIdentifier: "configuration-1",
            domainIdentifier: "domain-old",
            displayName: "Team",
            driveID: 42,
            driveName: "Team",
            storageLocation: .onThisMac
        )
        var journal = ProviderDomainRelocationJournal(
            configurationIdentifier: source.configurationIdentifier,
            sourceConfiguration: source,
            targetStorageLocation: .externalVolume(
                volumeUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                displayName: "Portable"
            ),
            knownFoldersWereActive: true
        )

        try await store.save(journal)
        #expect(try await store.journal(configurationIdentifier: "configuration-1") == journal)

        journal.phase = .targetConfigurationSaved
        journal.targetDomainIdentifier = "domain-new"
        journal.updatedAt = journal.updatedAt.addingTimeInterval(1)
        try await store.save(journal)

        let allJournals = try await store.allJournals()
        #expect(allJournals == [journal])
        #expect(allJournals.first?.sourceConfiguration.domainIdentifier == "domain-old")

        try await store.remove(configurationIdentifier: "configuration-1")
        #expect(try await store.journal(configurationIdentifier: "configuration-1") == nil)
    }
}
