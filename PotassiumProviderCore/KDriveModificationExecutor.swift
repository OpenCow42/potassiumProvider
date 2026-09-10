import FileProvider
import Foundation

/// The production plaintext modify callback sequence. Content I/O stays injectable
/// so the extension can retain its transfer permit, progress, and staging boundary.
public struct KDriveModificationExecutor: Sendable {
    public struct Result: Sendable {
        public let item: KDriveRemoteItem?
        public let remainingFields: NSFileProviderItemFields
        public let affectedParentIDs: Set<Int>
        public let trashed: Bool
    }

    private let coordinator: KDriveMutationCoordinator
    private let lookup: @Sendable (Int) async throws -> KDriveRemoteItem

    public init(coordinator: KDriveMutationCoordinator,
                lookup: @escaping @Sendable (Int) async throws -> KDriveRemoteItem) {
        self.coordinator = coordinator
        self.lookup = lookup
    }

    public func execute(fileID: Int, filename: String, baseVersion: KDriveItemBaseVersion,
                        fields: NSFileProviderItemFields, destinationParentID: Int?,
                        requestsTrash: Bool, modificationDate: Date?, hasContents: Bool,
                        applyContents: @Sendable () async throws -> KDriveContentMutationResult) async throws -> Result {
        try Task.checkCancellation()
        // Reject malformed callbacks before applying any metadata changes.
        if fields.contains(.contents), !hasContents { throw NSFileProviderError(.cannotSynchronize) }
        var remaining = fields
        var updated: KDriveRemoteItem?
        var parents = Set([KDriveItemMetadataVersion(data: baseVersion.metadataVersion)?.parentID].compactMap { $0 })
        if fields.contains(.parentItemIdentifier), !requestsTrash {
            guard let destinationParentID else { throw NSFileProviderError(.cannotSynchronize) }
            updated = try await coordinator.moveItem(fileID: fileID, baseMetadataVersion: baseVersion.metadataVersion,
                destinationParentID: destinationParentID, name: fields.contains(.filename) ? filename : nil)
            remaining.subtract([.parentItemIdentifier, .filename])
            parents.insert(destinationParentID)
        } else if fields.contains(.filename) {
            updated = try await coordinator.renameItem(fileID: fileID, baseMetadataVersion: baseVersion.metadataVersion, name: filename)
            remaining.remove(.filename)
        }
        if let updated { parents.insert(updated.parentID) }
        try Task.checkCancellation()
        if fields.contains(.contents) {
            updated = try await applyContents().item
            remaining.subtract([.contents, .contentModificationDate])
        } else if fields.contains(.contentModificationDate), let modificationDate {
            updated = try await coordinator.updateModificationDate(fileID: fileID, date: modificationDate)
            remaining.remove(.contentModificationDate)
        }
        if let updated { parents.insert(updated.parentID) }
        try Task.checkCancellation()
        if requestsTrash {
            let original = try await coordinator.trashItem(fileID: fileID, baseVersion: baseVersion)
            parents.insert(original.parentID)
            if let updated, updated.id != fileID {
                _ = try await coordinator.trashItem(fileID: updated.id,
                    baseVersion: KDriveItemBaseVersion(contentVersion: updated.contentVersion, metadataVersion: updated.metadataVersion))
            }
            remaining.remove(.parentItemIdentifier)
            return Result(item: nil, remainingFields: remaining, affectedParentIDs: parents, trashed: true)
        }
        let result: KDriveRemoteItem
        if let updated { result = updated } else { result = try await lookup(fileID) }
        if result.isDirectory { parents.insert(result.id) }
        return Result(item: result, remainingFields: remaining, affectedParentIDs: parents, trashed: false)
    }
}
