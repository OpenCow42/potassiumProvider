import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@Suite(.serialized)
struct ActivityTimelinePagingTests {
    @MainActor
    @Test func itemOpeningReportsResolutionAndPresentationResults() async {
        let url = URL(fileURLWithPath: "/tmp/report.txt")
        let opened = ProviderItemOpening(
            resolve: { _, _ in .resolved(url) },
            present: { $0 == url }
        )
        let rejected = ProviderItemOpening(
            resolve: { _, _ in .resolved(url) },
            present: { _ in false }
        )
        let missingDomain = ProviderItemOpening(
            resolve: { _, _ in .domainUnavailable },
            present: { _ in true }
        )
        let missingItem = ProviderItemOpening(
            resolve: { _, _ in .itemUnavailable },
            present: { _ in true }
        )

        #expect(await opened.open(domainIdentifier: "domain", itemIdentifier: "item") == .opened)
        #expect(
            await rejected.open(domainIdentifier: "domain", itemIdentifier: "item")
                == .itemUnavailable
        )
        #expect(
            await missingDomain.open(domainIdentifier: "domain", itemIdentifier: "item")
                == .domainUnavailable
        )
        #expect(
            await missingItem.open(domainIdentifier: "domain", itemIdentifier: "item")
                == .itemUnavailable
        )
    }

    @MainActor
    @Test func copyActionOnlyReportsCopiedAfterASuccessfulWrite() {
        let successful = ProviderActivityCopyAction(write: { _ in true })
        let failed = ProviderActivityCopyAction(write: { _ in false })

        #expect(successful.copy("details") == .copied)
        #expect(failed.copy("details") == .failed)
    }

    @Test func itemOpenActionUsesThePlatformFileBrowserName() {
        #if os(macOS)
        #expect(ProviderFileBrowserPresentation.applicationName == "Finder")
        #expect(ProviderFileBrowserPresentation.openActionTitle == "Open in Finder")
        #expect(ProviderFileBrowserPresentation.openingActionTitle == "Opening in Finder…")
        #expect(
            ProviderFileBrowserPresentation.accessibilityLabel(for: "Report")
                == "Open Report in Finder"
        )
        #expect(
            ProviderFileBrowserPresentation.unavailableMessage
                == "This item could not be found in Finder. It may have been moved or deleted."
        )
        #else
        #expect(ProviderFileBrowserPresentation.applicationName == "Files")
        #expect(ProviderFileBrowserPresentation.openActionTitle == "Open in Files")
        #expect(ProviderFileBrowserPresentation.openingActionTitle == "Opening in Files…")
        #expect(
            ProviderFileBrowserPresentation.accessibilityLabel(for: "Report")
                == "Open Report in Files"
        )
        #expect(
            ProviderFileBrowserPresentation.unavailableMessage
                == "This item is not currently available in Files."
        )
        #endif
    }

    #if os(macOS)
    @MainActor
    @Test func finderRevealReportsAMissingItem() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-provider-item-\(UUID().uuidString)")

        #expect(ProviderFileBrowserPresentation.revealInFinder(missingURL) == false)
    }
    #endif

    @Test func sqliteTimelinePagesMixedEventsWithoutDuplicatesOrGaps() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveProviderEventSQLiteStore(
            databaseURL: directory.appendingPathComponent("Snapshots.sqlite3")
        )

        var expectedEntries: [KDriveProviderTimelineEntry] = []
        for index in 0..<7 {
            let event = makeActivity(
                id: UUID(),
                date: Date(timeIntervalSince1970: Double(700 - index * 100)),
                outcome: index.isMultiple(of: 2) ? .failure : .success
            )
            try await store.recordActivity(event)
            expectedEntries.append(.activity(event))
        }
        for index in 0..<5 {
            let event = makeConflict(
                id: UUID(),
                detectedAt: Date(timeIntervalSince1970: Double(650 - index * 100))
            )
            try await store.saveConflict(event)
            expectedEntries.append(.conflict(event))
        }
        let relatedActivity = makeActivity(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_000),
            outcome: .failure,
            relatedConflictID: UUID()
        )
        try await store.recordActivity(relatedActivity)

        expectedEntries.sort(by: isNewer)
        var cursor: KDriveProviderTimelineCursor?
        var actualEntries: [KDriveProviderTimelineEntry] = []
        repeat {
            let page = try await store.timelinePage(
                filter: .allActivity,
                before: cursor,
                limit: 3
            )
            actualEntries.append(contentsOf: page.entries)
            cursor = page.nextCursor
            if page.hasMore == false {
                break
            }
        } while true

        #expect(actualEntries.map(\.id) == expectedEntries.map(\.id))
        #expect(Set(actualEntries.map(\.id)).count == actualEntries.count)
        #expect(actualEntries.contains { $0.id == relatedActivity.timelineID } == false)
    }

    @Test func sqliteTimelineUsesEffectiveConflictDateAndStableEqualTimestampOrdering() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveProviderEventSQLiteStore(
            databaseURL: directory.appendingPathComponent("Snapshots.sqlite3")
        )
        let sharedDate = Date(timeIntervalSince1970: 500)
        var resolvedConflict = makeConflict(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            detectedAt: Date(timeIntervalSince1970: 100)
        )
        resolvedConflict.resolvedAt = sharedDate
        let sameDateActivity = makeActivity(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            date: sharedDate,
            outcome: .failure
        )
        let olderConflict = makeConflict(
            id: UUID(),
            detectedAt: Date(timeIntervalSince1970: 400)
        )

        try await store.saveConflict(resolvedConflict)
        try await store.recordActivity(sameDateActivity)
        try await store.saveConflict(olderConflict)

        let firstPage = try await store.timelinePage(
            filter: .errorsAndConflicts,
            before: nil,
            limit: 2
        )
        let secondPage = try await store.timelinePage(
            filter: .errorsAndConflicts,
            before: firstPage.nextCursor,
            limit: 2
        )

        #expect(firstPage.entries.map(\.id) == [
            resolvedConflict.timelineID,
            sameDateActivity.timelineID,
        ])
        #expect(firstPage.hasMore)
        #expect(secondPage.entries.map(\.id) == [olderConflict.timelineID])
        #expect(secondPage.hasMore == false)
    }

    @Test func sqliteTimelineFiltersSuccessesAndRelatedConflictActivityAtQueryTime() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveProviderEventSQLiteStore(
            databaseURL: directory.appendingPathComponent("Snapshots.sqlite3")
        )
        let success = makeActivity(id: UUID(), date: Date(timeIntervalSince1970: 300), outcome: .success)
        let failure = makeActivity(id: UUID(), date: Date(timeIntervalSince1970: 200), outcome: .failure)
        let relatedFailure = makeActivity(
            id: UUID(),
            date: Date(timeIntervalSince1970: 400),
            outcome: .failure,
            relatedConflictID: UUID()
        )
        try await store.recordActivity(success)
        try await store.recordActivity(failure)
        try await store.recordActivity(relatedFailure)

        let errors = try await store.timelinePage(
            filter: .errorsAndConflicts,
            before: nil,
            limit: 50
        )
        let all = try await store.timelinePage(filter: .allActivity, before: nil, limit: 50)

        #expect(errors.entries.map(\.id) == [failure.timelineID])
        #expect(all.entries.map(\.id) == [success.timelineID, failure.timelineID])
    }

    @Test func keysetCursorKeepsOlderPageStableWhenNewEventArrives() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KDriveProviderEventSQLiteStore(
            databaseURL: directory.appendingPathComponent("Snapshots.sqlite3")
        )
        for timestamp in [500.0, 400, 300, 200] {
            try await store.recordActivity(makeActivity(
                id: UUID(),
                date: Date(timeIntervalSince1970: timestamp),
                outcome: .success
            ))
        }

        let firstPage = try await store.timelinePage(filter: .allActivity, before: nil, limit: 2)
        let inserted = makeActivity(
            id: UUID(),
            date: Date(timeIntervalSince1970: 450),
            outcome: .success
        )
        try await store.recordActivity(inserted)
        let olderPage = try await store.timelinePage(
            filter: .allActivity,
            before: firstPage.nextCursor,
            limit: 2
        )
        let refreshedPage = try await store.timelinePage(filter: .allActivity, before: nil, limit: 3)

        #expect(Set(firstPage.entries.map(\.id)).isDisjoint(with: olderPage.entries.map(\.id)))
        #expect(olderPage.entries.contains { $0.id == inserted.timelineID } == false)
        #expect(refreshedPage.entries.contains { $0.id == inserted.timelineID })
    }

    @MainActor
    @Test func viewModelPrefetchesOnceNearTheEndAndAppendsInPlace() async throws {
        let activity = (0..<120).map { index in
            makeActivity(
                id: UUID(),
                date: Date(timeIntervalSince1970: Double(1_000 - index)),
                outcome: .failure
            )
        }
        let store = PagingEventStore(activity: activity)
        let model = ConflictLogViewModel(eventStore: store)

        await model.load()
        #expect(model.entries.count == 50)
        #expect(model.hasMore)

        let firstTriggerID = model.entries[40].id
        await model.loadMoreIfNeeded(visibleEntryIDs: [firstTriggerID])
        await model.loadMoreIfNeeded(visibleEntryIDs: [firstTriggerID])

        #expect(model.entries.count == 100)
        #expect(await store.pageRequestCount() == 2)

        await model.loadMoreIfNeeded(visibleEntryIDs: [model.entries[90].id])
        #expect(model.entries.count == 120)
        #expect(model.hasMore == false)
        #expect(await store.pageRequestCount() == 3)
    }

    @MainActor
    @Test func viewModelKeepsLoadedEntriesAndCleansProgressAfterPagingFailure() async throws {
        let activity = (0..<80).map { index in
            makeActivity(
                id: UUID(),
                date: Date(timeIntervalSince1970: Double(1_000 - index)),
                outcome: .failure
            )
        }
        let store = PagingEventStore(activity: activity)
        let model = ConflictLogViewModel(eventStore: store)
        await model.load()
        await store.failNextOlderPage()

        await model.loadMoreIfNeeded(visibleEntryIDs: [model.entries[40].id])

        #expect(model.entries.count == 50)
        #expect(model.isLoadingMore == false)
        #expect(model.paginationErrorMessage != nil)

        await model.loadMore()
        #expect(model.entries.count == 80)
        #expect(model.paginationErrorMessage == nil)
        #expect(model.isLoadingMore == false)
    }

    @MainActor
    @Test func viewModelRefreshMergesNewEntriesWithoutDiscardingLoadedHistory() async throws {
        let activity = (0..<70).map { index in
            makeActivity(
                id: UUID(),
                date: Date(timeIntervalSince1970: Double(1_000 - index)),
                outcome: .failure
            )
        }
        let store = PagingEventStore(activity: activity)
        let model = ConflictLogViewModel(eventStore: store)
        await model.load()
        await model.loadMore()
        let loadedIDs = Set(model.entries.map(\.id))
        let newEvent = makeActivity(
            id: UUID(),
            date: Date(timeIntervalSince1970: 2_000),
            outcome: .failure
        )
        await store.recordActivity(newEvent)

        await model.refresh()

        #expect(model.entries.first?.id == newEvent.timelineID)
        #expect(loadedIDs.isSubset(of: Set(model.entries.map(\.id))))
        #expect(Set(model.entries.map(\.id)).count == model.entries.count)
    }

    @MainActor
    @Test func viewModelGuardsClearAndExportFromOverlapAndDuplicateCalls() async {
        let store = BlockingActivityActionStore()
        let model = ConflictLogViewModel(eventStore: store)
        await model.load()

        let clearTask = Task { await model.clearActivity() }
        while await store.clearRequestCount() == 0 {
            await Task.yield()
        }
        #expect(model.isClearing)
        #expect(model.canExportSupportLog == false)
        #expect(await model.clearActivity() == false)
        #expect(await model.supportLogData() == nil)
        #expect(await store.clearRequestCount() == 1)
        #expect(await store.exportRequestCount() == 0)

        await store.releaseClear()
        #expect(await clearTask.value)
        #expect(model.isClearing == false)

        let exportTask = Task { await model.supportLogData() }
        while await store.exportRequestCount() == 0 {
            await Task.yield()
        }
        #expect(model.isExporting)
        #expect(model.canClearActivity == false)
        #expect(await model.supportLogData() == nil)
        #expect(await model.clearActivity() == false)
        #expect(await store.exportRequestCount() == 1)
        #expect(await store.clearRequestCount() == 1)

        await store.releaseExport()
        #expect(await exportTask.value != nil)
        #expect(model.isExporting == false)
    }

    @MainActor
    @Test func viewModelAvailabilityMatchesUnavailableAndBusyStates() async {
        let unavailable = ConflictLogViewModel(eventStore: nil)
        #expect(unavailable.canRefresh == false)
        #expect(unavailable.canChangeFilter == false)
        #expect(unavailable.canClearActivity == false)
        #expect(unavailable.canExportSupportLog == false)

        let store = BlockingActivityActionStore()
        let model = ConflictLogViewModel(eventStore: store)
        await model.load()
        #expect(model.canRefresh)
        #expect(model.canChangeFilter)

        let clearTask = Task { await model.clearActivity() }
        while await store.clearRequestCount() == 0 {
            await Task.yield()
        }
        #expect(model.canRefresh == false)
        #expect(model.canChangeFilter == false)
        await store.releaseClear()
        #expect(await clearTask.value)
        #expect(model.canRefresh)
        #expect(model.canChangeFilter)
    }

    @MainActor
    @Test func viewModelCleansActionProgressAfterFailures() async {
        let store = FailingActivityActionStore()
        let model = ConflictLogViewModel(eventStore: store)
        await model.load()

        #expect(await model.clearActivity() == false)
        #expect(model.isClearing == false)
        #expect(model.actionErrorMessage?.contains("Could not clear activity events") == true)

        #expect(await model.supportLogData() == nil)
        #expect(model.isExporting == false)
        #expect(model.actionErrorMessage?.contains("Could not create support log") == true)
    }

    @MainActor
    @Test func refreshAvailabilityTracksInitialAndPagingLoads() async {
        let entry = KDriveProviderTimelineEntry.activity(makeActivity(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_000),
            outcome: .failure
        ))
        let initialStore = BlockingTimelineStore(entry: entry, blocksInitialLoad: true)
        let initialModel = ConflictLogViewModel(eventStore: initialStore)
        let initialTask = Task { await initialModel.load() }
        while await initialStore.pageRequestCount() == 0 {
            await Task.yield()
        }
        #expect(initialModel.isInitialLoading)
        #expect(initialModel.canRefresh == false)
        #expect(initialModel.canChangeFilter)
        await initialStore.releasePage()
        await initialTask.value
        #expect(initialModel.canRefresh)

        let pagingStore = BlockingTimelineStore(entry: entry, blocksInitialLoad: false)
        let pagingModel = ConflictLogViewModel(eventStore: pagingStore)
        await pagingModel.load()
        let pagingTask = Task { await pagingModel.loadMore() }
        while await pagingStore.pageRequestCount() < 2 {
            await Task.yield()
        }
        #expect(pagingModel.isLoadingMore)
        #expect(pagingModel.canRefresh == false)
        #expect(pagingModel.canChangeFilter)
        await pagingStore.releasePage()
        await pagingTask.value
        #expect(pagingModel.canRefresh)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-timeline-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeActivity(
        id: UUID,
        date: Date,
        outcome: KDriveProviderActivityOutcome,
        relatedConflictID: UUID? = nil
    ) -> KDriveProviderActivityEvent {
        KDriveProviderActivityEvent(
            id: id,
            occurredAt: date,
            domainIdentifier: "domain-1",
            driveID: 1,
            kind: .enumeration,
            outcome: outcome,
            severity: outcome == .failure ? .error : .info,
            itemIdentifier: nil,
            itemName: nil,
            itemPath: nil,
            summary: "Activity \(id.uuidString)",
            relatedConflictID: relatedConflictID
        )
    }

    private func makeConflict(id: UUID, detectedAt: Date) -> KDriveConflictEvent {
        KDriveConflictEvent(
            id: id,
            detectedAt: detectedAt,
            domainIdentifier: "domain-1",
            driveID: 1,
            operation: .modify,
            originalItemIdentifier: "item-\(id.uuidString)",
            originalItemName: "Report.txt",
            originalItemPath: "/Report.txt",
            resolutionState: .blockedRetryable,
            automaticallyResolved: false,
            resolutionKind: .blockedBeforeServerMutation,
            resolutionSummary: "The operation is blocked."
        )
    }

    private func isNewer(
        _ lhs: KDriveProviderTimelineEntry,
        than rhs: KDriveProviderTimelineEntry
    ) -> Bool {
        if lhs.cursor.date != rhs.cursor.date {
            return lhs.cursor.date > rhs.cursor.date
        }
        if lhs.cursor.kind != rhs.cursor.kind {
            return lhs.cursor.kind.rawValue > rhs.cursor.kind.rawValue
        }
        return lhs.cursor.eventID.uuidString > rhs.cursor.eventID.uuidString
    }
}

