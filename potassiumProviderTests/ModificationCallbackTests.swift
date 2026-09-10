import FileProvider
import Foundation
import PotassiumProviderCore
import Testing

struct ModificationCallbackTests {
    struct Shape: Sendable {
        let fields: NSFileProviderItemFields
        let trash: Bool
        let operations: [String]
    }
    static let shapes: [Shape] = [
        Shape(fields: [.contents, .filename], trash: false, operations: ["rename", "replace"]),
        Shape(fields: [.contents, .parentItemIdentifier], trash: false, operations: ["move", "replace"]),
        Shape(fields: [.contents, .filename, .parentItemIdentifier], trash: false, operations: ["move", "replace"]),
        Shape(fields: [.contents, .parentItemIdentifier], trash: true, operations: ["replace", "trash"]),
        Shape(fields: [.filename, .tagData], trash: false, operations: ["rename"]),
        Shape(fields: [.contents, .filename, .tagData], trash: false, operations: ["rename", "replace"]),
        Shape(fields: [.tagData], trash: false, operations: [])
    ]

    @Test(arguments: shapes, [false, true])
    func productionPlaintextSequence(_ shape: Shape, remoteChanged: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
        let client = ConflictTestClient(directory: directory.appendingPathComponent("client"), remote: remote)
        let base = try await remote.item(driveID: 7, fileID: 3)
        try client.cache(base)
        let other = Data("remote".utf8), local = Data("local".utf8)
        if remoteChanged {
            _ = try await remote.replaceFile(driveID: 7, fileID: 3, expectedETag: base.etag!, clientToken: "other",
                contentHash: KDriveMutationIdentity.contentHash(other), contents: other, lastModifiedAt: nil)
        }
        await remote.clearOperations()
        let executor = KDriveModificationExecutor(coordinator: client.coordinator) { try await remote.item(driveID: 7, fileID: $0) }
        let requestedName = shape.fields.contains(.filename) ? "Renamed.txt" : base.name
        let result = try await executor.execute(fileID: 3, filename: requestedName,
            baseVersion: KDriveItemBaseVersion(contentVersion: base.contentVersion, metadataVersion: base.metadataVersion),
            fields: shape.fields, destinationParentID: shape.trash ? nil : 2, requestsTrash: shape.trash,
            modificationDate: nil, hasContents: true) { try await client.edit(local, filename: requestedName) }
        let uploads = remoteChanged && shape.fields.contains(.contents)
        var expected = shape.operations.map { $0 == "replace" && uploads ? "upload" : $0 }
        if shape.trash && uploads { expected.append("trash") }
        #expect(await remote.operations() == expected)
        #expect(result.remainingFields == shape.fields.intersection(.tagData))
        #expect(result.trashed == shape.trash)
        let state = await remote.snapshot()
        let expectedParent = shape.fields.contains(.parentItemIdentifier) && !shape.trash ? 2 : 1
        #expect(state.items[3]?.parentID == expectedParent)
        #expect(state.items[3]?.name == (shape.fields.contains(.filename) ? "Renamed.txt" : base.name))
        if shape.fields.contains(.contents) {
            let localIDs = state.bytes.filter { $0.value == local }.map(\.key)
            #expect(localIDs.count == 1)
            let localID = try #require(localIDs.first)
            #expect(state.items[localID]?.parentID == expectedParent)
            #expect(state.items[localID]?.contentVersion != base.contentVersion)
            let expectedName = remoteChanged ? KDriveConflictFilename.filename(for: requestedName,
                deviceName: "Synthetic", date: Date(timeIntervalSince1970: 1), timeZone: TimeZone(secondsFromGMT: 0)!) : requestedName
            #expect(state.items[localID]?.name == expectedName)
            #expect(try await remote.downloadFile(driveID: 7, fileID: localID) == local)
            if remoteChanged {
                #expect(localID != 3 && state.bytes[3] == other)
                if shape.trash { #expect(state.trash == [3, localID]) }
            } else { #expect(localID == 3) }
        }
        if shape.trash { #expect(result.item == nil && state.trash.contains(3)) }
        else {
            let item = try #require(result.item)
            #expect(state.items[item.id] == item)
            #expect(item.parentID == expectedParent)
        }
    }

    @Test func malformedCombinedCallbackDoesNotRenameBeforeFailing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try ConflictTestRemote(directory: directory)
        let client = ConflictTestClient(directory: directory.appendingPathComponent("client"), remote: remote)
        let base = try await remote.item(driveID: 7, fileID: 3)
        let executor = KDriveModificationExecutor(coordinator: client.coordinator) { try await remote.item(driveID: 7, fileID: $0) }
        await #expect(throws: (any Error).self) {
            try await executor.execute(fileID: 3, filename: "Incorrect.txt",
                baseVersion: KDriveItemBaseVersion(contentVersion: base.contentVersion, metadataVersion: base.metadataVersion),
                fields: [.contents, .filename], destinationParentID: nil, requestsTrash: false,
                modificationDate: nil, hasContents: false) { throw CancellationError() }
        }
        #expect(await remote.operations().isEmpty)
        #expect(try await remote.item(driveID: 7, fileID: 3) == base)
    }

    @Test(arguments: [false, true])
    func vaultCombinedTrashUsesCommittedRevisionsAndPreservesUnsupportedFields(failUpload: Bool) async throws {
        let current = vaultCallbackItem(revision: 1)
        let updated = vaultCallbackItem(revision: 2)
        let calls = VaultCallbackProbe()
        do {
            let result = try await VaultModificationExecutor.execute(current: current,
                fields: [.contents, .filename, .parentItemIdentifier, .tagData], requestsTrash: true,
                hasContents: true, baseContentRevision: current.contentRevision, baseMetadataRevision: current.metadataRevision,
                modify: {
                    await calls.record("modify")
                    if failUpload { throw URLError(.notConnectedToInternet) }
                    return updated
                }, trash: { content, metadata in
                    #expect(content == updated.contentRevision && metadata == updated.metadataRevision)
                    await calls.record("trash")
                })
            #expect(!failUpload)
            #expect(result.item == nil && result.trashed && result.remainingFields == [.tagData])
            #expect(await calls.values() == ["modify", "trash"])
        } catch {
            #expect(failUpload)
            #expect(await calls.values() == ["modify"])
        }
    }

    @Test func vaultUnsupportedFieldsAndDateAreNotFalselyAcknowledged() async throws {
        let current = vaultCallbackItem(revision: 1)
        let fields: NSFileProviderItemFields = [.tagData, .contentModificationDate]
        let result = try await VaultModificationExecutor.execute(current: current, fields: fields,
            requestsTrash: false, hasContents: false, baseContentRevision: current.contentRevision,
            baseMetadataRevision: current.metadataRevision,
            modify: { Issue.record("Unsupported fields must not perform a mutation"); return current },
            trash: { _, _ in Issue.record("Unexpected trash") })
        #expect(result.item == current && result.remainingFields == fields)
    }

    @Test func vaultMissingContentsCannotTrashOrModify() async throws {
        let item = vaultCallbackItem(revision: 1)
        await #expect(throws: (any Error).self) {
            try await VaultModificationExecutor.execute(current: item, fields: [.contents, .parentItemIdentifier],
                requestsTrash: true, hasContents: false, baseContentRevision: item.contentRevision,
                baseMetadataRevision: item.metadataRevision,
                modify: { Issue.record("Missing contents mutated metadata"); return item },
                trash: { _, _ in Issue.record("Missing contents were discarded by trash") })
        }
    }
}

private actor VaultCallbackProbe {
    var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
    func values() -> [String] { calls }
}
private func vaultCallbackItem(revision: UInt8) -> VaultItem {
    VaultItem(id: VaultItemIdentifier(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!),
        parentID: nil, filename: "Synthetic.txt", isDirectory: false,
        createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: Double(revision)),
        plaintextSize: 1, contentRevision: VaultRevision(data: Data(repeating: revision, count: 32))!,
        metadataRevision: VaultRevision(data: Data(repeating: revision &+ 10, count: 32))!)
}
