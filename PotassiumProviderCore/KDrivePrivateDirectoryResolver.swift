import Foundation

public enum KDrivePrivateDirectoryResolutionError: Error, Equatable, LocalizedError, Sendable {
    case missing(driveID: Int, rootFileID: Int)
    case notDirectory(driveID: Int, rootFileID: Int, itemID: Int)
    case ambiguous(driveID: Int, rootFileID: Int, itemIDs: [Int])

    public var errorDescription: String? {
        switch self {
        case .missing(_, let rootFileID):
            return "The kDrive root folder '\(rootFileID)' does not contain its Private directory."
        case .notDirectory(_, let rootFileID, let itemID):
            return "The Private item '\(itemID)' in kDrive root folder '\(rootFileID)' is not a directory."
        case .ambiguous(_, let rootFileID, let itemIDs):
            let identifiers = itemIDs.map(String.init).joined(separator: ", ")
            return "The kDrive root folder '\(rootFileID)' contains multiple Private items (\(identifiers))."
        }
    }
}

/// Resolves the server-created kDrive directory that represents the user's private area.
///
/// kDrive v3 exposes this special directory as an ordinary root child named `Private`.
/// Its numeric identifier is drive-specific and must not be inferred from the drive root.
public enum KDrivePrivateDirectoryResolver {
    public static let directoryName = "Private"
    public static let pageSize = 200

    public static func resolveFileID(
        driveID: Int,
        rootFileID: Int,
        remote: any KDriveFileProviding
    ) async throws -> Int {
        var cursor: String?
        var seenCursors: Set<String> = []
        var namedItemsByID: [Int: KDriveRemoteItem] = [:]

        while true {
            let page = try await remote.listDirectory(
                driveID: driveID,
                folderID: rootFileID,
                cursor: cursor,
                limit: pageSize
            )

            for item in page.items where item.name == directoryName && item.parentID == rootFileID {
                namedItemsByID[item.id] = item
            }

            let nextCursor = try KDriveListingValidator.validatedNextCursor(
                currentCursor: cursor,
                nextCursor: page.nextCursor,
                hasMore: page.hasMore,
                seenCursors: &seenCursors
            )
            guard page.hasMore else {
                break
            }
            cursor = nextCursor
        }

        let namedItems = namedItemsByID.values.sorted { $0.id < $1.id }
        switch namedItems.count {
        case 0:
            throw KDrivePrivateDirectoryResolutionError.missing(
                driveID: driveID,
                rootFileID: rootFileID
            )
        case 1:
            let item = namedItems[0]
            guard item.isDirectory else {
                throw KDrivePrivateDirectoryResolutionError.notDirectory(
                    driveID: driveID,
                    rootFileID: rootFileID,
                    itemID: item.id
                )
            }
            return item.id
        default:
            throw KDrivePrivateDirectoryResolutionError.ambiguous(
                driveID: driveID,
                rootFileID: rootFileID,
                itemIDs: namedItems.map(\.id)
            )
        }
    }
}
