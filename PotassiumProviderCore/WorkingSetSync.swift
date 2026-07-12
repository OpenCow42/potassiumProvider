import Foundation

public struct KDriveMaterializedItem: Codable, Equatable, Sendable {
    public let fileID: Int
    public let isContainer: Bool

    public init(fileID: Int, isContainer: Bool) {
        self.fileID = fileID
        self.isContainer = isContainer
    }
}

public struct KDrivePartialActivityResult: Equatable, Sendable {
    public let fileID: Int
    public let lastAction: String?
    public let lastActionAt: Date?
    public let item: KDriveRemoteItem?

    public init(fileID: Int, lastAction: String?, lastActionAt: Date?, item: KDriveRemoteItem?) {
        self.fileID = fileID
        self.lastAction = lastAction
        self.lastActionAt = lastActionAt
        self.item = item
    }

    public var isDeletion: Bool {
        guard let lastAction else { return false }
        return KDriveListingValidator.actionKind(for: lastAction) == .delete
    }
}

public protocol KDriveWorkingSetRemoteProviding: Sendable {
    func listWorkingSetRelevantItems(driveID: Int, latestLimit: Int) async throws -> [KDriveRemoteItem]
    func listPartialActivities(
        driveID: Int,
        fileIDs: [Int],
        since: Date
    ) async throws -> [KDrivePartialActivityResult]
}

public struct KDriveWorkingSetSnapshot: Equatable, Sendable {
    public let anchor: String
    public let items: [KDriveRemoteItem]

    public init(anchor: String, items: [KDriveRemoteItem]) {
        self.anchor = anchor
        self.items = items
    }
}

public struct KDriveWorkingSetChanges: Equatable, Sendable {
    public let changes: KDriveSnapshotChangeSet
    public let anchor: String

    public init(changes: KDriveSnapshotChangeSet, anchor: String) {
        self.changes = changes
        self.anchor = anchor
    }
}

public protocol KDriveWorkingSetStateStoring: Sendable {
    func replaceMaterializedItems(
        _ items: [KDriveMaterializedItem],
        domainIdentifier: String
    ) async throws
    func materializedItems(domainIdentifier: String) async throws -> [KDriveMaterializedItem]
    func workingSetSnapshot(domainIdentifier: String) async throws -> KDriveWorkingSetSnapshot?
    func workingSetChanges(
        domainIdentifier: String,
        from anchor: String
    ) async throws -> KDriveWorkingSetChanges?
    func lastSuccessfulWorkingSetPoll(domainIdentifier: String) async throws -> Date?
    func claimWorkingSetPoll(
        domainIdentifier: String,
        now: Date,
        minimumInterval: TimeInterval
    ) async throws -> Bool
    func commitWorkingSetPoll(
        domainIdentifier: String,
        items: [KDriveRemoteItem],
        changes: KDriveSnapshotChangeSet,
        completedAt: Date
    ) async throws -> KDriveWorkingSetSnapshot
}

public struct KDriveWorkingSetPollOutcome: Equatable, Sendable {
    public let didPoll: Bool
    public let changes: KDriveSnapshotChangeSet
    public let snapshot: KDriveWorkingSetSnapshot?

    public init(didPoll: Bool, changes: KDriveSnapshotChangeSet, snapshot: KDriveWorkingSetSnapshot?) {
        self.didPoll = didPoll
        self.changes = changes
        self.snapshot = snapshot
    }
}

/// Polls only the remote state that can affect File Provider's working set.
///
/// File Provider extensions are not guaranteed to stay alive. This coordinator
/// therefore persists both its throttle and change anchors, and deliberately
/// accepts that remote changes can be delayed while the extension is suspended.
public struct KDriveWorkingSetPollCoordinator: Sendable {
    public static let pollingInterval: TimeInterval = 60
    public static let latestItemLimit = 200
    public static let partialActivityBatchSize = 200

    private let domainIdentifier: String
    private let driveID: Int
    private let rootFileID: Int
    private let remote: any KDriveFileProviding
    private let workingSetRemote: any KDriveWorkingSetRemoteProviding
    private let snapshotStore: any KDriveSnapshotStoring
    private let stateStore: any KDriveWorkingSetStateStoring

