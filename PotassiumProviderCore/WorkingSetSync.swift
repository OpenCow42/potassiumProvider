import Foundation
import InfomaniakConcurrency

public struct KDriveMaterializedItem: Codable, Equatable, Sendable {
    public let fileID: Int
    public let isContainer: Bool

    public init(fileID: Int, isContainer: Bool) {
        self.fileID = fileID
        self.isContainer = isContainer
    }
}

/// A prepared materialized-container snapshot that must commit with the
/// working-set change batch produced by the same remote poll.
public struct KDriveWorkingSetContainerSnapshotUpdate: Equatable, Sendable {
    public let containerIdentifier: String
    public let snapshot: KDriveSnapshot
    public let condition: KDriveSnapshotSaveCondition

    public init(
        containerIdentifier: String,
        snapshot: KDriveSnapshot,
        condition: KDriveSnapshotSaveCondition
    ) {
        self.containerIdentifier = containerIdentifier
        self.snapshot = snapshot
        self.condition = condition
    }
}

extension KDriveSnapshot {
    func isSameAdvancedListingResult(as other: KDriveSnapshot) -> Bool {
        usesAdvancedListing && other.usesAdvancedListing && isFullyEnumerated && other.isFullyEnumerated &&
            serverCursor != nil && serverCursor == other.serverCursor &&
            items.sorted { $0.id < $1.id } == other.items.sorted { $0.id < $1.id }
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
        guard let lastAction, !isMoveOut else { return false }
        return KDriveListingValidator.actionKind(for: lastAction) == .delete
    }

    /// A move-out removes an item from one container listing, but partial
    /// activity follows the item itself and must resolve its current parent.
    var isMoveOut: Bool {
        lastAction == "file_move_out"
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

public enum KDriveWorkingSetCommitCondition: Sendable {
    case unconditional
    case matchingAnchor(String?)
}

public protocol KDriveWorkingSetStateStoring: Sendable {
    func snapshot(domainIdentifier: String, containerIdentifier: String) async throws -> KDriveSnapshot?
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
        containerSnapshotUpdates: [KDriveWorkingSetContainerSnapshotUpdate],
        items: [KDriveRemoteItem],
        changes: KDriveSnapshotChangeSet,
        completedAt: Date,
        condition: KDriveWorkingSetCommitCondition
    ) async throws -> KDriveWorkingSetSnapshot
    func publishKnownWorkingSetItem(_ item: KDriveRemoteItem, replacing expectedItem: KDriveRemoteItem?,
                                   domainIdentifier: String, recordedAt: Date) async throws -> Bool
}

public extension KDriveWorkingSetStateStoring {
    func commitWorkingSetPoll(domainIdentifier: String, containerSnapshotUpdates: [KDriveWorkingSetContainerSnapshotUpdate],
                              items: [KDriveRemoteItem], changes: KDriveSnapshotChangeSet,
                              completedAt: Date) async throws -> KDriveWorkingSetSnapshot {
        try await commitWorkingSetPoll(domainIdentifier: domainIdentifier, containerSnapshotUpdates: containerSnapshotUpdates,
            items: items, changes: changes, completedAt: completedAt, condition: .unconditional)
    }
}

/// Deliver committed journal entries before waiting for another remote crawl.
/// Empty journals still refresh normally; an expired anchor stays expired.
public enum KDriveWorkingSetChangeDelivery {
    public static func changes(domainIdentifier: String, from anchor: String,
                               store: any KDriveWorkingSetStateStoring,
                               refresh: @escaping @Sendable () async throws -> Void) async throws -> KDriveWorkingSetChanges? {
        try Task.checkCancellation()
        if let cached = try await store.workingSetChanges(domainIdentifier: domainIdentifier, from: anchor),
           !cached.changes.isEmpty { return cached }
        // Keep the refresh inside the callback lifetime. Polling cooperatively
        // stops when a newer journal supersedes its starting snapshot.
        try await refresh()
        try Task.checkCancellation()
        return try await store.workingSetChanges(domainIdentifier: domainIdentifier, from: anchor)
    }
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
    private static let maximumConcurrentContainerPolls = 4

    private let domainIdentifier: String
    private let driveID: Int
    private let rootFileID: Int
    private let remote: any KDriveFileProviding
    private let workingSetRemote: any KDriveWorkingSetRemoteProviding
    private let stateStore: any KDriveWorkingSetStateStoring

    public init(
        domainIdentifier: String,
        driveID: Int,
        rootFileID: Int,
        remote: any KDriveFileProviding,
        workingSetRemote: any KDriveWorkingSetRemoteProviding,
        stateStore: any KDriveWorkingSetStateStoring
    ) {
        self.domainIdentifier = domainIdentifier
        self.driveID = driveID
        self.rootFileID = rootFileID
        self.remote = remote
        self.workingSetRemote = workingSetRemote
        self.stateStore = stateStore
    }