private actor PagingEventStore: KDriveProviderEventStoring, KDriveProviderEventTimelinePaging {
    private var conflicts: [KDriveConflictEvent] = []
    private var activity: [KDriveProviderActivityEvent]
    private var requestCount = 0
    private var shouldFailNextOlderPage = false

    init(activity: [KDriveProviderActivityEvent]) {
        self.activity = activity
    }

    func saveConflict(_ event: KDriveConflictEvent) {
        conflicts.removeAll { $0.id == event.id }
        conflicts.append(event)
    }

    func recordActivity(_ event: KDriveProviderActivityEvent) {
        activity.removeAll { $0.id == event.id }
        activity.append(event)
    }

    func recentConflicts(domainIdentifier: String?, limit: Int) -> [KDriveConflictEvent] {
        Array(conflicts.prefix(limit))
    }

    func recentActivity(domainIdentifier: String?, limit: Int) -> [KDriveProviderActivityEvent] {
        Array(activity.prefix(limit))
    }

    func recentActivity(
        domainIdentifier: String?,
        outcome: KDriveProviderActivityOutcome?,
        limit: Int
    ) -> [KDriveProviderActivityEvent] {
        Array(activity.filter { outcome == nil || $0.outcome == outcome }.prefix(limit))
    }

    func removeActivityAndResolvedConflicts(domainIdentifier: String?) {
        activity.removeAll()
        conflicts.removeAll { $0.resolutionState == .automaticallyResolved }
    }

    func removeEvents(domainIdentifier: String) {
        activity.removeAll { $0.domainIdentifier == domainIdentifier }
        conflicts.removeAll { $0.domainIdentifier == domainIdentifier }
    }

    func timelinePage(
        filter: KDriveProviderTimelineFilter,
        before cursor: KDriveProviderTimelineCursor?,
        limit: Int
    ) throws -> KDriveProviderTimelinePage {
        requestCount += 1
        if cursor != nil, shouldFailNextOlderPage {
            shouldFailNextOlderPage = false
            throw TestPagingError.failed
        }

        let sorted = (
            conflicts.map(KDriveProviderTimelineEntry.conflict)
                + activity
                    .filter { $0.relatedConflictID == nil }
                    .filter { filter == .allActivity || $0.outcome == .failure }
                    .map(KDriveProviderTimelineEntry.activity)
        ).sorted(by: Self.isNewer)
        let eligible = sorted.filter { entry in
            guard let cursor else { return true }
            return Self.isOlder(entry.cursor, than: cursor)
        }
        let entries = Array(eligible.prefix(limit))
        let hasMore = eligible.count > entries.count
        return KDriveProviderTimelinePage(
            entries: entries,
            nextCursor: hasMore ? entries.last?.cursor : nil,
            hasMore: hasMore
        )
    }

    func pageRequestCount() -> Int {
        requestCount
    }

    func failNextOlderPage() {
        shouldFailNextOlderPage = true
    }

    private static func isNewer(
        _ lhs: KDriveProviderTimelineEntry,
        than rhs: KDriveProviderTimelineEntry
    ) -> Bool {
        if lhs.cursor.date != rhs.cursor.date {
            return lhs.cursor.date > rhs.cursor.date
        }
        if lhs.cursor.kind != rhs.cursor.kind {
            return lhs.cursor.kind.rawValue > rhs.cursor.kind.rawValue
        }
        return lhs.cursor.eventID.uuidString > rhs.cursor.eventID.uuidString
    }

    private static func isOlder(
        _ lhs: KDriveProviderTimelineCursor,
        than rhs: KDriveProviderTimelineCursor
    ) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date < rhs.date
        }
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.eventID.uuidString < rhs.eventID.uuidString
    }
}