    public init(
        domainIdentifier: String,
        driveID: Int,
        rootFileID: Int,
        remote: any KDriveFileProviding,
        workingSetRemote: any KDriveWorkingSetRemoteProviding,
        snapshotStore: any KDriveSnapshotStoring,
        stateStore: any KDriveWorkingSetStateStoring
    ) {
        self.domainIdentifier = domainIdentifier
        self.driveID = driveID
        self.rootFileID = rootFileID
        self.remote = remote
        self.workingSetRemote = workingSetRemote
        self.snapshotStore = snapshotStore
        self.stateStore = stateStore
    }

    public func poll(
        now: Date = Date(),
        minimumInterval: TimeInterval = Self.pollingInterval
    ) async throws -> KDriveWorkingSetPollOutcome {
        let claimed = try await stateStore.claimWorkingSetPoll(
            domainIdentifier: domainIdentifier,
            now: now,
            minimumInterval: minimumInterval
        )
        guard claimed else {
            return KDriveWorkingSetPollOutcome(
                didPoll: false,
                changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: []),
                snapshot: try await stateStore.workingSetSnapshot(domainIdentifier: domainIdentifier)
            )
        }

        let oldWorkingSet = try await stateStore.workingSetSnapshot(domainIdentifier: domainIdentifier)
        let lastSuccessfulPoll = try await stateStore.lastSuccessfulWorkingSetPoll(domainIdentifier: domainIdentifier)
        let materialized = try await stateStore.materializedItems(domainIdentifier: domainIdentifier)
        let materializedContainerIDs = Set(materialized.filter(\.isContainer).map(\.fileID))
        let materializedFileIDs = Set(materialized.filter { !$0.isContainer }.map(\.fileID))

        var relevantItems = try await workingSetRemote.listWorkingSetRelevantItems(
            driveID: driveID,
            latestLimit: Self.latestItemLimit
        )
        var changedItems: [KDriveRemoteItem] = []
        var deletedItemIDs = Set<Int>()

        for folderID in materializedContainerIDs.sorted() {
            let result = try await pollMaterializedContainer(folderID: folderID)
            relevantItems.append(contentsOf: result.snapshot.items)
            changedItems.append(contentsOf: result.changes.updatedItems)
            deletedItemIDs.formUnion(result.changes.deletedItemIDs)
        }
        relevantItems.append(contentsOf: changedItems)

        let oldItemsByID = Dictionary(uniqueKeysWithValues: (oldWorkingSet?.items ?? []).map { ($0.id, $0) })
        let relevantFileIDs = Set(relevantItems.map(\.id)).union(materializedFileIDs)
        let partialSince = lastSuccessfulPoll ?? Date(timeIntervalSince1970: 0)
        for fileIDBatch in relevantFileIDs.sorted().chunked(maximumCount: Self.partialActivityBatchSize) {
            let activities = try await workingSetRemote.listPartialActivities(
                driveID: driveID,
                fileIDs: fileIDBatch,
                since: partialSince
            )
            for activity in activities {
                if activity.isDeletion {
                    deletedItemIDs.insert(activity.fileID)
                } else if let item = activity.item {
                    changedItems.append(item)
                    relevantItems.append(item)
                } else if let oldItem = oldItemsByID[activity.fileID] {
                    relevantItems.append(oldItem)
                }
            }
        }

        var currentItemsByID = Dictionary(
            relevantItems.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        for fileID in deletedItemIDs {
            currentItemsByID[fileID] = nil
        }

        let currentItems = currentItemsByID.values.sorted(by: Self.workingSetOrder)
        let newlyRelevantItems = currentItems.filter { oldItemsByID[$0.id] != $0 }
        let updates = Self.uniqueItems(changedItems + newlyRelevantItems)
            .filter { deletedItemIDs.contains($0.id) == false }
        let changes = KDriveSnapshotChangeSet(
            updatedItems: updates,
            deletedItemIDs: deletedItemIDs.sorted()
        )
        let snapshot = try await stateStore.commitWorkingSetPoll(
            domainIdentifier: domainIdentifier,
            items: currentItems,
            changes: changes,
            completedAt: now
        )
        return KDriveWorkingSetPollOutcome(didPoll: true, changes: changes, snapshot: snapshot)
    }