    public func poll(
        now: Date = Date(),
        minimumInterval: TimeInterval = Self.pollingInterval,
        coalescePendingMaterializationPolls: Bool = false,
        onSnapshotRetry: @Sendable () async -> Void = {}
    ) async throws -> KDriveWorkingSetPollOutcome {
        try await WorkingSetPollScheduling.shared.withPermit(domainIdentifier: domainIdentifier,
            coalescePending: coalescePendingMaterializationPolls) {
            try await pollExclusively(now: now, minimumInterval: minimumInterval, onSnapshotRetry: onSnapshotRetry)
        }
    }

    private func pollExclusively(now: Date, minimumInterval: TimeInterval,
                                onSnapshotRetry: @Sendable () async -> Void) async throws -> KDriveWorkingSetPollOutcome {
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

        // Enumeration can commit a newer container while the remote poll is
        // in flight. Retry the complete read/prepare/transaction, never the
        // stale write. Failed transactions leave every cursor and watermark
        // unchanged. Keep the original throttle claim and bound contention.
        for attempt in 0...2 {
            try Task.checkCancellation()
            do { return try await pollClaimed(now: now) }
            catch WorkingSetPollSuperseded.newerJournal {
                return KDriveWorkingSetPollOutcome(didPoll: false,
                    changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: []),
                    snapshot: try await stateStore.workingSetSnapshot(domainIdentifier: domainIdentifier))
            }
            catch let error as KDriveSnapshotStoreError where error == .staleSnapshot(
                domainIdentifier: domainIdentifier, containerIdentifier: "working-set") {
                return KDriveWorkingSetPollOutcome(didPoll: false,
                    changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: []),
                    snapshot: try await stateStore.workingSetSnapshot(domainIdentifier: domainIdentifier))
            }
            catch KDriveSnapshotStoreError.staleSnapshot where attempt < 2 {
                await onSnapshotRetry()
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        preconditionFailure("The final poll attempt returns or throws")
    }

