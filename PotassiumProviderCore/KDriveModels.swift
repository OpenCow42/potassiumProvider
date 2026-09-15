import Foundation
import UniformTypeIdentifiers

public struct KDriveDriveSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let accountID: Int
    public let role: String
    public let status: String
    public let isInMaintenance: Bool

    /// Matches the official iOS kDrive eligibility rule for a drive belonging
    /// to the signed-in user rather than an unavailable or external share.
    public var isUsableInternalDrive: Bool {
        role != "none" && role != "external"
    }

    public init(
        id: Int,
        name: String,
        accountID: Int,
        role: String,
        status: String,
        isInMaintenance: Bool
    ) {
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
    public let isFavorite: Bool?
    public let createdAt: Date?
    public let modifiedAt: Date
    public let revisedAt: Date?
    public let updatedAt: Date
    public let etag: String?

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
        isFavorite: Bool? = nil,
        createdAt: Date?,
        modifiedAt: Date,
        revisedAt: Date? = nil,
        updatedAt: Date,
        etag: String? = nil
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
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.revisedAt = revisedAt
        self.updatedAt = updatedAt
        self.etag = etag
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
        KDriveItemContentVersion(
            itemID: id,
            etag: etag,
            revisedAt: revisedAt ?? modifiedAt,
            size: size
        ).data
    }

    public var metadataVersion: Data {
        KDriveItemMetadataVersion(
            itemID: id,
            updatedAt: updatedAt,
            name: name,
            parentID: parentID
        ).data
    }
}

public struct KDriveItemContentVersion: Equatable, Sendable {
    private static let currentVersion = 2

    public let itemID: Int?
    public let etag: String?
    public let revisedAt: Date
    public let size: Int?
    public let isLegacy: Bool

    public init(itemID: Int, etag: String?, revisedAt: Date, size: Int?) {
        self.itemID = itemID
        self.etag = etag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.revisedAt = revisedAt
        self.size = size
        self.isLegacy = false
    }

    public init?(data: Data) {
        if let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.version == Self.currentVersion,
           payload.itemID > 0 {
            self.itemID = payload.itemID
            self.etag = payload.etag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.revisedAt = Date(timeIntervalSince1970: payload.revisedAt)
            self.size = payload.size
            self.isLegacy = false
            return
        }

        guard let rawValue = String(data: data, encoding: .utf8),
              let timestamp = TimeInterval(rawValue) else {
            return nil
        }
        self.itemID = nil
        self.etag = nil
        self.revisedAt = Date(timeIntervalSince1970: timestamp)
        self.size = nil
        self.isLegacy = true
    }

    public var isAuthoritative: Bool {
        isLegacy == false && itemID != nil && etag != nil
    }

    public var data: Data {
        let payload = Payload(
            version: Self.currentVersion,
            itemID: itemID ?? 0,
            etag: etag,
            revisedAt: revisedAt.timeIntervalSince1970,
            size: size
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }

    public func authoritativelyMatches(_ item: KDriveRemoteItem) -> Bool {
        guard isAuthoritative,
              itemID == item.id,
              let etag,
              let remoteETag = item.etag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return false
        }
        return etag == remoteETag
    }

    private struct Payload: Codable {
        let version: Int
        let itemID: Int
        let etag: String?
        let revisedAt: TimeInterval
        let size: Int?
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

public struct KDriveItemMetadataVersion: Equatable, Sendable {
    private static let currentVersion = 2

    public let itemID: Int
    public let updatedAt: Date
    public let name: String
    public let parentID: Int

    public init(itemID: Int, updatedAt: Date, name: String, parentID: Int) {
        self.itemID = itemID
        self.updatedAt = updatedAt
        self.name = name
        self.parentID = parentID
    }

    public init?(data: Data) {
        if let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.version == Self.currentVersion,
           payload.itemID > 0,
           payload.parentID > 0,
           payload.name.isEmpty == false {
            self.init(
                itemID: payload.itemID,
                updatedAt: Date(timeIntervalSince1970: payload.updatedAt),
                name: payload.name,
                parentID: payload.parentID
            )
            return
        }
        guard let rawValue = String(data: data, encoding: .utf8) else { return nil }
        self.init(rawValue: rawValue)
    }

    public init?(rawValue: String) {
        guard let parentSeparator = rawValue.lastIndex(of: "-"),
              let itemSeparator = rawValue.firstIndex(of: "-") else {
            return nil
        }

        let parentSubstring = rawValue[rawValue.index(after: parentSeparator)...]
        let prefix = rawValue[..<parentSeparator]
        let timestampStart = rawValue.index(after: itemSeparator)
        guard let timestampSeparator = prefix[timestampStart...].firstIndex(of: "-") else {
            return nil
        }

        let itemSubstring = rawValue[..<itemSeparator]
        let timestampSubstring = rawValue[timestampStart..<timestampSeparator]
        let nameStart = rawValue.index(after: timestampSeparator)
        let name = String(rawValue[nameStart..<parentSeparator])

        guard let itemID = Int(itemSubstring),
              let timestamp = TimeInterval(timestampSubstring),
              let parentID = Int(parentSubstring),
              itemID > 0,
              parentID > 0,
              name.isEmpty == false else {
            return nil
        }

        self.itemID = itemID
        self.updatedAt = Date(timeIntervalSince1970: timestamp)
        self.name = name
        self.parentID = parentID
    }

