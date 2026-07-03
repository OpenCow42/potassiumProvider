import Foundation
import UniformTypeIdentifiers

public struct KDriveDriveSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let accountID: Int
    public let role: String
    public let status: String
    public let isInMaintenance: Bool

    public init(id: Int, name: String, accountID: Int, role: String, status: String, isInMaintenance: Bool) {
        self.id = id
        self.name = name
        self.accountID = accountID
        self.role = role
        self.status = status
        self.isInMaintenance = isInMaintenance
    }
}

public struct KDriveRemoteItem: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let type: String?
    public let status: String
    public let driveID: Int
    public let parentID: Int
    public let path: String?
    public let size: Int?
    public let mimeType: String?
    public let createdAt: Date?
    public let modifiedAt: Date
    public let updatedAt: Date

    public init(
        id: Int,
        name: String,
        type: String?,
        status: String,
        driveID: Int,
        parentID: Int,
        path: String?,
        size: Int?,
        mimeType: String?,
        createdAt: Date?,
        modifiedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.status = status
        self.driveID = driveID
        self.parentID = parentID
        self.path = path
        self.size = size
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.updatedAt = updatedAt
    }

    public var isDirectory: Bool {
        type == "dir" || type == "directory"
    }

    public var contentType: UTType {
        if isDirectory { return .folder }
        if let mimeType, let type = UTType(mimeType: mimeType) { return type }
        let extensionType = UTType(filenameExtension: (name as NSString).pathExtension)
        return extensionType ?? .data
    }

    public var contentVersion: Data {
        Data(String(modifiedAt.timeIntervalSince1970).utf8)
    }

    public var metadataVersion: Data {
        Data("\(id)-\(updatedAt.timeIntervalSince1970)-\(name)-\(parentID)".utf8)
    }
}

public struct KDriveItemPage: Equatable, Sendable {
    public let items: [KDriveRemoteItem]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(items: [KDriveRemoteItem], nextCursor: String?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public enum KDriveItemIdentifier: Equatable, Hashable, Sendable {
    case root
    case trash
    case item(Int)

    public init(rawValue: String) throws {
        switch rawValue {
        case "NSFileProviderRootContainerItemIdentifier":
            self = .root
        case "NSFileProviderTrashContainerItemIdentifier":
            self = .trash
        default:
            guard let id = Int(rawValue), id > 0 else {
                throw KDriveItemIdentifierError.invalid(rawValue)
            }
            self = .item(id)
        }
    }

    public init(fileID: Int) {
        self = .item(fileID)
    }

    public var fileID: Int? {
        switch self {
        case .root:
            return ProviderConstants.defaultRootFileID
        case .trash:
            return nil
        case .item(let id):
            return id
        }
    }

    public var rawValue: String {
        switch self {
        case .root:
            return "NSFileProviderRootContainerItemIdentifier"
        case .trash:
            return "NSFileProviderTrashContainerItemIdentifier"
        case .item(let id):
            return String(id)
        }
    }
}

public enum KDriveItemIdentifierError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let value):
            return "'\(value)' is not a valid kDrive item identifier."
        }
    }
}