    private func pollClaimed(now: Date) async throws -> KDriveWorkingSetPollOutcome {
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
        var containerSnapshotUpdates: [KDriveWorkingSetContainerSnapshotUpdate] = []

        // Independent folders can be read together, but their cursors and the
        // working-set journal still commit as one guarded transaction. Bound
        // requests instead of making Finder wait for every folder serially.
        let containerResults = try await materializedContainerIDs.sorted().concurrentMap(
            customConcurrency: Self.maximumConcurrentContainerPolls
        ) { folderID in
            try await self.requireWorkingSetAnchor(oldWorkingSet?.anchor)
            return try await self.pollMaterializedContainer(folderID: folderID)
        }
        for result in containerResults {
            relevantItems.append(contentsOf: result.snapshot.items)
            changedItems.append(contentsOf: result.changes.updatedItems)
            deletedItemIDs.formUnion(result.changes.deletedItemIDs)
            containerSnapshotUpdates.append(result.snapshotUpdate)
        }
        relevantItems.append(contentsOf: changedItems)

        let oldItemsByID = Dictionary(uniqueKeysWithValues: (oldWorkingSet?.items ?? []).map { ($0.id, $0) })
        let relevantFileIDs = Set(relevantItems.map(\.id)).union(materializedFileIDs)
        let partialSince = lastSuccessfulPoll ?? Date(timeIntervalSince1970: 0)
        for fileIDBatch in relevantFileIDs.sorted().chunked(maximumCount: Self.partialActivityBatchSize) {
            try await requireWorkingSetAnchor(oldWorkingSet?.anchor)
            let activities = try await workingSetRemote.listPartialActivities(
                driveID: driveID,
                fileIDs: fileIDBatch,
                since: partialSince
            )
            for activity in activities {
                if activity.isMoveOut {
                    if let movedItem = try await currentItem(forMoveOut: activity) {
                        deletedItemIDs.remove(activity.fileID)
                        changedItems.append(movedItem)
                        relevantItems.append(movedItem)
                    } else {
                        deletedItemIDs.insert(activity.fileID)
                    }
                } else if activity.isDeletion {
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
        try await requireWorkingSetAnchor(oldWorkingSet?.anchor)
        let snapshot = try await stateStore.commitWorkingSetPoll(
            domainIdentifier: domainIdentifier,
            containerSnapshotUpdates: containerSnapshotUpdates,
            items: currentItems,
            changes: changes,
            completedAt: now,
            condition: .matchingAnchor(oldWorkingSet?.anchor)
        )
        return KDriveWorkingSetPollOutcome(didPoll: true, changes: changes, snapshot: snapshot)
    }

    private func requireWorkingSetAnchor(_ expected: String?) async throws {
        try Task.checkCancellation()
        if try await stateStore.workingSetSnapshot(domainIdentifier: domainIdentifier)?.anchor != expected {
            // Discard prepared container updates. The new journal is already
            // durable; this poll must not overwrite it or advance watermarks.
            throw WorkingSetPollSuperseded.newerJournal
        }
    }

    private func currentItem(
        forMoveOut activity: KDrivePartialActivityResult
    ) async throws -> KDriveRemoteItem? {
        if let item = activity.item {
            return item
        }

        do {
            return try await remote.item(driveID: driveID, fileID: activity.fileID)
        } catch {
            guard KDriveRemoteErrorClassifier.apiRejection(from: error)?.statusCode == 404 else {
                throw error
            }
            return nil
        }
    }

    private func pollMaterializedContainer(
        folderID: Int
    ) async throws -> (
        snapshot: KDriveSnapshot,
        changes: KDriveSnapshotChangeSet,
        snapshotUpdate: KDriveWorkingSetContainerSnapshotUpdate
    ) {
        let containerIdentifier = folderID == rootFileID ? "root" : String(folderID)
        let storedSnapshot = try await stateStore.snapshot(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier
        )
        let saveCondition: KDriveSnapshotSaveCondition
        if let storedSnapshot {
            saveCondition = .matching(
                anchor: storedSnapshot.anchor,
                serverCursor: storedSnapshot.serverCursor
            )
        } else {
            saveCondition = .missing
        }

        guard let oldSnapshot = storedSnapshot,
              oldSnapshot.usesAdvancedListing, oldSnapshot.isFullyEnumerated,
              let serverCursor = oldSnapshot.serverCursor else {
            let rebuilt = try await rebuildMaterializedContainer(folderID: folderID)
            return (
                rebuilt,
                KDriveSnapshotChangeSet(updatedItems: rebuilt.items, deletedItemIDs: []),
                KDriveWorkingSetContainerSnapshotUpdate(
                    containerIdentifier: containerIdentifier,
                    snapshot: rebuilt,
                    condition: saveCondition
                )
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

            return (
                snapshot,
                KDriveSnapshotChangeSet(
                    updatedItems: Self.uniqueItems(allUpdatedItems),
                    deletedItemIDs: allDeletedIDs.sorted()
                ),
                KDriveWorkingSetContainerSnapshotUpdate(
                    containerIdentifier: containerIdentifier,
                    snapshot: snapshot,
                    condition: saveCondition
                )
            )
        } catch let error where KDriveRemoteErrorClassifier.isInvalidCursor(error) {
            let rebuilt = try await rebuildMaterializedContainer(folderID: folderID)
            let changes = KDriveSnapshotDiffer.changes(from: oldSnapshot, to: rebuilt)
            return (
                rebuilt,
                changes,
                KDriveWorkingSetContainerSnapshotUpdate(
                    containerIdentifier: containerIdentifier,
                    snapshot: rebuilt,
                    condition: saveCondition
                )
            )
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

private enum WorkingSetPollSuperseded: Error { case newerJournal }

/// Materialization notifications request an immediate poll while enumeration
/// and the timer can also poll. The persisted interval is a throttle, not an
/// in-flight lock (notably when the interval is zero). Serialize these callers
/// per domain while retaining cancellation and the snapshot transaction guards.
actor WorkingSetPollScheduling {
    static let shared = WorkingSetPollScheduling()
    private struct Entry {
        let limiter = AsyncOperationLimiter(maxConcurrentOperations: 1)
        var clients = 0
        var requestNumber: UInt64 = 0
        var completed: (coveredRequest: UInt64, outcome: KDriveWorkingSetPollOutcome)?
    }
    private var entries: [String: Entry] = [:]

    func pendingRequestCount(domainIdentifier: String) -> Int { entries[domainIdentifier]?.clients ?? 0 }

    func withPermit(domainIdentifier: String, coalescePending: Bool = false,
                    operation: @Sendable () async throws -> KDriveWorkingSetPollOutcome) async throws -> KDriveWorkingSetPollOutcome {
        var entry = entries[domainIdentifier] ?? Entry()
        entry.clients += 1
        entry.requestNumber += 1
        let requestNumber = entry.requestNumber
        entries[domainIdentifier] = entry
        defer {
            if var remaining = entries[domainIdentifier] {
                remaining.clients -= 1
                entries[domainIdentifier] = remaining.clients == 0 ? nil : remaining
            }
        }
        return try await entry.limiter.withPermit {
            try await self.perform(domainIdentifier: domainIdentifier, requestNumber: requestNumber,
                                   coalescePending: coalescePending, operation: operation)
        }
    }

    private func perform(domainIdentifier: String, requestNumber: UInt64, coalescePending: Bool,
                         operation: @Sendable () async throws -> KDriveWorkingSetPollOutcome) async throws -> KDriveWorkingSetPollOutcome {
        try Task.checkCancellation()
        guard let entry = entries[domainIdentifier] else { throw CancellationError() }
        if coalescePending, let completed = entry.completed, completed.coveredRequest >= requestNumber {
            return KDriveWorkingSetPollOutcome(didPoll: false,
                changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: []), snapshot: completed.outcome.snapshot)
        }
        // Every request in this batch persisted its materialized set before
        // entering the queue. Only a successful poll which STARTS after those
        // requests may satisfy them; arrivals during its I/O require another poll.
        let coveredRequest = entry.requestNumber
        let outcome = try await operation()
        if outcome.didPoll { entries[domainIdentifier]?.completed = (coveredRequest, outcome) }
        return outcome
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
