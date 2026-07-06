import Foundation

public protocol KDriveSnapshotStoring: Sendable {
    func snapshot(domainIdentifier: String, containerIdentifier: String) async throws -> KDriveSnapshot?
    func save(
        _ snapshot: KDriveSnapshot,
        domainIdentifier: String,
        containerIdentifier: String,
        condition: KDriveSnapshotSaveCondition
    ) async throws
    func removeSnapshot(domainIdentifier: String, containerIdentifier: String) async throws
    func removeSnapshots(domainIdentifier: String) async throws
}

public extension KDriveSnapshotStoring {
    func save(_ snapshot: KDriveSnapshot, domainIdentifier: String, containerIdentifier: String) async throws {
        try await save(
            snapshot,
            domainIdentifier: domainIdentifier,
            containerIdentifier: containerIdentifier,
            condition: .unconditional
        )
    }
}

public enum KDriveSnapshotSaveCondition: Equatable, Sendable {
    case unconditional
    case missing
    case matching(anchor: String, serverCursor: String?)

    func accepts(_ snapshot: KDriveSnapshot?) -> Bool {
        switch self {
        case .unconditional:
            return true
        case .missing:
            return snapshot == nil
        case .matching(let anchor, let serverCursor):
            return snapshot?.anchor == anchor && snapshot?.serverCursor == serverCursor
        }
    }
}

public actor KDriveSnapshotFileStore: KDriveSnapshotStoring {
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
            throw KDriveSnapshotStoreError.missingAppGroupContainer(appGroupIdentifier)
        }
        self.init(directoryURL: containerURL.appendingPathComponent("Snapshots", isDirectory: true))
    }

    public func snapshot(domainIdentifier: String, containerIdentifier: String) throws -> KDriveSnapshot? {
        let url = fileURL(domainIdentifier: domainIdentifier, containerIdentifier: containerIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(KDriveSnapshot.self, from: Data(contentsOf: url))
    }

    public func save(
        _ snapshot: KDriveSnapshot,
        domainIdentifier: String,
        containerIdentifier: String,
        condition: KDriveSnapshotSaveCondition
    ) throws {
        let currentSnapshot = try self.snapshot(domainIdentifier: domainIdentifier, containerIdentifier: containerIdentifier)
        guard condition.accepts(currentSnapshot) else {
            throw KDriveSnapshotStoreError.staleSnapshot(
                domainIdentifier: domainIdentifier,
                containerIdentifier: containerIdentifier
            )
        }
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

    public func removeSnapshot(domainIdentifier: String, containerIdentifier: String) throws {
        let url = fileURL(domainIdentifier: domainIdentifier, containerIdentifier: containerIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
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
    case staleSnapshot(domainIdentifier: String, containerIdentifier: String)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer(let identifier):
            return "The shared app group container '\(identifier)' is not available."
        case .staleSnapshot(let domainIdentifier, let containerIdentifier):
            return "The cached snapshot for domain '\(domainIdentifier)' and container '\(containerIdentifier)' changed before it could be saved."
        }
    }
}
