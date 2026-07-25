import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@MainActor
struct ProviderSetupViewTests {
    @Test func driveDescriptorsMergeRemoteAndConfiguredState() throws {
        let configured = makeDrive(id: 10, name: "Projects", role: "admin")
        let available = makeDrive(id: 20, name: "Archive", role: "user", isInMaintenance: true)
        let configuration = makeConfiguration(
            accountIdentifier: "account-a",
            driveID: configured.id,
            driveName: configured.name
        )

        let descriptors = ProviderDriveDescriptor.merge(
            accountIdentifier: "account-a",
            drives: [configured, available],
            configurations: [configuration]
        )

        #expect(descriptors.map(\.driveID) == [10, 20])
        #expect(descriptors[0].configuration == configuration)
        #expect(descriptors[0].role == "admin")
        #expect(descriptors[1].configuration == nil)
        #expect(descriptors[1].isInMaintenance)
    }

    @Test func configuredDriveRemainsVisibleWithoutRemoteDetails() throws {
        let configuration = makeConfiguration(
            accountIdentifier: "account-a",
            driveID: 30,
            driveName: "Saved Drive"
        )

        let descriptor = try #require(ProviderDriveDescriptor.merge(
            accountIdentifier: "account-a",
            drives: [],
            configurations: [configuration]
        ).first)

        #expect(descriptor.name == "Saved Drive")
        #expect(descriptor.isConfigured)
        #expect(descriptor.remoteDetailsAreAvailable == false)
    }

    @Test func driveIdentityIncludesItsAccount() {
        let accountA = ProviderDriveKey(accountIdentifier: "account-a", driveID: 10)
        let accountB = ProviderDriveKey(accountIdentifier: "account-b", driveID: 10)

        #expect(accountA != accountB)
        #expect(ProviderSetupRoute.drive(accountA) != ProviderSetupRoute.drive(accountB))
    }

    @Test func refreshedRemoteMetadataReplacesPresentationWithoutChangingIdentity() throws {
        let initial = try #require(ProviderDriveDescriptor.merge(
            accountIdentifier: "account-a",
            drives: [makeDrive(id: 10, name: "Old Name", role: "user")],
            configurations: []
        ).first)
        let refreshed = try #require(ProviderDriveDescriptor.merge(
            accountIdentifier: "account-a",
            drives: [makeDrive(id: 10, name: "New Name", role: "admin")],
            configurations: []
        ).first)

        #expect(initial.id == refreshed.id)
        #expect(refreshed.name == "New Name")
        #expect(refreshed.role == "admin")
    }

    @Test func removedConfigurationLeavesDiscoveredDriveUnconfigured() throws {
        let drive = makeDrive(id: 10, name: "Projects", role: "admin")
        let configuration = makeConfiguration(
            accountIdentifier: "account-a",
            driveID: drive.id,
            driveName: drive.name
        )
        let configured = try #require(ProviderDriveDescriptor.merge(
            accountIdentifier: "account-a",
            drives: [drive],
            configurations: [configuration]
        ).first)
        let removed = try #require(ProviderDriveDescriptor.merge(
            accountIdentifier: "account-a",
            drives: [drive],
            configurations: []
        ).first)

        #expect(configured.id == removed.id)
        #expect(configured.isConfigured)
        #expect(removed.isConfigured == false)
    }

    @Test func storedStateReloadPublishesLoadingUntilAccountsAreAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = ProviderAccount(
            accountIdentifier: "account-a",
            displayName: "Account",
            authenticationKind: .oauth
        )
        let accountStore = BlockingSetupAccountStore(accounts: [account])
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: DomainConfigurationFileStore(
                directoryURL: directory.appendingPathComponent("Domains", isDirectory: true)
            ),
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: SetupTestOAuthAuthenticator(),
            domainRegistrar: SetupTestDomainRegistrar(),
            automaticallyReloadStoredState: false
        )

        #expect(model.isReloadingStoredState == false)
        let reload = Task { await model.reloadStoredState() }
        await accountStore.waitUntilAllAccountsStarts()

        #expect(model.isReloadingStoredState)

        await accountStore.resumeAllAccounts()
        await reload.value

        #expect(model.isReloadingStoredState == false)
        #expect(model.accounts == [account])
    }

    @Test func duplicateAddIsGuardedAndActionStateClears() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = ProviderAccount(
            accountIdentifier: "account-a",
            displayName: "Account",
            authenticationKind: .oauth
        )
        let drive = makeDrive(id: 10, name: "Projects", role: "admin")
        let registrar = BlockingAddDomainRegistrar()
        let model = PotassiumProviderAppModel(
            accountStore: ProviderAccountFileStore(
                directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true)
            ),
            domainStore: DomainConfigurationFileStore(
                directoryURL: directory.appendingPathComponent("Domains", isDirectory: true)
            ),
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: SetupTestOAuthAuthenticator(),
            domainRegistrar: registrar,
            automaticallyReloadStoredState: false,
            initialAccounts: [account],
            initialDrivesByAccountIdentifier: [account.accountIdentifier: [drive]]
        )
        let key = ProviderDriveKey(accountIdentifier: account.accountIdentifier, driveID: drive.id)

        let firstAdd = Task {
            await model.addDomain(accountIdentifier: account.accountIdentifier, drive: drive)
        }
        await registrar.waitUntilAddStarts()

        #expect(model.activeDriveAction(for: key) == .addingToFiles)
        await model.addDomain(accountIdentifier: account.accountIdentifier, drive: drive)
        #expect(registrar.addCallCount == 1)
        await model.logoutAccount(account)
        #expect(model.account(accountIdentifier: account.accountIdentifier) != nil)
        #expect(model.errorMessage?.contains("Wait for the current drive action") == true)

        registrar.resumeAdd()
        await firstAdd.value

        #expect(model.activeDriveAction(for: key) == nil)
        #expect(model.isConfigured(accountIdentifier: account.accountIdentifier, driveID: drive.id))
    }

    @Test func explicitRenamePersistsOnlyTheSubmittedNormalizedName() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = ProviderAccount(
            accountIdentifier: "account-a",
            displayName: "Old Name",
            authenticationKind: .oauth
        )
        let accountStore = ProviderAccountFileStore(
            directoryURL: directory.appendingPathComponent("Accounts", isDirectory: true)
        )
        let model = PotassiumProviderAppModel(
            accountStore: accountStore,
            domainStore: DomainConfigurationFileStore(
                directoryURL: directory.appendingPathComponent("Domains", isDirectory: true)
            ),
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: SetupTestOAuthAuthenticator(),
            domainRegistrar: SetupTestDomainRegistrar(),
            automaticallyReloadStoredState: false,
            initialAccounts: [account]
        )

        await model.renameAccount(
            accountIdentifier: account.accountIdentifier,
            displayName: "  Design Team  "
        )

        #expect(model.account(accountIdentifier: account.accountIdentifier)?.displayName == "Design Team")
        #expect(try await accountStore.allAccounts().map(\.displayName) == ["Design Team"])
    }

    private func makeDrive(
        id: Int,
        name: String,
        role: String,
        isInMaintenance: Bool = false
    ) -> KDriveDriveSummary {
        KDriveDriveSummary(
            id: id,
            name: name,
            accountID: 1,
            role: role,
            status: isInMaintenance ? "maintenance" : "active",
            isInMaintenance: isInMaintenance
        )
    }

    private func makeConfiguration(
        accountIdentifier: String,
        driveID: Int,
        driveName: String
    ) -> ProviderDomainConfiguration {
        ProviderDomainConfiguration(
            accountIdentifier: accountIdentifier,
            displayName: driveName,
            driveID: driveID,
            driveName: driveName
        )
    }
}

