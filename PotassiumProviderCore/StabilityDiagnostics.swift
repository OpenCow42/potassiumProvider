import CryptoKit
import Darwin
import Foundation

public enum ProviderRuntimeProfile: String, Codable, Equatable, Sendable {
    case standard
    case stability

    public static var current: ProviderRuntimeProfile {
        #if STABILITY
        .stability
        #else
        .standard
        #endif
    }
}

public enum ProviderDiagnosticSource: String, Codable, Equatable, Sendable {
    case app
    case fileProviderExtension
    case actionExtension
    case finderRunner
}

public enum ProviderDiagnosticOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case runtimeLoad
    case runtimeInitialize
    case runtimeInvalidate
    case enumeratorInitialize
    case enumeratorInvalidate
    case itemLookup
    case enumerateItems
    case enumerateChanges
    case currentSyncAnchor
    case fetchContents
    case createItem
    case modifyItem
    case deleteItem
    case materializedItemsChanged
    case thumbnail
    case listDrives
    case listDirectory
    case listAdvancedDirectory
    case listTrash
    case listWorkingSetRelevantItems
    case listPartialActivities
    case downloadFile
    case uploadFile
    case replaceFile
    case createDirectory
    case renameItem
    case moveItem
    case updateModificationDate
    case trashItem
    case deleteTrashedItem
    case favoriteItem
    case duplicateItem
    case trashedItem
    case existingFileIDs
    case restoreTrashedItem
    case shareLink
    case createShareLink
    case updateShareLink
    case deleteShareLink
    case fileVersions
    case restoreFileVersion
    case workingSetRefresh
    case knownFolderLocations
    case labPreflight
    case labProvision
    case labReset
    case finderScenario
}

public enum ProviderDiagnosticPhase: String, Codable, Equatable, Sendable {
    case started
    case progress
    case completed
    case failed
    case cancelled
    case checkpoint
}

public enum ProviderDiagnosticField: String, Codable, CaseIterable, Equatable, Sendable {
    case contents
    case filename
    case parent
    case contentModificationDate
    case creationDate
    case extendedAttributes
    case favoriteRank
    case fileSystemFlags
    case lastUsedDate
    case tagData
    case trash
    case typeAndCreator
}

public enum ProviderDiagnosticRouteTemplate: String, Codable, CaseIterable, Equatable, Sendable {
    case driveDiscovery = "GET /2/drive/init"
    case item = "GET /3/drive/{drive_id}/files/{file_id}"
    case listDirectory = "GET /3/drive/{drive_id}/files/{file_id}/files"
    case listAdvancedDirectory = "GET /3/drive/{drive_id}/files/{file_id}/listing"
    case continueAdvancedDirectory = "GET /3/drive/{drive_id}/files/{file_id}/listing/continue"
    case partialActivities = "POST /3/drive/{drive_id}/files/listing/partial"
    case trash = "GET /3/drive/{drive_id}/trash"
    case download = "GET /2/drive/{drive_id}/files/{file_id}/download"
    case thumbnail = "GET /2/drive/{drive_id}/files/{file_id}/thumbnail"
    case upload = "POST /3/drive/{drive_id}/upload"
    case createDirectory = "POST /3/drive/{drive_id}/files/{file_id}/directory"
    case rename = "POST /2/drive/{drive_id}/files/{file_id}/rename"
    case move = "POST /3/drive/{drive_id}/files/{file_id}/move/{destination_id}"
    case trashItem = "DELETE /2/drive/{drive_id}/files/{file_id}"
    case deleteTrashedItem = "DELETE /2/drive/{drive_id}/trash/{file_id}"
    case favorite = "POST /2/drive/{drive_id}/files/{file_id}/favorite"
    case duplicate = "POST /3/drive/{drive_id}/files/{file_id}/duplicate"
    case trashedItem = "GET /2/drive/{drive_id}/trash/{file_id}"
    case existingFileIDs = "POST /2/drive/{drive_id}/files/existence"
    case restoreTrash = "POST /2/drive/{drive_id}/trash/{file_id}/restore"
    case shareLink = "/2/drive/{drive_id}/files/{file_id}/link"
    case versions = "GET /3/drive/{drive_id}/files/{file_id}/versions"
    case restoreVersion = "POST /3/drive/{drive_id}/files/{file_id}/versions/{version_id}/restore/{destination_id}"
}

public enum ProviderDiagnosticOption: String, Codable, CaseIterable, Equatable, Sendable {
    case paginationCursor
    case pageLimit
    case orderByName
    case orderByTypeThenName
    case includeETag
    case includeCapabilities
    case conditionalETag
    case stableFileID
    case clientToken
    case contentHash
    case conflictError
    case conflictRename
    case conflictVersion
    case destinationParent
    case optionalName
    case lastModifiedAt
    case cancellableTransfer
    case thumbnailDimensions
    case activityBatch
    case shareConfiguration
    case versionPagination
}

public enum ProviderDiagnosticStatusClass: String, Codable, Equatable, Sendable {
    case informational
    case success
    case redirection
    case clientError
    case serverError
    case transportError

    public init(httpStatusCode: Int) {
        switch httpStatusCode {
        case 100..<200: self = .informational
        case 200..<300: self = .success
        case 300..<400: self = .redirection
        case 400..<500: self = .clientError
        default: self = .serverError
        }
    }
}

public enum ProviderDiagnosticErrorClass: String, Codable, Equatable, Sendable {
    case concurrentSnapshot
    case authentication
    case cancellation
    case conflict
    case invalidCursor
    case network
    case notFound
    case permission
    case quota
    case server
    case storage
    case synchronization
    case validation
    case unknown
}

/// A value-only diagnostic record. Every textual field is a closed enum so a
/// caller cannot accidentally persist a token, URL, item name, path, body, or
/// account identifier.
public struct ProviderDiagnosticEvent: Codable, Equatable, Sendable {
    public static let schemaVersion = 3

    public let schemaVersion: Int
    public let id: UUID
    public let occurredAt: Date
    public let spanID: UUID?
    public let parentSpanID: UUID?
    public let subjectAlias: UUID?
    public let itemMetadataAlias: UUID?
    public let processInstanceID: UUID?
    public let processCodeHash: String?
    public let errorCode: Int?
    public let validationFields: [ProviderDiagnosticValidationField]?
    public let correlationID: UUID
    public let source: ProviderDiagnosticSource
    public let operation: ProviderDiagnosticOperation
    public let phase: ProviderDiagnosticPhase
    public let fieldShape: [ProviderDiagnosticField]
    public let routeTemplate: ProviderDiagnosticRouteTemplate?
    public let optionShape: [ProviderDiagnosticOption]
    public let statusClass: ProviderDiagnosticStatusClass?
    public let errorClass: ProviderDiagnosticErrorClass?
    public let durationMilliseconds: Int?
    public let progressPercentBucket: Int?
    public let hasCursor: Bool?
    public let hasMore: Bool?
    public let hasAnchor: Bool?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        spanID: UUID? = nil,
        parentSpanID: UUID? = nil,
        subjectAlias: UUID? = nil,
        itemMetadataAlias: UUID? = nil,
        processInstanceID: UUID? = nil,
        processCodeHash: String? = nil,
        errorCode: Int? = nil,
        validationFields: [ProviderDiagnosticValidationField]? = nil,
        correlationID: UUID,
        source: ProviderDiagnosticSource,
        operation: ProviderDiagnosticOperation,
        phase: ProviderDiagnosticPhase,
        fieldShape: [ProviderDiagnosticField] = [],
        routeTemplate: ProviderDiagnosticRouteTemplate? = nil,
        optionShape: [ProviderDiagnosticOption] = [],
        statusClass: ProviderDiagnosticStatusClass? = nil,
        errorClass: ProviderDiagnosticErrorClass? = nil,
        durationMilliseconds: Int? = nil,
        progressPercentBucket: Int? = nil,
        hasCursor: Bool? = nil,
        hasMore: Bool? = nil,
        hasAnchor: Bool? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.occurredAt = occurredAt
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.subjectAlias = subjectAlias
        self.itemMetadataAlias = itemMetadataAlias
        self.processInstanceID = processInstanceID
        self.processCodeHash = processCodeHash.flatMap { value in
            value.count == 40 && value.allSatisfy(\.isHexDigit) ? value.lowercased() : nil
        }
        self.errorCode = errorCode
        self.validationFields = validationFields
        self.correlationID = correlationID
        self.source = source
        self.operation = operation
        self.phase = phase
        self.fieldShape = Array(Set(fieldShape)).sorted { $0.rawValue < $1.rawValue }
        self.routeTemplate = routeTemplate
        self.optionShape = Array(Set(optionShape)).sorted { $0.rawValue < $1.rawValue }
        self.statusClass = statusClass
        self.errorClass = errorClass
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.progressPercentBucket = progressPercentBucket.map { min(100, max(0, $0)) }
        self.hasCursor = hasCursor
        self.hasMore = hasMore
        self.hasAnchor = hasAnchor
    }
}

