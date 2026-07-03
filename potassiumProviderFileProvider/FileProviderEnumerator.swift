import FileProvider
import Foundation
import PotassiumProviderCore

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let domain: NSFileProviderDomain

    init(containerItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain) {
        self.containerItemIdentifier = containerItemIdentifier
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let runtime = try await FileProviderRuntime.load(domain: domain)
                let itemPage = try await listItems(runtime: runtime, startingAt: page)
                observer.didEnumerate(itemPage.items.map { FileProviderItem(remoteItem: $0, rootFileID: runtime.configuration.rootFileID) })
                observer.finishEnumerating(upTo: FileProviderPageCodec.page(from: itemPage.nextCursor))
            } catch {
                observer.finishEnumeratingWithError(providerError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        do {
            let configuration = try FileProviderRuntime.loadConfiguration(domain: domain)
            let snapshotStore = try FileProviderRuntime.makeSnapshotStore()
            let snapshot = try snapshotStore.snapshot(
                domainIdentifier: configuration.domainIdentifier,
                containerIdentifier: snapshotContainerIdentifier
            )
            completionHandler(snapshot.map { FileProviderPageCodec.anchor(from: $0.anchor) })
        } catch {
            completionHandler(nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                let runtime = try await FileProviderRuntime.load(domain: domain)
                let oldSnapshot = try runtime.snapshotStore.snapshot(
                    domainIdentifier: runtime.configuration.domainIdentifier,
                    containerIdentifier: snapshotContainerIdentifier
                )
                let requestedAnchor = FileProviderPageCodec.anchorString(from: anchor)
                let baselineSnapshot = oldSnapshot?.anchor == requestedAnchor ? oldSnapshot : nil
                let newSnapshot = KDriveSnapshot(items: try await listAllItems(runtime: runtime))
                let changes = KDriveSnapshotDiffer.changes(from: baselineSnapshot, to: newSnapshot)

                if changes.updatedItems.isEmpty == false {
                    observer.didUpdate(changes.updatedItems.map { FileProviderItem(remoteItem: $0, rootFileID: runtime.configuration.rootFileID) })
                }

                if changes.deletedItemIDs.isEmpty == false {
                    observer.didDeleteItems(withIdentifiers: changes.deletedItemIDs.map { NSFileProviderItemIdentifier(String($0)) })
                }

                try runtime.snapshotStore.save(
                    newSnapshot,
                    domainIdentifier: runtime.configuration.domainIdentifier,
                    containerIdentifier: snapshotContainerIdentifier
                )
                observer.finishEnumeratingChanges(upTo: FileProviderPageCodec.anchor(from: newSnapshot.anchor), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(providerError(error))
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
        switch containerItemIdentifier {
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
            let identifier = try KDriveItemIdentifier(rawValue: containerItemIdentifier.rawValue)
            guard let folderID = identifier.fileID(rootFileID: runtime.configuration.rootFileID) else {
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

        while true {
            let itemPage = try await listItems(runtime: runtime, startingAt: page)
            items.append(contentsOf: itemPage.items)

            guard let nextPage = FileProviderPageCodec.page(from: itemPage.nextCursor) else {
                return items
            }

            let cursor = FileProviderPageCodec.cursor(from: nextPage) ?? ""
            guard seenCursors.insert(cursor).inserted else {
                return items
            }
            page = nextPage
        }
    }
}
