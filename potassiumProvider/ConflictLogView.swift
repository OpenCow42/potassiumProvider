import Combine
import FileProvider
import PotassiumProviderCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ConflictLogView: View {
    @StateObject private var model: ConflictLogViewModel
    @State private var isClearConfirmationPresented = false
    @State private var isSupportLogExporterPresented = false
    @State private var supportLogDocument: ProviderSupportLogDocument?

    init(eventStore: (any KDriveProviderEventStoring)?) {
        _model = StateObject(wrappedValue: ConflictLogViewModel(eventStore: eventStore))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    activityFilterControl
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                if model.timelineItems.isEmpty {
                    Section {
                        Label(emptyActivityMessage, systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section(model.showsActivity ? "Full Activity" : "Errors and Conflicts") {
                        ForEach(model.timelineItems) { item in
                            switch item {
                            case .conflict(let event):
                                ConflictEventRow(event: event)
                            case .activity(let event):
                                ActivityEventRow(event: event)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activities")
            .toolbar {
                ToolbarItemGroup(placement: activityToolbarPlacement) {
                    Button(role: .destructive) {
                        isClearConfirmationPresented = true
                    } label: {
                        Label(model.isClearing ? "Clearing" : "Clear", systemImage: "trash")
                    }
                    .disabled(model.canClearActivity == false)

                    Button {
                        Task { await model.load() }
                    } label: {
                        Label(model.isLoading ? "Loading" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)

                    Button {
                        Task {
                            guard let data = await model.supportLogData() else { return }
                            supportLogDocument = ProviderSupportLogDocument(data: data)
                            isSupportLogExporterPresented = true
                        }
                    } label: {
                        Label(model.isExporting ? "Exporting" : "Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.canExportSupportLog == false)
                }
            }
            .task {
                await model.load()
            }
            .onChange(of: model.showsActivity) { _, _ in
                Task { await model.load() }
            }
            .confirmationDialog("Clear Activities?", isPresented: $isClearConfirmationPresented) {
                Button("Clear Events and Resolved Conflicts", role: .destructive) {
                    Task { await model.clearActivity() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Activity events and resolved conflict rows will be removed. Unresolved, blocked, and failed conflicts stay visible.")
            }
            .fileExporter(
                isPresented: $isSupportLogExporterPresented,
                document: supportLogDocument,
                contentType: .json,
                defaultFilename: "potassium-provider-support-log"
            ) { result in
                if case let .failure(error) = result {
                    model.recordExportFailure(error)
                }
            }
        }
    }

    private var activityFilterControl: some View {
        Picker("Activity visibility", selection: activityFilter) {
            ForEach(ActivityFilterOption.allCases) { option in
                Label(option.title, systemImage: option.systemImage)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .frame(maxWidth: 420)
        .accessibilityLabel("Activity visibility")
        .providerActivityControlGlass()
    }

    private var activityFilter: Binding<ActivityFilterOption> {
        Binding {
            model.showsActivity ? .fullActivity : .errorsOnly
        } set: { option in
            model.showsActivity = option.showsActivity
        }
    }

    private var emptyActivityMessage: String {
        model.showsActivity ? "No activities yet" : "No errors or conflicts yet"
    }

    private var activityToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }
}

private enum ActivityFilterOption: CaseIterable, Identifiable {
    case errorsOnly
    case fullActivity

    var id: Self { self }

    var title: String {
        switch self {
        case .errorsOnly:
            return "Only Errors"
        case .fullActivity:
            return "Full Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .errorsOnly:
            return "exclamationmark.triangle"
        case .fullActivity:
            return "clock.arrow.circlepath"
        }
    }

    var showsActivity: Bool {
        self == .fullActivity
    }
}

private extension View {
    @ViewBuilder
    func providerActivityControlGlass() -> some View {
        #if os(visionOS)
        self
        #else
        glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8))
        #endif
    }

    @ViewBuilder
    func providerActivityCopyableText(_ text: String) -> some View {
        #if os(macOS)
        textSelection(.enabled)
            .contextMenu {
                Button {
                    ProviderActivityClipboard.copy(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        #else
        self
        #endif
    }
}

#if os(macOS)
private enum ProviderActivityClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif

@MainActor
final class ConflictLogViewModel: ObservableObject {
    @Published private(set) var conflicts: [KDriveConflictEvent] = []
    @Published private(set) var activity: [KDriveProviderActivityEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isClearing = false
    @Published private(set) var isExporting = false
    @Published var showsActivity = false
    @Published var errorMessage: String?

    private let eventStore: (any KDriveProviderEventStoring)?
    private var eventObservationTask: Task<Void, Never>?

    init(eventStore: (any KDriveProviderEventStoring)?) {
        self.eventStore = eventStore
        if let eventStore = eventStore as? any KDriveProviderEventObserving {
            eventObservationTask = Task { [weak self] in
                let changes = await eventStore.eventChanges(pollInterval: 1)
                for await _ in changes {
                    await self?.load()
                }
            }
        }
    }

    deinit {
        eventObservationTask?.cancel()
    }

    var timelineItems: [ConflictTimelineItem] {
        let conflictItems = conflicts.map(ConflictTimelineItem.conflict)
        let activityItems = activity
            .filter { $0.relatedConflictID == nil }
            .filter { showsActivity || $0.outcome == .failure }
            .map(ConflictTimelineItem.activity)
        return (conflictItems + activityItems).sorted { $0.date > $1.date }
    }

    var canClearActivity: Bool {
        eventStore != nil && isLoading == false && isClearing == false
    }

    var canExportSupportLog: Bool {
        eventStore is any KDriveProviderEventExporting && isExporting == false
    }

    func load() async {
        guard let eventStore else {
            conflicts = []
            activity = []
            errorMessage = "Activity database is unavailable."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            conflicts = try await eventStore.recentConflicts(domainIdentifier: nil, limit: 100)
            activity = try await eventStore.recentActivity(
                domainIdentifier: nil,
                outcome: showsActivity ? nil : .failure,
                limit: 100
            )
            errorMessage = nil
        } catch {
            errorMessage = "Could not load activity events: \(error.localizedDescription)"
        }
    }

    func clearActivity() async {
        guard let eventStore else {
            conflicts = []
            activity = []
            errorMessage = "Activity database is unavailable."
            return
        }

        isClearing = true
        defer { isClearing = false }

        do {
            try await eventStore.removeActivityAndResolvedConflicts(domainIdentifier: nil)
            await load()
        } catch {
            errorMessage = "Could not clear activity events: \(error.localizedDescription)"
        }
    }

    func supportLogData() async -> Data? {
        guard let eventStore = eventStore as? any KDriveProviderEventExporting else {
            errorMessage = "Support-log export is unavailable."
            return nil
        }

        isExporting = true
        defer { isExporting = false }

        do {
            let data = try await eventStore.supportLogData(domainIdentifier: nil)
            errorMessage = nil
            return data
        } catch {
            errorMessage = "Could not create support log: \(error.localizedDescription)"
            return nil
        }
    }

    func recordExportFailure(_ error: Error) {
        errorMessage = "Could not export support log: \(error.localizedDescription)"
    }
}

private struct ProviderSupportLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ConflictTimelineItem: Identifiable {
    case conflict(KDriveConflictEvent)
    case activity(KDriveProviderActivityEvent)

    var id: String {
        switch self {
        case .conflict(let event):
            return "conflict-\(event.id.uuidString)"
        case .activity(let event):
            return "activity-\(event.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .conflict(let event):
            return event.resolvedAt ?? event.detectedAt
        case .activity(let event):
            return event.occurredAt
        }
    }
}

private struct ConflictEventRow: View {
    let event: KDriveConflictEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(eventTitle, systemImage: event.resolutionState.systemImage)
                    .font(.headline)
                Spacer()
                Text(event.detectedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(event.operation.displayName, systemImage: event.operation.systemImage)
                Label(event.resolutionState.displayName, systemImage: event.resolutionState.systemImage)
                if event.automaticallyResolved {
                    Label("Automatic", systemImage: "bolt.fill")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(event.resolutionSummary)
                .font(.subheadline)

            if let stagedUploadRelativePath = event.stagedUploadRelativePath {
                Text(stagedUploadRelativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProviderItemLink(
                domainIdentifier: event.domainIdentifier,
                itemIdentifier: event.conflictItemIdentifier ?? event.originalItemIdentifier,
                title: linkTitle,
                fallbackDetail: event.conflictItemPath ?? event.originalItemPath
            )
        }
        .padding(.vertical, 4)
        .providerActivityCopyableText(copyText)
    }

    private var eventTitle: String {
        event.conflictItemName
            ?? event.originalItemName
            ?? event.originalItemIdentifier
            ?? "Unknown item"
    }

    private var linkTitle: String {
        event.conflictItemName
            ?? event.originalItemName
            ?? "Open item"
    }

    private var copyText: String {
        var lines = [
            "Conflict: \(eventTitle)",
            "Detected: \(event.detectedAt.providerActivityCopyFormatted)",
            "Operation: \(event.operation.displayName)",
            "State: \(event.resolutionState.displayName)",
            "Summary: \(event.resolutionSummary)"
        ]

        if let resolvedAt = event.resolvedAt {
            lines.insert("Resolved: \(resolvedAt.providerActivityCopyFormatted)", at: 2)
        }
        if event.automaticallyResolved {
            lines.append("Automatic: Yes")
        }
        if let stagedUploadRelativePath = event.stagedUploadRelativePath, stagedUploadRelativePath.isEmpty == false {
            lines.append("Staged upload: \(stagedUploadRelativePath)")
        }
        if let itemPath = event.conflictItemPath ?? event.originalItemPath, itemPath.isEmpty == false {
            lines.append("Item path: \(itemPath)")
        }
        if let itemIdentifier = event.conflictItemIdentifier ?? event.originalItemIdentifier, itemIdentifier.isEmpty == false {
            lines.append("Item identifier: \(itemIdentifier)")
        }

        return lines.joined(separator: "\n")
    }
}

private struct ActivityEventRow: View {
    let event: KDriveProviderActivityEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: event.outcome.systemImage(for: event.kind))
                    .font(.headline)
                Spacer()
                Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(event.summary)
                .font(.subheadline)

            if event.outcome == .failure {
                HStack(spacing: 12) {
                    Label(event.kind.displayName, systemImage: event.kind.systemImage)
                    if let errorCategory = event.errorCategory {
                        Label(errorCategory.displayName, systemImage: "tag")
                    }
                    if let diagnosticCode {
                        Label(diagnosticCode, systemImage: "number")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let recoverySuggestion = event.recoverySuggestion, recoverySuggestion.isEmpty == false {
                    Text(recoverySuggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let diagnosticSummary = event.diagnosticSummary, diagnosticSummary.isEmpty == false {
                    Text(diagnosticSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if event.scope == .domain {
                ProviderItemLink(
                    domainIdentifier: event.domainIdentifier,
                    itemIdentifier: event.itemIdentifier,
                    title: event.itemName ?? event.itemIdentifier ?? "Open item",
                    fallbackDetail: event.itemPath
                )
            } else {
                Label("App", systemImage: "app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .providerActivityCopyableText(copyText)
    }

    private var title: String {
        switch event.outcome {
        case .success:
            return event.kind.displayName
        case .failure:
            return "Failed \(event.kind.displayName.lowercased())"
        }
    }

    private var diagnosticCode: String? {
        if let providerErrorCode = event.providerErrorCode {
            return "Provider \(providerErrorCode)"
        }
        if let underlyingErrorDomain = event.underlyingErrorDomain,
           let underlyingErrorCode = event.underlyingErrorCode {
            return "\(underlyingErrorDomain) \(underlyingErrorCode)"
        }
        return nil
    }

    private var copyText: String {
        var lines = [
            "Activity: \(title)",
            "Occurred: \(event.occurredAt.providerActivityCopyFormatted)",
            "Outcome: \(event.outcome.copyDisplayName)",
            "Outcome key: \(event.outcome.rawValue)",
            "Kind: \(event.kind.displayName)",
            "Kind key: \(event.kind.rawValue)",
            "Summary: \(event.summary)"
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
            if let underlyingErrorDomain = event.underlyingErrorDomain, underlyingErrorDomain.isEmpty == false {
                lines.append("Underlying error domain: \(underlyingErrorDomain)")
            }
            if let underlyingErrorCode = event.underlyingErrorCode {
                lines.append("Underlying error code: \(underlyingErrorCode)")
            }
            if let recoverySuggestion = event.recoverySuggestion, recoverySuggestion.isEmpty == false {
                lines.append("Recovery suggestion: \(recoverySuggestion)")
            }
            if let diagnosticSummary = event.diagnosticSummary, diagnosticSummary.isEmpty == false {
                lines.append("Diagnostic summary: \(diagnosticSummary)")
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

private struct ProviderItemLink: View {
    let domainIdentifier: String
    let itemIdentifier: String?
    let title: String
    let fallbackDetail: String?

    @State private var resolvedURL: URL?
    @State private var didResolve = false

    var body: some View {
        Group {
            if let resolvedURL {
                Link(destination: resolvedURL) {
                    Label(title, systemImage: "arrow.up.forward.app")
                }
            } else if let itemIdentifier {
                Label(fallbackDetail ?? itemIdentifier, systemImage: didResolve ? "link.badge.plus" : "link")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task(id: "\(domainIdentifier)-\(itemIdentifier ?? "")") {
            await resolveURL()
        }
    }

    private func resolveURL() async {
        guard let itemIdentifier else {
            didResolve = true
            resolvedURL = nil
            return
        }

        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domainIdentifier),
            displayName: domainIdentifier
        )
        guard let manager = NSFileProviderManager(for: domain) else {
            didResolve = true
            resolvedURL = nil
            return
        }

        resolvedURL = await withCheckedContinuation { continuation in
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(itemIdentifier)) { url, _ in
                continuation.resume(returning: url)
            }
        }
        didResolve = true
    }
}

private extension Date {
    var providerActivityCopyFormatted: String {
        formatted(.dateTime.year().month().day().hour().minute().second())
    }
}

private extension KDriveProviderActivityKind {
    var displayName: String {
        switch self {
        case .enumeration:
            return "Enumeration"
        case .changeSync:
            return "Change Sync"
        case .syncAnchor:
            return "Sync Anchor"
        case .fetchContents:
            return "Fetch"
        case .metadataLookup:
            return "Metadata Lookup"
        case .create:
            return "Create"
        case .modify:
            return "Modify"
        case .trash:
            return "Trash"
        case .delete:
            return "Delete"
        case .conflict:
            return "Conflict"
        case .thumbnail:
            return "Thumbnail"
        case .runtimeLoading:
            return "Runtime Loading"
        case .authentication:
            return "Authentication"
        case .driveDiscovery:
            return "Drive Discovery"
        case .domainManagement:
            return "Domain Management"
        }
    }

    var systemImage: String {
        switch self {
        case .enumeration:
            return "list.bullet.rectangle"
        case .changeSync:
            return "arrow.triangle.2.circlepath"
        case .syncAnchor:
            return "link"
        case .fetchContents:
            return "arrow.down.doc"
        case .metadataLookup:
            return "doc.text.magnifyingglass"
        case .create:
            return "plus"
        case .modify:
            return "pencil"
        case .trash:
            return "trash"
        case .delete:
            return "xmark.bin"
        case .conflict:
            return "exclamationmark.triangle"
        case .thumbnail:
            return "photo"
        case .runtimeLoading:
            return "gearshape"
        case .authentication:
            return "person.crop.circle.badge.exclamationmark"
        case .driveDiscovery:
            return "externaldrive.badge.questionmark"
        case .domainManagement:
            return "folder.badge.gearshape"
        }
    }
}

private extension KDriveProviderActivityOutcome {
    func systemImage(for kind: KDriveProviderActivityKind) -> String {
        switch self {
        case .success:
            return kind.systemImage
        case .failure:
            return "exclamationmark.triangle"
        }
    }

    var copyDisplayName: String {
        switch self {
        case .success:
            return "Success"
        case .failure:
            return "Failure"
        }
    }
}

private extension KDriveProviderActivitySeverity {
    var copyDisplayName: String {
        switch self {
        case .info:
            return "Info"
        case .warning:
            return "Warning"
        case .error:
            return "Error"
        }
    }
}

private extension KDriveProviderActivityErrorCategory {
    var displayName: String {
        switch self {
        case .authentication:
            return "Authentication"
        case .network:
            return "Network"
        case .api:
            return "API"
        case .fileProvider:
            return "File Provider"
        case .listing:
            return "Listing"
        case .snapshot:
            return "Snapshot"
        case .storage:
            return "Storage"
        case .validation:
            return "Validation"
        case .mutationConflict:
            return "Conflict"
        case .unknown:
            return "Unknown"
        }
    }
}

private extension KDriveConflictResolutionState {
    var displayName: String {
        switch self {
        case .unresolved:
            return "Unresolved"
        case .automaticallyResolved:
            return "Resolved"
        case .blockedRetryable:
            return "Blocked"
        case .failed:
            return "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .unresolved:
            return "questionmark.circle"
        case .automaticallyResolved:
            return "checkmark.circle"
        case .blockedRetryable:
            return "pause.circle"
        case .failed:
            return "xmark.circle"
        }
    }
}