public protocol ProviderDiagnosticRecording: Sendable {
    func recordDiagnostic(_ event: ProviderDiagnosticEvent) async throws
}

public struct StabilityRunManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let runID: UUID
    public let startedAt: Date
    public let buildRevision: String?

    public init(runID: UUID, startedAt: Date = Date(), buildRevision: String?) {
        self.schemaVersion = Self.schemaVersion
        self.runID = runID
        self.startedAt = startedAt
        self.buildRevision = Self.safeRevision(buildRevision)
    }

    private static func safeRevision(_ revision: String?) -> String? {
        guard let revision else { return nil }
        let safe = revision.lowercased().filter { $0.isHexDigit || $0 == "-" }.prefix(64)
        return safe.isEmpty ? nil : String(safe)
    }
}

public struct StabilityRunSummary: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let finishedAt: Date
    public let assertionCount: Int
    public let failedAssertionCount: Int
    public let checkpointCount: Int

    public init(
        finishedAt: Date = Date(),
        assertionCount: Int,
        failedAssertionCount: Int,
        checkpointCount: Int
    ) {
        self.schemaVersion = Self.schemaVersion
        self.finishedAt = finishedAt
        self.assertionCount = max(0, assertionCount)
        self.failedAssertionCount = max(0, failedAssertionCount)
        self.checkpointCount = max(0, checkpointCount)
    }
}

public struct StabilityRunHandle: Codable, Equatable, Sendable {
    public let runID: UUID
    public let directoryURL: URL

    public var manifestURL: URL { directoryURL.appendingPathComponent("run.json") }
    public var eventsURL: URL { directoryURL.appendingPathComponent("events.jsonl") }
    public var observationsURL: URL { directoryURL.appendingPathComponent("api-observations.jsonl") }
    public var assertionsURL: URL { directoryURL.appendingPathComponent("assertions.jsonl") }
    public var finderReportURL: URL { directoryURL.appendingPathComponent("finder-report.json") }
    public var finderAbandonedURL: URL { directoryURL.appendingPathComponent("finder-abandoned.json") }
    fileprivate var finderOwnerURL: URL { directoryURL.appendingPathComponent("finder-owner.json") }
    fileprivate var finderStepURL: URL { directoryURL.appendingPathComponent("finder-step.json") }
    public var summaryURL: URL { directoryURL.appendingPathComponent("summary.json") }
}

public struct StabilityOwnedRunHandle: Equatable, Sendable {
    public let run: StabilityRunHandle
    fileprivate let ownershipToken: UUID
}

