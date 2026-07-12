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
        try Self.migrateLegacySnapshots(on: database)
        self.database = database
    }

    public init(appGroupIdentifier: String = ProviderConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw KDriveSnapshotStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        try self.init(databaseURL: containerURL.appendingPathComponent("Snapshots.sqlite3"))
    }

    public func snapshot(domainIdentifier: String, containerIdentifier: String) throws -> KDriveSnapshot? {
        guard let state = try activeSnapshotState(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier
        ) else {
            return nil
        }

        let itemRows = try database.prepare(
            GenerationSchema.items
                .filter(
                    GenerationSchema.domainIdentifier == domainIdentifier &&
                    GenerationSchema.containerIdentifier == containerIdentifier &&
                    GenerationSchema.generation == state.generation
                )
                .order(GenerationSchema.position.asc)
        )
        let items = itemRows.map(Self.generationRemoteItem(from:))

        return KDriveSnapshot(
            anchor: state.anchor,
            serverCursor: state.serverCursor,
            isFullyEnumerated: state.isFullyEnumerated,
            usesAdvancedListing: state.usesAdvancedListing,
            items: items
        )
    }

    public func snapshotMetadata(domainIdentifier: String, containerIdentifier: String) async throws -> KDriveSnapshot? {
        try activeSnapshotState(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier
        )?.snapshotMetadata
    }

    public func item(domainIdentifier: String, fileID: Int) throws -> KDriveRemoteItem? {
        for head in try database.prepare(
            GenerationSchema.heads.filter(GenerationSchema.domainIdentifier == domainIdentifier)
        ) {
            let query = GenerationSchema.items.filter(
                GenerationSchema.domainIdentifier == domainIdentifier &&
                GenerationSchema.containerIdentifier == head[GenerationSchema.containerIdentifier] &&
                GenerationSchema.generation == head[GenerationSchema.activeGeneration] &&
                GenerationSchema.itemID == fileID
            ).limit(1)
            if let row = try database.pluck(query) {
                return Self.generationRemoteItem(from: row)
            }
        }
        return nil
    }

    public func save(
        _ snapshot: KDriveSnapshot,
        domainIdentifier: String,
        containerIdentifier: String,
        condition: KDriveSnapshotSaveCondition
    ) throws {
        try database.transaction {
            let currentState = try activeSnapshotState(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier
            )
            guard condition.accepts(currentState?.snapshotMetadata) else {
                throw KDriveSnapshotStoreError.staleSnapshot(
                    domainIdentifier: domainIdentifier,
                    containerIdentifier: containerIdentifier
                )
            }

            let generation = (currentState?.generation ?? 0) + 1
            let committedAt = Date().timeIntervalSince1970
            try database.run(GenerationSchema.generations.insert(
                GenerationSchema.domainIdentifier <- domainIdentifier,
                GenerationSchema.containerIdentifier <- containerIdentifier,
                GenerationSchema.generation <- generation,
                GenerationSchema.anchor <- snapshot.anchor,
                GenerationSchema.serverCursor <- snapshot.serverCursor,
                GenerationSchema.isFullyEnumerated <- snapshot.isFullyEnumerated,
                GenerationSchema.usesAdvancedListing <- snapshot.usesAdvancedListing,
                GenerationSchema.updatedAt <- committedAt
            ))

            for (position, item) in snapshot.items.enumerated() {
                try database.run(GenerationSchema.items.insert(Self.generationSetters(
                    for: item,
                    domainIdentifier: domainIdentifier,
                    containerIdentifier: containerIdentifier,
                    generation: generation,
                    position: position
                )))
            }
            try database.run(GenerationSchema.heads.insert(or: .replace,
                GenerationSchema.domainIdentifier <- domainIdentifier,
                GenerationSchema.containerIdentifier <- containerIdentifier,
                GenerationSchema.activeGeneration <- generation
            ))
            try trimSnapshotGenerations(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier,
                retaining: 3
            )
        }
    }

    public func removeSnapshots(domainIdentifier: String) throws {
        try database.transaction {
            try database.run(GenerationSchema.items.filter(GenerationSchema.domainIdentifier == domainIdentifier).delete())
            try database.run(GenerationSchema.generations.filter(GenerationSchema.domainIdentifier == domainIdentifier).delete())
            try database.run(GenerationSchema.heads.filter(GenerationSchema.domainIdentifier == domainIdentifier).delete())
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

        for head in try database.prepare(GenerationSchema.heads) {
            let domainIdentifier = head[GenerationSchema.domainIdentifier]
            guard var builder = builders[domainIdentifier] else { continue }
            guard let row = try database.pluck(GenerationSchema.generations.filter(
                GenerationSchema.domainIdentifier == domainIdentifier &&
                GenerationSchema.containerIdentifier == head[GenerationSchema.containerIdentifier] &&
                GenerationSchema.generation == head[GenerationSchema.activeGeneration]
            )) else { continue }

            builder.containerCount += 1
            if row[GenerationSchema.isFullyEnumerated] {
                builder.fullyEnumeratedContainerCount += 1
            }
            if row[GenerationSchema.usesAdvancedListing] {
                builder.advancedListingContainerCount += 1
            }

            let updatedAt = Date(timeIntervalSince1970: row[GenerationSchema.updatedAt])
            if builder.lastUpdatedAt.map({ updatedAt > $0 }) ?? true {
                builder.lastUpdatedAt = updatedAt
            }
            builders[domainIdentifier] = builder
        }

        for head in try database.prepare(GenerationSchema.heads) {
            let domainIdentifier = head[GenerationSchema.domainIdentifier]
            guard var builder = builders[domainIdentifier] else { continue }
            let count = try database.scalar(
                GenerationSchema.items
                    .filter(
                        GenerationSchema.domainIdentifier == domainIdentifier &&
                        GenerationSchema.containerIdentifier == head[GenerationSchema.containerIdentifier] &&
                        GenerationSchema.generation == head[GenerationSchema.activeGeneration]
                    ).count
            )
            builder.itemCount += count
            builders[domainIdentifier] = builder
        }

        return requestedDomainIdentifiers
            .sorted()
            .compactMap { builders[$0]?.statistics }
    }

    public func snapshotPage(
        domainIdentifier: String,
        containerIdentifier: String,
        after token: String?,
        limit: Int
    ) async throws -> KDriveSnapshotItemPage? {
        let pageSize = max(1, limit)
        let generation: Int64
        let lastPosition: Int

        if let token {
            let decoded = try SnapshotPageToken.decode(token)
            guard decoded.kind == .items,
                  decoded.domainIdentifier == domainIdentifier,
                  decoded.containerIdentifier == containerIdentifier,
                  decoded.sourceGeneration == nil,
                  decoded.phase == nil,
                  decoded.lastItemID == nil,
                  let decodedPosition = decoded.lastPosition else {
                throw KDriveSnapshotStoreError.invalidPageToken
            }
            generation = decoded.targetGeneration
            lastPosition = decodedPosition
        } else {
            guard let state = try activeSnapshotState(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier
            ), state.isFullyEnumerated else {
                return nil
            }
            generation = state.generation
            lastPosition = -1
        }

        guard let pageState = try generationState(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier,
            generation: generation
        ), pageState.isFullyEnumerated else {
            throw KDriveSnapshotStoreError.expiredGeneration(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier
            )
        }

        let rows = Array(try database.prepare(
            GenerationSchema.items
                .filter(
                    GenerationSchema.domainIdentifier == domainIdentifier &&
                    GenerationSchema.containerIdentifier == containerIdentifier &&
                    GenerationSchema.generation == generation &&
                    GenerationSchema.position > lastPosition
                )
                .order(GenerationSchema.position.asc)
                .limit(pageSize + 1)
        ))
        let pageRows = rows.prefix(pageSize)
        let items = pageRows.map(Self.generationRemoteItem(from:))
        let nextToken: String?
        if rows.count > pageSize, let finalRow = pageRows.last {
            nextToken = try SnapshotPageToken(
                kind: .items,
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier,
                sourceGeneration: nil,
                targetGeneration: generation,
                phase: nil,
                lastItemID: nil,
                lastPosition: finalRow[GenerationSchema.position]
            ).encoded()
        } else {
            nextToken = nil
        }
        return KDriveSnapshotItemPage(items: items, nextToken: nextToken, generation: generation)
    }

    public func snapshotChangePage(
        domainIdentifier: String,
        containerIdentifier: String,
        from anchor: String,
        after token: String?,
        limit: Int
    ) async throws -> KDriveSnapshotChangePage? {
        let pageSize = max(1, limit)
        let sourceGeneration: Int64
        let targetGeneration: Int64
        var phase: SnapshotPageToken.Phase
        var lastItemID: Int

        if let token {
            let decoded = try SnapshotPageToken.decode(token)
            guard decoded.kind == .changes,
                  decoded.domainIdentifier == domainIdentifier,
                  decoded.containerIdentifier == containerIdentifier,
                  let decodedSource = decoded.sourceGeneration,
                  let decodedPhase = decoded.phase,
                  let decodedLastItemID = decoded.lastItemID,
                  decoded.lastPosition == nil else {
                throw KDriveSnapshotStoreError.invalidPageToken
            }
            sourceGeneration = decodedSource
            targetGeneration = decoded.targetGeneration
            phase = decodedPhase
            lastItemID = decodedLastItemID
        } else {
            guard let target = try activeSnapshotState(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier
            ) else {
                return nil
            }
            if target.anchor == anchor {
                return KDriveSnapshotChangePage(
                    changes: KDriveSnapshotChangeSet(updatedItems: [], deletedItemIDs: []),
                    nextToken: nil,
                    targetAnchor: target.anchor
                )
            }
            guard let source = try generationState(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier,
                anchor: anchor
            ) else {
                throw KDriveSnapshotStoreError.expiredGeneration(
                    domainIdentifier: domainIdentifier,
                    containerIdentifier: containerIdentifier
                )
            }
            sourceGeneration = source.generation
            targetGeneration = target.generation
            phase = .updates
            lastItemID = Int.min
        }

        guard try generationExists(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier,
            generation: sourceGeneration
        ), try generationExists(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier,
            generation: targetGeneration
        ), let target = try generationState(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier,
            generation: targetGeneration
        ) else {
            throw KDriveSnapshotStoreError.expiredGeneration(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier
            )
        }

        var updates: [KDriveRemoteItem] = []
        var deletions: [Int] = []
        var nextToken: String?

        if phase == .updates {
            let scan = try scanUpdatedItems(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier,
                sourceGeneration: sourceGeneration,
                targetGeneration: targetGeneration,
                after: lastItemID,
                limit: pageSize
            )
            updates = scan.values
            if scan.hasMore {
                nextToken = try changeToken(
                    domainIdentifier: domainIdentifier,
                    containerIdentifier: containerIdentifier,
                    sourceGeneration: sourceGeneration,
                    targetGeneration: targetGeneration,
                    phase: .updates,
                    lastItemID: scan.lastScannedID
                )
            } else {
                phase = .deletions
                lastItemID = Int.min
                if updates.count == pageSize {
                    nextToken = try changeToken(
                        domainIdentifier: domainIdentifier,
                        containerIdentifier: containerIdentifier,
                        sourceGeneration: sourceGeneration,
                        targetGeneration: targetGeneration,
                        phase: .deletions,
                        lastItemID: Int.min
                    )
                }
            }
        }

        if nextToken == nil, phase == .deletions, updates.count < pageSize {
            let scan = try scanDeletedItemIDs(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier,
                sourceGeneration: sourceGeneration,
                targetGeneration: targetGeneration,
                after: lastItemID,
                limit: pageSize - updates.count
            )
            deletions = scan.values
            if scan.hasMore {
                nextToken = try changeToken(
                    domainIdentifier: domainIdentifier,
                    containerIdentifier: containerIdentifier,
                    sourceGeneration: sourceGeneration,
                    targetGeneration: targetGeneration,
                    phase: .deletions,
                    lastItemID: scan.lastScannedID
                )
            }
        }

        return KDriveSnapshotChangePage(
            changes: KDriveSnapshotChangeSet(updatedItems: updates, deletedItemIDs: deletions),
            nextToken: nextToken,
            targetAnchor: target.anchor
        )
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
        let generationFilter = GenerationSchema.domainIdentifier == domainIdentifier &&
            GenerationSchema.containerIdentifier == containerIdentifier
        try database.run(GenerationSchema.items.filter(generationFilter).delete())
        try database.run(GenerationSchema.generations.filter(generationFilter).delete())
        try database.run(GenerationSchema.heads.filter(generationFilter).delete())

        let legacyFilter = Schema.domainIdentifier == domainIdentifier && Schema.containerIdentifier == containerIdentifier
        try database.run(Schema.snapshotItems.filter(legacyFilter).delete())
        try database.run(Schema.containerSnapshots.filter(legacyFilter).delete())
    }

    private func activeSnapshotState(
        domainIdentifier: String,
        containerIdentifier: String
    ) throws -> SnapshotGenerationState? {
        guard let head = try database.pluck(GenerationSchema.heads.filter(
            GenerationSchema.domainIdentifier == domainIdentifier &&
            GenerationSchema.containerIdentifier == containerIdentifier
        )) else { return nil }
        return try generationState(
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier,
            generation: head[GenerationSchema.activeGeneration]
        )
    }

    private func generationState(
        domainIdentifier: String,
        containerIdentifier: String,
        generation: Int64
    ) throws -> SnapshotGenerationState? {
        guard let row = try database.pluck(GenerationSchema.generations.filter(
            GenerationSchema.domainIdentifier == domainIdentifier &&
            GenerationSchema.containerIdentifier == containerIdentifier &&
            GenerationSchema.generation == generation
        )) else { return nil }
        return Self.generationState(from: row)
    }

    private func generationState(
        domainIdentifier: String,
        containerIdentifier: String,
        anchor: String
    ) throws -> SnapshotGenerationState? {
        guard let row = try database.pluck(
            GenerationSchema.generations
                .filter(
                    GenerationSchema.domainIdentifier == domainIdentifier &&
                    GenerationSchema.containerIdentifier == containerIdentifier &&
                    GenerationSchema.anchor == anchor
                )
                .order(GenerationSchema.generation.desc)
                .limit(1)
        ) else { return nil }
        return Self.generationState(from: row)
    }

    private func generationExists(
        domainIdentifier: String,
        containerIdentifier: String,
        generation: Int64
    ) throws -> Bool {
        try database.pluck(GenerationSchema.generations.filter(
            GenerationSchema.domainIdentifier == domainIdentifier &&
            GenerationSchema.containerIdentifier == containerIdentifier &&
            GenerationSchema.generation == generation
        ).limit(1)) != nil
    }

    private func trimSnapshotGenerations(
        domainIdentifier: String,
        containerIdentifier: String,
        retaining count: Int
    ) throws {
        let staleRows = try database.prepare(
            GenerationSchema.generations
                .filter(
                    GenerationSchema.domainIdentifier == domainIdentifier &&
                    GenerationSchema.containerIdentifier == containerIdentifier
                )
                .order(GenerationSchema.generation.desc)
                .limit(-1, offset: count)
        )
        for row in staleRows {
            let generation = row[GenerationSchema.generation]
            let filter = GenerationSchema.domainIdentifier == domainIdentifier &&
                GenerationSchema.containerIdentifier == containerIdentifier &&
                GenerationSchema.generation == generation
            try database.run(GenerationSchema.items.filter(filter).delete())
            try database.run(GenerationSchema.generations.filter(filter).delete())
        }
    }

    private func scanUpdatedItems(
        domainIdentifier: String,
        containerIdentifier: String,
        sourceGeneration: Int64,
        targetGeneration: Int64,
        after initialItemID: Int,
        limit: Int
    ) throws -> SnapshotChangeScan<KDriveRemoteItem> {
        var values: [KDriveRemoteItem] = []
        var cursor = initialItemID
        let batchSize = max(64, min(512, limit * 4))

        while values.count < limit {
            let rows = Array(try database.prepare(
                GenerationSchema.items
                    .filter(
                        GenerationSchema.domainIdentifier == domainIdentifier &&
                        GenerationSchema.containerIdentifier == containerIdentifier &&
                        GenerationSchema.generation == targetGeneration &&
                        GenerationSchema.itemID > cursor
                    )
                    .order(GenerationSchema.itemID.asc)
                    .limit(batchSize)
            ))
            guard rows.isEmpty == false else {
                return SnapshotChangeScan(values: values, lastScannedID: cursor, hasMore: false)
            }
            for row in rows {
                cursor = row[GenerationSchema.itemID]
                let targetItem = Self.generationRemoteItem(from: row)
                let sourceRow = try database.pluck(GenerationSchema.items.filter(
                    GenerationSchema.domainIdentifier == domainIdentifier &&
                    GenerationSchema.containerIdentifier == containerIdentifier &&
                    GenerationSchema.generation == sourceGeneration &&
                    GenerationSchema.itemID == targetItem.id
                ).limit(1))
                if sourceRow.map(Self.generationRemoteItem(from:)) != targetItem {
                    values.append(targetItem)
                    if values.count == limit {
                        return SnapshotChangeScan(values: values, lastScannedID: cursor, hasMore: true)
                    }
                }
            }
            if rows.count < batchSize {
                return SnapshotChangeScan(values: values, lastScannedID: cursor, hasMore: false)
            }
        }
        return SnapshotChangeScan(values: values, lastScannedID: cursor, hasMore: true)
    }

    private func scanDeletedItemIDs(
        domainIdentifier: String,
        containerIdentifier: String,
        sourceGeneration: Int64,
        targetGeneration: Int64,
        after initialItemID: Int,
        limit: Int
    ) throws -> SnapshotChangeScan<Int> {
        var values: [Int] = []
        var cursor = initialItemID
        let batchSize = max(64, min(512, limit * 4))

        while values.count < limit {
            let rows = Array(try database.prepare(
                GenerationSchema.items
                    .filter(
                        GenerationSchema.domainIdentifier == domainIdentifier &&
                        GenerationSchema.containerIdentifier == containerIdentifier &&
                        GenerationSchema.generation == sourceGeneration &&
                        GenerationSchema.itemID > cursor
                    )
                    .order(GenerationSchema.itemID.asc)
                    .limit(batchSize)
            ))
            guard rows.isEmpty == false else {
                return SnapshotChangeScan(values: values, lastScannedID: cursor, hasMore: false)
            }
            for row in rows {
                cursor = row[GenerationSchema.itemID]
                let targetRow = try database.pluck(GenerationSchema.items.filter(
                    GenerationSchema.domainIdentifier == domainIdentifier &&
                    GenerationSchema.containerIdentifier == containerIdentifier &&
                    GenerationSchema.generation == targetGeneration &&
                    GenerationSchema.itemID == cursor
                ).limit(1))
                if targetRow == nil {
                    values.append(cursor)
                    if values.count == limit {
                        return SnapshotChangeScan(values: values, lastScannedID: cursor, hasMore: true)
                    }
                }
            }
            if rows.count < batchSize {
                return SnapshotChangeScan(values: values, lastScannedID: cursor, hasMore: false)
            }
        }
        return SnapshotChangeScan(values: values, lastScannedID: cursor, hasMore: true)
    }

    private func changeToken(
        domainIdentifier: String,
        containerIdentifier: String,
        sourceGeneration: Int64,
        targetGeneration: Int64,
        phase: SnapshotPageToken.Phase,
        lastItemID: Int
    ) throws -> String {
        try SnapshotPageToken(
            kind: .changes,
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier,
            sourceGeneration: sourceGeneration,
            targetGeneration: targetGeneration,
            phase: phase,
            lastItemID: lastItemID,
            lastPosition: nil
        ).encoded()
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

        try database.run(GenerationSchema.heads.create(ifNotExists: true) { table in
            table.column(GenerationSchema.domainIdentifier)
            table.column(GenerationSchema.containerIdentifier)
            table.column(GenerationSchema.activeGeneration)
            table.primaryKey(GenerationSchema.domainIdentifier, GenerationSchema.containerIdentifier)
        })

        try database.run(GenerationSchema.generations.create(ifNotExists: true) { table in
            table.column(GenerationSchema.domainIdentifier)
            table.column(GenerationSchema.containerIdentifier)
            table.column(GenerationSchema.generation)
            table.column(GenerationSchema.anchor)
            table.column(GenerationSchema.serverCursor)
            table.column(GenerationSchema.isFullyEnumerated)
            table.column(GenerationSchema.usesAdvancedListing)
            table.column(GenerationSchema.updatedAt)
            table.primaryKey(
                GenerationSchema.domainIdentifier,
                GenerationSchema.containerIdentifier,
                GenerationSchema.generation
            )
        })

        try database.run(GenerationSchema.items.create(ifNotExists: true) { table in
            table.column(GenerationSchema.domainIdentifier)
            table.column(GenerationSchema.containerIdentifier)
            table.column(GenerationSchema.generation)
            table.column(GenerationSchema.position)
            table.column(GenerationSchema.itemID)
            table.column(GenerationSchema.name)
            table.column(GenerationSchema.type)
            table.column(GenerationSchema.status)
            table.column(GenerationSchema.driveID)
            table.column(GenerationSchema.parentID)
            table.column(GenerationSchema.path)
            table.column(GenerationSchema.size)
            table.column(GenerationSchema.mimeType)
            table.column(GenerationSchema.createdAt)
            table.column(GenerationSchema.modifiedAt)
            table.column(GenerationSchema.itemUpdatedAt)
            table.primaryKey(
                GenerationSchema.domainIdentifier,
                GenerationSchema.containerIdentifier,
                GenerationSchema.generation,
                GenerationSchema.itemID
            )
        })
        try database.execute("""
            CREATE INDEX IF NOT EXISTS snapshot_generations_anchor_idx
            ON snapshot_generations(domainIdentifier, containerIdentifier, anchor)
            """)
        try database.execute("""
            CREATE INDEX IF NOT EXISTS snapshot_generation_items_position_idx
            ON snapshot_generation_items(domainIdentifier, containerIdentifier, generation, position)
            """)

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

    private static func migrateLegacySnapshots(on database: Connection) throws {
        try database.transaction {
            let legacySnapshots = Array(try database.prepare(Schema.containerSnapshots))
            for snapshotRow in legacySnapshots {
                let domainIdentifier = snapshotRow[Schema.domainIdentifier]
                let containerIdentifier = snapshotRow[Schema.containerIdentifier]
                let existingHead = try database.pluck(GenerationSchema.heads.filter(
                    GenerationSchema.domainIdentifier == domainIdentifier &&
                    GenerationSchema.containerIdentifier == containerIdentifier
                ))
                guard existingHead == nil else { continue }

                let generation: Int64 = 1
                try database.run(GenerationSchema.generations.insert(
                    GenerationSchema.domainIdentifier <- domainIdentifier,
                    GenerationSchema.containerIdentifier <- containerIdentifier,
                    GenerationSchema.generation <- generation,
                    GenerationSchema.anchor <- snapshotRow[Schema.anchor],
                    GenerationSchema.serverCursor <- snapshotRow[Schema.serverCursor],
                    GenerationSchema.isFullyEnumerated <- snapshotRow[Schema.isFullyEnumerated],
                    GenerationSchema.usesAdvancedListing <- snapshotRow[Schema.usesAdvancedListing],
                    GenerationSchema.updatedAt <- snapshotRow[Schema.updatedAt]
                ))
                for itemRow in try database.prepare(
                    Schema.snapshotItems
                        .filter(
                            Schema.domainIdentifier == domainIdentifier &&
                            Schema.containerIdentifier == containerIdentifier
                        )
                        .order(Schema.position.asc)
                ) {
                    try database.run(GenerationSchema.items.insert(generationSetters(
                        for: remoteItem(from: itemRow),
                        domainIdentifier: domainIdentifier,
                        containerIdentifier: containerIdentifier,
                        generation: generation,
                        position: itemRow[Schema.position]
                    )))
                }
                try database.run(GenerationSchema.heads.insert(
                    GenerationSchema.domainIdentifier <- domainIdentifier,
                    GenerationSchema.containerIdentifier <- containerIdentifier,
                    GenerationSchema.activeGeneration <- generation
                ))
                try database.run(
                    Schema.snapshotItems.filter(
                        Schema.domainIdentifier == domainIdentifier &&
                        Schema.containerIdentifier == containerIdentifier
                    ).delete()
                )
                try database.run(
                    Schema.containerSnapshots.filter(
                        Schema.domainIdentifier == domainIdentifier &&
                        Schema.containerIdentifier == containerIdentifier
                    ).delete()
                )
            }
        }
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

    private static func generationSetters(
        for item: KDriveRemoteItem,
        domainIdentifier: String,
        containerIdentifier: String,
        generation: Int64,
        position: Int
    ) -> [Setter] {
        [
            GenerationSchema.domainIdentifier <- domainIdentifier,
            GenerationSchema.containerIdentifier <- containerIdentifier,
            GenerationSchema.generation <- generation,
            GenerationSchema.position <- position,
            GenerationSchema.itemID <- item.id,
            GenerationSchema.name <- item.name,
            GenerationSchema.type <- item.type,
            GenerationSchema.status <- item.status,
            GenerationSchema.driveID <- item.driveID,
            GenerationSchema.parentID <- item.parentID,
            GenerationSchema.path <- item.path,
            GenerationSchema.size <- item.size,
            GenerationSchema.mimeType <- item.mimeType,
            GenerationSchema.createdAt <- item.createdAt?.timeIntervalSince1970,
            GenerationSchema.modifiedAt <- item.modifiedAt.timeIntervalSince1970,
            GenerationSchema.itemUpdatedAt <- item.updatedAt.timeIntervalSince1970,
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

    private static func generationRemoteItem(from row: Row) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: row[GenerationSchema.itemID],
            name: row[GenerationSchema.name],
            type: row[GenerationSchema.type],
            status: row[GenerationSchema.status],
            driveID: row[GenerationSchema.driveID],
            parentID: row[GenerationSchema.parentID],
            path: row[GenerationSchema.path],
            size: row[GenerationSchema.size],
            mimeType: row[GenerationSchema.mimeType],
            createdAt: row[GenerationSchema.createdAt].map { Date(timeIntervalSince1970: $0) },
            modifiedAt: Date(timeIntervalSince1970: row[GenerationSchema.modifiedAt]),
            updatedAt: Date(timeIntervalSince1970: row[GenerationSchema.itemUpdatedAt])
        )
    }

    private static func generationState(from row: Row) -> SnapshotGenerationState {
        SnapshotGenerationState(
            generation: row[GenerationSchema.generation],
            anchor: row[GenerationSchema.anchor],
            serverCursor: row[GenerationSchema.serverCursor],
            isFullyEnumerated: row[GenerationSchema.isFullyEnumerated],
            usesAdvancedListing: row[GenerationSchema.usesAdvancedListing],
            updatedAt: row[GenerationSchema.updatedAt]
        )
    }
}

private struct SnapshotGenerationState {
    let generation: Int64
    let anchor: String
    let serverCursor: String?
    let isFullyEnumerated: Bool
    let usesAdvancedListing: Bool
    let updatedAt: Double

    var snapshotMetadata: KDriveSnapshot {
        KDriveSnapshot(
            anchor: anchor,
            serverCursor: serverCursor,
            isFullyEnumerated: isFullyEnumerated,
            usesAdvancedListing: usesAdvancedListing,
            items: []
        )
    }
}

private struct SnapshotChangeScan<Value> {
    let values: [Value]
    let lastScannedID: Int
    let hasMore: Bool
}

private struct SnapshotPageToken: Codable {
    enum Kind: String, Codable {
        case items
        case changes
    }

    enum Phase: String, Codable {
        case updates
        case deletions
    }

    let kind: Kind
    let domainIdentifier: String
    let containerIdentifier: String
    let sourceGeneration: Int64?
    let targetGeneration: Int64
    let phase: Phase?
    let lastItemID: Int?
    let lastPosition: Int?

    func encoded() throws -> String {
        KDriveSnapshotPagingToken.prefix + (try JSONEncoder().encode(self)).base64EncodedString()
    }

    static func decode(_ value: String) throws -> SnapshotPageToken {
        guard value.hasPrefix(KDriveSnapshotPagingToken.prefix),
              let data = Data(base64Encoded: String(value.dropFirst(KDriveSnapshotPagingToken.prefix.count))) else {
            throw KDriveSnapshotStoreError.invalidPageToken
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw KDriveSnapshotStoreError.invalidPageToken
        }
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

private enum GenerationSchema {
    static let heads = Table("snapshot_heads")
    static let generations = Table("snapshot_generations")
    static let items = Table("snapshot_generation_items")

    static let domainIdentifier = Expression<String>("domainIdentifier")
    static let containerIdentifier = Expression<String>("containerIdentifier")
    static let activeGeneration = Expression<Int64>("activeGeneration")
    static let generation = Expression<Int64>("generation")
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
