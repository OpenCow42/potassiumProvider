import FileProvider
import PotassiumProviderCore
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ProviderActivityTimelineRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: KDriveProviderTimelineEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.snappy) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                summary
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(statusText)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses activity details" : "Shows activity details")

            if isExpanded {
                Divider()
                details
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        }
        .accessibilityIdentifier("activity.entry.\(entry.id)")
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(statusText)
                    if let itemName {
                        Text("•")
                        Text(itemName)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 1)
            }

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var details: some View {
        switch entry {
        case .conflict(let event):
            ConflictActivityDetails(event: event)
        case .activity(let event):
            ProviderActivityDetails(event: event)
        }
    }

    private var title: String {
        switch entry {
        case .conflict(let event):
            return event.conflictItemName
                ?? event.originalItemName
                ?? event.originalItemIdentifier
                ?? "Unknown item"
        case .activity(let event):
            return event.outcome == .success
                ? event.kind.displayName
                : "Failed \(event.kind.displayName.lowercased())"
        }
    }

    private var statusText: String {
        switch entry {
        case .conflict(let event):
            return event.resolutionState.displayName
        case .activity(let event):
            return event.kind.displayName
        }
    }

    private var itemName: String? {
        switch entry {
        case .conflict(let event):
            return event.conflictItemName ?? event.originalItemName
        case .activity(let event):
            return event.itemName
        }
    }

    private var summaryText: String {
        switch entry {
        case .conflict(let event):
            return event.resolutionSummary
        case .activity(let event):
            return event.summary
        }
    }

    private var systemImage: String {
        switch entry {
        case .conflict(let event):
            return event.resolutionState.systemImage
        case .activity(let event):
            return event.outcome.systemImage(for: event.kind)
        }
    }

    private var iconColor: Color {
        switch entry {
        case .conflict(let event):
            return event.resolutionState == .automaticallyResolved ? .green : .orange
        case .activity(let event):
            return event.outcome == .failure ? .orange : .accentColor
        }
    }
}

private struct ConflictActivityDetails: View {
    let event: KDriveConflictEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityMetadataFlow {
                Label(event.operation.displayName, systemImage: event.operation.systemImage)
                Label(event.resolutionState.displayName, systemImage: event.resolutionState.systemImage)
                if event.automaticallyResolved {
                    Label("Automatic", systemImage: "bolt.fill")
                }
            }

            Text(event.resolutionSummary)
                .font(.subheadline)

            if let resolvedAt = event.resolvedAt {
                LabeledContent("Resolved", value: resolvedAt.providerActivityCopyFormatted)
            }
            LabeledContent("Detected", value: event.detectedAt.providerActivityCopyFormatted)

            if let stagedUploadRelativePath = event.stagedUploadRelativePath {
                LabeledContent("Staged upload", value: stagedUploadRelativePath)
            }

            ProviderItemAction(
                domainIdentifier: event.domainIdentifier,
                itemIdentifier: event.conflictItemIdentifier ?? event.originalItemIdentifier,
                title: event.conflictItemName ?? event.originalItemName ?? "Open item",
                fallbackDetail: event.conflictItemPath ?? event.originalItemPath
            )

            CopyActivityDetailsButton(text: copyText)
        }
        .font(.caption)
    }

    private var copyText: String {
        var lines = [
            "Conflict: \(event.conflictItemName ?? event.originalItemName ?? event.originalItemIdentifier ?? "Unknown item")",
            "Detected: \(event.detectedAt.providerActivityCopyFormatted)",
            "Operation: \(event.operation.displayName)",
            "State: \(event.resolutionState.displayName)",
            "Summary: \(event.resolutionSummary)",
        ]
        if let resolvedAt = event.resolvedAt {
            lines.insert("Resolved: \(resolvedAt.providerActivityCopyFormatted)", at: 2)
        }
        if event.automaticallyResolved {
            lines.append("Automatic: Yes")
        }
        if let path = event.stagedUploadRelativePath, path.isEmpty == false {
            lines.append("Staged upload: \(path)")
        }
        if let path = event.conflictItemPath ?? event.originalItemPath, path.isEmpty == false {
            lines.append("Item path: \(path)")
        }
        if let identifier = event.conflictItemIdentifier ?? event.originalItemIdentifier,
           identifier.isEmpty == false {
            lines.append("Item identifier: \(identifier)")
        }
        return lines.joined(separator: "\n")
    }
}

private struct ProviderActivityDetails: View {
    let event: KDriveProviderActivityEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityMetadataFlow {
                Label(event.kind.displayName, systemImage: event.kind.systemImage)
                if let errorCategory = event.errorCategory {
                    Label(errorCategory.displayName, systemImage: "tag")
                }
                if let diagnosticCode {
                    Label(diagnosticCode, systemImage: "number")
                }
            }

