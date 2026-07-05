import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

enum ProviderEventRecorder {
    static func saveConflict(_ event: KDriveConflictEvent, runtime: FileProviderRuntime) async {
        guard let eventStore = runtime.eventStore else { return }
        do {
            try await eventStore.saveConflict(event)
            try await eventStore.recordActivity(KDriveProviderActivityEvent(
                occurredAt: event.resolvedAt ?? event.detectedAt,
                domainIdentifier: event.domainIdentifier,
                driveID: event.driveID,
                kind: .conflict,
                itemIdentifier: event.conflictItemIdentifier ?? event.originalItemIdentifier,
                itemName: event.conflictItemName ?? event.originalItemName,
                itemPath: event.conflictItemPath ?? event.originalItemPath,
                summary: event.resolutionSummary,
                relatedConflictID: event.id
            ))
        } catch {
            FileProviderLog.runtime.error("failed to save provider conflict event: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func recordActivity(
        kind: KDriveProviderActivityKind,
        runtime: FileProviderRuntime,
        itemIdentifier: String?,
        itemName: String?,
        itemPath: String?,
        summary: String,
        relatedConflictID: UUID? = nil
    ) async {
        guard let eventStore = runtime.eventStore else { return }
        do {
            try await eventStore.recordActivity(KDriveProviderActivityEvent(
                domainIdentifier: runtime.configuration.domainIdentifier,
                driveID: runtime.configuration.driveID,
                kind: kind,
                itemIdentifier: itemIdentifier,
                itemName: itemName,
                itemPath: itemPath,
                summary: summary,
                relatedConflictID: relatedConflictID
            ))
        } catch {
            FileProviderLog.runtime.error("failed to save provider activity event: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func itemIdentifier(for item: KDriveRemoteItem) -> String {
        KDriveItemIdentifier.item(item.id).rawValue
    }

    static func relativeStagedPath(for stagedURL: URL) -> String {
        "ConflictStaging/\(stagedURL.lastPathComponent)"
    }
}
