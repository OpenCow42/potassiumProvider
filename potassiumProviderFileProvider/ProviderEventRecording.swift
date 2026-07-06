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
        relatedConflictID: UUID? = nil,
        outcome: KDriveProviderActivityOutcome = .success,
        severity: KDriveProviderActivitySeverity = .info,
        diagnostic: KDriveProviderActivityErrorDiagnostic? = nil
    ) async {
        await recordActivity(
            kind: kind,
            eventStore: runtime.eventStore,
            domainIdentifier: runtime.configuration.domainIdentifier,
            driveID: runtime.configuration.driveID,
            scope: .domain,
            itemIdentifier: itemIdentifier,
            itemName: itemName,
            itemPath: itemPath,
            summary: summary,
            relatedConflictID: relatedConflictID,
            outcome: outcome,
            severity: severity,
            diagnostic: diagnostic
        )
    }

    static func recordFailure(
        kind: KDriveProviderActivityKind,
        runtime: FileProviderRuntime,
        itemIdentifier: String?,
        itemName: String?,
        itemPath: String?,
        summary: String,
        diagnostic: KDriveProviderActivityErrorDiagnostic
    ) async {
        await recordActivity(
            kind: kind,
            runtime: runtime,
            itemIdentifier: itemIdentifier,
            itemName: itemName,
            itemPath: itemPath,
            summary: summary,
            outcome: .failure,
            severity: .error,
            diagnostic: diagnostic
        )
    }

    static func recordFailure(
        kind: KDriveProviderActivityKind,
        eventStore: (any KDriveProviderEventStoring)?,
        domainIdentifier: String,
        driveID: Int = 0,
        itemIdentifier: String?,
        itemName: String?,
        itemPath: String?,
        summary: String,
        diagnostic: KDriveProviderActivityErrorDiagnostic
    ) async {
        await recordActivity(
            kind: kind,
            eventStore: eventStore,
            domainIdentifier: domainIdentifier,
            driveID: driveID,
            scope: .domain,
            itemIdentifier: itemIdentifier,
            itemName: itemName,
            itemPath: itemPath,
            summary: summary,
            outcome: .failure,
            severity: .error,
            diagnostic: diagnostic
        )
    }

    private static func recordActivity(
        kind: KDriveProviderActivityKind,
        eventStore: (any KDriveProviderEventStoring)?,
        domainIdentifier: String,
        driveID: Int,
        scope: KDriveProviderActivityScope,
        itemIdentifier: String?,
        itemName: String?,
        itemPath: String?,
        summary: String,
        relatedConflictID: UUID? = nil,
        outcome: KDriveProviderActivityOutcome,
        severity: KDriveProviderActivitySeverity,
        diagnostic: KDriveProviderActivityErrorDiagnostic?
    ) async {
        guard let eventStore else { return }
        do {
            try await eventStore.recordActivity(KDriveProviderActivityEvent(
                domainIdentifier: domainIdentifier,
                driveID: driveID,
                kind: kind,
                scope: scope,
                outcome: outcome,
                severity: severity,
                itemIdentifier: itemIdentifier,
                itemName: itemName,
                itemPath: itemPath,
                summary: summary,
                relatedConflictID: relatedConflictID,
                diagnostic: diagnostic
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
