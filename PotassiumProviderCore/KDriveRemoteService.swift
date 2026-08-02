import Foundation
import OSLog
import PotassiumChannelCore
import PotassiumKDrive

public protocol KDriveItemMetadataProviding: Sendable {
    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem
}

public protocol KDriveFileProviding: KDriveItemMetadataProviding {
    func listDrives() async throws -> [KDriveDriveSummary]
    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage
    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage
    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage
    func downloadFile(driveID: Int, fileID: Int) async throws -> Data
    func downloadFileOperation(driveID: Int, fileID: Int) throws -> KDriveTransferOperation<Data>
    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data
    func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy,
        clientToken: String?,
        contentHash: String?
    ) async throws -> KDriveRemoteItem
    func uploadFileOperation(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy,
        clientToken: String?,
        contentHash: String?
    ) throws -> KDriveTransferOperation<KDriveRemoteItem>
    func replaceFile(
        driveID: Int,
        fileID: Int,
        expectedETag: String,
        clientToken: String,
        contentHash: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem
    func replaceFileOperation(
        driveID: Int,
        fileID: Int,
        expectedETag: String,
        clientToken: String,
        contentHash: String,
        contents: Data,
        lastModifiedAt: Date?
    ) throws -> KDriveTransferOperation<KDriveRemoteItem>
    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem
    func renameItem(driveID: Int, fileID: Int, name: String) async throws
    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws
    func updateModificationDate(driveID: Int, fileID: Int, date: Date) async throws
    func trashItem(driveID: Int, fileID: Int) async throws
    func deleteTrashedItem(driveID: Int, fileID: Int) async throws
}

/// Provider-facing view of one observable, cancellable content transfer.
public final class KDriveTransferOperation<Output: Sendable>: @unchecked Sendable {
    public let progress: Progress

    private let valueProvider: @Sendable () async throws -> Output
    private let cancellation: @Sendable () -> Void

    public init(
        progress: Progress,
        value: @escaping @Sendable () async throws -> Output,
        cancellation: @escaping @Sendable () -> Void = {}
    ) {
        self.progress = progress
        self.valueProvider = value
        self.cancellation = cancellation
    }

    public var value: Output {
        get async throws {
            try await valueProvider()
        }
    }

    public func cancel() {
        if progress.isCancelled == false {
            progress.cancel()
        }
        cancellation()
    }
}

public extension KDriveFileProviding {
    func downloadFileOperation(driveID: Int, fileID: Int) throws -> KDriveTransferOperation<Data> {
        let progress = Progress(totalUnitCount: -1)
        return KDriveTransferOperation(progress: progress) {
            let data = try await downloadFile(driveID: driveID, fileID: fileID)
            progress.totalUnitCount = Int64(max(data.count, 1))
            progress.completedUnitCount = progress.totalUnitCount
            return data
        }
    }

    func uploadFileOperation(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy,
        clientToken: String?,
        contentHash: String?
    ) throws -> KDriveTransferOperation<KDriveRemoteItem> {
        let progress = Progress(totalUnitCount: Int64(max(contents.count, 1)))
        return KDriveTransferOperation(progress: progress) {
            let item = try await uploadFile(
                driveID: driveID,
                parentID: parentID,
                fileName: fileName,
                contents: contents,
                lastModifiedAt: lastModifiedAt,
                conflictStrategy: conflictStrategy,
                clientToken: clientToken,
                contentHash: contentHash
            )
            progress.completedUnitCount = progress.totalUnitCount
            return item
        }
    }

    func replaceFileOperation(
        driveID: Int,
        fileID: Int,
        expectedETag: String,
        clientToken: String,
        contentHash: String,
        contents: Data,
        lastModifiedAt: Date?
    ) throws -> KDriveTransferOperation<KDriveRemoteItem> {
        let progress = Progress(totalUnitCount: Int64(max(contents.count, 1)))
        return KDriveTransferOperation(progress: progress) {
            let item = try await replaceFile(
                driveID: driveID,
                fileID: fileID,
                expectedETag: expectedETag,
                clientToken: clientToken,
                contentHash: contentHash,
                contents: contents,
                lastModifiedAt: lastModifiedAt
            )
            progress.completedUnitCount = progress.totalUnitCount
            return item
        }
    }
}

