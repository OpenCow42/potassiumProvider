import Darwin
import FileProvider
import Foundation
@preconcurrency import SQLite

/// Propagates a privacy-safe correlation identifier through structured tasks.
///
/// The value is deliberately limited to a UUID. Nested diagnostics can be
/// correlated without carrying item identifiers, paths, URLs, or other private
/// request context through the logging API.
public enum ProviderDiagnosticCorrelationContext {
    @TaskLocal public static var current: UUID?
    @TaskLocal public static var parentSpanID: UUID?
    @TaskLocal public static var subjectAlias: UUID?

    public static func withCorrelation<Result: Sendable>(
        _ correlationID: UUID,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await $current.withValue(correlationID, operation: operation)
    }
}

/// Classifies only stable error categories. Error descriptions, domains, and
/// user-info values are never copied into a diagnostic event.
public enum ProviderDiagnosticErrorClassifier {
    public static func classify(_ error: any Error) -> ProviderDiagnosticErrorClass {
        classifyOriginal(originalError(error))
    }

    private static func classifyOriginal(_ error: any Error) -> ProviderDiagnosticErrorClass {
        if error is CancellationError {
            return .cancellation
        }

        if sqliteCode(error) != nil || error is DomainConfigurationStoreError { return .storage }
        if error is DecodingError { return .validation }

        if let snapshotError = error as? KDriveSnapshotStoreError {
            switch snapshotError {
            case .staleSnapshot: return .concurrentSnapshot
            case .expiredGeneration, .invalidPageToken: return .invalidCursor
            case .missingAppGroupContainer: return .storage
            }
        }

        if let rejection = KDriveRemoteErrorClassifier.apiRejection(from: error) {
            switch rejection.statusCode {
            case 401: return .authentication
            case 403: return .permission
            case 404: return .notFound
            case 408, 429: return .network
            case 409, 412: return .conflict
            case 422: return .validation
            case 507: return .quota
            case 500...599: return .server
            default: return .unknown
            }
        }

        if error is KDriveMutationConflictError {
            return .conflict
        }

        if error is KDriveDirectUploadError {
            return .validation
        }

        let cocoaError = error as NSError
        if cocoaError.domain == NSFileProviderErrorDomain,
           let code = NSFileProviderError.Code(rawValue: cocoaError.code) {
            return classifyFileProviderCode(code)
        }
        switch cocoaError.domain {
        case NSURLErrorDomain:
            return classifyURLCode(cocoaError.code)
        case NSCocoaErrorDomain:
            return classifyCocoaCode(cocoaError.code)
        case NSPOSIXErrorDomain:
            return classifyPOSIXCode(cocoaError.code)
        default:
            return .unknown
        }
    }

    /// Our fallback mapping wraps an otherwise unknown error as XPC reply
    /// invalid. Inspect only that bounded cause chain; never retain user-info.
    fileprivate static func originalError(_ error: any Error) -> any Error {
        var result = error
        for _ in 0..<4 {
            let value = result as NSError
            guard value.domain == NSCocoaErrorDomain, value.code == NSXPCConnectionReplyInvalid,
                  let underlying = value.userInfo[NSUnderlyingErrorKey] as? any Error else { break }
            result = underlying
        }
        return result
    }

    fileprivate static func sqliteCode(_ error: any Error) -> Int? {
        guard let result = error as? SQLite.Result else { return nil }
        switch result {
        case .error(_, let code, _): return Int(code)
        case .extendedError(_, let code, _): return Int(code)
        }
    }

    private static func classifyFileProviderCode(
        _ code: NSFileProviderError.Code
    ) -> ProviderDiagnosticErrorClass {
        switch code {
        case .notAuthenticated:
            return .authentication
        case .filenameCollision, .localVersionConflictingWithServer:
            return .conflict
        case .syncAnchorExpired:
            return .invalidCursor
        case .insufficientQuota:
            return .quota
        case .serverUnreachable, .providerDomainTemporarilyUnavailable:
            return .network
        case .noSuchItem, .providerDomainNotFound, .versionNoLongerAvailable:
            return .notFound
        case .deletionRejected, .directoryNotEmpty, .excludedFromSync,
             .domainDisabled, .nonEvictable, .nonEvictableChildren,
             .unsyncedEdits:
            return .permission
        case .cannotSynchronize, .providerNotFound, .providerTranslocated,
             .olderExtensionVersionRunning, .newerExtensionVersionFound,
             .applicationExtensionNotFound:
            return .synchronization
        @unknown default:
            return .unknown
        }
    }

