import FileProvider
import Foundation
import ImageIO
import InfomaniakConcurrency
import OSLog
import PotassiumProviderCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

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
                try Task.checkCancellation()

                try await itemIdentifiers.concurrentForEach(customConcurrency: Self.maximumConcurrentContentFetches) { itemIdentifier in
                    try Task.checkCancellation()
                    try await self.fetchThumbnail(
                        for: itemIdentifier,
                        dimensions: dimensions,
                        runtime: loadedRuntime,
                        perThumbnailCompletionHandler: perThumbnailCompletionHandler
                    )
                    progress.completedUnitCount += 1
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
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void
    ) async throws {
        try Task.checkCancellation()
        do {
            if let vault = runtime.encryptedVault {
                guard let identifier = VaultItemIdentifier(
                    fileProviderIdentifier: itemIdentifier.rawValue
                ) else {
                    perThumbnailCompletionHandler(itemIdentifier, nil, nil)
                    return
                }
                let item = try await vault.item(identifier)
                guard item.isDirectory == false else {
                    perThumbnailCompletionHandler(itemIdentifier, nil, nil)
                    return
                }
                let plaintextURL = try operationTemporaryDirectoryURL()
                    .appendingPathComponent("thumbnail-\(UUID().uuidString)")
                    .appendingPathExtension((item.filename as NSString).pathExtension)
                defer { try? FileManager.default.removeItem(at: plaintextURL) }
                _ = try await vault.fetchContent(
                    itemID: identifier,
                    expectedRevision: item.contentRevision,
                    to: plaintextURL
                )
                let data = try await localThumbnailData(
                    fileURL: plaintextURL,
                    dimensions: dimensions
                )
                try Task.checkCancellation()
                perThumbnailCompletionHandler(itemIdentifier, data, nil)
                return
            }
            let identifier = try KDriveItemIdentifier(rawValue: itemIdentifier.rawValue)
            guard case let .item(fileID) = identifier else {
                perThumbnailCompletionHandler(itemIdentifier, nil, nil)
                return
            }

            let data = try await runtime.remote.thumbnail(
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

    private func localThumbnailData(
        fileURL: URL,
        dimensions: KDriveThumbnailDimensions
    ) async throws -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: dimensions.width, height: dimensions.height),
            scale: 1,
            representationTypes: .thumbnail
        )
        let representation = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<QLThumbnailRepresentation?, Error>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(
                for: request
            ) { representation, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: representation)
                }
            }
        }
        guard let image = representation?.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
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
