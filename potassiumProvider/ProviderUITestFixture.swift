#if DEBUG
import Foundation
import PotassiumProviderCore

@MainActor
enum ProviderUITestFixture {
    private static let environmentKey = "POTASSIUM_UI_TEST_FIXTURE"

    static func makeModel() -> PotassiumProviderAppModel? {
        guard let fixtureName = ProcessInfo.processInfo.environment[environmentKey],
              ["setup-navigation", "setup-error-banner"].contains(fixtureName)
        else {
            return nil
        }

        let account = ProviderAccount(
            accountIdentifier: "ui-account",
            displayName: "Design Team",
            authenticationKind: .oauth
        )
        let configuredDrive = KDriveDriveSummary(
            id: 10,
            name: "Shared Projects",
            accountID: 1,
            role: "admin",
            status: "active",
            isInMaintenance: false
        )
        let availableDrive = KDriveDriveSummary(
            id: 20,
            name: "Archive",
            accountID: 1,
            role: "user",
            status: "maintenance",
            isInMaintenance: true
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "ui-domain",
            accountIdentifier: account.accountIdentifier,
            displayName: configuredDrive.name,
            driveID: configuredDrive.id,
            driveName: configuredDrive.name
        )
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("potassiumProviderUITestFixture", isDirectory: true)

        let model = PotassiumProviderAppModel(
            accountStore: ProviderAccountFileStore(
                directoryURL: fixtureDirectory.appendingPathComponent("Accounts", isDirectory: true)
            ),
            domainStore: DomainConfigurationFileStore(
                directoryURL: fixtureDirectory.appendingPathComponent("Domains", isDirectory: true)
            ),
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: ProviderUITestOAuthAuthenticator(),
            domainRegistrar: ProviderUITestDomainRegistrar(),
            automaticallyReloadStoredState: false,
            initialAccounts: [account],
            initialDrivesByAccountIdentifier: [
                account.accountIdentifier: [configuredDrive, availableDrive],
            ],
            initialDomains: [configuration]
        )
        if fixtureName == "setup-error-banner" {
            model.errorMessage = "Could not refresh kDrive details."
        }
        return model
    }
}

@MainActor
private final class ProviderUITestOAuthAuthenticator: KDriveOAuthAuthenticating {
    func authenticate() async throws -> KDriveOAuthToken {
        KDriveOAuthToken(
            accessToken: "ui-test-token",
            tokenType: "Bearer",
            refreshToken: nil,
            scope: nil,
            idToken: nil,
            expiresAt: nil
        )
    }
}

@MainActor
private struct ProviderUITestDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {}
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}
#endif
