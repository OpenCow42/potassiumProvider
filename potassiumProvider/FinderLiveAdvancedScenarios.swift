#if os(macOS) && STABILITY
import AppKit
import FileProvider
import PotassiumProviderCore

extension FinderLiveRunSession {
    func waitRestoredLocation(_ item: KDriveRemoteItem) async throws -> URL {
        let parent = try require(owned[item.parentID])
        let parentURL = try await visible(parent)
        var restoredURL: URL?
        try await poll {
            let candidate = try await self.visible(item)
            guard FinderRestoreObservation.matchesVisibleDestination(candidate, parent: parentURL, name: item.name) else { return false }
            restoredURL = candidate
            return true
        }
        return try require(restoredURL)
    }

    func waitRestored(_ item: KDriveRemoteItem) async throws -> KDriveRemoteItem {
        let alias = StabilityDiagnosticIdentity.alias(for: String(item.id), runID: run.runID)
        var restored: KDriveRemoteItem?
        try await poll {
            let callbacks = try self.diagnostics().filter {
                $0.source == .fileProviderExtension && $0.operation == .restoreTrashedItem &&
                    $0.parentSpanID == nil && $0.subjectAlias == alias && $0.correlationID == self.correlationID
            }
            guard callbacks.allSatisfy({ $0.processCodeHash == self.expectedExtensionCodeHash && $0.processInstanceID != nil }) else {
                throw StabilityLiveEvidenceError.wrongExtensionBuild
            }
            guard !callbacks.contains(where: { [.failed, .cancelled].contains($0.phase) }) else {
                throw StabilityLiveEvidenceError.unexpectedFailure
            }
            restored = try await FinderRestoreObservation.observe(
                callbackCompleted: callbacks.contains { $0.phase == .completed }, expected: item) {
                    try await self.context.remote.item(driveID: self.context.domain.driveID, fileID: item.id)
                }
            return restored != nil
        }
        let result = try require(restored)
        remember(result)
        return result
    }

    func waitTrashed(_ item: KDriveRemoteItem, exists: Bool) async throws {
        guard let actions = context.remote as? any KDriveContextActionProviding else { throw FinderLiveError.missingCapability }
        try await poll {
            do {
                let trashed = try await actions.trashedItem(driveID: self.context.domain.driveID, fileID: item.id)
                return exists && trashed.id == item.id
            } catch where KDriveRemoteErrorClassifier.isNotFound(error) { return !exists }
        }
    }

    func waitDeleted(_ item: KDriveRemoteItem) async throws {
        guard let actions = context.remote as? any KDriveContextActionProviding else { throw FinderLiveError.missingCapability }
        try await poll {
            // Absence from Trash alone can also mean that an item was restored.
            // Require independent absence from the active-item and existence APIs.
            guard try await actions.existingFileIDs(driveID: self.context.domain.driveID, fileIDs: [item.id]).isEmpty else { return false }
            do {
                _ = try await self.context.remote.item(driveID: self.context.domain.driveID, fileID: item.id)
                return false
            } catch where KDriveRemoteErrorClassifier.isNotFound(error) {}
            do {
                _ = try await actions.trashedItem(driveID: self.context.domain.driveID, fileID: item.id)
                return false
            } catch where KDriveRemoteErrorClassifier.isNotFound(error) { return true }
        }
    }

    func preserveBoth() async throws {
        let base = Data("conflict base\n".utf8), local = Data("conflict local\n".utf8), other = Data("conflict remote\n".utf8)
        let item = try await upload(name: "conflict.txt", parent: require(root), data: base)
        try await signal(NSFileProviderItemIdentifier(String(item.parentID)))
        let url = try await visible(item)
        try await ui.edit(url, contents: nil)
        let fresh = try await context.remote.item(driveID: context.domain.driveID, fileID: item.id)
        guard let etag = fresh.etag else { throw FinderLiveError.assertionFailed }
        try StabilityConflictBarrier.arm(run: run, itemIdentifier: String(item.id), correlationID: correlationID)
        defer { try? StabilityConflictBarrier.release(run: run) }
        try await ui.edit(url, contents: String(decoding: local, as: UTF8.self))
        try await poll { StabilityConflictBarrier.reached(run: self.run) }
        conflictReached = true
        do {
            _ = try await context.remote.replaceFile(driveID: context.domain.driveID, fileID: item.id, expectedETag: etag,
                clientToken: KDriveMutationIdentity.clientToken([run.runID.uuidString, "remote-conflict"]),
                contentHash: KDriveMutationIdentity.contentHash(other), contents: other, lastModifiedAt: Date())
        } catch {
            try? StabilityConflictBarrier.release(run: run)
            throw error
        }
        try StabilityConflictBarrier.release(run: run)
        var localItem: KDriveRemoteItem?, remoteItem: KDriveRemoteItem?
        try await poll {
            for candidate in try await self.list(self.require(self.root)) where candidate.name.contains("conflict") && !candidate.isDirectory {
                let data = try await self.context.remote.downloadFile(driveID: self.context.domain.driveID, fileID: candidate.id)
                if data == local { localItem = candidate }
                if data == other { remoteItem = candidate }
            }
            return localItem != nil && remoteItem != nil && localItem?.id != remoteItem?.id
        }
        for item in [try require(localItem), try require(remoteItem)] {
            remember(item)
            try await ui.select(visible(item))
        }
    }

