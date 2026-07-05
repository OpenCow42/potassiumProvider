import Foundation
import UniformTypeIdentifiers

public struct KDriveDriveSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let accountID: Int
    public let role: String
    public let status: String
    public let isInMaintenance: Bool

    public init(id: Int, name: String, accountID: Int, role: String, status: String, isInMaintenance: Bool) {
        self.id = id
        self.name = name
        self.accountID = accountID
        self.role = role
        self.status = status
        self.isInMaintenance = isInMaintenance
    }
}

public struct KDriveRemoteItem: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let type: String?
    public let status: String
    public let driveID: Int
    public let parentID: Int
    public let path: String?
    public let size: Int?
    public let mimeType: String?
    public let createdAt: Date?
    public let modifiedAt: Date
    public let updatedAt: Date

    public init(
        id: Int,
        name: String,
        type: String?,
        status: String,
        driveID: Int,
        parentID: Int,
        path: String?,
        size: Int?,
        mimeType: String?,
        createdAt: Date?,
        modifiedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.status = status
        self.driveID = driveID
        self.parentID = parentID
        self.path = path
        self.size = size
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.updatedAt = updatedAt
    }

    public var isDirectory: Bool {
        type == "dir" || type == "directory"
    }

    public var contentType: UTType {
        if isDirectory { return .folder }
        if let mimeType, let type = UTType(mimeType: mimeType) { return type }
        let extensionType = UTType(filenameExtension: (name as NSString).pathExtension)
        return extensionType ?? .data
    }

    public var contentVersion: Data {
        Data(String(modifiedAt.timeIntervalSince1970).utf8)
    }

    public var metadataVersion: Data {
        Data("\(id)-\(updatedAt.timeIntervalSince1970)-\(name)-\(parentID)".utf8)
    }
}