public actor StabilityRunCoordinator {
    public static let defaultMaximumRunCount = 20
    public static let defaultMaximumTotalBytes = 250 * 1_024 * 1_024
    private static let maximumFinderReportBytes = 1 * 1_024 * 1_024

    private let rootDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let processIdentifier: Int32

    public init(rootDirectoryURL: URL, processIdentifier: Int32 = getpid()) {
        self.rootDirectoryURL = rootDirectoryURL
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
        self.processIdentifier = processIdentifier
    }

    public init(
        appGroupIdentifier: String = ProviderConstants.appGroupIdentifier,
        processIdentifier: Int32 = getpid()
    ) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ProviderDiagnosticStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        self.init(
            rootDirectoryURL: containerURL.appendingPathComponent("StabilityRuns", isDirectory: true),
            processIdentifier: processIdentifier
        )
    }

    public func startRun(buildRevision: String? = nil) throws -> StabilityRunHandle {
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        return try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            if let active = try StabilityRunLocator.activeRunUnlocked(rootDirectoryURL: rootDirectoryURL) {
                guard SecurePOSIXFile.pathKind(active.finderAbandonedURL) == .missing else {
                    throw ProviderDiagnosticStoreError.runAbandonedByFinderRunner(active.runID)
                }
                return active
            }

            try SecurePOSIXFile.ensureDirectory(runsDirectoryURL)
            let runID = UUID()
            let directoryURL = runsDirectoryURL.appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
            try SecurePOSIXFile.createDirectoryExclusively(directoryURL)
            let handle = StabilityRunHandle(runID: runID, directoryURL: directoryURL)
            try SecurePOSIXFile.createExclusively(
                encoder.encode(StabilityRunManifest(runID: runID, buildRevision: buildRevision)),
                at: handle.manifestURL,
                permissions: 0o400
            )
            for url in [handle.eventsURL, handle.observationsURL, handle.assertionsURL] {
                try SecurePOSIXFile.createExclusively(Data(), at: url, permissions: 0o600)
            }
            try SecurePOSIXFile.replaceAtomically(
                encoder.encode(ActiveRunPointer(runID: runID)),
                at: activeRunURL,
                permissions: 0o600
            )
            return handle
        }
    }

    /// Starts a new run that only its creator may finish. Unlike `startRun`,
    /// this rejects a pre-existing active run so a command cannot repurpose a
    /// UI-owned bundle. The owner marker is retained after failures so partial
    /// evidence cannot be finalized as an ordinary successful run. A separate,
    /// explicit stale-owner recovery transition preserves an abandonment
    /// marker before releasing the active-run lease.
    public func startOwnedRun(buildRevision: String? = nil) throws -> StabilityOwnedRunHandle {
        guard processIdentifier > 0 else {
            throw ProviderDiagnosticStoreError.malformedRecord
        }
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        return try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            guard try StabilityRunLocator.activeRunUnlocked(rootDirectoryURL: rootDirectoryURL) == nil else {
                throw ProviderDiagnosticStoreError.runAlreadyActive
            }
            try SecurePOSIXFile.ensureDirectory(runsDirectoryURL)
            let runID = UUID()
            let token = UUID()
            let directoryURL = runsDirectoryURL.appendingPathComponent(
                runID.uuidString.lowercased(),
                isDirectory: true
            )
            try SecurePOSIXFile.createDirectoryExclusively(directoryURL)
            let handle = StabilityRunHandle(runID: runID, directoryURL: directoryURL)
            try SecurePOSIXFile.createExclusively(
                encoder.encode(StabilityRunManifest(runID: runID, buildRevision: buildRevision)),
                at: handle.manifestURL,
                permissions: 0o400
            )
            for url in [handle.eventsURL, handle.observationsURL, handle.assertionsURL] {
                try SecurePOSIXFile.createExclusively(Data(), at: url, permissions: 0o600)
            }
            try SecurePOSIXFile.createExclusively(
                encoder.encode(FinderRunOwnership(
                    token: token,
                    processIdentifier: processIdentifier
                )),
                at: handle.finderOwnerURL,
                permissions: 0o400
            )
            try SecurePOSIXFile.replaceAtomically(
                encoder.encode(ActiveRunPointer(runID: runID)),
                at: activeRunURL,
                permissions: 0o600
            )
            return StabilityOwnedRunHandle(run: handle, ownershipToken: token)
        }
    }

    @discardableResult
    public func finishRun(runID: UUID, summary: StabilityRunSummary) throws -> StabilityRunHandle {
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        return try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            let handle = StabilityRunHandle(
                runID: runID,
                directoryURL: runsDirectoryURL.appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
            )
            guard SecurePOSIXFile.isRegularFile(handle.manifestURL) else {
                throw ProviderDiagnosticStoreError.runNotFound(runID)
            }
            guard SecurePOSIXFile.pathKind(handle.finderOwnerURL) == .missing else {
                throw ProviderDiagnosticStoreError.runOwnedByFinderRunner(runID)
            }
            guard SecurePOSIXFile.pathKind(handle.finderAbandonedURL) == .missing else {
                throw ProviderDiagnosticStoreError.runAbandonedByFinderRunner(runID)
            }
            guard SecurePOSIXFile.pathKind(handle.summaryURL) == .missing else {
                throw ProviderDiagnosticStoreError.runAlreadyFinished(runID)
            }
            let wasActive = try StabilityRunLocator.activeRunUnlocked(rootDirectoryURL: rootDirectoryURL)?.runID == runID
            try SecurePOSIXFile.createExclusively(
                encoder.encode(summary),
                at: handle.summaryURL,
                permissions: 0o400
            )

            if wasActive {
                try SecurePOSIXFile.removeRegularFile(activeRunURL)
            }
            return handle
        }
    }

    @discardableResult
    public func finishOwnedRun(
        _ ownedRun: StabilityOwnedRunHandle,
        summary: StabilityRunSummary
    ) throws -> StabilityRunHandle {
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        return try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            let handle = ownedRun.run
            guard try StabilityRunLocator.activeRunUnlocked(
                rootDirectoryURL: rootDirectoryURL
            )?.runID == handle.runID,
                  SecurePOSIXFile.isRegularFile(handle.manifestURL),
                  SecurePOSIXFile.isRegularFile(handle.finderReportURL),
                  SecurePOSIXFile.pathKind(handle.finderAbandonedURL) == .missing,
                  SecurePOSIXFile.pathKind(handle.finderStepURL) == .missing,
                  SecurePOSIXFile.pathKind(handle.summaryURL) == .missing,
                  try Self.matchesOwnership(ownedRun, decoder: decoder) else {
                throw ProviderDiagnosticStoreError.runNotFound(handle.runID)
            }
            let report = try decoder.decode(
                StabilityFinderRunReport.self,
                from: SecurePOSIXFile.read(
                    handle.finderReportURL,
                    maximumBytes: Self.maximumFinderReportBytes
                )
            )
            let expectedAssertionCount = report.stepResults.reduce(into: 0) {
                $0 += $1.assertions.count
            }
            let expectedFailedAssertionCount = report.stepResults.reduce(into: 0) { count, step in
                count += step.assertions.filter {
                    if case .failed = $0.outcome { return true }
                    return false
                }.count
            }
            let expectedCheckpointCount = report.preflightSummary.checkpointed
                + report.stepSummary.checkpointed
            guard summary.assertionCount == expectedAssertionCount,
                  summary.failedAssertionCount == expectedFailedAssertionCount,
                  summary.checkpointCount == expectedCheckpointCount else {
                throw ProviderDiagnosticStoreError.finderSummaryMismatch
            }
            try SecurePOSIXFile.createExclusively(
                encoder.encode(summary),
                at: handle.summaryURL,
                permissions: 0o400
            )
            try SecurePOSIXFile.removeRegularFile(activeRunURL)
            try SecurePOSIXFile.removeRegularFile(handle.finderOwnerURL)
            return handle
        }
    }

    /// Abandons an incomplete Finder run only after its recorded owner process
    /// is no longer alive. Evidence remains on disk and is marked incomplete;
    /// the active pointer is removed so a new run or reversible lab reset can
    /// proceed. This operation never mutates remote data.
    @discardableResult
    public func abandonStaleOwnedRun() throws -> StabilityRunHandle {
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        return try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            guard let handle = try StabilityRunLocator.activeRunUnlocked(
                rootDirectoryURL: rootDirectoryURL
            ) else {
                throw ProviderDiagnosticStoreError.noStaleFinderRun
            }

            switch SecurePOSIXFile.pathKind(handle.finderAbandonedURL) {
            case .regularFile:
                break
            case .missing:
                guard SecurePOSIXFile.isRegularFile(handle.finderOwnerURL) else {
                    throw ProviderDiagnosticStoreError.noStaleFinderRun
                }
                let ownership = try decoder.decode(
                    FinderRunOwnership.self,
                    from: SecurePOSIXFile.read(handle.finderOwnerURL, maximumBytes: 4 * 1_024)
                )
                guard ownership.processIdentifier > 0 else {
                    throw ProviderDiagnosticStoreError.malformedRecord
                }
                errno = 0
                if kill(ownership.processIdentifier, 0) == 0 || errno == EPERM {
                    throw ProviderDiagnosticStoreError.finderOwnerProcessStillRunning
                }
                guard errno == ESRCH else {
                    throw ProviderDiagnosticStoreError.fileSystemError(errno)
                }
                try SecurePOSIXFile.createExclusively(
                    encoder.encode(FinderRunAbandonment()),
                    at: handle.finderAbandonedURL,
                    permissions: 0o400
                )
            case .directory, .other:
                throw ProviderDiagnosticStoreError.unsafeFileType
            }

            switch SecurePOSIXFile.pathKind(handle.finderStepURL) {
            case .missing:
                break
            case .regularFile:
                try SecurePOSIXFile.removeRegularFile(handle.finderStepURL)
            case .directory, .other:
                throw ProviderDiagnosticStoreError.unsafeFileType
            }
            switch SecurePOSIXFile.pathKind(handle.finderOwnerURL) {
            case .missing:
                break
            case .regularFile:
                try SecurePOSIXFile.removeRegularFile(handle.finderOwnerURL)
            case .directory, .other:
                throw ProviderDiagnosticStoreError.unsafeFileType
            }
            try SecurePOSIXFile.removeRegularFile(activeRunURL)
            return handle
        }
    }

    public func beginFinderStep(
        ownedRun: StabilityOwnedRunHandle,
        correlationID: UUID
    ) throws {
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            guard try StabilityRunLocator.activeRunUnlocked(
                rootDirectoryURL: rootDirectoryURL
            )?.runID == ownedRun.run.runID,
                  try Self.matchesOwnership(ownedRun, decoder: decoder),
                  SecurePOSIXFile.pathKind(ownedRun.run.summaryURL) == .missing else {
                throw ProviderDiagnosticStoreError.runNotFound(ownedRun.run.runID)
            }
            guard SecurePOSIXFile.pathKind(ownedRun.run.finderStepURL) == .missing else {
                throw ProviderDiagnosticStoreError.finderStepAlreadyActive
            }
            try SecurePOSIXFile.createExclusively(
                encoder.encode(FinderStepPointer(correlationID: correlationID)),
                at: ownedRun.run.finderStepURL,
                permissions: 0o400
            )
        }
    }

    public func endFinderStep(
        ownedRun: StabilityOwnedRunHandle,
        correlationID: UUID
    ) throws {
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            guard try Self.matchesOwnership(ownedRun, decoder: decoder),
                  SecurePOSIXFile.isRegularFile(ownedRun.run.finderStepURL) else {
                throw ProviderDiagnosticStoreError.runNotFound(ownedRun.run.runID)
            }
            let pointer = try decoder.decode(
                FinderStepPointer.self,
                from: SecurePOSIXFile.read(
                    ownedRun.run.finderStepURL,
                    maximumBytes: 4 * 1_024
                )
            )
            guard pointer.correlationID == correlationID else {
                throw ProviderDiagnosticStoreError.finderStepCorrelationMismatch
            }
            try SecurePOSIXFile.removeRegularFile(ownedRun.run.finderStepURL)
        }
    }

    public func activeRun() throws -> StabilityRunHandle? {
        try StabilityRunLocator.activeRun(rootDirectoryURL: rootDirectoryURL)
    }

    #if STABILITY
    public func selectConflictProfile(_ selectedCase: StabilityLiveConflictCase, ownedRun: StabilityOwnedRunHandle,
                                      extensionLaunchMode: StabilityExtensionLaunchMode? = nil) throws {
        try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            guard try Self.matchesOwnership(ownedRun, decoder: decoder),
                  try StabilityRunLocator.activeRunUnlocked(rootDirectoryURL: rootDirectoryURL)?.runID == ownedRun.run.runID else {
                throw ProviderDiagnosticStoreError.runNotFound(ownedRun.run.runID)
            }
            try SecurePOSIXFile.createExclusively(encoder.encode(StabilityConflictProfile(runID: ownedRun.run.runID, selectedCase: selectedCase, extensionLaunchMode: extensionLaunchMode)),
                at: ownedRun.run.directoryURL.appendingPathComponent("conflict-profile.json"), permissions: 0o400)
        }
    }
    public func requireExtensionLaunch(_ mode: StabilityExtensionLaunchMode, ownedRun: StabilityOwnedRunHandle) throws {
        try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            guard try Self.matchesOwnership(ownedRun, decoder: decoder),
                  try StabilityRunLocator.activeRunUnlocked(rootDirectoryURL: rootDirectoryURL)?.runID == ownedRun.run.runID else {
                throw ProviderDiagnosticStoreError.runNotFound(ownedRun.run.runID)
            }
            try SecurePOSIXFile.createExclusively(encoder.encode(StabilityExtensionLaunchRequest(runID: ownedRun.run.runID, mode: mode)),
                at: ownedRun.run.directoryURL.appendingPathComponent("extension-launch-request.json"), permissions: 0o400)
        }
    }

    public func recordExtensionLaunch(_ evidence: StabilityExtensionLaunchEvidence, ownedRun: StabilityOwnedRunHandle) throws {
        try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            guard evidence.runID == ownedRun.run.runID, try Self.matchesOwnership(ownedRun, decoder: decoder),
                  try StabilityRunLocator.activeRunUnlocked(rootDirectoryURL: rootDirectoryURL)?.runID == evidence.runID,
                  SecurePOSIXFile.pathKind(ownedRun.run.finderReportURL) == .missing else {
                throw ProviderDiagnosticStoreError.runNotFound(ownedRun.run.runID)
            }
            try SecurePOSIXFile.createExclusively(encoder.encode(evidence),
                at: ownedRun.run.directoryURL.appendingPathComponent("extension-launch.json"), permissions: 0o400)
        }
    }
    #endif

    /// Retains a rejected candidate without authorizing finalization or changing
    /// the accepted report. Error descriptions and external payloads are omitted.
    public func recordFinderEvidenceRejection(
        _ rejection: StabilityFinderEvidenceRejection, ownedRun: StabilityOwnedRunHandle
    ) throws {
        try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            guard try Self.matchesOwnership(ownedRun, decoder: decoder),
                  SecurePOSIXFile.pathKind(ownedRun.run.summaryURL) == .missing else {
                throw ProviderDiagnosticStoreError.runNotFound(ownedRun.run.runID)
            }
            try SecurePOSIXFile.createExclusively(encoder.encode(rejection),
                at: ownedRun.run.directoryURL.appendingPathComponent("finder-evidence-rejected.json"), permissions: 0o400)
        }
    }

    /// Assembles closed Finder assertion and API-observation evidence. Each
    /// file replacement is atomic; the immutable report is the commit marker
    /// and can be written only once. Run summary sealing remains a separate
    /// final lifecycle transition.
    public func writeFinderEvidence(
        ownedRun: StabilityOwnedRunHandle,
        report: StabilityFinderRunReport,
        observations: [StabilityFinderAPIObservation]
    ) throws {
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            let handle = ownedRun.run
            guard try StabilityRunLocator.activeRunUnlocked(
                rootDirectoryURL: rootDirectoryURL
            )?.runID == handle.runID,
                  SecurePOSIXFile.isRegularFile(handle.manifestURL),
                  SecurePOSIXFile.pathKind(handle.summaryURL) == .missing,
                  SecurePOSIXFile.pathKind(handle.finderStepURL) == .missing,
                  try Self.matchesOwnership(ownedRun, decoder: decoder) else {
                throw ProviderDiagnosticStoreError.runNotFound(handle.runID)
            }
            guard SecurePOSIXFile.pathKind(handle.finderReportURL) == .missing else {
                throw ProviderDiagnosticStoreError.finderEvidenceAlreadyFinalized(handle.runID)
            }
            guard SecurePOSIXFile.pathKind(handle.directoryURL.appendingPathComponent("diagnostic-health.failed")) == .missing else {
                throw ProviderDiagnosticStoreError.malformedRecord
            }
            try Self.validateFinderObservations(observations, report: report)
            let timeline = try Self.readDiagnosticEvents(from: handle.eventsURL, decoder: decoder).sorted {
                $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt < $1.occurredAt
            }
            try Self.validateFinderDiagnostics(timeline, report: report)
            #if STABILITY
            let profileURL = handle.directoryURL.appendingPathComponent("conflict-profile.json")
            if SecurePOSIXFile.isRegularFile(profileURL) {
                let profile = try decoder.decode(StabilityConflictProfile.self, from: SecurePOSIXFile.read(profileURL, maximumBytes: 4096))
                guard profile.runID == handle.runID else { throw StabilityLiveEvidenceError.missingConflict }
                let requestURL = handle.directoryURL.appendingPathComponent("conflict-request.json")
                let ticket = SecurePOSIXFile.isRegularFile(requestURL)
                    ? try JSONDecoder().decode(StabilityConflictBarrier.Ticket.self, from: SecurePOSIXFile.read(requestURL, maximumBytes: 4096)) : nil
                let released = ticket.map { SecurePOSIXFile.isRegularFile(handle.directoryURL.appendingPathComponent("conflict-" + $0.attemptID.uuidString.lowercased() + "-release")) } ?? false
                try profile.validate(report: report, ticket: ticket,
                    reached: ticket.map { StabilityConflictBarrier.reached($0, run: handle) } ?? false,
                    released: released,
                    competingMutationVerified: ticket.map { StabilityConflictBarrier.competingMutationVerified($0, run: handle) } ?? false,
                    diagnostics: timeline)
                if let mode = profile.extensionLaunchMode, report.stepSummary.passed > 0 {
                    let launch = try decoder.decode(StabilityExtensionLaunchEvidence.self,
                        from: SecurePOSIXFile.read(handle.directoryURL.appendingPathComponent("extension-launch.json"), maximumBytes: 4096))
                    guard launch.mode == mode else { throw StabilityLiveEvidenceError.wrongExtensionBuild }
                    try launch.validate(runID: handle.runID, report: report, diagnostics: timeline)
                }
            } else if report.stepResults.contains(where: { $0.outcome == .skipped(.notSelectedForConflictProfile) }) {
                throw StabilityLiveEvidenceError.missingConflict
            }
            if report.schemaVersion >= StabilityFinderRunReport.liveSchemaVersion,
               report.stepResults.contains(where: { $0.scenario == .concurrentRemotePreserveBoth && $0.outcome == .passed }) {
                let ticket = try JSONDecoder().decode(StabilityConflictBarrier.Ticket.self,
                    from: SecurePOSIXFile.read(handle.directoryURL.appendingPathComponent("conflict-request.json"), maximumBytes: 4096))
                guard StabilityConflictBarrier.competingMutationVerified(ticket, run: handle) else {
                    throw StabilityLiveEvidenceError.missingConflict
                }
            }
            let launchRequestURL = handle.directoryURL.appendingPathComponent("extension-launch-request.json")
            if SecurePOSIXFile.isRegularFile(launchRequestURL) {
                let request = try decoder.decode(StabilityExtensionLaunchRequest.self, from: SecurePOSIXFile.read(launchRequestURL, maximumBytes: 4096))
                guard request.runID == handle.runID else { throw StabilityLiveEvidenceError.wrongExtensionBuild }
                let launchURL = handle.directoryURL.appendingPathComponent("extension-launch.json")
                let evidence = SecurePOSIXFile.isRegularFile(launchURL)
                    ? try decoder.decode(StabilityExtensionLaunchEvidence.self, from: SecurePOSIXFile.read(launchURL, maximumBytes: 4096)) : nil
                try request.validate(evidence: evidence, report: report, diagnostics: timeline)
            }
            #endif
            if report.schemaVersion >= StabilityFinderRunReport.liveSchemaVersion {
                try SecurePOSIXFile.replaceAtomically(try encoder.encode(timeline),
                    at: handle.directoryURL.appendingPathComponent("diagnostic-timeline.json"), permissions: 0o400)
            }

            let assertionRecords = report.preflightResults.map {
                FinderAssertionRecord.preflight($0)
            } + report.stepResults.map {
                FinderAssertionRecord.step($0)
            }
            try SecurePOSIXFile.replaceAtomically(
                try Self.jsonLines(assertionRecords, encoder: encoder),
                at: handle.assertionsURL,
                permissions: 0o400
            )
            try SecurePOSIXFile.replaceAtomically(
                try Self.jsonLines(observations, encoder: encoder),
                at: handle.observationsURL,
                permissions: 0o400
            )
            try SecurePOSIXFile.createExclusively(
                encoder.encode(report),
                at: handle.finderReportURL,
                permissions: 0o400
            )
        }
    }

    /// Holds the cross-process run lifecycle lock for the full duration of a
    /// destructive Stability Lab reset. A run cannot start between the reset
    /// preflight and its final reversible trash operation.
    public func withInactiveRunLease<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        return try await SecurePOSIXFile.withAsyncLock(
            at: coordinatorLockURL,
            operation: LOCK_EX
        ) {
            guard try StabilityRunLocator.activeRunUnlocked(
                rootDirectoryURL: rootDirectoryURL
            ) == nil else {
                throw ProviderDiagnosticStoreError.runAlreadyActive
            }
            return try await body()
        }
    }

    @discardableResult
    public func pruneCompletedRuns(
        maximumRunCount: Int = defaultMaximumRunCount,
        maximumTotalBytes: Int = defaultMaximumTotalBytes
    ) throws -> [UUID] {
        guard SecurePOSIXFile.pathKind(runsDirectoryURL) != .missing else { return [] }
        try SecurePOSIXFile.ensureDirectory(rootDirectoryURL)
        return try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_EX) {
            let activeRunID = try StabilityRunLocator.activeRunUnlocked(rootDirectoryURL: rootDirectoryURL)?.runID
            let directories = try FileManager.default.contentsOfDirectory(
                at: runsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            var completed: [(handle: StabilityRunHandle, finishedAt: Date, size: Int)] = []
            for directory in directories {
                guard SecurePOSIXFile.pathKind(directory) == .directory,
                      let runID = UUID(uuidString: directory.lastPathComponent),
                      runID != activeRunID else { continue }
                let handle = StabilityRunHandle(runID: runID, directoryURL: directory)
                guard SecurePOSIXFile.isRegularFile(handle.manifestURL),
                      SecurePOSIXFile.isRegularFile(handle.summaryURL) else { continue }
                let summary = try decoder.decode(
                    StabilityRunSummary.self,
                    from: SecurePOSIXFile.read(handle.summaryURL, maximumBytes: 64 * 1_024)
                )
                completed.append((handle, summary.finishedAt, try Self.directorySize(directory)))
            }
            completed.sort { $0.finishedAt > $1.finishedAt }

            var retainedCount = 0
            var retainedBytes = 0
            var removed: [UUID] = []
            for run in completed {
                let fitsCount = retainedCount < max(0, maximumRunCount)
                let fitsBytes = run.size <= max(0, maximumTotalBytes - retainedBytes)
                if fitsCount && fitsBytes {
                    retainedCount += 1
                    retainedBytes += run.size
                } else {
                    try FileManager.default.removeItem(at: run.handle.directoryURL)
                    try SecurePOSIXFile.synchronizeDirectory(runsDirectoryURL)
                    removed.append(run.handle.runID)
                }
            }
            return removed
        }
    }

    private var runsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("runs", isDirectory: true)
    }

    private var activeRunURL: URL {
        rootDirectoryURL.appendingPathComponent("current-run.json")
    }

    private var coordinatorLockURL: URL {
        rootDirectoryURL.appendingPathComponent("coordinator.lock")
    }

    private static func directorySize(_ directoryURL: URL) throws -> Int {
        guard SecurePOSIXFile.pathKind(directoryURL) == .directory,
              let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var size = 0
        for case let url as URL in enumerator {
            switch SecurePOSIXFile.pathKind(url) {
            case .regularFile:
                size += try SecurePOSIXFile.fileSize(url)
            case .directory:
                continue
            case .missing, .other:
                throw ProviderDiagnosticStoreError.unsafeFileType
            }
        }
        return size
    }

    private static func validateFinderObservations(
        _ observations: [StabilityFinderAPIObservation],
        report: StabilityFinderRunReport
    ) throws {
        let steps = Dictionary(uniqueKeysWithValues: report.stepResults.map {
            ($0.scenario, $0)
        })
        var seen: Set<FinderObservationKey> = []
        for observation in observations {
            let key = FinderObservationKey(
                scenario: observation.scenario,
                phase: observation.phase
            )
            guard seen.insert(key).inserted else {
                throw StabilityFinderEvidenceValidationError.duplicateObservation(
                    scenario: observation.scenario,
                    phase: observation.phase
                )
            }
            guard steps[observation.scenario]?.correlationID == observation.correlationID else {
                throw StabilityFinderEvidenceValidationError.observationCorrelationMismatch(
                    observation.scenario
                )
            }
        }

        for step in report.stepResults where step.outcome == .passed {
            for phase in [
                StabilityFinderAPIObservationPhase.baseline,
                .postcondition,
            ] {
                guard let observation = observations.first(where: {
                    $0.scenario == step.scenario && $0.phase == phase
                }) else {
                    throw StabilityFinderEvidenceValidationError.missingPassedObservation(
                        scenario: step.scenario,
                        phase: phase
                    )
                }
                guard observation.outcome == .passed else {
                    throw StabilityFinderEvidenceValidationError.invalidPassedObservation(
                        step.scenario
                    )
                }
            }
        }
    }

    public static func readDiagnosticEvents(
        from eventsURL: URL,
        decoder suppliedDecoder: JSONDecoder? = nil
    ) throws -> [ProviderDiagnosticEvent] {
        let decoder = suppliedDecoder ?? makeDecoder()
        let data = try LockedJSONLFile.read(
            from: eventsURL,
            maximumBytes: defaultMaximumTotalBytes
        )
        let endsInNewline = data.last == 0x0A || data.isEmpty
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var diagnostics: [ProviderDiagnosticEvent] = []
        for (offset, line) in lines.enumerated() where line.isEmpty == false {
            if endsInNewline == false, offset == lines.count - 1 {
                break
            }
            let record: JSONLRecord
            do {
                record = try decoder.decode(JSONLRecord.self, from: Data(line))
            } catch {
                throw ProviderDiagnosticStoreError.corruptRecord(line: offset + 1)
            }
            guard record.schemaVersion == JSONLRecord.schemaVersion else {
                throw ProviderDiagnosticStoreError.unsupportedSchemaVersion(record.schemaVersion)
            }
            if case .diagnostic(let event) = try record.payload {
                diagnostics.append(event)
            }
        }
        return diagnostics
    }

    private static func validateFinderDiagnostics(
        _ diagnostics: [ProviderDiagnosticEvent],
        report: StabilityFinderRunReport
    ) throws {
        for step in report.stepResults where step.outcome == .passed {
            if report.schemaVersion == StabilityFinderRunReport.liveSchemaVersion {
                try StabilityLiveEvidenceValidator.validate(step: step, diagnostics: diagnostics)
                continue
            }
            guard let requirement = step.scenario.diagnosticRequirement,
                  requirement.operationGroups.isEmpty == false,
                  requirement.operationGroups.allSatisfy({ operationGroup in
                      operationGroup.isEmpty == false && diagnostics.contains(where: {
                          $0.correlationID == step.correlationID
                              && $0.source == requirement.source
                              && operationGroup.contains($0.operation)
                              && $0.phase == .completed
                      })
                  }) else {
                throw StabilityFinderEvidenceValidationError.missingDiagnosticEvidence(
                    step.scenario
                )
            }
        }
    }

    private static func jsonLines<T: Encodable>(
        _ values: [T],
        encoder: JSONEncoder
    ) throws -> Data {
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0A)
        }
        return data
    }

    private static func matchesOwnership(
        _ ownedRun: StabilityOwnedRunHandle,
        decoder: JSONDecoder
    ) throws -> Bool {
        guard SecurePOSIXFile.isRegularFile(ownedRun.run.finderOwnerURL) else { return false }
        let ownership = try decoder.decode(
            FinderRunOwnership.self,
            from: SecurePOSIXFile.read(ownedRun.run.finderOwnerURL, maximumBytes: 4 * 1_024)
        )
        return ownership.token == ownedRun.ownershipToken
    }

    fileprivate static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    fileprivate static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct ActiveRunPointer: Codable {
    let runID: UUID
}

