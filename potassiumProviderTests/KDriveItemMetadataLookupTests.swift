import Foundation
import PotassiumChannelCore
import PotassiumProviderCore
import Testing

@Suite("Active and trashed item metadata")
struct KDriveItemMetadataLookupTests {
    private static func item(id: Int = 42, driveID: Int = 7) -> KDriveRemoteItem {
        KDriveRemoteItem(id: id, name: "Synthetic.txt", type: "file", status: "ok",
            driveID: driveID, parentID: 3, path: nil, size: 4, mimeType: "text/plain",
            createdAt: nil, modifiedAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10))
    }

    private static func rejection(_ status: Int) -> APIClientError {
        .unacceptableStatusCode(status, body: "synthetic")
    }

    @Test func activeMetadataDoesNotConsultTrash() async throws {
        let calls = MetadataLookupCalls()
        let result = try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
            active: { await calls.record("active"); return Self.item() },
            trashed: { await calls.record("trash"); return Self.item() })
        #expect(result.item == Self.item())
        #expect(!result.isTrashed)
        #expect(await calls.values == ["active"])
    }

    @Test func activeNotFoundResolvesTheExactTrashIdentity() async throws {
        let calls = MetadataLookupCalls()
        let result = try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
            active: { await calls.record("active"); throw Self.rejection(404) },
            trashed: { await calls.record("trash"); return Self.item() })
        #expect(result.item == Self.item())
        #expect(result.isTrashed)
        #expect(await calls.values == ["active", "trash"])
    }

    @Test func absenceRequiresBothIdentityEndpoints() async {
        let calls = MetadataLookupCalls()
        await #expect(throws: KDriveItemMetadataLookupError.notFound) {
            try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
                active: { await calls.record("active"); throw Self.rejection(404) },
                trashed: { await calls.record("trash"); throw Self.rejection(404) })
        }
        #expect(await calls.values == ["active", "trash"])
    }

    @Test(arguments: [401, 403, 429, 500])
    func activeFailuresDoNotConsultTrash(_ status: Int) async {
        let calls = MetadataLookupCalls()
        do {
            _ = try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
                active: { throw Self.rejection(status) },
                trashed: { await calls.record("trash"); return Self.item() })
            Issue.record("Expected the original active metadata error")
        } catch {
            #expect(KDriveRemoteErrorClassifier.apiRejection(from: error)?.statusCode == status)
        }
        #expect(await calls.values.isEmpty)
    }

    @Test(arguments: [401, 403, 429, 500])
    func trashFailuresDoNotEstablishAbsence(_ status: Int) async {
        do {
            _ = try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
                active: { throw Self.rejection(404) }, trashed: { throw Self.rejection(status) })
            Issue.record("Expected the original Trash metadata error")
        } catch {
            #expect(KDriveRemoteErrorClassifier.apiRejection(from: error)?.statusCode == status)
        }
    }

    @Test func unavailableTrashLookupDoesNotEstablishAbsence() async {
        await #expect(throws: KDriveItemMetadataLookupError.trashLookupUnavailable) {
            try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
                active: { throw Self.rejection(404) },
                trashed: { throw KDriveItemMetadataLookupError.trashLookupUnavailable })
        }
    }

    @Test(arguments: [false, true], [false, true])
    func mismatchedIdentityIsRejected(inTrash: Bool, wrongDrive: Bool) async {
        let wrong = Self.item(id: wrongDrive ? 42 : 43, driveID: wrongDrive ? 8 : 7)
        await #expect(throws: KDriveItemMetadataLookupError.identityMismatch) {
            try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
                active: { if inTrash { throw Self.rejection(404) }; return wrong }, trashed: { wrong })
        }
    }

    @Test func cancellationBetweenLookupsPreventsTrashRequest() async {
        let calls = MetadataLookupCalls()
        let task = Task {
            try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
                active: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw Self.rejection(404)
                }, trashed: { await calls.record("trash"); return Self.item() })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.values.isEmpty)
    }

    @Test func transportAndCancellationErrorsArePreserved() async {
        let calls = MetadataLookupCalls()
        await #expect(throws: URLError(.notConnectedToInternet)) {
            try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
                active: { throw URLError(.notConnectedToInternet) },
                trashed: { await calls.record("trash"); return Self.item() })
        }
        await #expect(throws: CancellationError.self) {
            try await KDriveItemMetadataLookup.resolve(driveID: 7, fileID: 42,
                active: { throw CancellationError() },
                trashed: { await calls.record("trash"); return Self.item() })
        }
        #expect(await calls.values.isEmpty)
    }
}

private actor MetadataLookupCalls {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
