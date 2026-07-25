import PotassiumProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct ConflictLogView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: ConflictLogViewModel
    @State private var isClearConfirmationPresented = false
    @State private var isSupportLogExporterPresented = false
    @State private var supportLogDocument: ProviderSupportLogDocument?
    @State private var scrollPositionID: String?
    @State private var visibleEntryIDs: [String] = []

    init(eventStore: (any KDriveProviderEventStoring)?) {
        _model = StateObject(wrappedValue: ConflictLogViewModel(eventStore: eventStore))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterControl
                Divider()
                timelineContent
            }
            .navigationTitle("Activities")
            .toolbar { activityToolbar }
            .task {
                await model.start()
            }
            .onDisappear {
                model.stop()
            }
            .confirmationDialog("Clear Activities?", isPresented: $isClearConfirmationPresented) {
                Button("Clear Events and Resolved Conflicts", role: .destructive) {
                    Task {
                        await model.clearActivity()
                        moveToLatest(animated: false)
                    }
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

    private var filterControl: some View {
        Picker("Activity visibility", selection: filterBinding) {
            Label("Errors", systemImage: "exclamationmark.triangle")
                .tag(KDriveProviderTimelineFilter.errorsAndConflicts)
            Label("All Activity", systemImage: "clock.arrow.circlepath")
                .tag(KDriveProviderTimelineFilter.allActivity)
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .frame(maxWidth: 420)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityLabel("Activity visibility")
        .accessibilityIdentifier("activity.filter")
    }

    private var filterBinding: Binding<KDriveProviderTimelineFilter> {
        Binding {
            model.filter
        } set: { filter in
            Task {
                await model.setFilter(filter)
                moveToLatest(animated: true)
            }
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if model.isDatabaseUnavailable {
            ContentUnavailableView(
                "Activities Unavailable",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text("The activity database could not be opened.")
            )
        } else if model.isInitialLoading && model.entries.isEmpty {
            ProgressView("Loading activities…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("activity.initialLoading")
        } else if let errorMessage = model.initialErrorMessage, model.entries.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Activities", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await model.load() }
                }
                .accessibilityIdentifier("activity.retryInitial")
            }
        } else if model.entries.isEmpty {
            ContentUnavailableView(
                emptyActivityTitle,
                systemImage: "checkmark.seal",
                description: Text(emptyActivityDescription)
            )
        } else {
            timelineScrollView
        }
    }

    private var timelineScrollView: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if let actionErrorMessage = model.actionErrorMessage {
                        ActivityInlineError(
                            message: actionErrorMessage,
                            dismiss: model.dismissActionError
                        )
                        .padding(.horizontal)
                        .padding(.top, 12)
                    }

                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                ProviderActivityTimelineRow(entry: entry)
                                    .id(entry.id)
                                    .padding(.horizontal)
                                    .padding(.vertical, 5)
                            }
                        } header: {
                            ActivityDateHeader(date: section.id)
                        }
                    }

                    paginationFooter
                }
                .scrollTargetLayout()
                .padding(.bottom, 12)
            }
            .scrollPosition(id: $scrollPositionID)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.35) { visibleIDs in
                visibleEntryIDs = visibleIDs
                Task { await model.loadMoreIfNeeded(visibleEntryIDs: visibleIDs) }
            }
            .refreshable {
                await model.refresh()
            }
            .accessibilityIdentifier("activity.timeline")

            if isAwayFromLatest {
                Button {
                    moveToLatest(animated: true)
                } label: {
                    Label("Back to Latest", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.borderedProminent)
                .labelStyle(.titleAndIcon)
                .padding()
                .accessibilityIdentifier("activity.backToLatest")
            }
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView("Loading older activity…")
                Spacer()
            }
            .padding()
            .accessibilityIdentifier("activity.loadingMore")
        } else if let paginationErrorMessage = model.paginationErrorMessage {
            VStack(spacing: 8) {
                Label(paginationErrorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await model.loadMore() }
                }
                .accessibilityIdentifier("activity.retryPage")
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else if model.hasMore == false {
            Label("End of activity", systemImage: "checkmark")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding()
                .accessibilityIdentifier("activity.end")
        }
    }

    @ToolbarContentBuilder
    private var activityToolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .automatic) {
            clearButton
            refreshButton
            exportButton
        }
        #else
        ToolbarItem(placement: .topBarTrailing) {
            refreshButton
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                exportButton
                clearButton
            } label: {
                Label("More Activity Actions", systemImage: "ellipsis.circle")
            }
        }
        #endif
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            isClearConfirmationPresented = true
        } label: {
            Label(model.isClearing ? "Clearing" : "Clear", systemImage: "trash")
        }
        .disabled(model.canClearActivity == false)
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(model.isLoading)
        .accessibilityIdentifier("activity.refresh")
    }

    private var exportButton: some View {
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

    private var isAwayFromLatest: Bool {
        guard let latestID = model.entries.first?.id else { return false }
        guard visibleEntryIDs.isEmpty == false else { return false }
        return visibleEntryIDs.contains(latestID) == false
    }

    private func moveToLatest(animated: Bool) {
        guard let latestID = model.entries.first?.id else { return }
        if animated && reduceMotion == false {
            withAnimation(.snappy) {
                scrollPositionID = latestID
            }
        } else {
            scrollPositionID = latestID
        }
    }

    private var emptyActivityTitle: String {
        model.showsActivity ? "No Activities Yet" : "No Errors or Conflicts"
    }

    private var emptyActivityDescription: String {
        model.showsActivity
            ? "Provider activity will appear here as files synchronize."
            : "Everything looks clear. Switch to All Activity to see successful operations."
    }
}

private struct ActivityDateHeader: View {
    let date: Date

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 7)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

private struct ActivityInlineError: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Dismiss activity message")
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("activity.error")
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
