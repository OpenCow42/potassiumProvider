import Foundation
@preconcurrency import SQLite

public enum KDriveConflictResolutionState: String, Codable, Equatable, Sendable {
    case unresolved
    case automaticallyResolved
    case blockedRetryable
    case failed
}

public enum KDriveConflictResolutionKind: String, Codable, Equatable, Sendable {
    case preservedBothAsRenamedConflictCopy
    case blockedBeforeServerMutation
    case retainedStagedUploadAfterFailure
}

public enum KDriveProviderActivityKind: String, Codable, Equatable, Sendable {
    case enumeration
    case changeSync
    case syncAnchor
    case fetchContents
    case metadataLookup
    case create
    case modify
    case trash
    case delete
    case conflict
    case thumbnail
    case runtimeLoading
    case authentication
    case driveDiscovery
    case domainManagement
}

public enum KDriveProviderActivityScope: String, Codable, Equatable, Sendable {
    case domain
    case app
}

public enum KDriveProviderActivityOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
}

public enum KDriveProviderActivitySeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

public enum KDriveProviderActivityErrorCategory: String, Codable, Equatable, Sendable {
    case authentication
    case network
    case api
    case fileProvider
    case listing
    case snapshot
    case storage
    case validation
    case mutationConflict
    case unknown
}

public struct KDriveProviderActivityErrorDiagnostic: Codable, Equatable, Sendable {
    public var errorCategory: KDriveProviderActivityErrorCategory
    public var providerErrorCode: Int?
    public var underlyingErrorDomain: String?
    public var underlyingErrorCode: Int?
    public var recoverySuggestion: String?
    public var diagnosticSummary: String?

    public init(
        errorCategory: KDriveProviderActivityErrorCategory,
        providerErrorCode: Int? = nil,
        underlyingErrorDomain: String? = nil,
        underlyingErrorCode: Int? = nil,
        recoverySuggestion: String? = nil,
        diagnosticSummary: String? = nil
    ) {
        self.errorCategory = errorCategory
        self.providerErrorCode = providerErrorCode
        self.underlyingErrorDomain = underlyingErrorDomain
        self.underlyingErrorCode = underlyingErrorCode
        self.recoverySuggestion = recoverySuggestion
        self.diagnosticSummary = diagnosticSummary
    }
}

public struct KDriveConflictEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var detectedAt: Date
    public var resolvedAt: Date?
    public var domainIdentifier: String
    public var driveID: Int
    public var operation: KDriveProviderActivityKind
    public var originalItemIdentifier: String?
    public var originalItemName: String?
    public var originalItemPath: String?
    public var conflictItemIdentifier: String?
    public var conflictItemName: String?
    public var conflictItemPath: String?
    public var resolutionState: KDriveConflictResolutionState
    public var automaticallyResolved: Bool
    public var resolutionKind: KDriveConflictResolutionKind?
    public var resolutionSummary: String
    public var stagedUploadRelativePath: String?

    public init(
        id: UUID = UUID(),
        detectedAt: Date = Date(),
        resolvedAt: Date? = nil,
        domainIdentifier: String,
        driveID: Int,
        operation: KDriveProviderActivityKind,
        originalItemIdentifier: String?,
        originalItemName: String?,
        originalItemPath: String?,
        conflictItemIdentifier: String? = nil,
        conflictItemName: String? = nil,
        conflictItemPath: String? = nil,
        resolutionState: KDriveConflictResolutionState,
        automaticallyResolved: Bool,
        resolutionKind: KDriveConflictResolutionKind?,
        resolutionSummary: String,
        stagedUploadRelativePath: String? = nil
    ) {
        self.id = id
        self.detectedAt = detectedAt
        self.resolvedAt = resolvedAt
        self.domainIdentifier = domainIdentifier
        self.driveID = driveID
        self.operation = operation
        self.originalItemIdentifier = originalItemIdentifier
        self.originalItemName = originalItemName
        self.originalItemPath = originalItemPath
        self.conflictItemIdentifier = conflictItemIdentifier
        self.conflictItemName = conflictItemName
        self.conflictItemPath = conflictItemPath
        self.resolutionState = resolutionState
        self.automaticallyResolved = automaticallyResolved
        self.resolutionKind = resolutionKind
        self.resolutionSummary = resolutionSummary
        self.stagedUploadRelativePath = stagedUploadRelativePath
    }
}

