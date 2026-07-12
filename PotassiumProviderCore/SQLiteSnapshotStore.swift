import Foundation
@preconcurrency import SQLite

public actor KDriveSnapshotSQLiteStore: KDriveSnapshotStoring, KDriveSnapshotStatisticsProviding, KDriveWorkingSetStateStoring {
    private let databaseURL: URL
    private let database: Connection

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try Connection(databaseURL.path)
        try Self.configure(database)
        try Self.createTables(on: database)
        self.database = database
    }

    public init(appGroupIdentifier: String = ProviderConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw KDriveSnapshotStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        try self.init(databaseURL: containerURL.appendingPathComponent("Snapshots.sqlite3"))
    }

    public func snapshot(domainIdentifier: String, containerIdentifier: String) throws -> KDriveSnapshot? {
        let snapshotQuery = Schema.containerSnapshots
            .filter(Schema.domainIdentifier == domainIdentifier && Schema.containerIdentifier == containerIdentifier)

        guard let snapshotRow = try database.pluck(snapshotQuery) else {
            return nil
        }

        let itemRows = try database.prepare(
            Schema.snapshotItems
                .filter(Schema.domainIdentifier == domainIdentifier && Schema.containerIdentifier == containerIdentifier)
                .order(Schema.position.asc)
        )
        let items = itemRows.map(Self.remoteItem(from:))

        return KDriveSnapshot(
            anchor: snapshotRow[Schema.anchor],
            serverCursor: snapshotRow[Schema.serverCursor],
            isFullyEnumerated: snapshotRow[Schema.isFullyEnumerated],
            usesAdvancedListing: snapshotRow[Schema.usesAdvancedListing],
            items: items
        )
    }

    public func item(domainIdentifier: String, fileID: Int) throws -> KDriveRemoteItem? {
        let itemQuery = Schema.snapshotItems
            .filter(Schema.domainIdentifier == domainIdentifier && Schema.itemID == fileID)
            .limit(1)

        guard let row = try database.pluck(itemQuery) else {
            return nil
        }

        return Self.remoteItem(from: row)
    }

    public func save(
        _ snapshot: KDriveSnapshot,
        domainIdentifier: String,
        containerIdentifier: String,
        condition: KDriveSnapshotSaveCondition
    ) throws {
        try database.transaction {
            let currentSnapshot = try self.snapshot(domainIdentifier: domainIdentifier, containerIdentifier: containerIdentifier)
            guard condition.accepts(currentSnapshot) else {
                throw KDriveSnapshotStoreError.staleSnapshot(
                    domainIdentifier: domainIdentifier,
                    containerIdentifier: containerIdentifier
                )
            }

            try deleteSnapshot(domainIdentifier: domainIdentifier, containerIdentifier: containerIdentifier)

            try database.run(Schema.containerSnapshots.insert(
                Schema.domainIdentifier <- domainIdentifier,
                Schema.containerIdentifier <- containerIdentifier,
                Schema.anchor <- snapshot.anchor,
                Schema.serverCursor <- snapshot.serverCursor,
                Schema.isFullyEnumerated <- snapshot.isFullyEnumerated,
                Schema.usesAdvancedListing <- snapshot.usesAdvancedListing,
                Schema.updatedAt <- Date().timeIntervalSince1970
            ))

            for (position, item) in snapshot.items.enumerated() {
                try database.run(Schema.snapshotItems.insert(Self.setters(
                    for: item,
                    domainIdentifier: domainIdentifier,
                    containerIdentifier: containerIdentifier,
                    position: position
                )))
            }
        }
    }

    public func removeSnapshots(domainIdentifier: String) throws {
        try database.transaction {
            try database.run(Schema.snapshotItems.filter(Schema.domainIdentifier == domainIdentifier).delete())
            try database.run(Schema.containerSnapshots.filter(Schema.domainIdentifier == domainIdentifier).delete())
            try database.run(WorkingSetSchema.materializedItems.filter(WorkingSetSchema.domainIdentifier == domainIdentifier).delete())
            try database.run(WorkingSetSchema.changeBatches.filter(WorkingSetSchema.domainIdentifier == domainIdentifier).delete())
            try database.run(WorkingSetSchema.pollState.filter(WorkingSetSchema.domainIdentifier == domainIdentifier).delete())
        }
    }

    public func removeSnapshot(domainIdentifier: String, containerIdentifier: String) throws {
        try database.transaction {
            try deleteSnapshot(domainIdentifier: domainIdentifier, containerIdentifier: containerIdentifier)
        }
    }

    public func snapshotStatistics(domainIdentifiers: Set<String>) throws -> [KDriveSnapshotDomainStatistics] {
        let requestedDomainIdentifiers = Set(domainIdentifiers.filter { $0.isEmpty == false })
        guard requestedDomainIdentifiers.isEmpty == false else { return [] }

        var builders = Dictionary(uniqueKeysWithValues: requestedDomainIdentifiers.map {
            ($0, KDriveSnapshotDomainStatisticsBuilder(domainIdentifier: $0))
        })

        for row in try database.prepare(Schema.containerSnapshots) {
            let domainIdentifier = row[Schema.domainIdentifier]
            guard var builder = builders[domainIdentifier] else { continue }

            builder.containerCount += 1
            if row[Schema.isFullyEnumerated] {
                builder.fullyEnumeratedContainerCount += 1
            }
            if row[Schema.usesAdvancedListing] {
                builder.advancedListingContainerCount += 1
            }

            let updatedAt = Date(timeIntervalSince1970: row[Schema.updatedAt])
            if builder.lastUpdatedAt.map({ updatedAt > $0 }) ?? true {
                builder.lastUpdatedAt = updatedAt
            }
            builders[domainIdentifier] = builder
        }

        for row in try database.prepare(Schema.snapshotItems) {
            let domainIdentifier = row[Schema.domainIdentifier]
            guard var builder = builders[domainIdentifier] else { continue }
            builder.itemCount += 1
            builders[domainIdentifier] = builder
        }

        return requestedDomainIdentifiers
            .sorted()
            .compactMap { builders[$0]?.statistics }
    }

    public func replaceMaterializedItems(
        _ items: [KDriveMaterializedItem],
        domainIdentifier: String
    ) throws {
        try database.transaction {
            try database.run(
                WorkingSetSchema.materializedItems
                    .filter(WorkingSetSchema.domainIdentifier == domainIdentifier)
                    .delete()
            )
            for item in items {
                try database.run(WorkingSetSchema.materializedItems.insert(
                    WorkingSetSchema.domainIdentifier <- domainIdentifier,
                    WorkingSetSchema.fileID <- item.fileID,
                    WorkingSetSchema.isContainer <- item.isContainer
                ))
            }
        }
    }

    public func materializedItems(domainIdentifier: String) throws -> [KDriveMaterializedItem] {
        try database.prepare(
            WorkingSetSchema.materializedItems
                .filter(WorkingSetSchema.domainIdentifier == domainIdentifier)
                .order(WorkingSetSchema.fileID.asc)
        ).map {
            KDriveMaterializedItem(
                fileID: $0[WorkingSetSchema.fileID],
                isContainer: $0[WorkingSetSchema.isContainer]
            )
        }
    }

    public func workingSetSnapshot(domainIdentifier: String) throws -> KDriveWorkingSetSnapshot? {
        guard let row = try database.pluck(
            WorkingSetSchema.pollState.filter(WorkingSetSchema.domainIdentifier == domainIdentifier)
        ) else {
            return nil
        }
        return KDriveWorkingSetSnapshot(
            anchor: row[WorkingSetSchema.workingSetAnchor],
            items: try Self.decode([KDriveRemoteItem].self, from: row[WorkingSetSchema.workingSetItemsJSON])
        )
    }

    public func workingSetChanges(
        domainIdentifier: String,
        from anchor: String
    ) throws -> KDriveWorkingSetChanges? {
        guard let snapshot = try workingSetSnapshot(domainIdentifier: domainIdentifier) else {
            return nil
        }
        if snapshot.anchor == anchor {
            return KDriveWorkingSetChanges(
                changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: []),
                anchor: anchor
            )
        }

        let rows = try database.prepare(
            WorkingSetSchema.changeBatches
                .filter(WorkingSetSchema.domainIdentifier == domainIdentifier)
                .order(WorkingSetSchema.changeSequence.asc)
        )
        var cursor = anchor
        var updatesByID: [Int: KDriveRemoteItem] = [:]
        var deletedIDs = Set<Int>()
        var foundStart = false

        for row in rows {
            guard row[WorkingSetSchema.anchorBefore] == cursor else {
                if foundStart { break }
                continue
            }
            foundStart = true
            let updates = try Self.decode([KDriveRemoteItem].self, from: row[WorkingSetSchema.updatedItemsJSON])
            let deletions = try Self.decode([Int].self, from: row[WorkingSetSchema.deletedItemIDsJSON])
            for item in updates {
                deletedIDs.remove(item.id)
                updatesByID[item.id] = item
            }
            for fileID in deletions {
                updatesByID[fileID] = nil
                deletedIDs.insert(fileID)
            }
            cursor = row[WorkingSetSchema.anchorAfter]
            if cursor == snapshot.anchor { break }
        }

        guard foundStart, cursor == snapshot.anchor else { return nil }
        return KDriveWorkingSetChanges(
            changes: KDriveSnapshotChangeSet(
                updatedItems: updatesByID.values.sorted { $0.id < $1.id },
                deletedItemIDs: deletedIDs.sorted()
            ),
            anchor: snapshot.anchor
        )
    }

    public func lastSuccessfulWorkingSetPoll(domainIdentifier: String) throws -> Date? {
        try database.pluck(
            WorkingSetSchema.pollState.filter(WorkingSetSchema.domainIdentifier == domainIdentifier)
        )?[WorkingSetSchema.lastSuccessfulPollAt].map(Date.init(timeIntervalSince1970:))
    }

    public func claimWorkingSetPoll(
        domainIdentifier: String,
        now: Date,
        minimumInterval: TimeInterval
    ) throws -> Bool {
        var claimed = false
        try database.transaction {
            let query = WorkingSetSchema.pollState.filter(WorkingSetSchema.domainIdentifier == domainIdentifier)
            if let row = try database.pluck(query) {
                if let lastAttempt = row[WorkingSetSchema.lastPollAttemptAt],
                   now.timeIntervalSince1970 - lastAttempt < minimumInterval {
                    return
                }
                try database.run(query.update(WorkingSetSchema.lastPollAttemptAt <- now.timeIntervalSince1970))
            } else {
                try database.run(WorkingSetSchema.pollState.insert(
                    WorkingSetSchema.domainIdentifier <- domainIdentifier,
                    WorkingSetSchema.workingSetAnchor <- UUID().uuidString,
                    WorkingSetSchema.workingSetItemsJSON <- try Self.encode([KDriveRemoteItem]()),
                    WorkingSetSchema.lastPollAttemptAt <- now.timeIntervalSince1970,
                    WorkingSetSchema.lastSuccessfulPollAt <- nil
                ))
            }
            claimed = true
        }
        return claimed
    }

    public func commitWorkingSetPoll(
        domainIdentifier: String,
        items: [KDriveRemoteItem],
        changes: KDriveSnapshotChangeSet,
        completedAt: Date
    ) throws -> KDriveWorkingSetSnapshot {
        var committedSnapshot: KDriveWorkingSetSnapshot?
        try database.transaction {
            let query = WorkingSetSchema.pollState.filter(WorkingSetSchema.domainIdentifier == domainIdentifier)
            let oldAnchor = try database.pluck(query)?[WorkingSetSchema.workingSetAnchor] ?? UUID().uuidString
            let newAnchor = changes.isEmpty ? oldAnchor : UUID().uuidString
            if changes.isEmpty == false {
                try database.run(WorkingSetSchema.changeBatches.insert(
                    WorkingSetSchema.domainIdentifier <- domainIdentifier,
                    WorkingSetSchema.anchorBefore <- oldAnchor,
                    WorkingSetSchema.anchorAfter <- newAnchor,
                    WorkingSetSchema.updatedItemsJSON <- try Self.encode(changes.updatedItems),
                    WorkingSetSchema.deletedItemIDsJSON <- try Self.encode(changes.deletedItemIDs),
                    WorkingSetSchema.changeCompletedAt <- completedAt.timeIntervalSince1970
                ))
            }

            try database.run(WorkingSetSchema.pollState.insert(or: .replace,
                WorkingSetSchema.domainIdentifier <- domainIdentifier,
                WorkingSetSchema.workingSetAnchor <- newAnchor,
                WorkingSetSchema.workingSetItemsJSON <- try Self.encode(items),
                WorkingSetSchema.lastPollAttemptAt <- completedAt.timeIntervalSince1970,
                WorkingSetSchema.lastSuccessfulPollAt <- completedAt.timeIntervalSince1970
            ))
            try trimWorkingSetChangeBatches(domainIdentifier: domainIdentifier, retaining: 32)
            committedSnapshot = KDriveWorkingSetSnapshot(anchor: newAnchor, items: items)
        }
        return committedSnapshot!
    }

    private func deleteSnapshot(domainIdentifier: String, containerIdentifier: String) throws {
        let filter = Schema.domainIdentifier == domainIdentifier && Schema.containerIdentifier == containerIdentifier
        try database.run(Schema.snapshotItems.filter(filter).delete())
        try database.run(Schema.containerSnapshots.filter(filter).delete())
    }

    private static func configure(_ database: Connection) throws {
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("PRAGMA busy_timeout=5000")
    }

    private static func createTables(on database: Connection) throws {
        try KDriveProviderEventSQLiteStore.createTables(on: database)

        try database.run(Schema.containerSnapshots.create(ifNotExists: true) { table in
            table.column(Schema.domainIdentifier)
            table.column(Schema.containerIdentifier)
            table.column(Schema.anchor)
            table.column(Schema.serverCursor)
            table.column(Schema.isFullyEnumerated)
            table.column(Schema.usesAdvancedListing)
            table.column(Schema.updatedAt)
            table.primaryKey(Schema.domainIdentifier, Schema.containerIdentifier)
        })

        try database.run(Schema.snapshotItems.create(ifNotExists: true) { table in
            table.column(Schema.domainIdentifier)
            table.column(Schema.containerIdentifier)
            table.column(Schema.position)
            table.column(Schema.itemID)
            table.column(Schema.name)
            table.column(Schema.type)
            table.column(Schema.status)
            table.column(Schema.driveID)
            table.column(Schema.parentID)
            table.column(Schema.path)
            table.column(Schema.size)
            table.column(Schema.mimeType)
            table.column(Schema.createdAt)
            table.column(Schema.modifiedAt)
            table.column(Schema.itemUpdatedAt)
            table.primaryKey(Schema.domainIdentifier, Schema.containerIdentifier, Schema.itemID)
        })

        try database.run(WorkingSetSchema.materializedItems.create(ifNotExists: true) { table in
            table.column(WorkingSetSchema.domainIdentifier)
            table.column(WorkingSetSchema.fileID)
            table.column(WorkingSetSchema.isContainer)
            table.primaryKey(WorkingSetSchema.domainIdentifier, WorkingSetSchema.fileID)
        })

        try database.run(WorkingSetSchema.pollState.create(ifNotExists: true) { table in
            table.column(WorkingSetSchema.domainIdentifier, primaryKey: true)
            table.column(WorkingSetSchema.workingSetAnchor)
            table.column(WorkingSetSchema.workingSetItemsJSON)
            table.column(WorkingSetSchema.lastPollAttemptAt)
            table.column(WorkingSetSchema.lastSuccessfulPollAt)
        })

        try database.run(WorkingSetSchema.changeBatches.create(ifNotExists: true) { table in
            table.column(WorkingSetSchema.changeSequence, primaryKey: .autoincrement)
            table.column(WorkingSetSchema.domainIdentifier)
            table.column(WorkingSetSchema.anchorBefore)
            table.column(WorkingSetSchema.anchorAfter)
            table.column(WorkingSetSchema.updatedItemsJSON)
            table.column(WorkingSetSchema.deletedItemIDsJSON)
            table.column(WorkingSetSchema.changeCompletedAt)
        })
    }

    private func trimWorkingSetChangeBatches(domainIdentifier: String, retaining count: Int) throws {
        let staleRows = try database.prepare(
            WorkingSetSchema.changeBatches
                .filter(WorkingSetSchema.domainIdentifier == domainIdentifier)
                .order(WorkingSetSchema.changeSequence.desc)
                .limit(-1, offset: count)
        )
        for row in staleRows {
            try database.run(
                WorkingSetSchema.changeBatches
                    .filter(WorkingSetSchema.changeSequence == row[WorkingSetSchema.changeSequence])
                    .delete()
            )
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from string: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }

    private static func setters(
        for item: KDriveRemoteItem,
        domainIdentifier: String,
        containerIdentifier: String,
        position: Int
    ) -> [Setter] {
        [
            Schema.domainIdentifier <- domainIdentifier,
            Schema.containerIdentifier <- containerIdentifier,
            Schema.position <- position,
            Schema.itemID <- item.id,
            Schema.name <- item.name,
            Schema.type <- item.type,
            Schema.status <- item.status,
            Schema.driveID <- item.driveID,
            Schema.parentID <- item.parentID,
            Schema.path <- item.path,
            Schema.size <- item.size,
            Schema.mimeType <- item.mimeType,
            Schema.createdAt <- item.createdAt?.timeIntervalSince1970,
            Schema.modifiedAt <- item.modifiedAt.timeIntervalSince1970,
            Schema.itemUpdatedAt <- item.updatedAt.timeIntervalSince1970,
        ]
    }

    private static func remoteItem(from row: Row) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: row[Schema.itemID],
            name: row[Schema.name],
            type: row[Schema.type],
            status: row[Schema.status],
            driveID: row[Schema.driveID],
            parentID: row[Schema.parentID],
            path: row[Schema.path],
            size: row[Schema.size],
            mimeType: row[Schema.mimeType],
            createdAt: row[Schema.createdAt].map { Date(timeIntervalSince1970: $0) },
            modifiedAt: Date(timeIntervalSince1970: row[Schema.modifiedAt]),
            updatedAt: Date(timeIntervalSince1970: row[Schema.itemUpdatedAt])
        )
    }
}

