import CryptoKit
import Foundation

public protocol KDriveProviderEventExporting: Sendable {
    func supportLogData(domainIdentifier: String?) async throws -> Data
}

public struct KDriveProviderSupportLog: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let activity: [Activity]
    public let conflicts: [Conflict]

    public init(
        exportedAt: Date = Date(),
        activity: [KDriveProviderActivityEvent],
        conflicts: [KDriveConflictEvent],
        redactionSalt: String = UUID().uuidString
    ) {
        let redactor = ProviderSupportLogRedactor(salt: redactionSalt)
        self.schemaVersion = Self.schemaVersion
        self.exportedAt = exportedAt
        self.activity = activity.map { Activity(event: $0, redactor: redactor) }
        self.conflicts = conflicts.map { Conflict(event: $0, redactor: redactor) }
    }

    public struct Activity: Codable, Equatable, Sendable {
        public let occurredAt: Date
        public let correlationID: String?
        public let scope: KDriveProviderActivityScope
        public let kind: KDriveProviderActivityKind
        public let outcome: KDriveProviderActivityOutcome
        public let severity: KDriveProviderActivitySeverity
        public let domain: String
        public let drive: String
        public let item: String?
        public let summary: String
        public let errorCategory: KDriveProviderActivityErrorCategory?
        public let providerErrorCode: Int?
        public let underlyingErrorDomain: String?
        public let underlyingErrorCode: Int?
        public let recoverySuggestion: String?
        public let diagnosticSummary: String?
        public let durationMilliseconds: Int?
        public let networkOperation: String?
        public let httpStatusCode: Int?
        public let remoteRequestID: String?

        fileprivate init(event: KDriveProviderActivityEvent, redactor: ProviderSupportLogRedactor) {
            occurredAt = event.occurredAt
            correlationID = event.correlationID.map { redactor.label("correlation", value: $0) }
            scope = event.scope
            kind = event.kind
            outcome = event.outcome
            severity = event.severity
            domain = redactor.label("domain", value: event.domainIdentifier)
            drive = redactor.label("drive", value: String(event.driveID))
            item = event.itemIdentifier.map { redactor.label("item", value: $0) }
            summary = redactor.summary(event.summary, sensitiveValues: [event.itemIdentifier, event.itemName, event.itemPath])
            errorCategory = event.errorCategory
            providerErrorCode = event.providerErrorCode
            underlyingErrorDomain = event.underlyingErrorDomain
            underlyingErrorCode = event.underlyingErrorCode
            recoverySuggestion = event.recoverySuggestion.map { redactor.summary($0, sensitiveValues: [event.itemName, event.itemPath]) }
            diagnosticSummary = event.diagnosticSummary.map { redactor.summary($0, sensitiveValues: [event.itemName, event.itemPath]) }
            durationMilliseconds = event.durationMilliseconds
            networkOperation = event.networkOperation
            httpStatusCode = event.httpStatusCode
            remoteRequestID = event.remoteRequestID.map { redactor.label("request", value: $0) }
        }
    }

    public struct Conflict: Codable, Equatable, Sendable {
        public let detectedAt: Date
        public let resolvedAt: Date?
        public let domain: String
        public let drive: String
        public let operation: KDriveProviderActivityKind
        public let resolutionState: KDriveConflictResolutionState
        public let automaticallyResolved: Bool
        public let resolutionKind: KDriveConflictResolutionKind?
        public let resolutionSummary: String

        fileprivate init(event: KDriveConflictEvent, redactor: ProviderSupportLogRedactor) {
            detectedAt = event.detectedAt
            resolvedAt = event.resolvedAt
            domain = redactor.label("domain", value: event.domainIdentifier)
            drive = redactor.label("drive", value: String(event.driveID))
            operation = event.operation
            resolutionState = event.resolutionState
            automaticallyResolved = event.automaticallyResolved
            resolutionKind = event.resolutionKind
            resolutionSummary = redactor.summary(
                event.resolutionSummary,
                sensitiveValues: [
                    event.originalItemIdentifier,
                    event.originalItemName,
                    event.originalItemPath,
                    event.conflictItemIdentifier,
                    event.conflictItemName,
                    event.conflictItemPath,
                    event.stagedUploadRelativePath,
                ]
            )
        }
    }
}

private struct ProviderSupportLogRedactor: Sendable {
    let salt: String

    func label(_ type: String, value: String) -> String {
        let input = Data("\(salt):\(type):\(value)".utf8)
        let digest = SHA256.hash(data: input)
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(type)-\(suffix)"
    }

    func summary(_ text: String, sensitiveValues: [String?]) -> String {
        var redacted = text
        for value in sensitiveValues.compactMap({ $0 }).filter({ $0.isEmpty == false }).sorted(by: { $0.count > $1.count }) {
            redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
        }
        redacted = redacted.replacingOccurrences(
            of: #"https?://[^\s]+"#,
            with: "<redacted-url>",
            options: .regularExpression
        )
        return redacted.replacingOccurrences(
            of: #"/(?:[^\s/]+/)*[^\s/]+"#,
            with: "<redacted-path>",
            options: .regularExpression
        )
    }
}
