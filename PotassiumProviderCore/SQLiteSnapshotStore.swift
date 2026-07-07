import Foundation
@preconcurrency import SQLite

public actor KDriveSnapshotSQLiteStore: KDriveSnapshotStoring, KDriveSnapshotStatisticsProviding {
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