    func cancelTransfer() async throws {
        for mebibytes in [64, 256] {
            let data = Data(repeating: 0x5A, count: mebibytes * 1_024 * 1_024)
            let item = try await upload(name: "transfer-\(mebibytes).bin", parent: require(root), data: data)
            transfer = item
            try await signal(NSFileProviderItemIdentifier(String(item.parentID)))
            let url = try await visible(item)
            let subject = StabilityDiagnosticIdentity.alias(for: String(item.id), runID: run.runID)
            try await ui.contextAction("Download Now", on: url)
            try await poll(seconds: 600) {
                try self.diagnostics().contains { $0.subjectAlias == subject && $0.operation == .downloadFile &&
                    ($0.phase == .completed || ($0.phase == .progress && ($0.progressPercentBucket ?? 0) > 0)) }
            }
            let alreadyCompleted = try diagnostics().contains { $0.subjectAlias == subject && $0.operation == .fetchContents && $0.phase == .completed }
            if alreadyCompleted { continue }
            try await ui.cancelDownload(url)
            try await poll {
                self.cancellationObserved = try self.diagnostics().contains { $0.subjectAlias == subject && $0.operation == .fetchContents && $0.phase == .cancelled }
                return self.cancellationObserved
            }
            try await ui.contextAction("Download Now", on: url)
            try await poll(seconds: 600) {
                try self.diagnostics().contains { $0.subjectAlias == subject && $0.operation == .fetchContents && $0.phase == .completed }
            }
            guard try Data(contentsOf: url) == data else { throw FinderLiveError.assertionFailed }
            try await waitBytes(item, expected: data)
            return
        }
        throw FinderLiveError.cancellationNotExercised
    }

    func contextActions() async throws {
        guard let actions = context.remote as? any KDriveContextActionProviding else { throw FinderLiveError.missingCapability }
        let old = Data("actions original version\n".utf8), current = Data("actions current version\n".utf8)
        let parent = try require(root)
        let item = try await upload(name: "actions.txt", parent: parent, data: old)
        try await signal(NSFileProviderItemIdentifier(String(parent.id)))
        let url = try await visible(item)
        try await ui.edit(url, contents: String(decoding: current, as: UTF8.self))
        try await waitBytes(item, expected: current)
        try await bind(url, item: item)
        try await ui.contextAction("Add to kDrive Favorites", on: url)
        _ = try await waitMetadata(item) { $0.isFavorite == true }
        try await bind(url, item: item)
        try await ui.contextAction("Remove from kDrive Favorites", on: url)
        _ = try await waitMetadata(item) { $0.isFavorite == false }
        let beforeCopy = Set(try await list(parent).map(\.id))
        try await bind(url, item: item)
        try await ui.contextAction("Duplicate on kDrive", on: url)
        var duplicate: KDriveRemoteItem?
        try await poll { duplicate = try await self.list(parent).first { !beforeCopy.contains($0.id) && !$0.isDirectory }; return duplicate != nil }
        try await waitBytes(require(duplicate), expected: current)
        remember(try require(duplicate))
        try await bind(url, item: item)
        try await ui.contextAction("Share kDrive Link…", on: url)
        try await ui.panelAction(.inheritAccess)
        try await bind(url, item: item)
        try await ui.panelAction(.createLink)
        try await poll { try await actions.shareLink(driveID: self.context.domain.driveID, fileID: item.id)?.configuration.access == .inherit }
        try await ui.panelAction(.toggleComments)
        try await bind(url, item: item)
        try await ui.panelAction(.saveLink)
        try await poll { try await actions.shareLink(driveID: self.context.domain.driveID, fileID: item.id)?.configuration.allowsComments == true }
        try await ui.panelAction(.disableLink)
        try await bind(url, item: item)
        try await ui.panelAction(.confirmDisableLink)
        try await poll { try await actions.shareLink(driveID: self.context.domain.driveID, fileID: item.id) == nil }
        try await ui.panelAction(.done)
        let versions = try await actions.fileVersions(driveID: context.domain.driveID, fileID: item.id, page: 1, pageSize: 50)
        let historical = versions.versions.filter { $0.size == old.count }
        guard !versions.hasMore, historical.count == 1, let version = historical.first else { throw FinderLiveError.missingCapability }
        let beforeRestore = Set(try await list(parent).map(\.id))
        try await bind(url, item: item)
        try await ui.contextAction("Version History…", on: url)
        try await ui.panelAction(.restoreVersion(version.id))
        try await bind(url, item: item)
        try await ui.panelAction(.confirmRestore)
        var restored: KDriveRemoteItem?
        try await poll { restored = try await self.list(parent).first { !beforeRestore.contains($0.id) && !$0.isDirectory }; return restored != nil }
        let restoredItem = try require(restored)
        try await waitBytes(restoredItem, expected: old)
        try await waitBytes(item, expected: current)
        remember(restoredItem)
        try await ui.panelAction(.done)
        try await ui.select(visible(restoredItem))
    }

    /// Allow every run-related started callback to reach a terminal before sealing.
    /// An interrupted transfer never becomes an apparently complete evidence bundle.
    func drain() async throws {
        try await poll(seconds: 600) {
            let events = try self.diagnostics().filter { $0.spanID != nil }
            return Dictionary(grouping: events, by: { $0.spanID! }).values.allSatisfy { span in
                !span.contains { $0.phase == .started } || span.contains { [.completed, .cancelled, .failed].contains($0.phase) }
            }
        }
    }
}
#endif
