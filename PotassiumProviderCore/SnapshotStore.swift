import Foundation

public protocol KDriveSnapshotStoring: Sendable {
    func snapshot(domainIdentifier: String, containerIdentifier: String) throws -> KDriveSnapshot?
    func save(_ snapshot: KDriveSnapshot, domainIdentifier: String, containerIdentifier: String) throws
    func removeSnapshots(domainIdentifier: String) throws
}

public final class KDriveSnapshotFileStore: KDriveSnapshotStoring, @unchecked Sendable {
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

    public convenience init(appGroupIdentifier: String = ProviderConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw KDriveSnapshotStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        self.init(directoryURL: containerURL.appendingPathComponent("Snapshots", isDirectory: true))
    }

    public func snapshot(domainIdentifier: String, containerIdentifier: String) throws -> KDriveSnapshot? {
        let url = fileURL(domainIdentifier: domainIdentifier, containerIdentifier: containerIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(KDriveSnapshot.self, from: Data(contentsOf: url))
    }

    public func save(_ snapshot: KDriveSnapshot, domainIdentifier: String, containerIdentifier: String) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(domainIdentifier: domainIdentifier, containerIdentifier: containerIdentifier), options: [.atomic])
    }

    public func removeSnapshots(domainIdentifier: String) throws {
        try ensureDirectoryExists()
        let prefix = "\(Self.safeFileName(for: domainIdentifier))--"
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in urls where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(domainIdentifier: String, containerIdentifier: String) -> URL {
        let fileName = "\(Self.safeFileName(for: domainIdentifier))--\(Self.safeFileName(for: containerIdentifier))"
        return directoryURL.appendingPathComponent(fileName).appendingPathExtension("json")
    }

    private static func safeFileName(for value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }.reduce(into: "") { $0.append($1) }
    }
}

public enum KDriveSnapshotStoreError: Error, Equatable, LocalizedError, Sendable {
    case missingAppGroupContainer(String)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer(let identifier):
            return "The shared app group container '\(identifier)' is not available."
        }
    }
}