    private static func classifyURLCode(_ rawCode: Int) -> ProviderDiagnosticErrorClass {
        switch URLError.Code(rawValue: rawCode) {
        case .cancelled, .userCancelledAuthentication:
            return .cancellation
        case .userAuthenticationRequired:
            return .authentication
        case .fileDoesNotExist:
            return .notFound
        case .noPermissionsToReadFile:
            return .permission
        case .badURL, .unsupportedURL:
            return .validation
        default:
            // A recognized URL-loading domain is safe to classify broadly as
            // network failure without retaining its URL or response details.
            return .network
        }
    }

    private static func classifyCocoaCode(_ code: Int) -> ProviderDiagnosticErrorClass {
        switch code {
        case NSUserCancelledError:
            return .cancellation
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .notFound
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .permission
        case NSFileWriteOutOfSpaceError:
            return .storage
        default:
            return .unknown
        }
    }

    private static func classifyPOSIXCode(_ code: Int) -> ProviderDiagnosticErrorClass {
        if code == Int(ECANCELED) {
            return .cancellation
        }
        if code == Int(ENOENT) {
            return .notFound
        }
        if code == Int(EACCES) || code == Int(EPERM) {
            return .permission
        }
        if code == Int(ENOSPC) || code == Int(EDQUOT) {
            return .storage
        }
        if code == Int(EINVAL) {
            return .validation
        }
        return .unknown
    }
}

/// Converts File Provider's option set to a closed, value-free diagnostic
/// shape. The caller supplies only whether a parent change targets the virtual
/// trash container; no item identifier is retained.
public enum ProviderDiagnosticFieldClassifier {
    public static func classify(
        _ fields: NSFileProviderItemFields,
        isTrashDestination: Bool = false
    ) -> [ProviderDiagnosticField] {
        var result: [ProviderDiagnosticField] = []
        if fields.contains(.contents) { result.append(.contents) }
        if fields.contains(.filename) { result.append(.filename) }
        if fields.contains(.parentItemIdentifier) {
            result.append(.parent)
            if isTrashDestination { result.append(.trash) }
        }
        if fields.contains(.lastUsedDate) { result.append(.lastUsedDate) }
        if fields.contains(.tagData) { result.append(.tagData) }
        if fields.contains(.favoriteRank) { result.append(.favoriteRank) }
        if fields.contains(.creationDate) { result.append(.creationDate) }
        if fields.contains(.contentModificationDate) {
            result.append(.contentModificationDate)
        }
        if fields.contains(.fileSystemFlags) { result.append(.fileSystemFlags) }
        if fields.contains(.extendedAttributes) { result.append(.extendedAttributes) }
        if fields.contains(.typeAndCreator) { result.append(.typeAndCreator) }
        return result
    }
}

