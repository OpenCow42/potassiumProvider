import Foundation

public struct KDriveSnapshot: Codable, Equatable, Sendable {
    public let anchor: String
    public let serverCursor: String?
    public let isFullyEnumerated: Bool
    public let usesAdvancedListing: Bool
    public let items: [KDriveRemoteItem]

    public enum CodingKeys: String, CodingKey {
        case anchor
        case serverCursor
        case isFullyEnumerated
        case usesAdvancedListing
        case items
    }

    public init(
        anchor: String = UUID().uuidString,
        serverCursor: String? = nil,
        isFullyEnumerated: Bool = false,
        usesAdvancedListing: Bool = false,
        items: [KDriveRemoteItem]
    ) {
        self.anchor = anchor
        self.serverCursor = serverCursor
        self.isFullyEnumerated = isFullyEnumerated
        self.usesAdvancedListing = usesAdvancedListing
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.anchor = try container.decode(String.self, forKey: .anchor)
        self.serverCursor = try container.decodeIfPresent(String.self, forKey: .serverCursor)
        self.isFullyEnumerated = try container.decodeIfPresent(Bool.self, forKey: .isFullyEnumerated) ?? false
        self.usesAdvancedListing = try container.decodeIfPresent(Bool.self, forKey: .usesAdvancedListing) ?? false
        self.items = try container.decode([KDriveRemoteItem].self, forKey: .items)
    }
}

public struct KDriveSnapshotChangeSet: Equatable, Sendable {
    public let updatedItems: [KDriveRemoteItem]
    public let deletedItemIDs: [Int]

    public init(updatedItems: [KDriveRemoteItem], deletedItemIDs: [Int]) {
        self.updatedItems = updatedItems
        self.deletedItemIDs = deletedItemIDs
    }

    public var isEmpty: Bool {
        updatedItems.isEmpty && deletedItemIDs.isEmpty
    }
}

public enum KDriveSnapshotDiffer {
    public static func changes(from oldSnapshot: KDriveSnapshot?, to newSnapshot: KDriveSnapshot) -> KDriveSnapshotChangeSet {
        guard let oldSnapshot else {
            return KDriveSnapshotChangeSet(updatedItems: newSnapshot.items, deletedItemIDs: [])
        }

        let oldItemsByID = Dictionary(uniqueKeysWithValues: oldSnapshot.items.map { ($0.id, $0) })
        let newItemsByID = Dictionary(uniqueKeysWithValues: newSnapshot.items.map { ($0.id, $0) })
        let updatedItems = newSnapshot.items.filter { oldItemsByID[$0.id] != $0 }
        let deletedItemIDs = oldItemsByID.keys.filter { newItemsByID[$0] == nil }.sorted()

        return KDriveSnapshotChangeSet(updatedItems: updatedItems, deletedItemIDs: deletedItemIDs)
    }
}