private actor BlockingActivityActionStore:
    KDriveProviderEventStoring,
    KDriveProviderEventTimelinePaging,
    KDriveProviderEventExporting
{
    private var clearCount = 0
    private var exportCount = 0
    private var clearContinuation: CheckedContinuation<Void, Never>?
    private var exportContinuation: CheckedContinuation<Void, Never>?

    func saveConflict(_: KDriveConflictEvent) {}
    func recordActivity(_: KDriveProviderActivityEvent) {}
    func recentConflicts(domainIdentifier _: String?, limit _: Int) -> [KDriveConflictEvent] { [] }
    func recentActivity(domainIdentifier _: String?, limit _: Int) -> [KDriveProviderActivityEvent] { [] }
    func recentActivity(
        domainIdentifier _: String?,
        outcome _: KDriveProviderActivityOutcome?,
        limit _: Int
    ) -> [KDriveProviderActivityEvent] { [] }

    func removeActivityAndResolvedConflicts(domainIdentifier _: String?) async {
        clearCount += 1
        await withCheckedContinuation { clearContinuation = $0 }
    }

    func removeEvents(domainIdentifier _: String) {}

    func timelinePage(
        filter _: KDriveProviderTimelineFilter,
        before _: KDriveProviderTimelineCursor?,
        limit _: Int
    ) -> KDriveProviderTimelinePage {
        KDriveProviderTimelinePage(entries: [], nextCursor: nil, hasMore: false)
    }

    func supportLogData(domainIdentifier _: String?) async -> Data {
        exportCount += 1
        await withCheckedContinuation { exportContinuation = $0 }
        return Data("{}".utf8)
    }

    func clearRequestCount() -> Int { clearCount }
    func exportRequestCount() -> Int { exportCount }

    func releaseClear() {
        clearContinuation?.resume()
        clearContinuation = nil
    }

    func releaseExport() {
        exportContinuation?.resume()
        exportContinuation = nil
    }
}

