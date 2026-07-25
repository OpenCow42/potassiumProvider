import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@Suite(.serialized)
struct ActivityTimelinePagingTests {
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
