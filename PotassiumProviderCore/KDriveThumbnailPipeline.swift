import Foundation
import Nuke

public struct KDriveThumbnailPipeline: Sendable {
    public static let maximumConcurrentRemoteFetches = 4
    public static let diskCacheSizeLimit = 64 * 1024 * 1024
    public static let cacheDirectoryName = "ThumbnailCache"

    private let pipeline: ImagePipeline
    private let dataCache: DataCache

    public init(
        cacheDirectoryURL: URL,
        diskCacheSizeLimit: Int = Self.diskCacheSizeLimit,
        maximumConcurrentRemoteFetches: Int = Self.maximumConcurrentRemoteFetches
    ) throws {
        let dataCache = try DataCache(path: cacheDirectoryURL, filenameGenerator: Self.cacheFilename(for:))
        dataCache.sizeLimit = diskCacheSizeLimit

        var configuration = ImagePipeline.Configuration()
        configuration.dataCache = dataCache
        configuration.dataCachePolicy = .storeOriginalData
        configuration.dataLoadingQueue = TaskQueue(maxConcurrentOperationCount: maximumConcurrentRemoteFetches)
        configuration.isResumableDataEnabled = false

        self.pipeline = ImagePipeline(configuration: configuration)
        self.dataCache = dataCache
    }

    public static func cacheDirectory(appGroupIdentifier: String = ProviderConstants.appGroupIdentifier) throws -> URL {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw KDriveSnapshotStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        return containerURL.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    public func thumbnail(
        domainIdentifier: String,
        remote: any KDriveFileProviding,
        driveID: Int,
        fileID: Int,
        width: Int,
        height: Int
    ) async throws -> Data {
        let request = ImageRequest(
            id: Self.cacheIdentifier(
                domainIdentifier: domainIdentifier,
                driveID: driveID,
                fileID: fileID,
                width: width,
                height: height
            ),
            data: {
                try await remote.thumbnail(driveID: driveID, fileID: fileID, width: width, height: height)
            }
        )

        do {
            return try await pipeline.data(for: request).0
        } catch {
            throw Self.unwrappedPipelineError(error)
        }
    }

    public func removeCachedThumbnails(domainIdentifier: String, driveID: Int, fileID: Int) throws {
        dataCache.flush()
        try Self.removeCachedFiles(
            cacheDirectoryURL: dataCache.path,
            filenamePrefix: Self.cacheFilenamePrefix(
                domainIdentifier: domainIdentifier,
                driveID: driveID,
                fileID: fileID
            )
        )
    }

    public func removeCachedThumbnails(domainIdentifier: String) throws {
        dataCache.flush()
        try Self.removeCachedThumbnails(cacheDirectoryURL: dataCache.path, domainIdentifier: domainIdentifier)
    }

    public static func removeCachedThumbnails(
        appGroupIdentifier: String = ProviderConstants.appGroupIdentifier,
        domainIdentifier: String
    ) throws {
        try removeCachedThumbnails(
            cacheDirectoryURL: cacheDirectory(appGroupIdentifier: appGroupIdentifier),
            domainIdentifier: domainIdentifier
        )
    }

    public static func removeCachedThumbnails(
        appGroupIdentifier: String = ProviderConstants.appGroupIdentifier,
        domainIdentifier: String,
        driveID: Int,
        fileID: Int
    ) throws {
        try removeCachedThumbnails(
            cacheDirectoryURL: cacheDirectory(appGroupIdentifier: appGroupIdentifier),
            domainIdentifier: domainIdentifier,
            driveID: driveID,
            fileID: fileID
        )
    }

    public static func removeCachedThumbnails(cacheDirectoryURL: URL, domainIdentifier: String) throws {
        try removeCachedFiles(
            cacheDirectoryURL: cacheDirectoryURL,
            filenamePrefix: cacheFilenamePrefix(domainIdentifier: domainIdentifier)
        )
    }

    public static func removeCachedThumbnails(
        cacheDirectoryURL: URL,
        domainIdentifier: String,
        driveID: Int,
        fileID: Int
    ) throws {
        try removeCachedFiles(
            cacheDirectoryURL: cacheDirectoryURL,
            filenamePrefix: cacheFilenamePrefix(domainIdentifier: domainIdentifier, driveID: driveID, fileID: fileID)
        )
    }

    public static func containsCachedThumbnails(cacheDirectoryURL: URL, domainIdentifier: String) throws -> Bool {
        try cachedFileURLs(
            cacheDirectoryURL: cacheDirectoryURL,
            filenamePrefix: cacheFilenamePrefix(domainIdentifier: domainIdentifier)
        ).isEmpty == false
    }

    public static func cacheIdentifier(
        domainIdentifier: String,
        driveID: Int,
        fileID: Int,
        width: Int,
        height: Int
    ) -> String {
        "\(cacheFilenamePrefix(domainIdentifier: domainIdentifier, driveID: driveID, fileID: fileID))w_\(width)__h_\(height)"
    }

    static func cacheFilenamePrefix(domainIdentifier: String) -> String {
        "v1__d_\(safeCacheComponent(domainIdentifier))__"
    }

    static func cacheFilenamePrefix(domainIdentifier: String, driveID: Int, fileID: Int) -> String {
        "\(cacheFilenamePrefix(domainIdentifier: domainIdentifier))drive_\(driveID)__file_\(fileID)__"
    }

    private static func cacheFilename(for key: String) -> String? {
        key.isEmpty ? nil : key
    }

    private static func removeCachedFiles(cacheDirectoryURL: URL, filenamePrefix: String) throws {
        for url in try cachedFileURLs(cacheDirectoryURL: cacheDirectoryURL, filenamePrefix: filenamePrefix) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func cachedFileURLs(cacheDirectoryURL: URL, filenamePrefix: String) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: cacheDirectoryURL.path) else {
            return []
        }

        return try FileManager.default.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix(filenamePrefix) }
    }

    private static func safeCacheComponent(_ value: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.reduce(into: "") { result, scalar in
            if allowedCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
        }
    }

    private static func unwrappedPipelineError(_ error: Error) -> Error {
        guard let pipelineError = error as? ImagePipeline.Error else {
            return error
        }

        switch pipelineError {
        case .dataLoadingFailed(let underlyingError):
            return underlyingError
        case .cancelled:
            return CancellationError()
        default:
            return pipelineError
        }
    }
}

