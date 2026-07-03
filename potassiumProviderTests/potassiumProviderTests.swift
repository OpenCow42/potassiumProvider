import Foundation
import Testing
import UniformTypeIdentifiers
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
}
