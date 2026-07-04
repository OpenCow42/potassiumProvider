import Foundation
import Testing
import UniformTypeIdentifiers
@testable import potassiumProvider
import PotassiumProviderCore

struct PotassiumProviderCoreTests {
    @Test func domainConfigurationStorePersistsAndRemovesConfigurations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("potassium-provider-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DomainConfigurationFileStore(directoryURL: directory)
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "domain-1",
            displayName: "Work Drive",
            driveID: 42,
            driveName: "kDrive",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        try store.save(configuration)

        #expect(try store.configuration(domainIdentifier: "domain-1") == configuration)
        #expect(try store.allConfigurations() == [configuration])

        try store.remove(domainIdentifier: "domain-1")

        #expect(try store.configuration(domainIdentifier: "domain-1") == nil)
        #expect(try store.allConfigurations().isEmpty)
    }

    @Test func snapshotStorePersistsAndRemovesDomainSnapshots() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = KDriveSnapshotFileStore(directoryURL: directory)
        let rootSnapshot = KDriveSnapshot(anchor: "root-anchor", items: [makeItem(id: 1, name: "Root.txt")])
        let trashSnapshot = KDriveSnapshot(anchor: "trash-anchor", items: [makeItem(id: 2, name: "Trash.txt")])

        try store.save(rootSnapshot, domainIdentifier: "domain/1", containerIdentifier: "root")
        try store.save(trashSnapshot, domainIdentifier: "domain/1", containerIdentifier: "trash")

        #expect(try store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "root") == rootSnapshot)
        #expect(try store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "trash") == trashSnapshot)

        try store.removeSnapshots(domainIdentifier: "domain/1")

