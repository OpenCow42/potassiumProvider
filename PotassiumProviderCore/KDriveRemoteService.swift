import Foundation
import PotassiumChannelCore
import PotassiumKDrive

public protocol KDriveFileProviding: Sendable {
    func listDrives() async throws -> [KDriveDriveSummary]
    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem
    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage
    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage
    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage
    func downloadFile(driveID: Int, fileID: Int) async throws -> Data
    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data
    func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem
    func replaceFile(driveID: Int, fileID: Int, contents: Data, lastModifiedAt: Date?) async throws -> KDriveRemoteItem
    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem
    func renameItem(driveID: Int, fileID: Int, name: String) async throws
    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws
    func trashItem(driveID: Int, fileID: Int) async throws
    func deleteTrashedItem(driveID: Int, fileID: Int) async throws
}

public enum KDriveUploadConflictStrategy: String, Sendable {
    case version
    case rename
}

public struct PotassiumKDriveService: KDriveFileProviding {
    private let apiClient: InfomaniakAPIClient
    private let driveClient: InfomaniakAPIClient
    private let service: KDriveService

    public init(
        bearerToken: String,
        apiBaseURL: URL = ProviderConstants.apiBaseURL,
        driveBaseURL: URL = ProviderConstants.driveBaseURL,
        session: URLSession = .shared
    ) {
        self.apiClient = InfomaniakAPIClient(
            configuration: APIClientConfiguration(baseURL: apiBaseURL, bearerToken: bearerToken),
            session: session
        )
        self.driveClient = InfomaniakAPIClient(
            configuration: APIClientConfiguration(baseURL: driveBaseURL, bearerToken: bearerToken),
            session: session
        )
        self.service = KDriveService(client: apiClient)
    }

    public func listDrives() async throws -> [KDriveDriveSummary] {
        let response = try await driveClient.send(APIRequest<InfomaniakResponse<KDriveInitPayload>>(
            method: .get,
            path: "/2/drive/init",
            queryParameters: [QueryParameter(name: "with", value: .string("drives"))]
        ))
        return response.data.drives.map {
            KDriveDriveSummary(
                id: $0.id,
                name: $0.name,
                accountID: $0.accountId,
                role: $0.role,
                status: $0.status ?? "ok",
                isInMaintenance: $0.inMaintenance ?? false
            )
        }
    }

    public func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        try await service.getFile(driveId: driveID, fileId: fileID).data.remoteItem
    }

    public func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        let response = try await service.listDirectoryFiles(
            driveId: driveID,
            fileId: folderID,
            options: ListKDriveDirectoryFilesOptions(cursor: cursor, limit: limit, orderBy: ["name"], order: "asc")
        )
        return KDriveItemPage(items: response.data.map(\.remoteItem), nextCursor: response.cursor, hasMore: response.hasMore)
    }

    public func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage {
        let orderBy = ["type", "name"]
        let orderFor = ["type": "asc", "name": "asc"]

        let response: CursorPaginatedInfomaniakResponse<KDriveAdvancedDirectoryListing>
        if let cursor {
            response = try await service.continueAdvancedDirectoryListing(
                driveId: driveID,
                fileId: folderID,
                cursor: cursor,
                options: ContinueKDriveAdvancedDirectoryListingOptions(
                    limit: limit,
                    orderBy: orderBy,
                    orderFor: orderFor
                )
            )
        } else {
            response = try await service.listAdvancedDirectoryListing(
                driveId: driveID,
                fileId: folderID,
                options: ListKDriveAdvancedDirectoryListingOptions(
                    limit: limit,
                    orderBy: orderBy,
                    orderFor: orderFor
                )
            )
        }

        return KDriveAdvancedItemPage(
            items: response.data.files.map(\.remoteItem),
            actions: response.data.actions.map {
                KDriveRemoteFileAction(action: $0.action, fileID: $0.fileId, parentID: $0.parentId)
            },
            actionItems: response.data.actionsFiles.map(\.remoteItem),
            nextCursor: response.cursor,
            hasMore: response.hasMore
        )
    }

    public func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        let response = try await service.listTrashFiles(
            driveId: driveID,
            options: ListKDriveTrashOptions(cursor: cursor, limit: limit, orderBy: ["name"], order: "asc")
        )
        return KDriveItemPage(items: response.data.map(\.remoteItem), nextCursor: response.cursor, hasMore: response.hasMore)
    }

    public func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        try await service.downloadFile(driveId: driveID, fileId: fileID)
    }

    public func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data {
        try await service.getFileThumbnail(
            driveId: driveID,
            fileId: fileID,
            options: GetKDriveFileThumbnailOptions(height: height, width: width)
        )
    }

    public func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem {
        let response = try await service.uploadFile(
            driveId: driveID,
            data: contents,
            options: UploadKDriveFileOptions(
                conflict: conflictStrategy.rawValue,
                directoryId: parentID,
                fileName: fileName,
                lastModifiedAt: lastModifiedAt.map(Self.unixTimestamp)
            )
        )
        return response.data.remoteItem
    }

    public func replaceFile(driveID: Int, fileID: Int, contents: Data, lastModifiedAt: Date?) async throws -> KDriveRemoteItem {
        let response = try await service.uploadFile(
            driveId: driveID,
            data: contents,
            options: UploadKDriveFileOptions(
                conflict: "version",
                fileId: fileID,
                lastModifiedAt: lastModifiedAt.map(Self.unixTimestamp)
            )
        )
        return response.data.remoteItem
    }

    public func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        try await service.createDirectory(
            driveId: driveID,
            fileId: parentID,
            options: CreateKDriveDirectoryOptions(name: name)
        ).data.remoteItem
    }

    public func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        _ = try await service.renameFile(driveId: driveID, fileId: fileID, options: RenameKDriveFileOptions(name: name))
    }

    public func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws {
        _ = try await service.moveFile(
            driveId: driveID,
            fileId: fileID,
            destinationDirectoryId: destinationParentID,
            options: MoveKDriveFileOptions(conflict: "rename", name: name)
        )
    }

    public func trashItem(driveID: Int, fileID: Int) async throws {
        _ = try await service.trashFileV2(driveId: driveID, fileId: fileID)
    }

    public func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        _ = try await service.removeTrashedFile(driveId: driveID, fileId: fileID)
    }

    private static func unixTimestamp(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }
}

public enum KDriveRemoteErrorClassifier {
    public static func isInvalidCursor(_ error: Error) -> Bool {
        guard case let APIClientError.unacceptableStatusCode(_, body) = error else {
            return false
        }

        let lowercasedBody = body.lowercased()
        return lowercasedBody.contains("invalid") && lowercasedBody.contains("cursor")
    }
}

private struct KDriveInitPayload: Decodable, Sendable {
    let drives: [KDriveInitDrive]
}

private struct KDriveInitDrive: Decodable, Sendable {
    let id: Int
    let name: String
    let accountId: Int
    let role: String
    let status: String?
    let inMaintenance: Bool?
}

extension KDriveFileItem {
    var remoteItem: KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name,
            type: type,
            status: status,
            driveID: driveId,
            parentID: parentId,
            path: path,
            size: size,
            mimeType: mimeType,
            createdAt: createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(lastModifiedAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }
}
