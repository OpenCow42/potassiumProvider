import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

extension PotassiumFileProviderExtension: NSFileProviderThumbnailing {
    public func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let dimensions = KDriveThumbnailDimensions(requestedSize: size)
        FileProviderLog.replicatedExtension.debug("fetchThumbnails(count:\(itemIdentifiers.count, privacy: .public) width:\(dimensions.width, privacy: .public) height:\(dimensions.height, privacy: .public)) domain(\(self.fileProviderDomain.identifier.rawValue, privacy: .public))")

        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))

        let task = Task {
            var runtime: FileProviderRuntime?
            do {
                let loadedRuntime = try await FileProviderRuntime.load(domain: self.fileProviderDomain)
                runtime = loadedRuntime
                let thumbnailPipeline = try await KDriveThumbnailPipelinePool.shared.pipeline()
                try Task.checkCancellation()

                try await withThrowingTaskGroup(of: Void.self) { group in
                    for itemIdentifier in itemIdentifiers {
                        group.addTask {
                            try Task.checkCancellation()
                            try await self.fetchThumbnail(
                                for: itemIdentifier,
                                dimensions: dimensions,
                                runtime: loadedRuntime,
                                thumbnailPipeline: thumbnailPipeline,
                                perThumbnailCompletionHandler: perThumbnailCompletionHandler
                            )
                        }
                    }

                    while try await group.next() != nil {
                        progress.completedUnitCount += 1
                    }
                }

                try Task.checkCancellation()
                FileProviderLog.replicatedExtension.info("fetched thumbnails count(\(itemIdentifiers.count, privacy: .public))")
                completionHandler(nil)
            } catch is CancellationError {
                completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                let mappedError = await self.recordProviderFailure(
                    error,
                    runtime: runtime,
                    fallbackKind: .thumbnail,
                    itemIdentifier: nil,
                    itemName: nil,
                    itemPath: nil,
                    summary: "fetch thumbnails."
                )
                FileProviderLog.replicatedExtension.error("fetchThumbnails failed: \(mappedError.localizedDescription, privacy: .public)")
                completionHandler(mappedError)
            }
        }
        progress.cancellationHandler = {
            FileProviderLog.replicatedExtension.debug("cancel fetchThumbnails(count:\(itemIdentifiers.count, privacy: .public))")
            task.cancel()
        }

        return progress
    }

    private func fetchThumbnail(
        for itemIdentifier: NSFileProviderItemIdentifier,
        dimensions: KDriveThumbnailDimensions,
        runtime: FileProviderRuntime,
        thumbnailPipeline: KDriveThumbnailPipeline,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void
    ) async throws {
        try Task.checkCancellation()
        do {
            guard let fileID = try await KDriveThumbnailEligibilityResolver.thumbnailFileID(
                rawItemIdentifier: itemIdentifier.rawValue,
                domainIdentifier: runtime.configuration.domainIdentifier,
                driveID: runtime.configuration.driveID,
                snapshotStore: runtime.snapshotStore,
                remote: runtime.remote
            ) else {
                FileProviderLog.replicatedExtension.debug("skip thumbnail for non-file item(\(itemIdentifier.rawValue, privacy: .public))")
                perThumbnailCompletionHandler(itemIdentifier, nil, nil)
                return
            }

            let data = try await thumbnailPipeline.thumbnail(
                domainIdentifier: runtime.configuration.domainIdentifier,
                remote: runtime.remote,
                driveID: runtime.configuration.driveID,
                fileID: fileID,
                width: dimensions.width,
                height: dimensions.height
            )
            try Task.checkCancellation()
            FileProviderLog.replicatedExtension.debug("fetched thumbnail for item(\(itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public)) bytes(\(data.count, privacy: .public))")
            perThumbnailCompletionHandler(itemIdentifier, data, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let mapping = providerErrorMapping(error)
            let mappedError = mapping.mappedError
            if shouldRecordGenericFailure(for: error) {
                await ProviderEventRecorder.recordFailure(
                    kind: .thumbnail,
                    runtime: runtime,
                    itemIdentifier: itemIdentifier.rawValue,
                    itemName: nil,
                    itemPath: nil,
                    summary: "Could not fetch a thumbnail.",
                    diagnostic: mapping.diagnostic
                )
            }
            FileProviderLog.replicatedExtension.error("fetchThumbnail(for:\(itemIdentifier.rawValue, privacy: .public)) failed: \(mappedError.localizedDescription, privacy: .public)")
            perThumbnailCompletionHandler(itemIdentifier, nil, mappedError)
        }
    }
}

private struct KDriveThumbnailDimensions {
    let width: Int
    let height: Int

    init(requestedSize size: CGSize) {
        self.width = Self.clampedPixelDimension(size.width)
        self.height = Self.clampedPixelDimension(size.height)
    }

    private static func clampedPixelDimension(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 10 }
        return min(max(Int(value.rounded(.up)), 10), 400)
    }
}
