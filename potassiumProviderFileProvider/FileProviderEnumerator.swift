import FileProvider
import Foundation
import PotassiumProviderCore

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let runtime: FileProviderRuntime

    init(containerItemIdentifier: NSFileProviderItemIdentifier, runtime: FileProviderRuntime) {
        self.containerItemIdentifier = containerItemIdentifier
        self.runtime = runtime
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let itemPage = try await listItems(startingAt: page)
                observer.didEnumerate(itemPage.items.map(FileProviderItem.init(remoteItem:)))
                observer.finishEnumerating(upTo: FileProviderPageCodec.page(from: itemPage.nextCursor))
            } catch {
                observer.finishEnumeratingWithError(providerError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(FileProviderPageCodec.anchor())
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                let itemPage = try await listItems(startingAt: NSFileProviderPage.initialPageSortedByName as NSFileProviderPage)
                observer.didUpdate(itemPage.items.map(FileProviderItem.init(remoteItem:)))
                observer.finishEnumeratingChanges(upTo: FileProviderPageCodec.anchor(), moreComing: itemPage.hasMore)
            } catch {
                observer.finishEnumeratingWithError(providerError(error))
            }
        }
    }

    private func listItems(startingAt page: NSFileProviderPage) async throws -> KDriveItemPage {
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
            guard let folderID = identifier.fileID else {
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
}