public enum KDriveUploadConflictStrategy: String, Sendable {
    case error
    case version
    case rename
}

public struct PotassiumKDriveService: KDriveFileProviding, KDriveWorkingSetRemoteProviding, KDriveContextActionProviding {
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
        try await performNetworkOperation("listDrives") {
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
    }

    public func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        try await performNetworkOperation("item") {
            try await service.getFile(driveId: driveID, fileId: fileID, with: "etag").data.remoteItem
        }
    }

    public func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        try await performNetworkOperation("listDirectory") {
            let response = try await service.listDirectoryFiles(
                driveId: driveID,
                fileId: folderID,
                with: "etag",
                options: ListKDriveDirectoryFilesOptions(cursor: cursor, limit: limit, orderBy: ["name"], order: "asc")
            )
            return KDriveItemPage(items: response.data.map(\.remoteItem), nextCursor: response.cursor, hasMore: response.hasMore)
        }
    }

    public func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage {
        let orderBy = ["type", "name"]
        let orderFor = ["type": "asc", "name": "asc"]

        return try await performNetworkOperation("listAdvancedDirectory") {
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
                actions: response.data.actionsNewestFirst.map {
                    KDriveRemoteFileAction(action: $0.action, fileID: $0.fileId, parentID: $0.parentId)
                },
                actionItems: response.data.actionsFiles.map(\.remoteItem),
                nextCursor: response.cursor,
                hasMore: response.hasMore
            )
        }
    }

    public func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        try await performNetworkOperation("listTrash") {
            let response = try await service.listTrashFiles(
                driveId: driveID,
                with: "etag",
                options: ListKDriveTrashOptions(cursor: cursor, limit: limit, orderBy: ["name"], order: "asc")
            )
            return KDriveItemPage(items: response.data.map(\.remoteItem), nextCursor: response.cursor, hasMore: response.hasMore)
        }
    }

    public func listWorkingSetRelevantItems(driveID: Int, latestLimit: Int) async throws -> [KDriveRemoteItem] {
        try await performNetworkOperation("listWorkingSetRelevantItems") {
            let latest = try await service.listLastModifiedFiles(driveId: driveID, with: "etag", limit: latestLimit).data
            let favorites = try await service.listFavoriteFiles(driveId: driveID, with: "etag", limit: latestLimit).data
            let myShared = try await service.listMySharedFiles(driveId: driveID, with: "etag", limit: latestLimit).data
            let sharedWithMe = try await service.listSharedWithMeFiles(driveId: driveID, with: "etag", limit: latestLimit).data
            var itemsByID: [Int: KDriveRemoteItem] = [:]
            for item in latest + favorites + myShared + sharedWithMe {
                itemsByID[item.id] = item.remoteItem
            }
            return itemsByID.values.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
        }
    }

    public func listPartialActivities(
        driveID: Int,
        fileIDs: [Int],
        since: Date
    ) async throws -> [KDrivePartialActivityResult] {
        guard fileIDs.isEmpty == false else { return [] }
        return try await performNetworkOperation("listPartialActivities") {
            let response = try await service.listPartialFileActivities(
                driveId: driveID,
                with: "file,file.etag",
                options: ListKDrivePartialFileActivitiesOptions(
                    actions: [
                        "file_create", "file_delete", "file_trash", "file_restore",
                        "file_update", "file_rename", "file_move", "file_move_out",
                        "file_favorite_create", "file_favorite_remove",
                        "file_share_create", "file_share_update", "file_share_delete",
                    ],
                    files: fileIDs.map {
                        KDrivePartialFileActivityRequestFile(
                            id: $0,
                            fromDate: Int(since.timeIntervalSince1970)
                        )
                    }
                )
            )
            return response.data.map {
                KDrivePartialActivityResult(
                    fileID: $0.fileId,
                    lastAction: $0.lastAction,
                    lastActionAt: $0.lastActionAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    item: $0.file?.remoteItem
                )
            }
        }
    }

    public func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        try await downloadFileOperation(driveID: driveID, fileID: fileID).value
    }

    public func downloadFileOperation(driveID: Int, fileID: Int) throws -> KDriveTransferOperation<Data> {
        let operation = try service.downloadFile(driveId: driveID, fileId: fileID)
        return KDriveTransferOperation(
            progress: operation.progress,
            value: {
                try await performNetworkOperation("downloadFile") {
                    try await operation.value
                }
            },
            cancellation: operation.cancel
        )
    }

    public func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data {
        try await performNetworkOperation("thumbnail") {
            try await service.getFileThumbnail(
                driveId: driveID,
                fileId: fileID,
                options: GetKDriveFileThumbnailOptions(height: height, width: width)
            ).value
        }
    }

    public func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy,
        clientToken: String? = nil,
        contentHash: String? = nil
    ) async throws -> KDriveRemoteItem {
        try await uploadFileOperation(
            driveID: driveID,
            parentID: parentID,
            fileName: fileName,
            contents: contents,
            lastModifiedAt: lastModifiedAt,
            conflictStrategy: conflictStrategy,
            clientToken: clientToken,
            contentHash: contentHash
        ).value
    }

    public func uploadFileOperation(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy,
        clientToken: String? = nil,
        contentHash: String? = nil
    ) throws -> KDriveTransferOperation<KDriveRemoteItem> {
        let operation = try service.uploadFile(
            driveId: driveID,
            data: contents,
            options: UploadKDriveFileOptions(
                with: "etag",
                clientToken: clientToken,
                conflict: conflictStrategy.rawValue,
                directoryId: parentID,
                fileName: fileName,
                lastModifiedAt: lastModifiedAt.map(Self.unixTimestamp),
                totalChunkHash: contentHash
            )
        )
        return KDriveTransferOperation(
            progress: operation.progress,
            value: {
                try await performNetworkOperation("uploadFile") {
                    try await operation.value.data.remoteItem
                }
            },
            cancellation: operation.cancel
        )
    }

    public func replaceFile(
        driveID: Int,
        fileID: Int,
        expectedETag: String,
        clientToken: String,
        contentHash: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem {
        try await replaceFileOperation(
            driveID: driveID,
            fileID: fileID,
            expectedETag: expectedETag,
            clientToken: clientToken,
            contentHash: contentHash,
            contents: contents,
            lastModifiedAt: lastModifiedAt
        ).value
    }

    public func replaceFileOperation(
        driveID: Int,
        fileID: Int,
        expectedETag: String,
        clientToken: String,
        contentHash: String,
        contents: Data,
        lastModifiedAt: Date?
    ) throws -> KDriveTransferOperation<KDriveRemoteItem> {
        let operation = try service.uploadFile(
            driveId: driveID,
            data: contents,
            options: UploadKDriveFileOptions(
                with: "etag",
                ifMatch: expectedETag,
                clientToken: clientToken,
                fileId: fileID,
                lastModifiedAt: lastModifiedAt.map(Self.unixTimestamp),
                totalChunkHash: contentHash
            )
        )
        return KDriveTransferOperation(
            progress: operation.progress,
            value: {
                try await performNetworkOperation("replaceFile") {
                    try await operation.value.data.remoteItem
                }
            },
            cancellation: operation.cancel
        )
    }

    public func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        try await performNetworkOperation("createDirectory") {
            try await service.createDirectory(
                driveId: driveID,
                fileId: parentID,
                options: CreateKDriveDirectoryOptions(name: name)
            ).data.remoteItem
        }
    }

    public func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        _ = try await performNetworkOperation("renameItem") {
            try await service.renameFile(driveId: driveID, fileId: fileID, options: RenameKDriveFileOptions(name: name))
        }
    }

    public func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws {
        _ = try await performNetworkOperation("moveItem") {
            try await service.moveFile(
                driveId: driveID,
                fileId: fileID,
                destinationDirectoryId: destinationParentID,
                options: MoveKDriveFileOptions(conflict: "rename", name: name)
            )
        }
    }

    public func updateModificationDate(driveID: Int, fileID: Int, date: Date) async throws {
        _ = try await performNetworkOperation("updateModificationDate") {
            try await service.updateFileLastModified(
                driveId: driveID,
                fileId: fileID,
                lastModifiedAt: Self.unixTimestamp(date)
            )
        }
    }

    public func trashItem(driveID: Int, fileID: Int) async throws {
        _ = try await performNetworkOperation("trashItem") {
            try await service.trashFileV2(driveId: driveID, fileId: fileID)
        }
    }

    public func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        _ = try await performNetworkOperation("deleteTrashedItem") {
            try await service.removeTrashedFile(driveId: driveID, fileId: fileID)
        }
    }

    public func setFavorite(driveID: Int, fileID: Int, isFavorite: Bool) async throws {
        _ = try await performNetworkOperation(isFavorite ? "favoriteItem" : "unfavoriteItem") {
            if isFavorite {
                try await service.favoriteFile(driveId: driveID, fileId: fileID)
            } else {
                try await service.unfavoriteFile(driveId: driveID, fileId: fileID)
            }
        }
    }

    public func duplicateItem(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        try await performNetworkOperation("duplicateItem") {
            try await service.duplicateFile(driveId: driveID, fileId: fileID).data.remoteItem
        }
    }

    public func trashedItem(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        try await performNetworkOperation("trashedItem") {
            try await service.getTrashedFile(driveId: driveID, fileId: fileID).data.remoteItem
        }
    }

    public func existingFileIDs(driveID: Int, fileIDs: [Int]) async throws -> Set<Int> {
        guard fileIDs.isEmpty == false else { return [] }
        return try await performNetworkOperation("existingFileIDs") {
            Set(try await service.checkFilesExistence(driveId: driveID, fileIds: fileIDs).data.lazy
                .filter(\.result)
                .map(\.id))
        }
    }

    public func restoreTrashedItem(driveID: Int, fileID: Int, destinationParentID: Int) async throws {
        _ = try await performNetworkOperation("restoreTrashedItem") {
            try await service.restoreTrashedFile(
                driveId: driveID,
                fileId: fileID,
                destinationDirectoryId: destinationParentID
            )
        }
    }

    public func shareLink(driveID: Int, fileID: Int) async throws -> KDriveShareLinkSummary? {
        do {
            return try await performNetworkOperation("shareLink") {
                try Self.shareLinkSummary(
                    try await service.getFileShareLink(driveId: driveID, fileId: fileID).data
                )
            }
        } catch APIClientError.unacceptableStatusCode(let statusCode, _, _) where statusCode == 404 {
            return nil
        }
    }

    public func createShareLink(
        driveID: Int,
        fileID: Int,
        configuration: KDriveShareLinkConfiguration
    ) async throws -> KDriveShareLinkSummary {
        guard configuration.isValid else {
            throw KDriveContextActionError.passwordRequired
        }
        return try await performNetworkOperation("createShareLink") {
            let link = try await service.createFileShareLink(
                driveId: driveID,
                fileId: fileID,
                options: Self.createShareLinkOptions(configuration)
            ).data
            return try Self.shareLinkSummary(link)
        }
    }

    public func updateShareLink(
        driveID: Int,
        fileID: Int,
        configuration: KDriveShareLinkConfiguration
    ) async throws -> KDriveShareLinkSummary {
        _ = try await performNetworkOperation("updateShareLink") {
            try await service.updateFileShareLink(
                driveId: driveID,
                fileId: fileID,
                options: Self.updateShareLinkOptions(configuration)
            )
        }
        guard let link = try await shareLink(driveID: driveID, fileID: fileID) else {
            throw KDriveContextActionError.invalidShareLinkURL
        }
        return link
    }

    public func deleteShareLink(driveID: Int, fileID: Int) async throws {
        _ = try await performNetworkOperation("deleteShareLink") {
            try await service.deleteFileShareLink(driveId: driveID, fileId: fileID)
        }
    }

    public func fileVersions(
        driveID: Int,
        fileID: Int,
        page: Int,
        pageSize: Int
    ) async throws -> KDriveFileVersionPage {
        try await performNetworkOperation("fileVersions") {
            let response = try await service.listFileVersions(
                driveId: driveID,
                fileId: fileID,
                page: page,
                perPage: pageSize,
                total: true,
                orderBy: "created_at",
                order: "desc"
            )
            let resolvedPage = response.page ?? page
            let versions = response.data.map { version in
                KDriveFileVersionSummary(
                    id: version.id,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(version.createdAt)),
                    modifiedAt: version.lastModifiedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    size: version.size,
                    mimeType: version.mimeType,
                    editorDisplayName: Self.displayName(for: version.updatedBy),
                    isKeptForever: version.keepForever
                )
            }
            let hasMore = response.pages.map { resolvedPage < $0 } ?? (versions.count == pageSize)
            return KDriveFileVersionPage(versions: versions, page: resolvedPage, hasMore: hasMore)
        }
    }

    public func restoreFileVersion(
        driveID: Int,
        fileID: Int,
        versionID: Int,
        destinationParentID: Int,
        name: String
    ) async throws -> KDriveRemoteItem {
        let restoredID = try await performNetworkOperation("restoreFileVersion") {
            try await service.restoreFileVersionToDirectory(
                driveId: driveID,
                fileId: fileID,
                versionId: versionID,
                destinationDirectoryId: destinationParentID,
                options: RestoreKDriveFileVersionToDirectoryOptions(name: name)
            ).data.id
        }
        return try await item(driveID: driveID, fileID: restoredID)
    }

    private static func createShareLinkOptions(
        _ configuration: KDriveShareLinkConfiguration
    ) -> CreateKDriveFileShareLinkOptions {
        CreateKDriveFileShareLinkOptions(
            right: configuration.access.rawValue,
            canComment: configuration.allowsComments,
            canDownload: configuration.allowsDownload,
            canEdit: configuration.allowsEditing,
            canRequestAccess: configuration.allowsAccessRequests,
            canSeeInfo: configuration.showsFileInformation,
            canSeeStats: configuration.showsStatistics,
            password: configuration.access == .password ? configuration.password : nil,
            validUntil: configuration.validUntil.map(unixTimestamp)
        )
    }

    private static func updateShareLinkOptions(
        _ configuration: KDriveShareLinkConfiguration
    ) -> UpdateKDriveFileShareLinkOptions {
        UpdateKDriveFileShareLinkOptions(
            canComment: configuration.allowsComments,
            canDownload: configuration.allowsDownload,
            canEdit: configuration.allowsEditing,
            canRequestAccess: configuration.allowsAccessRequests,
            canSeeInfo: configuration.showsFileInformation,
            canSeeStats: configuration.showsStatistics,
            password: configuration.access == .password ? configuration.password : nil,
            right: configuration.access.rawValue,
            validUntil: configuration.validUntil.map(unixTimestamp)
        )
    }

    private static func shareLinkSummary(_ link: KDriveShareLink) throws -> KDriveShareLinkSummary {
        guard let url = URL(string: link.url) else {
            throw KDriveContextActionError.invalidShareLinkURL
        }
        let access = KDriveShareLinkConfiguration.Access(rawValue: link.right) ?? .public
        return KDriveShareLinkSummary(
            url: url,
            configuration: KDriveShareLinkConfiguration(
                access: access,
                validUntil: link.validUntil.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                allowsDownload: link.capabilities.canDownload,
                allowsComments: link.capabilities.canComment,
                allowsEditing: link.capabilities.canEdit,
                allowsAccessRequests: link.capabilities.canRequestAccess,
                showsFileInformation: link.capabilities.canSeeInfo,
                showsStatistics: link.capabilities.canSeeStats
            ),
            viewCount: link.views
        )
    }

    private static func displayName(for user: KDriveUser) -> String {
        if let displayName = user.displayName, displayName.isEmpty == false {
            return displayName
        }
        let components = [user.firstName, user.lastName].compactMap { $0 }.filter { $0.isEmpty == false }
        return components.isEmpty ? "Unknown editor" : components.joined(separator: " ")
    }

    private func performNetworkOperation<Value>(
        _ operation: String,
        _ work: () async throws -> Value
    ) async throws -> Value {
        let correlationID = UUID().uuidString
        let startedAt = Date()
        ProviderLog.network.debug("network start operation(\(operation, privacy: .public)) correlationID(\(correlationID, privacy: .public))")

        do {
            let value = try await work()
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            ProviderLog.network.info("network success operation(\(operation, privacy: .public)) correlationID(\(correlationID, privacy: .public)) durationMilliseconds(\(durationMilliseconds, privacy: .public))")
            return value
        } catch {
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            let statusCode = KDriveRemoteErrorClassifier.apiRejection(from: error)?.statusCode
            let nsError = error as NSError
            ProviderLog.network.error("network failure operation(\(operation, privacy: .public)) correlationID(\(correlationID, privacy: .public)) durationMilliseconds(\(durationMilliseconds, privacy: .public)) httpStatusCode(\(statusCode ?? 0, privacy: .public)) errorDomain(\(nsError.domain, privacy: .public)) errorCode(\(nsError.code, privacy: .public))")
            throw error
        }
    }

    private static func unixTimestamp(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }
}

