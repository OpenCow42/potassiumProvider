import CryptoKit
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
    case localContentConflict(latestItem: KDriveRemoteItem, stagedURL: URL)

    public var errorDescription: String? {
        switch self {
        case .staleVersion:
            return "The item changed on the server before the local mutation could be applied."
        case .localContentConflict:
            return "The local upload conflicts with a newer server version."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .staleVersion:
            return "Refresh the folder and retry the change."
        case .localContentConflict:
            return "Choose which version to keep; the local bytes have been retained for recovery."
        }
    }
}

public enum KDriveMutationIdentity {
    public static func contentHash(_ contents: Data) -> String {
        "sha256:\(hexDigest(SHA256.hash(data: contents)))"
    }

    public static func clientToken(_ components: [String]) -> String {
        let input = Data(components.joined(separator: "\u{1f}").utf8)
        return String(hexDigest(SHA256.hash(data: input)).prefix(32))
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
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
        let recoveryKey = KDriveMutationIdentity.clientToken([
            itemIdentifier,
            KDriveMutationIdentity.contentHash(contents),
        ])
        let fileURL = directoryURL
            // Keep the provider-owned filename bounded and opaque. File Provider
            // identifiers and user filenames can exceed filesystem component
            // limits and must not leak into a private recovery path.
            .appendingPathComponent(recoveryKey)
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
        lastModifiedAt: Date?,
        transferProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> KDriveRemoteItem {
        // File Provider owns the callback URL, so preserve our own deterministic
        // copy before starting a create that may outlive this extension process.
        let stagedURL = try await conflictStager.stageConflictContents(
            contents,
            itemIdentifier: "create-\(parentID)-\(fileName)"
        )
        let contentHash = KDriveMutationIdentity.contentHash(contents)
        let clientToken = KDriveMutationIdentity.clientToken([
            configuration.domainIdentifier,
            "create",
            String(parentID),
            fileName,
            contentHash,
        ])
        let operation = try remote.uploadFileOperation(
            driveID: configuration.driveID,
            parentID: parentID,
            fileName: fileName,
            contents: contents,
            lastModifiedAt: lastModifiedAt,
            conflictStrategy: .rename,
            clientToken: clientToken,
            contentHash: contentHash
        )
        transferProgress?(operation.progress)
        let item = try await operation.value
        await conflictStager.removeStagedConflictContents(at: stagedURL)
        return item
    }

    public func createDirectory(parentID: Int, name: String) async throws -> KDriveRemoteItem {
        do {
            return try await remote.createDirectory(
                driveID: configuration.driveID,
                parentID: parentID,
                name: name
            )
        } catch where KDriveRemoteErrorClassifier.isNameCollision(error) {
            return try await remote.createDirectory(
                driveID: configuration.driveID,
                parentID: parentID,
                name: conflictName(for: name)
            )
        }
    }

    public func replaceContents(
        itemIdentifier: String,
        fileID: Int,
        localFilename: String,
        baseContentVersion: Data,
        contents: Data,
        lastModifiedAt: Date?,
        failOnConflict: Bool = false,
        transferProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> KDriveContentMutationResult {
        // Stage before any network preflight. If the process, network, or API fails,
        // the exact local bytes remain available for a later retry or recovery.
        let stagedURL = try await conflictStager.stageConflictContents(contents, itemIdentifier: itemIdentifier)
        let contentHash = KDriveMutationIdentity.contentHash(contents)
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        guard let baseVersion = KDriveItemContentVersion(data: baseContentVersion),
              baseVersion.authoritativelyMatches(latestItem),
              let expectedETag = baseVersion.etag else {
            if failOnConflict {
                throw KDriveMutationConflictError.localContentConflict(
                    latestItem: latestItem,
                    stagedURL: stagedURL
                )
            }
            return try await uploadConflictCopy(
                itemIdentifier: itemIdentifier,
                localFilename: localFilename,
                latestItem: latestItem,
                stagedURL: stagedURL,
                contents: contents,
                contentHash: contentHash,
                lastModifiedAt: lastModifiedAt,
                transferProgress: transferProgress
            )
        }

        let clientToken = KDriveMutationIdentity.clientToken([
            configuration.domainIdentifier,
            "replace",
            String(fileID),
            expectedETag,
            contentHash,
        ])
        let operation = try remote.replaceFileOperation(
            driveID: configuration.driveID,
            fileID: fileID,
            expectedETag: expectedETag,
            clientToken: clientToken,
            contentHash: contentHash,
            contents: contents,
            lastModifiedAt: lastModifiedAt
        )
        transferProgress?(operation.progress)
        do {
            let replacedItem = try await operation.value
            await conflictStager.removeStagedConflictContents(at: stagedURL)
            return .replaced(replacedItem)
        } catch {
            guard KDriveRemoteErrorClassifier.isConditionalConflict(error) else {
                await recordRetainedUploadFailure(
                    itemIdentifier: itemIdentifier,
                    localFilename: localFilename,
                    latestItem: latestItem,
                    stagedURL: stagedURL
                )
                throw error
            }

            let refreshedItem = (try? await remote.item(
                driveID: configuration.driveID,
                fileID: fileID
            )) ?? latestItem
            if failOnConflict {
                throw KDriveMutationConflictError.localContentConflict(
                    latestItem: refreshedItem,
                    stagedURL: stagedURL
                )
            }
            return try await uploadConflictCopy(
                itemIdentifier: itemIdentifier,
                localFilename: localFilename,
                latestItem: refreshedItem,
                stagedURL: stagedURL,
                contents: contents,
                contentHash: contentHash,
                lastModifiedAt: lastModifiedAt,
                transferProgress: transferProgress
            )
        }
    }

    public func renameItem(
        fileID: Int,
        baseMetadataVersion: Data,
        name: String
    ) async throws -> KDriveRemoteItem {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        if latestItem.name == name {
            return latestItem
        }

        do {
            try await remote.renameItem(driveID: configuration.driveID, fileID: fileID, name: name)
        } catch where KDriveRemoteErrorClassifier.isNameCollision(error) {
            try await remote.renameItem(
                driveID: configuration.driveID,
                fileID: fileID,
                name: conflictName(for: name)
            )
        }
        return try await remote.item(driveID: configuration.driveID, fileID: fileID)
    }

    public func moveItem(
        fileID: Int,
        baseMetadataVersion: Data,
        destinationParentID: Int,
        name: String?
    ) async throws -> KDriveRemoteItem {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        let baseName = KDriveItemMetadataVersion(data: baseMetadataVersion)?.name
        let desiredName = name ?? latestItem.name
        if latestItem.parentID == destinationParentID, latestItem.name == desiredName {
            return latestItem
        }

        try await remote.moveItem(
            driveID: configuration.driveID,
            fileID: fileID,
            destinationParentID: destinationParentID,
            // Preserve an independent remote rename for a move-only local edit.
            name: name == nil && baseName != latestItem.name ? nil : name
        )
        return try await remote.item(driveID: configuration.driveID, fileID: fileID)
    }

    public func updateModificationDate(fileID: Int, date: Date) async throws -> KDriveRemoteItem {
        try await remote.updateModificationDate(
            driveID: configuration.driveID,
            fileID: fileID,
            date: date
        )
        return try await remote.item(driveID: configuration.driveID, fileID: fileID)
    }

    public func trashItem(fileID: Int, baseVersion: KDriveItemBaseVersion) async throws -> KDriveRemoteItem {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        try await remote.trashItem(driveID: configuration.driveID, fileID: fileID)
        return latestItem
    }

    public func deleteTrashedItem(fileID: Int, baseVersion: KDriveItemBaseVersion) async throws -> KDriveRemoteItem {
        let latestItem = try await remote.item(driveID: configuration.driveID, fileID: fileID)
        guard KDriveVersionConflictResolver.itemVersionMatchesAllowingMetadataTimestampDrift(
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
        stagedURL: URL,
        contents: Data,
        contentHash: String,
        lastModifiedAt: Date?,
        transferProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> KDriveContentMutationResult {
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
            let clientToken = KDriveMutationIdentity.clientToken([
                configuration.domainIdentifier,
                "conflict-copy",
                itemIdentifier,
                latestItem.etag ?? "missing-etag",
                contentHash,
            ])
            let operation = try remote.uploadFileOperation(
                driveID: configuration.driveID,
                parentID: latestItem.parentID,
                fileName: conflictFilename,
                contents: contents,
                lastModifiedAt: lastModifiedAt,
                conflictStrategy: .rename,
                clientToken: clientToken,
                contentHash: contentHash
            )
            transferProgress?(operation.progress)
            let conflictItem = try await operation.value
            await contentConflictObserver?(.resolved(context, conflictItem: conflictItem, resolvedAt: conflictDate()))
            await conflictStager.removeStagedConflictContents(at: stagedURL)
            return .conflictCopy(conflictItem)
        } catch {
            await contentConflictObserver?(.failed(context, failedAt: conflictDate()))
            throw error
        }
    }

    private func recordRetainedUploadFailure(
        itemIdentifier: String,
        localFilename: String,
        latestItem: KDriveRemoteItem,
        stagedURL: URL
    ) async {
        let context = KDriveStaleContentConflictContext(
            detectedAt: conflictDate(),
            localItemIdentifier: itemIdentifier,
            localFilename: localFilename,
            latestItem: latestItem,
            stagedURL: stagedURL
        )
        await contentConflictObserver?(.started(context))
        await contentConflictObserver?(.failed(context, failedAt: conflictDate()))
    }

    private func conflictName(for name: String) -> String {
        KDriveConflictFilename.filename(
            for: name,
            deviceName: conflictDeviceName(),
            date: conflictDate(),
            timeZone: conflictTimeZone()
        )
    }
}
