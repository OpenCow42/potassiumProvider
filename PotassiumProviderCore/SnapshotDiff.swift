import Foundation

public struct KDriveSnapshot: Codable, Equatable, Sendable {
    public let anchor: String
    public let items: [KDriveRemoteItem]

    public init(anchor: String = UUID().uuidString, items: [KDriveRemoteItem]) {
        self.anchor = anchor
        self.items = items
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