private struct KDriveSnapshotDomainStatisticsBuilder {
    let domainIdentifier: String
    var containerCount = 0
    var itemCount = 0
    var fullyEnumeratedContainerCount = 0
    var advancedListingContainerCount = 0
    var lastUpdatedAt: Date?

    var statistics: KDriveSnapshotDomainStatistics {
        KDriveSnapshotDomainStatistics(
            domainIdentifier: domainIdentifier,
            containerCount: containerCount,
            itemCount: itemCount,
            fullyEnumeratedContainerCount: fullyEnumeratedContainerCount,
            advancedListingContainerCount: advancedListingContainerCount,
            lastUpdatedAt: lastUpdatedAt
        )
    }
}

private enum Schema {
    static let containerSnapshots = Table("container_snapshots")
    static let snapshotItems = Table("snapshot_items")

    static let domainIdentifier = Expression<String>("domainIdentifier")
    static let containerIdentifier = Expression<String>("containerIdentifier")
    static let anchor = Expression<String>("anchor")
    static let serverCursor = Expression<String?>("serverCursor")
    static let isFullyEnumerated = Expression<Bool>("isFullyEnumerated")
    static let usesAdvancedListing = Expression<Bool>("usesAdvancedListing")
    static let updatedAt = Expression<Double>("updatedAt")

