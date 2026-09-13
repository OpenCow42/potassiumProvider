#if os(macOS) && STABILITY
import FileProvider
import Foundation
import PotassiumProviderCore

extension FinderLiveRunSession {
    func executeConflict(_ conflict: StabilityLiveConflictCase) async throws {
        let parent = try require(root)
        let baseBytes = Data("conflict base\n".utf8)
        let localBytes = Data("conflict local\n".utf8)
        let remoteBytes = Data("conflict remote\n".utf8)
        let original = try await upload(name: "conflict.txt", parent: parent, data: baseBytes)
        try await signal(NSFileProviderItemIdentifier(String(parent.id)))
        let url = try await visible(original)
        // Materialize the base through Finder before arming an upload gate.
        try await ui.edit(url, contents: nil)
        let base = try await context.remote.item(driveID: context.domain.driveID, fileID: original.id)
        guard let etag = base.etag else { throw FinderLiveError.assertionFailed }
        let localDestination = try require(nested), remoteDestination = try require(sibling)
        let destinationURL = conflict == .moveMove ? try await visible(localDestination) : nil
        try await bind(url, item: original)
        let ticket = try StabilityConflictBarrier.arm(run: run, itemIdentifier: String(original.id),
            correlationID: correlationID, caseID: conflict)
        defer { try? StabilityConflictBarrier.release(ticket, run: run) }
        var localFailure: Error?
        let localTask = Task { @MainActor in
            do {
                switch conflict {
                case .renameRename: try await self.ui.rename(url, to: "Local.txt")
                case .moveMove: try await self.ui.move(url, to: self.require(destinationURL))
                default: try await self.ui.edit(url, contents: String(decoding: localBytes, as: UTF8.self))
                }
            } catch { localFailure = error; throw error }
        }
        defer { localTask.cancel() }
        do {
            try await poll {
                if let localFailure { throw localFailure }
                return StabilityConflictBarrier.reached(ticket, run: self.run)
            }
            conflictReached = true
            try await verifyOwned(original)
            let competing: KDriveRemoteItem
            switch conflict {
            case .contentBeforePreflight, .contentAfterPreflight:
                _ = try await context.remote.replaceFile(driveID: context.domain.driveID, fileID: original.id,
                    expectedETag: etag, clientToken: KDriveMutationIdentity.clientToken([run.runID.uuidString, "competitor"]),
                    contentHash: KDriveMutationIdentity.contentHash(remoteBytes), contents: remoteBytes, lastModifiedAt: Date())
                competing = try await waitMetadata(original) { $0.id == original.id && $0.parentID == parent.id &&
                    $0.name == original.name && $0.contentVersion != base.contentVersion }
                try await waitBytes(competing, expected: remoteBytes)
            case .renameRename, .editRename:
                try await context.remote.renameItem(driveID: context.domain.driveID, fileID: original.id, name: "Remote.txt")
                competing = try await waitMetadata(original) { $0.id == original.id && $0.parentID == parent.id && $0.name == "Remote.txt" }
                try await waitBytes(competing, expected: baseBytes)
            case .moveMove, .editMove:
                try await verifyOwned(remoteDestination)
                try await context.remote.moveItem(driveID: context.domain.driveID, fileID: original.id,
                    destinationParentID: remoteDestination.id, name: nil)
                competing = try await waitMetadata(original) { $0.id == original.id &&
                    $0.parentID == remoteDestination.id && $0.name == original.name }
                try await waitBytes(competing, expected: baseBytes)
            }
            try StabilityConflictBarrier.recordVerifiedCompetingMutation(ticket, run: run,
                itemIdentifier: String(competing.id), metadataAlias: StabilityDiagnosticIdentity.metadataAlias(for: competing, runID: run.runID))
            print("finder conflict: competing server state verified before gate release")
            try StabilityConflictBarrier.release(ticket, run: run)
            try await localTask.value
            if conflict == .contentBeforePreflight || conflict == .contentAfterPreflight {
                var localItem: KDriveRemoteItem?
                try await poll {
                    for candidate in try await self.list(parent) where !candidate.isDirectory && candidate.id != original.id {
                        if try await self.context.remote.downloadFile(driveID: self.context.domain.driveID, fileID: candidate.id) == localBytes {
                            localItem = candidate
                        }
                    }
                    return localItem != nil
                }
                let copy = try require(localItem)
                let remote = try await context.remote.item(driveID: context.domain.driveID, fileID: original.id)
                guard remote.parentID == parent.id, remote.name == original.name, copy.parentID == parent.id,
                      copy.id != remote.id, copy.contentVersion != base.contentVersion,
                      remote.contentVersion != base.contentVersion else { throw FinderLiveError.assertionFailed }
                try await waitBytes(remote, expected: remoteBytes)
                try await showAndReopen(copy, expected: localBytes, capture: 301)
                try await showAndReopen(remote, expected: remoteBytes, capture: 302)
            } else {
                let expectedParent = conflict == .moveMove ? localDestination.id : conflict == .editMove ? remoteDestination.id : parent.id
                let expectedName = conflict == .renameRename ? "Local.txt" : conflict == .editRename ? "Remote.txt" : original.name
                var current = try await waitMetadata(original) { $0.id == original.id && $0.parentID == expectedParent && $0.name == expectedName }
                let expectedBytes = conflict == .renameRename || conflict == .moveMove ? baseBytes : localBytes
                try await waitBytes(current, expected: expectedBytes)
                // TextEdit save can return before upload completion. Refresh the
                // metadata after byte verification so its size/version is current.
                current = try await waitMetadata(original) { $0.id == original.id && $0.parentID == expectedParent &&
                    $0.name == expectedName && $0.size == expectedBytes.count }
                let subject = StabilityDiagnosticIdentity.alias(for: String(original.id), runID: run.runID)
                let returned = try diagnostics().last { $0.operation == .modifyItem && $0.phase == .completed &&
                    $0.subjectAlias == subject && $0.correlationID == correlationID && $0.itemMetadataAlias != nil }
                if let returned {
                    let matches = returned.itemMetadataAlias == StabilityDiagnosticIdentity.metadataAlias(for: current, runID: run.runID)
                    print("finder conflict: callback metadata matches verified remote result=\(matches)")
                }
                try await showAndReopen(current, expected: expectedBytes, capture: 303)
            }
        } catch {
            localTask.cancel()
            try? StabilityConflictBarrier.release(ticket, run: run)
            _ = try? await localTask.value
            throw error
        }
    }

    private func showAndReopen(_ item: KDriveRemoteItem, expected: Data, capture: Int) async throws {
        remember(item)
        let url = try await waitVisibleDestination(item)
        try await bind(url, item: item)
        try await ui.select(url)
        try await ui.capture(in: run.directoryURL.appendingPathComponent("visual-evidence"), sequence: capture)
        try await ui.edit(url, contents: nil)
        let bytes = try Data(contentsOf: url)
        guard bytes == expected else { throw FinderLiveError.assertionFailed }
        lastVisibleURL = url
    }
}
#endif