/// A concurrency-safe diagnostic lifecycle shared by callback and network
/// instrumentation.
///
/// Construction is intentionally asynchronous so the `.started` event is
/// attempted exactly once before the span is returned. Recording is
/// best-effort: a missing, unavailable, or failed diagnostic sink never changes
/// provider behavior. Actor isolation makes the first terminal call win even
/// when completion, failure, and cancellation race.
public actor ProviderDiagnosticSpan {
    /// Prevents corrupt or implausibly large elapsed values from entering a run
    /// bundle if a span survives an unusually long process lifetime.
    public static let maximumDurationMilliseconds = 7 * 24 * 60 * 60 * 1_000

    /// Progress is deliberately coarse so diagnostics capture behavior rather
    /// than byte counts or other workload-specific values.
    public static let progressBucketWidth = 10

    public nonisolated let correlationID: UUID
    public nonisolated let spanID: UUID
    public nonisolated let parentSpanID: UUID?
    public nonisolated let subjectAlias: UUID?
    public nonisolated let source: ProviderDiagnosticSource
    public nonisolated let operation: ProviderDiagnosticOperation
    public nonisolated let fieldShape: [ProviderDiagnosticField]
    public nonisolated let routeTemplate: ProviderDiagnosticRouteTemplate?
    public nonisolated let optionShape: [ProviderDiagnosticOption]
    public nonisolated let startedAt: Date

    private let recorder: (any ProviderDiagnosticRecording)?
    private let clock: ContinuousClock
    private let startedInstant: ContinuousClock.Instant
    private var startedWasEmitted = false
    private var terminalWasEmitted = false
    private var lastProgressPercentBucket: Int?

    private init(
        correlationID: UUID,
        subjectAlias: UUID?,
        source: ProviderDiagnosticSource,
        operation: ProviderDiagnosticOperation,
        fieldShape: [ProviderDiagnosticField],
        routeTemplate: ProviderDiagnosticRouteTemplate?,
        optionShape: [ProviderDiagnosticOption],
        startedAt: Date,
        recorder: (any ProviderDiagnosticRecording)?
    ) {
        self.correlationID = correlationID
        self.spanID = UUID()
        self.parentSpanID = ProviderDiagnosticCorrelationContext.parentSpanID
        self.subjectAlias = subjectAlias
        self.source = source
        self.operation = operation
        self.fieldShape = Array(Set(fieldShape)).sorted { $0.rawValue < $1.rawValue }
        self.routeTemplate = routeTemplate
        self.optionShape = Array(Set(optionShape)).sorted { $0.rawValue < $1.rawValue }
        self.startedAt = startedAt
        self.recorder = recorder
        let clock = ContinuousClock()
        self.clock = clock
        self.startedInstant = clock.now
    }

    public static func start(
        correlationID: UUID? = nil,
        itemIdentifier: String? = nil,
        source: ProviderDiagnosticSource,
        operation: ProviderDiagnosticOperation,
        fieldShape: [ProviderDiagnosticField] = [],
        routeTemplate: ProviderDiagnosticRouteTemplate? = nil,
        optionShape: [ProviderDiagnosticOption] = [],
        recorder: (any ProviderDiagnosticRecording)? = nil
    ) async -> ProviderDiagnosticSpan {
        let inheritedCorrelationID: UUID?
        if let taskCorrelationID = ProviderDiagnosticCorrelationContext.current {
            inheritedCorrelationID = taskCorrelationID
        } else {
            #if STABILITY
            inheritedCorrelationID = try? ProviderEventStoreFactory.activeFinderStepCorrelation()
            #else
            inheritedCorrelationID = nil
            #endif
        }
        let span = ProviderDiagnosticSpan(
            correlationID: correlationID ?? inheritedCorrelationID ?? UUID(),
            subjectAlias: StabilityDiagnosticIdentity.activeAlias(for: itemIdentifier) ?? ProviderDiagnosticCorrelationContext.subjectAlias,
            source: source,
            operation: operation,
            fieldShape: fieldShape,
            routeTemplate: routeTemplate,
            optionShape: optionShape,
            startedAt: Date(),
            recorder: recorder
        )
        await span.emitStarted()
        return span
    }

    /// Runs nested work with this span's correlation identifier. A nested span
    /// that does not specify an identifier inherits it automatically.
    public nonisolated func withCorrelation<Result: Sendable>(
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await ProviderDiagnosticCorrelationContext.$parentSpanID.withValue(spanID) {
            try await ProviderDiagnosticCorrelationContext.$subjectAlias.withValue(subjectAlias) {
                try await ProviderDiagnosticCorrelationContext.withCorrelation(correlationID, operation: operation)
            }
        }
    }

    public func progress(fractionCompleted: Double) async {
        guard terminalWasEmitted == false else { return }
        let bucket = Self.progressBucket(for: fractionCompleted)
        guard bucket != lastProgressPercentBucket else { return }
        lastProgressPercentBucket = bucket
        await emit(
            phase: .progress,
            durationMilliseconds: elapsedMilliseconds(),
            progressPercentBucket: bucket
        )
    }

    public func checkpoint(
        hasCursor: Bool? = nil,
        hasMore: Bool? = nil,
        hasAnchor: Bool? = nil,
        errorClass: ProviderDiagnosticErrorClass? = nil
    ) async {
        guard terminalWasEmitted == false else { return }
        await emit(
            phase: .checkpoint,
            errorClass: errorClass,
            durationMilliseconds: elapsedMilliseconds(),
            hasCursor: hasCursor,
            hasMore: hasMore,
            hasAnchor: hasAnchor
        )
    }

    public func complete(
        statusClass: ProviderDiagnosticStatusClass? = nil,
        hasCursor: Bool? = nil,
        hasMore: Bool? = nil,
        hasAnchor: Bool? = nil,
        itemMetadataAlias: UUID? = nil
    ) async {
        guard beginTerminalEmission() else { return }
        await emit(
            phase: .completed,
            itemMetadataAlias: itemMetadataAlias,
            statusClass: statusClass,
            durationMilliseconds: elapsedMilliseconds(),
            progressPercentBucket: 100,
            hasCursor: hasCursor,
            hasMore: hasMore,
            hasAnchor: hasAnchor
        )
    }

    public func fail(
        error: any Error,
        statusClass: ProviderDiagnosticStatusClass? = nil
    ) async {
        guard beginTerminalEmission() else { return }
        await emit(
            phase: .failed,
            statusClass: statusClass,
            errorClass: ProviderDiagnosticErrorClassifier.classify(error),
            errorCode: Self.safeCode(error),
            validationFields: ProviderDiagnosticValidationField.classify(error),
            durationMilliseconds: elapsedMilliseconds()
        )
    }

    public func cancel() async {
        guard beginTerminalEmission() else { return }
        await emit(
            phase: .cancelled,
            errorClass: .cancellation,
            durationMilliseconds: elapsedMilliseconds()
        )
    }

    private func emitStarted() async {
        guard startedWasEmitted == false else { return }
        startedWasEmitted = true
        await emit(phase: .started, occurredAt: startedAt)
    }

    private func beginTerminalEmission() -> Bool {
        guard terminalWasEmitted == false else { return false }
        terminalWasEmitted = true
        return true
    }

    private func emit(
        phase: ProviderDiagnosticPhase,
        itemMetadataAlias: UUID? = nil,
        occurredAt: Date = Date(),
        statusClass: ProviderDiagnosticStatusClass? = nil,
        errorClass: ProviderDiagnosticErrorClass? = nil,
        errorCode: Int? = nil,
        validationFields: [ProviderDiagnosticValidationField]? = nil,
        durationMilliseconds: Int? = nil,
        progressPercentBucket: Int? = nil,
        hasCursor: Bool? = nil,
        hasMore: Bool? = nil,
        hasAnchor: Bool? = nil
    ) async {
        guard let recorder else { return }
        let event = ProviderDiagnosticEvent(
            occurredAt: occurredAt,
            spanID: spanID,
            parentSpanID: parentSpanID,
            subjectAlias: subjectAlias,
            itemMetadataAlias: itemMetadataAlias,
            processInstanceID: StabilityDiagnosticIdentity.processInstanceID,
            processCodeHash: StabilityDiagnosticIdentity.processCodeHash,
            errorCode: errorCode,
            validationFields: validationFields,
            correlationID: correlationID,
            source: source,
            operation: operation,
            phase: phase,
            fieldShape: fieldShape,
            routeTemplate: routeTemplate,
            optionShape: optionShape,
            statusClass: statusClass,
            errorClass: errorClass,
            durationMilliseconds: durationMilliseconds,
            progressPercentBucket: progressPercentBucket,
            hasCursor: hasCursor,
            hasMore: hasMore,
            hasAnchor: hasAnchor
        )
        do {
            try await recorder.recordDiagnostic(event)
        } catch {
            // Diagnostics are evidence, never part of callback or API success.
        }
    }

    private static func safeCode(_ error: any Error) -> Int? {
        let original = ProviderDiagnosticErrorClassifier.originalError(error)
        if let code = ProviderDiagnosticErrorClassifier.sqliteCode(original) { return code }
        if let rejection = KDriveRemoteErrorClassifier.apiRejection(from: original) { return rejection.statusCode }
        let value = original as NSError
        return [NSFileProviderErrorDomain, NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(value.domain) ? value.code : nil
    }

    private func elapsedMilliseconds() -> Int {
        let components = startedInstant.duration(to: clock.now).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        guard milliseconds.isFinite else {
            return Self.maximumDurationMilliseconds
        }
        return Int(min(
            Double(Self.maximumDurationMilliseconds),
            max(0, milliseconds.rounded(.down))
        ))
    }

    private static func progressBucket(for fractionCompleted: Double) -> Int {
        guard fractionCompleted.isFinite else { return 0 }
        let boundedFraction = min(1, max(0, fractionCompleted))
        let percent = Int((boundedFraction * 100).rounded(.down))
        guard percent < 100 else { return 100 }
        return (percent / progressBucketWidth) * progressBucketWidth
    }
}