public actor KDriveThumbnailPipelinePool {
    public static let shared = KDriveThumbnailPipelinePool()

    private var pipelinesByCacheDirectoryPath: [String: KDriveThumbnailPipeline] = [:]

    public func pipeline(appGroupIdentifier: String = ProviderConstants.appGroupIdentifier) throws -> KDriveThumbnailPipeline {
        let cacheDirectory = try KDriveThumbnailPipeline.cacheDirectory(appGroupIdentifier: appGroupIdentifier)
        let key = cacheDirectory.path
        if let pipeline = pipelinesByCacheDirectoryPath[key] {
            return pipeline
        }

        let pipeline = try KDriveThumbnailPipeline(cacheDirectoryURL: cacheDirectory)
        pipelinesByCacheDirectoryPath[key] = pipeline
        return pipeline
    }

    public func removeCachedThumbnails(
        domainIdentifier: String,
        driveID: Int,
        fileID: Int,
        appGroupIdentifier: String = ProviderConstants.appGroupIdentifier
    ) throws {
        try pipeline(appGroupIdentifier: appGroupIdentifier).removeCachedThumbnails(
            domainIdentifier: domainIdentifier,
            driveID: driveID,
            fileID: fileID
        )
    }

    public func removeCachedThumbnails(
        domainIdentifier: String,
        appGroupIdentifier: String = ProviderConstants.appGroupIdentifier
    ) throws {
        try pipeline(appGroupIdentifier: appGroupIdentifier).removeCachedThumbnails(domainIdentifier: domainIdentifier)
    }
}

public enum KDriveThumbnailEligibilityResolver {
    public static func thumbnailFileID(
        rawItemIdentifier: String,
        domainIdentifier: String,
        driveID: Int,
        snapshotStore: any KDriveSnapshotStoring,
        remote: any KDriveFileProviding
    ) async throws -> Int? {
        guard let identifier = try? KDriveItemIdentifier(rawValue: rawItemIdentifier),
              case .item(let fileID) = identifier else {
            return nil
        }

        if let cachedItem = try await snapshotStore.item(domainIdentifier: domainIdentifier, fileID: fileID) {
            return cachedItem.isDirectory ? nil : fileID
        }

        let item = try await remote.item(driveID: driveID, fileID: fileID)
        return item.isDirectory ? nil : fileID
    }
}