public struct KDriveProviderActivityEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var domainIdentifier: String
    public var driveID: Int
    public var kind: KDriveProviderActivityKind
    public var scope: KDriveProviderActivityScope
    public var outcome: KDriveProviderActivityOutcome
    public var severity: KDriveProviderActivitySeverity
    public var itemIdentifier: String?
    public var itemName: String?
    public var itemPath: String?
    public var summary: String
    public var relatedConflictID: UUID?
    public var errorCategory: KDriveProviderActivityErrorCategory?
    public var providerErrorCode: Int?
    public var underlyingErrorDomain: String?
    public var underlyingErrorCode: Int?
    public var recoverySuggestion: String?
    public var diagnosticSummary: String?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        domainIdentifier: String,
        driveID: Int,
        kind: KDriveProviderActivityKind,
        scope: KDriveProviderActivityScope = .domain,
        outcome: KDriveProviderActivityOutcome = .success,
        severity: KDriveProviderActivitySeverity = .info,
        itemIdentifier: String?,
        itemName: String?,
        itemPath: String?,
        summary: String,
        relatedConflictID: UUID? = nil,
        diagnostic: KDriveProviderActivityErrorDiagnostic? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.domainIdentifier = domainIdentifier
        self.driveID = driveID
        self.kind = kind
        self.scope = scope
        self.outcome = outcome
        self.severity = severity
        self.itemIdentifier = itemIdentifier
        self.itemName = itemName
        self.itemPath = itemPath
        self.summary = summary
        self.relatedConflictID = relatedConflictID
        self.errorCategory = diagnostic?.errorCategory
        self.providerErrorCode = diagnostic?.providerErrorCode
        self.underlyingErrorDomain = diagnostic?.underlyingErrorDomain
        self.underlyingErrorCode = diagnostic?.underlyingErrorCode
        self.recoverySuggestion = diagnostic?.recoverySuggestion
        self.diagnosticSummary = diagnostic?.diagnosticSummary
    }
}

public protocol KDriveProviderEventStoring: Sendable {
    func saveConflict(_ event: KDriveConflictEvent) async throws
    func recordActivity(_ event: KDriveProviderActivityEvent) async throws
    func recentConflicts(domainIdentifier: String?, limit: Int) async throws -> [KDriveConflictEvent]
    func recentActivity(domainIdentifier: String?, limit: Int) async throws -> [KDriveProviderActivityEvent]
    func recentActivity(domainIdentifier: String?, outcome: KDriveProviderActivityOutcome?, limit: Int) async throws -> [KDriveProviderActivityEvent]
    func removeEvents(domainIdentifier: String) async throws
}

public protocol KDriveProviderEventObserving: Sendable {
    func eventChanges(pollInterval: TimeInterval) async -> AsyncStream<Void>
}

