import Combine
import Foundation
import PotassiumProviderCore

struct ActivityTimelineSection: Identifiable, Equatable {
    let id: Date
    let entries: [KDriveProviderTimelineEntry]
}

@MainActor
final class ConflictLogViewModel: ObservableObject {
    static let pageSize = 50
    static let prefetchDistance = 10

    @Published private(set) var entries: [KDriveProviderTimelineEntry] = []
    @Published private(set) var sections: [ActivityTimelineSection] = []
    @Published private(set) var filter: KDriveProviderTimelineFilter = .errorsAndConflicts
    @Published private(set) var isInitialLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isClearing = false
    @Published private(set) var isExporting = false
    @Published private(set) var hasMore = false
    @Published private(set) var initialErrorMessage: String?
    @Published private(set) var paginationErrorMessage: String?
    @Published var actionErrorMessage: String?

    private let eventStore: (any KDriveProviderEventStoring)?
    private let timelineStore: (any KDriveProviderEventTimelinePaging)?
    private var nextCursor: KDriveProviderTimelineCursor?
    private var loadGeneration = 0
    private var hasLoadedAdditionalPages = false
    private var eventObservationTask: Task<Void, Never>?
    private var coalescedRefreshTask: Task<Void, Never>?

    init(eventStore: (any KDriveProviderEventStoring)?) {
        self.eventStore = eventStore
        timelineStore = eventStore as? any KDriveProviderEventTimelinePaging
    }

    deinit {
        eventObservationTask?.cancel()
        coalescedRefreshTask?.cancel()
    }

    var showsActivity: Bool {
        filter == .allActivity
    }

    var isLoading: Bool {
        isInitialLoading || isRefreshing
    }

    var isDatabaseUnavailable: Bool {
        eventStore == nil || timelineStore == nil
    }

    var canClearActivity: Bool {
        eventStore != nil
            && isInitialLoading == false
            && isLoadingMore == false
            && isRefreshing == false
            && isClearing == false
            && isExporting == false
    }

    var canExportSupportLog: Bool {
        eventStore is any KDriveProviderEventExporting
            && isExporting == false
            && isClearing == false
    }

    var canRefresh: Bool {
        timelineStore != nil
            && isInitialLoading == false
            && isLoadingMore == false
            && isRefreshing == false
            && isClearing == false
    }

    var canChangeFilter: Bool {
        timelineStore != nil && isClearing == false
    }

    func start() async {
        if entries.isEmpty && isInitialLoading == false {
            await load()
        }
        startObservingChanges()
    }

    func stop() {
        eventObservationTask?.cancel()
        eventObservationTask = nil
        coalescedRefreshTask?.cancel()
        coalescedRefreshTask = nil
    }

    func setFilter(_ newFilter: KDriveProviderTimelineFilter) async {
        guard canChangeFilter, filter != newFilter else { return }
        filter = newFilter
        await load()
    }

    func load() async {
        guard let timelineStore else {
            entries = []
            rebuildSections()
            hasMore = false
            initialErrorMessage = "Activity database is unavailable."
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        isLoadingMore = false
        isRefreshing = false
        isInitialLoading = true
        paginationErrorMessage = nil
        initialErrorMessage = nil
        defer {
            if generation == loadGeneration {
                isInitialLoading = false
            }
        }

        do {
            let page = try await timelineStore.timelinePage(
                filter: filter,
                before: nil,
                limit: Self.pageSize
            )
            guard generation == loadGeneration else { return }
            entries = page.entries
            nextCursor = page.nextCursor
            hasMore = page.hasMore
            hasLoadedAdditionalPages = false
            rebuildSections()
        } catch {
            guard generation == loadGeneration else { return }
            entries = []
            nextCursor = nil
            hasMore = false
            rebuildSections()
            initialErrorMessage = "Could not load activity events: \(error.localizedDescription)"
        }
    }

    func loadMoreIfNeeded(visibleEntryIDs: [String]) async {
        guard shouldPrefetch(visibleEntryIDs: visibleEntryIDs) else { return }
        await loadMore()
    }

    func loadMore() async {
        guard
            let timelineStore,
            hasMore,
            isLoadingMore == false,
            isInitialLoading == false,
            isRefreshing == false,
            isClearing == false,
            let nextCursor
        else {
            return
        }

        let generation = loadGeneration
        isLoadingMore = true
        paginationErrorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoadingMore = false
            }
        }

        do {
            let page = try await timelineStore.timelinePage(
                filter: filter,
                before: nextCursor,
                limit: Self.pageSize
            )
            guard generation == loadGeneration else { return }
            merge(page.entries)
            self.nextCursor = page.nextCursor
            hasMore = page.hasMore
            hasLoadedAdditionalPages = true
        } catch {
            guard generation == loadGeneration else { return }
            paginationErrorMessage = "Could not load older activity: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard let timelineStore else {
            initialErrorMessage = "Activity database is unavailable."
            return
        }
        guard canRefresh else { return }

