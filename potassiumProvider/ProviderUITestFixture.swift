#if DEBUG
import Foundation
import PotassiumProviderCore

@MainActor
enum ProviderUITestFixture {
    private static let environmentKey = "POTASSIUM_UI_TEST_FIXTURE"

    static func makeModel() -> PotassiumProviderAppModel? {
        guard let fixtureName = ProcessInfo.processInfo.environment[environmentKey],
              ["setup-navigation", "setup-error-banner", "activities-pagination"].contains(fixtureName)
        else {
            return nil
        }

        if fixtureName == "activities-pagination" {
            return makeActivitiesModel()
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

    private static func makeActivitiesModel() -> PotassiumProviderAppModel {
        let activity = (0..<1_000).map { index in
            KDriveProviderActivityEvent(
                id: deterministicUUID(index),
                occurredAt: Date(timeIntervalSince1970: Double(2_000_000 - index)),
                domainIdentifier: "ui-domain",
                driveID: 10,
                kind: .enumeration,
                outcome: .failure,
                severity: .error,
                itemIdentifier: "\(index)",
                itemName: String(format: "Item %04d", index),
                itemPath: String(format: "/Item %04d", index),
                summary: String(format: "Deterministic activity %04d.", index),
                diagnostic: KDriveProviderActivityErrorDiagnostic(
                    errorCategory: .fileProvider,
                    recoverySuggestion: "Retry after the provider becomes available."
                )
            )
        }
        return PotassiumProviderAppModel(
            eventStore: ProviderUITestActivityStore(activity: activity),
            automaticallyReloadStoredState: false
        )
    }

    private static func deterministicUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
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

private actor ProviderUITestActivityStore: KDriveProviderEventStoring, KDriveProviderEventTimelinePaging {
    private var activity: [KDriveProviderActivityEvent]

    init(activity: [KDriveProviderActivityEvent]) {
        self.activity = activity
    }

    func saveConflict(_: KDriveConflictEvent) {}

    func recordActivity(_ event: KDriveProviderActivityEvent) {
        activity.removeAll { $0.id == event.id }
        activity.append(event)
    }

    func recentConflicts(domainIdentifier _: String?, limit _: Int) -> [KDriveConflictEvent] {
        []
    }

    func recentActivity(domainIdentifier _: String?, limit: Int) -> [KDriveProviderActivityEvent] {
        Array(activity.prefix(limit))
    }

    func recentActivity(
        domainIdentifier _: String?,
        outcome: KDriveProviderActivityOutcome?,
        limit: Int
    ) -> [KDriveProviderActivityEvent] {
        Array(activity.filter { outcome == nil || $0.outcome == outcome }.prefix(limit))
    }

    func removeActivityAndResolvedConflicts(domainIdentifier _: String?) {
        activity.removeAll()
    }

    func removeEvents(domainIdentifier: String) {
        activity.removeAll { $0.domainIdentifier == domainIdentifier }
    }

    func timelinePage(
        filter: KDriveProviderTimelineFilter,
        before cursor: KDriveProviderTimelineCursor?,
        limit: Int
    ) -> KDriveProviderTimelinePage {
        let entries = activity
            .filter { filter == .allActivity || $0.outcome == .failure }
            .map(KDriveProviderTimelineEntry.activity)
            .filter { entry in
                guard let cursor else { return true }
                return entry.cursor.date < cursor.date
                    || (
                        entry.cursor.date == cursor.date
                            && entry.cursor.eventID.uuidString < cursor.eventID.uuidString
                    )
            }
            .sorted {
                if $0.cursor.date != $1.cursor.date {
                    return $0.cursor.date > $1.cursor.date
                }
                return $0.cursor.eventID.uuidString > $1.cursor.eventID.uuidString
            }
        let pageEntries = Array(entries.prefix(limit))
        let hasMore = entries.count > pageEntries.count
        return KDriveProviderTimelinePage(
            entries: pageEntries,
            nextCursor: hasMore ? pageEntries.last?.cursor : nil,
            hasMore: hasMore
        )
    }
}
#endif
