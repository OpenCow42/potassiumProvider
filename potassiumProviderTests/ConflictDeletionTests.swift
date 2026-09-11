import Foundation
import PotassiumChannelCore
import PotassiumProviderCore
import Testing

struct ConflictDeletionTests {
    @Test func permanentDeleteUsesAuthoritativeTrashMetadataAndRepeatedAbsenceIsObservable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
        let base = try await remote.item(driveID: 7, fileID: 3)
        try await remote.trashItem(driveID: 7, fileID: 3)
        let coordinator = KDriveMutationCoordinator(configuration: ProviderDomainConfiguration(domainIdentifier: "synthetic",
            displayName: "Synthetic", driveID: 7, driveName: "Synthetic", rootFileID: 1), remote: remote,
            trashedItemLookup: { id in
                guard let item = await remote.snapshot().items[id], await remote.snapshot().trash.contains(id) else {
                    throw APIClientError.unacceptableStatusCode(404, body: "")
                }
                return item
            })
        // An active-item request would fail. Successful deletion therefore has
        // to use the injected authoritative Trash lookup, not active metadata.
        await remote.hideFromActiveLookup(3)
        let version = KDriveItemBaseVersion(contentVersion: base.contentVersion, metadataVersion: base.metadataVersion)
        await #expect(throws: APIClientError.self) { try await remote.item(driveID: 7, fileID: 3) }
        let deleted = try await coordinator.deleteTrashedItem(fileID: 3, baseVersion: version)
        #expect(deleted.id == 3)
        #expect(await remote.snapshot().items[3] == nil)
        do {
            _ = try await coordinator.deleteTrashedItem(fileID: 3, baseVersion: version)
            Issue.record("Expected authoritative absence on a repeated deletion")
        } catch { #expect(KDriveRemoteErrorClassifier.isNotFound(error)) }
        #expect(await remote.operations().filter { $0 == "delete" }.count == 1)
    }
}