public enum KDriveRemoteErrorClassifier {
    public static func apiRejection(from error: Error) -> KDriveRemoteAPIRejection? {
        guard case let APIClientError.unacceptableStatusCode(statusCode, body, _) = error else {
            return nil
        }

        return KDriveRemoteAPIRejection(statusCode: statusCode, responseBody: body)
    }

    public static func isInvalidCursor(_ error: Error) -> Bool {
        guard case let APIClientError.unacceptableStatusCode(_, body, _) = error else {
            return false
        }

        let lowercasedBody = body.lowercased()
        return lowercasedBody.contains("invalid") && lowercasedBody.contains("cursor")
    }

    /// Infomaniak documents `If-Match` support for uploads but does not specify
    /// one exclusive rejection status. Accept both standard conflict responses.
    public static func isConditionalConflict(_ error: Error) -> Bool {
        guard let rejection = apiRejection(from: error) else { return false }
        return rejection.statusCode == 409 || rejection.statusCode == 412
    }

    public static func isNotFound(_ error: Error) -> Bool {
        apiRejection(from: error)?.statusCode == 404
    }

    public static func isNameCollision(_ error: Error) -> Bool {
        guard let rejection = apiRejection(from: error) else {
            return false
        }
        // A conflict response is unambiguous in the create/rename call sites
        // that use this classifier. Do not make safe automatic renaming depend
        // on the server returning a particular localized response body.
        if rejection.statusCode == 409 {
            return true
        }
        guard rejection.statusCode == 422 else { return false }
        let body = rejection.responseBody.lowercased()
        return body.contains("collision")
            || body.contains("already exists")
            || body.contains("name")
    }
}

