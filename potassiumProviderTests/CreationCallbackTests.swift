import FileProvider
import Foundation
import PotassiumProviderCore
import Testing

struct CreationCallbackTests {
    @Test(arguments: [false, true])
    func reconciliationHintPreservesExistingBytesAndReplaysFileIdentity(mayAlreadyExist: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
        let client = ConflictTestClient(directory: directory.appendingPathComponent("client"), remote: remote)
        let original = try await remote.item(driveID: 7, fileID: 3)
        let local = Data("local create".utf8)
        let options: NSFileProviderCreateItemOptions = mayAlreadyExist ? [.mayAlreadyExist] : []
        func deliver(_ client: ConflictTestClient) async throws -> KDriveRemoteItem {
            try await KDriveCreationExecutor.execute(isDirectory: false, options: options,
                createDirectory: { Issue.record("File callback routed as directory"); throw CancellationError() },
                createFile: { try await client.coordinator.createFile(parentID: 1, fileName: original.name, contents: local, lastModifiedAt: nil) })
        }
        let created = try await deliver(client)
        let restarted = ConflictTestClient(directory: client.directory, remote: remote)
        let replay = try await deliver(restarted)
        #expect(created == replay && created.id != original.id && created.name != original.name)
        #expect(created.parentID == original.parentID && created.etag != nil)
        #expect(try await remote.downloadFile(driveID: 7, fileID: created.id) == local)
        #expect(try await remote.downloadFile(driveID: 7, fileID: original.id) == Data("base".utf8))
        #expect(await remote.snapshot().items.count == 4)
    }

    @Test func repeatedDirectoryHintRetainsTheDocumentedReconciliationLimitation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
        let client = ConflictTestClient(directory: directory.appendingPathComponent("client"), remote: remote)
        func deliver() async throws -> KDriveRemoteItem {
            try await KDriveCreationExecutor.execute(isDirectory: true, options: [.mayAlreadyExist],
                createDirectory: { try await client.coordinator.createDirectory(parentID: 1, name: "Repeated") },
                createFile: { Issue.record("Directory callback tried uploading file bytes"); throw CancellationError() })
        }
        let original = try await deliver(), replay = try await deliver()
        #expect(original.id != replay.id && original.name != replay.name)
        #expect(original.isDirectory && replay.isDirectory && original.parentID == replay.parentID)
        #expect(try await remote.item(driveID: 7, fileID: original.id) == original)
        for folder in [original, replay] {
            let data = Data("usable child".utf8)
            let child = try await client.coordinator.createFile(parentID: folder.id, fileName: "Child.txt", contents: data, lastModifiedAt: nil)
            #expect(child.parentID == folder.id)
            #expect(try await remote.downloadFile(driveID: 7, fileID: child.id) == data)
        }
        // This verifies current conservative policy. It intentionally does not
        // claim no-duplicate-effect acceptance or resolve CR-009.
    }
}