private actor FailingActivityActionStore:
    KDriveProviderEventStoring,
    KDriveProviderEventTimelinePaging,
    KDriveProviderEventExporting
{
    func saveConflict(_: KDriveConflictEvent) {}
    func recordActivity(_: KDriveProviderActivityEvent) {}
    func recentConflicts(domainIdentifier _: String?, limit _: Int) -> [KDriveConflictEvent] { [] }
    func recentActivity(domainIdentifier _: String?, limit _: Int) -> [KDriveProviderActivityEvent] { [] }
    func recentActivity(
        domainIdentifier _: String?,
        outcome _: KDriveProviderActivityOutcome?,
        limit _: Int
    ) -> [KDriveProviderActivityEvent] { [] }
    func removeActivityAndResolvedConflicts(domainIdentifier _: String?) throws {
        throw TestPagingError.failed
    }
    func removeEvents(domainIdentifier _: String) {}
    func timelinePage(
        filter _: KDriveProviderTimelineFilter,
        before _: KDriveProviderTimelineCursor?,
        limit _: Int
    ) -> KDriveProviderTimelinePage {
        KDriveProviderTimelinePage(entries: [], nextCursor: nil, hasMore: false)
    }
    func supportLogData(domainIdentifier _: String?) throws -> Data {
        throw TestPagingError.failed
    }
}

