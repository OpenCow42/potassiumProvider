import Foundation
import OSLog
import PotassiumProviderCore

enum ThumbnailCacheInvalidation {
    static func removeCachedThumbnail(for item: KDriveRemoteItem, runtime: FileProviderRuntime) async {
        guard item.isDirectory == false else { return }
        await removeCachedThumbnail(fileID: item.id, runtime: runtime)
    }

    static func removeCachedThumbnails(
        for changes: KDriveSnapshotChangeSet,
        previousSnapshot: KDriveSnapshot?,
        runtime: FileProviderRuntime
    ) async {
        let updatedFileIDs = changes.updatedItems
            .filter { $0.isDirectory == false }
            .map(\.id)

        let deletedIDs = Set(changes.deletedItemIDs)
        let deletedFileIDs = previousSnapshot?.items
            .filter { deletedIDs.contains($0.id) && $0.isDirectory == false }
            .map(\.id) ?? []

        for fileID in Set(updatedFileIDs + deletedFileIDs) {
            await removeCachedThumbnail(fileID: fileID, runtime: runtime)
        }
    }

    private static func removeCachedThumbnail(fileID: Int, runtime: FileProviderRuntime) async {
        do {
            try await KDriveThumbnailPipelinePool.shared.removeCachedThumbnails(
                domainIdentifier: runtime.configuration.domainIdentifier,
                driveID: runtime.configuration.driveID,
                fileID: fileID
            )
            FileProviderLog.replicatedExtension.debug("invalidated thumbnail cache for domain(\(runtime.configuration.domainIdentifier, privacy: .public)) fileID(\(fileID, privacy: .public))")
        } catch {
            FileProviderLog.replicatedExtension.error("failed to invalidate thumbnail cache for domain(\(runtime.configuration.domainIdentifier, privacy: .public)) fileID(\(fileID, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
}
