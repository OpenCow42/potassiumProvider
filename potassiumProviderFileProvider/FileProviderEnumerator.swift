import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let domain: NSFileProviderDomain

    init(containerItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain) {
        self.containerItemIdentifier = containerItemIdentifier
        self.domain = domain
        super.init()
        FileProviderLog.enumeration.debug("init enumerator container(\(self.containerItemIdentifier.rawValue, privacy: .public)) kind(\(self.snapshotContainerIdentifier, privacy: .public)) domain(\(self.domain.identifier.rawValue, privacy: .public))")
    }

    func invalidate() {
        FileProviderLog.enumeration.debug("invalidate enumerator container(\(self.containerItemIdentifier.rawValue, privacy: .public)) domain(\(self.domain.identifier.rawValue, privacy: .public))")
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let cursor = FileProviderPageCodec.cursor(from: page)
        FileProviderLog.enumeration.debug("enumerateItems start container(\(self.containerItemIdentifier.rawValue, privacy: .public)) kind(\(self.snapshotContainerIdentifier, privacy: .public)) cursorPresent(\(cursor != nil, privacy: .public))")
        Task {
            var runtime: FileProviderRuntime?
            do {
                let loadedRuntime = try await FileProviderRuntime.load(domain: self.domain)
                runtime = loadedRuntime
                let itemPage = try await self.listItems(runtime: loadedRuntime, startingAt: page)
                observer.didEnumerate(itemPage.items.map { FileProviderItem(remoteItem: $0, rootFileID: loadedRuntime.configuration.rootFileID) })
                FileProviderLog.enumeration.info("enumerateItems success container(\(self.containerItemIdentifier.rawValue, privacy: .public)) count(\(itemPage.items.count, privacy: .public)) nextCursorPresent(\(itemPage.nextCursor != nil, privacy: .public)) driveID(\(loadedRuntime.configuration.driveID, privacy: .public))")
                await ProviderEventRecorder.recordActivity(
                    kind: .enumeration,
                    runtime: loadedRuntime,
                    itemIdentifier: self.containerItemIdentifier.rawValue,
                    itemName: nil,
                    itemPath: nil,
                    summary: "Enumerated \(itemPage.items.count) item(s) in \(self.snapshotContainerIdentifier)."
                )
                observer.finishEnumerating(upTo: FileProviderPageCodec.page(from: itemPage.nextCursor))
            } catch {
                let mappedError = await self.recordFailure(
                    error,
                    runtime: runtime,
                    kind: .enumeration,
                    summary: "enumerate folder items."
                )
                FileProviderLog.enumeration.error("enumerateItems failed container(\(self.containerItemIdentifier.rawValue, privacy: .public)): \(mappedError.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(mappedError)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            var domainIdentifier = domain.identifier.rawValue
            var driveID = 0
            do {
                let configuration = try await FileProviderRuntime.loadConfiguration(domain: domain)
                domainIdentifier = configuration.domainIdentifier
                driveID = configuration.driveID
                let snapshotStore = try FileProviderRuntime.makeSnapshotStore()
                let snapshot = try await snapshotStore.snapshot(
                    domainIdentifier: configuration.domainIdentifier,
                    containerIdentifier: snapshotContainerIdentifier
                )
                FileProviderLog.enumeration.debug("currentSyncAnchor container(\(self.containerItemIdentifier.rawValue, privacy: .public)) snapshotPresent(\(snapshot != nil, privacy: .public))")

                if self.usesAdvancedListing {
                    guard let snapshot,
                          snapshot.usesAdvancedListing,
                          snapshot.isFullyEnumerated,
                          let serverCursor = snapshot.serverCursor else {
                        completionHandler(nil)
                        return
                    }
                    completionHandler(FileProviderPageCodec.anchor(from: serverCursor))
                } else {
                    completionHandler(snapshot.map { FileProviderPageCodec.anchor(from: $0.anchor) })
                }
            } catch {
                let mapping = providerErrorMapping(error)
                if shouldRecordGenericFailure(for: error) {
                    await ProviderEventRecorder.recordFailure(
                        kind: .syncAnchor,
                        eventStore: FileProviderRuntime.makeEventStore(),
                        domainIdentifier: domainIdentifier,
                        driveID: driveID,
                        itemIdentifier: self.containerItemIdentifier.rawValue,
                        itemName: nil,
                        itemPath: nil,
                        summary: "Could not read the current sync anchor.",
                        diagnostic: mapping.diagnostic
                    )
                }
                FileProviderLog.enumeration.error("currentSyncAnchor failed container(\(self.containerItemIdentifier.rawValue, privacy: .public)): \(mapping.mappedError.localizedDescription, privacy: .public)")
                completionHandler(nil)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let requestedAnchor = FileProviderPageCodec.anchorString(from: anchor)
        FileProviderLog.enumeration.debug("enumerateChanges start container(\(self.containerItemIdentifier.rawValue, privacy: .public)) requestedAnchorPresent(\(requestedAnchor != nil, privacy: .public))")
        Task {
            var runtime: FileProviderRuntime?
            do {
                let loadedRuntime = try await FileProviderRuntime.load(domain: self.domain)
                runtime = loadedRuntime
                if self.usesAdvancedListing {
                    try await self.enumerateAdvancedChanges(
                        for: observer,
                        runtime: loadedRuntime,
                        requestedCursor: requestedAnchor
                    )
                    return
                }

                let oldSnapshot = try await loadedRuntime.snapshotStore.snapshot(
                    domainIdentifier: loadedRuntime.configuration.domainIdentifier,
                    containerIdentifier: self.snapshotContainerIdentifier
                )
                let baselineSnapshot = oldSnapshot?.anchor == requestedAnchor ? oldSnapshot : nil
                let saveCondition = self.saveCondition(replacing: oldSnapshot)
                FileProviderLog.enumeration.debug("enumerateChanges baseline container(\(self.containerItemIdentifier.rawValue, privacy: .public)) oldSnapshotPresent(\(oldSnapshot != nil, privacy: .public)) anchorMatched(\(baselineSnapshot != nil, privacy: .public))")
                let newSnapshot = KDriveSnapshot(items: try await self.listAllItems(runtime: loadedRuntime))
                let changes = KDriveSnapshotDiffer.changes(from: baselineSnapshot, to: newSnapshot)

                try await loadedRuntime.snapshotStore.save(
                    newSnapshot,
                    domainIdentifier: loadedRuntime.configuration.domainIdentifier,
                    containerIdentifier: self.snapshotContainerIdentifier,
                    condition: saveCondition
                )
                await ThumbnailCacheInvalidation.removeCachedThumbnails(
                    for: changes,
                    previousSnapshot: baselineSnapshot,
                    runtime: loadedRuntime
                )
                self.emit(changes, to: observer, rootFileID: loadedRuntime.configuration.rootFileID)
                FileProviderLog.enumeration.info("enumerateChanges success container(\(self.containerItemIdentifier.rawValue, privacy: .public)) updated(\(changes.updatedItems.count, privacy: .public)) deleted(\(changes.deletedItemIDs.count, privacy: .public)) total(\(newSnapshot.items.count, privacy: .public))")
                await ProviderEventRecorder.recordActivity(
                    kind: .changeSync,
                    runtime: loadedRuntime,
                    itemIdentifier: self.containerItemIdentifier.rawValue,
                    itemName: nil,
                    itemPath: nil,
                    summary: "Synced \(changes.updatedItems.count) update(s) and \(changes.deletedItemIDs.count) delete(s)."
                )
                observer.finishEnumeratingChanges(upTo: FileProviderPageCodec.anchor(from: newSnapshot.anchor), moreComing: false)
            } catch {
                let mappedError = await self.recordFailure(
                    error,
                    runtime: runtime,
                    kind: .changeSync,
                    summary: "enumerate folder changes."
                )
                FileProviderLog.enumeration.error("enumerateChanges failed container(\(self.containerItemIdentifier.rawValue, privacy: .public)): \(mappedError.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(mappedError)
            }
        }
    }

    private var usesAdvancedListing: Bool {
        guard containerItemIdentifier != .workingSet,
              containerItemIdentifier != .rootContainer,
              containerItemIdentifier != .trashContainer,
              let identifier = try? KDriveItemIdentifier(rawValue: containerItemIdentifier.rawValue) else {
            return false
        }

        if case .item = identifier {
            return true
        }

        return false
    }

    private var snapshotContainerIdentifier: String {
        switch containerItemIdentifier {
        case .workingSet:
            return "working-set"
        case .rootContainer:
            return "root"
        case .trashContainer:
            return "trash"
        default:
            return containerItemIdentifier.rawValue
        }
    }

    private func recordFailure(
        _ error: Error,
        runtime: FileProviderRuntime?,
        kind: KDriveProviderActivityKind,
        summary: String
    ) async -> Error {
        let mapping = providerErrorMapping(error)
        guard shouldRecordGenericFailure(for: error) else {
            return mapping.mappedError
        }

        if let runtime {
            await ProviderEventRecorder.recordFailure(
                kind: kind,
                runtime: runtime,
                itemIdentifier: containerItemIdentifier.rawValue,
                itemName: nil,
                itemPath: nil,
                summary: "Could not \(summary)",
                diagnostic: mapping.diagnostic
            )
        } else {
            await ProviderEventRecorder.recordFailure(
                kind: providerActivityKindForRuntimeLoadFailure(error),
                eventStore: FileProviderRuntime.makeEventStore(),
                domainIdentifier: domain.identifier.rawValue,
                itemIdentifier: containerItemIdentifier.rawValue,
                itemName: nil,
                itemPath: nil,
                summary: "Could not load File Provider runtime to \(summary)",
                diagnostic: mapping.diagnostic
            )
        }

        return mapping.mappedError
    }

    private func listItems(runtime: FileProviderRuntime, startingAt page: NSFileProviderPage) async throws -> KDriveItemPage {
        if usesAdvancedListing {
            return try await listAdvancedItems(runtime: runtime, startingAt: page)
        }

        return try await listLegacyItems(runtime: runtime, startingAt: page)
    }

    private func listLegacyItems(runtime: FileProviderRuntime, startingAt page: NSFileProviderPage) async throws -> KDriveItemPage {
        let cursor = FileProviderPageCodec.cursor(from: page)
        FileProviderLog.enumeration.debug("listItems container(\(self.containerItemIdentifier.rawValue, privacy: .public)) kind(\(self.snapshotContainerIdentifier, privacy: .public)) cursorPresent(\(cursor != nil, privacy: .public))")
        switch self.containerItemIdentifier {
        case .workingSet, .rootContainer:
            return try await runtime.remote.listDirectory(
                driveID: runtime.configuration.driveID,
                folderID: runtime.configuration.rootFileID,
                cursor: cursor,
                limit: 200
            )
        case .trashContainer:
            return try await runtime.remote.listTrash(
                driveID: runtime.configuration.driveID,
                cursor: cursor,
                limit: 200
            )
        default:
            let identifier = try KDriveItemIdentifier(rawValue: self.containerItemIdentifier.rawValue)
            guard let folderID = identifier.fileID(rootFileID: runtime.configuration.rootFileID) else {
                FileProviderLog.enumeration.error("listItems cannot resolve folder identifier(\(self.containerItemIdentifier.rawValue, privacy: .public))")
                throw NSFileProviderError(.noSuchItem)
            }
            return try await runtime.remote.listDirectory(
                driveID: runtime.configuration.driveID,
                folderID: folderID,
                cursor: cursor,
                limit: 200
            )
        }
    }

    private func listAdvancedItems(runtime: FileProviderRuntime, startingAt page: NSFileProviderPage) async throws -> KDriveItemPage {
        let cursor = FileProviderPageCodec.cursor(from: page)
        let folderID = try advancedFolderID(rootFileID: runtime.configuration.rootFileID)
        FileProviderLog.enumeration.debug("listAdvancedItems container(\(self.containerItemIdentifier.rawValue, privacy: .public)) cursorPresent(\(cursor != nil, privacy: .public))")

        if cursor == nil,
           let snapshot = try await runtime.snapshotStore.snapshot(
            domainIdentifier: runtime.configuration.domainIdentifier,
            containerIdentifier: snapshotContainerIdentifier
           ),
           snapshot.usesAdvancedListing,
           snapshot.isFullyEnumerated {
            return KDriveItemPage(items: snapshot.items, nextCursor: nil, hasMore: false)
        }

        do {
            return try await fetchAndStoreAdvancedPage(
                runtime: runtime,
                folderID: folderID,
                cursor: cursor,
                replaceSnapshot: cursor == nil
            )
        } catch let error where cursor != nil && KDriveRemoteErrorClassifier.isInvalidCursor(error) {
            FileProviderLog.enumeration.error("listAdvancedItems invalid cursor; restarting container(\(self.containerItemIdentifier.rawValue, privacy: .public))")
            return try await fetchAndStoreAdvancedPage(
                runtime: runtime,
                folderID: folderID,
                cursor: nil,
                replaceSnapshot: true
            )
        }
    }

    private func fetchAndStoreAdvancedPage(
        runtime: FileProviderRuntime,
        folderID: Int,
        cursor: String?,
        replaceSnapshot: Bool
    ) async throws -> KDriveItemPage {
        let oldSnapshot = try await runtime.snapshotStore.snapshot(
            domainIdentifier: runtime.configuration.domainIdentifier,
            containerIdentifier: snapshotContainerIdentifier
        )
        guard replaceSnapshot || oldSnapshot != nil else {
            throw KDriveListingValidationError.missingSnapshotForContinuation(cursor ?? "<nil>")
        }
        let saveCondition = saveCondition(replacing: oldSnapshot)
        let response = try await runtime.remote.listAdvancedDirectory(
            driveID: runtime.configuration.driveID,
            folderID: folderID,
            cursor: cursor,
            limit: 200
        )
        try KDriveListingValidator.validateAdvancedActions(response.actions, actionItems: response.actionItems)
        let nextCursor = try KDriveListingValidator.validatedNextCursor(
            currentCursor: cursor,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore
        )
        let mergedItems = mergeListingItems(
            existingItems: replaceSnapshot ? [] : oldSnapshot?.items ?? [],
            pageItems: response.items
        )
        let storedCursor = response.actions.isEmpty ? nextCursor : cursor
        let snapshot = KDriveSnapshot(
            anchor: storedCursor ?? UUID().uuidString,
            serverCursor: storedCursor,
            isFullyEnumerated: response.hasMore == false,
            usesAdvancedListing: true,
            items: mergedItems
        )
        try await runtime.snapshotStore.save(
            snapshot,
            domainIdentifier: runtime.configuration.domainIdentifier,
            containerIdentifier: snapshotContainerIdentifier,
            condition: saveCondition
        )

        return KDriveItemPage(
            items: response.items,
            nextCursor: response.hasMore ? nextCursor : nil,
            hasMore: response.hasMore
        )
    }

    private func listAllItems(runtime: FileProviderRuntime) async throws -> [KDriveRemoteItem] {
        var items: [KDriveRemoteItem] = []
        var page = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        var seenCursors = Set<String>()
        var pageCount = 0

        while true {
            let currentCursor = FileProviderPageCodec.cursor(from: page)
            let itemPage = try await listLegacyItems(runtime: runtime, startingAt: page)
            pageCount += 1
            items.append(contentsOf: itemPage.items)

            let nextCursor = try KDriveListingValidator.validatedNextCursor(
                currentCursor: currentCursor,
                nextCursor: itemPage.nextCursor,
                hasMore: itemPage.hasMore,
                seenCursors: &seenCursors
            )

            guard itemPage.hasMore, let nextPage = FileProviderPageCodec.page(from: nextCursor) else {
                FileProviderLog.enumeration.debug("listAllItems complete container(\(self.containerItemIdentifier.rawValue, privacy: .public)) pages(\(pageCount, privacy: .public)) total(\(items.count, privacy: .public))")
                return items
            }

            page = nextPage
        }
    }

    private func enumerateAdvancedChanges(
        for observer: NSFileProviderChangeObserver,
        runtime: FileProviderRuntime,
        requestedCursor: String?
    ) async throws {
        guard let requestedCursor else {
            throw NSFileProviderError(.syncAnchorExpired)
        }

        let folderID = try advancedFolderID(rootFileID: runtime.configuration.rootFileID)
        guard let oldSnapshot = try await runtime.snapshotStore.snapshot(
            domainIdentifier: runtime.configuration.domainIdentifier,
            containerIdentifier: snapshotContainerIdentifier
        ),
              oldSnapshot.usesAdvancedListing,
              oldSnapshot.isFullyEnumerated,
              oldSnapshot.serverCursor == requestedCursor else {
            throw NSFileProviderError(.syncAnchorExpired)
        }

        do {
            let response = try await runtime.remote.listAdvancedDirectory(
                driveID: runtime.configuration.driveID,
                folderID: folderID,
                cursor: requestedCursor,
                limit: 200
            )
            let nextCursor = try KDriveListingValidator.validatedNextCursor(
                currentCursor: requestedCursor,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore
            )
            let newCursor = nextCursor ?? requestedCursor
            let result = try KDriveAdvancedActionReducer.applying(
                actions: response.actions,
                actionItems: response.actionItems,
                to: oldSnapshot,
                anchor: newCursor,
                serverCursor: newCursor
            )
            try await runtime.snapshotStore.save(
                result.snapshot,
                domainIdentifier: runtime.configuration.domainIdentifier,
                containerIdentifier: snapshotContainerIdentifier,
                condition: .matching(anchor: oldSnapshot.anchor, serverCursor: oldSnapshot.serverCursor)
            )
            await ThumbnailCacheInvalidation.removeCachedThumbnails(
                for: result.changes,
                previousSnapshot: oldSnapshot,
                runtime: runtime
            )
            emit(result.changes, to: observer, rootFileID: runtime.configuration.rootFileID)
            FileProviderLog.enumeration.info("enumerateAdvancedChanges success container(\(self.containerItemIdentifier.rawValue, privacy: .public)) updated(\(result.changes.updatedItems.count, privacy: .public)) deleted(\(result.changes.deletedItemIDs.count, privacy: .public))")
            await ProviderEventRecorder.recordActivity(
                kind: .changeSync,
                runtime: runtime,
                itemIdentifier: self.containerItemIdentifier.rawValue,
                itemName: nil,
                itemPath: nil,
                summary: "Synced \(result.changes.updatedItems.count) update(s) and \(result.changes.deletedItemIDs.count) delete(s)."
            )
            observer.finishEnumeratingChanges(upTo: FileProviderPageCodec.anchor(from: newCursor), moreComing: response.hasMore)
        } catch let error as KDriveListingValidationError {
            FileProviderLog.enumeration.error("enumerateAdvancedChanges invalid listing payload container(\(self.containerItemIdentifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            throw NSFileProviderError(.syncAnchorExpired)
        } catch let error where KDriveRemoteErrorClassifier.isInvalidCursor(error) {
            FileProviderLog.enumeration.error("enumerateAdvancedChanges invalid cursor; rebuilding container(\(self.containerItemIdentifier.rawValue, privacy: .public))")
            let rebuiltSnapshot: KDriveSnapshot
            do {
                rebuiltSnapshot = try await rebuildAdvancedSnapshot(runtime: runtime, folderID: folderID)
            } catch let error as KDriveListingValidationError {
                FileProviderLog.enumeration.error("rebuildAdvancedSnapshot invalid listing payload container(\(self.containerItemIdentifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                throw NSFileProviderError(.syncAnchorExpired)
            }
            let changes = KDriveSnapshotDiffer.changes(from: oldSnapshot, to: rebuiltSnapshot)
            try await runtime.snapshotStore.save(
                rebuiltSnapshot,
                domainIdentifier: runtime.configuration.domainIdentifier,
                containerIdentifier: snapshotContainerIdentifier,
                condition: .matching(anchor: oldSnapshot.anchor, serverCursor: oldSnapshot.serverCursor)
            )
            await ThumbnailCacheInvalidation.removeCachedThumbnails(
                for: changes,
                previousSnapshot: oldSnapshot,
                runtime: runtime
            )
            emit(changes, to: observer, rootFileID: runtime.configuration.rootFileID)
            await ProviderEventRecorder.recordActivity(
                kind: .changeSync,
                runtime: runtime,
                itemIdentifier: self.containerItemIdentifier.rawValue,
                itemName: nil,
                itemPath: nil,
                summary: "Rebuilt sync state with \(changes.updatedItems.count) update(s) and \(changes.deletedItemIDs.count) delete(s)."
            )
            observer.finishEnumeratingChanges(upTo: FileProviderPageCodec.anchor(from: rebuiltSnapshot.anchor), moreComing: false)
        }
    }

    private func rebuildAdvancedSnapshot(runtime: FileProviderRuntime, folderID: Int) async throws -> KDriveSnapshot {
        var items: [KDriveRemoteItem] = []
        var cursor: String?
        var storedCursor: String?
        var seenCursors = Set<String>()

        while true {
            let response = try await runtime.remote.listAdvancedDirectory(
                driveID: runtime.configuration.driveID,
                folderID: folderID,
                cursor: cursor,
                limit: 200
            )
            try KDriveListingValidator.validateAdvancedActions(response.actions, actionItems: response.actionItems)
            items = mergeListingItems(existingItems: items, pageItems: response.items)
            let nextCursor = try KDriveListingValidator.validatedNextCursor(
                currentCursor: cursor,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore,
                seenCursors: &seenCursors
            )
            storedCursor = response.actions.isEmpty ? nextCursor : cursor

            guard response.hasMore, let nextCursor else {
                return KDriveSnapshot(
                    anchor: storedCursor ?? UUID().uuidString,
                    serverCursor: storedCursor,
                    isFullyEnumerated: true,
                    usesAdvancedListing: true,
                    items: items
                )
            }

            cursor = nextCursor
        }
    }

    private func advancedFolderID(rootFileID: Int) throws -> Int {
        let identifier = try KDriveItemIdentifier(rawValue: containerItemIdentifier.rawValue)
        guard case .item(let folderID) = identifier,
              folderID != rootFileID else {
            throw NSFileProviderError(.noSuchItem)
        }
        return folderID
    }

    private func mergeListingItems(existingItems: [KDriveRemoteItem], pageItems: [KDriveRemoteItem]) -> [KDriveRemoteItem] {
        var items = existingItems
        var indexesByID = Dictionary(uniqueKeysWithValues: existingItems.enumerated().map { ($0.element.id, $0.offset) })

        for item in pageItems {
            if let index = indexesByID[item.id] {
                items[index] = item
            } else {
                indexesByID[item.id] = items.count
                items.append(item)
            }
        }

        return items
    }

    private func emit(_ changes: KDriveSnapshotChangeSet, to observer: NSFileProviderChangeObserver, rootFileID: Int) {
        if changes.updatedItems.isEmpty == false {
            observer.didUpdate(changes.updatedItems.map { FileProviderItem(remoteItem: $0, rootFileID: rootFileID) })
        }

        if changes.deletedItemIDs.isEmpty == false {
            observer.didDeleteItems(withIdentifiers: changes.deletedItemIDs.map { NSFileProviderItemIdentifier(String($0)) })
        }
    }

    private func saveCondition(replacing snapshot: KDriveSnapshot?) -> KDriveSnapshotSaveCondition {
        guard let snapshot else { return .missing }
        return .matching(anchor: snapshot.anchor, serverCursor: snapshot.serverCursor)
    }
}