    public var data: Data {
        let payload = Payload(
            version: Self.currentVersion,
            itemID: itemID,
            updatedAt: updatedAt.timeIntervalSince1970,
            name: name,
            parentID: parentID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }

    public var rawValue: String {
        "\(itemID)-\(updatedAt.timeIntervalSince1970)-\(name)-\(parentID)"
    }

    public func matchesIdentityNameAndParent(of item: KDriveRemoteItem) -> Bool {
        itemID == item.id && name == item.name && parentID == item.parentID
    }

    public func matches(itemID expectedItemID: Int, name expectedName: String, parentID expectedParentID: Int) -> Bool {
        itemID == expectedItemID && name == expectedName && parentID == expectedParentID
    }

    private struct Payload: Codable {
        let version: Int
        let itemID: Int
        let updatedAt: TimeInterval
        let name: String
        let parentID: Int
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
        var selectedActions: [KDriveRemoteFileAction] = []
        var selectedFileIDs = Set<Int>()
        for action in actions where selectedFileIDs.insert(action.fileID).inserted {
            selectedActions.append(action)
        }
        try KDriveListingValidator.validateAdvancedActions(selectedActions, actionItems: actionItems)

        let actionItemsByID = Dictionary(actionItems.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var updatedItems: [KDriveRemoteItem] = []
        var deletedItemIDs = Set<Int>()

        for action in selectedActions {
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
    public enum MetadataMutationState: Equatable, Sendable {
        case base
        case desired
    }

    public static func contentMatches(baseVersion: Data, remoteItem: KDriveRemoteItem) -> Bool {
        KDriveItemContentVersion(data: baseVersion)?.authoritativelyMatches(remoteItem) == true
    }

    public static func metadataMatches(baseVersion: Data, remoteItem: KDriveRemoteItem) -> Bool {
        baseVersion == remoteItem.metadataVersion
    }

    public static func metadataMatchesBaseStateIgnoringTimestamp(baseVersion: Data, remoteItem: KDriveRemoteItem) -> Bool {
        guard let baseMetadata = KDriveItemMetadataVersion(data: baseVersion) else {
            return metadataMatches(baseVersion: baseVersion, remoteItem: remoteItem)
        }

        return baseMetadata.matchesIdentityNameAndParent(of: remoteItem)
    }

    public static func metadataMutationState(
        baseVersion: Data,
        remoteItem: KDriveRemoteItem,
        desiredName: String,
        desiredParentID: Int
    ) -> MetadataMutationState? {
        guard let baseMetadata = KDriveItemMetadataVersion(data: baseVersion) else {
            return metadataMatches(baseVersion: baseVersion, remoteItem: remoteItem) ? .base : nil
        }

        if baseMetadata.matchesIdentityNameAndParent(of: remoteItem) {
            return .base
        }

        let latestMetadata = KDriveItemMetadataVersion(
            itemID: remoteItem.id,
            updatedAt: remoteItem.updatedAt,
            name: remoteItem.name,
            parentID: remoteItem.parentID
        )
        if latestMetadata.matches(itemID: baseMetadata.itemID, name: desiredName, parentID: desiredParentID) {
            return .desired
        }

        return nil
    }

    public static func itemVersionMatches(contentVersion: Data, metadataVersion: Data, remoteItem: KDriveRemoteItem) -> Bool {
        contentMatches(baseVersion: contentVersion, remoteItem: remoteItem)
            && metadataMatches(baseVersion: metadataVersion, remoteItem: remoteItem)
    }

    public static func itemVersionMatchesAllowingMetadataTimestampDrift(
        contentVersion: Data,
        metadataVersion: Data,
        remoteItem: KDriveRemoteItem
    ) -> Bool {
        contentMatches(baseVersion: contentVersion, remoteItem: remoteItem)
            && metadataMatchesBaseStateIgnoringTimestamp(baseVersion: metadataVersion, remoteItem: remoteItem)
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
    case workingSet
    case trash
    case item(Int)

    public init(rawValue: String) throws {
        switch rawValue {
        case "NSFileProviderRootContainerItemIdentifier":
            self = .root
        case "NSFileProviderWorkingSetContainerItemIdentifier":
            self = .workingSet
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
        case .workingSet, .trash:
            return nil
        case .item(let id):
            return id
        }
    }

    public var rawValue: String {
        switch self {
        case .root:
            return "NSFileProviderRootContainerItemIdentifier"
        case .workingSet:
            return "NSFileProviderWorkingSetContainerItemIdentifier"
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

public enum KDriveContainerValidationError: Error, Equatable, LocalizedError, Sendable {
    case notAContainer(fileID: Int)

    public var errorDescription: String? {
        switch self {
        case .notAContainer(let fileID):
            return "kDrive item '\(fileID)' is not a container."
        }
    }
}

public enum KDriveContainerValidator {
    public static func validate(_ item: KDriveRemoteItem, expectedFileID: Int) throws {
        guard item.id == expectedFileID, item.isDirectory else {
            throw KDriveContainerValidationError.notAContainer(fileID: expectedFileID)
        }
    }
}