public struct KDriveItemPage: Equatable, Sendable {
    public let items: [KDriveRemoteItem]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(items: [KDriveRemoteItem], nextCursor: String?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct KDriveAdvancedItemPage: Equatable, Sendable {
    public let items: [KDriveRemoteItem]
    public let actions: [KDriveRemoteFileAction]
    public let actionItems: [KDriveRemoteItem]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(
        items: [KDriveRemoteItem],
        actions: [KDriveRemoteFileAction],
        actionItems: [KDriveRemoteItem],
        nextCursor: String?,
        hasMore: Bool
    ) {
        self.items = items
        self.actions = actions
        self.actionItems = actionItems
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct KDriveRemoteFileAction: Equatable, Sendable {
    public let action: String
    public let fileID: Int
    public let parentID: Int

    public init(action: String, fileID: Int, parentID: Int) {
        self.action = action
        self.fileID = fileID
        self.parentID = parentID
    }
}

public enum KDriveRemoteFileActionKind: Equatable, Sendable {
    case delete
    case update
}

public enum KDriveListingValidationError: Error, Equatable, LocalizedError, Sendable {
    case missingContinuationCursor
    case repeatedContinuationCursor(String)
    case missingSnapshotForContinuation(String)
    case unknownAdvancedAction(String)
    case missingActionItem(action: String, fileID: Int)

    public var errorDescription: String? {
        switch self {
        case .missingContinuationCursor:
            return "The server reported more listing pages but did not return a continuation cursor."
        case .repeatedContinuationCursor(let cursor):
            return "The server repeated listing cursor '\(cursor)'."
        case .missingSnapshotForContinuation(let cursor):
            return "No cached listing snapshot exists for continuation cursor '\(cursor)'."
        case .unknownAdvancedAction(let action):
            return "The server returned unknown advanced listing action '\(action)'."
        case .missingActionItem(let action, let fileID):
            return "Advanced listing action '\(action)' for file '\(fileID)' did not include item metadata."
        }
    }
}

public enum KDriveListingValidator {
    public static func validatedNextCursor(
        currentCursor: String?,
        nextCursor: String?,
        hasMore: Bool
    ) throws -> String? {
        guard let nextCursor, nextCursor.isEmpty == false else {
            if hasMore {
                throw KDriveListingValidationError.missingContinuationCursor
            }
            return nil
        }

        if hasMore, currentCursor == nextCursor {
            throw KDriveListingValidationError.repeatedContinuationCursor(nextCursor)
        }

        return nextCursor
    }

    public static func validatedNextCursor(
        currentCursor: String?,
        nextCursor: String?,
        hasMore: Bool,
        seenCursors: inout Set<String>
    ) throws -> String? {
        let nextCursor = try validatedNextCursor(
            currentCursor: currentCursor,
            nextCursor: nextCursor,
            hasMore: hasMore
        )
        guard hasMore, let nextCursor else {
            return nextCursor
        }
        guard seenCursors.insert(nextCursor).inserted else {
            throw KDriveListingValidationError.repeatedContinuationCursor(nextCursor)
        }
        return nextCursor
    }

    public static func validateAdvancedActions(
        _ actions: [KDriveRemoteFileAction],
        actionItems: [KDriveRemoteItem]
    ) throws {
        let actionItemIDs = Set(actionItems.map(\.id))
        for action in actions {
            switch actionKind(for: action.action) {
            case .delete:
                continue
            case .update:
                guard actionItemIDs.contains(action.fileID) else {
                    throw KDriveListingValidationError.missingActionItem(
                        action: action.action,
                        fileID: action.fileID
                    )
                }
            case nil:
                throw KDriveListingValidationError.unknownAdvancedAction(action.action)
            }
        }
    }

    public static func actionKind(for action: String) -> KDriveRemoteFileActionKind? {
        if deleteActions.contains(action) {
            return .delete
        }
        if updateActions.contains(action) {
            return .update
        }
        return nil
    }

    private static let deleteActions: Set<String> = [
        "file_delete",
        "file_trash",
        "file_move_out"
    ]

    private static let updateActions: Set<String> = [
        "file_create",
        "file_rename",
        "file_move",
        "file_restore",
        "file_update",
        "file_favorite_create",
        "file_favorite_remove",
        "file_share_create",
        "file_share_update",
        "file_share_delete",
        "share_link_create",
        "share_link_update",
        "share_link_delete",
        "collaborative_folder_create",
        "collaborative_folder_update",
        "collaborative_folder_delete",
        "file_color_update",
        "file_color_delete",
        "file_categorize",
        "file_uncategorize"
    ]
}

public enum KDriveAdvancedActionReducer {
    public static func changes(
        from actions: [KDriveRemoteFileAction],
        actionItems: [KDriveRemoteItem]
    ) throws -> KDriveSnapshotChangeSet {
        try KDriveListingValidator.validateAdvancedActions(actions, actionItems: actionItems)

        let actionItemsByID = Dictionary(uniqueKeysWithValues: actionItems.map { ($0.id, $0) })
        var handledFileIDs = Set<Int>()
        var updatedItems: [KDriveRemoteItem] = []
        var deletedItemIDs = Set<Int>()

        for action in actions {
            guard handledFileIDs.insert(action.fileID).inserted else {
                continue
            }

            if KDriveListingValidator.actionKind(for: action.action) == .delete {
                deletedItemIDs.insert(action.fileID)
                continue
            }

            guard let item = actionItemsByID[action.fileID] else {
                continue
            }

            updatedItems.append(item)
        }

        return KDriveSnapshotChangeSet(
            updatedItems: updatedItems,
            deletedItemIDs: deletedItemIDs.sorted()
        )
    }

    public static func applying(
        actions: [KDriveRemoteFileAction],
        actionItems: [KDriveRemoteItem],
        to snapshot: KDriveSnapshot,
        anchor: String,
        serverCursor: String?
    ) throws -> (snapshot: KDriveSnapshot, changes: KDriveSnapshotChangeSet) {
        let changes = try changes(from: actions, actionItems: actionItems)
        var itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        for itemID in changes.deletedItemIDs {
            itemsByID[itemID] = nil
        }
        for item in changes.updatedItems {
            itemsByID[item.id] = item
        }

        let existingOrder = snapshot.items.map(\.id)
        var items: [KDriveRemoteItem] = []
        var emittedIDs = Set<Int>()
        for itemID in existingOrder {
            if let item = itemsByID[itemID] {
                items.append(item)
                emittedIDs.insert(itemID)
            }
        }
        let appendedItems = changes.updatedItems
            .filter { emittedIDs.contains($0.id) == false }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        items.append(contentsOf: appendedItems)

        return (
            KDriveSnapshot(
                anchor: anchor,
                serverCursor: serverCursor,
                isFullyEnumerated: true,
                usesAdvancedListing: true,
                items: items
            ),
            changes
        )
    }
}

public enum KDriveVersionConflictResolver {
    public static func contentMatches(baseVersion: Data, remoteItem: KDriveRemoteItem) -> Bool {
        baseVersion == remoteItem.contentVersion
    }

    public static func metadataMatches(baseVersion: Data, remoteItem: KDriveRemoteItem) -> Bool {
        baseVersion == remoteItem.metadataVersion
    }

    public static func itemVersionMatches(contentVersion: Data, metadataVersion: Data, remoteItem: KDriveRemoteItem) -> Bool {
        contentMatches(baseVersion: contentVersion, remoteItem: remoteItem)
            && metadataMatches(baseVersion: metadataVersion, remoteItem: remoteItem)
    }
}

public enum KDriveConflictFilename {
    public static func filename(
        for originalName: String,
        deviceName: String = "This Mac",
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let nsName = originalName as NSString
        let fileExtension = nsName.pathExtension
        let stem = fileExtension.isEmpty ? originalName : nsName.deletingPathExtension
        let suffix = "conflict - \(safeDeviceName(deviceName)) - \(timestamp(for: date, timeZone: timeZone))"
        guard fileExtension.isEmpty == false else {
            return "\(stem) (\(suffix))"
        }
        return "\(stem) (\(suffix)).\(fileExtension)"
    }

    private static func safeDeviceName(_ deviceName: String) -> String {
        deviceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
    }

    private static func timestamp(for date: Date, timeZone: TimeZone) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: timeZone, from: date)
        return String(
            format: "%04d-%02d-%02d %02d.%02d.%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }
}

public enum KDriveItemIdentifier: Equatable, Hashable, Sendable {
    case root
    case trash
    case item(Int)

    public init(rawValue: String) throws {
        switch rawValue {
        case "NSFileProviderRootContainerItemIdentifier":
            self = .root
        case "NSFileProviderTrashContainerItemIdentifier":
            self = .trash
        default:
            guard let id = Int(rawValue), id > 0 else {
                throw KDriveItemIdentifierError.invalid(rawValue)
            }
            self = .item(id)
        }
    }

    public init(fileID: Int) {
        self = .item(fileID)
    }

    public var fileID: Int? {
        fileID(rootFileID: ProviderConstants.defaultRootFileID)
    }

    public func fileID(rootFileID: Int) -> Int? {
        switch self {
        case .root:
            return rootFileID
        case .trash:
            return nil
        case .item(let id):
            return id
        }
    }

    public var rawValue: String {
        switch self {
        case .root:
            return "NSFileProviderRootContainerItemIdentifier"
        case .trash:
            return "NSFileProviderTrashContainerItemIdentifier"
        case .item(let id):
            return String(id)
        }
    }
}

public enum KDriveItemIdentifierError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let value):
            return "'\(value)' is not a valid kDrive item identifier."
        }
    }
}