            Text(event.summary)
                .font(.subheadline)

            if let recoverySuggestion = event.recoverySuggestion, recoverySuggestion.isEmpty == false {
                Label(recoverySuggestion, systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
            }
            if let diagnosticSummary = event.diagnosticSummary, diagnosticSummary.isEmpty == false {
                Text(diagnosticSummary)
                    .foregroundStyle(.secondary)
            }
            if let durationMilliseconds = event.durationMilliseconds {
                LabeledContent("Duration", value: "\(durationMilliseconds) ms")
            }
            if let httpStatusCode = event.httpStatusCode {
                LabeledContent("HTTP status", value: "\(httpStatusCode)")
            }

            if event.scope == .domain {
                ProviderItemAction(
                    domainIdentifier: event.domainIdentifier,
                    itemIdentifier: event.itemIdentifier,
                    title: event.itemName ?? event.itemIdentifier ?? "Open item",
                    fallbackDetail: event.itemPath
                )
            } else {
                Label("App activity", systemImage: "app")
                    .foregroundStyle(.secondary)
            }

            CopyActivityDetailsButton(text: copyText)
        }
        .font(.caption)
    }

    private var diagnosticCode: String? {
        if let providerErrorCode = event.providerErrorCode {
            return "Provider \(providerErrorCode)"
        }
        if let domain = event.underlyingErrorDomain, let code = event.underlyingErrorCode {
            return "\(domain) \(code)"
        }
        return nil
    }

    private var copyText: String {
        var lines = [
            "Activity: \(event.outcome == .success ? event.kind.displayName : "Failed \(event.kind.displayName.lowercased())")",
            "Occurred: \(event.occurredAt.providerActivityCopyFormatted)",
            "Outcome: \(event.outcome.copyDisplayName)",
            "Outcome key: \(event.outcome.rawValue)",
            "Kind: \(event.kind.displayName)",
            "Kind key: \(event.kind.rawValue)",
            "Summary: \(event.summary)",
        ]

        if let correlationID = event.correlationID, correlationID.isEmpty == false {
            lines.append("Correlation ID: \(correlationID)")
        }
        if let durationMilliseconds = event.durationMilliseconds {
            lines.append("Duration: \(durationMilliseconds) ms")
        }
        if let networkOperation = event.networkOperation, networkOperation.isEmpty == false {
            lines.append("Network operation: \(networkOperation)")
        }
        if let httpStatusCode = event.httpStatusCode {
            lines.append("HTTP status: \(httpStatusCode)")
        }
        if event.outcome == .failure {
            lines.append("Severity: \(event.severity.copyDisplayName)")
            lines.append("Severity key: \(event.severity.rawValue)")
            if let errorCategory = event.errorCategory {
                lines.append("Error category: \(errorCategory.displayName)")
                lines.append("Error category key: \(errorCategory.rawValue)")
            }
            if let providerErrorCode = event.providerErrorCode {
                lines.append("Provider error code: \(providerErrorCode)")
            }
            if let domain = event.underlyingErrorDomain, domain.isEmpty == false {
                lines.append("Underlying error domain: \(domain)")
            }
            if let code = event.underlyingErrorCode {
                lines.append("Underlying error code: \(code)")
            }
            if let suggestion = event.recoverySuggestion, suggestion.isEmpty == false {
                lines.append("Recovery suggestion: \(suggestion)")
            }
            if let summary = event.diagnosticSummary, summary.isEmpty == false {
                lines.append("Diagnostic summary: \(summary)")
            }
            if let relatedConflictID = event.relatedConflictID {
                lines.append("Related conflict ID: \(relatedConflictID.uuidString)")
            }
            lines.append("Event ID: \(event.id.uuidString)")
            lines.append("Domain identifier: \(event.domainIdentifier)")
            lines.append("Drive ID: \(event.driveID)")
        }
        if event.scope == .domain {
            lines.append("Scope: Domain")
            if let itemName = event.itemName, itemName.isEmpty == false {
                lines.append("Item: \(itemName)")
            }
            if let itemPath = event.itemPath, itemPath.isEmpty == false {
                lines.append("Item path: \(itemPath)")
            }
            if let itemIdentifier = event.itemIdentifier, itemIdentifier.isEmpty == false {
                lines.append("Item identifier: \(itemIdentifier)")
            }
        } else {
            lines.append("Scope: App")
        }
        return lines.joined(separator: "\n")
    }
}

