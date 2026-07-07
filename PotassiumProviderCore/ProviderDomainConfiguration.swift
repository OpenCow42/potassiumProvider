import Foundation

public enum ProviderAccountAuthenticationKind: String, Codable, Equatable, Sendable {
    case oauth
    case manualAccessToken
}

public struct ProviderAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: String { accountIdentifier }

    public let accountIdentifier: String
    public var displayName: String
    public var authenticationKind: ProviderAccountAuthenticationKind
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        accountIdentifier: String = UUID().uuidString,
        displayName: String,
        authenticationKind: ProviderAccountAuthenticationKind,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.accountIdentifier = accountIdentifier
        self.displayName = displayName
        self.authenticationKind = authenticationKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    @discardableResult
    public mutating func updateDisplayName(_ newDisplayName: String, updatedAt: Date = Date()) -> Bool {
        let trimmedDisplayName = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = trimmedDisplayName.isEmpty ? "Account" : trimmedDisplayName
        guard displayName != normalizedDisplayName else {
            return false
        }

        displayName = normalizedDisplayName
        self.updatedAt = updatedAt
        return true
    }
}

public protocol ProviderAccountStoring: Sendable {
    func allAccounts() async throws -> [ProviderAccount]
    func account(accountIdentifier: String) async throws -> ProviderAccount?
    func save(_ account: ProviderAccount) async throws
    func remove(accountIdentifier: String) async throws
}

public actor ProviderAccountFileStore: ProviderAccountStoring {
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
            throw ProviderAccountStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        self.init(directoryURL: containerURL.appendingPathComponent("Accounts", isDirectory: true))
    }

    public func allAccounts() throws -> [ProviderAccount] {
        try ensureDirectoryExists()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return try urls
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(ProviderAccount.self, from: Data(contentsOf: $0)) }
            .sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    public func account(accountIdentifier: String) throws -> ProviderAccount? {
        let url = fileURL(for: accountIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ProviderAccount.self, from: Data(contentsOf: url))
    }

    public func save(_ account: ProviderAccount) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(account)
        try data.write(to: fileURL(for: account.accountIdentifier), options: [.atomic])
    }

    public func remove(accountIdentifier: String) throws {
        let url = fileURL(for: accountIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for accountIdentifier: String) -> URL {
        directoryURL.appendingPathComponent(Self.safeFileName(for: accountIdentifier)).appendingPathExtension("json")
    }

    private static func safeFileName(for value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }.reduce(into: "") { $0.append($1) }
    }
}

public enum ProviderAccountStoreError: Error, Equatable, LocalizedError, Sendable {
    case missingAppGroupContainer(String)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer(let identifier):
            return "The shared app group container '\(identifier)' is not available."
        }
    }
}

public struct ProviderDomainConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String { domainIdentifier }

    public let domainIdentifier: String
    public var accountIdentifier: String
    public var displayName: String
    public var driveID: Int
    public var driveName: String
    public var rootFileID: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        domainIdentifier: String = UUID().uuidString,
        accountIdentifier: String = ProviderConstants.legacyAccountIdentifier,
        displayName: String,
        driveID: Int,
        driveName: String,
        rootFileID: Int = ProviderConstants.defaultRootFileID,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.domainIdentifier = domainIdentifier
        self.accountIdentifier = accountIdentifier
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

    private enum CodingKeys: String, CodingKey {
        case domainIdentifier
        case accountIdentifier
        case displayName
        case driveID
        case driveName
        case rootFileID
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domainIdentifier = try container.decode(String.self, forKey: .domainIdentifier)
        accountIdentifier = try container.decodeIfPresent(String.self, forKey: .accountIdentifier)
            ?? ProviderConstants.legacyAccountIdentifier
        displayName = try container.decode(String.self, forKey: .displayName)
        driveID = try container.decode(Int.self, forKey: .driveID)
        driveName = try container.decode(String.self, forKey: .driveName)
        rootFileID = try container.decodeIfPresent(Int.self, forKey: .rootFileID)
            ?? ProviderConstants.defaultRootFileID
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
