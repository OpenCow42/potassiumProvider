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
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.domain)
                let itemPage = try await self.listItems(runtime: runtime, startingAt: page)
                observer.didEnumerate(itemPage.items.map { FileProviderItem(remoteItem: $0, rootFileID: runtime.configuration.rootFileID) })
                FileProviderLog.enumeration.info("enumerateItems success container(\(self.containerItemIdentifier.rawValue, privacy: .public)) count(\(itemPage.items.count, privacy: .public)) nextCursorPresent(\(itemPage.nextCursor != nil, privacy: .public)) driveID(\(runtime.configuration.driveID, privacy: .public))")
                observer.finishEnumerating(upTo: FileProviderPageCodec.page(from: itemPage.nextCursor))
            } catch {
                let mappedError = providerError(error)
                FileProviderLog.enumeration.error("enumerateItems failed container(\(self.containerItemIdentifier.rawValue, privacy: .public)): \(mappedError.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(mappedError)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            do {
                let configuration = try await FileProviderRuntime.loadConfiguration(domain: domain)
                let snapshotStore = try FileProviderRuntime.makeSnapshotStore()
                let snapshot = try await snapshotStore.snapshot(
                    domainIdentifier: configuration.domainIdentifier,
                    containerIdentifier: snapshotContainerIdentifier
                )
                FileProviderLog.enumeration.debug("currentSyncAnchor container(\(self.containerItemIdentifier.rawValue, privacy: .public)) snapshotPresent(\(snapshot != nil, privacy: .public))")
                completionHandler(snapshot.map { FileProviderPageCodec.anchor(from: $0.anchor) })
            } catch {
                FileProviderLog.enumeration.error("currentSyncAnchor failed container(\(self.containerItemIdentifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let requestedAnchor = FileProviderPageCodec.anchorString(from: anchor)
        FileProviderLog.enumeration.debug("enumerateChanges start container(\(self.containerItemIdentifier.rawValue, privacy: .public)) requestedAnchorPresent(\(requestedAnchor != nil, privacy: .public))")
        Task {
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.domain)
                let oldSnapshot = try await runtime.snapshotStore.snapshot(
                    domainIdentifier: runtime.configuration.domainIdentifier,
                    containerIdentifier: self.snapshotContainerIdentifier
                )
                let baselineSnapshot = oldSnapshot?.anchor == requestedAnchor ? oldSnapshot : nil
                FileProviderLog.enumeration.debug("enumerateChanges baseline container(\(self.containerItemIdentifier.rawValue, privacy: .public)) oldSnapshotPresent(\(oldSnapshot != nil, privacy: .public)) anchorMatched(\(baselineSnapshot != nil, privacy: .public))")
                let newSnapshot = KDriveSnapshot(items: try await self.listAllItems(runtime: runtime))
                let changes = KDriveSnapshotDiffer.changes(from: baselineSnapshot, to: newSnapshot)

                if changes.updatedItems.isEmpty == false {
                    observer.didUpdate(changes.updatedItems.map { FileProviderItem(remoteItem: $0, rootFileID: runtime.configuration.rootFileID) })
                }

                if changes.deletedItemIDs.isEmpty == false {
                    observer.didDeleteItems(withIdentifiers: changes.deletedItemIDs.map { NSFileProviderItemIdentifier(String($0)) })
                }

                try await runtime.snapshotStore.save(
                    newSnapshot,
                    domainIdentifier: runtime.configuration.domainIdentifier,
                    containerIdentifier: self.snapshotContainerIdentifier
                )
                FileProviderLog.enumeration.info("enumerateChanges success container(\(self.containerItemIdentifier.rawValue, privacy: .public)) updated(\(changes.updatedItems.count, privacy: .public)) deleted(\(changes.deletedItemIDs.count, privacy: .public)) total(\(newSnapshot.items.count, privacy: .public))")
                observer.finishEnumeratingChanges(upTo: FileProviderPageCodec.anchor(from: newSnapshot.anchor), moreComing: false)
            } catch {
                let mappedError = providerError(error)
                FileProviderLog.enumeration.error("enumerateChanges failed container(\(self.containerItemIdentifier.rawValue, privacy: .public)): \(mappedError.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(mappedError)
            }
        }
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

    private func listItems(runtime: FileProviderRuntime, startingAt page: NSFileProviderPage) async throws -> KDriveItemPage {
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

    private func listAllItems(runtime: FileProviderRuntime) async throws -> [KDriveRemoteItem] {
        var items: [KDriveRemoteItem] = []
        var page = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        var seenCursors = Set<String>()
        var pageCount = 0

        while true {
            let itemPage = try await listItems(runtime: runtime, startingAt: page)
            pageCount += 1
            items.append(contentsOf: itemPage.items)

            guard let nextPage = FileProviderPageCodec.page(from: itemPage.nextCursor) else {
                FileProviderLog.enumeration.debug("listAllItems complete container(\(self.containerItemIdentifier.rawValue, privacy: .public)) pages(\(pageCount, privacy: .public)) total(\(items.count, privacy: .public))")
                return items
            }

            let cursor = FileProviderPageCodec.cursor(from: nextPage) ?? ""
            guard seenCursors.insert(cursor).inserted else {
                FileProviderLog.enumeration.error("listAllItems stopping after repeated cursor container(\(self.containerItemIdentifier.rawValue, privacy: .public)) pages(\(pageCount, privacy: .public)) total(\(items.count, privacy: .public))")
                return items
            }
            page = nextPage
        }
    }
}
