import Foundation

public struct KDriveShareLinkConfiguration: Equatable, Sendable {
    public enum Access: String, CaseIterable, Equatable, Sendable {
        case `public`
        case password
    }

    public var access: Access
    public var password: String?
    public var validUntil: Date?
    public var allowsDownload: Bool
    public var allowsComments: Bool
    public var allowsEditing: Bool
    public var allowsAccessRequests: Bool
    public var showsFileInformation: Bool
    public var showsStatistics: Bool

    public init(
        access: Access = .public,
        password: String? = nil,
        validUntil: Date? = nil,
        allowsDownload: Bool = true,
        allowsComments: Bool = false,
        allowsEditing: Bool = false,
        allowsAccessRequests: Bool = false,
        showsFileInformation: Bool = true,
        showsStatistics: Bool = false
    ) {
        self.access = access
        self.password = password
        self.validUntil = validUntil
        self.allowsDownload = allowsDownload
        self.allowsComments = allowsComments
        self.allowsEditing = allowsEditing
        self.allowsAccessRequests = allowsAccessRequests
        self.showsFileInformation = showsFileInformation
        self.showsStatistics = showsStatistics
    }

    public var isValid: Bool {
        access != .password || password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public func isValid(preservingPasswordFor existingAccess: Access?) -> Bool {
        isValid || (access == .password && existingAccess == .password)
    }
}

public struct KDriveShareLinkSummary: Equatable, Sendable {
    public let url: URL
    public let configuration: KDriveShareLinkConfiguration
    public let viewCount: Int?

    public init(url: URL, configuration: KDriveShareLinkConfiguration, viewCount: Int?) {
        self.url = url
        self.configuration = configuration
        self.viewCount = viewCount
    }
}

public struct KDriveFileVersionSummary: Equatable, Identifiable, Sendable {
    public let id: Int
    public let createdAt: Date
    public let modifiedAt: Date?
    public let size: Int
    public let mimeType: String?
    public let editorDisplayName: String
    public let isKeptForever: Bool

    public init(
        id: Int,
        createdAt: Date,
        modifiedAt: Date?,
        size: Int,
        mimeType: String?,
        editorDisplayName: String,
        isKeptForever: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.size = size
        self.mimeType = mimeType
        self.editorDisplayName = editorDisplayName
        self.isKeptForever = isKeptForever
    }
}

public struct KDriveFileVersionPage: Equatable, Sendable {
    public let versions: [KDriveFileVersionSummary]
    public let page: Int
    public let hasMore: Bool

    public init(versions: [KDriveFileVersionSummary], page: Int, hasMore: Bool) {
        self.versions = versions
        self.page = page
        self.hasMore = hasMore
    }
}

public protocol KDriveContextActionProviding: Sendable {
    func setFavorite(driveID: Int, fileID: Int, isFavorite: Bool) async throws
    func duplicateItem(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem
    func trashedItem(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem
    func existingFileIDs(driveID: Int, fileIDs: [Int]) async throws -> Set<Int>
    func restoreTrashedItem(driveID: Int, fileID: Int, destinationParentID: Int) async throws
    func shareLink(driveID: Int, fileID: Int) async throws -> KDriveShareLinkSummary?
    func createShareLink(
        driveID: Int,
        fileID: Int,
        configuration: KDriveShareLinkConfiguration
    ) async throws -> KDriveShareLinkSummary
    func updateShareLink(
        driveID: Int,
        fileID: Int,
        configuration: KDriveShareLinkConfiguration
    ) async throws -> KDriveShareLinkSummary
    func deleteShareLink(driveID: Int, fileID: Int) async throws
    func fileVersions(driveID: Int, fileID: Int, page: Int, pageSize: Int) async throws -> KDriveFileVersionPage
    func restoreFileVersion(
        driveID: Int,
        fileID: Int,
        versionID: Int,
        destinationParentID: Int,
        name: String
    ) async throws -> KDriveRemoteItem
}

public enum KDriveContextActionError: Error, Equatable, LocalizedError, Sendable {
    case invalidShareLinkURL
    case passwordRequired
    case restoredItemUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidShareLinkURL:
            return "kDrive returned an invalid share link."
        case .passwordRequired:
            return "Enter a password for the protected share link."
        case .restoredItemUnavailable:
            return "kDrive restored the version, but its metadata is not available yet."
        }
    }
}

public enum ProviderContextActionIdentifier {
    public static let addFavorite = ProviderDirectContextAction.addFavorite.rawValue
    public static let removeFavorite = ProviderDirectContextAction.removeFavorite.rawValue
    public static let duplicate = ProviderDirectContextAction.duplicate.rawValue
    public static let restoreFromTrash = ProviderDirectContextAction.restoreFromTrash.rawValue
    public static let shareLink = "net.weavee.potassiumProvider.action.shareLink"
    public static let versionHistory = "net.weavee.potassiumProvider.action.versionHistory"
}

public struct ProviderContextItemState: Equatable, Sendable {
    public let isDirectory: Bool
    public let isFavorite: Bool
    public let isTrashed: Bool
    public let isRoot: Bool

