import Foundation
import PotassiumChannelCore
import PotassiumProviderCore

/// A stateful service double, not a queue of canned successful responses. Each
/// request validates the current identity, parent and conditional version.
actor ConflictTestRemote: KDriveFileProviding {
    struct State: Codable {
        var items: [Int: KDriveRemoteItem] = [:]
        var bytes: [Int: Data] = [:]
        var trash: Set<Int> = []
        var tokens: [String: Int] = [:]
        var revision = 1
        var nextID = 100
    }
    enum Fault: Sendable { case status(Int), offline, cancelled, responseLost }
    private var state: State
    private let url: URL
    private var fault: Fault?
    private var calls: [String] = []
    private var replaceGate: ConflictTestGate?
    private var hiddenFromActiveLookup: Set<Int> = []
    func hideFromActiveLookup(_ id: Int) { hiddenFromActiveLookup.insert(id) }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("server.json")
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } else {
            state = State()
            state.items[1] = Self.item(1, name: "Root", parent: 0, directory: true)
            state.items[2] = Self.item(2, name: "Other", parent: 1, directory: true)
            state.items[3] = Self.item(3, name: "Original.txt", parent: 1)
            state.bytes[3] = Data("base".utf8)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        }
    }
    static func item(_ id: Int, name: String, parent: Int, directory: Bool = false,
                     revision: Int = 1, size: Int = 4) -> KDriveRemoteItem {
        KDriveRemoteItem(id: id, name: name, type: directory ? "dir" : "file", status: "ok",
            driveID: 7, parentID: parent, path: nil, size: directory ? nil : size,
            mimeType: directory ? nil : "text/plain", createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: Double(revision)),
            updatedAt: Date(timeIntervalSince1970: Double(revision)), etag: "revision-\(revision)")
    }
    func snapshot() -> State { state }
    func operations() -> [String] { calls }
    func inject(_ fault: Fault) { self.fault = fault }
    func gateReplacement(_ gate: ConflictTestGate) { replaceGate = gate }
    func clearOperations() { calls = [] }
    private func save() throws { try JSONEncoder().encode(state).write(to: url, options: .atomic) }
    private func failBeforeRequest() throws {
        guard let fault else { return }
        if case .responseLost = fault { return }
        self.fault = nil
        switch fault {
        case .status(let code): throw APIClientError.unacceptableStatusCode(code, body: "")
        case .offline: throw URLError(.notConnectedToInternet)
        case .cancelled: throw CancellationError()
        case .responseLost: break
        }
    }
    private func afterCommit() throws {
        try save()
        if case .responseLost = fault { fault = nil; throw URLError(.networkConnectionLost) }
    }
    private func existing(_ id: Int) throws -> KDriveRemoteItem {
        guard let item = state.items[id] else { throw APIClientError.unacceptableStatusCode(404, body: "") }
        return item
    }
    private func parent(_ id: Int, child: Int? = nil) throws {
        guard try existing(id).isDirectory, !state.trash.contains(id) else {
            throw APIClientError.unacceptableStatusCode(404, body: "")
        }
        var ancestor = id, seen = Set<Int>()
        while ancestor != 0 {
            guard ancestor != child, seen.insert(ancestor).inserted else {
                throw APIClientError.unacceptableStatusCode(409, body: "")
            }
            ancestor = try existing(ancestor).parentID
        }
    }
    private func allocated(_ name: String, parent: Int, excluding: Int? = nil) -> String {
        let names = Set(state.items.values.filter { $0.parentID == parent && $0.id != excluding && !state.trash.contains($0.id) }
            .map { $0.name.precomposedStringWithCanonicalMapping.lowercased() })
        var candidate = name, suffix = 2
        while names.contains(candidate.precomposedStringWithCanonicalMapping.lowercased()) {
            candidate = "\((name as NSString).deletingPathExtension) \(suffix).\((name as NSString).pathExtension)"
            suffix += 1
        }
        return candidate
    }
    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        try failBeforeRequest()
        if hiddenFromActiveLookup.contains(fileID) { throw APIClientError.unacceptableStatusCode(404, body: "") }
        return try existing(fileID)
    }
    func listDrives() async throws -> [KDriveDriveSummary] { [] }
    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        KDriveItemPage(items: state.items.values.filter { $0.parentID == folderID && !state.trash.contains($0.id) }, nextCursor: nil, hasMore: false)
    }
    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage {
        let page = try await listDirectory(driveID: driveID, folderID: folderID, cursor: cursor, limit: limit)
        return KDriveAdvancedItemPage(items: page.items, actions: [], actionItems: [], nextCursor: nil, hasMore: false)
    }
    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        KDriveItemPage(items: state.items.values.filter { state.trash.contains($0.id) }, nextCursor: nil, hasMore: false)
    }
    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        try failBeforeRequest(); _ = try existing(fileID)
        return state.bytes[fileID] ?? Data()
    }
    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data { Data() }
    func uploadFile(driveID: Int, parentID: Int, fileName: String, contents: Data, lastModifiedAt: Date?,
                    conflictStrategy: KDriveUploadConflictStrategy, clientToken: String?, contentHash: String?) async throws -> KDriveRemoteItem {
        try failBeforeRequest(); calls.append("upload")
        if let clientToken, let id = state.tokens[clientToken] { return try existing(id) }
        try parent(parentID)
        let name = allocated(fileName, parent: parentID)
        if conflictStrategy == .error, name != fileName { throw APIClientError.unacceptableStatusCode(409, body: "") }
        state.nextID += 1; state.revision += 1
        let item = Self.item(state.nextID, name: name, parent: parentID, revision: state.revision, size: contents.count)
        state.items[item.id] = item; state.bytes[item.id] = contents
        if let clientToken { state.tokens[clientToken] = item.id }
        try afterCommit(); return item
    }
    func replaceFile(driveID: Int, fileID: Int, expectedETag: String, clientToken: String, contentHash: String,
                     contents: Data, lastModifiedAt: Date?) async throws -> KDriveRemoteItem {
        if let gate = replaceGate { replaceGate = nil; try await gate.arrive() }
        try failBeforeRequest(); calls.append("replace")
        let current = try existing(fileID)
        guard current.etag == expectedETag else { throw APIClientError.unacceptableStatusCode(412, body: "") }
        state.revision += 1
        let updated = Self.item(fileID, name: current.name, parent: current.parentID, revision: state.revision, size: contents.count)
        state.items[fileID] = updated; state.bytes[fileID] = contents
        try afterCommit(); return updated
    }
    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        try parent(parentID); calls.append("mkdir")
        guard allocated(name, parent: parentID) == name else { throw APIClientError.unacceptableStatusCode(409, body: "") }
        state.nextID += 1
        let item = Self.item(state.nextID, name: name, parent: parentID, directory: true)
        state.items[item.id] = item; try afterCommit(); return item
    }
    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        try failBeforeRequest(); calls.append("rename")
        let item = try existing(fileID)
        guard allocated(name, parent: item.parentID, excluding: fileID) == name else { throw APIClientError.unacceptableStatusCode(409, body: "") }
        state.items[fileID] = Self.item(fileID, name: name, parent: item.parentID, directory: item.isDirectory,
            revision: Int(item.modifiedAt.timeIntervalSince1970), size: item.size ?? 0)
        try afterCommit()
    }
    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws {
        try failBeforeRequest(); calls.append("move"); try parent(destinationParentID, child: fileID)
        let item = try existing(fileID)
        state.items[fileID] = Self.item(fileID, name: allocated(name ?? item.name, parent: destinationParentID, excluding: fileID),
            parent: destinationParentID, directory: item.isDirectory, revision: Int(item.modifiedAt.timeIntervalSince1970), size: item.size ?? 0)
        try afterCommit()
    }
    func updateModificationDate(driveID: Int, fileID: Int, date: Date) async throws { calls.append("date") }
    func trashItem(driveID: Int, fileID: Int) async throws {
        try failBeforeRequest(); _ = try existing(fileID); calls.append("trash")
        state.trash.insert(fileID); try afterCommit()
    }
    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        try failBeforeRequest(); calls.append("delete")
        state.items[fileID] = nil; state.bytes[fileID] = nil; state.trash.remove(fileID); try afterCommit()
    }
}

