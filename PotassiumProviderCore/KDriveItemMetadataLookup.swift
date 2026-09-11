import Foundation

public enum KDriveItemMetadataLookupError: Error, Equatable {
    case notFound, identityMismatch, trashLookupUnavailable
}

/// Resolves an existing identity for metadata, including items in Trash.
/// Content and mutation preflight must continue to use active-item metadata.
public enum KDriveItemMetadataLookup {
    public struct Result: Equatable, Sendable {
        public let item: KDriveRemoteItem
        public let isTrashed: Bool
    }

    public static func resolve(
        driveID: Int,
        fileID: Int,
        active: @Sendable () async throws -> KDriveRemoteItem,
        trashed: @Sendable () async throws -> KDriveRemoteItem
    ) async throws -> Result {
        try Task.checkCancellation()
        let item: KDriveRemoteItem
        let isTrashed: Bool
        do {
            item = try await active()
            isTrashed = false
        } catch {
            try Task.checkCancellation()
            guard KDriveRemoteErrorClassifier.isNotFound(error) else { throw error }
            do {
                item = try await trashed()
                isTrashed = true
            } catch {
                try Task.checkCancellation()
                // Only absence from both identity endpoints establishes noSuchItem.
                guard KDriveRemoteErrorClassifier.isNotFound(error) else { throw error }
                throw KDriveItemMetadataLookupError.notFound
            }
        }
        try Task.checkCancellation()
        guard item.id == fileID, item.driveID == driveID else {
            throw KDriveItemMetadataLookupError.identityMismatch
        }
        return Result(item: item, isTrashed: isTrashed)
    }
}
