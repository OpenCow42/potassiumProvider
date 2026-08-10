import Foundation
import PotassiumChannelCore
import PotassiumKDrive

public struct KDriveOpaqueObject: Equatable, Identifiable, Sendable {
    public let id: Int
    public let parentID: Int
    public let token: String
    public let byteCount: Int64?
    public let serverUpdatedAt: Date
    public let isContainer: Bool

    public init(
        id: Int,
        parentID: Int,
        token: String,
        byteCount: Int64?,
        serverUpdatedAt: Date,
        isContainer: Bool
    ) {
        self.id = id
        self.parentID = parentID
        self.token = token
        self.byteCount = byteCount
        self.serverUpdatedAt = serverUpdatedAt
        self.isContainer = isContainer
    }
}

public struct KDriveOpaqueObjectPage: Equatable, Sendable {
    public let objects: [KDriveOpaqueObject]
    public let nextCursor: String?

    public init(objects: [KDriveOpaqueObject], nextCursor: String?) {
        self.objects = objects
        self.nextCursor = nextCursor
    }
}

public protocol KDriveObjectStoreProviding: Sendable {
    func createContainer(parentID: Int, token: String) async throws -> KDriveOpaqueObject
    func listObjects(containerID: Int, cursor: String?) async throws -> KDriveOpaqueObjectPage
    func uploadObject(
        containerID: Int,
        token: String,
        fileURL: URL
    ) async throws -> KDriveOpaqueObject
    func downloadObject(fileID: Int, to destinationURL: URL) async throws
    func deleteObject(fileID: Int) async throws
}

public enum KDriveObjectStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidObjectToken
    case unexpectedPhysicalName(String)
    case missingHTTPResponse
    case responseRejected(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidObjectToken:
            return "The opaque object token is invalid."
        case .unexpectedPhysicalName:
            return "kDrive returned an object with a non-vault physical name."
        case .missingHTTPResponse:
            return "kDrive returned no HTTP response."
        case .responseRejected(let statusCode, _):
            return "kDrive rejected an opaque object transfer with HTTP \(statusCode)."
        }
    }
}

/// The only kDrive adapter used by encrypted domains. Uploads are backed by a
/// file URL and downloads arrive as URLSession temporary files; ciphertext is
/// never assembled in one in-memory `Data` value.
public struct PotassiumKDriveObjectStore: KDriveObjectStoreProviding {
    private let driveID: Int
    private let bearerToken: String
    private let session: URLSession
    private let client: InfomaniakAPIClient
    private let metadataService: any KDriveFileProviding

    public init(
        driveID: Int,
        bearerToken: String,
        apiBaseURL: URL = ProviderConstants.apiBaseURL,
        session: URLSession = .shared
    ) {
        self.driveID = driveID
        self.bearerToken = bearerToken
        self.session = session
        self.client = InfomaniakAPIClient(
            configuration: APIClientConfiguration(
                baseURL: apiBaseURL,
                bearerToken: bearerToken
            ),
            session: session
        )
        self.metadataService = PotassiumKDriveService(
            bearerToken: bearerToken,
            apiBaseURL: apiBaseURL,
            session: session
        )
    }

    public func createContainer(
        parentID: Int,
        token: String
    ) async throws -> KDriveOpaqueObject {
        try validateToken(token)
        let item = try await metadataService.createDirectory(
            driveID: driveID,
            parentID: parentID,
            name: token
        )
        return try opaqueObject(item, expectsContainer: true)
    }

    public func listObjects(
        containerID: Int,
        cursor: String?
    ) async throws -> KDriveOpaqueObjectPage {
        let page = try await metadataService.listDirectory(
            driveID: driveID,
            folderID: containerID,
            cursor: cursor,
            limit: 200
        )
        let nextCursor = try KDriveListingValidator.validatedNextCursor(
            currentCursor: cursor,
            nextCursor: page.nextCursor,
            hasMore: page.hasMore
        )
        return KDriveOpaqueObjectPage(
            objects: try page.items.map { try opaqueObject($0, expectsContainer: nil) },
            nextCursor: nextCursor
        )
    }

    public func uploadObject(
        containerID: Int,
        token: String,
        fileURL: URL
    ) async throws -> KDriveOpaqueObject {
        try validateToken(token)
        let byteCount = try fileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        let request = try await uploadRequest(
            containerID: containerID,
            token: token,
            byteCount: byteCount
        )
        let (responseData, response) = try await session.upload(
            for: request,
            fromFile: fileURL
        )
        try validate(response: response, responseData: responseData)
        let decoded = try InfomaniakJSONResponseDecoder().decode(
            InfomaniakResponse<KDriveFileItem>.self,
            from: responseData
        )
        return try opaqueObject(decoded.data.remoteItem, expectsContainer: false)
    }

    public func downloadObject(fileID: Int, to destinationURL: URL) async throws {
        let request = try await client.makeURLRequest(
            for: KDriveRequests.downloadFile(driveId: driveID, fileId: fileID)
        )
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response: response, responseData: Data())
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        try applyCiphertextFileProtection(to: destinationURL)
    }

    public func deleteObject(fileID: Int) async throws {
        try await metadataService.trashItem(driveID: driveID, fileID: fileID)
        try await metadataService.deleteTrashedItem(driveID: driveID, fileID: fileID)
    }

    func uploadRequest(
        containerID: Int,
        token: String,
        byteCount: Int
    ) async throws -> URLRequest {
        let placeholder = APIRequest<KDriveBinaryResponse>(
            method: .post,
            path: "/3/drive/\(driveID)/upload",
            queryParameters: [
                QueryParameter(name: "total_size", value: .integer(byteCount)),
                QueryParameter(name: "client_token", value: .string(token)),
                QueryParameter(name: "conflict", value: .string("error")),
                QueryParameter(name: "directory_id", value: .integer(containerID)),
                QueryParameter(name: "file_name", value: .string("\(token).bin")),
            ],
            headers: [
                HTTPHeader(name: "Accept", value: "application/json"),
                HTTPHeader(name: "Content-Type", value: "application/octet-stream"),
            ]
        )
        var request = try await client.makeURLRequest(for: placeholder)
        request.httpBody = nil
        // Keep the token local to URLSession's credential-free request copy.
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func opaqueObject(
        _ item: KDriveRemoteItem,
        expectsContainer: Bool?
    ) throws -> KDriveOpaqueObject {
        let token: String
        if item.isDirectory {
            token = item.name
        } else {
            guard item.name.hasSuffix(".bin") else {
                throw KDriveObjectStoreError.unexpectedPhysicalName(item.name)
            }
            token = String(item.name.dropLast(4))
        }
        try validateToken(token)
        if let expectsContainer, expectsContainer != item.isDirectory {
            throw KDriveObjectStoreError.unexpectedPhysicalName(item.name)
        }
        return KDriveOpaqueObject(
            id: item.id,
            parentID: item.parentID,
            token: token,
            byteCount: item.size.map(Int64.init),
            serverUpdatedAt: item.updatedAt,
            isContainer: item.isDirectory
        )
    }

    private func validateToken(_ token: String) throws {
        guard let bytes = Data(base64URLEncoded: token),
              bytes.count == 20 else {
            throw KDriveObjectStoreError.invalidObjectToken
        }
    }

    private func validate(response: URLResponse, responseData: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveObjectStoreError.missingHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw KDriveObjectStoreError.responseRejected(
                statusCode: httpResponse.statusCode,
                body: String(data: responseData, encoding: .utf8) ?? ""
            )
        }
    }

    private func applyCiphertextFileProtection(to url: URL) throws {
        #if canImport(Darwin)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
