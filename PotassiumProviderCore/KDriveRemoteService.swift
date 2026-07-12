import Foundation
import OSLog
import PotassiumChannelCore
import PotassiumKDrive

public protocol KDriveFileProviding: Sendable {
    func listDrives() async throws -> [KDriveDriveSummary]
    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem
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
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem
    func uploadFileOperation(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) throws -> KDriveTransferOperation<KDriveRemoteItem>
    func replaceFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem
    func replaceFileOperation(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) throws -> KDriveTransferOperation<KDriveRemoteItem>
    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem
    func renameItem(driveID: Int, fileID: Int, name: String) async throws
    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws
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
        conflictStrategy: KDriveUploadConflictStrategy
    ) throws -> KDriveTransferOperation<KDriveRemoteItem> {
        let progress = Progress(totalUnitCount: Int64(max(contents.count, 1)))
        return KDriveTransferOperation(progress: progress) {
            let item = try await uploadFile(
                driveID: driveID,
                parentID: parentID,
                fileName: fileName,
                contents: contents,
                lastModifiedAt: lastModifiedAt,
                conflictStrategy: conflictStrategy
            )
            progress.completedUnitCount = progress.totalUnitCount
            return item
        }
    }

    func replaceFileOperation(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) throws -> KDriveTransferOperation<KDriveRemoteItem> {
        let progress = Progress(totalUnitCount: Int64(max(contents.count, 1)))
        return KDriveTransferOperation(progress: progress) {
            let item = try await replaceFile(
                driveID: driveID,
                parentID: parentID,
                fileName: fileName,
                contents: contents,
                lastModifiedAt: lastModifiedAt
            )
            progress.completedUnitCount = progress.totalUnitCount
            return item
        }
    }
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
            try await service.getFile(driveId: driveID, fileId: fileID).data.remoteItem
        }
    }

    public func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        try await performNetworkOperation("listDirectory") {
            let response = try await service.listDirectoryFiles(
                driveId: driveID,
                fileId: folderID,
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
                actions: response.data.actions.map {
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
                options: ListKDriveTrashOptions(cursor: cursor, limit: limit, orderBy: ["name"], order: "asc")
            )
            return KDriveItemPage(items: response.data.map(\.remoteItem), nextCursor: response.cursor, hasMore: response.hasMore)
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
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem {
        try await uploadFileOperation(
            driveID: driveID,
            parentID: parentID,
            fileName: fileName,
            contents: contents,
            lastModifiedAt: lastModifiedAt,
            conflictStrategy: conflictStrategy
        ).value
    }

    public func uploadFileOperation(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) throws -> KDriveTransferOperation<KDriveRemoteItem> {
        let operation = try service.uploadFile(
            driveId: driveID,
            data: contents,
            options: UploadKDriveFileOptions(
                conflict: conflictStrategy.rawValue,
                directoryId: parentID,
                fileName: fileName,
                lastModifiedAt: lastModifiedAt.map(Self.unixTimestamp)
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
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem {
        try await replaceFileOperation(
            driveID: driveID,
            parentID: parentID,
            fileName: fileName,
            contents: contents,
            lastModifiedAt: lastModifiedAt
        ).value
    }

    public func replaceFileOperation(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) throws -> KDriveTransferOperation<KDriveRemoteItem> {
        let operation = try service.uploadFile(
            driveId: driveID,
            data: contents,
            options: UploadKDriveFileOptions(
                conflict: KDriveUploadConflictStrategy.version.rawValue,
                directoryId: parentID,
                fileName: fileName,
                lastModifiedAt: lastModifiedAt.map(Self.unixTimestamp)
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
        guard case let APIClientError.unacceptableStatusCode(statusCode, body) = error else {
            return nil
        }

        return KDriveRemoteAPIRejection(statusCode: statusCode, responseBody: body)
    }

    public static func isInvalidCursor(_ error: Error) -> Bool {
        guard case let APIClientError.unacceptableStatusCode(_, body) = error else {
            return false
        }

        let lowercasedBody = body.lowercased()
        return lowercasedBody.contains("invalid") && lowercasedBody.contains("cursor")
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
            createdAt: createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(lastModifiedAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }
}
