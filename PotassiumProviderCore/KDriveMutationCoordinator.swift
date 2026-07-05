import Foundation

public struct KDriveItemBaseVersion: Equatable, Sendable {
    public let contentVersion: Data
    public let metadataVersion: Data

    public init(contentVersion: Data, metadataVersion: Data) {
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
    }
}

public enum KDriveMutationConflictError: Error, LocalizedError, Sendable {
    case staleVersion(latestItem: KDriveRemoteItem)

    public var errorDescription: String? {
        "The item changed on the server before the local mutation could be applied."
    }

    public var recoverySuggestion: String? {
        "Refresh the folder and retry the change."
    }
}

public protocol KDriveConflictContentStaging: Sendable {
    func stageConflictContents(_ contents: Data, itemIdentifier: String) async throws -> URL
    func removeStagedConflictContents(at url: URL) async
}

public struct KDriveAppGroupConflictContentStager: KDriveConflictContentStaging {
    private let appGroupIdentifier: String

    public init(appGroupIdentifier: String = ProviderConstants.appGroupIdentifier) {
        self.appGroupIdentifier = appGroupIdentifier
    }

    public func stageConflictContents(_ contents: Data, itemIdentifier: String) async throws -> URL {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw KDriveSnapshotStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        let directoryURL = containerURL.appendingPathComponent("ConflictStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL
            .appendingPathComponent("\(itemIdentifier)-\(UUID().uuidString)")
            .appendingPathExtension("upload")
        try contents.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    public func removeStagedConflictContents(at url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }
}

public struct KDriveStaleContentConflictContext: Sendable {
    public let id: UUID
    public let detectedAt: Date
    public let localItemIdentifier: String
    public let localFilename: String
    public let latestItem: KDriveRemoteItem
    public let stagedURL: URL

    public init(
        id: UUID = UUID(),
        detectedAt: Date,
        localItemIdentifier: String,
        localFilename: String,
        latestItem: KDriveRemoteItem,
        stagedURL: URL
    ) {
        self.id = id
        self.detectedAt = detectedAt
        self.localItemIdentifier = localItemIdentifier
        self.localFilename = localFilename
        self.latestItem = latestItem
        self.stagedURL = stagedURL
    }
}

public enum KDriveStaleContentConflictEvent: Sendable {
    case started(KDriveStaleContentConflictContext)
    case resolved(KDriveStaleContentConflictContext, conflictItem: KDriveRemoteItem, resolvedAt: Date)
    case failed(KDriveStaleContentConflictContext, failedAt: Date)
}

public enum KDriveContentMutationResult: Equatable, Sendable {
    case replaced(KDriveRemoteItem)
    case conflictCopy(KDriveRemoteItem)

    public var item: KDriveRemoteItem {
        switch self {
        case .replaced(let item), .conflictCopy(let item):
            return item
        }
    }
}

public struct KDriveMutationCoordinator: Sendable {
    public typealias ContentConflictObserver = @Sendable (KDriveStaleContentConflictEvent) async -> Void

    private let configuration: ProviderDomainConfiguration
    private let remote: any KDriveFileProviding
    private let conflictStager: any KDriveConflictContentStaging
    private let conflictDeviceName: @Sendable () -> String
    private let conflictDate: @Sendable () -> Date
    private let conflictTimeZone: @Sendable () -> TimeZone
    private let contentConflictObserver: ContentConflictObserver?

    public init(
        configuration: ProviderDomainConfiguration,
        remote: any KDriveFileProviding,
        conflictStager: any KDriveConflictContentStaging = KDriveAppGroupConflictContentStager(),
        conflictDeviceName: @escaping @Sendable () -> String = { "This Mac" },
        conflictDate: @escaping @Sendable () -> Date = { Date() },
        conflictTimeZone: @escaping @Sendable () -> TimeZone = { .current },
        contentConflictObserver: ContentConflictObserver? = nil
    ) {
        self.configuration = configuration
        self.remote = remote
        self.conflictStager = conflictStager
        self.conflictDeviceName = conflictDeviceName
        self.conflictDate = conflictDate
        self.conflictTimeZone = conflictTimeZone
        self.contentConflictObserver = contentConflictObserver
    }

    public func createFile(
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveRemoteItem {
        try await remote.uploadFile(
            driveID: configuration.driveID,
            parentID: parentID,
            fileName: fileName,
            contents: contents,
            lastModifiedAt: lastModifiedAt,
            conflictStrategy: .version
        )
    }

    public func createDirectory(parentID: Int, name: String) async throws -> KDriveRemoteItem {
        try await remote.createDirectory(
            driveID: configuration.driveID,
            parentID: parentID,
            name: name
        )
    }

    public func replaceContents(
        itemIdentifier: String,
        fileID: Int,
        localFilename: String,
        baseContentVersion: Data,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveContentMutationResult {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        guard KDriveVersionConflictResolver.contentMatches(baseVersion: baseContentVersion, remoteItem: latestItem) else {
            return try await uploadConflictCopy(
                itemIdentifier: itemIdentifier,
                localFilename: localFilename,
                latestItem: latestItem,
                contents: contents,
                lastModifiedAt: lastModifiedAt
            )
        }

        let replacedItem = try await remote.replaceFile(
            driveID: configuration.driveID,
            fileID: fileID,
            contents: contents,
            lastModifiedAt: lastModifiedAt
        )
        return .replaced(replacedItem)
    }

    public func renameItem(
        fileID: Int,
        baseMetadataVersion: Data,
        name: String
    ) async throws -> KDriveRemoteItem {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        guard KDriveVersionConflictResolver.metadataMatches(baseVersion: baseMetadataVersion, remoteItem: latestItem) else {
            throw KDriveMutationConflictError.staleVersion(latestItem: latestItem)
        }

        try await remote.renameItem(driveID: configuration.driveID, fileID: fileID, name: name)
        return try await remote.item(driveID: configuration.driveID, fileID: fileID)
    }

    public func moveItem(
        fileID: Int,
        baseMetadataVersion: Data,
        destinationParentID: Int,
        name: String?
    ) async throws -> KDriveRemoteItem {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        guard KDriveVersionConflictResolver.metadataMatches(baseVersion: baseMetadataVersion, remoteItem: latestItem) else {
            throw KDriveMutationConflictError.staleVersion(latestItem: latestItem)
        }

        try await remote.moveItem(
            driveID: configuration.driveID,
            fileID: fileID,
            destinationParentID: destinationParentID,
            name: name
        )
        return try await remote.item(driveID: configuration.driveID, fileID: fileID)
    }

    public func trashItem(fileID: Int, baseVersion: KDriveItemBaseVersion) async throws -> KDriveRemoteItem {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        guard KDriveVersionConflictResolver.itemVersionMatches(
            contentVersion: baseVersion.contentVersion,
            metadataVersion: baseVersion.metadataVersion,
            remoteItem: latestItem
        ) else {
            throw KDriveMutationConflictError.staleVersion(latestItem: latestItem)
        }

        try await remote.trashItem(driveID: configuration.driveID, fileID: fileID)
        return latestItem
    }

    public func deleteTrashedItem(fileID: Int, baseVersion: KDriveItemBaseVersion) async throws -> KDriveRemoteItem {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        guard KDriveVersionConflictResolver.itemVersionMatches(
            contentVersion: baseVersion.contentVersion,
            metadataVersion: baseVersion.metadataVersion,
            remoteItem: latestItem
        ) else {
            throw KDriveMutationConflictError.staleVersion(latestItem: latestItem)
        }

        try await remote.deleteTrashedItem(driveID: configuration.driveID, fileID: fileID)
        return latestItem
    }

    private func uploadConflictCopy(
        itemIdentifier: String,
        localFilename: String,
        latestItem: KDriveRemoteItem,
        contents: Data,
        lastModifiedAt: Date?
    ) async throws -> KDriveContentMutationResult {
        let stagedURL = try await conflictStager.stageConflictContents(contents, itemIdentifier: itemIdentifier)
        let detectedAt = conflictDate()
        let context = KDriveStaleContentConflictContext(
            detectedAt: detectedAt,
            localItemIdentifier: itemIdentifier,
            localFilename: localFilename,
            latestItem: latestItem,
            stagedURL: stagedURL
        )
        await contentConflictObserver?(.started(context))

        let conflictFilename = KDriveConflictFilename.filename(
            for: localFilename,
            deviceName: conflictDeviceName(),
            date: detectedAt,
            timeZone: conflictTimeZone()
        )

        do {
            let conflictItem = try await remote.uploadFile(
                driveID: configuration.driveID,
                parentID: latestItem.parentID,
                fileName: conflictFilename,
                contents: contents,
                lastModifiedAt: lastModifiedAt,
                conflictStrategy: .rename
            )
            await contentConflictObserver?(.resolved(context, conflictItem: conflictItem, resolvedAt: conflictDate()))
            await conflictStager.removeStagedConflictContents(at: stagedURL)
            return .conflictCopy(conflictItem)
        } catch {
            await contentConflictObserver?(.failed(context, failedAt: conflictDate()))
            throw error
        }
    }
}