actor ConflictTestGate {
    private let arrival = AsyncStream<Void>.makeStream()
    private let releaseSignal = AsyncStream<Void>.makeStream()
    func arrive() async throws {
        arrival.continuation.finish()
        for await _ in releaseSignal.stream { }
        // Cancellation and release can race. A released gate must never turn
        // a cancelled request into a committed synthetic mutation.
        try Task.checkCancellation()
    }
    func waitUntilReached() async throws {
        for await _ in arrival.stream { }
        try Task.checkCancellation()
    }
    func release() { releaseSignal.continuation.finish() }
}

struct ConflictTestClient: Sendable {
    let directory: URL
    let remote: ConflictTestRemote
    var coordinator: KDriveMutationCoordinator {
        KDriveMutationCoordinator(configuration: ProviderDomainConfiguration(domainIdentifier: directory.lastPathComponent,
            displayName: "Synthetic", driveID: 7, driveName: "Synthetic", rootFileID: 1),
            remote: remote, conflictStager: ConflictTestStager(directory: directory.appendingPathComponent("staging")),
            conflictDeviceName: { "Synthetic" }, conflictDate: { Date(timeIntervalSince1970: 1) },
            conflictTimeZone: { TimeZone(secondsFromGMT: 0)! })
    }
    func cache(_ item: KDriveRemoteItem) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(item).write(to: directory.appendingPathComponent("base.json"), options: .atomic)
    }
    func base() throws -> KDriveRemoteItem {
        try JSONDecoder().decode(KDriveRemoteItem.self, from: Data(contentsOf: directory.appendingPathComponent("base.json")))
    }
    func edit(_ bytes: Data, filename: String? = nil, version: Data? = nil, failOnConflict: Bool = false) async throws -> KDriveContentMutationResult {
        let base = try base()
        return try await coordinator.replaceContents(itemIdentifier: String(base.id), fileID: base.id,
            localFilename: filename ?? base.name, baseContentVersion: version ?? base.contentVersion,
            contents: bytes, lastModifiedAt: nil, failOnConflict: failOnConflict)
    }
}
struct ConflictTestStager: KDriveConflictContentStaging {
    let directory: URL
    func stageConflictContents(_ contents: Data, itemIdentifier: String) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(KDriveMutationIdentity.clientToken([itemIdentifier, KDriveMutationIdentity.contentHash(contents)]))
        try contents.write(to: file, options: .atomic); return file
    }
    func removeStagedConflictContents(at url: URL) async { try? FileManager.default.removeItem(at: url) }
}
