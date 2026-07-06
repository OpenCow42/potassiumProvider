import Combine
import FileProvider
import PotassiumProviderCore
import SwiftUI

struct ConflictLogView: View {
    @StateObject private var model: ConflictLogViewModel
    @State private var isClearConfirmationPresented = false

    init(eventStore: (any KDriveProviderEventStoring)?) {
        _model = StateObject(wrappedValue: ConflictLogViewModel(eventStore: eventStore))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $model.showsActivity) {
                        Label("Last Activity", systemImage: "clock.arrow.circlepath")
                    }
                    .providerActivityControlGlass()
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                if model.timelineItems.isEmpty {
                    Section {
                        Label("No activities yet", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section(model.showsActivity ? "Timeline" : "Conflict and Failure Activity") {
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
        }
    }

    private var activityToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
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
}

@MainActor
final class ConflictLogViewModel: ObservableObject {
    @Published private(set) var conflicts: [KDriveConflictEvent] = []
    @Published private(set) var activity: [KDriveProviderActivityEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isClearing = false
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