private struct FinderRunOwnership: Codable {
    let token: UUID
    let processIdentifier: Int32
}

private struct FinderRunAbandonment: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let abandonedAt: Date

    init(abandonedAt: Date = Date()) {
        self.schemaVersion = Self.schemaVersion
        self.abandonedAt = abandonedAt
    }
}

private struct FinderStepPointer: Codable {
    let correlationID: UUID
}

private struct FinderObservationKey: Hashable {
    let scenario: StabilityFinderScenario
    let phase: StabilityFinderAPIObservationPhase
}

private enum FinderAssertionRecord: Codable {
    case preflight(StabilityFinderPreflightResult)
    case step(StabilityFinderStepResult)
}

public enum StabilityRunLocator {
    public static func activeRun(rootDirectoryURL: URL) throws -> StabilityRunHandle? {
        switch SecurePOSIXFile.pathKind(rootDirectoryURL) {
        case .missing:
            return nil
        case .directory:
            break
        case .regularFile, .other:
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
        return try SecurePOSIXFile.withLock(
            at: rootDirectoryURL.appendingPathComponent("coordinator.lock"),
            operation: LOCK_SH
        ) {
            try activeRunUnlocked(rootDirectoryURL: rootDirectoryURL)
        }
    }

    public static func activeFinderStepCorrelation(
        rootDirectoryURL: URL
    ) throws -> UUID? {
        guard SecurePOSIXFile.pathKind(rootDirectoryURL) == .directory else { return nil }
        return try SecurePOSIXFile.withLock(
            at: rootDirectoryURL.appendingPathComponent("coordinator.lock"),
            operation: LOCK_SH
        ) {
            guard let run = try activeRunUnlocked(rootDirectoryURL: rootDirectoryURL) else {
                return nil
            }
            switch SecurePOSIXFile.pathKind(run.finderStepURL) {
            case .missing:
                return nil
            case .regularFile:
                return try StabilityRunCoordinator.makeDecoder().decode(
                    FinderStepPointer.self,
                    from: SecurePOSIXFile.read(run.finderStepURL, maximumBytes: 4 * 1_024)
                ).correlationID
            case .directory, .other:
                throw ProviderDiagnosticStoreError.unsafeFileType
            }
        }
    }

    fileprivate static func activeRunUnlocked(rootDirectoryURL: URL) throws -> StabilityRunHandle? {
        let pointerURL = rootDirectoryURL.appendingPathComponent("current-run.json")
        switch SecurePOSIXFile.pathKind(pointerURL) {
        case .missing:
            return nil
        case .regularFile:
            break
        case .directory, .other:
            throw ProviderDiagnosticStoreError.invalidActiveRunPointer
        }
        let pointer = try StabilityRunCoordinator.makeDecoder().decode(
            ActiveRunPointer.self,
            from: SecurePOSIXFile.read(pointerURL, maximumBytes: 64 * 1_024)
        )
        let directoryURL = rootDirectoryURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(pointer.runID.uuidString.lowercased(), isDirectory: true)
        let handle = StabilityRunHandle(runID: pointer.runID, directoryURL: directoryURL)
        guard SecurePOSIXFile.pathKind(directoryURL) == .directory,
              SecurePOSIXFile.isRegularFile(handle.manifestURL) else {
            throw ProviderDiagnosticStoreError.invalidActiveRunPointer
        }
        switch SecurePOSIXFile.pathKind(handle.summaryURL) {
        case .missing:
            break
        case .regularFile:
            // A crash after the immutable summary was created but before the
            // active pointer was unlinked leaves a recoverable stale pointer.
            return nil
        case .directory, .other:
            throw ProviderDiagnosticStoreError.invalidActiveRunPointer
        }
        let manifest = try StabilityRunCoordinator.makeDecoder().decode(
            StabilityRunManifest.self,
            from: SecurePOSIXFile.read(handle.manifestURL, maximumBytes: 64 * 1_024)
        )
        guard manifest.runID == pointer.runID else {
            throw ProviderDiagnosticStoreError.invalidActiveRunPointer
        }
        return handle
    }
}

public actor KDriveProviderEventJSONLStore: KDriveProviderEventStoring,
    KDriveProviderEventTimelinePaging,
    KDriveProviderEventStatisticsProviding,
    KDriveProviderEventObserving,
    KDriveProviderEventPruning,
    KDriveProviderEventExporting,
    ProviderDiagnosticRecording
{
    private let eventsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let runID: UUID
    private let domainHashSalt: Data
    private let summaryURL: URL
    private let coordinatorLockURL: URL
    private let maximumEventBytes: Int

    public init(
        runDirectoryURL: URL,
        maximumEventBytes: Int = StabilityRunCoordinator.defaultMaximumTotalBytes
    ) throws {
        guard SecurePOSIXFile.pathKind(runDirectoryURL) == .directory else {
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
        let manifestURL = runDirectoryURL.appendingPathComponent("run.json")
        let manifest = try StabilityRunCoordinator.makeDecoder().decode(
            StabilityRunManifest.self,
            from: SecurePOSIXFile.read(manifestURL, maximumBytes: 64 * 1_024)
        )
        guard runDirectoryURL.lastPathComponent.caseInsensitiveCompare(manifest.runID.uuidString) == .orderedSame else {
            throw ProviderDiagnosticStoreError.invalidActiveRunPointer
        }
        self.eventsURL = runDirectoryURL.appendingPathComponent("events.jsonl")
        self.encoder = StabilityRunCoordinator.makeEncoder()
        self.decoder = StabilityRunCoordinator.makeDecoder()
        self.runID = manifest.runID
        self.domainHashSalt = Data(manifest.runID.uuidString.lowercased().utf8)
        self.summaryURL = runDirectoryURL.appendingPathComponent("summary.json")
        self.coordinatorLockURL = runDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("coordinator.lock")
        self.maximumEventBytes = max(0, maximumEventBytes)
        switch SecurePOSIXFile.pathKind(eventsURL) {
        case .regularFile:
            break
        case .missing:
            try SecurePOSIXFile.createExclusively(Data(), at: eventsURL, permissions: 0o600)
        case .directory, .other:
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
    }

    public func saveConflict(_ event: KDriveConflictEvent) throws {
        try append(.conflict(sanitize(event)))
    }

    public func recordActivity(_ event: KDriveProviderActivityEvent) throws {
        try append(.activity(sanitize(event)))
    }

    public func recordDiagnostic(_ event: ProviderDiagnosticEvent) throws {
        try append(.diagnostic(event))
    }

    public func recentConflicts(domainIdentifier: String?, limit: Int = 100) throws -> [KDriveConflictEvent] {
        let domainHash = domainIdentifier.map(domainHash)
        return Array(try replay().conflicts.values
            .filter { domainHash == nil || $0.domainIdentifier == domainHash }
            .sorted { $0.detectedAt > $1.detectedAt }
            .prefix(max(0, limit)))
    }

    public func recentActivity(domainIdentifier: String?, limit: Int = 100) throws -> [KDriveProviderActivityEvent] {
        try recentActivity(domainIdentifier: domainIdentifier, outcome: nil, limit: limit)
    }

    public func recentActivity(
        domainIdentifier: String?,
        outcome: KDriveProviderActivityOutcome?,
        limit: Int = 100
    ) throws -> [KDriveProviderActivityEvent] {
        let domainHash = domainIdentifier.map(domainHash)
        return Array(try replay().activity.values
            .filter { event in
                (domainHash == nil || event.domainIdentifier == domainHash)
                    && (outcome == nil || event.outcome == outcome)
            }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(max(0, limit)))
    }

    public func removeActivityAndResolvedConflicts(domainIdentifier: String? = nil) throws {
        try append(.clearActivityAndResolvedConflicts(domainIdentifier.map(domainHash)))
    }

    public func removeEvents(domainIdentifier: String) throws {
        try append(.removeDomain(domainHash(domainIdentifier)))
    }

    public func pruneActivityEvents(maximumCount _: Int) throws {
        // Stability bundles are immutable evidence. Retention removes only
        // complete run directories through StabilityRunCoordinator.
    }

    public func timelinePage(
        filter: KDriveProviderTimelineFilter,
        before cursor: KDriveProviderTimelineCursor?,
        limit: Int
    ) throws -> KDriveProviderTimelinePage {
        guard limit > 0 else {
            return KDriveProviderTimelinePage(entries: [], nextCursor: nil, hasMore: false)
        }
        let state = try replay()
        var entries = state.conflicts.values.map(KDriveProviderTimelineEntry.conflict)
        entries += state.activity.values
            .filter { $0.relatedConflictID == nil }
            .filter { filter == .allActivity || $0.outcome == .failure }
            .map(KDriveProviderTimelineEntry.activity)
        entries.sort(by: Self.isNewer)
        if let cursor {
            entries = entries.filter { Self.isEntry($0, before: cursor) }
        }
        let pageSize = max(0, limit)
        let pageEntries = Array(entries.prefix(pageSize))
        let hasMore = entries.count > pageEntries.count
        return KDriveProviderTimelinePage(
            entries: pageEntries,
            nextCursor: hasMore ? pageEntries.last?.cursor : nil,
            hasMore: hasMore
        )
    }

    public func eventStatistics(
        domainIdentifiers: Set<String>
    ) throws -> [KDriveProviderEventDomainStatistics] {
        let requested = Dictionary(uniqueKeysWithValues: domainIdentifiers.map { (domainHash($0), $0) })
        let state = try replay()
        return requested.sorted { $0.value < $1.value }.map { domainHash, originalDomain in
            let conflicts = state.conflicts.values.filter { $0.domainIdentifier == domainHash }
            let activity = state.activity.values.filter { $0.domainIdentifier == domainHash }
            return KDriveProviderEventDomainStatistics(
                domainIdentifier: originalDomain,
                unresolvedConflictCount: conflicts.filter { $0.resolutionState == .unresolved }.count,
                blockedConflictCount: conflicts.filter { $0.resolutionState == .blockedRetryable }.count,
                failedConflictCount: conflicts.filter { $0.resolutionState == .failed }.count,
                resolvedConflictCount: conflicts.filter { $0.resolutionState == .automaticallyResolved }.count,
                recentFailureCount: activity.filter { $0.outcome == .failure }.count,
                recentSuccessCount: activity.filter { $0.outcome == .success }.count,
                latestConflictAt: conflicts.map { $0.resolvedAt ?? $0.detectedAt }.max(),
                latestActivityAt: activity.map(\.occurredAt).max()
            )
        }
    }

    public func supportLogData(domainIdentifier: String? = nil) throws -> Data {
        let log = KDriveProviderSupportLog(
            activity: try recentActivity(domainIdentifier: domainIdentifier, limit: .max),
            conflicts: try recentConflicts(domainIdentifier: domainIdentifier, limit: .max)
        )
        let exportEncoder = StabilityRunCoordinator.makeEncoder()
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try exportEncoder.encode(log)
    }

    public func eventChanges(pollInterval: TimeInterval = 1) async -> AsyncStream<Void> {
        let url = eventsURL
        // Establish the subscription before returning it. If the worker takes
        // its baseline later, an intervening append becomes invisible.
        let initial = Self.fileFingerprint(url)
        return AsyncStream { continuation in
            let task = Task.detached {
                var previous = initial
                while Task.isCancelled == false {
                    try? await Task.sleep(for: .seconds(max(0.05, pollInterval)))
                    let current = Self.fileFingerprint(url)
                    if current != previous {
                        previous = current
                        continuation.yield()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func append(_ payload: JSONLRecord.Payload) throws {
        var data = try encoder.encode(JSONLRecord(payload: payload))
        data.append(0x0A)
        try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_SH) {
            guard SecurePOSIXFile.pathKind(summaryURL) == .missing else {
                throw ProviderDiagnosticStoreError.runAlreadyFinished(runID)
            }
            do {
                try LockedJSONLFile.append(data, to: eventsURL, maximumBytes: maximumEventBytes)
            } catch {
                // Persist a content-free health latch: a later successful write cannot hide a gap.
                try? SecurePOSIXFile.createExclusively(Data(), at: eventsURL.deletingLastPathComponent().appendingPathComponent("diagnostic-health.failed"), permissions: 0o400)
                throw error
            }
        }
    }

    private func replay() throws -> ReplayState {
        let data = try SecurePOSIXFile.withLock(at: coordinatorLockURL, operation: LOCK_SH) {
            try LockedJSONLFile.read(from: eventsURL, maximumBytes: maximumEventBytes)
        }
        let endsInNewline = data.last == 0x0A || data.isEmpty
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var state = ReplayState()
        for (offset, line) in lines.enumerated() where line.isEmpty == false {
            if endsInNewline == false, offset == lines.count - 1 {
                break
            }
            let record: JSONLRecord
            do {
                record = try decoder.decode(JSONLRecord.self, from: Data(line))
            } catch {
                throw ProviderDiagnosticStoreError.corruptRecord(line: offset + 1)
            }
            guard record.schemaVersion == JSONLRecord.schemaVersion else {
                throw ProviderDiagnosticStoreError.unsupportedSchemaVersion(record.schemaVersion)
            }
            state.apply(try record.payload)
        }
        return state
    }

    private func sanitize(_ event: KDriveProviderActivityEvent) -> KDriveProviderActivityEvent {
        KDriveProviderActivityEvent(
            id: event.id,
            occurredAt: event.occurredAt,
            domainIdentifier: domainHash(event.domainIdentifier),
            driveID: 0,
            kind: event.kind,
            scope: event.scope,
            outcome: event.outcome,
            severity: event.severity,
            itemIdentifier: nil,
            itemName: nil,
            itemPath: nil,
            summary: "\(Self.displayName(event.kind)) \(Self.outcomeDescription(event.outcome)).",
            relatedConflictID: event.relatedConflictID,
            diagnostic: event.errorCategory.map {
                KDriveProviderActivityErrorDiagnostic(
                    errorCategory: $0,
                    providerErrorCode: event.providerErrorCode,
                    underlyingErrorDomain: Self.safeErrorDomain(event.underlyingErrorDomain),
                    underlyingErrorCode: event.underlyingErrorCode,
                    recoverySuggestion: nil,
                    diagnosticSummary: nil
                )
            },
            correlationID: Self.safeUUIDString(event.correlationID),
            durationMilliseconds: event.durationMilliseconds.map { max(0, $0) },
            networkOperation: event.networkOperation.flatMap(Self.safeNetworkOperation),
            httpStatusCode: event.httpStatusCode,
            remoteRequestID: nil
        )
    }

    private func sanitize(_ event: KDriveConflictEvent) -> KDriveConflictEvent {
        KDriveConflictEvent(
            id: event.id,
            detectedAt: event.detectedAt,
            resolvedAt: event.resolvedAt,
            domainIdentifier: domainHash(event.domainIdentifier),
            driveID: 0,
            operation: event.operation,
            originalItemIdentifier: nil,
            originalItemName: nil,
            originalItemPath: nil,
            conflictItemIdentifier: nil,
            conflictItemName: nil,
            conflictItemPath: nil,
            resolutionState: event.resolutionState,
            automaticallyResolved: event.automaticallyResolved,
            resolutionKind: event.resolutionKind,
            resolutionSummary: "Conflict \(event.resolutionState.rawValue).",
            stagedUploadRelativePath: nil
        )
    }

    private func domainHash(_ value: String) -> String {
        var input = domainHashSalt
        input.append(contentsOf: value.utf8)
        let digest = SHA256.hash(data: input)
        return "domain-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeUUIDString(_ value: String?) -> String? {
        value.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    }

    private static func safeErrorDomain(_ value: String?) -> String? {
        let allowed = [NSCocoaErrorDomain, NSURLErrorDomain, "NSFileProviderErrorDomain"]
        return value.flatMap { allowed.contains($0) ? $0 : nil }
    }

    private static func safeNetworkOperation(_ value: String) -> String? {
        let allowed = Set(ProviderDiagnosticOperation.allCases.map(\.rawValue))
        return allowed.contains(value) ? value : nil
    }

    private static func displayName(_ kind: KDriveProviderActivityKind) -> String {
        switch kind {
        case .syncAnchor: "Sync anchor"
        case .fetchContents: "Fetch contents"
        case .metadataLookup: "Metadata lookup"
        case .runtimeLoading: "Runtime loading"
        case .driveDiscovery: "Drive discovery"
        case .domainManagement: "Domain management"
        case .shareLink: "Share link"
        case .versionRestore: "Version restore"
        default: kind.rawValue.capitalized
        }
    }

    private static func outcomeDescription(_ outcome: KDriveProviderActivityOutcome) -> String {
        switch outcome {
        case .success: "succeeded"
        case .failure: "failed"
        }
    }

    private static func isNewer(_ lhs: KDriveProviderTimelineEntry, _ rhs: KDriveProviderTimelineEntry) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        if lhs.cursor.kind != rhs.cursor.kind { return lhs.cursor.kind.rawValue > rhs.cursor.kind.rawValue }
        return lhs.cursor.eventID.uuidString > rhs.cursor.eventID.uuidString
    }

    private static func isEntry(_ entry: KDriveProviderTimelineEntry, before cursor: KDriveProviderTimelineCursor) -> Bool {
        if entry.date != cursor.date { return entry.date < cursor.date }
        if entry.cursor.kind != cursor.kind { return entry.cursor.kind.rawValue < cursor.kind.rawValue }
        return entry.cursor.eventID.uuidString < cursor.eventID.uuidString
    }

    private struct FileFingerprint: Equatable, Sendable {
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private nonisolated static func fileFingerprint(_ url: URL) -> FileFingerprint? {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return FileFingerprint(
            size: status.st_size,
            modifiedSeconds: status.st_mtimespec.tv_sec,
            modifiedNanoseconds: status.st_mtimespec.tv_nsec
        )
    }
}

private struct ReplayState {
    var activity: [UUID: KDriveProviderActivityEvent] = [:]
    var conflicts: [UUID: KDriveConflictEvent] = [:]
    var diagnostics: [UUID: ProviderDiagnosticEvent] = [:]

    mutating func apply(_ payload: JSONLRecord.Payload) {
        switch payload {
        case .activity(let event):
            activity[event.id] = event
        case .conflict(let event):
            conflicts[event.id] = event
        case .diagnostic(let event):
            diagnostics[event.id] = event
        case .removeDomain(let domainIdentifier):
            activity = activity.filter { $0.value.domainIdentifier != domainIdentifier }
            conflicts = conflicts.filter { $0.value.domainIdentifier != domainIdentifier }
        case .clearActivityAndResolvedConflicts(let domainIdentifier):
            activity = activity.filter { _, event in
                domainIdentifier != nil && event.domainIdentifier != domainIdentifier
            }
            conflicts = conflicts.filter { _, event in
                let matchesDomain = domainIdentifier == nil || event.domainIdentifier == domainIdentifier
                return matchesDomain == false || event.resolutionState != .automaticallyResolved
            }
        }
    }
}

private struct JSONLRecord: Codable {
    static let schemaVersion = 1

    enum Kind: String, Codable {
        case activity
        case conflict
        case diagnostic
        case removeDomain
        case clearActivityAndResolvedConflicts
    }

    enum Payload {
        case activity(KDriveProviderActivityEvent)
        case conflict(KDriveConflictEvent)
        case diagnostic(ProviderDiagnosticEvent)
        case removeDomain(String)
        case clearActivityAndResolvedConflicts(String?)
    }

    let schemaVersion: Int
    let kind: Kind
    let activity: KDriveProviderActivityEvent?
    let conflict: KDriveConflictEvent?
    let diagnostic: ProviderDiagnosticEvent?
    let domainIdentifier: String?

    init(payload: Payload) {
        self.schemaVersion = Self.schemaVersion
        switch payload {
        case .activity(let event):
            self.kind = .activity
            self.activity = event
            self.conflict = nil
            self.diagnostic = nil
            self.domainIdentifier = nil
        case .conflict(let event):
            self.kind = .conflict
            self.activity = nil
            self.conflict = event
            self.diagnostic = nil
            self.domainIdentifier = nil
        case .diagnostic(let event):
            self.kind = .diagnostic
            self.activity = nil
            self.conflict = nil
            self.diagnostic = event
            self.domainIdentifier = nil
        case .removeDomain(let domainIdentifier):
            self.kind = .removeDomain
            self.activity = nil
            self.conflict = nil
            self.diagnostic = nil
            self.domainIdentifier = domainIdentifier
        case .clearActivityAndResolvedConflicts(let domainIdentifier):
            self.kind = .clearActivityAndResolvedConflicts
            self.activity = nil
            self.conflict = nil
            self.diagnostic = nil
            self.domainIdentifier = domainIdentifier
        }
    }

    var payload: Payload {
        get throws {
            switch kind {
            case .activity:
                guard let activity else { throw ProviderDiagnosticStoreError.malformedRecord }
                return .activity(activity)
            case .conflict:
                guard let conflict else { throw ProviderDiagnosticStoreError.malformedRecord }
                return .conflict(conflict)
            case .diagnostic:
                guard let diagnostic else { throw ProviderDiagnosticStoreError.malformedRecord }
                return .diagnostic(diagnostic)
            case .removeDomain:
                guard let domainIdentifier else { throw ProviderDiagnosticStoreError.malformedRecord }
                return .removeDomain(domainIdentifier)
            case .clearActivityAndResolvedConflicts:
                return .clearActivityAndResolvedConflicts(domainIdentifier)
            }
        }
    }
}

private enum LockedJSONLFile {
    static func append(_ data: Data, to url: URL, maximumBytes: Int) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_APPEND | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
        defer { Darwin.close(descriptor) }
        try SecurePOSIXFile.requireRegularFile(descriptor)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        try truncateInterruptedTail(descriptor)
        let existingBytes = try SecurePOSIXFile.fileSize(descriptor)
        guard data.count <= maximumBytes,
              existingBytes <= maximumBytes - data.count else {
            throw ProviderDiagnosticStoreError.runCapacityExceeded
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: written), buffer.count - written)
                guard result > 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
    }

    private static func truncateInterruptedTail(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard status.st_size > 0 else { return }

        var finalByte: UInt8 = 0
        guard pread(descriptor, &finalByte, 1, status.st_size - 1) == 1 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard finalByte != 0x0A else { return }

        var scanEnd = status.st_size
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var retainedLength: off_t = 0
        while scanEnd > 0 {
            let count = Int(min(off_t(buffer.count), scanEnd))
            let offset = scanEnd - off_t(count)
            let readCount = pread(descriptor, &buffer, count, offset)
            guard readCount == count else {
                if readCount < 0, errno == EINTR { continue }
                throw ProviderDiagnosticStoreError.fileSystemError(errno)
            }
            if let newline = buffer[..<count].lastIndex(of: 0x0A) {
                retainedLength = offset + off_t(newline + 1)
                break
            }
            scanEnd = offset
        }
        guard ftruncate(descriptor, retainedLength) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
    }

    static func read(from url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
        defer { Darwin.close(descriptor) }
        try SecurePOSIXFile.requireRegularFile(descriptor)
        guard flock(descriptor, LOCK_SH) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try SecurePOSIXFile.read(descriptor, maximumBytes: maximumBytes)
    }
}

enum SecurePOSIXFile {
    enum PathKind: Equatable {
        case missing
        case regularFile
        case directory
        case other
    }

    static func pathKind(_ url: URL) -> PathKind {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return errno == ENOENT ? .missing : .other
        }
        switch status.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        default: return .other
        }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        pathKind(url) == .regularFile
    }

    static func ensureDirectory(_ url: URL) throws {
        let created = pathKind(url) == .missing
        if created {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard pathKind(url) == .directory else {
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        if created {
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    static func createDirectoryExclusively(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard pathKind(url) == .directory else {
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func createExclusively(_ data: Data, at url: URL, permissions: mode_t) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard descriptor >= 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
        defer { Darwin.close(descriptor) }
        try requireRegularFile(descriptor)
        guard fchmod(descriptor, permissions) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        try write(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func replaceAtomically(_ data: Data, at url: URL, permissions: mode_t) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
        do {
            try createExclusively(data, at: temporaryURL, permissions: permissions)
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw ProviderDiagnosticStoreError.fileSystemError(errno)
            }
            try synchronizeDirectory(url.deletingLastPathComponent())
        } catch {
            if pathKind(temporaryURL) == .regularFile {
                _ = unlink(temporaryURL.path)
            }
            throw error
        }
    }

    static func withLock<T>(at url: URL, operation: Int32, _ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
        defer { Darwin.close(descriptor) }
        try requireRegularFile(descriptor)
        guard fchmod(descriptor, 0o600) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard flock(descriptor, operation) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func withAsyncLock<T: Sendable>(
        at url: URL,
        operation: Int32,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
        defer { Darwin.close(descriptor) }
        try requireRegularFile(descriptor)
        guard fchmod(descriptor, 0o600) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard flock(descriptor, operation) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
        defer { Darwin.close(descriptor) }
        try requireRegularFile(descriptor)
        return try read(descriptor, maximumBytes: maximumBytes)
    }

    static func read(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard status.st_size >= 0, status.st_size <= off_t(max(0, maximumBytes)) else {
            throw ProviderDiagnosticStoreError.fileTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProviderDiagnosticStoreError.fileSystemError(errno)
            }
            guard data.count <= maximumBytes - count else {
                throw ProviderDiagnosticStoreError.fileTooLarge
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func requireRegularFile(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
    }

    static func fileSize(_ url: URL) throws -> Int {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
        return Int(status.st_size)
    }

    static func fileSize(_ descriptor: Int32) throws -> Int {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
        return Int(status.st_size)
    }

    static func removeRegularFile(_ url: URL) throws {
        guard pathKind(url) == .regularFile else {
            throw ProviderDiagnosticStoreError.unsafeFileType
        }
        guard unlink(url.path) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: written), buffer.count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
                written += result
            }
        }
    }
}

public enum ProviderEventStoreFactory {
    public static func activeFinderStepCorrelation(
        appGroupIdentifier: String = ProviderConstants.appGroupIdentifier
    ) throws -> UUID? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ProviderDiagnosticStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        return try StabilityRunLocator.activeFinderStepCorrelation(
            rootDirectoryURL: containerURL.appendingPathComponent("StabilityRuns", isDirectory: true)
        )
    }

    public static func makeDefault(
        profile: ProviderRuntimeProfile = .current,
        appGroupIdentifier: String = ProviderConstants.appGroupIdentifier
    ) throws -> (any KDriveProviderEventStoring)? {
        switch profile {
        case .standard:
            return try KDriveProviderEventSQLiteStore(appGroupIdentifier: appGroupIdentifier)
        case .stability:
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            ) else {
                throw ProviderDiagnosticStoreError.missingAppGroupContainer(appGroupIdentifier)
            }
            let root = containerURL.appendingPathComponent("StabilityRuns", isDirectory: true)
            guard let run = try StabilityRunLocator.activeRun(rootDirectoryURL: root) else { return nil }
            return try KDriveProviderEventJSONLStore(runDirectoryURL: run.directoryURL)
        }
    }

    public static func make(
        profile: ProviderRuntimeProfile,
        standardDatabaseURL: URL,
        stabilityRootDirectoryURL: URL
    ) throws -> (any KDriveProviderEventStoring)? {
        switch profile {
        case .standard:
            return try KDriveProviderEventSQLiteStore(databaseURL: standardDatabaseURL)
        case .stability:
            guard let run = try StabilityRunLocator.activeRun(rootDirectoryURL: stabilityRootDirectoryURL) else {
                return nil
            }
            return try KDriveProviderEventJSONLStore(runDirectoryURL: run.directoryURL)
        }
    }
}

public enum ProviderDiagnosticStoreError: Error, Equatable, LocalizedError, Sendable {
    case missingAppGroupContainer(String)
    case couldNotCreateEventFile
    case unsafeFileType
    case fileTooLarge
    case runCapacityExceeded
    case corruptRecord(line: Int)
    case unsupportedSchemaVersion(Int)
    case malformedRecord
    case invalidActiveRunPointer
    case runNotFound(UUID)
    case runAlreadyFinished(UUID)
    case runAlreadyActive
    case runOwnedByFinderRunner(UUID)
    case runAbandonedByFinderRunner(UUID)
    case finderOwnerProcessStillRunning
    case noStaleFinderRun
    case finderEvidenceAlreadyFinalized(UUID)
    case finderSummaryMismatch
    case finderStepAlreadyActive
    case finderStepCorrelationMismatch
    case fileSystemError(Int32)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer(let identifier):
            "The shared app-group container '\(identifier)' is unavailable."
        case .couldNotCreateEventFile:
            "The Stability event file could not be created."
        case .unsafeFileType:
            "A Stability run path is not a regular file or directory."
        case .fileTooLarge:
            "A Stability run file exceeds the supported size limit."
        case .runCapacityExceeded:
            "The active Stability event file reached its configured capacity. Finish the run before recording more evidence."
        case .corruptRecord(let line):
            "The Stability event stream is corrupt at complete line \(line)."
        case .unsupportedSchemaVersion(let version):
            "The Stability event stream uses unsupported schema version \(version)."
        case .malformedRecord:
            "The Stability event stream contains a malformed record."
        case .invalidActiveRunPointer:
            "The active Stability run pointer is stale or invalid."
        case .runNotFound:
            "The Stability run does not exist."
        case .runAlreadyFinished:
            "The Stability run is already complete."
        case .runAlreadyActive:
            "A Stability run is active."
        case .runOwnedByFinderRunner:
            "The active Stability run is owned by the Finder runner."
        case .runAbandonedByFinderRunner:
            "The Stability run was abandoned by the Finder runner and cannot be finalized."
        case .finderOwnerProcessStillRunning:
            "The Stability Finder run owner process is still running."
        case .noStaleFinderRun:
            "There is no stale Stability Finder run to recover."
        case .finderEvidenceAlreadyFinalized:
            "The Stability Finder evidence is already finalized."
        case .finderSummaryMismatch:
            "The Stability Finder summary does not match its immutable report."
        case .finderStepAlreadyActive:
            "A Stability Finder step is already active."
        case .finderStepCorrelationMismatch:
            "The active Stability Finder step correlation does not match."
        case .fileSystemError(let code):
            "The Stability event file operation failed with errno \(code)."
        }
    }
}