public struct KDriveRemoteAPIRejection: Equatable, Sendable {
    public let statusCode: Int
    public let responseBody: String

    public init(statusCode: Int, responseBody: String) {
        self.statusCode = statusCode
        self.responseBody = responseBody
    }

    public var recovery: KDriveRemoteAPIRejectionRecovery {
        if statusCode == 401 {
            return .notAuthenticated
        }
        if isInsufficientQuota {
            return .insufficientQuota
        }
        if (500..<600).contains(statusCode) {
            return .serverUnreachable
        }
        return .cannotSynchronize
    }

    public var diagnosticSummary: String {
        "The remote API rejected the operation. HTTP \(statusCode)."
    }

    public func responseBodyPreview(maxLength: Int = 1024) -> String {
        guard responseBody.isEmpty == false else {
            return "<empty>"
        }
        guard responseBody.count > maxLength else {
            return responseBody
        }
        return "\(responseBody.prefix(maxLength))..."
    }

    private var isInsufficientQuota: Bool {
        if statusCode == 507 {
            return true
        }

        let lowercasedBody = responseBody.lowercased()
        return lowercasedBody.contains("quota")
            || lowercasedBody.contains("insufficient storage")
            || lowercasedBody.contains("not enough space")
            || lowercasedBody.contains("storage limit")
    }
}

public enum KDriveRemoteAPIRejectionRecovery: Equatable, Sendable {
    case notAuthenticated
    case serverUnreachable
    case insufficientQuota
    case cannotSynchronize
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
            isFavorite: isFavorite,
            createdAt: createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(lastModifiedAt)),
            revisedAt: revisedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
            etag: etag
        )
    }
}
