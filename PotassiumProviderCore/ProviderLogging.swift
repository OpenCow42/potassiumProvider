import Foundation
import OSLog

public enum ProviderLogCategory: String, CaseIterable, Sendable {
    case app
    case authentication
    case domain
    case runtime
    case fileProvider = "file-provider"
    case enumeration
    case mutation
    case network
    case persistence
    case conflict
    case thumbnail
    case export
}

public enum ProviderLog {
    public static let app = logger(.app)
    public static let authentication = logger(.authentication)
    public static let domain = logger(.domain)
    public static let runtime = logger(.runtime)
    public static let fileProvider = logger(.fileProvider)
    public static let enumeration = logger(.enumeration)
    public static let mutation = logger(.mutation)
    public static let network = logger(.network)
    public static let persistence = logger(.persistence)
    public static let conflict = logger(.conflict)
    public static let thumbnail = logger(.thumbnail)
    public static let export = logger(.export)

    public static func logger(_ category: ProviderLogCategory) -> Logger {
        Logger(subsystem: ProviderConstants.logSubsystem, category: category.rawValue)
    }
}

public struct ProviderLogContext: Codable, Equatable, Sendable {
    public var correlationID: String
    public var scope: KDriveProviderActivityScope
    public var domainIdentifier: String?
    public var driveID: Int?
    public var operation: String
    public var itemIdentifier: String?
    public var containerIdentifier: String?
    public var startedAt: Date

    public init(
        correlationID: String = UUID().uuidString,
        scope: KDriveProviderActivityScope,
        domainIdentifier: String? = nil,
        driveID: Int? = nil,
        operation: String,
        itemIdentifier: String? = nil,
        containerIdentifier: String? = nil,
        startedAt: Date = Date()
    ) {
        self.correlationID = correlationID
        self.scope = scope
        self.domainIdentifier = domainIdentifier
        self.driveID = driveID
        self.operation = operation
        self.itemIdentifier = itemIdentifier
        self.containerIdentifier = containerIdentifier
        self.startedAt = startedAt
    }

    public func durationMilliseconds(endedAt: Date = Date()) -> Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000))
    }
}

public protocol ProviderLogClock: Sendable {
    func now() -> Date
}

public struct SystemProviderLogClock: ProviderLogClock {
    public init() {}

    public func now() -> Date {
        Date()
    }
}
