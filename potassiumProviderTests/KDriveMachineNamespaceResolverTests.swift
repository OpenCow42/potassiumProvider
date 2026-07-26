import Foundation
import PotassiumProviderCore
import Testing

@Suite
struct KDriveMachineNamespaceResolverTests {
    @Test func sanitizesMacNameForKDriveAndNormalizesUnicode() throws {
        let decomposedName = " Cafe\u{301}/Office:\u{1} "

        let name = try KDriveMachineNamespaceName.sanitized(decomposedName)

        #expect(name == "Café-Office--")
        #expect(name == name.precomposedStringWithCanonicalMapping)
    }

    @Test func truncatesLongNamesOnCharacterBoundaryWithStableHashSuffix() throws {
        let longName = String(repeating: "🖥️ Studio ", count: 40)

        let first = try KDriveMachineNamespaceName.sanitized(longName)
        let second = try KDriveMachineNamespaceName.sanitized(longName)

        #expect(first == second)
        #expect(first.utf8.count <= KDriveMachineNamespaceName.maximumUTF8ByteCount)
        #expect(first.contains("�") == false)
        #expect(first.suffix(9).first == "-")
    }

    @Test func rejectsEmptyAndReservedNames() {
        #expect(throws: KDriveMachineNamespaceNameError.unusableComputerName) {
            try KDriveMachineNamespaceName.sanitized(" \n ")
        }
        #expect(throws: KDriveMachineNamespaceNameError.unusableComputerName) {
            try KDriveMachineNamespaceName.sanitized("..")
        }
        #expect(throws: KDriveMachineNamespaceNameError.unusableComputerName) {
            try KDriveMachineNamespaceName.sanitized("/:\u{1}")
        }
    }

    @Test func reusesExistingNamespaceAfterExhaustiveListing() async throws {
        let remote = MachineNamespaceRemote(
            listings: [
                page(items: [], nextCursor: "next", hasMore: true),
                page(items: [item(id: 44, name: "Studio Mac", type: "dir")]),
            ],
            creation: .failure
        )

        let namespace = try await KDriveMachineNamespaceResolver.resolveOrCreate(
            driveID: 10,
            privateDirectoryFileID: 77,
            computerName: "Studio Mac",
            remote: remote
        )

        #expect(namespace == KDriveMachineNamespace(name: "Studio Mac", fileID: 44))
        #expect(await remote.createdNames().isEmpty)
    }

    @Test func createsMissingNamespace() async throws {
        let remote = MachineNamespaceRemote(
            listings: [page(items: [])],
            creation: .item(item(id: 45, name: "Studio Mac", type: "dir"))
        )

        let namespace = try await KDriveMachineNamespaceResolver.resolveOrCreate(
            driveID: 10,
            privateDirectoryFileID: 77,
            computerName: "Studio Mac",
            remote: remote
        )

        #expect(namespace.fileID == 45)
        #expect(await remote.createdNames() == ["Studio Mac"])
    }

    @Test func relistsOnceWhenConcurrentCreateWinsRace() async throws {
        let remote = MachineNamespaceRemote(
            listings: [
                page(items: []),
                page(items: [item(id: 46, name: "Studio Mac", type: "dir")]),
            ],
            creation: .failure
        )

        let namespace = try await KDriveMachineNamespaceResolver.resolveOrCreate(
            driveID: 10,
            privateDirectoryFileID: 77,
            computerName: "Studio Mac",
            remote: remote
        )

        #expect(namespace.fileID == 46)
        #expect(await remote.listingCallCount() == 2)
    }

    @Test func failsClosedForFileCollisionAndAmbiguousDirectories() async {
        let fileRemote = MachineNamespaceRemote(
            listings: [page(items: [item(id: 47, name: "Studio Mac", type: "file")])],
            creation: .failure
        )
        await #expect(throws: KDriveMachineNamespaceResolutionError.notDirectory(
            driveID: 10,
            parentFileID: 77,
            itemID: 47,
            name: "Studio Mac"
        )) {
            try await KDriveMachineNamespaceResolver.resolveOrCreate(
                driveID: 10,
                privateDirectoryFileID: 77,
                computerName: "Studio Mac",
                remote: fileRemote
            )
        }

        let ambiguousRemote = MachineNamespaceRemote(
            listings: [page(items: [
                item(id: 48, name: "Studio Mac", type: "dir"),
                item(id: 49, name: "Studio Mac", type: "dir"),
            ])],
            creation: .failure
        )
        await #expect(throws: KDriveMachineNamespaceResolutionError.ambiguous(
            driveID: 10,
            parentFileID: 77,
            itemIDs: [48, 49],
            name: "Studio Mac"
        )) {
            try await KDriveMachineNamespaceResolver.resolveOrCreate(
                driveID: 10,
                privateDirectoryFileID: 77,
                computerName: "Studio Mac",
                remote: ambiguousRemote
            )
        }
    }

    private func page(
        items: [KDriveRemoteItem],
        nextCursor: String? = nil,
        hasMore: Bool = false
    ) -> KDriveItemPage {
        KDriveItemPage(items: items, nextCursor: nextCursor, hasMore: hasMore)
    }

    private func item(id: Int, name: String, type: String) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name,
            type: type,
            status: "ok",
            driveID: 10,
            parentID: 77,
            path: "/Private/\(name)",
            size: type == "file" ? 1 : nil,
            mimeType: type == "file" ? "application/octet-stream" : nil,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private enum MachineNamespaceCreation: Sendable {
    case item(KDriveRemoteItem)
    case failure
}

private enum MachineNamespaceRemoteError: Error {
    case createFailed
    case unexpectedRequest
    case unimplemented
}

private actor MachineNamespaceRemote: KDriveFileProviding {
    private var listings: [KDriveItemPage]
    private let creation: MachineNamespaceCreation
    private var listedCount = 0
    private var namesCreated: [String] = []

    init(listings: [KDriveItemPage], creation: MachineNamespaceCreation) {
        self.listings = listings
        self.creation = creation
    }

    func listingCallCount() -> Int {
        listedCount
    }

    func createdNames() -> [String] {
        namesCreated
    }

    func listDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveItemPage {
        guard listings.isEmpty == false else {
            throw MachineNamespaceRemoteError.unexpectedRequest
        }
        listedCount += 1
        return listings.removeFirst()
    }

    func createDirectory(
        driveID: Int,
        parentID: Int,
        name: String
    ) async throws -> KDriveRemoteItem {
        namesCreated.append(name)
        switch creation {
        case .item(let item):
            return item
        case .failure:
            throw MachineNamespaceRemoteError.createFailed
        }
    }

    func listDrives() async throws -> [KDriveDriveSummary] {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func listAdvancedDirectory(
        driveID: Int,
        folderID: Int,
        cursor: String?,
        limit: Int
    ) async throws -> KDriveAdvancedItemPage {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func replaceFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func moveItem(
        driveID: Int,
        fileID: Int,
        destinationParentID: Int,
        name: String?
    ) async throws {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        throw MachineNamespaceRemoteError.unimplemented
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        throw MachineNamespaceRemoteError.unimplemented
    }
}
