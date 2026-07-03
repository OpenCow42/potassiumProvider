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

    @Test func oauthAuthorizationRequestContainsPkceStateAndScopes() throws {
        let request = try KDriveOAuthClient.makeAuthorizationRequest(
            configuration: KDriveOAuthConfiguration(scopes: ["accounts", "drive"]),
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
        #expect(query["redirect_uri"] == ProviderConstants.oauthRedirectURI.absoluteString)
        #expect(query["scope"] == "accounts drive")
        #expect(query["state"] == "known-state")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == KDriveOAuthClient.codeChallenge(for: "known-verifier"))
        #expect(request.callbackScheme == "com.infomaniak.drive")
    }

    @Test func oauthCallbackValidatesStateAndAuthorizationCode() throws {
        let callback = URL(string: "com.infomaniak.drive://oauth2redirect?code=abc123&state=state-1")!

        #expect(try KDriveOAuthClient.authorizationCode(from: callback, expectedState: "state-1") == "abc123")
        #expect(throws: KDriveOAuthError.stateMismatch) {
            try KDriveOAuthClient.authorizationCode(from: callback, expectedState: "different-state")
        }
    }

    @Test func tokenScopeAndRefreshLeewayAreComputed() {
        let token = KDriveOAuthToken(
            accessToken: "redacted",
            tokenType: "Bearer",
            refreshToken: "refresh",
            scope: "profile drive",
            idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(token.scopes == ["profile", "drive"])
        #expect(token.hasKDriveScope)
        #expect(token.shouldRefresh(now: Date(timeIntervalSince1970: 800), leeway: 300))
        #expect(!token.shouldRefresh(now: Date(timeIntervalSince1970: 600), leeway: 300))
    }

    @Test func itemIdentifierParsesFileProviderAndKDriveValues() throws {
        #expect(try KDriveItemIdentifier(rawValue: "NSFileProviderRootContainerItemIdentifier") == .root)
        #expect(try KDriveItemIdentifier(rawValue: "NSFileProviderTrashContainerItemIdentifier") == .trash)
        #expect(try KDriveItemIdentifier(rawValue: "123") == .item(123))
        #expect(KDriveItemIdentifier.item(456).rawValue == "456")
        #expect(KDriveItemIdentifier.root.fileID == ProviderConstants.defaultRootFileID)
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
    }

    @MainActor
    @Test func appModelAddsAndRemovesDomainConfigurations() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let domainStore = DomainConfigurationFileStore(directoryURL: directory)
        let model = PotassiumProviderAppModel(
            domainStore: domainStore,
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: FakeKDriveOAuthAuthenticator(),
            fileProviderFactory: { _ in FakeKDriveFileProvider(drives: []) }
        )

        model.manualDriveID = " 42 "
        model.manualDriveName = "Work Drive"
        model.domainDisplayName = "Team Files"

        model.addDomain()

        let domain = try #require(model.domains.first)
        #expect(domain.displayName == "Team Files")
        #expect(domain.driveID == 42)
        #expect(domain.driveName == "Work Drive")
        #expect(try domainStore.allConfigurations().count == 1)

        model.removeDomain(domain)

        #expect(model.domains.isEmpty)
        #expect(try domainStore.allConfigurations().isEmpty)
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
}

@MainActor
private final class FakeKDriveOAuthAuthenticator: KDriveOAuthAuthenticating {
    private let token: KDriveOAuthToken

    init(token: KDriveOAuthToken = KDriveOAuthToken(
        accessToken: "oauth-token",
        tokenType: "Bearer",
        refreshToken: nil,
        scope: "drive",
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
