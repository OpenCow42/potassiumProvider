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

        let completionGate = CompletionGate()
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        progress.cancellationHandler = {
            FileProviderLog.replicatedExtension.debug("cancel fetchThumbnails(count:\(itemIdentifiers.count, privacy: .public))")
            completionGate.complete {
                completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }
        }

        Task {
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.fileProviderDomain)
                for itemIdentifier in itemIdentifiers {
                    guard progress.isCancelled == false else {
                        completionGate.complete {
                            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                        }
                        return
                    }

                    await self.fetchThumbnail(
                        for: itemIdentifier,
                        dimensions: dimensions,
                        runtime: runtime,
                        perThumbnailCompletionHandler: perThumbnailCompletionHandler
                    )
                    progress.completedUnitCount += 1
                }

                FileProviderLog.replicatedExtension.info("fetched thumbnails count(\(itemIdentifiers.count, privacy: .public))")
                completionGate.complete {
                    completionHandler(nil)
                }
            } catch {
                let mappedError = providerError(error)
                FileProviderLog.replicatedExtension.error("fetchThumbnails failed: \(mappedError.localizedDescription, privacy: .public)")
                completionGate.complete {
                    completionHandler(mappedError)
                }
            }
        }

        return progress
    }

    private func fetchThumbnail(
        for itemIdentifier: NSFileProviderItemIdentifier,
        dimensions: KDriveThumbnailDimensions,
        runtime: FileProviderRuntime,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void
    ) async {
        do {
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
            FileProviderLog.replicatedExtension.debug("fetched thumbnail for item(\(itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public)) bytes(\(data.count, privacy: .public))")
            perThumbnailCompletionHandler(itemIdentifier, data, nil)
        } catch {
            let mappedError = providerError(error)
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

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false

    func complete(_ completion: () -> Void) {
        lock.lock()
        guard isComplete == false else {
            lock.unlock()
            return
        }
        isComplete = true
        lock.unlock()

        completion()
    }
}
