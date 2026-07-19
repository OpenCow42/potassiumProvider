import Foundation
import PotassiumProviderCore
import Testing

@Suite
struct KDrivePrivateDirectoryResolverTests {
    @Test func resolvesPrivateDirectoryFromConfiguredRoot() async throws {
        let remote = PrivateDirectoryRemote(pages: [
            .init(expectedCursor: nil, page: KDriveItemPage(
                items: [item(id: 42, name: "Private", parentID: 900, type: "dir")],
                nextCursor: nil,
                hasMore: false
            ))
        ])

        let fileID = try await KDrivePrivateDirectoryResolver.resolveFileID(
            driveID: 10,
            rootFileID: 900,
            remote: remote
        )

        #expect(fileID == 42)
        #expect(await remote.recordedCalls() == [
            .init(driveID: 10, folderID: 900, cursor: nil, limit: 200)
        ])
    }

    @Test func exhaustivelyPagesRootBeforeResolvingPrivateDirectory() async throws {
        let remote = PrivateDirectoryRemote(pages: [
            .init(expectedCursor: nil, page: KDriveItemPage(
                items: [item(id: 7, name: "Common documents", parentID: 321, type: "dir")],
                nextCursor: "page-2",
                hasMore: true
            )),
            .init(expectedCursor: "page-2", page: KDriveItemPage(
                items: [item(id: 8, name: "Private", parentID: 321, type: "directory")],
                nextCursor: nil,
                hasMore: false
            ))
        ])

        let fileID = try await KDrivePrivateDirectoryResolver.resolveFileID(
            driveID: 11,
            rootFileID: 321,
            remote: remote
        )

        #expect(fileID == 8)
        #expect(await remote.recordedCalls().map(\.cursor) == [nil, "page-2"])
    }

    @Test func rejectsMissingPrivateDirectory() async {
        let remote = PrivateDirectoryRemote(pages: [
            .init(expectedCursor: nil, page: KDriveItemPage(items: [], nextCursor: nil, hasMore: false))
        ])

        await #expect(throws: KDrivePrivateDirectoryResolutionError.missing(driveID: 10, rootFileID: 1)) {
            try await KDrivePrivateDirectoryResolver.resolveFileID(
                driveID: 10,
                rootFileID: 1,
                remote: remote
            )
        }
    }

    @Test func rejectsNonDirectoryPrivateItem() async {
        let remote = PrivateDirectoryRemote(pages: [
            .init(expectedCursor: nil, page: KDriveItemPage(
                items: [item(id: 45, name: "Private", parentID: 1, type: "file")],
                nextCursor: nil,
                hasMore: false
            ))
        ])

        await #expect(throws: KDrivePrivateDirectoryResolutionError.notDirectory(
            driveID: 10,
            rootFileID: 1,
            itemID: 45
        )) {
            try await KDrivePrivateDirectoryResolver.resolveFileID(
                driveID: 10,
                rootFileID: 1,
                remote: remote
            )
        }
    }

    @Test func rejectsAmbiguousPrivateItemsAcrossPages() async {
        let remote = PrivateDirectoryRemote(pages: [
            .init(expectedCursor: nil, page: KDriveItemPage(
                items: [item(id: 45, name: "Private", parentID: 1, type: "dir")],
                nextCursor: "page-2",
                hasMore: true
            )),
            .init(expectedCursor: "page-2", page: KDriveItemPage(
                items: [item(id: 46, name: "Private", parentID: 1, type: "dir")],
                nextCursor: nil,
                hasMore: false
            ))
        ])

        await #expect(throws: KDrivePrivateDirectoryResolutionError.ambiguous(
            driveID: 10,
            rootFileID: 1,
            itemIDs: [45, 46]
        )) {
            try await KDrivePrivateDirectoryResolver.resolveFileID(
                driveID: 10,
                rootFileID: 1,
                remote: remote
            )
        }
    }

    @Test func rejectsMissingContinuationCursor() async {
        let remote = PrivateDirectoryRemote(pages: [
            .init(expectedCursor: nil, page: KDriveItemPage(items: [], nextCursor: nil, hasMore: true))
        ])

        await #expect(throws: KDriveListingValidationError.missingContinuationCursor) {
            try await KDrivePrivateDirectoryResolver.resolveFileID(
                driveID: 10,
                rootFileID: 1,
                remote: remote
            )
        }
    }

    private func item(id: Int, name: String, parentID: Int, type: String) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name,
            type: type,
            status: "ok",
            driveID: 10,
            parentID: parentID,
            path: "/\(name)",
            size: type == "file" ? 1 : nil,
            mimeType: type == "file" ? "application/octet-stream" : nil,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private struct PrivateDirectoryPage: Sendable {
    let expectedCursor: String?
    let page: KDriveItemPage
}

private struct PrivateDirectoryCall: Equatable, Sendable {
    let driveID: Int
    let folderID: Int
    let cursor: String?
    let limit: Int
}

private enum PrivateDirectoryRemoteError: Error {
    case unexpectedCursor(expected: String?, actual: String?)
    case unexpectedRequest
    case unimplemented
}

private actor PrivateDirectoryRemote: KDriveFileProviding {
    private var pages: [PrivateDirectoryPage]
    private var calls: [PrivateDirectoryCall] = []

    init(pages: [PrivateDirectoryPage]) {
        self.pages = pages
    }

    func recordedCalls() -> [PrivateDirectoryCall] {
        calls
    }

    func listDrives() async throws -> [KDriveDriveSummary] {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        guard pages.isEmpty == false else {
            throw PrivateDirectoryRemoteError.unexpectedRequest
        }
        let response = pages.removeFirst()
        guard response.expectedCursor == cursor else {
            throw PrivateDirectoryRemoteError.unexpectedCursor(expected: response.expectedCursor, actual: cursor)
        }
        calls.append(PrivateDirectoryCall(driveID: driveID, folderID: folderID, cursor: cursor, limit: limit))
        return response.page
    }

    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func replaceFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        throw PrivateDirectoryRemoteError.unimplemented
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        throw PrivateDirectoryRemoteError.unimplemented
    }
}