@MainActor
private final class BlockingAddDomainRegistrar: ProviderDomainRegistering {
    private var addStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var addContinuation: CheckedContinuation<Void, Never>?
    private(set) var addCallCount = 0

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        addCallCount += 1
        let waiting = addStartedContinuations
        addStartedContinuations.removeAll()
        waiting.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            addContinuation = continuation
        }
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}

    func waitUntilAddStarts() async {
        guard addCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            addStartedContinuations.append(continuation)
        }
    }

    func resumeAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
}

@MainActor
private final class SetupTestOAuthAuthenticator: KDriveOAuthAuthenticating {
    func authenticate() async throws -> KDriveOAuthToken {
        KDriveOAuthToken(
            accessToken: "test-token",
            tokenType: "Bearer",
            refreshToken: nil,
            scope: nil,
            idToken: nil,
            expiresAt: nil
        )
    }
}

@MainActor
private struct SetupTestDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {}
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}

private actor BlockingSetupAccountStore: ProviderAccountStoring {
    private var accounts: [ProviderAccount]
    private var hasStartedAllAccounts = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var allAccountsContinuation: CheckedContinuation<Void, Never>?

    init(accounts: [ProviderAccount]) {
        self.accounts = accounts
    }

    func allAccounts() async -> [ProviderAccount] {
        hasStartedAllAccounts = true
        let waiting = startContinuations
        startContinuations.removeAll()
        waiting.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            allAccountsContinuation = continuation
        }
        return accounts
    }

    func account(accountIdentifier: String) -> ProviderAccount? {
        accounts.first { $0.accountIdentifier == accountIdentifier }
    }

    func save(_ account: ProviderAccount) {
        accounts.removeAll { $0.accountIdentifier == account.accountIdentifier }
        accounts.append(account)
    }

    func remove(accountIdentifier: String) {
        accounts.removeAll { $0.accountIdentifier == accountIdentifier }
    }

    func waitUntilAllAccountsStarts() async {
        guard hasStartedAllAccounts == false else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func resumeAllAccounts() {
        allAccountsContinuation?.resume()
        allAccountsContinuation = nil
    }
}