public actor KDriveProviderEventSQLiteStore: KDriveProviderEventStoring, KDriveProviderEventObserving {
    private let database: Connection
    private var eventChangeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var isUpdateHookInstalled = false
    private var lastObservedDataVersion: Int64?
    private var dataVersionPollingTask: Task<Void, Never>?

    public init(databaseURL: URL) throws {
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

    public func saveConflict(_ event: KDriveConflictEvent) throws {
        try database.run(ProviderEventSchema.conflictEvents.insert(or: .replace, Self.setters(for: event)))
    }

    public func recordActivity(_ event: KDriveProviderActivityEvent) throws {
        try database.run(ProviderEventSchema.activityEvents.insert(or: .replace, Self.setters(for: event)))
    }

    public func recentConflicts(domainIdentifier: String?, limit: Int = 100) throws -> [KDriveConflictEvent] {
        let rowLimit = max(0, limit)
        let query: Table
        if let domainIdentifier {
            query = ProviderEventSchema.conflictEvents
                .filter(ProviderEventSchema.domainIdentifier == domainIdentifier)
                .order(ProviderEventSchema.detectedAt.desc)
                .limit(rowLimit)
        } else {
            query = ProviderEventSchema.conflictEvents
                .order(ProviderEventSchema.detectedAt.desc)
                .limit(rowLimit)
        }

        return try database.prepare(query).map(Self.conflictEvent(from:))
    }

    public func recentActivity(domainIdentifier: String?, limit: Int = 100) throws -> [KDriveProviderActivityEvent] {
        try recentActivity(domainIdentifier: domainIdentifier, outcome: nil, limit: limit)
    }

    public func recentActivity(
        domainIdentifier: String?,
        outcome: KDriveProviderActivityOutcome?,
        limit: Int = 100
    ) throws -> [KDriveProviderActivityEvent] {
        let rowLimit = max(0, limit)
        var query = ProviderEventSchema.activityEvents
        if let domainIdentifier {
            query = query.filter(ProviderEventSchema.domainIdentifier == domainIdentifier)
        }
        if let outcome {
            query = query.filter(ProviderEventSchema.outcome == outcome.rawValue)
        }

        return try database.prepare(query.order(ProviderEventSchema.occurredAt.desc).limit(rowLimit))
            .map(Self.activityEvent(from:))
    }

    public func removeEvents(domainIdentifier: String) throws {
        try Self.removeEvents(on: database, domainIdentifier: domainIdentifier)
    }

    public func eventChanges(pollInterval: TimeInterval = 1) async -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            eventChangeContinuations[id] = continuation
            installUpdateHookIfNeeded()
            startDataVersionPollingIfNeeded(pollInterval: pollInterval)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventChangeContinuation(id: id) }
            }
        }
    }

    static func configure(_ database: Connection) throws {
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("PRAGMA busy_timeout=5000")
    }

    static func createTables(on database: Connection) throws {
        try database.run(ProviderEventSchema.conflictEvents.create(ifNotExists: true) { table in
            table.column(ProviderEventSchema.id, primaryKey: true)
            table.column(ProviderEventSchema.detectedAt)
            table.column(ProviderEventSchema.resolvedAt)
            table.column(ProviderEventSchema.domainIdentifier)
            table.column(ProviderEventSchema.driveID)
            table.column(ProviderEventSchema.operation)
            table.column(ProviderEventSchema.originalItemIdentifier)
            table.column(ProviderEventSchema.originalItemName)
            table.column(ProviderEventSchema.originalItemPath)
            table.column(ProviderEventSchema.conflictItemIdentifier)
            table.column(ProviderEventSchema.conflictItemName)
            table.column(ProviderEventSchema.conflictItemPath)
            table.column(ProviderEventSchema.resolutionState)
            table.column(ProviderEventSchema.automaticallyResolved)
            table.column(ProviderEventSchema.resolutionKind)
            table.column(ProviderEventSchema.resolutionSummary)
            table.column(ProviderEventSchema.stagedUploadRelativePath)
        })

        try database.run(ProviderEventSchema.activityEvents.create(ifNotExists: true) { table in
            table.column(ProviderEventSchema.id, primaryKey: true)
            table.column(ProviderEventSchema.occurredAt)
            table.column(ProviderEventSchema.domainIdentifier)
            table.column(ProviderEventSchema.driveID)
            table.column(ProviderEventSchema.kind)
            table.column(ProviderEventSchema.scope)
            table.column(ProviderEventSchema.outcome)
            table.column(ProviderEventSchema.severity)
            table.column(ProviderEventSchema.itemIdentifier)
            table.column(ProviderEventSchema.itemName)
            table.column(ProviderEventSchema.itemPath)
            table.column(ProviderEventSchema.summary)
            table.column(ProviderEventSchema.relatedConflictID)
            table.column(ProviderEventSchema.errorCategory)
            table.column(ProviderEventSchema.providerErrorCode)
            table.column(ProviderEventSchema.underlyingErrorDomain)
            table.column(ProviderEventSchema.underlyingErrorCode)
            table.column(ProviderEventSchema.recoverySuggestion)
            table.column(ProviderEventSchema.diagnosticSummary)
        })
        try migrateActivityEvents(on: database)

        try database.execute("CREATE INDEX IF NOT EXISTS conflict_events_domainIdentifier_idx ON conflict_events(domainIdentifier)")
        try database.execute("CREATE INDEX IF NOT EXISTS conflict_events_detectedAt_idx ON conflict_events(detectedAt)")
        try database.execute("CREATE INDEX IF NOT EXISTS provider_activity_events_domainIdentifier_idx ON provider_activity_events(domainIdentifier)")
        try database.execute("CREATE INDEX IF NOT EXISTS provider_activity_events_occurredAt_idx ON provider_activity_events(occurredAt)")
        try database.execute("CREATE INDEX IF NOT EXISTS provider_activity_events_relatedConflictID_idx ON provider_activity_events(relatedConflictID)")
        try database.execute("CREATE INDEX IF NOT EXISTS provider_activity_events_outcome_idx ON provider_activity_events(outcome)")
    }

    private static func migrateActivityEvents(on database: Connection) throws {
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN scope TEXT NOT NULL DEFAULT 'domain'")
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN outcome TEXT NOT NULL DEFAULT 'success'")
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN severity TEXT NOT NULL DEFAULT 'info'")
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN errorCategory TEXT")
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN providerErrorCode INTEGER")
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN underlyingErrorDomain TEXT")
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN underlyingErrorCode INTEGER")
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN recoverySuggestion TEXT")
        try addActivityColumnIfMissing(on: database, sql: "ALTER TABLE provider_activity_events ADD COLUMN diagnosticSummary TEXT")
    }

    private static func addActivityColumnIfMissing(on database: Connection, sql: String) throws {
        do {
            try database.execute(sql)
        } catch {
            let description = "\(error.localizedDescription) \(String(describing: error))"
            guard description.localizedCaseInsensitiveContains("duplicate column name") else {
                throw error
            }
        }
    }

    static func removeEvents(on database: Connection, domainIdentifier: String) throws {
        try database.transaction {
            try database.run(ProviderEventSchema.activityEvents
                .filter(ProviderEventSchema.domainIdentifier == domainIdentifier)
                .delete()
            )
            try database.run(ProviderEventSchema.conflictEvents
                .filter(ProviderEventSchema.domainIdentifier == domainIdentifier)
                .delete()
            )
        }
    }

    private func installUpdateHookIfNeeded() {
        guard isUpdateHookInstalled == false else { return }

        database.updateHook { [weak self] _, _, table, _ in
            guard ProviderEventSchema.observedTableNames.contains(table) else { return }
            Task { await self?.notifyEventChange() }
        }
        isUpdateHookInstalled = true
    }

    private func startDataVersionPollingIfNeeded(pollInterval: TimeInterval) {
        guard dataVersionPollingTask == nil else { return }

        lastObservedDataVersion = try? Self.dataVersion(on: database)
        let nanoseconds = UInt64(max(0.25, pollInterval) * 1_000_000_000)
        dataVersionPollingTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: nanoseconds)
                await self?.pollDataVersion()
            }
        }
    }

    private func pollDataVersion() {
        guard let dataVersion = try? Self.dataVersion(on: database) else { return }

        if let lastObservedDataVersion, dataVersion != lastObservedDataVersion {
            self.lastObservedDataVersion = dataVersion
            notifyEventChange()
        } else if lastObservedDataVersion == nil {
            lastObservedDataVersion = dataVersion
        }
    }

    private func notifyEventChange() {
        for continuation in eventChangeContinuations.values {
            continuation.yield(())
        }
    }

    private func removeEventChangeContinuation(id: UUID) {
        eventChangeContinuations[id] = nil

        guard eventChangeContinuations.isEmpty else { return }
        database.updateHook(nil)
        isUpdateHookInstalled = false
        dataVersionPollingTask?.cancel()
        dataVersionPollingTask = nil
        lastObservedDataVersion = nil
    }

    private static func dataVersion(on database: Connection) throws -> Int64 {
        try database.scalar("PRAGMA data_version") as? Int64 ?? 0
    }

    private static func setters(for event: KDriveConflictEvent) -> [Setter] {
        [
            ProviderEventSchema.id <- event.id.uuidString,
            ProviderEventSchema.detectedAt <- event.detectedAt.timeIntervalSince1970,
            ProviderEventSchema.resolvedAt <- event.resolvedAt?.timeIntervalSince1970,
            ProviderEventSchema.domainIdentifier <- event.domainIdentifier,
            ProviderEventSchema.driveID <- event.driveID,
            ProviderEventSchema.operation <- event.operation.rawValue,
            ProviderEventSchema.originalItemIdentifier <- event.originalItemIdentifier,
            ProviderEventSchema.originalItemName <- event.originalItemName,
            ProviderEventSchema.originalItemPath <- event.originalItemPath,
            ProviderEventSchema.conflictItemIdentifier <- event.conflictItemIdentifier,
            ProviderEventSchema.conflictItemName <- event.conflictItemName,
            ProviderEventSchema.conflictItemPath <- event.conflictItemPath,
            ProviderEventSchema.resolutionState <- event.resolutionState.rawValue,
            ProviderEventSchema.automaticallyResolved <- event.automaticallyResolved,
            ProviderEventSchema.resolutionKind <- event.resolutionKind?.rawValue,
            ProviderEventSchema.resolutionSummary <- event.resolutionSummary,
            ProviderEventSchema.stagedUploadRelativePath <- event.stagedUploadRelativePath,
        ]
    }

    private static func setters(for event: KDriveProviderActivityEvent) -> [Setter] {
        [
            ProviderEventSchema.id <- event.id.uuidString,
            ProviderEventSchema.occurredAt <- event.occurredAt.timeIntervalSince1970,
            ProviderEventSchema.domainIdentifier <- event.domainIdentifier,
            ProviderEventSchema.driveID <- event.driveID,
            ProviderEventSchema.kind <- event.kind.rawValue,
            ProviderEventSchema.scope <- event.scope.rawValue,
            ProviderEventSchema.outcome <- event.outcome.rawValue,
            ProviderEventSchema.severity <- event.severity.rawValue,
            ProviderEventSchema.itemIdentifier <- event.itemIdentifier,
            ProviderEventSchema.itemName <- event.itemName,
            ProviderEventSchema.itemPath <- event.itemPath,
            ProviderEventSchema.summary <- event.summary,
            ProviderEventSchema.relatedConflictID <- event.relatedConflictID?.uuidString,
            ProviderEventSchema.errorCategory <- event.errorCategory?.rawValue,
            ProviderEventSchema.providerErrorCode <- event.providerErrorCode,
            ProviderEventSchema.underlyingErrorDomain <- event.underlyingErrorDomain,
            ProviderEventSchema.underlyingErrorCode <- event.underlyingErrorCode,
            ProviderEventSchema.recoverySuggestion <- event.recoverySuggestion,
            ProviderEventSchema.diagnosticSummary <- event.diagnosticSummary,
        ]
    }

    private static func conflictEvent(from row: Row) -> KDriveConflictEvent {
        KDriveConflictEvent(
            id: UUID(uuidString: row[ProviderEventSchema.id]) ?? UUID(),
            detectedAt: Date(timeIntervalSince1970: row[ProviderEventSchema.detectedAt]),
            resolvedAt: row[ProviderEventSchema.resolvedAt].map { Date(timeIntervalSince1970: $0) },
            domainIdentifier: row[ProviderEventSchema.domainIdentifier],
            driveID: row[ProviderEventSchema.driveID],
            operation: KDriveProviderActivityKind(rawValue: row[ProviderEventSchema.operation]) ?? .conflict,
            originalItemIdentifier: row[ProviderEventSchema.originalItemIdentifier],
            originalItemName: row[ProviderEventSchema.originalItemName],
            originalItemPath: row[ProviderEventSchema.originalItemPath],
            conflictItemIdentifier: row[ProviderEventSchema.conflictItemIdentifier],
            conflictItemName: row[ProviderEventSchema.conflictItemName],
            conflictItemPath: row[ProviderEventSchema.conflictItemPath],
            resolutionState: KDriveConflictResolutionState(rawValue: row[ProviderEventSchema.resolutionState]) ?? .unresolved,
            automaticallyResolved: row[ProviderEventSchema.automaticallyResolved],
            resolutionKind: row[ProviderEventSchema.resolutionKind].flatMap(KDriveConflictResolutionKind.init(rawValue:)),
            resolutionSummary: row[ProviderEventSchema.resolutionSummary],
            stagedUploadRelativePath: row[ProviderEventSchema.stagedUploadRelativePath]
        )
    }

    private static func activityEvent(from row: Row) -> KDriveProviderActivityEvent {
        KDriveProviderActivityEvent(
            id: UUID(uuidString: row[ProviderEventSchema.id]) ?? UUID(),
            occurredAt: Date(timeIntervalSince1970: row[ProviderEventSchema.occurredAt]),
            domainIdentifier: row[ProviderEventSchema.domainIdentifier],
            driveID: row[ProviderEventSchema.driveID],
            kind: KDriveProviderActivityKind(rawValue: row[ProviderEventSchema.kind]) ?? .conflict,
            scope: KDriveProviderActivityScope(rawValue: row[ProviderEventSchema.scope]) ?? .domain,
            outcome: KDriveProviderActivityOutcome(rawValue: row[ProviderEventSchema.outcome]) ?? .success,
            severity: KDriveProviderActivitySeverity(rawValue: row[ProviderEventSchema.severity]) ?? .info,
            itemIdentifier: row[ProviderEventSchema.itemIdentifier],
            itemName: row[ProviderEventSchema.itemName],
            itemPath: row[ProviderEventSchema.itemPath],
            summary: row[ProviderEventSchema.summary],
            relatedConflictID: row[ProviderEventSchema.relatedConflictID].flatMap(UUID.init(uuidString:)),
            diagnostic: row[ProviderEventSchema.errorCategory].flatMap { category in
                KDriveProviderActivityErrorCategory(rawValue: category).map {
                    KDriveProviderActivityErrorDiagnostic(
                        errorCategory: $0,
                        providerErrorCode: row[ProviderEventSchema.providerErrorCode],
                        underlyingErrorDomain: row[ProviderEventSchema.underlyingErrorDomain],
                        underlyingErrorCode: row[ProviderEventSchema.underlyingErrorCode],
                        recoverySuggestion: row[ProviderEventSchema.recoverySuggestion],
                        diagnosticSummary: row[ProviderEventSchema.diagnosticSummary]
                    )
                }
            }
        )
    }
}