    static let position = Expression<Int>("position")
    static let itemID = Expression<Int>("itemID")
    static let name = Expression<String>("name")
    static let type = Expression<String?>("type")
    static let status = Expression<String>("status")
    static let driveID = Expression<Int>("driveID")
    static let parentID = Expression<Int>("parentID")
    static let path = Expression<String?>("path")
    static let size = Expression<Int?>("size")
    static let mimeType = Expression<String?>("mimeType")
    static let createdAt = Expression<Double?>("createdAt")
    static let modifiedAt = Expression<Double>("modifiedAt")
    static let itemUpdatedAt = Expression<Double>("itemUpdatedAt")
}

private enum WorkingSetSchema {
    static let materializedItems = Table("materialized_items")
    static let pollState = Table("working_set_poll_state")
    static let changeBatches = Table("working_set_change_batches")

    static let domainIdentifier = Expression<String>("domainIdentifier")
    static let fileID = Expression<Int>("fileID")
    static let isContainer = Expression<Bool>("isContainer")
    static let workingSetAnchor = Expression<String>("workingSetAnchor")
    static let workingSetItemsJSON = Expression<String>("workingSetItemsJSON")
    static let lastPollAttemptAt = Expression<Double?>("lastPollAttemptAt")
    static let lastSuccessfulPollAt = Expression<Double?>("lastSuccessfulPollAt")
    static let changeSequence = Expression<Int64>("changeSequence")
    static let anchorBefore = Expression<String>("anchorBefore")
    static let anchorAfter = Expression<String>("anchorAfter")
    static let updatedItemsJSON = Expression<String>("updatedItemsJSON")
    static let deletedItemIDsJSON = Expression<String>("deletedItemIDsJSON")
    static let changeCompletedAt = Expression<Double>("completedAt")
}