private actor BlockingTimelineStore: KDriveProviderEventStoring, KDriveProviderEventTimelinePaging {
    private let entry: KDriveProviderTimelineEntry
    private let blocksInitialLoad: Bool
    private var requestCount = 0
    private var pageContinuation: CheckedContinuation<Void, Never>?

    init(entry: KDriveProviderTimelineEntry, blocksInitialLoad: Bool) {
        self.entry = entry
        self.blocksInitialLoad = blocksInitialLoad
    }

    func saveConflict(_: KDriveConflictEvent) {}
    func recordActivity(_: KDriveProviderActivityEvent) {}
    func recentConflicts(domainIdentifier _: String?, limit _: Int) -> [KDriveConflictEvent] { [] }
    func recentActivity(domainIdentifier _: String?, limit _: Int) -> [KDriveProviderActivityEvent] { [] }
    func recentActivity(
        domainIdentifier _: String?,
        outcome _: KDriveProviderActivityOutcome?,
        limit _: Int
    ) -> [KDriveProviderActivityEvent] { [] }
    func removeActivityAndResolvedConflicts(domainIdentifier _: String?) {}
    func removeEvents(domainIdentifier _: String) {}

    func timelinePage(
        filter _: KDriveProviderTimelineFilter,
        before: KDriveProviderTimelineCursor?,
        limit _: Int
    ) async -> KDriveProviderTimelinePage {
        requestCount += 1
        if (before == nil && blocksInitialLoad) || before != nil {
            await withCheckedContinuation { pageContinuation = $0 }
        }
        if before == nil {
            return KDriveProviderTimelinePage(
                entries: [entry],
                nextCursor: entry.cursor,
                hasMore: true
            )
        }
        return KDriveProviderTimelinePage(entries: [], nextCursor: nil, hasMore: false)
    }

    func pageRequestCount() -> Int { requestCount }

    func releasePage() {
        pageContinuation?.resume()
        pageContinuation = nil
    }
}

private enum TestPagingError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The test page failed."
    }
}

private extension KDriveProviderActivityEvent {
    var timelineID: String { "activity-\(id.uuidString)" }
}

private extension KDriveConflictEvent {
    var timelineID: String { "conflict-\(id.uuidString)" }
}