private enum ProviderEventSchema {
    static let conflictEvents = Table("conflict_events")
    static let activityEvents = Table("provider_activity_events")
    static let observedTableNames: Set<String> = ["conflict_events", "provider_activity_events"]

    static let id = Expression<String>("id")
    static let detectedAt = Expression<Double>("detectedAt")
    static let resolvedAt = Expression<Double?>("resolvedAt")
    static let occurredAt = Expression<Double>("occurredAt")
    static let domainIdentifier = Expression<String>("domainIdentifier")
    static let driveID = Expression<Int>("driveID")
    static let operation = Expression<String>("operation")
    static let kind = Expression<String>("kind")
    static let scope = Expression<String>("scope")
    static let outcome = Expression<String>("outcome")
    static let severity = Expression<String>("severity")
    static let originalItemIdentifier = Expression<String?>("originalItemIdentifier")
    static let originalItemName = Expression<String?>("originalItemName")
    static let originalItemPath = Expression<String?>("originalItemPath")
    static let conflictItemIdentifier = Expression<String?>("conflictItemIdentifier")
    static let conflictItemName = Expression<String?>("conflictItemName")
    static let conflictItemPath = Expression<String?>("conflictItemPath")
    static let resolutionState = Expression<String>("resolutionState")
    static let automaticallyResolved = Expression<Bool>("automaticallyResolved")
    static let resolutionKind = Expression<String?>("resolutionKind")
    static let resolutionSummary = Expression<String>("resolutionSummary")
    static let stagedUploadRelativePath = Expression<String?>("stagedUploadRelativePath")
    static let itemIdentifier = Expression<String?>("itemIdentifier")
    static let itemName = Expression<String?>("itemName")
    static let itemPath = Expression<String?>("itemPath")
    static let summary = Expression<String>("summary")
    static let relatedConflictID = Expression<String?>("relatedConflictID")
    static let errorCategory = Expression<String?>("errorCategory")
    static let providerErrorCode = Expression<Int?>("providerErrorCode")
    static let underlyingErrorDomain = Expression<String?>("underlyingErrorDomain")
    static let underlyingErrorCode = Expression<Int?>("underlyingErrorCode")
    static let recoverySuggestion = Expression<String?>("recoverySuggestion")
    static let diagnosticSummary = Expression<String?>("diagnosticSummary")
}