    public init(
        isDirectory: Bool,
        isFavorite: Bool,
        isTrashed: Bool,
        isRoot: Bool = false
    ) {
        self.isDirectory = isDirectory
        self.isFavorite = isFavorite
        self.isTrashed = isTrashed
        self.isRoot = isRoot
    }
}

public enum ProviderDirectContextAction: String, CaseIterable, Equatable, Sendable {
    case addFavorite = "net.weavee.potassiumProvider.action.addFavorite"
    case removeFavorite = "net.weavee.potassiumProvider.action.removeFavorite"
    case duplicate = "net.weavee.potassiumProvider.action.duplicate"
    case restoreFromTrash = "net.weavee.potassiumProvider.action.restoreFromTrash"

    public func isAvailable(for state: ProviderContextItemState) -> Bool {
        guard state.isRoot == false else { return false }
        switch self {
        case .addFavorite:
            return state.isTrashed == false && state.isFavorite == false
        case .removeFavorite:
            return state.isTrashed == false && state.isFavorite
        case .duplicate:
            return state.isTrashed == false
        case .restoreFromTrash:
            return state.isTrashed
        }
    }
}

public struct KDriveContextActionExecution: Equatable, Sendable {
    public let action: ProviderDirectContextAction
    public let activityItem: KDriveRemoteItem
    public let affectedParentIDs: Set<Int>
    public let invalidatesTrash: Bool
    public let summary: String

    public init(
        action: ProviderDirectContextAction,
        activityItem: KDriveRemoteItem,
        affectedParentIDs: Set<Int>,
        invalidatesTrash: Bool,
        summary: String
    ) {
        self.action = action
        self.activityItem = activityItem
        self.affectedParentIDs = affectedParentIDs
        self.invalidatesTrash = invalidatesTrash
        self.summary = summary
    }
}

/// Coordinates action-specific remote calls and returns the exact provider
/// containers that must be invalidated after the server mutation succeeds.
public struct KDriveContextActionCoordinator: Sendable {
    private let driveID: Int
    private let rootFileID: Int
    private let remote: any KDriveItemMetadataProviding
    private let actions: any KDriveContextActionProviding

    public init(
        driveID: Int,
        rootFileID: Int,
        remote: any KDriveItemMetadataProviding,
        actions: any KDriveContextActionProviding
    ) {
        self.driveID = driveID
        self.rootFileID = rootFileID
        self.remote = remote
        self.actions = actions
    }

    public func perform(
        _ action: ProviderDirectContextAction,
        fileID: Int
    ) async throws -> KDriveContextActionExecution {
        switch action {
        case .addFavorite:
            return try await setFavorite(true, fileID: fileID, action: action)
        case .removeFavorite:
            return try await setFavorite(false, fileID: fileID, action: action)
        case .duplicate:
            try Task.checkCancellation()
            let duplicate = try await actions.duplicateItem(driveID: driveID, fileID: fileID)
            let authoritativeDuplicate = try await remote.item(driveID: driveID, fileID: duplicate.id)
            return KDriveContextActionExecution(
                action: action,
                activityItem: authoritativeDuplicate,
                affectedParentIDs: [authoritativeDuplicate.parentID],
                invalidatesTrash: false,
                summary: "Duplicated item on kDrive."
            )
        case .restoreFromTrash:
            let trashedItem = try await actions.trashedItem(driveID: driveID, fileID: fileID)
            let originalParentExists: Bool
            if trashedItem.parentID == rootFileID {
                originalParentExists = true
            } else {
                originalParentExists = try await actions.existingFileIDs(
                    driveID: driveID,
                    fileIDs: [trashedItem.parentID]
                ).contains(trashedItem.parentID)
            }
            let destinationParentID = originalParentExists ? trashedItem.parentID : rootFileID
            try Task.checkCancellation()
            try await actions.restoreTrashedItem(
                driveID: driveID,
                fileID: fileID,
                destinationParentID: destinationParentID
            )
            return KDriveContextActionExecution(
                action: action,
                activityItem: trashedItem,
                affectedParentIDs: [destinationParentID],
                invalidatesTrash: true,
                summary: originalParentExists
                    ? "Restored item from kDrive trash."
                    : "Restored item from kDrive trash to the drive root because its original folder is unavailable."
            )
        }
    }

    private func setFavorite(
        _ isFavorite: Bool,
        fileID: Int,
        action: ProviderDirectContextAction
    ) async throws -> KDriveContextActionExecution {
        let currentItem = try await remote.item(driveID: driveID, fileID: fileID)
        try Task.checkCancellation()
        try await actions.setFavorite(driveID: driveID, fileID: fileID, isFavorite: isFavorite)
        let updatedItem = try await remote.item(driveID: driveID, fileID: fileID)
        return KDriveContextActionExecution(
            action: action,
            activityItem: updatedItem,
            affectedParentIDs: [currentItem.parentID, updatedItem.parentID],
            invalidatesTrash: false,
            summary: isFavorite
                ? "Added item to kDrive favorites."
                : "Removed item from kDrive favorites."
        )
    }
}

public enum KDriveRestoredCopyNaming {
    public static func filename(
        originalName: String,
        restoredAt date: Date,
        timeZone: TimeZone = .current,
        uniqueSuffix: String = String(UUID().uuidString.prefix(6))
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"

        let original = originalName as NSString
        let pathExtension = original.pathExtension
        let stem = original.deletingPathExtension
        let suffix = " (restored \(formatter.string(from: date)) \(uniqueSuffix))"
        return pathExtension.isEmpty ? stem + suffix : "\(stem)\(suffix).\(pathExtension)"
    }
}
