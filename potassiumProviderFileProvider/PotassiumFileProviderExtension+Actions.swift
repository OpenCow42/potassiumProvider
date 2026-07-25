import FileProvider
import Foundation
import PotassiumProviderCore

extension PotassiumFileProviderExtension: NSFileProviderCustomAction {
    public func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let lifecycle = FileProviderOperationLifecycle(progress: progress) {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        lifecycle.start { lifecycle in
            var runtime: FileProviderRuntime?
            let activityKind = Self.activityKind(for: actionIdentifier)
            let selectedIdentifier = itemIdentifiers.first

            do {
                guard itemIdentifiers.count == 1, let selectedIdentifier else {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                let loadedRuntime = try await FileProviderRuntime.load(domain: self.domain)
                runtime = loadedRuntime
                let parsedIdentifier = try KDriveItemIdentifier(rawValue: selectedIdentifier.rawValue)
                guard let fileID = parsedIdentifier.fileID(
                    rootFileID: loadedRuntime.configuration.rootFileID
                ) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                guard let action = ProviderDirectContextAction(rawValue: actionIdentifier.rawValue) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let execution = try await KDriveContextActionCoordinator(
                    driveID: loadedRuntime.configuration.driveID,
                    rootFileID: loadedRuntime.configuration.rootFileID,
                    remote: loadedRuntime.remote,
                    actions: loadedRuntime.actions
                ).perform(action, fileID: fileID)

                let recordedIdentifier = action == .duplicate
                    ? ProviderEventRecorder.itemIdentifier(for: execution.activityItem)
                    : selectedIdentifier.rawValue
                await ProviderEventRecorder.recordActivity(
                    kind: Self.activityKind(for: action),
                    runtime: loadedRuntime,
                    itemIdentifier: recordedIdentifier,
                    itemName: execution.activityItem.name,
                    itemPath: action == .restoreFromTrash ? nil : execution.activityItem.path,
                    summary: execution.summary
                )

                var containers = self.containerIdentifiers(
                    forFileIDs: execution.affectedParentIDs.map(Optional.some),
                    rootFileID: loadedRuntime.configuration.rootFileID
                )
                if execution.invalidatesTrash {
                    containers.append(.trashContainer)
                }
                await self.invalidateCachedSnapshotsAndSignal(
                    runtime: loadedRuntime,
                    containerIdentifiers: containers
                )
                await lifecycle.finish(markProgressComplete: true) {
                    completionHandler(nil)
                }
            } catch is CancellationError {
                await lifecycle.cancel()
            } catch {
                let mappedError = await self.recordProviderFailure(
                    error,
                    runtime: runtime,
                    fallbackKind: activityKind,
                    itemIdentifier: selectedIdentifier?.rawValue,
                    itemName: nil,
                    itemPath: nil,
                    summary: "perform contextual action."
                )
                await lifecycle.finish(markProgressComplete: false) {
                    completionHandler(mappedError)
                }
            }
        }
        return progress
    }

    private static func activityKind(
        for actionIdentifier: NSFileProviderExtensionActionIdentifier
    ) -> KDriveProviderActivityKind {
        guard let action = ProviderDirectContextAction(rawValue: actionIdentifier.rawValue) else {
            return .modify
        }
        return activityKind(for: action)
    }

    private static func activityKind(
        for action: ProviderDirectContextAction
    ) -> KDriveProviderActivityKind {
        switch action {
        case .addFavorite, .removeFavorite:
            return .favorite
        case .duplicate:
            return .duplicate
        case .restoreFromTrash:
            return .restore
        }
    }
}
