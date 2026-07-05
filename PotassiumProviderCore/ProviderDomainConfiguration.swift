import Foundation

public struct ProviderDomainConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String { domainIdentifier }

    public let domainIdentifier: String
    public var displayName: String
    public var driveID: Int
    public var driveName: String
    public var rootFileID: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        domainIdentifier: String = UUID().uuidString,
        displayName: String,
        driveID: Int,
        driveName: String,
        rootFileID: Int = ProviderConstants.defaultRootFileID,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.domainIdentifier = domainIdentifier
        self.displayName = displayName
        self.driveID = driveID
        self.driveName = driveName
        self.rootFileID = rootFileID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func finderDisplayName(forDriveName driveName: String) -> String {
        let trimmedDriveName = driveName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDriveName.isEmpty ? "kDrive" : trimmedDriveName
    }

    @discardableResult
    public mutating func normalizeFinderDisplayName(updatedAt: Date = Date()) -> Bool {
        let normalizedDisplayName = Self.finderDisplayName(forDriveName: driveName)
        guard displayName != normalizedDisplayName else {
            return false
        }

        displayName = normalizedDisplayName
        self.updatedAt = updatedAt
        return true
    }
}

public protocol DomainConfigurationStoring: Sendable {
    func allConfigurations() async throws -> [ProviderDomainConfiguration]
    func configuration(domainIdentifier: String) async throws -> ProviderDomainConfiguration?
    func save(_ configuration: ProviderDomainConfiguration) async throws
    func remove(domainIdentifier: String) async throws
}

public actor DomainConfigurationFileStore: DomainConfigurationStoring {
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
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw DomainConfigurationStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        self.init(directoryURL: containerURL.appendingPathComponent("DomainConfigurations", isDirectory: true))
    }

    public func allConfigurations() throws -> [ProviderDomainConfiguration] {
        try ensureDirectoryExists()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return try urls
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(ProviderDomainConfiguration.self, from: Data(contentsOf: $0)) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func configuration(domainIdentifier: String) throws -> ProviderDomainConfiguration? {
        let url = fileURL(for: domainIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ProviderDomainConfiguration.self, from: Data(contentsOf: url))
    }

    public func save(_ configuration: ProviderDomainConfiguration) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(configuration)
        try data.write(to: fileURL(for: configuration.domainIdentifier), options: [.atomic])
    }

    public func remove(domainIdentifier: String) throws {
        let url = fileURL(for: domainIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for domainIdentifier: String) -> URL {
        directoryURL.appendingPathComponent(Self.safeFileName(for: domainIdentifier)).appendingPathExtension("json")
    }

    private static func safeFileName(for value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }.reduce(into: "") { $0.append($1) }
    }
}

public enum DomainConfigurationStoreError: Error, Equatable, LocalizedError, Sendable {
    case missingAppGroupContainer(String)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer(let identifier):
            return "The shared app group container '\(identifier)' is not available."
        }
    }
}