        #expect(try store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "root") == nil)
        #expect(try store.snapshot(domainIdentifier: "domain/1", containerIdentifier: "trash") == nil)
    }

    @Test func oauthAuthorizationRequestContainsPkceStateAndNoScopes() throws {
        let request = try KDriveOAuthClient.makeAuthorizationRequest(
            state: "known-state",
            codeVerifier: "known-verifier"
        )
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "login.infomaniak.com")
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == ProviderConstants.oauthClientID)
        #expect(ProviderConstants.oauthClientID == "9473D73C-C20F-4971-9E10-D957C563FA68")
        #expect(query["redirect_uri"] == ProviderConstants.oauthRedirectURI.absoluteString)
        #expect(query["scope"] == nil)
        #expect(query["state"] == "known-state")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == KDriveOAuthClient.codeChallenge(for: "known-verifier"))
        #expect(request.callbackScheme == "com.infomaniak.drive")
    }

    @Test func oauthRefreshRequestDoesNotSpecifyScopes() async throws {
        OAuthRequestCapturingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthRequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        _ = try await KDriveOAuthClient.refresh(refreshToken: "refresh-token", session: session)

        let body = try #require(OAuthRequestCapturingURLProtocol.lastBody())
        let form = try decodedFormBody(from: body)
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["client_id"] == ProviderConstants.oauthClientID)
        #expect(form["refresh_token"] == "refresh-token")
        #expect(form["scope"] == nil)
    }

    @Test func oauthCallbackValidatesStateAndAuthorizationCode() throws {
        let callback = URL(string: "com.infomaniak.drive://oauth2redirect?code=abc123&state=state-1")!

        #expect(try KDriveOAuthClient.authorizationCode(from: callback, expectedState: "state-1") == "abc123")
        #expect(throws: KDriveOAuthError.stateMismatch) {
            try KDriveOAuthClient.authorizationCode(from: callback, expectedState: "different-state")
        }
    }

    @Test func tokenRefreshLeewayIsComputed() {
        let token = KDriveOAuthToken(
            accessToken: "redacted",
            tokenType: "Bearer",
            refreshToken: "refresh",
            scope: "profile drive",
            idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(token.shouldRefresh(now: Date(timeIntervalSince1970: 800), leeway: 300))
        #expect(!token.shouldRefresh(now: Date(timeIntervalSince1970: 600), leeway: 300))
    }

    @Test func itemIdentifierParsesFileProviderAndKDriveValues() throws {
        #expect(try KDriveItemIdentifier(rawValue: "NSFileProviderRootContainerItemIdentifier") == .root)
        #expect(try KDriveItemIdentifier(rawValue: "NSFileProviderTrashContainerItemIdentifier") == .trash)
        #expect(try KDriveItemIdentifier(rawValue: "123") == .item(123))
        #expect(KDriveItemIdentifier.item(456).rawValue == "456")
        #expect(KDriveItemIdentifier.root.fileID == ProviderConstants.defaultRootFileID)
        #expect(KDriveItemIdentifier.root.fileID(rootFileID: 999) == 999)
        #expect(throws: KDriveItemIdentifierError.invalid("not-a-number")) {
            try KDriveItemIdentifier(rawValue: "not-a-number")
        }
    }

    @Test func remoteItemMapsContentTypes() {
        let folder = makeItem(id: 1, name: "Documents", type: "dir", mimeType: nil)
        let text = makeItem(id: 2, name: "Notes.txt", type: "file", mimeType: "text/plain")

        #expect(folder.isDirectory)
        #expect(folder.contentType == .folder)
        #expect(!text.isDirectory)
        #expect(text.contentType.conforms(to: .plainText))
    }

    @Test func snapshotDiffReportsUpdatesAndDeletes() {
        let oldSnapshot = KDriveSnapshot(anchor: "old", items: [
            makeItem(id: 1, name: "Keep.txt"),
            makeItem(id: 2, name: "Delete.txt")
        ])
        let newSnapshot = KDriveSnapshot(anchor: "new", items: [
            makeItem(id: 1, name: "Keep Renamed.txt"),
            makeItem(id: 3, name: "Create.txt")
        ])

        let changes = KDriveSnapshotDiffer.changes(from: oldSnapshot, to: newSnapshot)

        #expect(changes.updatedItems.map(\.id) == [1, 3])
        #expect(changes.deletedItemIDs == [2])
    }

    @MainActor
    @Test func appModelStoresManualTokenAndLoadsDrives() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let domainStore = DomainConfigurationFileStore(directoryURL: directory)
        let tokenStore = InMemoryOAuthTokenStore()
        let drive = KDriveDriveSummary(
            id: 42,
            name: "Work Drive",
            accountID: 100,
            role: "admin",
            status: "ok",
            isInMaintenance: false
        )
        let model = PotassiumProviderAppModel(
            domainStore: domainStore,
            tokenStore: tokenStore,
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: NoopProviderDomainRegistrar(),
            fileProviderFactory: { token in
                #expect(token == "manual-token")
                return FakeKDriveFileProvider(drives: [drive])
            }
        )

        model.manualAccessToken = " manual-token "

        await model.saveManualAccessToken()

        #expect(model.isConnected)
        #expect(model.manualAccessToken.isEmpty)
        #expect(model.drives == [drive])
        #expect(model.selectedDriveID == drive.id)
        #expect(tokenStore.loadToken()?.accessToken == "manual-token")
        #expect(tokenStore.loadToken()?.scope == nil)
    }

    @MainActor
    @Test func appModelAddsAndRemovesDomainConfigurations() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let domainStore = DomainConfigurationFileStore(directoryURL: directory)
        let snapshotStore = KDriveSnapshotFileStore(directoryURL: directory.appendingPathComponent("Snapshots", isDirectory: true))
        let model = PotassiumProviderAppModel(
            domainStore: domainStore,
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: NoopProviderDomainRegistrar(),
            snapshotStore: snapshotStore,
            fileProviderFactory: { _ in FakeKDriveFileProvider(drives: []) }
        )

        model.manualDriveID = " 42 "
        model.manualDriveName = "Work Drive"
        model.domainDisplayName = "Team Files"

        await model.addDomain()

        let domain = try #require(model.domains.first)
        #expect(domain.displayName == "Team Files")
        #expect(domain.driveID == 42)
        #expect(domain.driveName == "Work Drive")
        #expect(try domainStore.allConfigurations().count == 1)
        try snapshotStore.save(
            KDriveSnapshot(anchor: "anchor", items: [makeItem(id: 7, name: "Cached.txt")]),
            domainIdentifier: domain.domainIdentifier,
            containerIdentifier: "root"
        )

        await model.removeDomain(domain)

        #expect(model.domains.isEmpty)
        #expect(try domainStore.allConfigurations().isEmpty)
        #expect(try snapshotStore.snapshot(domainIdentifier: domain.domainIdentifier, containerIdentifier: "root") == nil)
    }

    @MainActor
    @Test func appModelRollsBackDomainConfigurationWhenRegistrationFails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let domainStore = DomainConfigurationFileStore(directoryURL: directory)
        let model = PotassiumProviderAppModel(
            domainStore: domainStore,
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            domainRegistrar: FailingProviderDomainRegistrar(),
            fileProviderFactory: { _ in FakeKDriveFileProvider(drives: []) }
        )

        model.manualDriveID = "42"
        model.manualDriveName = "Work Drive"
        model.domainDisplayName = "Team Files"

        await model.addDomain()

        #expect(model.domains.isEmpty)
        #expect(try domainStore.allConfigurations().isEmpty)
        #expect(model.errorMessage?.contains("The application cannot be used right now") == true)
    }

    private func makeItem(
        id: Int,
        name: String,
        type: String? = "file",
        mimeType: String? = "text/plain"
    ) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name,
            type: type,
            status: "ok",
            driveID: 10,
            parentID: ProviderConstants.defaultRootFileID,
            path: "/\(name)",
            size: type == "dir" ? nil : 12,
            mimeType: mimeType,
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 300)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("potassium-provider-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func decodedFormBody(from body: Data) throws -> [String: String] {
        let encodedBody = String(decoding: body, as: UTF8.self)
        let components = try #require(URLComponents(string: "?\(encodedBody)"))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

private final class OAuthRequestCapturingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var capturedRequest: URLRequest?
    private static var capturedBody: Data?

    static func reset() {
        lock.lock()
        capturedRequest = nil
        capturedBody = nil
        lock.unlock()
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    static func lastBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequest = request
        Self.capturedBody = request.httpBody ?? Self.readBodyStream(from: request)
        Self.lock.unlock()

        let data = """
        {
          "access_token": "refreshed-token",
          "token_type": "Bearer",
          "expires_in": 3600,
          "refresh_token": "new-refresh-token"
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            guard bytesRead > 0 else {
                break
            }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}

@MainActor
private final class FakeKDriveOAuthAuthenticator: KDriveOAuthAuthenticating {
    private let token: KDriveOAuthToken

    init(token: KDriveOAuthToken = KDriveOAuthToken(
        accessToken: "oauth-token",
        tokenType: "Bearer",
        refreshToken: nil,
        scope: nil,
        idToken: nil,
        expiresAt: nil
    )) {
        self.token = token
    }

    func authenticate() async throws -> KDriveOAuthToken {
        token
    }
}

private struct FakeKDriveFileProvider: KDriveFileProviding {
    let drives: [KDriveDriveSummary]

    func listDrives() async throws -> [KDriveDriveSummary] {
        drives
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func uploadFile(driveID: Int, parentID: Int, fileName: String, contents: Data, lastModifiedAt: Date?) async throws -> KDriveRemoteItem {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func replaceFile(driveID: Int, fileID: Int, contents: Data, lastModifiedAt: Date?) async throws -> KDriveRemoteItem {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        throw FakeKDriveFileProviderError.unimplemented
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        throw FakeKDriveFileProviderError.unimplemented
    }
}

private enum FakeKDriveFileProviderError: Error {
    case unimplemented
}

@MainActor
private struct NoopProviderDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {}
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}

@MainActor
private struct FailingProviderDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        throw FailingProviderDomainRegistrarError.applicationUnavailable
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}

private enum FailingProviderDomainRegistrarError: LocalizedError {
    case applicationUnavailable

    var errorDescription: String? {
        "The application cannot be used right now"
    }
}