private struct ProviderItemAction: View {
    @Environment(\.openURL) private var openURL
    let domainIdentifier: String
    let itemIdentifier: String?
    let title: String
    let fallbackDetail: String?
    @State private var isResolving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let itemIdentifier {
                Button {
                    Task { await resolveAndOpen(itemIdentifier: itemIdentifier) }
                } label: {
                    if isResolving {
                        Label("Opening in Files…", systemImage: "arrow.up.forward.app")
                    } else {
                        Label("Open in Files", systemImage: "arrow.up.forward.app")
                    }
                }
                .disabled(isResolving)
                .accessibilityLabel("Open \(title) in Files")
                .accessibilityIdentifier("activity.openInFiles")

                if let fallbackDetail, fallbackDetail.isEmpty == false {
                    Text(fallbackDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func resolveAndOpen(itemIdentifier: String) async {
        guard isResolving == false else { return }
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }

        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domainIdentifier),
            displayName: domainIdentifier
        )
        guard let manager = NSFileProviderManager(for: domain) else {
            errorMessage = "This File Provider domain is unavailable."
            return
        }

        let resolvedURL: URL? = await withCheckedContinuation { continuation in
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(itemIdentifier)) { url, _ in
                continuation.resume(returning: url)
            }
        }
        guard let resolvedURL else {
            errorMessage = "This item is not currently available in Files."
            return
        }
        openURL(resolvedURL)
    }
}

private struct CopyActivityDetailsButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            ProviderActivityClipboard.copy(text)
            didCopy = true
        } label: {
            Label(didCopy ? "Copied" : "Copy Details", systemImage: didCopy ? "checkmark" : "doc.on.doc")
        }
        .accessibilityIdentifier("activity.copyDetails")
    }
}

private struct ActivityMetadataFlow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                content
            }
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
        .foregroundStyle(.secondary)
    }
}

private enum ProviderActivityClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

extension Date {
    var providerActivityCopyFormatted: String {
        formatted(.dateTime.year().month().day().hour().minute().second())
    }
}

extension KDriveProviderActivityKind {
    var displayName: String {
        switch self {
        case .enumeration: "Enumeration"
        case .changeSync: "Change Sync"
        case .syncAnchor: "Sync Anchor"
        case .fetchContents: "Fetch"
        case .metadataLookup: "Metadata Lookup"
        case .create: "Create"
        case .modify: "Modify"
        case .trash: "Trash"
        case .delete: "Delete"
        case .conflict: "Conflict"
        case .thumbnail: "Thumbnail"
        case .runtimeLoading: "Runtime Loading"
        case .authentication: "Authentication"
        case .driveDiscovery: "Drive Discovery"
        case .domainManagement: "Domain Management"
        case .favorite: "Favorite"
        case .duplicate: "Duplicate"
        case .restore: "Restore"
        case .shareLink: "Share Link"
        case .versionRestore: "Version Restore"
        }
    }

    var systemImage: String {
        switch self {
        case .enumeration: "list.bullet.rectangle"
        case .changeSync: "arrow.triangle.2.circlepath"
        case .syncAnchor: "link"
        case .fetchContents: "arrow.down.doc"
        case .metadataLookup: "doc.text.magnifyingglass"
        case .create: "plus"
        case .modify: "pencil"
        case .trash: "trash"
        case .delete: "xmark.bin"
        case .conflict: "exclamationmark.triangle"
        case .thumbnail: "photo"
        case .runtimeLoading: "gearshape"
        case .authentication: "person.crop.circle.badge.exclamationmark"
        case .driveDiscovery: "externaldrive.badge.questionmark"
        case .domainManagement: "folder.badge.gearshape"
        case .favorite: "star"
        case .duplicate: "plus.square.on.square"
        case .restore: "arrow.uturn.backward"
        case .shareLink: "link"
        case .versionRestore: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }
}

extension KDriveProviderActivityOutcome {
    func systemImage(for kind: KDriveProviderActivityKind) -> String {
        self == .success ? kind.systemImage : "exclamationmark.triangle"
    }

    var copyDisplayName: String {
        self == .success ? "Success" : "Failure"
    }
}

extension KDriveProviderActivitySeverity {
    var copyDisplayName: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

extension KDriveProviderActivityErrorCategory {
    var displayName: String {
        switch self {
        case .authentication: "Authentication"
        case .network: "Network"
        case .api: "API"
        case .fileProvider: "File Provider"
        case .listing: "Listing"
        case .snapshot: "Snapshot"
        case .storage: "Storage"
        case .validation: "Validation"
        case .mutationConflict: "Conflict"
        case .unknown: "Unknown"
        }
    }
}

extension KDriveConflictResolutionState {
    var displayName: String {
        switch self {
        case .unresolved: "Unresolved"
        case .automaticallyResolved: "Resolved"
        case .blockedRetryable: "Blocked"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .unresolved: "questionmark.circle"
        case .automaticallyResolved: "checkmark.circle"
        case .blockedRetryable: "pause.circle"
        case .failed: "xmark.circle"
        }
    }
}