        let generation = loadGeneration
        isRefreshing = true
        defer {
            if generation == loadGeneration {
                isRefreshing = false
            }
        }

        do {
            let page = try await timelineStore.timelinePage(
                filter: filter,
                before: nil,
                limit: Self.pageSize
            )
            guard generation == loadGeneration else { return }

            if hasLoadedAdditionalPages {
                merge(page.entries)
            } else {
                entries = page.entries
                nextCursor = page.nextCursor
                hasMore = page.hasMore
                rebuildSections()
            }
            initialErrorMessage = nil
            actionErrorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            if entries.isEmpty {
                initialErrorMessage = "Could not load activity events: \(error.localizedDescription)"
            } else {
                actionErrorMessage = "Could not refresh activity events: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func clearActivity() async -> Bool {
        guard let eventStore else {
            actionErrorMessage = "Activity database is unavailable."
            return false
        }
        guard canClearActivity else { return false }

        isClearing = true
        defer { isClearing = false }

        do {
            try await eventStore.removeActivityAndResolvedConflicts(domainIdentifier: nil)
            actionErrorMessage = nil
            await load()
            return true
        } catch {
            actionErrorMessage = "Could not clear activity events: \(error.localizedDescription)"
            return false
        }
    }

    func supportLogData() async -> Data? {
        guard let eventStore = eventStore as? any KDriveProviderEventExporting else {
            actionErrorMessage = "Support-log export is unavailable."
            return nil
        }
        guard canExportSupportLog else { return nil }

        isExporting = true
        defer { isExporting = false }

        do {
            let data = try await eventStore.supportLogData(domainIdentifier: nil)
            actionErrorMessage = nil
            return data
        } catch {
            actionErrorMessage = "Could not create support log: \(error.localizedDescription)"
            return nil
        }
    }

    func recordExportFailure(_ error: Error) {
        let cocoaError = error as NSError
        if error is CancellationError
            || (cocoaError.domain == NSCocoaErrorDomain
                && cocoaError.code == CocoaError.Code.userCancelled.rawValue) {
            return
        }
        actionErrorMessage = "Could not export support log: \(error.localizedDescription)"
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    private func shouldPrefetch(visibleEntryIDs: [String]) -> Bool {
        guard hasMore, isLoadingMore == false, visibleEntryIDs.isEmpty == false else {
            return false
        }
        let thresholdIndex = max(0, entries.count - Self.prefetchDistance)
        return visibleEntryIDs.contains { id in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            return index >= thresholdIndex
        }
    }

    private func merge(_ updatedEntries: [KDriveProviderTimelineEntry]) {
        var entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for entry in updatedEntries {
            entriesByID[entry.id] = entry
        }
        entries = entriesByID.values.sorted(by: Self.isNewer)
        rebuildSections()
    }

    private func rebuildSections() {
        let calendar = Calendar.autoupdatingCurrent
        var grouped: [(date: Date, entries: [KDriveProviderTimelineEntry])] = []

        for entry in entries {
            let date = calendar.startOfDay(for: entry.date)
            if grouped.last?.date == date {
                grouped[grouped.count - 1].entries.append(entry)
            } else {
                grouped.append((date, [entry]))
            }
        }
        sections = grouped.map { ActivityTimelineSection(id: $0.date, entries: $0.entries) }
    }

    private static func isNewer(
        _ lhs: KDriveProviderTimelineEntry,
        than rhs: KDriveProviderTimelineEntry
    ) -> Bool {
        let lhsCursor = lhs.cursor
        let rhsCursor = rhs.cursor
        if lhsCursor.date != rhsCursor.date {
            return lhsCursor.date > rhsCursor.date
        }
        if lhsCursor.kind != rhsCursor.kind {
            return lhsCursor.kind.rawValue > rhsCursor.kind.rawValue
        }
        return lhsCursor.eventID.uuidString > rhsCursor.eventID.uuidString
    }

    private func startObservingChanges() {
        guard
            eventObservationTask == nil,
            let observingStore = eventStore as? any KDriveProviderEventObserving
        else {
            return
        }

        eventObservationTask = Task { [weak self] in
            let changes = await observingStore.eventChanges(pollInterval: 1)
            for await _ in changes {
                guard Task.isCancelled == false else { return }
                self?.scheduleCoalescedRefresh()
            }
        }
    }

    private func scheduleCoalescedRefresh() {
        coalescedRefreshTask?.cancel()
        coalescedRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            await self?.refreshAfterActivitySettles()
        }
    }

    private func refreshAfterActivitySettles() async {
        while isInitialLoading || isLoadingMore || isClearing {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }
        await refresh()
    }
}