    private func pollMaterializedContainer(
        folderID: Int
    ) async throws -> (snapshot: KDriveSnapshot, changes: KDriveSnapshotChangeSet) {
        let containerIdentifier = folderID == rootFileID ? "root" : String(folderID)
        guard let oldSnapshot = try await snapshotStore.snapshot(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier
        ), oldSnapshot.usesAdvancedListing, oldSnapshot.isFullyEnumerated,
              let serverCursor = oldSnapshot.serverCursor else {
            let rebuilt = try await rebuildMaterializedContainer(folderID: folderID)
            try await snapshotStore.save(
                rebuilt,
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier,
                condition: .unconditional
            )
            return (
                rebuilt,
                KDriveSnapshotChangeSet(updatedItems: rebuilt.items, deletedItemIDs: [])
            )
        }

        do {
            var snapshot = oldSnapshot
            var cursor = serverCursor
            var allUpdatedItems: [KDriveRemoteItem] = []
            var allDeletedIDs = Set<Int>()

            while true {
                let response = try await remote.listAdvancedDirectory(
                    driveID: driveID,
                    folderID: folderID,
                    cursor: cursor,
                    limit: 200
                )
                let nextCursor = try KDriveListingValidator.validatedNextCursor(
                    currentCursor: cursor,
                    nextCursor: response.nextCursor,
                    hasMore: response.hasMore
                ) ?? cursor
                let applied = try KDriveAdvancedActionReducer.applying(
                    actions: response.actions,
                    actionItems: response.actionItems,
                    to: snapshot,
                    anchor: nextCursor,
                    serverCursor: nextCursor
                )
                snapshot = applied.snapshot
                allUpdatedItems.append(contentsOf: applied.changes.updatedItems)
                allDeletedIDs.formUnion(applied.changes.deletedItemIDs)
                var handledActionFileIDs = Set<Int>()
                for action in response.actions
                where handledActionFileIDs.insert(action.fileID).inserted && action.action == "file_move_out" {
                    do {
                        let movedItem = try await remote.item(driveID: driveID, fileID: action.fileID)
                        allUpdatedItems.append(movedItem)
                        allDeletedIDs.remove(action.fileID)
                    } catch {
                        guard KDriveRemoteErrorClassifier.apiRejection(from: error)?.statusCode == 404 else {
                            throw error
                        }
                    }
                }
                cursor = nextCursor
                if !response.hasMore { break }
            }

            try await snapshotStore.save(
                snapshot,
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier,
                condition: .matching(anchor: oldSnapshot.anchor, serverCursor: oldSnapshot.serverCursor)
            )
            return (
                snapshot,
                KDriveSnapshotChangeSet(
                    updatedItems: Self.uniqueItems(allUpdatedItems),
                    deletedItemIDs: allDeletedIDs.sorted()
                )
            )
        } catch let error where KDriveRemoteErrorClassifier.isInvalidCursor(error) {
            let rebuilt = try await rebuildMaterializedContainer(folderID: folderID)
            let changes = KDriveSnapshotDiffer.changes(from: oldSnapshot, to: rebuilt)
            try await snapshotStore.save(
                rebuilt,
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier,
                condition: .matching(anchor: oldSnapshot.anchor, serverCursor: oldSnapshot.serverCursor)
            )
            return (rebuilt, changes)
        }
    }

    private func rebuildMaterializedContainer(folderID: Int) async throws -> KDriveSnapshot {
        var itemsByID: [Int: KDriveRemoteItem] = [:]
        var cursor: String?
        var finalCursor: String?
        var seenCursors = Set<String>()

        while true {
            let response = try await remote.listAdvancedDirectory(
                driveID: driveID,
                folderID: folderID,
                cursor: cursor,
                limit: 200
            )
            try KDriveListingValidator.validateAdvancedActions(response.actions, actionItems: response.actionItems)
            for item in response.items { itemsByID[item.id] = item }
            finalCursor = try KDriveListingValidator.validatedNextCursor(
                currentCursor: cursor,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore,
                seenCursors: &seenCursors
            ) ?? cursor
            guard response.hasMore, let nextCursor = finalCursor else { break }
            cursor = nextCursor
        }

        return KDriveSnapshot(
            anchor: finalCursor ?? UUID().uuidString,
            serverCursor: finalCursor,
            isFullyEnumerated: true,
            usesAdvancedListing: true,
            items: itemsByID.values.sorted(by: Self.workingSetOrder)
        )
    }

    private static func uniqueItems(_ items: [KDriveRemoteItem]) -> [KDriveRemoteItem] {
        var byID: [Int: KDriveRemoteItem] = [:]
        for item in items { byID[item.id] = item }
        return byID.values.sorted(by: workingSetOrder)
    }

    private static func workingSetOrder(_ lhs: KDriveRemoteItem, _ rhs: KDriveRemoteItem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0, isEmpty == false else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map {
            Array(self[$0..<Swift.min($0 + maximumCount, count)])
        }
    }
}
