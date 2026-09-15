import Foundation

/// Durable progress for a remove-and-recreate File Provider storage transition.
///
/// File Provider does not provide an in-place domain move API. Keeping this journal in
/// the app group lets the containing app distinguish an unavailable external volume
/// from an interrupted transition and offer a deterministic repair path after relaunch.
public struct ProviderDomainRelocationJournal: Codable, Equatable, Identifiable, Sendable {
    public var id: String { configurationIdentifier }

    public let configurationIdentifier: String
    public var sourceConfiguration: ProviderDomainConfiguration
    public var targetStorageLocation: ProviderDomainStorageLocation
    public var targetDomainIdentifier: String?
    public var knownFoldersWereActive: Bool
    public var phase: ProviderDomainRelocationPhase
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        configurationIdentifier: String,
        sourceConfiguration: ProviderDomainConfiguration,
        targetStorageLocation: ProviderDomainStorageLocation,
        targetDomainIdentifier: String? = nil,
        knownFoldersWereActive: Bool,
        phase: ProviderDomainRelocationPhase = .preparing,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.configurationIdentifier = configurationIdentifier
        self.sourceConfiguration = sourceConfiguration
        self.targetStorageLocation = targetStorageLocation
        self.targetDomainIdentifier = targetDomainIdentifier
        self.knownFoldersWereActive = knownFoldersWereActive
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ProviderDomainRelocationPhase: String, Codable, Equatable, Sendable {
    case preparing
    case knownFoldersReleased
    case sourceRemoved
    case targetConfigurationSaved
    case targetRegistered
    case knownFolderReclaimRequired
    case needsRepair
}

public protocol ProviderDomainRelocationJournaling: Sendable {
    func allJournals() async throws -> [ProviderDomainRelocationJournal]
    func journal(configurationIdentifier: String) async throws -> ProviderDomainRelocationJournal?
    func save(_ journal: ProviderDomainRelocationJournal) async throws
    func remove(configurationIdentifier: String) async throws
}

public actor ProviderDomainRelocationFileStore: ProviderDomainRelocationJournaling {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public init(appGroupIdentifier: String = ProviderConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ProviderDomainRelocationStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        self.init(directoryURL: containerURL.appendingPathComponent("DomainRelocations", isDirectory: true))
    }

    public func allJournals() throws -> [ProviderDomainRelocationJournal] {
        try ensureDirectoryExists()
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { try decoder.decode(ProviderDomainRelocationJournal.self, from: Data(contentsOf: $0)) }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func journal(configurationIdentifier: String) throws -> ProviderDomainRelocationJournal? {
        let url = fileURL(for: configurationIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ProviderDomainRelocationJournal.self, from: Data(contentsOf: url))
    }

    public func save(_ journal: ProviderDomainRelocationJournal) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(journal)
        try data.write(to: fileURL(for: journal.configurationIdentifier), options: [.atomic])
    }

    public func remove(configurationIdentifier: String) throws {
        let url = fileURL(for: configurationIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for configurationIdentifier: String) -> URL {
        directoryURL
            .appendingPathComponent(Self.safeFileName(for: configurationIdentifier))
            .appendingPathExtension("json")
    }

    private static func safeFileName(for value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }.reduce(into: "") { $0.append($1) }
    }
}

public enum ProviderDomainRelocationStoreError: Error, Equatable, LocalizedError, Sendable {
    case missingAppGroupContainer(String)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer(let identifier):
            return "The shared app group container '\(identifier)' is not available."
        }
    }
}
